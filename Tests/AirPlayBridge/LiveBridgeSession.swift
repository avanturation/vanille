import Foundation
import AVFoundation
import CoreAudio
import Synchronization

/// All capture lifecycle, encoding and playback-clock control run on this serial queue.
/// UI polling is observational; it does not drive rendering or encoding.
final class LiveBridgeSession {
    private let queue=DispatchQueue(label:"Vanille.AirPlayLab.Live",qos:.userInitiated)
    private let capture=BridgeCapture()
    private var segments:LiveSegments?
    private var server:MemoryHTTPServer?
    private var timer:DispatchSourceTimer?
    private let player:AVPlayer
    private let device:OutputDevice
    private var cursor:Int64=0
    private let pcm=UnsafeMutablePointer<Float>.allocate(capacity:4096)
    private var errorText=""
    private var validClock=false
    private var playbackFrame=0.0
    private var callbackCount:UInt64=0
    private var callbackChangedAt=Date()
    private var lastHardwareCheck=Date.distantPast
    private var outputPeak=0.0
    private(set) var baseURL:URL?
    var startedItem=false // main thread only
    var onFailure:((String)->Void)?

    init(player:AVPlayer,device:OutputDevice,apps:[AudioApplication],settings:SavedState,tone:Bool) throws {
        self.player=player;self.device=device
        pcm.initialize(repeating:0,count:4096)
        do {
            try queue.sync {
                let segments=try LiveSegments(sampleRate:48_000);self.segments=segments
                try capture.start(device:device,apps:apps,settings:settings,tone:tone)
                callbackChangedAt=Date()
                let server=MemoryHTTPServer { [weak segments] path in segments?.resource(path) }
                self.server=server
                server.onReady = { [weak self] url in self?.baseURL=url }
                server.onError = { [weak self] text in self?.queue.async { self?.fail(text) } }
                try server.start()
                let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer
                timer.schedule(deadline:.now(),repeating:.milliseconds(20),leeway:.milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick() };timer.resume()
            }
        } catch { stop();throw error }
    }

    private func tick() {
        guard let context=capture.context,let segments,errorText.isEmpty else { return }
        do {
            if context.fault.load(ordering:.relaxed) { throw AudioFailure(operation:"Audio format changed; original output restored",status:-1) }
            let count=context.callbacks.load(ordering:.relaxed)
            if count != callbackCount { callbackCount=count;callbackChangedAt=Date() }
            let timeout=callbackCount==0 ? 12.0 : 1.5
            if Date().timeIntervalSince(callbackChangedAt)>timeout { throw AudioFailure(operation:"Capture stopped responding; original output restored",status:-1) }
            if Date().timeIntervalSince(lastHardwareCheck)>0.5 {
                lastHardwareCheck=Date()
                let currentRate=(try? HAL.read(device.id,kAudioDevicePropertyNominalSampleRate,default:Double(0))) ?? 0
                guard DeviceManager().defaultOutput()==device.id,
                      (try? HAL.read(device.id,kAudioDevicePropertyDeviceIsAlive,default:UInt32(0)))==1,
                      abs(currentRate-48_000)<1 else {
                    throw AudioFailure(operation:"System output changed; original output restored",status:-1)
                }
            }
            var iterations=0
            while context.history.published.load(ordering:.acquiring)-cursor>=2048,iterations<8 {
                guard context.history.copy(from:cursor,count:2048,to:pcm) else { throw AudioFailure(operation:"Live encoder fell behind; original output restored",status:-1) }
                guard try segments.append(pcm,frames:2048) else { break }
                cursor += 2048;iterations += 1
            }
            let date=player.currentItem?.currentDate()
            validClock=player.timeControlStatus == .playing && date != nil && segments.ready
            if let date,validClock {
                playbackFrame=date.timeIntervalSince(segments.origin)*48_000
                let head=Double(context.history.published.load(ordering:.acquiring))
                validClock=playbackFrame>=0 && playbackFrame<head && playbackFrame>head-48_000*40
            }
            context.clock.publish(PlaybackAnchor(frame:playbackFrame,host:AudioGetCurrentHostTime(),valid:validClock))
            if capture.replaced && !validClock { try capture.replaceOriginal(false) }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ text:String) {
        guard errorText.isEmpty else { return }
        errorText=text;validClock=false
        try? capture.replaceOriginal(false)
        capture.context?.clock.publish(PlaybackAnchor())
        capture.stop()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(text) }
    }
    var ready:Bool { queue.sync { segments?.ready == true && errorText.isEmpty } }
    func replaceOriginal(_ value:Bool) throws {
        try queue.sync {
            guard !value || validClock else { throw AudioFailure(operation:"Remote playback clock is not ready; original output retained",status:-1) }
            try capture.replaceOriginal(value)
        }
    }
    func setLocalVolume(_ value:Double) { queue.sync { capture.context?.localGain.store(min(1,max(0,value)),ordering:.relaxed) } }
    var snapshot:[String:Any] {
        queue.sync {
            var result=segments?.snapshot ?? [:]
            result["sourceFrames"]=capture.context?.history.published.load(ordering:.acquiring) ?? 0
            result["encodedFrames"]=cursor
            result["captureCallbacks"]=capture.context?.callbacks.load(ordering:.relaxed) ?? 0
            result["capturedInputPeak"]=capture.context?.inputPeak.load(ordering:.relaxed) ?? 0
            result["capturedApplications"]=capture.appNames
            result["originalReplaced"]=capture.replaced
            result["playbackClockReady"]=validClock
            result["playbackFrame"]=playbackFrame
            result["bufferedSeconds"]=(Double(capture.context?.history.published.load(ordering:.acquiring) ?? 0)-playbackFrame)/48_000
            result["cleanup"]=capture.lastCleanup
            result["error"]=errorText
            result["memoryOnly"]=true
            return result
        }
    }
    func stop() {
        queue.sync {
            timer?.cancel();timer=nil
            validClock=false
            try? capture.replaceOriginal(false)
            capture.stop();segments?.stop()
        }
        server?.stop();server=nil
    }
    deinit { stop();pcm.deinitialize(count:4096);pcm.deallocate() }
}
