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
a.deallocate(); b.deallocate(); c.deallocate(); l.deallocate(); r.deallocate(); inList.unsafeMutablePointer.deallocate(); outList.unsafeMutablePointer.deallocate()

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VanilleTests-\(UUID().uuidString)/settings.json")
let store = StateStore(url:temp)
var saved = SavedState(); saved.applications["test.bundle"] = AppVolume(volume:0.42,muted:true,bypass:true,name:"Test")
saved.eq = boost; saved.profiles[0].outputUID = "stable-device-uid"
store.save(saved,immediately:true)
let restored = StateStore(url:temp).load()
check(restored.applications["test.bundle"] == saved.applications["test.bundle"] && restored.eq == saved.eq && restored.profiles[0].outputUID == "stable-device-uid","Persistent settings round-trip by Bundle ID and Device UID")
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
