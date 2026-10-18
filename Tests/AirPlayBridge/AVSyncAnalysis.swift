import Foundation

/// Timing cues are deliberately irregular: a whole-second audio delay must not
/// look synchronized merely because a periodic metronome has wrapped around.
enum SyncCue {
    static let period=17.0
    static let starts=[0.8,3.4,8.3,13.9]
    static func lit(_ seconds:Double)->Bool {
        guard seconds.isFinite,seconds>=0 else { return false }
        let phase=seconds.truncatingRemainder(dividingBy:period)
        return starts.contains { phase >= $0 && phase < $0+0.1 }
    }
    @inline(__always) static func sample(_ frame:Int64,rate:Double)->Double {
        guard frame>=0,rate>0 else { return 0 }
        let seconds=Double(frame)/rate,phase=seconds.truncatingRemainder(dividingBy:period)
        var envelope=0.0
        for start in starts where phase>=start && phase<start+0.1 {
            envelope=min(1,(phase-start)/0.005)*min(1,(start+0.1-phase)/0.005)
        }
        return 0.015*max(0,envelope)*sin(2*Double.pi*880*seconds)
    }
}

struct TrendPoint:Codable { let elapsed:Double;let valueMS:Double }
enum SyncTrend {
    /// Slope is a descriptive fit, not a claim of acoustic clock drift. Buffer
    /// steps and stalls must be considered alongside it.
    static func summarize(_ points:[TrendPoint],warmup:Double=15)->[String:Any] {
        let valid=points.filter { $0.elapsed>=warmup && $0.elapsed.isFinite && $0.valueMS.isFinite }
        guard !valid.isEmpty else { return ["samples":0,"status":"insufficient data"] }
        let values=valid.map(\.valueMS).sorted(),n=Double(valid.count)
        let x=valid.reduce(0) { $0+$1.elapsed }/n,y=values.reduce(0,+)/n
        var xx=0.0,xy=0.0,yy=0.0
        for point in valid { xx += pow(point.elapsed-x,2);xy += (point.elapsed-x)*(point.valueMS-y);yy += pow(point.valueMS-y,2) }
        let slope=xx>0 ? xy/xx : 0
        let r2=xx>0 && yy>0 ? min(1,max(0,xy*xy/(xx*yy))) : 0
        let window=max(1,valid.count/5)
        let first=valid.prefix(window).map(\.valueMS).sorted(),last=valid.suffix(window).map(\.valueMS).sorted()
        let change=last[last.count/2]-first[first.count/2]
        let steps=zip(valid.dropFirst(),valid).filter { abs($0.0.valueMS-$0.1.valueMS)>100 }.count
        let span=(valid.last?.elapsed ?? 0)-(valid.first?.elapsed ?? 0)
        let trend=span<30 ? "short observation" : steps>0 ? "buffer steps observed; slope is not clock drift" : abs(slope*60)>20 && abs(change)>30 && r2>0.7 ? "progressive timeline offset observed" : "no progressive offset established in this observation"
        return ["samples":valid.count,"observedSeconds":span,"medianMS":values[values.count/2],"minimumMS":values.first!,"maximumMS":values.last!,"p05MS":values[Int(Double(values.count-1)*0.05)],"p95MS":values[Int(Double(values.count-1)*0.95)],"slopeMSPerMinute":slope*60,"rSquared":r2,"firstToLastWindowChangeMS":change,"stepsOver100MS":steps,"status":trend]
    }
}

struct AVSyncReference {
    var seconds=0.0
    var host:UInt64=0
    var valid=false
    var rate=1.0
}

struct HardwareClockTracker {
    private var firstSample:Double?
    private var firstHost:UInt64=0
    private var lastSample=0.0
    private var lastHost:UInt64=0
    private(set) var rejected=0
    private(set) var resets=0
    mutating func observe(sample:Double,host:UInt64,sampleRate:Double,hostFrequency:Double)->Double? {
        guard sample.isFinite,host>0,sampleRate.isFinite,sampleRate>0,hostFrequency>0 else { rejected += 1;return nil }
        if firstSample == nil || host<lastHost || sample<lastSample {
            if firstSample != nil { resets += 1 }
            firstSample=sample;firstHost=host
        }
        lastHost=host;lastSample=sample
        return ((sample-firstSample!)/sampleRate-(Double(host)-Double(firstHost))/hostFrequency)*1000
    }
}

enum SourceToPlaybackLatency {
    /// Maps the captured frame's actual input host time to the AirPlay clock's host time.
    /// This reports downstream latency to the source player; it adds no audio delay.
    static func seconds(sourceFrame:Int64,sourceHost:UInt64,playbackFrame:Double,playbackHost:UInt64,sampleRate:Double,hostFrequency:Double)->Double? {
        guard sourceFrame>=0,sourceHost>0,playbackHost>=sourceHost,playbackFrame.isFinite,playbackFrame>=0,
              sampleRate.isFinite,sampleRate>0,hostFrequency.isFinite,hostFrequency>0 else { return nil }
        let age=(Double(playbackHost)-Double(sourceHost))/hostFrequency
        guard age<=0.25 else { return nil }
        let latency=(Double(sourceFrame)-playbackFrame)/sampleRate+age
        return latency.isFinite && latency>=0 && latency<=10 ? latency : nil
    }
}

/// Control-queue only. Rejects startup, stale clocks, discontinuities and unstable buffers.
/// The hysteresis/cooldown prevents repeated Core Audio reconfiguration for buffer-sized jitter.
struct LatencyDeclarationFilter {
    private var points=[(time:Double,value:Double)]()
    private var lastSample = -Double.infinity
    private var lastChange = -Double.infinity
    private(set) var medianSeconds:Double?
    private(set) var status="Waiting for playback"
    mutating func observe(seconds:Double?,hostSeconds:Double,declaredSeconds:Double)->Double? {
        guard let seconds,seconds.isFinite,seconds>=0.1,seconds<=10,hostSeconds.isFinite,declaredSeconds.isFinite else {
            points.removeAll(keepingCapacity:true);lastSample = -Double.infinity;medianSeconds=nil;status="Waiting for a valid clock";return nil
        }
        if hostSeconds<lastSample || hostSeconds-lastSample>0.75 || points.last.map({ abs($0.value-seconds)>0.35 }) == true {
            points.removeAll(keepingCapacity:true)
        }
        guard hostSeconds-lastSample>=0.25 || hostSeconds<lastSample else { return nil }
        lastSample=hostSeconds;points.append((hostSeconds,seconds))
        if points.count>49 { points.removeFirst(points.count-49) }
        guard let first=points.first,hostSeconds-first.time>=8 else { status="Measuring stable playback";return nil }
        let values=points.map(\.value).sorted(),median=values[values.count/2]
        let deviations=values.map { abs($0-median) }.sorted()
        guard values.last!-values.first!<=0.10,deviations[deviations.count/2]<=0.025 else { status="Playback buffer is changing";return nil }
        medianSeconds=median
        let rounded=(median*100).rounded()/100
        guard abs(rounded-declaredSeconds)>=0.04 else { status="Latency declaration matches playback";return nil }
        guard hostSeconds-lastChange>=15 else { status="Waiting for timing to settle";return nil }
        lastChange=hostSeconds;status="Updating source-player latency"
        return rounded
    }
}
