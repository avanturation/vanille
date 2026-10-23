import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

final class SourceSignal: @unchecked Sendable {
    let peak = Atomic<Double>(0)
    let capturedSignal = Atomic<Bool>(false)
    let ready: Atomic<Bool>
    init(ready: Bool) { self.ready = Atomic(ready) }
}

struct RenderRoute {
    let left: Int
    let right: Int
}

private struct ChannelPointer {
    var data: UnsafeMutablePointer<Float>?
    var stride = 1
    var frames = 0
}

/// HAL owns callback timing; no UI, allocation, file IO, or locks occur here.
final class RenderContext: @unchecked Sendable {
    let mailbox = ParameterMailbox()
    let dsp: StereoDSP
    let routes: [RenderRoute]
    let destinations: [RenderRoute]
    let outputMixer: OutputMixer
    let timingPulse:TimingPulse
    let signals: [SourceSignal]
    let telemetry: CallbackTelemetry
    let captureSlots:[CaptureSlot]
    private let captureScratch:UnsafeMutablePointer<Float>?
    private let captureBuffers:UnsafeMutableAudioBufferListPointer?
    private let capturePhaseGuard:Int
    let suppressOutput = Atomic<Bool>(false)
    private let sourcePeaks: UnsafeMutablePointer<Double>
    private let sourceReady: UnsafeMutablePointer<Bool>
    private let inputPointers: UnsafeMutablePointer<ChannelPointer>
    private let outputPointers: UnsafeMutablePointer<ChannelPointer>
    let callbacks = Atomic<UInt64>(0)
    let fault = Atomic<Bool>(false)
    let inputRMS = Atomic<Double>(0)
    let outputRMS = Atomic<Double>(0)
    let sampleFrames = Atomic<UInt64>(0)
    let clipped = Atomic<UInt64>(0)
    static let maximumFrames = 16_384

    init(sampleRate: Double, routes: [RenderRoute], initiallyReady: Bool = true,
         destinations: [RenderRoute] = [RenderRoute(left:0,right:1)], bufferedCapture:Bool = false, capturePhaseGuard:Int = 0) {
        self.routes = routes
        self.capturePhaseGuard = capturePhaseGuard
        if bufferedCapture {
            captureSlots = routes.map { _ in CaptureSlot() }
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity:routes.count*Self.maximumFrames*2)
            scratch.initialize(repeating:0,count:routes.count*Self.maximumFrames*2); captureScratch = scratch
            let buffers = AudioBufferList.allocate(maximumBuffers:routes.count)
            for index in routes.indices {
                buffers[index] = AudioBuffer(mNumberChannels:2,mDataByteSize:0,mData:scratch.advanced(by:index*Self.maximumFrames*2))
            }
            captureBuffers = buffers
        } else { captureSlots = []; captureScratch = nil; captureBuffers = nil }
        telemetry = CallbackTelemetry(sampleRate: sampleRate)
        self.destinations = destinations
        outputMixer = OutputMixer(sampleRate:sampleRate,destinations:destinations.count)
        timingPulse = TimingPulse(sampleRate:sampleRate)
        signals = routes.map { _ in SourceSignal(ready: initiallyReady) }
        sourcePeaks = .allocate(capacity: max(1,routes.count))
        sourcePeaks.initialize(repeating: 0, count: max(1,routes.count))
        sourceReady = .allocate(capacity: max(1,routes.count))
        sourceReady.initialize(repeating: initiallyReady, count: max(1,routes.count))
        dsp = StereoDSP(sampleRate: sampleRate, mailbox: mailbox)
        inputPointers = .allocate(capacity: max(2, routes.count*2))
        inputPointers.initialize(repeating: ChannelPointer(), count: max(2, routes.count*2))
        outputPointers = .allocate(capacity: destinations.count*2)
        outputPointers.initialize(repeating: ChannelPointer(), count: destinations.count*2)
    }
    deinit {
        captureScratch?.deinitialize(count:routes.count*Self.maximumFrames*2); captureScratch?.deallocate()
        captureBuffers?.unsafeMutablePointer.deallocate()
        sourcePeaks.deinitialize(count:max(1,routes.count)); sourcePeaks.deallocate()
        sourceReady.deinitialize(count:max(1,routes.count)); sourceReady.deallocate()
        inputPointers.deinitialize(count: max(2,routes.count*2)); inputPointers.deallocate()
        outputPointers.deinitialize(count: destinations.count*2); outputPointers.deallocate()
    }
    @inline(__always) func renderCaptured(output:UnsafeMutablePointer<AudioBufferList>,frames:Int) {
        guard frames>0, frames<=Self.maximumFrames, let captureBuffers, let captureScratch else {
            for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data,0,Int(buffer.mDataByteSize)) } }
            fault.store(true,ordering:.relaxed); return
        }
        for index in captureSlots.indices {
            let pointer = captureScratch.advanced(by:index*Self.maximumFrames*2)
            captureSlots[index].pull(into:pointer,frames:frames,phaseGuard:capturePhaseGuard)
            captureBuffers[index].mDataByteSize = UInt32(frames*8)
        }
        render(input:UnsafePointer(captureBuffers.unsafeMutablePointer),output:output)
    }
    @inline(__always) private func channel(_ channel: Int, in buffers: UnsafeMutableAudioBufferListPointer) -> ChannelPointer {
        var start = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            if channel < start+channels, channels > 0, let data = buffer.mData {
                return ChannelPointer(data: data.assumingMemoryBound(to: Float.self).advanced(by: channel-start),
                                      stride: channels, frames: Int(buffer.mDataByteSize) / (4*channels))
            }
            start += channels
        }
        return ChannelPointer()
    }
    @inline(__always) func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        if suppressOutput.load(ordering: .relaxed) { return }
        for destination in destinations.indices {
            outputPointers[destination*2] = channel(destinations[destination].left,in:outputs)
            outputPointers[destination*2+1] = channel(destinations[destination].right,in:outputs)
            if outputPointers[destination*2].data == nil || outputPointers[destination*2+1].data == nil {
                fault.store(true,ordering:.relaxed); return
            }
        }
        let frames = min(outputPointers[0].frames, outputPointers[1].frames)
        guard frames > 0, frames <= Self.maximumFrames else { fault.store(true, ordering: .relaxed); return }
        for i in 0..<(destinations.count*2) where outputPointers[i].frames != frames {
            fault.store(true,ordering:.relaxed); return
        }
        for source in routes.indices {
            sourcePeaks[source] = 0
            sourceReady[source] = signals[source].ready.load(ordering: .acquiring)
            inputPointers[source*2] = channel(routes[source].left, in: inputs)
            inputPointers[source*2+1] = channel(routes[source].right, in: inputs)
            if inputPointers[source*2].frames < frames || inputPointers[source*2+1].frames < frames {
                telemetry.inputShortfalls.wrappingAdd(1,ordering:.relaxed)
                fault.store(true, ordering: .relaxed); return
            }
        }
        let p = mailbox.consume()
        outputMixer.beginBlock(p)
        var inputEnergy = 0.0, outputEnergy = 0.0
        for frame in 0..<frames {
            var left = 0.0, right = 0.0
            for source in routes.indices {
                let l = inputPointers[source*2], r = inputPointers[source*2+1]
                let gain = dsp.gain(source: source, parameters: p)
                let a = Double(l.data![frame*l.stride]), b = Double(r.data![frame*r.stride])
                if !a.isFinite || !b.isFinite { telemetry.invalidSamples.wrappingAdd(1,ordering:.relaxed); fault.store(true, ordering: .relaxed); continue }
                inputEnergy += (a*a+b*b)*0.5
                sourcePeaks[source] = max(sourcePeaks[source],max(abs(a),abs(b)))
                if sourceReady[source] { left += a*gain; right += b*gain }
            }
            let timing = timingPulse.sample(enabled:p[ParameterMailbox.timingIndex]>0.5)
            let result = dsp.process(left: left+timing, right: right+timing, parameters: p)
            outputMixer.push(left:result.0,right:result.1)
            for destination in destinations.indices {
                let routed = outputMixer.read(destination:destination,parameters:p)
                outputPointers[destination*2].data![frame*outputPointers[destination*2].stride] = Float(routed.0)
                outputPointers[destination*2+1].data![frame*outputPointers[destination*2+1].stride] = Float(routed.1)
            }
            outputMixer.advance()
            outputEnergy += (result.0*result.0+result.1*result.1)*0.5
        }
        inputRMS.store(sqrt(inputEnergy / Double(frames)), ordering: .relaxed)
        for source in routes.indices {
            signals[source].peak.store(sourcePeaks[source],ordering:.relaxed)
            // Latch short sounds until the control queue can confirm them. A periodic UI/control
            // poll must not miss a notification, click, or a short test pulse between polls.
            if sourcePeaks[source] > 1e-7 && !sourceReady[source] {
                signals[source].capturedSignal.store(true,ordering:.releasing)
            }
        }
        outputRMS.store(sqrt(outputEnergy / Double(frames)), ordering: .relaxed)
        sampleFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
        clipped.store(dsp.limitedSamples, ordering: .relaxed)
        callbacks.wrappingAdd(1, ordering: .relaxed)
    }
}

private let vanilleIOProc: AudioDeviceIOProc = { _, now, input, _, output, outputTime, clientData in
    guard let clientData else { return noErr }
    let context = Unmanaged<RenderContext>.fromOpaque(clientData).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    let frames = buffers.first.map { $0.mNumberChannels > 0 ? Int($0.mDataByteSize)/(4*Int($0.mNumberChannels)) : 0 } ?? 0
    context.telemetry.observe(now:now.pointee,output:outputTime.pointee,frames:frames)
    if context.captureSlots.isEmpty { context.render(input: input, output: output) }
    else { context.renderCaptured(output:output,frames:frames) }
    return noErr
}

struct EngineMetrics {
    var appIDs: [String] = []
    var running = false
    var callbacks: UInt64 = 0
    var sampleFrames: UInt64 = 0
    var inputRMS: Double = 0
    var outputRMS: Double = 0
    var limitedSamples: UInt64 = 0
    var originalAudioIDs: Set<String> = []
    var outputUIDs: [String] = []
    var outputDelayMS:[Double] = []
    var callbackGaps: UInt64 = 0
    var maximumCallbackGapMS: Double = 0
    var inputShortfalls: UInt64 = 0
    var sampleDiscontinuities: UInt64 = 0
    var sourceUnderruns:[String:UInt64] = [:]
    var sourceOverruns:[String:UInt64] = [:]
    var sourceQueuedFrames:[String:[UInt64]] = [:]
    var processUnderruns:[AudioObjectID:UInt64] = [:]
    var processOverruns:[AudioObjectID:UInt64] = [:]
    var processQueuedFrames:[AudioObjectID:[UInt64]] = [:]
    var processCaptureGaps:[AudioObjectID:UInt64] = [:]
    var error: String?
}

/// Control-queue lifecycle for the existing renderer. The physical output clock,
/// DSP and delay history survive process changes; each tap has an input-only reader.
final class AudioEngine {
    let diagnostics:AudioDiagnostics
    private var sources:[ProcessCapture] = []
    private var failedProcesses:Set<AudioObjectID> = []
    private var rejectedApps:Set<String> = []
    private var aggregate:AudioObjectID = 0
    private var ioProc:AudioDeviceIOProcID?
    private var context:RenderContext?
    private var lastCallbackCount:UInt64 = 0
    private var lastCallbackAt = Date()
    private var observations:[HALObservation] = []
    private let needsRebuild = Atomic<Bool>(false)
    private var routedDevices:[OutputDevice] = []
    private var routeSettings:[DeviceRoute] = []
    private var sourceDeviceUID = ""
    private var timingSound = false
    private var loggedGaps:UInt64 = 0
    private var loggedDiscontinuities:UInt64 = 0
    private var loggedUnderruns:[Int:UInt64] = [:]
    private var loggedOverruns:[Int:UInt64] = [:]
    private var expectedLayout:[StreamLayout] = []
    private(set) var sampleRate = 48_000.0
    init(diagnostics:AudioDiagnostics = AudioDiagnostics()) { self.diagnostics = diagnostics }
    var appIDs:[String] { Array(Set(sources.map(\.appID))).sorted() }
    private struct StreamLayout:Equatable {
        let rate:Double, channels:UInt32, format:UInt32, flags:UInt32, bits:UInt32, start:UInt32
    }
    private func streamLayout() throws -> [StreamLayout] {
        try HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput).map { stream in
            let f = try HAL.read(stream,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())
            return StreamLayout(rate:f.mSampleRate,channels:f.mChannelsPerFrame,format:f.mFormatID,flags:f.mFormatFlags,bits:f.mBitsPerChannel,
                start:try HAL.read(stream,kAudioStreamPropertyStartingChannel,default:UInt32(0)))
        }
    }
    func start(apps:[AudioApplication],device:OutputDevice,outputs:[OutputDevice],routes outputSettings:[DeviceRoute],
               settings:SavedState,queue:DispatchQueue) throws {
        stop()
        guard !apps.isEmpty || settings.timingSound else { return }
        guard !outputs.isEmpty, outputs.count<=ParameterMailbox.maxOutputs, outputSettings.count==outputs.count,
              outputs.allSatisfy({ $0.channels==2 && $0.sampleRate>=32_000 && $0.sampleRate<=192_000 }) else {
            throw AudioFailure(operation:"Choose connected stereo outputs at 32–192 kHz",status:kAudioHardwareUnsupportedOperationError)
        }
        let clock = outputs.first(where: { !$0.isAirPlay }) ?? outputs[0]
        do {
            diagnostics.record("engineStart","apps=\(apps.count) outputs=\(outputs.count) rate=\(clock.sampleRate)")
            sampleRate = clock.sampleRate; sourceDeviceUID = device.uid
            routedDevices = outputs; routeSettings = outputSettings
            let composition:[String:Any] = [kAudioAggregateDeviceNameKey:"Vanille Processing",
                kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,
                kAudioAggregateDeviceMainSubDeviceKey:clock.uid,
                kAudioAggregateDeviceSubDeviceListKey:outputs.map {
                    [kAudioSubDeviceUIDKey:$0.uid,kAudioSubDeviceDriftCompensationKey:$0.uid != clock.uid] as [String:Any]
                }]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&aggregate),"Create audio processing output")
            diagnostics.record("aggregateCreate","taps=0 outputs=\(outputs.count)")
            guard try HAL.strings(aggregate,kAudioAggregateDevicePropertyFullSubDeviceList)==outputs.map(\.uid),
                  try HAL.objects(aggregate,kAudioAggregateDevicePropertyActiveSubDeviceList).count==outputs.count else {
                throw AudioFailure(operation:"An output disconnected before routing started",status:kAudioDeviceUnsupportedFormatError)
            }
            let rate = try HAL.read(aggregate,kAudioDevicePropertyNominalSampleRate,default:Double(0))
            expectedLayout = try streamLayout()
            guard abs(rate-sampleRate)<1, expectedLayout.reduce(0,{ $0+Int($1.channels) })==outputs.count*2,
                  expectedLayout.allSatisfy({ abs($0.rate-sampleRate)<1 && $0.format==kAudioFormatLinearPCM && $0.bits==32 && $0.flags & kAudioFormatFlagIsFloat != 0 && $0.flags & kAudioFormatFlagIsBigEndian == 0 }) else {
                throw AudioFailure(operation:"Incompatible output format",status:kAudioDeviceUnsupportedFormatError)
            }
            let quantum = Int(try HAL.read(aggregate,kAudioDevicePropertyBufferFrameSize,default:UInt32(0)))
            guard quantum>0 && quantum<=RenderContext.maximumFrames else {
                throw AudioFailure(operation:"Unsupported output quantum",status:kAudioDeviceUnsupportedFormatError)
            }
            let render = RenderContext(sampleRate:sampleRate,
                routes:(0..<ParameterMailbox.maxSources).map { RenderRoute(left:$0*2,right:$0*2+1) },initiallyReady:false,
                destinations:outputs.indices.map { RenderRoute(left:$0*2,right:$0*2+1) },bufferedCapture:true,capturePhaseGuard:quantum)
            context = render; update(settings)
            try HAL.check(AudioDeviceCreateIOProcID(aggregate,vanilleIOProc,Unmanaged.passUnretained(render).toOpaque(),&ioProc),"Create realtime output callback")
            try disablePhysicalInputs()
            needsRebuild.store(false,ordering:.relaxed)
            if let observation = HALObservation(aggregate,kAudioDevicePropertyStreamConfiguration,scope:kAudioObjectPropertyScopeOutput,queue:queue,change: { [weak self] in
                self?.diagnostics.record("engineConfigurationNotification"); self?.needsRebuild.store(true,ordering:.relaxed)
            }) { observations.append(observation) }
            for d in outputs+[device] {
                for selector in [kAudioDevicePropertyNominalSampleRate,kAudioDevicePropertyDeviceIsAlive] {
                    if let observation = HALObservation(d.id,selector,queue:queue,change: { [weak self] in
                        self?.diagnostics.record(selector==kAudioDevicePropertyNominalSampleRate ? "sampleRateNotification" : "deviceAliveNotification")
                        self?.needsRebuild.store(true,ordering:.relaxed)
                    }) { observations.append(observation) }
                }
            }
            try HAL.check(AudioDeviceStart(aggregate,ioProc),"Start audio output")
            diagnostics.record("outputStreamStart","quantum=\(quantum) inputPhaseGuardFrames=\(quantum)")
            lastCallbackAt = Date(); lastCallbackCount = 0; loggedGaps = 0; loggedDiscontinuities = 0
            reconcileSources(apps,allApps:apps,settings:settings)
        } catch { diagnostics.record("engineStartFailure",error.localizedDescription); stop(); throw error }
    }
    private func disablePhysicalInputs() throws {
        let inputs = try HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput)
        guard !inputs.isEmpty, let ioProc else { return }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of:\.mStreamIsOn)!
        let bytes = offset+inputs.count*MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount:bytes,alignment:MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as:UInt8.self,repeating:0,count:bytes)
        let usage = storage.assumingMemoryBound(to:AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc,to:UnsafeMutableRawPointer.self); usage.pointee.mNumberStreams = UInt32(inputs.count)
        var address = HAL.address(kAudioDevicePropertyIOProcStreamUsage,scope:kAudioObjectPropertyScopeInput)
        try HAL.check(AudioObjectSetPropertyData(aggregate,&address,0,nil,UInt32(bytes),storage),"Exclude physical inputs")
    }
    func reconcileSources(_ apps:[AudioApplication],allApps:[AudioApplication],settings:SavedState,retry:Bool = false) {
        guard let context, aggregate != 0,
              let validList = try? HAL.objects(HAL.system,kAudioHardwarePropertyProcessObjectList) else { return }
        let valid = Set(validList)
        if retry { failedProcesses.removeAll() }
        failedProcesses.formIntersection(valid.intersection(Set(apps.flatMap(\.processes)))); rejectedApps.removeAll()
        let onOtherOutput = Set(allApps.filter { app in !apps.contains(where: { $0.id==app.id }) }.map(\.id))
        sources.removeAll { source in
            if !valid.contains(source.process) || settings.applications[source.appID]?.bypass == true || onOtherOutput.contains(source.appID) {
                source.stop(); return true
            }
            return false
        }
        for app in apps {
            for process in app.processes where !sources.contains(where: { $0.process==process }) {
                guard !failedProcesses.contains(process) else { rejectedApps.insert(app.id); continue }
                let occupied = Set(sources.map(\.index)).union(context.captureSlots.indices.filter { context.captureSlots[$0].blocked.load(ordering:.acquiring) })
                guard let index = (0..<ParameterMailbox.maxSources).first(where: { !occupied.contains($0) }) else {
                    rejectedApps.insert(app.id); diagnostics.record("sourceCapacityBypass"); continue
                }
                do {
                    let source = try ProcessCapture(appID:app.id,process:process,index:index,deviceUID:sourceDeviceUID,sampleRate:sampleRate,
                        slot:context.captureSlots[index],signal:context.signals[index],diagnostics:diagnostics)
                    sources.append(source)
                    diagnostics.record("sourceAttach","slot=\(index)")
                } catch {
                    failedProcesses.insert(process); rejectedApps.insert(app.id)
                    diagnostics.record("sourceAttachBypass",error.localizedDescription)
                }
            }
        }
        update(settings)
    }
    func update(_ settings:SavedState,routes:[DeviceRoute]? = nil) {
        if let routes { routeSettings = routes }
        timingSound = settings.timingSound
        var gains = Array(repeating:Float(0),count:ParameterMailbox.maxSources)
        for source in sources {
            let value = settings.applications[source.appID] ?? AppVolume()
            gains[source.index] = value.muted ? 0 : value.volume
        }
        context?.mailbox.publish(gains:gains,eq:settings.eq,sampleRate:sampleRate,outputs:routeSettings,timingSound:timingSound)
    }
    func metrics() -> EngineMetrics {
        guard let context else { return EngineMetrics() }
        sources.removeAll { source in
            if !source.poll() { failedProcesses.insert(source.process); rejectedApps.insert(source.appID); return true }
            return false
        }
        let active = Array(Set(sources.filter { context.signals[$0.index].ready.load(ordering:.relaxed) }.map(\.appID))).sorted()
        let count = context.callbacks.load(ordering:.relaxed)
        if count != lastCallbackCount { lastCallbackAt = Date(); lastCallbackCount = count }
        var changed = false
        if needsRebuild.exchange(false,ordering:.acquiringAndReleasing) {
            changed = (try? streamLayout()) != expectedLayout || !routedDevices.allSatisfy {
                (try? HAL.read($0.id,kAudioDevicePropertyDeviceIsAlive,default:UInt32(0)))==1
                    && abs(((try? HAL.read($0.id,kAudioDevicePropertyNominalSampleRate,default:Double(0))) ?? 0)-$0.sampleRate)<1
            }
            diagnostics.record(changed ? "configurationChanged" : "configurationUnchanged")
        }
        let gaps = context.telemetry.gaps.load(ordering:.relaxed)
        let discontinuities = context.telemetry.sampleDiscontinuities.load(ordering:.relaxed)
        if gaps != loggedGaps { diagnostics.record("callbackGap","count=\(gaps) maxMS=\(context.telemetry.maximumGapMS)"); loggedGaps = gaps }
        if discontinuities != loggedDiscontinuities { diagnostics.record("outputSampleDiscontinuity","count=\(discontinuities)"); loggedDiscontinuities = discontinuities }
        var result = EngineMetrics(appIDs:active,running:count>0 && (!active.isEmpty || timingSound),callbacks:count,
            sampleFrames:context.sampleFrames.load(ordering:.relaxed),inputRMS:context.inputRMS.load(ordering:.relaxed),
            outputRMS:context.outputRMS.load(ordering:.relaxed),limitedSamples:context.clipped.load(ordering:.relaxed))
        result.originalAudioIDs = Set(appIDs).subtracting(active).union(rejectedApps)
        result.outputUIDs = routedDevices.map(\.uid); result.outputDelayMS = routeSettings.map(\.delayMS)
        result.callbackGaps = gaps; result.maximumCallbackGapMS = context.telemetry.maximumGapMS
        result.inputShortfalls = context.telemetry.inputShortfalls.load(ordering:.relaxed); result.sampleDiscontinuities = discontinuities
        for source in sources {
            let slot = context.captureSlots[source.index]
            let underruns = slot.underruns.load(ordering:.relaxed), overruns = slot.overruns.load(ordering:.relaxed)
            result.sourceUnderruns[source.appID,default:0] += underruns
            result.sourceOverruns[source.appID,default:0] += overruns
            result.processUnderruns[source.process] = underruns
            result.processOverruns[source.process] = overruns
            result.processCaptureGaps[source.process] = source.callbackGaps
            if underruns != (loggedUnderruns[source.index] ?? 0) { diagnostics.record("inputRingUnderrun","slot=\(source.index) count=\(underruns)"); loggedUnderruns[source.index] = underruns }
            if overruns != (loggedOverruns[source.index] ?? 0) { diagnostics.record("inputRingOverrun","slot=\(source.index) count=\(overruns)"); loggedOverruns[source.index] = overruns }
            let minimum = slot.minimumQueued.load(ordering:.relaxed)
            let written = slot.written.load(ordering:.acquiring), consumed = slot.consumed.load(ordering:.acquiring)
            result.sourceQueuedFrames[source.appID] = [minimum == .max ? 0 : minimum,slot.maximumQueued.load(ordering:.relaxed),UInt64(slot.producerQuantum.load(ordering:.relaxed)),written>=consumed ? written-consumed : 0]
            result.processQueuedFrames[source.process] = result.sourceQueuedFrames[source.appID]
        }
        if context.fault.load(ordering:.relaxed) || changed || Date().timeIntervalSince(lastCallbackAt)>1.5 {
            result.running = false; result.appIDs = []
            result.error = changed ? "The output configuration changed. Original audio restored." : "Audio output stopped responding. Original audio restored."
            stop()
        }
        return result
    }
    func stop() {
        if aggregate != 0 { diagnostics.record("engineStop","callbacks=\(context?.callbacks.load(ordering:.relaxed) ?? 0)") }
        observations.removeAll(); context?.suppressOutput.store(true,ordering:.relaxed)
        for source in sources { source.stop() }; sources.removeAll()
        var callbackDestroyed = true
        if aggregate != 0, let ioProc {
            let status = AudioDeviceStop(aggregate,ioProc)
            diagnostics.record("outputStreamStop","status=\(status)")
            callbackDestroyed = AudioDeviceDestroyIOProcID(aggregate,ioProc)==noErr
        }
        ioProc = nil
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            diagnostics.record("aggregateDestroy","status=\(status)")
            if status != noErr, !callbackDestroyed, let context { _ = Unmanaged.passRetained(context) }
        }
        aggregate = 0; context = nil; routedDevices.removeAll(); routeSettings.removeAll()
        failedProcesses.removeAll(); rejectedApps.removeAll(); expectedLayout.removeAll(); timingSound = false
        loggedUnderruns.removeAll(); loggedOverruns.removeAll()
    }
    deinit { stop() }
}

final class AudioController: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.avanturation.Vanille.audio-control", qos: .userInitiated)
    let diagnostics = AudioDiagnostics()
    private let engine: AudioEngine
    private var signature = ""
    private var lastError: String?
    private var failedSignature: String?
    private var watchdog: DispatchSourceTimer?
    private var currentMetrics = EngineMetrics()

    init() {
        engine = AudioEngine(diagnostics:diagnostics)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let m = self.engine.metrics()
            if let error = m.error { self.lastError = error; self.failedSignature = self.signature; self.signature = "" }
            self.currentMetrics = m
        }
        watchdog = timer; timer.resume()
    }
    func reconcile(apps: [AudioApplication], output: OutputDevice?, availableOutputs: [OutputDevice] = [], state: SavedState, retry: Bool = false) {
        queue.async { [self] in
            let configured = state.outputGroups.first(where: { $0.id == state.selectedGroupID })?.devices ?? output.map {
                [state.deviceSettings[$0.uid] ?? DeviceRoute(id:$0.uid,name:$0.name)]
            } ?? []
            let available = availableOutputs.isEmpty ? output.map { [$0] } ?? [] : availableOutputs
            let pairs = configured.filter(\.enabled).compactMap { route -> (OutputDevice,DeviceRoute)? in
                guard let device = OutputRouting.device(for:route.id,in:available) else { return nil }
                return (device,route)
            }
            let destinations = pairs.map { $0.0 }
            var routes = pairs.map { $0.1 }
            let candidates = apps.filter { app in
                !(state.applications[app.id]?.bypass ?? false)
                && (output.map { app.outputDevices.contains($0.id) } ?? false)
            }
            if !state.manualTimingForVerification {
                if destinations.count<2 {
                    for i in routes.indices { routes[i].delayMS = 0 }
                } else if let offsets = LatencyAlignment.offsets(destinations.map(\.reportedLatencyMS)) {
                    for i in routes.indices { routes[i].delayMS = offsets[i] }
                } else if !state.processingPaused && (!candidates.isEmpty || state.timingSound) {
                    engine.stop(); signature = ""; currentMetrics = EngineMetrics()
                    lastError = "These speakers cannot currently be used together. Original audio is playing."
                    return
                }
            }
            let desired = state.processingPaused || output == nil || destinations.isEmpty ? "" :
                "\(output!.id):\(output!.uid):\(output!.sampleRate):\(output!.channels):" + destinations.map { "\($0.id):\($0.uid):\($0.sampleRate):\($0.channels)" }.joined(separator:",")
            if retry { failedSignature = nil; lastError = nil }
            if desired.isEmpty {
                engine.stop(); signature = ""; currentMetrics = EngineMetrics()
                if state.processingPaused { lastError = nil; failedSignature = nil }
                return
            }
            if desired == failedSignature { return }
            if desired != signature {
                diagnostics.record("routingRebuild", "apps=\(candidates.count) outputs=\(destinations.count)")
                engine.stop(); signature = ""
                if candidates.isEmpty && !state.timingSound { return }
                do {
                    try engine.start(apps: candidates, device: output!, outputs:destinations, routes:routes, settings: state, queue: queue)
                    signature = desired; lastError = nil
                } catch {
                    lastError = error.localizedDescription; failedSignature = desired
                    engine.stop(); currentMetrics = EngineMetrics()
                }
            } else {
                engine.reconcileSources(candidates,allApps:apps,settings:state,retry:retry)
                engine.update(state,routes:routes)
            }
        }
    }
    func snapshot(_ completion: @escaping (EngineMetrics) -> Void) {
        queue.async { [self] in
            var result = currentMetrics
            result.error = lastError ?? result.error
            DispatchQueue.main.async { completion(result) }
        }
    }
    func stopSynchronously() { queue.sync { engine.stop(); signature = ""; currentMetrics = EngineMetrics() } }
    deinit { watchdog?.cancel() }
}
