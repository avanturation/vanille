import Foundation
import CoreAudio
import AVFAudio
import Synchronization

struct IOTimeSnapshot {
    var callbackHost:UInt64=0
    var cycleHost:UInt64=0
    var inputHost:UInt64=0
    var outputHost:UInt64=0
    var outputSample=0.0
    var outputRateScalar=0.0
    var cycleFlags:UInt32=0
    var inputFlags:UInt32=0
    var outputFlags:UInt32=0
    var frames=0
    var sourceFrame:Int64=0
    func dictionary(frequency:Double)->[String:Any] {
        let hostValid=AudioTimeStampFlags(rawValue:outputFlags).contains(.hostTimeValid) && outputHost>0 && callbackHost>0
        var d:[String:Any]=["hostTimeValid":hostValid,"sampleTimeValid":AudioTimeStampFlags(rawValue:outputFlags).contains(.sampleTimeValid),"rateScalarValid":AudioTimeStampFlags(rawValue:outputFlags).contains(.rateScalarValid),"frames":frames,"sourceFrame":sourceFrame,"cycleFlags":cycleFlags,"inputFlags":inputFlags,"outputFlags":outputFlags]
        if outputSample.isFinite { d["outputSampleTime"]=outputSample }
        if outputRateScalar.isFinite { d["rateScalar"]=outputRateScalar }
        if hostValid {
            d["outputMinusCallbackMS"]=(Double(outputHost)-Double(callbackHost))/frequency*1000
            if AudioTimeStampFlags(rawValue:cycleFlags).contains(.hostTimeValid),cycleHost>0 { d["outputMinusCycleMS"]=(Double(outputHost)-Double(cycleHost))/frequency*1000 }
            d["outputHostSeconds"]=Double(outputHost)/frequency
        }
        if AudioTimeStampFlags(rawValue:inputFlags).contains(.hostTimeValid),inputHost>0,callbackHost>0 { d["inputAgeAtCallbackMS"]=(Double(callbackHost)-Double(inputHost))/frequency*1000 }
        return d
    }
}

/// Exactly one callback producer and one measurement-queue consumer.
final class IOTimingMailbox:@unchecked Sendable {
    private let storage=UnsafeMutablePointer<IOTimeSnapshot>.allocate(capacity:3)
    private let middle=Atomic<Int>(1)
    private var front=0,back=2
    init() { storage.initialize(repeating:IOTimeSnapshot(),count:3) }
    deinit { storage.deinitialize(count:3);storage.deallocate() }
    @inline(__always) func publish(_ value:IOTimeSnapshot) {
        storage[back]=value;back=middle.exchange(back|4,ordering:.acquiringAndReleasing)&3
    }
    func consume()->IOTimeSnapshot {
        if middle.load(ordering:.acquiring)&4 != 0 { front=middle.exchange(front,ordering:.acquiringAndReleasing)&3 }
        return storage[front]
    }
}

enum HardwareTiming {
    /// A private, non-running aggregate is used only to test property
    /// propagation. No device is selected and no audio delay is applied.
    static func latencyPropagation(_ device:OutputDevice)->[String:Any] {
        let original=DeviceManager().defaultOutput()
        var result:[String:Any]=["scope":"Private aggregate property probe; no IO or default route change"]
        // Configure separate private aggregates through the documented
        // composition key. ActiveSubDeviceList may contain physical devices;
        // it is never safe to assume those IDs are private writable wrappers.
        for extra in [0.0,device.sampleRate] {
            var aggregate:AudioObjectID=0
            let key=extra==0 ? "before" : "oneSecondConfigured"
            do {
                let composition:[String:Any]=[kAudioAggregateDeviceNameKey:"Vanille Latency Property Probe",kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.latency-probe.\(UUID().uuidString)",kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,kAudioAggregateDeviceMainSubDeviceKey:device.uid,kAudioAggregateDeviceSubDeviceListKey:[[kAudioSubDeviceUIDKey:device.uid,kAudioSubDeviceExtraOutputLatencyKey:extra]]]
                try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&aggregate),"Create private latency probe")
                // HAL configuration converges asynchronously. This is a
                // diagnostic worker, never an audio callback or the UI queue.
                Thread.sleep(forTimeInterval:0.2)
                var row:[String:Any]=["configuredExtraFrames":extra]
                row["aggregateLatencyFrames"]=try? HAL.read(aggregate,kAudioDevicePropertyLatency,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
                row["streamLatencyFrames"]=((try? HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput)) ?? []).compactMap { try? HAL.read($0,kAudioStreamPropertyLatency,default:UInt32(0)) }
                let children=(try? HAL.objects(aggregate,kAudioAggregateDevicePropertyActiveSubDeviceList)) ?? []
                row["activeClasses"]=children.compactMap { try? HAL.read($0,kAudioObjectPropertyClass,default:UInt32(0)) }
                let engine=AVAudioEngine()
                do { try engine.outputNode.auAudioUnit.setDeviceID(aggregate);row["auOutputLatencyMS"]=engine.outputNode.auAudioUnit.deviceOutputLatency*1000;row["avPresentationLatencyMS"]=engine.outputNode.presentationLatency*1000 }
                catch { row["queryError"]=error.localizedDescription }
                result[key]=row
            } catch { result[key]=["error":error.localizedDescription] }
            if aggregate != 0 { result[key+"DestroyStatus"]=AudioHardwareDestroyAggregateDevice(aggregate) }
        }
        result["defaultOutputPreserved"]=DeviceManager().defaultOutput()==original
        return result
    }
    static func describe(_ device:OutputDevice)->[String:Any] {
        let id=device.id,rate=device.sampleRate
        var d:[String:Any]=["name":device.isAirPlay ? "System AirPlay" : device.name,"airPlay":device.isAirPlay,"sampleRate":rate,"channels":device.channels]
        let hardware=try? HAL.read(id,kAudioDevicePropertyLatency,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
        let safety=try? HAL.read(id,kAudioDevicePropertySafetyOffset,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
        let buffer=try? HAL.read(id,kAudioDevicePropertyBufferFrameSize,default:UInt32(0))
        if let hardware { d["deviceLatencyFrames"]=hardware;d["deviceLatencyMS"]=Double(hardware)/rate*1000 }
        if let safety { d["safetyOffsetFrames"]=safety;d["safetyOffsetMS"]=Double(safety)/rate*1000 }
        if let buffer { d["bufferFrames"]=buffer;d["bufferMS"]=Double(buffer)/rate*1000 }
        d["latencyWritable"]=HAL.isSettable(id,kAudioDevicePropertyLatency,scope:kAudioObjectPropertyScopeOutput)
        d["streams"]=((try? HAL.objects(id,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput)) ?? []).map { stream -> [String:Any] in
            let frames=try? HAL.read(stream,kAudioStreamPropertyLatency,default:UInt32(0))
            let f=try? HAL.read(stream,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())
            let streamRate=(f?.mSampleRate ?? 0)>0 ? f!.mSampleRate : rate
            var result:[String:Any]=["sampleRate":streamRate]
            if let frames { result["latencyFrames"]=frames;result["latencyMS"]=Double(frames)/streamRate*1000 }
            return result
        }
        // These are queried, not added to the IO timestamp again. Summing a
        // scheduling lead and every reported offset can count buffering twice.
        let engine=AVAudioEngine()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(id)
            d["auDeviceOutputLatencyMS"]=engine.outputNode.auAudioUnit.deviceOutputLatency*1000
            d["avPresentationLatencyMS"]=engine.outputNode.presentationLatency*1000
            d["avOutputPresentationLatencyMS"]=engine.outputNode.outputPresentationLatency*1000
        } catch { d["presentationQueryError"]=error.localizedDescription }
        return d
    }
}

/// Adds a silent IO client to the selected physical device. It never captures
/// audio, changes the default route, or modifies device format/buffer settings.
private final class TimingProbeContext { let mailbox=IOTimingMailbox() }
final class HardwareTimingProbe {
    private let context=TimingProbeContext()
    var mailbox:IOTimingMailbox { context.mailbox }
    private var device:AudioObjectID=0
    private var io:AudioDeviceIOProcID?
    private(set) var cleanup:[String:Int32]=[:]
    func start(_ id:AudioObjectID) throws {
        stop();device=id
        do {
            try HAL.check(AudioDeviceCreateIOProcID(id,{ _,now,_,input,output,time,client in
                guard let client else { return noErr }
                let c=Unmanaged<TimingProbeContext>.fromOpaque(client).takeUnretainedValue()
                let host=AudioGetCurrentHostTime()
                for b in UnsafeMutableAudioBufferListPointer(output) { if let p=b.mData { memset(p,0,Int(b.mDataByteSize)) } }
                c.mailbox.publish(IOTimeSnapshot(callbackHost:host,cycleHost:now.pointee.mHostTime,inputHost:input.pointee.mHostTime,outputHost:time.pointee.mHostTime,outputSample:time.pointee.mSampleTime,outputRateScalar:time.pointee.mRateScalar,cycleFlags:now.pointee.mFlags.rawValue,inputFlags:input.pointee.mFlags.rawValue,outputFlags:time.pointee.mFlags.rawValue))
                return noErr
            },Unmanaged.passUnretained(context).toOpaque(),&io),"Register timing observer")
            try HAL.check(AudioDeviceStart(id,io),"Start timing observer")
        } catch { stop();throw error }
    }
    func stop() {
        if let io,device != 0 {
            cleanup["stop"]=AudioDeviceStop(device,io)
            let result=AudioDeviceDestroyIOProcID(device,io);cleanup["io"]=result
            // Keep callback storage alive if the HAL cannot detach the client.
            if result != noErr { _=Unmanaged.passRetained(context) }
        }
        io=nil;device=0
    }
    deinit { stop() }
}
