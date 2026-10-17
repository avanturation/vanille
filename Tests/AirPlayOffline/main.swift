import Foundation
import Synchronization

var failures=0
func check(_ condition:Bool,_ name:String) { print("\(condition ? "PASS" : "FAIL") \(name)");if !condition { failures += 1 } }
let history=PCMHistory(sampleRate:1_000)
check(history.sample(at:0,head:0).0 == 0,"Empty history is silent")
for i in 0..<2_000 { history.push(Float(i),-Float(i)) };history.commit()
let sample=history.sample(at:100.5,head:2_000)
check(sample.0 == 100.5 && sample.1 == -100.5,"Fractional stereo playback preserves channel polarity")
check(history.sample(at:.infinity,head:2_000).0 == 0 && history.sample(at:.nan,head:2_000).0 == 0 && history.sample(at:Double.greatestFiniteMagnitude,head:2_000).0 == 0,"Invalid and huge positions cannot overflow sample indexes")
check(history.sample(at:2_001,head:2_000).0 == 0 && history.sample(at:-1,head:2_000).0 == 0,"Future and negative playback positions are silent")
for i in 2_000..<100_000 { history.push(Float(i),-Float(i)) };history.commit()
let recent=history.sample(at:90_000.25,head:100_000)
check(abs(recent.0-90_000.25)<0.01 && history.sample(at:10_000,head:100_000).0 == 0,"Wrapped history retains recent frames and rejects overwritten audio")
let output=UnsafeMutablePointer<Float>.allocate(capacity:20)
defer { output.deallocate() }
check(history.copy(from:90_000,count:10,to:output) && output[0] == 90_000 && output[19] == -90_009 && !history.copy(from:0,count:10,to:output),"Encoder gets only complete retained frames")
let clock=PlaybackClock(),finished=Atomic<Bool>(false),torn=Atomic<Bool>(false)
let group=DispatchGroup();group.enter()
DispatchQueue.global().async {
    for i in 1...20_000 { clock.publish(PlaybackAnchor(frame:Double(i),host:UInt64(i),valid:true)) }
    finished.store(true,ordering:.releasing);group.leave()
}
while !finished.load(ordering:.acquiring) { let a=clock.consume();if a.valid && a.frame != Double(a.host) { torn.store(true,ordering:.relaxed) } }
group.wait()
check(!torn.load(ordering:.relaxed),"Playback clock snapshots do not tear during 20,000 concurrent updates")
print("\(7-failures)/7 AirPlay bridge checks passed")
exit(failures == 0 ? 0 : 1)
