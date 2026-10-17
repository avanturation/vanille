import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

private struct TapHandle {
    let appID: String
    let object: AudioObjectID
    let uid: String
    let description: CATapDescription
}

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
         destinations: [RenderRoute] = [RenderRoute(left:0,right:1)]) {
        self.routes = routes
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
        sourcePeaks.deinitialize(count:max(1,routes.count)); sourcePeaks.deallocate()
        sourceReady.deinitialize(count:max(1,routes.count)); sourceReady.deallocate()
        inputPointers.deinitialize(count: max(2,routes.count*2)); inputPointers.deallocate()
        outputPointers.deinitialize(count: destinations.count*2); outputPointers.deallocate()
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
                if !a.isFinite || !b.isFinite { fault.store(true, ordering: .relaxed); continue }
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

private let vanilleIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<RenderContext>.fromOpaque(clientData).takeUnretainedValue().render(input: input, output: output)
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
    var error: String?
}

/// Owned exclusively by AudioController's serial control queue.
/// One private aggregate clocks all process taps against the selected physical output.
final class AudioEngine {
    private var taps: [TapHandle] = []
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var context: RenderContext?
    private var startedAt = Date.distantPast
    private var lastCallbackCount: UInt64 = 0
    private var lastCallbackAt = Date.distantPast
    private var observations: [HALObservation] = []
    private let needsRebuild = Atomic<Bool>(false)
    private var activationFailures: Set<Int> = []
    private var routedDevices: [OutputDevice] = []
    private var routeSettings: [DeviceRoute] = []
    private var timingSound = false
    private(set) var sampleRate = 48_000.0
    var appIDs: [String] { taps.map(\.appID) }

    func start(apps: [AudioApplication], device: OutputDevice, outputs: [OutputDevice], routes outputSettings: [DeviceRoute],
               settings: SavedState, queue: DispatchQueue) throws {
        stop()
        guard !apps.isEmpty || settings.timingSound else { return }
        guard !outputs.isEmpty, outputs.count <= ParameterMailbox.maxOutputs, outputSettings.count == outputs.count else {
            throw AudioFailure(operation:"Choose one to eight connected outputs",status:kAudioHardwareUnsupportedOperationError)
        }
        guard apps.count <= ParameterMailbox.maxSources else {
            throw AudioFailure(operation: "Too many applications. Processing is paused", status: kAudioHardwareUnsupportedOperationError)
        }
        let clock = outputs.first(where: { !$0.isAirPlay }) ?? outputs[0]
        guard outputs.allSatisfy({ $0.channels == 2 && $0.sampleRate >= 32_000 && $0.sampleRate <= 192_000 }) else {
            throw AudioFailure(operation: "Processing requires a stereo output at 32–192 kHz", status: kAudioHardwareUnsupportedOperationError)
        }
        do {
            sampleRate = clock.sampleRate
            routedDevices = outputs; routeSettings = outputSettings
            for app in apps {
                let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
                description.name = "Vanille · \(app.name)"
                description.isPrivate = true
                description.deviceUID = device.uid
                // Verify that readable audio exists before replacing the source's output.
                // Denied capture and initially uncapturable content remain on their original path.
                description.muteBehavior = .unmuted
                var tap: AudioObjectID = 0
                try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Allow system audio access to process \(app.name)")
                let uid: String
                do { uid = try HAL.string(tap, kAudioTapPropertyUID) }
                catch { AudioHardwareDestroyProcessTap(tap); throw error }
                taps.append(TapHandle(appID: app.id, object: tap, uid: uid, description: description))
                let format = try HAL.read(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
                guard Self.supports(format), format.mChannelsPerFrame == 2 else {
                    throw AudioFailure(operation: "Unsupported tap format for \(app.name)", status: kAudioDeviceUnsupportedFormatError)
                }
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Vanille Processing",
                kAudioAggregateDeviceUIDKey: "com.avanturation.Vanille.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
                kAudioAggregateDeviceSubDeviceListKey: outputs.map { d in
                    [kAudioSubDeviceUIDKey:d.uid,kAudioSubDeviceDriftCompensationKey:d.uid != clock.uid] as [String:Any]
                },
                kAudioAggregateDeviceTapListKey: taps.map {
                    [kAudioSubTapUIDKey: $0.uid, kAudioSubTapDriftCompensationKey: true] as [String: Any]
                },
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create audio processing output")
            guard try HAL.strings(aggregate,kAudioAggregateDevicePropertyFullSubDeviceList) == outputs.map(\.uid) else {
                throw AudioFailure(operation:"Unexpected output stream order. Original audio kept",status:kAudioDeviceUnsupportedFormatError)
            }
            // Retain the hardware's rate; no device-wide sample-rate writes are made.
            let actualRate = try HAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, default: Double(0))
            guard abs(actualRate-sampleRate) < 1 else {
                throw AudioFailure(operation: "Output clock is not ready", status: kAudioDeviceUnsupportedFormatError)
            }
            let inputs = try HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            let physicalInputs = try outputs.reduce(0) { total,d in total + (try HAL.objects(d.id,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput).count) }
            guard inputs.count == physicalInputs + taps.count else {
                throw AudioFailure(operation: "Unexpected tap stream layout", status: kAudioDeviceUnsupportedFormatError)
            }
            let orderedUIDs = try tapOrder()
            guard orderedUIDs.count == taps.count, Set(orderedUIDs) == Set(taps.map(\.uid)) else {
                throw AudioFailure(operation: "Unexpected tap order", status: kAudioDeviceUnsupportedFormatError)
            }
            taps = orderedUIDs.compactMap { uid in taps.first { $0.uid == uid } }
            var routes: [RenderRoute] = []
            for stream in inputs.suffix(taps.count) {
                let f = try HAL.read(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
                guard Self.supports(f), f.mChannelsPerFrame == 2, abs(f.mSampleRate-sampleRate) < 1 else {
                    throw AudioFailure(operation: "Incompatible input stream", status: kAudioDeviceUnsupportedFormatError)
                }
                let first = try HAL.read(stream, kAudioStreamPropertyStartingChannel, default: UInt32(0))
                guard first > 0 else { throw AudioFailure(operation: "Invalid channel map", status: kAudioDeviceUnsupportedFormatError) }
                routes.append(RenderRoute(left: Int(first)-1, right: Int(first)))
            }
            let outputStreams = try HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var outputChannels: UInt32 = 0
            for stream in outputStreams {
                let f = try HAL.read(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
                guard Self.supports(f), abs(f.mSampleRate-sampleRate) < 1 else {
                    throw AudioFailure(operation: "Incompatible output stream", status: kAudioDeviceUnsupportedFormatError)
                }
                outputChannels += f.mChannelsPerFrame
            }
            guard outputChannels == outputs.count*2,
                  try HAL.objects(aggregate,kAudioAggregateDevicePropertyActiveSubDeviceList).count == outputs.count else {
                throw AudioFailure(operation:"An output disconnected before routing started",status:kAudioDeviceUnsupportedFormatError)
            }
            let renderContext = RenderContext(sampleRate: sampleRate, routes: routes, initiallyReady: false,
                destinations:outputs.indices.map { RenderRoute(left:$0*2,right:$0*2+1) })
            context = renderContext
            update(settings)
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, vanilleIOProc,
                Unmanaged.passUnretained(renderContext).toOpaque(), &ioProc), "Create realtime audio callback")
            // Disable every physical input (including microphones) for this IOProc.
            try disablePhysicalInputs(count: physicalInputs, total: inputs.count)
            needsRebuild.store(false, ordering: .relaxed)
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                if let o = HALObservation(aggregate, kAudioDevicePropertyStreamConfiguration, scope: scope, queue: queue, change: { [weak self] in self?.needsRebuild.store(true, ordering: .relaxed) }) { observations.append(o) }
            }
            for d in outputs + [device] {
                for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
                    if let o = HALObservation(d.id, selector, queue: queue, change: { [weak self] in self?.needsRebuild.store(true, ordering: .relaxed) }) { observations.append(o) }
                }
            }
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "Start processing (system audio permission may be required)")
            startedAt = Date(); lastCallbackAt = startedAt; lastCallbackCount = 0
        } catch { stop(); throw error }
    }
    private static func supports(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && f.mBitsPerChannel == 32
    }
    private func tapOrder() throws -> [String] {
        try HAL.strings(aggregate,kAudioAggregateDevicePropertyTapList)
    }
    private func disablePhysicalInputs(count: Int, total: Int) throws {
        guard count > 0, let ioProc else { return }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let bytes = offset + total * MemoryLayout<UInt32>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { data.deallocate() }
        data.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let usage = data.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = data.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        for i in 0..<total { flags[i] = i < count ? 0 : 1 }
        var a = HAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        try HAL.check(AudioObjectSetPropertyData(aggregate, &a, 0, nil, UInt32(bytes), data), "Exclude physical input streams")
    }
    func update(_ settings: SavedState, routes: [DeviceRoute]? = nil) {
        if let routes { routeSettings = routes }
        timingSound = settings.timingSound
        context?.mailbox.publish(gains: appIDs.map {
            let v = settings.applications[$0] ?? AppVolume()
            return v.muted ? 0 : v.volume
        }, eq: settings.eq, sampleRate: sampleRate, outputs:routeSettings,timingSound:timingSound)
    }
    func metrics() -> EngineMetrics {
        guard let context else { return EngineMetrics() }
        for index in taps.indices where !context.signals[index].ready.load(ordering: .relaxed)
            && !activationFailures.contains(index) && context.signals[index].capturedSignal.load(ordering: .acquiring) {
            let description = taps[index].description
            description.muteBehavior = .mutedWhenTapped
            do {
                try HAL.write(taps[index].object, kAudioTapPropertyDescription, value: description)
                context.signals[index].ready.store(true,ordering:.releasing)
            } catch {
                description.muteBehavior = .unmuted
                activationFailures.insert(index)
                NSLog("Vanille kept original audio: %@",error.localizedDescription)
            }
        }
        let active = taps.indices.filter { context.signals[$0].ready.load(ordering:.relaxed) }.map { taps[$0].appID }
        let count = context.callbacks.load(ordering: .relaxed)
        if count != lastCallbackCount { lastCallbackAt = Date(); lastCallbackCount = count }
        let timedOut = Date().timeIntervalSince(lastCallbackAt) > 1.5
        let invalid = context.fault.load(ordering: .relaxed) || needsRebuild.load(ordering: .relaxed)
        var result = EngineMetrics(appIDs: active, running: count > 0 && (!active.isEmpty || timingSound), callbacks: count,
            sampleFrames: context.sampleFrames.load(ordering: .relaxed),
            inputRMS: context.inputRMS.load(ordering: .relaxed), outputRMS: context.outputRMS.load(ordering: .relaxed),
            limitedSamples: context.clipped.load(ordering: .relaxed))
        if Date().timeIntervalSince(startedAt) > 2 { result.originalAudioIDs = Set(appIDs).subtracting(active) }
        result.outputUIDs = routedDevices.map(\.uid)
        result.outputDelayMS = routeSettings.map(\.delayMS)
        if active.isEmpty && !timingSound && Date().timeIntervalSince(startedAt) > 12 {
            result.error = "No processable audio was received. Original audio is playing. Check audio permission or use Protected Content Bypass."
            stop(); return result
        }
        if invalid || timedOut {
            result.running = false
            result.appIDs = []
            result.error = invalid ? "The audio format changed. Original audio has been restored." : "Audio processing did not respond. Original audio has been restored. Check System Audio Recording permission."
            stop()
        }
        return result
    }
    func stop() {
        observations.removeAll()
        // Stop the reader first: mutedWhenTapped restores the original output before teardown.
        var callbackDestroyed = true
        if aggregate != 0, let ioProc {
            let status = AudioDeviceStop(aggregate, ioProc)
            if status != noErr {
                context?.suppressOutput.store(true,ordering:.relaxed)
                for tap in taps {
                    tap.description.muteBehavior = .unmuted
                    try? HAL.write(tap.object,kAudioTapPropertyDescription,value:tap.description)
                }
                NSLog("Vanille audio stop status: %d",status)
            }
            let destroyed = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            callbackDestroyed = destroyed == noErr
            if destroyed != noErr { NSLog("Vanille callback teardown status: %d",destroyed) }
        }
        ioProc = nil
        if aggregate != 0 {
            let destroyed = AudioHardwareDestroyAggregateDevice(aggregate)
            if destroyed != noErr {
                NSLog("Vanille aggregate teardown status: %d",destroyed)
                if !callbackDestroyed, let context {
                    // If HAL refuses both unregister operations, retain storage until process exit
                    // rather than risk a callback using freed memory. Suppress all output first.
                    context.suppressOutput.store(true,ordering:.relaxed)
                    _ = Unmanaged.passRetained(context)
                }
            }
            aggregate = 0
        }
        for tap in taps {
            let status = AudioHardwareDestroyProcessTap(tap.object)
            if status != noErr { NSLog("Vanille tap teardown status: %d",status) }
        }
        taps.removeAll()
        activationFailures.removeAll()
        routedDevices.removeAll(); routeSettings.removeAll(); timingSound = false
        // IOProc has been unregistered, so all realtime storage can now be reclaimed.
        context = nil
    }
    deinit { stop() }
}

final class AudioController: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.avanturation.Vanille.audio-control", qos: .userInitiated)
    private let engine = AudioEngine()
    private var signature = ""
    private var lastError: String?
    private var failedSignature: String?
    private var watchdog: DispatchSourceTimer?
    private var currentMetrics = EngineMetrics()

    init() {
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
                "\(output!.uid):\(output!.sampleRate):" + destinations.map { "\($0.uid):\($0.sampleRate)" }.joined(separator:",")
                + ":timing=\(state.timingSound):"
                + candidates.map { "\($0.id)=\($0.processes.sorted())" }.joined(separator: ";")
            if retry { failedSignature = nil; lastError = nil }
            if desired.isEmpty || (candidates.isEmpty && !state.timingSound) {
                engine.stop(); signature = ""; currentMetrics = EngineMetrics()
                if state.processingPaused { lastError = nil; failedSignature = nil }
                return
            }
            if desired == failedSignature { return }
            if desired != signature {
                engine.stop(); signature = ""
                do {
                    try engine.start(apps: candidates, device: output!, outputs:destinations, routes:routes, settings: state, queue: queue)
                    signature = desired; lastError = nil
                } catch {
                    lastError = error.localizedDescription; failedSignature = desired
                    engine.stop(); currentMetrics = EngineMetrics()
                }
            } else { engine.update(state,routes:routes) }
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
