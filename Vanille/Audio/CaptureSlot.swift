import Foundation
import CoreAudio
import Synchronization

/// Fixed SPSC storage between one tap reader and the persistent output IOProc.
/// Capacity bounds memory; it is never used as a latency/prefill target.
final class CaptureSlot: @unchecked Sendable {
    let written = Atomic<UInt64>(0)
    let consumed = Atomic<UInt64>(0)
    let epoch = Atomic<UInt64>(0)
    let epochStart = Atomic<UInt64>(0)
    private let acknowledgedEpoch = Atomic<UInt64>(UInt64.max)
    let enabled = Atomic<Bool>(false)
    let blocked = Atomic<Bool>(false)
    let producerQuantum = Atomic<Int>(0)
    let underruns = Atomic<UInt64>(0)
    let overruns = Atomic<UInt64>(0)
    let minimumQueued = Atomic<UInt64>(UInt64.max)
    let maximumQueued = Atomic<UInt64>(0)
    let capacity:Int
    private let samples:UnsafeMutablePointer<Float>
    // Consumer-owned state. No control-thread writes after output starts.
    private var reader:UInt64 = 0
    private var readerEpoch:UInt64 = .max
    private var primed = false
    init(capacity:Int = RenderContext.maximumFrames*2) {
        self.capacity = capacity
        samples = .allocate(capacity:capacity*2); samples.initialize(repeating:0,count:capacity*2)
    }
    deinit { samples.deinitialize(count:capacity*2); samples.deallocate() }
    /// Old producer has stopped before a slot is reassigned. Output remains running.
    func begin() {
        enabled.store(false,ordering:.releasing)
        let start = written.load(ordering:.acquiring)
        epochStart.store(start,ordering:.relaxed)
        epoch.wrappingAdd(1,ordering:.releasing)
        enabled.store(true,ordering:.releasing)
    }
    @inline(__always) func push(_ input:UnsafePointer<AudioBufferList>,peak:UnsafeMutablePointer<Float>? = nil) -> Bool {
        peak?.pointee = 0
        guard enabled.load(ordering:.acquiring), acknowledgedEpoch.load(ordering:.acquiring) == epoch.load(ordering:.acquiring) else { return true }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels>0 else { return true }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize)/(4*channels)
        guard frames>0 else { return true }
        guard frames<=RenderContext.maximumFrames else { return false }
        producerQuantum.store(frames,ordering:.relaxed)
        let position = written.load(ordering:.relaxed)
        let oldest = consumed.load(ordering:.acquiring)
        guard position>=oldest, position-oldest+UInt64(frames)<=UInt64(capacity) else {
            overruns.wrappingAdd(1,ordering:.relaxed); return false
        }
        let left = data.assumingMemoryBound(to:Float.self)
        let right:UnsafePointer<Float>
        let rightStride:Int
        if channels>=2 { right = UnsafePointer(left.advanced(by:1)); rightStride = channels }
        else if buffers.count>1, let second = buffers.dropFirst().first, second.mNumberChannels>0,
                Int(second.mDataByteSize)>=frames*4*Int(second.mNumberChannels), let pointer = second.mData {
            right = UnsafePointer(pointer.assumingMemoryBound(to:Float.self)); rightStride = Int(second.mNumberChannels)
        } else { return false }
        for frame in 0..<frames {
            let offset = Int((position+UInt64(frame))%UInt64(capacity))*2
            let a = left[frame*channels], b = right[frame*rightStride]
            guard a.isFinite && b.isFinite else { return false }
            samples[offset] = a; samples[offset+1] = b
            if let peak { peak.pointee = max(peak.pointee,abs(a),abs(b)) }
        }
        written.store(position+UInt64(frames),ordering:.releasing)
        return true
    }
    @inline(__always) func pull(into output:UnsafeMutablePointer<Float>,frames:Int,phaseGuard:Int) {
        output.update(repeating:0,count:frames*2)
        guard enabled.load(ordering:.acquiring) else { return }
        let currentEpoch = epoch.load(ordering:.acquiring)
        if currentEpoch != readerEpoch {
            readerEpoch = currentEpoch; reader = epochStart.load(ordering:.relaxed); primed = false
            consumed.store(reader,ordering:.releasing)
            minimumQueued.store(.max,ordering:.relaxed); maximumQueued.store(0,ordering:.relaxed)
            acknowledgedEpoch.store(currentEpoch,ordering:.releasing)
        }
        let end = written.load(ordering:.acquiring)
        let available = end>=reader ? end-reader : 0
        if !primed {
            guard available>=UInt64(frames+max(phaseGuard,producerQuantum.load(ordering:.relaxed))) else { return }
            primed = true
        }
        guard available>=UInt64(frames) else {
            underruns.wrappingAdd(1,ordering:.relaxed)
            primed = false; reader = end; consumed.store(reader,ordering:.releasing); return
        }
        if available<minimumQueued.load(ordering:.relaxed) { minimumQueued.store(available,ordering:.relaxed) }
        if available>maximumQueued.load(ordering:.relaxed) { maximumQueued.store(available,ordering:.relaxed) }
        for frame in 0..<frames {
            let offset = Int((reader+UInt64(frame))%UInt64(capacity))*2
            output[frame*2] = samples[offset]; output[frame*2+1] = samples[offset+1]
        }
        reader += UInt64(frames); consumed.store(reader,ordering:.releasing)
    }
}

final class CaptureRenderContext: @unchecked Sendable {
    let slot:CaptureSlot
    let callbacks = Atomic<UInt64>(0)
    let fault = Atomic<Bool>(false)
    let disabled = Atomic<Bool>(false)
    let receivedSignal = Atomic<Bool>(false)
    let telemetry:CallbackTelemetry
    init(slot:CaptureSlot,sampleRate:Double) { self.slot = slot; telemetry = CallbackTelemetry(sampleRate:sampleRate) }
    @inline(__always) func render(_ input:UnsafePointer<AudioBufferList>,now:AudioTimeStamp,time:AudioTimeStamp) {
        guard !disabled.load(ordering:.relaxed) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
        let frames = buffers.first.map { $0.mNumberChannels>0 ? Int($0.mDataByteSize)/(4*Int($0.mNumberChannels)) : 0 } ?? 0
        telemetry.observe(now:now,output:time,frames:frames)
        var peak:Float = 0
        if !slot.push(input,peak:&peak) { fault.store(true,ordering:.relaxed) }
        else if peak>1e-7 { receivedSignal.store(true,ordering:.releasing) }
        callbacks.wrappingAdd(1,ordering:.relaxed)
    }
}

/// One immutable process membership per reader. Adding/removing a helper never
/// changes a reader containing another process, or the physical output Aggregate.
final class ProcessCapture {
    let appID:String
    let process:AudioObjectID
    let index:Int
    private var tap:AudioObjectID = 0
    private var aggregate:AudioObjectID = 0
    private var ioProc:AudioDeviceIOProcID?
    private var renderContext:CaptureRenderContext?
    private let description:CATapDescription
    private let signal:SourceSignal
    private let slot:CaptureSlot
    private let diagnostics:AudioDiagnostics
    private var activated = false
    private var stopped = false
    private var lastCallbacks:UInt64 = 0
    private var lastCallbackAt = Date()
    private var loggedGaps:UInt64 = 0
    var callbackGaps:UInt64 { renderContext?.telemetry.gaps.load(ordering:.relaxed) ?? 0 }
    init(appID:String,process:AudioObjectID,index:Int,deviceUID:String,sampleRate:Double,
         slot:CaptureSlot,signal:SourceSignal,diagnostics:AudioDiagnostics) throws {
        self.appID = appID; self.process = process; self.index = index
        self.slot = slot; self.signal = signal; self.diagnostics = diagnostics
        description = CATapDescription(stereoMixdownOfProcesses:[process])
        description.name = "Vanille source"; description.isPrivate = true
        description.deviceUID = deviceUID; description.muteBehavior = .unmuted
        do {
            try HAL.check(AudioHardwareCreateProcessTap(description,&tap),"Allow system audio processing")
            diagnostics.record("tapCreate", "slot=\(index)")
            let uid = try HAL.string(tap,kAudioTapPropertyUID)
            let composition:[String:Any] = [kAudioAggregateDeviceNameKey:"Vanille Capture",
                kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.capture.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey:true,
                kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:uid,kAudioSubTapDriftCompensationKey:true]],
                kAudioAggregateDeviceTapAutoStartKey:false]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&aggregate),"Create process capture reader")
            diagnostics.record("captureAggregateCreate", "slot=\(index)")
            let streams = try HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput)
            guard streams.count == 1 else { throw AudioFailure(operation:"Unsupported capture streams",status:kAudioDeviceUnsupportedFormatError) }
            let format = try HAL.read(streams[0],kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mChannelsPerFrame == 2, abs(format.mSampleRate-sampleRate)<1 else {
                throw AudioFailure(operation:"Capture sample rate or format is unavailable",status:kAudioDeviceUnsupportedFormatError)
            }
            let context = CaptureRenderContext(slot:slot,sampleRate:sampleRate); renderContext = context
            try HAL.check(AudioDeviceCreateIOProcID(aggregate,{ _,now,input,time,_,_,client in
                guard let client else { return noErr }
                Unmanaged<CaptureRenderContext>.fromOpaque(client).takeUnretainedValue().render(input,now:now.pointee,time:time.pointee)
                return noErr
            },Unmanaged.passUnretained(context).toOpaque(),&ioProc),"Create capture callback")
            slot.begin(); signal.ready.store(false,ordering:.releasing); signal.capturedSignal.store(false,ordering:.releasing)
            try HAL.check(AudioDeviceStart(aggregate,ioProc),"Start process capture")
            diagnostics.record("captureReaderStart", "slot=\(index)")
        } catch { stop(); throw error }
    }
    /// A capture failure restores only this process. Other readers and output keep running.
    func poll() -> Bool {
        guard !stopped, let renderContext else { return false }
        let count = renderContext.callbacks.load(ordering:.relaxed)
        if count != lastCallbacks { lastCallbacks = count; lastCallbackAt = Date() }
        let gaps = renderContext.telemetry.gaps.load(ordering:.relaxed)
        if gaps != loggedGaps {
            diagnostics.record("captureCallbackGap","slot=\(index) count=\(gaps) maxMS=\(renderContext.telemetry.maximumGapMS)")
            loggedGaps = gaps
        }
        if renderContext.fault.load(ordering:.relaxed) || Date().timeIntervalSince(lastCallbackAt)>1.5 {
            diagnostics.record("captureReaderFailure", "slot=\(index)"); stop(); return false
        }
        if !activated && renderContext.receivedSignal.load(ordering:.acquiring) && signal.capturedSignal.load(ordering:.acquiring) {
            description.muteBehavior = .mutedWhenTapped
            do {
                try HAL.write(tap,kAudioTapPropertyDescription,value:description)
                activated = true; signal.ready.store(true,ordering:.releasing)
                diagnostics.record("captureReaderConfirmed", "slot=\(index)")
            } catch { diagnostics.record("captureActivationBypass", "slot=\(index)"); stop(); return false }
        }
        return true
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        signal.ready.store(false,ordering:.releasing); signal.capturedSignal.store(false,ordering:.releasing)
        slot.enabled.store(false,ordering:.releasing)
        renderContext?.disabled.store(true,ordering:.releasing)
        var callbackDestroyed = true
        if aggregate != 0, let ioProc {
            let status = AudioDeviceStop(aggregate,ioProc)
            if status != noErr { description.muteBehavior = .unmuted; try? HAL.write(tap,kAudioTapPropertyDescription,value:description) }
            callbackDestroyed = AudioDeviceDestroyIOProcID(aggregate,ioProc) == noErr
            diagnostics.record("captureReaderStop", "slot=\(index) status=\(status)")
        }
        ioProc = nil
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status != noErr, !callbackDestroyed, let renderContext {
                slot.blocked.store(true,ordering:.releasing)
                _ = Unmanaged.passRetained(renderContext)
            }
            aggregate = 0; diagnostics.record("captureAggregateDestroy", "slot=\(index) status=\(status)")
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap); tap = 0
            diagnostics.record("tapDestroy", "slot=\(index) status=\(status)")
        }
        renderContext = nil
    }
    deinit { stop() }
}
