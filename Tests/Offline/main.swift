import Foundation
import Synchronization
import CoreAudio

var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { print("FAIL: \(name)"); exit(1) }
    passed += 1; print("PASS: \(name)")
}
func rmsTest(frequency: Double = 1000, sourceGain: Float = 1, eq: EQSettings = EQSettings(), sampleRate: Double = 48_000) -> Double {
    let mailbox = ParameterMailbox()
    let dsp = StereoDSP(sampleRate:sampleRate,mailbox:mailbox)
    mailbox.publish(gains:[sourceGain],eq:eq,sampleRate:sampleRate)
    let p = mailbox.consume()
    var energy = 0.0
    let count = Int(sampleRate)
    for i in 0..<(count*2) {
        let input = 0.02*sin(2*Double.pi*frequency*Double(i)/sampleRate)
        let gain = dsp.gain(source:0,parameters:p)
        let result = dsp.process(left:input*gain,right:input*gain,parameters:p)
        if i >= count { energy += result.0*result.0 }
    }
    return sqrt(energy/Double(count)) / (0.02/sqrt(2))
}
check(abs(rmsTest()-1) < 0.00001,"EQ bypass is unity")
check(abs(rmsTest(sourceGain:0.7)-0.7) < 0.00001,"70% gain changes actual PCM amplitude")
check(rmsTest(sourceGain:0) < 1e-9,"Mute produces zero PCM after gain ramp")
var eq = EQSettings(enabled:true)
eq.autoHeadroom = false; eq.gains[5] = 6
check(abs(20*log10(rmsTest(eq:eq))-6) < 0.02,"1 kHz +6 dB peaking filter")
check(abs(20*log10(rmsTest(sourceGain:0.5,eq:eq))-(6-6.0206)) < 0.02,"App gain and EQ work in the same DSP pipeline")
eq.enabled = false
check(abs(rmsTest(eq:eq)-1) < 0.00001,"Disabling EQ restores dry signal")
for rate in [44_100.0,48_000,96_000] {
    for (index,frequency) in EQSettings.frequencies.enumerated() {
        var setting = EQSettings(enabled:true); setting.autoHeadroom = false; setting.gains[index] = -12
        check(abs(20*log10(rmsTest(frequency:frequency,eq:setting,sampleRate:rate))+12) < 0.08,"\(Int(rate)) Hz / \(Int(frequency)) Hz cut")
    }
}
var boost = EQSettings(enabled:true); boost.gains = Array(repeating:12,count:10)
let mailbox = ParameterMailbox(); let dsp = StereoDSP(sampleRate:48_000,mailbox:mailbox)
mailbox.publish(gains:[1],eq:boost,sampleRate:48_000)
let p = mailbox.consume()
var peak = 0.0
for i in 0..<192_000 {
    let x = 0.95*sin(2*Double.pi*125*Double(i)/48_000)
    let y = dsp.process(left:x,right:-x,parameters:p)
    peak = max(peak,abs(y.0),abs(y.1))
}
check(peak <= 0.980001,"Boosted EQ has headroom and bounded output")
let rampMailbox = ParameterMailbox(); let rampDSP = StereoDSP(sampleRate:48_000,mailbox:rampMailbox)
rampMailbox.publish(gains:[0],eq:EQSettings(),sampleRate:48_000)
let rampP = rampMailbox.consume(); var previous = 1.0; var maxDelta = 0.0
for _ in 0..<480 { let value = rampDSP.gain(source:0,parameters:rampP); maxDelta = max(maxDelta,abs(previous-value)); previous = value }
check(maxDelta <= 1.0/480+1e-10 && previous < 1e-9,"Gain transitions use a 10 ms ramp")

// Same callback used by the live engine: two stereo apps, one interleaved and one planar.
let context = RenderContext(sampleRate:48_000,routes:[RenderRoute(left:0,right:1),RenderRoute(left:2,right:3)])
context.mailbox.publish(gains:[0.5,0.25],eq:EQSettings(),sampleRate:48_000)
let frames = 512
let inList = AudioBufferList.allocate(maximumBuffers:3)
let outList = AudioBufferList.allocate(maximumBuffers:2)
let a = UnsafeMutablePointer<Float>.allocate(capacity:frames*2); a.initialize(repeating:0.1,count:frames*2)
let b = UnsafeMutablePointer<Float>.allocate(capacity:frames); b.initialize(repeating:0.2,count:frames)
let c = UnsafeMutablePointer<Float>.allocate(capacity:frames); c.initialize(repeating:-0.2,count:frames)
let l = UnsafeMutablePointer<Float>.allocate(capacity:frames); l.initialize(repeating:0,count:frames)
let r = UnsafeMutablePointer<Float>.allocate(capacity:frames); r.initialize(repeating:0,count:frames)
inList[0] = AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(frames*8),mData:a)
inList[1] = AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(frames*4),mData:b)
inList[2] = AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(frames*4),mData:c)
outList[0] = AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(frames*4),mData:l)
outList[1] = AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(frames*4),mData:r)
for _ in 0..<4 { context.render(input:UnsafePointer(inList.unsafeMutablePointer),output:outList.unsafeMutablePointer) }
check(abs(l[frames-1]-0.1)<1e-5 && abs(r[frames-1])<1e-5,"HAL callback mixes per-app interleaved and planar PCM correctly")
check(!context.fault.load(ordering:.relaxed),"Valid buffers produce no realtime fault")
// Oversize or invalid buffers are rejected before writing beyond memory.
inList[0].mDataByteSize = 4
context.render(input:UnsafePointer(inList.unsafeMutablePointer),output:outList.unsafeMutablePointer)
check(context.fault.load(ordering:.relaxed) && l[0] == 0,"Truncated buffers fail safely with zero output")
inList[0].mDataByteSize = UInt32(frames*8)
let confirming = RenderContext(sampleRate:48_000,routes:[RenderRoute(left:0,right:1),RenderRoute(left:2,right:3)],initiallyReady:false)
confirming.render(input:UnsafePointer(inList.unsafeMutablePointer),output:outList.unsafeMutablePointer)
check(l[frames-1] == 0 && r[frames-1] == 0 && confirming.signals[0].peak.load(ordering:.relaxed)>0,"Unconfirmed capture never replaces original output")
inList[0].mDataByteSize = UInt32(frames*8)
for i in 0..<(frames*2) { a[i] = 0 }
confirming.render(input:UnsafePointer(inList.unsafeMutablePointer),output:outList.unsafeMutablePointer)
check(confirming.signals[0].capturedSignal.load(ordering:.acquiring),"Short captured sounds stay latched across later silent callbacks")
for i in 0..<(frames*2) { a[i] = 0.1 }
confirming.signals[0].ready.store(true,ordering:.releasing)
confirming.render(input:UnsafePointer(inList.unsafeMutablePointer),output:outList.unsafeMutablePointer)
check(abs(l[frames-1]-0.1)<1e-5 && abs(r[frames-1]-0.1)<1e-5,"Only confirmed sources enter the output mix")
a.deallocate(); b.deallocate(); c.deallocate(); l.deallocate(); r.deallocate(); inList.unsafeMutablePointer.deallocate(); outList.unsafeMutablePointer.deallocate()

// Exercise the production output ring with independent hardware-stream parameters.
let routeMailbox = ParameterMailbox()
var outputRoutes = [DeviceRoute(id:"wired",name:"Wired"),DeviceRoute(id:"wireless",name:"Wireless")]
outputRoutes[1].volume = 0.35; outputRoutes[1].delayMS = 120
routeMailbox.publish(gains:[1],eq:EQSettings(),sampleRate:48_000,outputs:outputRoutes)
let routeP = routeMailbox.consume()
let mixer = OutputMixer(sampleRate:48_000,destinations:2)
mixer.beginBlock(routeP)
// Settle gain and read-head crossfades before an impulse.
for _ in 0..<10_000 { mixer.push(left:0,right:0); _ = mixer.read(destination:0,parameters:routeP); _ = mixer.read(destination:1,parameters:routeP); mixer.advance() }
var impulseFrames = [-1,-1], impulsePeaks = [0.0,0.0], rightPeaks = [0.0,0.0]
for frame in 0..<7_000 {
    mixer.push(left:frame == 0 ? 0.2 : 0,right:frame == 0 ? -0.1 : 0)
    for destination in 0..<2 {
        let signal = mixer.read(destination:destination,parameters:routeP)
        if abs(signal.0)>impulsePeaks[destination] { impulsePeaks[destination] = abs(signal.0); impulseFrames[destination] = frame; rightPeaks[destination] = signal.1 }
    }
    mixer.advance()
}
check(impulseFrames == [0,5_760],"Per-device 120 ms offset delays actual PCM by exactly 5760 frames")
check(abs(impulsePeaks[0]-0.2)<1e-9 && abs(impulsePeaks[1]-0.07)<1e-8,"Independent output volumes change only their own PCM stream")
check(abs(rightPeaks[0]+0.1)<1e-9 && abs(rightPeaks[1]+0.035)<1e-8,"Per-output delay preserves stereo channel polarity and level")
outputRoutes[1].muted = true
routeMailbox.publish(gains:[1],eq:EQSettings(),sampleRate:48_000,outputs:outputRoutes)
let mutedP = routeMailbox.consume(); mixer.beginBlock(mutedP)
var mutedPeak = 0.0, wiredPeak = 0.0
for frame in 0..<7_000 {
    mixer.push(left:0.1,right:0.1)
    let wired = mixer.read(destination:0,parameters:mutedP), wireless = mixer.read(destination:1,parameters:mutedP)
    if frame>6_000 { mutedPeak = max(mutedPeak,abs(wireless.0)); wiredPeak = max(wiredPeak,abs(wired.0)) }
    mixer.advance()
}
check(mutedPeak == 0 && abs(wiredPeak-0.1)<1e-9,"Muting one output leaves another output playing")
// A changed delay blends two fixed read heads rather than jumping samples.
outputRoutes[0].delayMS = 3_000
routeMailbox.publish(gains:[1],eq:EQSettings(),sampleRate:48_000,outputs:outputRoutes)
let delayedP = routeMailbox.consume(); mixer.beginBlock(delayedP)
var last = 0.1, delta = 0.0
for _ in 0..<1_500 { mixer.push(left:0.1,right:0.1); let signal = mixer.read(destination:0,parameters:delayedP); _ = mixer.read(destination:1,parameters:delayedP); delta = max(delta,abs(signal.0-last)); last = signal.0; mixer.advance() }
check(delta<=0.1/1440+1e-9 && last==0,"Delay changes crossfade over 30 ms without a discontinuous jump")
let timing = TimingPulse(sampleRate:48_000)
var timingPeak = 0.0, betweenPulsesPeak = 0.0
for frame in 0..<192_000 {
    let signal = abs(timing.sample(enabled:true)); timingPeak = max(timingPeak,signal)
    if frame>4_800 { betweenPulsesPeak = max(betweenPulsesPeak,signal) }
}
check(timingPeak>0.029 && timingPeak<=0.03 && betweenPulsesPeak==0,"Timing sound emits a bounded 100 ms pulse every four seconds")
for _ in 0..<480 { _ = timing.sample(enabled:false) }
check(timing.sample(enabled:false)==0,"Stopping the timing sound fades its generator to silence")

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VanilleTests-\(UUID().uuidString)/settings.json")
let store = StateStore(url:temp)
var saved = SavedState(); saved.applications["test.bundle"] = AppVolume(volume:0.42,muted:true,bypass:true,name:"Test")
saved.eq = boost; saved.profiles[0].outputUID = "stable-device-uid"
saved.outputGroups[0].devices = outputRoutes; saved.selectedGroupID = saved.outputGroups[0].id
store.save(saved,immediately:true)
let restored = StateStore(url:temp).load()
check(restored.applications["test.bundle"] == saved.applications["test.bundle"] && restored.eq == saved.eq && restored.profiles[0].outputUID == "stable-device-uid","Persistent settings round-trip by Bundle ID and Device UID")
check(restored.outputGroups == saved.outputGroups && restored.selectedGroupID == saved.selectedGroupID,"Output groups retain independent volume, mute and millisecond offsets")
let oldData = try! JSONSerialization.data(withJSONObject:["schema":1,"processingPaused":true])
let migrated = try! JSONDecoder().decode(SavedState.self,from:oldData)
check(migrated.outputGroups.count == 4 && migrated.processingPaused,"Existing settings migrate safely to editable output groups")
var transient = saved; transient.timingSound = true; transient.processingPaused = false
store.save(transient,immediately:true)
let safeRestart = StateStore(url:temp).load()
check(!safeRestart.timingSound && safeRestart.processingPaused,"Timing tests never restart automatically after a crash or relaunch")
try! Data("broken".utf8).write(to:temp)
let corrupt = StateStore(url:temp); let fallback = corrupt.load()
check(corrupt.loadWarning != nil && fallback.eq == EQSettings(),"Corrupt settings recover to safe defaults")
try? FileManager.default.removeItem(at:temp.deletingLastPathComponent())

// Single writer / reader stress: a published set must never be torn.
let triple = ParameterMailbox(); let done = Atomic<Bool>(false); let group = DispatchGroup()
let errors = Atomic<Int>(0)
group.enter()
DispatchQueue.global().async {
    for index in 0..<5_000 { triple.publish(gains:Array(repeating:Float(index%100)/100,count:32),eq:EQSettings(),sampleRate:48_000) }
    done.store(true,ordering:.releasing); group.leave()
}
var reads = 0
while !done.load(ordering:.acquiring) {
    let p = triple.consume()
    let first = p[0]
    for i in 1..<32 { if p[i] != first { errors.wrappingAdd(1,ordering:.relaxed) } }
    reads += 1
}
group.wait()
check(errors.load(ordering:.relaxed) == 0 && reads > 0,"Triple-buffer parameter snapshots remain coherent under concurrent updates")
print("\(passed) checks passed")
