import Foundation
var failed=0,total=0
func check(_ value:Bool,_ name:String) { total += 1;print("\(value ? "PASS" : "FAIL") \(name)");if !value { failed += 1 } }
let fixed=(0..<900).map { TrendPoint(elapsed:Double($0)/10,valueMS:3600+sin(Double($0))*0.3) }
let constant=SyncTrend.summarize(fixed)
check(abs((constant["slopeMSPerMinute"] as? Double ?? 99))<1,"Fixed latency is not classified as accumulating drift")
let drift=SyncTrend.summarize((0..<900).map { TrendPoint(elapsed:Double($0)/10,valueMS:200+Double($0)/10) })
check(abs((drift["slopeMSPerMinute"] as? Double ?? 0)-60)<0.001 && (drift["rSquared"] as? Double ?? 0)>0.99,"Known progressive drift is measured in milliseconds per minute")
let stepped=SyncTrend.summarize((0..<900).map { TrendPoint(elapsed:Double($0)/10,valueMS:$0<450 ? 3000 : 4000) })
check(stepped["stepsOver100MS"] as? Int == 1 && (stepped["status"] as? String ?? "").contains("not clock drift"),"Buffer discontinuity is distinguished from oscillator drift")
check(SyncTrend.summarize([TrendPoint(elapsed:20,valueMS:.nan)])["samples"] as? Int == 0,"Non-finite timing samples cannot enter the fit")
check(SyncCue.lit(0.85) && !SyncCue.lit(2.85) && SyncCue.lit(17.85) && !SyncCue.lit(.infinity),"Irregular visual cues reject a misleading two-second phase match")
check(abs(SyncCue.sample(0,rate:48000))<1e-12 && SyncCue.sample(-1,rate:48000)==0,"Cue audio has a silent baseline and safe bounds")
var energy=0.0
for i in 0..<4800 { let x=SyncCue.sample(Int64(38400+i),rate:48000);energy += x*x }
check(energy>0.1,"Generated audio contains the actual cue signal")
var hardware=HardwareClockTracker()
check(hardware.observe(sample:0,host:0,sampleRate:48000,hostFrequency:1000)==nil,"A startup zero host timestamp is rejected even if a device marks its flags valid")
_ = hardware.observe(sample:48000,host:1000,sampleRate:48000,hostFrequency:1000)
check(abs(hardware.observe(sample:96000,host:2000,sampleRate:48000,hostFrequency:1000) ?? 1)<1e-9,"Valid sample and host clocks have a common zero reference")
_ = hardware.observe(sample:0,host:3000,sampleRate:48000,hostFrequency:1000)
check(hardware.resets==1 && hardware.observe(sample:.nan,host:4000,sampleRate:48000,hostFrequency:1000)==nil,"Clock resets create a new epoch and non-finite sample times are rejected")
check(abs((SourceToPlaybackLatency.seconds(sourceFrame:480_000,sourceHost:1000,playbackFrame:288_000,playbackHost:1010,sampleRate:48_000,hostFrequency:1000) ?? 0)-4.01)<1e-9,"Latency accounts for input and playback host timestamps")
check(SourceToPlaybackLatency.seconds(sourceFrame:480_000,sourceHost:0,playbackFrame:288_000,playbackHost:1010,sampleRate:48_000,hostFrequency:1000)==nil && SourceToPlaybackLatency.seconds(sourceFrame:480_000,sourceHost:1000,playbackFrame:288_000,playbackHost:2000,sampleRate:48_000,hostFrequency:1000)==nil,"Invalid and stale capture clocks cannot alter device latency")
var declaration=LatencyDeclarationFilter(),changes=[Double](),declared=4.0
for i in 0..<240 {
    if let value=declaration.observe(seconds:3.75+sin(Double(i))*0.005,hostSeconds:Double(i)*0.25,declaredSeconds:declared) { changes.append(value);declared=value }
}
check(changes==[3.75],"Stable measured latency changes the declaration once without chasing buffer jitter")
var startup=LatencyDeclarationFilter(),earlyChanges=0
for i in 0..<32 { if startup.observe(seconds:3.75,hostSeconds:Double(i)*0.25,declaredSeconds:4) != nil { earlyChanges += 1 } }
check(earlyChanges==0,"Startup buffering cannot trigger premature latency changes")
_ = startup.observe(seconds:nil,hostSeconds:8,declaredSeconds:4)
check(startup.observe(seconds:3.75,hostSeconds:8.25,declaredSeconds:4)==nil && startup.medianSeconds==nil,"A playback interruption requires a fresh stable timing window")
var unstable=LatencyDeclarationFilter(),unstableChanges=0
for i in 0..<120 { if unstable.observe(seconds:i.isMultiple(of:2) ? 3.5 : 3.8,hostSeconds:Double(i)*0.25,declaredSeconds:4) != nil { unstableChanges += 1 } }
check(unstableChanges==0,"Unstable playback buffers are not declared as a calibrated route")
print("\(total-failed)/\(total) A/V analysis checks passed")
exit(failed==0 ? 0 : 1)
