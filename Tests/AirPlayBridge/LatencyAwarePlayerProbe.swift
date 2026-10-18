import Foundation
import AVFoundation
import CoreAudio

/// An ordinary, unmodified source AVPlayer. No video clock/position correction
/// is applied. Its output is explicitly a private MR4 aggregate, so the global
/// route is preserved while testing whether HAL's declaration reaches a player.
final class LatencyAwarePlayerProbe {
    private let queue=DispatchQueue(label:"Vanille.SourcePlayerLatency",qos:.utility)
    private let player=AVPlayer()
    private let probe=HardwareTimingProbe()
    private let physical:OutputDevice
    private let url:URL
    private let original:AudioObjectID
    private let frequency=AudioGetHostClockFrequency()
    private var aggregate:AudioObjectID=0
    private var timer:DispatchSourceTimer?
    private var started:UInt64=0
    private var index=0
    private var points:[TrendPoint]=[]
    private var matches=0
    private var statuses:Set<Int32>=[]
    private var rows:[[String:Any]]=[]
    private var phase:[String:Any]=[:]
    private var stopped=false
    private let completion:([String:Any])->Void
    init(physical:OutputDevice,url:URL,completion:@escaping ([String:Any])->Void) {
        self.physical=physical;self.url=url;self.completion=completion;original=DeviceManager().defaultOutput()
        queue.async { self.beginCase() }
    }
    private func beginCase() {
        let extra=index==0 ? 0.0 : physical.sampleRate*4
        phase=["configuredExtraFrames":extra];points=[];matches=0;statuses=[]
        do {
            let uid="com.avanturation.Vanille.player-latency.\(UUID().uuidString)"
            let dictionary:[String:Any]=[kAudioAggregateDeviceNameKey:"Vanille Source Player Probe",kAudioAggregateDeviceUIDKey:uid,kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,kAudioAggregateDeviceMainSubDeviceKey:physical.uid,kAudioAggregateDeviceSubDeviceListKey:[[kAudioSubDeviceUIDKey:physical.uid,kAudioSubDeviceExtraOutputLatencyKey:extra]]]
            try HAL.check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary,&aggregate),"Create source player latency probe")
            Thread.sleep(forTimeInterval:0.15)
            phase["safetyOffsetFrames"]=try HAL.read(aggregate,kAudioDevicePropertySafetyOffset,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
            phase["deviceLatencyFrames"]=try HAL.read(aggregate,kAudioDevicePropertyLatency,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
            try probe.start(aggregate)
            player.audioOutputDeviceUniqueID=uid
            player.replaceCurrentItem(with:AVPlayerItem(url:url))
            player.volume=0.01 // Synthetic signal only, kept near inaudible.
            started=AudioGetCurrentHostTime();player.play()
            let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer
            timer.schedule(deadline:.now(),repeating:.milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() };timer.resume()
        } catch { phase["error"]=error.localizedDescription;finishCase() }
    }
    private func tick() {
        guard !stopped else { return }
        let elapsed=(Double(AudioGetCurrentHostTime())-Double(started))/frequency,time=player.currentTime().seconds
        if player.timeControlStatus == .playing,time.isFinite { points.append(TrendPoint(elapsed:elapsed,valueMS:(elapsed-time)*1000)) }
        if let base=player.currentItem?.timebase {
            var id:AudioDeviceID=0
            let status=CMAudioDeviceClockGetAudioDevice(CMTimebaseCopyUltimateSourceClock(base),deviceUIDOut:nil,deviceIDOut:&id,trackingDefaultDeviceOut:nil)
            statuses.insert(status);if status==noErr,id==aggregate { matches += 1 }
        }
        if let error=player.currentItem?.error { phase["error"]=error.localizedDescription;finishCase();return }
        if DeviceManager().defaultOutput() != original { phase["error"]="Default output changed; cancelled";stopped=true;finishCase();return }
        if elapsed>=12 { finishCase() }
    }
    private func finishCase() {
        timer?.cancel();timer=nil
        phase["commandToSourcePlayerTimeline"]=SyncTrend.summarize(points,warmup:3)
        phase["playerClockMatchesAggregate"]=matches
        phase["clockQueryStatuses"]=statuses.sorted()
        phase["ioTiming"]=probe.mailbox.consume().dictionary(frequency:frequency)
        player.pause();player.replaceCurrentItem(with:nil)
        probe.stop();phase["ioCleanup"]=probe.cleanup
        if aggregate != 0 { phase["destroyStatus"]=AudioHardwareDestroyAggregateDevice(aggregate) };aggregate=0
        rows.append(phase)
        if index==0,!stopped { index=1;beginCase();return }
        stopped=true
        let report:[String:Any]=["cases":rows,"defaultPreserved":DeviceManager().defaultOutput()==original,"scope":"Unmodified source AVPlayer, synthetic audio, private output only, no timeline correction, no global route change","audioSaved":false,"date":ISO8601DateFormatter().string(from:Date())]
        DispatchQueue.main.async { self.completion(report) }
    }
    func cancel() {
        queue.sync {
            stopped=true;timer?.cancel();timer=nil;player.pause();player.replaceCurrentItem(with:nil);probe.stop()
            if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate);aggregate=0 }
        }
    }
    deinit { timer?.cancel();player.pause();probe.stop();if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) } }
}
