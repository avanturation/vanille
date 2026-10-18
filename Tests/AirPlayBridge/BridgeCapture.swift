import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

private struct BridgeChannel { var data:UnsafeMutablePointer<Float>?;var stride=1;var frames=0 }
private final class BridgeSignal { let observed=Atomic<Bool>(false);let afterFrame=Atomic<Int64>(0);let lastFrame=Atomic<Int64>(-1) }
private struct BridgeTap { var id:String?;let object:AudioObjectID;let uid:String;let description:CATapDescription }

/// The existing tested gain/EQ implementation is reused without modifying product code.
final class BridgeRender:@unchecked Sendable {
    let history:PCMHistory
    let clock=PlaybackClock()
    let ioTiming=IOTimingMailbox()
    let outputIOTiming=IOTimingMailbox()
    let mailbox=ParameterMailbox()
    let dsp:StereoDSP
    let sampleRate:Double
    let callbacks=Atomic<UInt64>(0)
    let outputCallbacks=Atomic<UInt64>(0)
    let fault=Atomic<Bool>(false)
    let inputPeak=Atomic<Double>(0)
    let localOutputRMS=Atomic<Double>(0)
    let localFrameError=Atomic<Double>(0)
    let localEnabled=Atomic<Bool>(false)
    let localGain=Atomic<Double>(1)
    private let mappings:[Int]
    private let signals:[BridgeSignal]
    private let pointers:UnsafeMutablePointer<BridgeChannel>
    private let tone:Bool
    private let syncTone:Bool
    private let hostFrequency=AudioGetHostClockFrequency()
    private var frameCursor:Int64=0
    private var localPosition:Double = -1
    private var previousPosition:Double=0
    private var fadeRemaining=0
    private var gain=0.0

    init(rate:Double,mappings:[Int],tone:Bool,syncTone:Bool=false) {
        sampleRate=rate;self.mappings=mappings;self.tone=tone;self.syncTone=syncTone
        _=SyncCue.starts // Initialize the immutable cue schedule before realtime IO.
        signals=mappings.map { _ in BridgeSignal() }
        history=PCMHistory(sampleRate:rate)
        dsp=StereoDSP(sampleRate:rate,mailbox:mailbox)
        pointers = .allocate(capacity:max(2,mappings.count*2));pointers.initialize(repeating:BridgeChannel(),count:max(2,mappings.count*2))
    }
    deinit { pointers.deinitialize(count:max(2,mappings.count*2));pointers.deallocate() }
    var hasSignal:Bool { tone || signals.indices.contains { observed($0) } }
    func observed(_ index:Int)->Bool { signals[index].observed.load(ordering:.acquiring) && signals[index].lastFrame.load(ordering:.acquiring)>=signals[index].afterFrame.load(ordering:.acquiring) }
    func resetSignal(_ index:Int) {
        signals[index].afterFrame.store(history.published.load(ordering:.acquiring)+Int64(sampleRate*0.1),ordering:.releasing)
        signals[index].observed.store(false,ordering:.releasing)
        signals[index].lastFrame.store(-1,ordering:.releasing)
    }
    func recentlyAudible(_ index:Int)->Bool {
        let last=signals[index].lastFrame.load(ordering:.acquiring)
        return last>=signals[index].afterFrame.load(ordering:.acquiring) && history.published.load(ordering:.acquiring)-last<Int64(sampleRate*5)
    }
    @inline(__always) private func channel(_ index:Int,_ buffers:UnsafeMutableAudioBufferListPointer)->BridgeChannel {
        var offset=0
        for b in buffers {
            let channels=Int(b.mNumberChannels)
            if index<offset+channels,channels>0,let data=b.mData {
                return BridgeChannel(data:data.assumingMemoryBound(to:Float.self).advanced(by:index-offset),stride:channels,frames:Int(b.mDataByteSize)/(4*channels))
            }
            offset += channels
        }
        return BridgeChannel()
    }
    @inline(__always) func render(input:UnsafePointer<AudioBufferList>,output:UnsafeMutablePointer<AudioBufferList>,now:AudioTimeStamp,inputTime:AudioTimeStamp,outputTime:AudioTimeStamp) {
        let ins=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input)),outs=UnsafeMutableAudioBufferListPointer(output)
        let left=channel(0,outs),right=channel(1,outs)
        let count=min(left.frames,right.frames)
        guard count>0,count<=16_384,left.data != nil,right.data != nil else { fault.store(true,ordering:.relaxed);return }
        captureInput(ins,count:count,now:now,inputTime:inputTime,outputTime:outputTime)
        renderOutput(output:output,now:now,outputTime:outputTime)
    }
    @inline(__always) func captureOnly(input:UnsafePointer<AudioBufferList>,now:AudioTimeStamp,inputTime:AudioTimeStamp,outputTime:AudioTimeStamp) {
        let ins=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
        guard let first=mappings.first else { fault.store(true,ordering:.relaxed);return }
        let count=channel(first,ins).frames
        if count==0,ins.allSatisfy({ $0.mData==nil || $0.mDataByteSize==0 }) { return }
        guard count>0,count<=16_384 else { fault.store(true,ordering:.relaxed);return }
        captureInput(ins,count:count,now:now,inputTime:inputTime,outputTime:outputTime)
    }
    @inline(__always) private func captureInput(_ ins:UnsafeMutableAudioBufferListPointer,count:Int,now:AudioTimeStamp,inputTime:AudioTimeStamp,outputTime:AudioTimeStamp) {
        ioTiming.publish(IOTimeSnapshot(callbackHost:AudioGetCurrentHostTime(),cycleHost:now.mHostTime,inputHost:inputTime.mHostTime,outputHost:outputTime.mHostTime,outputSample:outputTime.mSampleTime,outputRateScalar:outputTime.mRateScalar,cycleFlags:now.mFlags.rawValue,inputFlags:inputTime.mFlags.rawValue,outputFlags:outputTime.mFlags.rawValue,frames:count,sourceFrame:frameCursor))
        for i in mappings.indices {
            pointers[i*2]=channel(mappings[i],ins);pointers[i*2+1]=channel(mappings[i]+1,ins)
            guard pointers[i*2].frames>=count,pointers[i*2+1].frames>=count else { fault.store(true,ordering:.relaxed);return }
        }
        let p=mailbox.consume()
        var peak=0.0
        for frame in 0..<count {
            var l=0.0,r=0.0
            for i in mappings.indices {
                let a=pointers[i*2],b=pointers[i*2+1]
                let x=Double(a.data![frame*a.stride]),y=Double(b.data![frame*b.stride])
                guard x.isFinite,y.isFinite else { fault.store(true,ordering:.relaxed);continue }
                let level=max(abs(x),abs(y));peak=max(peak,level)
                if level>1e-7,frameCursor>=signals[i].afterFrame.load(ordering:.acquiring) { signals[i].observed.store(true,ordering:.releasing);signals[i].lastFrame.store(frameCursor,ordering:.releasing) }
                let g=dsp.gain(source:i,parameters:p);l += x*g;r += y*g
            }
            if tone {
                let position=frameCursor%Int64(sampleRate*2)
                let envelope=position<Int64(sampleRate*0.1) ? min(1,Double(position)/240)*min(1,(sampleRate*0.1-Double(position))/240) : 0
                let pulse=syncTone ? SyncCue.sample(frameCursor,rate:sampleRate) : 0.02*envelope*sin(2*Double.pi*880*Double(frameCursor)/sampleRate)
                l += pulse;r += pulse
            }
            let sample=dsp.process(left:l,right:r,parameters:p)
            history.push(Float(sample.0),Float(sample.1));frameCursor += 1
        }
        history.commit();inputPeak.store(peak,ordering:.relaxed)
        callbacks.wrappingAdd(1,ordering:.relaxed)
    }
    // In virtual-output mode this is a separate consumer. Only captureInput mutates DSP
    // state and only this callback mutates resampling/gain state. PCMHistory publishes atomically.
    @inline(__always) func renderOutput(output:UnsafeMutablePointer<AudioBufferList>,now:AudioTimeStamp,outputTime:AudioTimeStamp) {
        let outs=UnsafeMutableAudioBufferListPointer(output)
        for b in outs { if let data=b.mData { memset(data,0,Int(b.mDataByteSize)) } }
        let left=channel(0,outs),right=channel(1,outs),host=outputTime.mHostTime
        let count=min(left.frames,right.frames)
        guard count>0,count<=16_384,left.data != nil,right.data != nil else { fault.store(true,ordering:.relaxed);return }
        guard outputTime.mFlags.contains(.hostTimeValid),host>0 else {
            if localEnabled.load(ordering:.relaxed) { fault.store(true,ordering:.relaxed) }
            return
        }
        outputIOTiming.publish(IOTimeSnapshot(callbackHost:AudioGetCurrentHostTime(),cycleHost:now.mHostTime,outputHost:host,outputSample:outputTime.mSampleTime,outputRateScalar:outputTime.mRateScalar,cycleFlags:now.mFlags.rawValue,outputFlags:outputTime.mFlags.rawValue,frames:count,sourceFrame:history.published.load(ordering:.acquiring)))
        let anchor=clock.consume()
        let enabled=localEnabled.load(ordering:.acquiring) && anchor.valid
        let targetGain=enabled ? min(1,max(0,localGain.load(ordering:.relaxed))) : 0
        let target=anchor.frame+(Double(host)-Double(anchor.host))*sampleRate/hostFrequency
        if enabled && target.isFinite {
            if localPosition<0 { localPosition=target }
            if abs(target-localPosition)>sampleRate*0.03 {
                previousPosition=localPosition;localPosition=target;fadeRemaining=Int(sampleRate*0.03)
            }
        }
        let correction=enabled ? min(0.005,max(-0.005,(target-localPosition)/(sampleRate*0.5))) : 0
        let head=history.published.load(ordering:.acquiring),fadeFrames=max(1,Int(sampleRate*0.03))
        localFrameError.store(enabled ? target-localPosition : 0,ordering:.relaxed)
        var localEnergy=0.0
        for frame in 0..<count {
            gain += min(1/(sampleRate*0.01),max(-1/(sampleRate*0.01),targetGain-gain))
            if gain>0,localPosition>=0 {
                var sample=history.sample(at:localPosition,head:head)
                if fadeRemaining>0 {
                    let old=history.sample(at:previousPosition,head:head),mix=Float(fadeRemaining)/Float(fadeFrames)
                    sample=(sample.0*(1-mix)+old.0*mix,sample.1*(1-mix)+old.1*mix)
                    previousPosition += 1;fadeRemaining -= 1
                }
                left.data![frame*left.stride]=sample.0*Float(gain);right.data![frame*right.stride]=sample.1*Float(gain)
                localEnergy += Double(sample.0*sample.0+sample.1*sample.1)*gain*gain*0.5
                localPosition += 1+correction
            }
        }
        if !enabled && gain<=0 { localPosition = -1 }
        localOutputRMS.store(sqrt(localEnergy/Double(count)),ordering:.relaxed)
        outputCallbacks.wrappingAdd(1,ordering:.relaxed)
    }
}

/// Owns private capture resources. An optional separately owned output avoids
/// opening the same physical subdevice in two aggregates.
final class BridgeCapture {
    private var aggregate:AudioObjectID=0
    private var io:AudioDeviceIOProcID?
    private var outputDevice:AudioObjectID=0
    private var outputIO:AudioDeviceIOProcID?
    private var sourceProcesses=[String:[AudioObjectID]]()
    private var taps:[BridgeTap]=[]
    private(set) var context:BridgeRender?
    private(set) var replaced=false
    private(set) var appNames:[String]=[]
    private(set) var lastCleanup:[String:Int32]=[:]

    func start(device:OutputDevice,apps:[AudioApplication],settings:SavedState,tone:Bool,syncTone:Bool=false,captureDeviceUID:String?=nil,separateOutput:AudioObjectID?=nil,progress:((String)->Void)?=nil) throws {
        stop()
        outputDevice=separateOutput ?? 0
        guard apps.count<=ParameterMailbox.maxSources else { throw AudioFailure(operation:"Too many audio applications (\(apps.count)); original output retained",status:-1) }
        guard device.channels==2,abs(device.sampleRate-48_000)<1,
              try HAL.channelCount(device.id,scope:kAudioObjectPropertyScopeInput)==0 else { throw AudioFailure(operation:"Experiment requires a 48 kHz stereo output without physical input streams",status:kAudioDeviceUnsupportedFormatError) }
        do {
            let capacity=separateOutput == nil ? apps.count : min(ParameterMailbox.maxSources,max(8,apps.count+4))
            for index in 0..<capacity {
                let app=index<apps.count ? apps[index] : nil
                progress?("Creating private capture tap")
                let d=CATapDescription(stereoMixdownOfProcesses:app?.processes ?? [])
                d.isPrivate=true;d.isExclusive=false;d.name="Vanille AirPlay experiment";d.deviceUID=captureDeviceUID ?? device.uid;d.muteBehavior = .unmuted
                var tap:AudioObjectID=0
                try HAL.check(AudioHardwareCreateProcessTap(d,&tap),"Allow system audio for AirPlay experiment")
                do { taps.append(BridgeTap(id:app?.id,object:tap,uid:try HAL.string(tap,kAudioTapPropertyUID),description:d)) }
                catch { AudioHardwareDestroyProcessTap(tap);throw error }
            }
            var composition:[String:Any]=[kAudioAggregateDeviceNameKey:"Vanille AirPlay Experiment",kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.bridge.\(UUID().uuidString)",kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,kAudioAggregateDeviceTapListKey:taps.map { [kAudioSubTapUIDKey:$0.uid,kAudioSubTapDriftCompensationKey:true] as [String:Any] },kAudioAggregateDeviceTapAutoStartKey:false]
            if separateOutput == nil {
                composition[kAudioAggregateDeviceMainSubDeviceKey]=device.uid
                composition[kAudioAggregateDeviceSubDeviceListKey]=[[kAudioSubDeviceUIDKey:device.uid]]
            }
            progress?("Creating private capture aggregate")
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&aggregate),"Create experiment clock")
            let outputChannels=try HAL.channelCount(aggregate,scope:kAudioObjectPropertyScopeOutput)
            guard outputChannels == (separateOutput == nil ? 2 : 0) else { throw AudioFailure(operation:"Unexpected experiment output layout: \(outputChannels) channels",status:-1) }
            let inputStreams=try HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput)
            let order=taps.isEmpty ? [] : try HAL.strings(aggregate,kAudioAggregateDevicePropertyTapList)
            guard inputStreams.count==taps.count,order.count==taps.count,Set(order)==Set(taps.map(\.uid)) else { throw AudioFailure(operation:"Unexpected experiment input layout: \(inputStreams.count) streams, \(order.count) listed taps, \(taps.count) requested",status:-1) }
            taps=order.compactMap { uid in taps.first { $0.uid==uid } }
            var mappings:[Int]=[]
            for stream in inputStreams {
                let format=try HAL.read(stream,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())
                guard Self.valid(format) else { throw AudioFailure(operation:"Unsupported experiment input format",status:kAudioDeviceUnsupportedFormatError) }
                let first=try HAL.read(stream,kAudioStreamPropertyStartingChannel,default:UInt32(0))
                guard first>0 else { throw AudioFailure(operation:"Invalid tap channel",status:-1) };mappings.append(Int(first)-1)
            }
            let renderDevice=separateOutput ?? aggregate
            guard try HAL.channelCount(renderDevice,scope:kAudioObjectPropertyScopeOutput)==2 else { throw AudioFailure(operation:"Render output is not stereo",status:-1) }
            for stream in try HAL.objects(renderDevice,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput) {
                guard Self.valid(try HAL.read(stream,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())) else { throw AudioFailure(operation:"Unsupported experiment output format",status:kAudioDeviceUnsupportedFormatError) }
            }
            let c=BridgeRender(rate:48_000,mappings:mappings,tone:tone,syncTone:syncTone);context=c
            publish(settings)
            progress?("Registering capture callback")
            if separateOutput != nil {
                try HAL.check(AudioDeviceCreateIOProcID(aggregate,{ _,now,input,inputTime,_,time,client in
                    guard let client else { return noErr }
                    Unmanaged<BridgeRender>.fromOpaque(client).takeUnretainedValue().captureOnly(input:input,now:now.pointee,inputTime:inputTime.pointee,outputTime:time.pointee)
                    return noErr
                },Unmanaged.passUnretained(c).toOpaque(),&io),"Create capture-only callback")
                try HAL.check(AudioDeviceCreateIOProcID(outputDevice,{ _,now,_,_,output,time,client in
                    guard let client else { return noErr }
                    Unmanaged<BridgeRender>.fromOpaque(client).takeUnretainedValue().renderOutput(output:output,now:now.pointee,outputTime:time.pointee)
                    return noErr
                },Unmanaged.passUnretained(c).toOpaque(),&outputIO),"Create independent output callback")
                progress?("Starting independent output callback")
                try HAL.check(AudioDeviceStart(outputDevice,outputIO),"Start independent output")
            } else {
                try HAL.check(AudioDeviceCreateIOProcID(aggregate,{ _,now,input,inputTime,output,time,client in
                    guard let client else { return noErr }
                    Unmanaged<BridgeRender>.fromOpaque(client).takeUnretainedValue().render(input:input,output:output,now:now.pointee,inputTime:inputTime.pointee,outputTime:time.pointee)
                    return noErr
                },Unmanaged.passUnretained(c).toOpaque(),&io),"Create experiment callback")
            }
            progress?("Starting capture callback")
            try HAL.check(AudioDeviceStart(aggregate,io),"Start live experiment")
            progress?("Capture and output callbacks started")
            appNames=apps.map(\.name)
            sourceProcesses=Dictionary(uniqueKeysWithValues:apps.map { ($0.id,$0.processes) })
        } catch { stop();throw error }
    }
    private func publish(_ settings:SavedState) {
        context?.mailbox.publish(gains:taps.map { tap in
            guard let id=tap.id else { return Float(0) }
            let v=settings.applications[id] ?? AppVolume();return v.muted || v.bypass ? 0 : v.volume
        },eq:settings.eq,sampleRate:48_000)
    }
    /// Process-list edits preserve the aggregate layout, PCM timeline and AAC writer.
    /// All calls are on the capture lifecycle queue, never an IO callback.
    func reconcile(apps:[AudioApplication],settings:SavedState) throws {
        guard let context else { return }
        let desired=Dictionary(uniqueKeysWithValues:apps.map { ($0.id,$0) })
        for index in taps.indices {
            let id=taps[index].id
            guard let id,desired[id]==nil else { continue }
            taps[index].description.muteBehavior = .unmuted;taps[index].description.processes=[]
            context.resetSignal(index)
            try HAL.write(taps[index].object,kAudioTapPropertyDescription,value:taps[index].description)
            taps[index].id=nil;sourceProcesses.removeValue(forKey:id)
        }
        for app in apps {
            let slot=taps.firstIndex { $0.id==app.id } ?? taps.firstIndex { $0.id==nil }
            guard let slot else { throw AudioFailure(operation:"Too many audio applications; original output restored",status:-1) }
            if taps[slot].id != app.id || Set(sourceProcesses[app.id] ?? []) != Set(app.processes) {
                taps[slot].description.muteBehavior = .unmuted;taps[slot].description.processes=app.processes
                context.resetSignal(slot)
                try HAL.write(taps[slot].object,kAudioTapPropertyDescription,value:taps[slot].description)
                taps[slot].id=app.id;sourceProcesses[app.id]=app.processes
            }
        }
        appNames=apps.map(\.name);publish(settings)
    }
    var recentlyAudibleAppIDs:Set<String> {
        guard let context else { return [] }
        return Set(taps.indices.compactMap { context.recentlyAudible($0) ? taps[$0].id : nil })
    }
    private static func valid(_ f:AudioStreamBasicDescription)->Bool {
        f.mFormatID==kAudioFormatLinearPCM && f.mFormatFlags&kAudioFormatFlagIsFloat != 0 && f.mFormatFlags&kAudioFormatFlagIsBigEndian == 0 && f.mBitsPerChannel==32 && f.mChannelsPerFrame==2 && abs(f.mSampleRate-48_000)<1
    }
    func replaceOriginal(_ value:Bool) throws {
        guard let context else { return }
        if value && !context.hasSignal { throw AudioFailure(operation:"No captured audio; original output retained",status:-1) }
        do {
            for (i,tap) in taps.enumerated() {
                let behavior:CATapMuteBehavior=value && tap.id != nil && context.observed(i) ? .mutedWhenTapped : .unmuted
                if tap.description.muteBehavior != behavior {
                    tap.description.muteBehavior=behavior
                    try HAL.write(tap.object,kAudioTapPropertyDescription,value:tap.description)
                }
            }
            replaced=value;context.localEnabled.store(value,ordering:.releasing)
        } catch {
            for tap in taps { tap.description.muteBehavior = .unmuted;try? HAL.write(tap.object,kAudioTapPropertyDescription,value:tap.description) }
            replaced=false;context.localEnabled.store(false,ordering:.releasing);throw error
        }
    }
    func stop() {
        try? replaceOriginal(false)
        var destroyed=true
        if let outputIO,outputDevice != 0 {
            lastCleanup["outputStop"]=AudioDeviceStop(outputDevice,outputIO)
            let result=AudioDeviceDestroyIOProcID(outputDevice,outputIO);lastCleanup["outputIO"]=result;destroyed=result==noErr
        }
        outputIO=nil;outputDevice=0
        if let io,aggregate != 0 {
            lastCleanup["stop"]=AudioDeviceStop(aggregate,io)
            let result=AudioDeviceDestroyIOProcID(aggregate,io);lastCleanup["io"]=result;destroyed = destroyed && result==noErr
        }
        io=nil
        if aggregate != 0 {
            let result=AudioHardwareDestroyAggregateDevice(aggregate);lastCleanup["aggregate"]=result
        }
        if !destroyed,let context { context.localEnabled.store(false,ordering:.relaxed);_ = Unmanaged.passRetained(context) }
        aggregate=0
        for tap in taps { lastCleanup["tap"]=AudioHardwareDestroyProcessTap(tap.object) }
        taps.removeAll();context=nil;appNames=[];replaced=false
        sourceProcesses.removeAll()
    }
    deinit { stop() }
}
