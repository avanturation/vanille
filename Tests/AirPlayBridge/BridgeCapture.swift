import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

private struct BridgeChannel { var data:UnsafeMutablePointer<Float>?;var stride=1;var frames=0 }
private final class BridgeSignal { let observed=Atomic<Bool>(false) }
private struct BridgeTap { let id:String;let object:AudioObjectID;let uid:String;let description:CATapDescription }

/// The existing tested gain/EQ implementation is reused without modifying product code.
final class BridgeRender:@unchecked Sendable {
    let history:PCMHistory
    let clock=PlaybackClock()
    let ioTiming=IOTimingMailbox()
    let mailbox=ParameterMailbox()
    let dsp:StereoDSP
    let sampleRate:Double
    let callbacks=Atomic<UInt64>(0)
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
    var hasSignal:Bool { tone || signals.contains { $0.observed.load(ordering:.acquiring) } }
    func observed(_ index:Int)->Bool { signals[index].observed.load(ordering:.acquiring) }
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
        let callbackHost=AudioGetCurrentHostTime()
        let host=outputTime.mHostTime
        let ins=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input)),outs=UnsafeMutableAudioBufferListPointer(output)
        for b in outs { if let data=b.mData { memset(data,0,Int(b.mDataByteSize)) } }
        let left=channel(0,outs),right=channel(1,outs)
        let count=min(left.frames,right.frames)
        guard count>0,count<=16_384,left.data != nil,right.data != nil else { fault.store(true,ordering:.relaxed);return }
        guard outputTime.mFlags.contains(.hostTimeValid),host>0 else {
            if localEnabled.load(ordering:.relaxed) { fault.store(true,ordering:.relaxed) }
            return
        }
        ioTiming.publish(IOTimeSnapshot(callbackHost:callbackHost,cycleHost:now.mHostTime,inputHost:inputTime.mHostTime,outputHost:host,outputSample:outputTime.mSampleTime,outputRateScalar:outputTime.mRateScalar,cycleFlags:now.mFlags.rawValue,inputFlags:inputTime.mFlags.rawValue,outputFlags:outputTime.mFlags.rawValue,frames:count,sourceFrame:frameCursor))
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
                if level>1e-7 { signals[i].observed.store(true,ordering:.releasing) }
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
        callbacks.wrappingAdd(1,ordering:.relaxed)
    }
}

/// Experiment has its own HAL resources and never changes the system default output.
final class BridgeCapture {
    private var aggregate:AudioObjectID=0
    private var io:AudioDeviceIOProcID?
    private var taps:[BridgeTap]=[]
    private(set) var context:BridgeRender?
    private(set) var replaced=false
    private(set) var appNames:[String]=[]
    private(set) var lastCleanup:[String:Int32]=[:]

    func start(device:OutputDevice,apps:[AudioApplication],settings:SavedState,tone:Bool,syncTone:Bool=false) throws {
        stop()
        guard device.channels==2,abs(device.sampleRate-48_000)<1,
              try HAL.channelCount(device.id,scope:kAudioObjectPropertyScopeInput)==0,
              apps.count<=ParameterMailbox.maxSources else { throw AudioFailure(operation:"Experiment requires a 48 kHz stereo output without physical input streams",status:kAudioDeviceUnsupportedFormatError) }
        do {
            for app in apps {
                let d=CATapDescription(stereoMixdownOfProcesses:app.processes)
                d.isPrivate=true;d.name="Vanille AirPlay experiment";d.deviceUID=device.uid;d.muteBehavior = .unmuted
                var tap:AudioObjectID=0
                try HAL.check(AudioHardwareCreateProcessTap(d,&tap),"Allow system audio for AirPlay experiment")
                do { taps.append(BridgeTap(id:app.id,object:tap,uid:try HAL.string(tap,kAudioTapPropertyUID),description:d)) }
                catch { AudioHardwareDestroyProcessTap(tap);throw error }
            }
            let composition:[String:Any]=[kAudioAggregateDeviceNameKey:"Vanille AirPlay Experiment",kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.bridge.\(UUID().uuidString)",kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,kAudioAggregateDeviceMainSubDeviceKey:device.uid,kAudioAggregateDeviceSubDeviceListKey:[[kAudioSubDeviceUIDKey:device.uid]],kAudioAggregateDeviceTapListKey:taps.map { [kAudioSubTapUIDKey:$0.uid,kAudioSubTapDriftCompensationKey:true] as [String:Any] },kAudioAggregateDeviceTapAutoStartKey:false]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&aggregate),"Create experiment clock")
            guard try HAL.channelCount(aggregate,scope:kAudioObjectPropertyScopeOutput)==2 else { throw AudioFailure(operation:"Unexpected experiment output layout",status:-1) }
            let inputStreams=try HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput)
            let order=taps.isEmpty ? [] : try HAL.strings(aggregate,kAudioAggregateDevicePropertyTapList)
            guard inputStreams.count==taps.count,order.count==taps.count,Set(order)==Set(taps.map(\.uid)) else { throw AudioFailure(operation:"Unexpected experiment input layout",status:-1) }
            taps=order.compactMap { uid in taps.first { $0.uid==uid } }
            var mappings:[Int]=[]
            for stream in inputStreams {
                let format=try HAL.read(stream,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())
                guard Self.valid(format) else { throw AudioFailure(operation:"Unsupported experiment input format",status:kAudioDeviceUnsupportedFormatError) }
                let first=try HAL.read(stream,kAudioStreamPropertyStartingChannel,default:UInt32(0))
                guard first>0 else { throw AudioFailure(operation:"Invalid tap channel",status:-1) };mappings.append(Int(first)-1)
            }
            for stream in try HAL.objects(aggregate,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput) {
                guard Self.valid(try HAL.read(stream,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())) else { throw AudioFailure(operation:"Unsupported experiment output format",status:kAudioDeviceUnsupportedFormatError) }
            }
            let c=BridgeRender(rate:48_000,mappings:mappings,tone:tone,syncTone:syncTone);context=c
            c.mailbox.publish(gains:taps.map { let v=settings.applications[$0.id] ?? AppVolume();return v.muted ? 0 : v.volume },eq:settings.eq,sampleRate:48_000)
            try HAL.check(AudioDeviceCreateIOProcID(aggregate,{ _,now,input,inputTime,output,time,client in
                guard let client else { return noErr }
                Unmanaged<BridgeRender>.fromOpaque(client).takeUnretainedValue().render(input:input,output:output,now:now.pointee,inputTime:inputTime.pointee,outputTime:time.pointee)
                return noErr
            },Unmanaged.passUnretained(c).toOpaque(),&io),"Create experiment callback")
            try HAL.check(AudioDeviceStart(aggregate,io),"Start live experiment")
            appNames=apps.map(\.name)
        } catch { stop();throw error }
    }
    private static func valid(_ f:AudioStreamBasicDescription)->Bool {
        f.mFormatID==kAudioFormatLinearPCM && f.mFormatFlags&kAudioFormatFlagIsFloat != 0 && f.mFormatFlags&kAudioFormatFlagIsBigEndian == 0 && f.mBitsPerChannel==32 && f.mChannelsPerFrame==2 && abs(f.mSampleRate-48_000)<1
    }
    func replaceOriginal(_ value:Bool) throws {
        guard let context else { return }
        if value && !context.hasSignal { throw AudioFailure(operation:"No captured audio; original output retained",status:-1) }
        do {
            for (i,tap) in taps.enumerated() {
                tap.description.muteBehavior=value && context.observed(i) ? .mutedWhenTapped : .unmuted
                try HAL.write(tap.object,kAudioTapPropertyDescription,value:tap.description)
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
        if let io,aggregate != 0 {
            lastCleanup["stop"]=AudioDeviceStop(aggregate,io)
            let result=AudioDeviceDestroyIOProcID(aggregate,io);lastCleanup["io"]=result;destroyed=result==noErr
        }
        io=nil
        if aggregate != 0 {
            let result=AudioHardwareDestroyAggregateDevice(aggregate);lastCleanup["aggregate"]=result
            if result != noErr && !destroyed,let context { context.localEnabled.store(false,ordering:.relaxed);_ = Unmanaged.passRetained(context) }
        }
        aggregate=0
        for tap in taps { lastCleanup["tap"]=AudioHardwareDestroyProcessTap(tap.object) }
        taps.removeAll();context=nil;appNames=[];replaced=false
    }
    deinit { stop() }
}
