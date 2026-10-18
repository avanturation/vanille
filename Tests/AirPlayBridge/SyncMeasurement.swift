import Foundation
import AVFoundation
import CoreAudio

final class SyncMeasurement {
    private let queue=DispatchQueue(label:"Vanille.AVSync.Measurement",qos:.utility)
    private let probe=HardwareTimingProbe()
    private let player:AVPlayer
    private let live:LiveBridgeSession?
    private let video:ControlledVideo
    private let device:OutputDevice
    private let label:String
    private let url:URL
    private var timer:DispatchSourceTimer?
    private let started:UInt64
    private let frequency=AudioGetHostClockFrequency()
    private var metadata:[String:Any]=[:]
    private var samples:[[String:Any]]=[]
    private var hardwareClock=HardwareClockTracker()
    private var callbackClock=HardwareClockTracker()
    private var finished=false
    private var reason="Running"
    var onFinish:(()->Void)?

    init(label:String,url:URL,device:OutputDevice,player:AVPlayer,live:LiveBridgeSession?,video:ControlledVideo,commandHost:UInt64) {
        self.label=label;self.url=url;self.device=device;self.player=player;self.live=live;self.video=video
        started=commandHost
        queue.sync {
            metadata=HardwareTiming.describe(device)
            do { try probe.start(device.id) } catch { metadata["ioProbeError"]=error.localizedDescription }
            let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer
            timer.schedule(deadline:.now(),repeating:.milliseconds(100),leeway:.milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() };timer.resume()
        }
    }
    private func tick() {
        guard !finished else { return }
        let elapsed=(Double(AudioGetCurrentHostTime())-Double(started))/frequency
        var row:[String:Any]=["elapsed":elapsed,"playerPlaying":player.timeControlStatus == .playing,"playerRate":player.rate]
        let io=probe.mailbox.consume(),timing=io.dictionary(frequency:frequency)
        row["deviceIO"]=timing
        if AudioTimeStampFlags(rawValue:io.outputFlags).contains([.sampleTimeValid,.hostTimeValid]),let delta=callbackClock.observe(sample:io.outputSample,host:io.outputHost,sampleRate:device.sampleRate,hostFrequency:frequency) { row["ioSampleVsHostMS"]=delta }
        var deviceTime=AudioTimeStamp()
        deviceTime.mFlags=[.sampleTimeValid,.hostTimeValid,.rateScalarValid]
        let status=AudioDeviceGetCurrentTime(device.id,&deviceTime)
        row["deviceCurrentTimeStatus"]=status
        if status==noErr,deviceTime.mFlags.contains([.sampleTimeValid,.hostTimeValid]) {
            if let delta=hardwareClock.observe(sample:deviceTime.mSampleTime,host:deviceTime.mHostTime,sampleRate:device.sampleRate,hostFrequency:frequency) { row["hardwareSampleVsHostMS"]=delta }
            var translated=AudioTimeStamp();translated.mFlags = .hostTimeValid
            var sampleOnly=AudioTimeStamp();sampleOnly.mFlags = .sampleTimeValid;sampleOnly.mSampleTime=deviceTime.mSampleTime
            let translatedStatus=AudioDeviceTranslateTime(device.id,&sampleOnly,&translated)
            row["translateTimeStatus"]=translatedStatus
            if translatedStatus==noErr,translated.mFlags.contains(.hostTimeValid) { row["translateRoundtripMS"]=(Double(translated.mHostTime)-Double(deviceTime.mHostTime))/frequency*1000 }
        }
        let t=player.currentTime().seconds
        if t.isFinite {
            row["playerTime"]=t
            row["commandToPlayerTimelineMS"]=(elapsed-t)*1000
        }
        if let timebase=player.currentItem?.timebase {
            var id:AudioDeviceID=0
            let clockStatus=CMAudioDeviceClockGetAudioDevice(CMTimebaseCopyUltimateSourceClock(timebase),deviceUIDOut:nil,deviceIDOut:&id,trackingDefaultDeviceOut:nil)
            row["playerDeviceClockStatus"]=clockStatus
            row["playerClockMatchesDefault"]=clockStatus==noErr && id==device.id
        }
        if let item=player.currentItem {
            let offset=item.recommendedTimeOffsetFromLive.seconds
            if offset.isFinite { row["recommendedLiveOffsetMS"]=offset*1000 }
            row["stalls"]=item.accessLog()?.events.last?.numberOfStalls ?? 0
        }
        if let live {
            let s=live.snapshot
            row["bridge"]=s
            if s["playbackClockReady"] as? Bool == true,let lag=s["bufferedSeconds"] as? Double { row["captureToPlayerTimelineMS"]=lag*1000 }
        }
        row["video"]=video.snapshot
        samples.append(row)
        if DeviceManager().defaultOutput() != device.id { finish("System output changed during measurement") }
        else if elapsed>=90 { finish("Completed 90-second observation") }
        else if samples.count%50==0 { write() }
    }
    private func points(_ key:String,nested:String?=nil)->[TrendPoint] {
        samples.compactMap { row in
            guard row["playerPlaying"] as? Bool == true,let t=row["elapsed"] as? Double else { return nil }
            let object=nested.flatMap { row[$0] as? [String:Any] } ?? row
            if nested=="video",object["settling"] as? Bool == true { return nil }
            if nested=="video",object["compensated"] as? Bool != true { return nil }
            guard let value=object[key] as? Double else { return nil }
            return TrendPoint(elapsed:t,valueMS:value)
        }
    }
    private func report()->[String:Any] {
        let clockMatches=samples.filter { $0["playerClockMatchesDefault"] as? Bool == true }.count
        return ["case":label,"status":reason,"date":ISO8601DateFormatter().string(from:Date()),"device":metadata,"durationSeconds":samples.last?["elapsed"] ?? 0,"playerDefaultDeviceClockMatches":clockMatches,"rejectedHardwareClockSamples":hardwareClock.rejected,"hardwareClockResets":hardwareClock.resets,"clockSampleVsHost":SyncTrend.summarize(points("hardwareSampleVsHostMS")),"ioSampleVsHost":SyncTrend.summarize(points("ioSampleVsHostMS")),"outputSchedulingLead":SyncTrend.summarize(points("outputMinusCallbackMS",nested:"deviceIO")),"captureToPlayerTimeline":SyncTrend.summarize(points("captureToPlayerTimelineMS")),"commandToPlayerTimeline":SyncTrend.summarize(points("commandToPlayerTimelineMS")),"videoTimebaseResidual":SyncTrend.summarize(points("timebaseResidualMS",nested:"video")),"decodedVideoFrameResidual":SyncTrend.summarize(points("decodedFrameResidualMS",nested:"video")),"samples":samples,"cleanup":probe.cleanup,"scope":"Synthetic cue, device timestamps and owned video only. No microphone, screen capture, protected frames or acoustic/lip-sync certification.","audioSaved":false]
    }
    private func write() {
        guard let data=try? JSONSerialization.data(withJSONObject:report(),options:[.prettyPrinted,.sortedKeys]) else { return }
        try? data.write(to:url,options:.atomic)
    }
    private func finish(_ text:String) {
        guard !finished else { return }
        reason=text;finished=true;timer?.cancel();timer=nil;probe.stop();write()
        DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    }
    func stop() { queue.sync { finish("Stopped before the scheduled end") } }
    var summary:[String:Any] { queue.sync { var r=report();r.removeValue(forKey:"samples");return r } }
    deinit { timer?.cancel();probe.stop() }
}
