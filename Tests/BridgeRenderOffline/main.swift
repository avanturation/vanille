import Foundation
import CoreAudio
import AudioToolbox

var failed=0,total=0
func check(_ value:Bool,_ label:String) { total += 1;print("\(value ? "PASS" : "FAIL") \(label)");if !value { failed += 1 } }
final class StereoBlock {
    let data:UnsafeMutablePointer<Float>
    let frames:Int
    var list:AudioBufferList
    init(frames:Int=128) {
        self.frames=frames;data = .allocate(capacity:frames*2);data.initialize(repeating:0,count:frames*2)
        list=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(frames*8),mData:data))
    }
    deinit { data.deinitialize(count:frames*2);data.deallocate() }
}
func timestamp(_ host:UInt64)->AudioTimeStamp { var t=AudioTimeStamp();t.mHostTime=host;t.mFlags=[.hostTimeValid,.sampleTimeValid,.rateScalarValid];t.mRateScalar=1;return t }
let input=StereoBlock(),output=StereoBlock(),host=AudioGetCurrentHostTime(),frequency=AudioGetHostClockFrequency()
for i in 0..<input.frames { input.data[i*2]=0.2;input.data[i*2+1] = -0.2 }
let c=BridgeRender(rate:48_000,mappings:[0],tone:false)
c.mailbox.publish(gains:[0.5],eq:EQSettings(enabled:false),sampleRate:48_000)
for i in 0..<128 {
    let t=timestamp(host+UInt64(Double(i*input.frames)/48_000*frequency))
    c.captureOnly(input:&input.list,now:t,inputTime:t,outputTime:AudioTimeStamp())
}
check(c.history.published.load(ordering:.acquiring)==16_384 && c.callbacks.load(ordering:.relaxed)==128 && !c.fault.load(ordering:.relaxed),"Input-only capture progresses without an output timestamp")
let sample=c.history.sample(at:8192,head:16_384)
check(abs(sample.0-0.1)<0.0001 && abs(sample.1+0.1)<0.0001,"Existing application gain changes the PCM captured by the split pipeline")
check(c.hasSignal && c.outputCallbacks.load(ordering:.relaxed)==0,"Capture and output callbacks have independent progress counters")
let idle=BridgeRender(rate:48_000,mappings:[0],tone:false)
var empty=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:0,mData:nil))
idle.captureOnly(input:&empty,now:timestamp(host),inputTime:timestamp(host),outputTime:AudioTimeStamp())
check(!idle.fault.load(ordering:.relaxed) && idle.history.published.load(ordering:.acquiring)==0,"A legitimate idle input with no sample memory is not a fatal format change")
idle.captureOnly(input:&input.list,now:timestamp(host),inputTime:timestamp(host),outputTime:AudioTimeStamp())
idle.resetSignal(0)
let cleared = !idle.hasSignal && !idle.recentlyAudible(0)
for _ in 0..<40 { idle.captureOnly(input:&input.list,now:timestamp(host),inputTime:timestamp(host),outputTime:AudioTimeStamp()) }
check(cleared && idle.hasSignal && idle.recentlyAudible(0),"A reassigned tap discards its old signal latch and requires fresh input before muting")
let t=timestamp(host)
for i in 0..<output.frames*2 { output.data[i]=0.8 }
c.renderOutput(output:&output.list,now:t,outputTime:t)
check((0..<output.frames*2).allSatisfy { output.data[$0]==0 },"An output without an enabled playback clock is silent")
c.localEnabled.store(true,ordering:.releasing);c.clock.publish(PlaybackAnchor(frame:4096,host:host,valid:true))
for i in 0..<8 {
    let t=timestamp(host+UInt64(Double(i*output.frames)/48_000*frequency))
    c.renderOutput(output:&output.list,now:t,outputTime:t)
}
check(abs(output.data[output.frames*2-2]-0.1)<0.0001 && abs(output.data[output.frames*2-1]+0.1)<0.0001,"Independent MR4 rendering reads the actual processed history after its gain ramp")
let invalid=BridgeRender(rate:48_000,mappings:[2],tone:false)
invalid.captureOnly(input:&input.list,now:t,inputTime:t,outputTime:AudioTimeStamp())
check(invalid.fault.load(ordering:.relaxed) && invalid.history.published.load(ordering:.acquiring)==0,"A missing input channel fails before accessing sample memory")
let nonfinite=BridgeRender(rate:48_000,mappings:[0],tone:false)
input.data[0] = .nan
nonfinite.captureOnly(input:&input.list,now:t,inputTime:t,outputTime:AudioTimeStamp())
check(nonfinite.fault.load(ordering:.relaxed) && nonfinite.history.sample(at:0,head:128).0.isFinite,"Non-finite source samples cannot propagate into output history")
input.data[0]=0.2
let concurrent=BridgeRender(rate:48_000,mappings:[0],tone:false)
for _ in 0..<128 { concurrent.captureOnly(input:&input.list,now:t,inputTime:t,outputTime:AudioTimeStamp()) }
concurrent.localEnabled.store(true,ordering:.releasing);concurrent.clock.publish(PlaybackAnchor(frame:4096,host:host,valid:true))
let group=DispatchGroup();group.enter()
DispatchQueue.global(qos:.userInitiated).async {
    for _ in 0..<200 { concurrent.captureOnly(input:&input.list,now:t,inputTime:t,outputTime:AudioTimeStamp()) }
    group.leave()
}
var bounded=true
for i in 0..<200 {
    let at=timestamp(host+UInt64(Double(i*output.frames)/48_000*frequency))
    concurrent.renderOutput(output:&output.list,now:at,outputTime:at)
    bounded = bounded && (0..<output.frames*2).allSatisfy { output.data[$0].isFinite && abs(output.data[$0])<=0.201 }
}
group.wait()
check(bounded && !concurrent.fault.load(ordering:.relaxed) && concurrent.callbacks.load(ordering:.relaxed)==328 && concurrent.outputCallbacks.load(ordering:.relaxed)==200,"Concurrent capture and MR4 callbacks keep separate mutable state and bounded output")
print("\(total-failed)/\(total) split-render checks passed; no HAL device was opened")
exit(failed==0 ? 0 : 1)
