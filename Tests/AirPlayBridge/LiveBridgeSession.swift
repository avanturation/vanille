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
    private let expectedDefault:AudioObjectID
    private var watchesDefault:Bool
    private var failureContext:[String:Any]=[:]
    private let testEndsAt:Date?
    private var cursor:Int64=0
    private let pcm=UnsafeMutablePointer<Float>.allocate(capacity:4096)
    private var errorText=""
    private var validClock=false
    private var playbackFrame=0.0
    private var playbackHost:UInt64=0
    private var latestIO=IOTimeSnapshot()
    private var callbackCount:UInt64=0
    private var callbackChangedAt=Date()
    private var outputCallbackCount:UInt64=0
    private var outputChangedAt=Date()
    private var lastHardwareCheck=Date.distantPast
    private var alignmentRequested=false
    private var alignmentRecoveries=0
    private let currentDeclaredLatency:(()->Double)?
    private let requestDeclaredLatency:((Double)->Void)?
    private let declarationError:(()->Int32)?
    private var latencyFilter=LatencyDeclarationFilter()
    private var measuredLatency:Double?
    private var wantsPlayback=true
    private var lastPlayerRetry=Date.distantPast
    private var playbackRetries=0
    private let sourceProvider:(() throws->[AudioApplication])?
    private let settings:SavedState
    private var sourceApps:[AudioApplication]
    private var sourceObservers=[AudioObjectID:HALObservation]()
    private var sourceListObserver:HALObservation?
    private var sourcesNeedRefresh=false
    private var lastSourceRefresh=Date.distantPast
    private var lastActivityCheck=Date.distantPast
    private var sourceActiveProcesses=0
    private var audibleAppIDs=Set<String>()
    private var sourceEvents=Set<String>()
    private var sourceIdleSince:Date?
    private var sourcePaused=false
    private var timelineSeeking=false
    private var hadPlaybackClock=false
    private var sourcePauses=0,sourceTimelineResets=0
    private var lastTimelineReset=Date.distantPast
    private var timelineResumeAfterFrame:Int64?
    private var ignoreSourceResetsUntil=Date.distantPast
    private(set) var baseURL:URL?
    var startedItem=false // main thread only
    var onFailure:((String)->Void)?

    init(player:AVPlayer,device:OutputDevice,apps:[AudioApplication],settings:SavedState,tone:Bool,syncTone:Bool=false,captureDeviceUID:String?=nil,expectedDefault:AudioObjectID?=nil,separateOutput:AudioObjectID?=nil,deferDefaultWatch:Bool=false,progress:((String)->Void)?=nil,currentDeclaredLatency:(()->Double)?=nil,requestDeclaredLatency:((Double)->Void)?=nil,declarationError:(()->Int32)?=nil,sourceProvider:(() throws->[AudioApplication])?=nil) throws {
        self.player=player;self.device=device;self.expectedDefault=expectedDefault ?? device.id;watchesDefault = !deferDefaultWatch;testEndsAt=tone ? Date().addingTimeInterval(syncTone ? 150 : 90) : nil
        self.currentDeclaredLatency=currentDeclaredLatency;self.requestDeclaredLatency=requestDeclaredLatency;self.declarationError=declarationError
        self.sourceProvider=sourceProvider;self.settings=settings;self.sourceApps=apps
        pcm.initialize(repeating:0,count:4096)
        do {
            try queue.sync {
                let segments=try LiveSegments(sampleRate:48_000);self.segments=segments
                try capture.start(device:device,apps:apps,settings:settings,tone:tone,syncTone:syncTone,captureDeviceUID:captureDeviceUID,separateOutput:separateOutput,progress:progress)
                if sourceProvider != nil {
                    updateSourceObservers()
                    sourceListObserver=HALObservation(HAL.system,kAudioHardwarePropertyProcessObjectList,queue:queue,change: { [weak self] in self?.sourcesNeedRefresh=true })
                }
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
        latestIO=context.ioTiming.consume()
        do {
            if let testEndsAt,Date()>=testEndsAt { throw AudioFailure(operation:"Timing test finished; original output restored",status:-1) }
            if context.fault.load(ordering:.relaxed) { throw AudioFailure(operation:"Audio format changed; original output restored",status:-1) }
            let count=context.callbacks.load(ordering:.relaxed)
            if count != callbackCount { callbackCount=count;callbackChangedAt=Date() }
            let outputCount=context.outputCallbacks.load(ordering:.relaxed)
            if outputCount != outputCallbackCount { outputCallbackCount=outputCount;outputChangedAt=Date() }
            if capture.replaced,Date().timeIntervalSince(outputChangedAt)>1.5 { throw AudioFailure(operation:"Speaker output stopped; original output restored",status:-1) }
            let timeout=callbackCount==0 ? 12.0 : 1.5
            if !sourcePaused,(sourceProvider == nil || sourceActiveProcesses>0),Date().timeIntervalSince(callbackChangedAt)>timeout { throw AudioFailure(operation:"Capture stopped responding; original output restored",status:-1) }
            if Date().timeIntervalSince(lastHardwareCheck)>0.5 {
                lastHardwareCheck=Date()
                let currentRate=(try? HAL.read(device.id,kAudioDevicePropertyNominalSampleRate,default:Double(0))) ?? 0
                guard (!watchesDefault || DeviceManager().defaultOutput()==expectedDefault),
                      (try? HAL.read(device.id,kAudioDevicePropertyDeviceIsAlive,default:UInt32(0)))==1,
                      abs(currentRate-48_000)<1 else {
                    throw AudioFailure(operation:"System output changed; original output restored",status:-1)
                }
            }
            if let sourceProvider {
                if sourcesNeedRefresh || Date().timeIntervalSince(lastSourceRefresh)>0.5 {
                    let apps=try sourceProvider()
                    try capture.reconcile(apps:apps,settings:settings)
                    sourceApps=apps;updateSourceObservers();sourcesNeedRefresh=false;lastSourceRefresh=Date()
                }
                updateSourceTransport()
            }
            var iterations=0
            while context.history.published.load(ordering:.acquiring)-cursor>=2048,iterations<8 {
                guard context.history.copy(from:cursor,count:2048,to:pcm) else { throw AudioFailure(operation:"Live encoder fell behind; original output restored",status:-1) }
                guard try segments.append(pcm,frames:2048) else { break }
                cursor += 2048;iterations += 1
            }
            if let resumeAfter=timelineResumeAfterFrame,cursor>=resumeAfter { seekToLiveNow() }
            if wantsPlayback,!sourcePaused,!timelineSeeking,player.currentItem?.status == .readyToPlay,player.timeControlStatus == .paused,
               player.currentItem?.isPlaybackBufferEmpty == false,Date().timeIntervalSince(lastPlayerRetry)>0.5 {
                lastPlayerRetry=Date();playbackRetries += 1;player.playImmediately(atRate:1)
            }
            let date=player.currentItem?.currentDate()
            validClock=player.timeControlStatus == .playing && date != nil && segments.ready && !sourcePaused && !timelineSeeking
            // A newly created item initially exposes the Mac clock while AirPlay connects.
            // Treat fallback as failure only after real media playback has a valid date.
            if alignmentRequested,validClock,let timebase=player.currentItem?.timebase {
                var id:AudioDeviceID=0
                let status=CMAudioDeviceClockGetAudioDevice(CMTimebaseCopyUltimateSourceClock(timebase),deviceUIDOut:nil,deviceIDOut:&id,trackingDefaultDeviceOut:nil)
                if status==noErr,(id==device.id || id==expectedDefault) {
                    throw AudioFailure(operation:"Player returned to the Mac; original MR4 output restored. Select AirPlay again before restarting",status:-1)
                }
            }
            if let date,validClock {
                playbackFrame=date.timeIntervalSince(segments.origin)*48_000
                let head=Double(context.history.published.load(ordering:.acquiring))
                validClock=playbackFrame>=0 && playbackFrame<head && playbackFrame>head-48_000*40
            }
            if validClock { hadPlaybackClock=true }
            playbackHost=AudioGetCurrentHostTime()
            context.clock.publish(PlaybackAnchor(frame:playbackFrame,host:playbackHost,valid:validClock))
            if let currentDeclaredLatency,let requestDeclaredLatency {
                let status=declarationError?() ?? noErr
                guard status==noErr else { throw AudioFailure(operation:"Source-player timing update failed; restoring original output",status:status) }
                let inputValid=AudioTimeStampFlags(rawValue:latestIO.inputFlags).contains(.hostTimeValid)
                measuredLatency=validClock && inputValid ? SourceToPlaybackLatency.seconds(sourceFrame:latestIO.sourceFrame,sourceHost:latestIO.inputHost,playbackFrame:playbackFrame,playbackHost:playbackHost,sampleRate:48_000,hostFrequency:AudioGetHostClockFrequency()) : nil
                if let target=latencyFilter.observe(seconds:measuredLatency,hostSeconds:Double(playbackHost)/AudioGetHostClockFrequency(),declaredSeconds:currentDeclaredLatency()) {
                    ignoreSourceResetsUntil=Date().addingTimeInterval(1.5);requestDeclaredLatency(target)
                }
            }
            if alignmentRequested && validClock && context.hasSignal {
                let wasReplaced=capture.replaced
                try capture.replaceOriginal(true)
                if !wasReplaced { alignmentRecoveries += 1 }
            } else if capture.replaced && !validClock && !sourcePaused && !timelineSeeking { try capture.replaceOriginal(false) }
        } catch { fail(error.localizedDescription) }
    }
    private func updateSourceObservers() {
        let processes=Set(sourceApps.flatMap(\.processes))
        for id in sourceObservers.keys.filter({ !processes.contains($0) }) { sourceObservers.removeValue(forKey:id) }
        for app in sourceApps {
            for id in app.processes where sourceObservers[id]==nil {
                sourceObservers[id]=HALObservation(id,kAudioProcessPropertyIsRunningOutput,queue:queue,change: { [weak self] in self?.sourceEvents.insert(app.id) })
            }
        }
    }
    private func updateSourceTransport() {
        guard Date().timeIntervalSince(lastActivityCheck)>0.1 else { return }
        lastActivityCheck=Date()
        let recent=capture.recentlyAudibleAppIDs
        if !recent.isEmpty { audibleAppIDs=recent }
        let relevant=sourceApps.filter { audibleAppIDs.isEmpty || audibleAppIDs.contains($0.id) }
        let previousActive=sourceActiveProcesses
        sourceActiveProcesses=relevant.flatMap(\.processes).filter { (try? HAL.read($0,kAudioProcessPropertyIsRunningOutput,default:UInt32(0)))==1 }.count
        if previousActive==0,sourceActiveProcesses>0 { callbackChangedAt=Date() }
        let changed = !sourceEvents.intersection(audibleAppIDs).isEmpty && Date()>ignoreSourceResetsUntil
        sourceEvents.removeAll()
        guard hadPlaybackClock,wantsPlayback,player.currentItem != nil else { return }
        if sourceActiveProcesses==0 {
            if sourceIdleSince==nil { sourceIdleSince=Date() }
            if !sourcePaused,Date().timeIntervalSince(sourceIdleSince!)>0.15 {
                sourcePaused=true;sourcePauses += 1;validClock=false
                capture.context?.clock.publish(PlaybackAnchor());player.pause()
            }
        } else {
            sourceIdleSince=nil
            if sourcePaused || changed {
                sourcePaused=false;resetLiveTimeline(primeFresh:true)
            }
        }
    }
    private func resetLiveTimeline(primeFresh:Bool=false) {
        guard !timelineSeeking,Date().timeIntervalSince(lastTimelineReset)>0.5,player.currentItem?.status == .readyToPlay else { return }
        timelineSeeking=true;lastTimelineReset=Date();sourceTimelineResets += 1;validClock=false
        capture.context?.clock.publish(PlaybackAnchor());player.pause()
        if primeFresh {
            // Expired pre-pause samples must not be replayed. One normal live buffer
            // of fresh source material is required before seeking the AirPlay stream.
            timelineResumeAfterFrame=(capture.context?.history.published.load(ordering:.acquiring) ?? cursor)+144_000
        } else { seekToLiveNow() }
    }
    private func seekToLiveNow() {
        timelineResumeAfterFrame=nil
        player.seek(to:.positiveInfinity) { [weak self] finished in
            guard let self else { return }
            self.queue.async {
                self.timelineSeeking=false
                guard self.errorText.isEmpty,self.wantsPlayback,!self.sourcePaused else { return }
                if finished { self.player.playImmediately(atRate:1) }
                else { self.fail("The live timeline could not resume; original output restored") }
            }
        }
    }
    func resynchronize() { queue.async { self.resetLiveTimeline() } }
    private func fail(_ text:String) {
        guard errorText.isEmpty else { return }
        errorText=text;validClock=false
        let actual=DeviceManager().defaultOutput()
        failureContext=["actualDefault":actual,"expectedDefault":expectedDefault,
            "actualDefaultName":(try? HAL.string(actual,kAudioObjectPropertyName)) ?? "Unavailable",
            "actualDefaultAlive":(try? HAL.read(actual,kAudioDevicePropertyDeviceIsAlive,default:UInt32(0))) ?? 0,
            "expectedDefaultAlive":(try? HAL.read(expectedDefault,kAudioDevicePropertyDeviceIsAlive,default:UInt32(0))) ?? 0,
            "expectedCanBeDefault":(try? HAL.read(expectedDefault,kAudioDevicePropertyDeviceCanBeDefaultDevice,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)) ?? 0,
            "expectedHidden":(try? HAL.read(expectedDefault,kAudioDevicePropertyIsHidden,default:UInt32(0))) ?? 0,
            "physicalAlive":(try? HAL.read(device.id,kAudioDevicePropertyDeviceIsAlive,default:UInt32(0))) ?? 0,
            "sourceFrames":capture.context?.history.published.load(ordering:.acquiring) ?? 0,
            "capturedInputPeak":capture.context?.inputPeak.load(ordering:.relaxed) ?? 0,
            "outputCallbacks":capture.context?.outputCallbacks.load(ordering:.relaxed) ?? 0,
            "callbacks":capture.context?.callbacks.load(ordering:.relaxed) ?? 0,"applications":capture.appNames,
            "ioTiming":latestIO.dictionary(frequency:AudioGetHostClockFrequency()),
            "outputIOTiming":capture.context?.outputIOTiming.consume().dictionary(frequency:AudioGetHostClockFrequency()) ?? [:]]
        try? capture.replaceOriginal(false)
        capture.context?.clock.publish(PlaybackAnchor())
        capture.stop()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(text) }
    }
    var ready:Bool { queue.sync { segments?.ready == true && errorText.isEmpty } }
    func beginDefaultWatch() { queue.sync { watchesDefault=true;lastHardwareCheck=Date.distantPast } }
    func releaseOriginal() { queue.sync { alignmentRequested=false;try? capture.replaceOriginal(false) } }
    func replaceOriginal(_ value:Bool) throws {
        try queue.sync {
            alignmentRequested=value
            if !value || validClock && capture.context?.hasSignal == true { try capture.replaceOriginal(value) }
        }
    }
    func setLocalVolume(_ value:Double) { queue.sync { capture.context?.localGain.store(min(1,max(0,value)),ordering:.relaxed) } }
    func avReference(compensated:Bool)->AVSyncReference {
        queue.sync {
            if compensated { return AVSyncReference(seconds:playbackFrame/48_000,host:playbackHost,valid:validClock) }
            return AVSyncReference(seconds:Double(latestIO.sourceFrame)/48_000,host:latestIO.outputHost,valid:AudioTimeStampFlags(rawValue:latestIO.outputFlags).contains(.hostTimeValid))
        }
    }
    func prepareForSeek() {
        queue.sync {
            wantsPlayback=false
            validClock=false
            capture.context?.clock.publish(PlaybackAnchor())
            try? capture.replaceOriginal(false)
        }
    }
    func pausePlayback() {
        queue.sync {
            wantsPlayback=false;player.pause();validClock=false
            capture.context?.clock.publish(PlaybackAnchor())
            try? capture.replaceOriginal(false)
        }
    }
    func resumePlayback() { queue.async { self.wantsPlayback=true;self.player.playImmediately(atRate:1) } }
    var snapshot:[String:Any] {
        queue.sync {
            var result=segments?.snapshot ?? [:]
            result["sourceFrames"]=capture.context?.history.published.load(ordering:.acquiring) ?? 0
            result["encodedFrames"]=cursor
            result["captureCallbacks"]=capture.context?.callbacks.load(ordering:.relaxed) ?? 0
            result["outputCallbacks"]=capture.context?.outputCallbacks.load(ordering:.relaxed) ?? 0
            result["capturedInputPeak"]=capture.context?.inputPeak.load(ordering:.relaxed) ?? 0
            result["localOutputRMS"]=capture.context?.localOutputRMS.load(ordering:.relaxed) ?? 0
            result["localFrameErrorMS"]=(capture.context?.localFrameError.load(ordering:.relaxed) ?? 0)/48
            result["capturedApplications"]=capture.appNames
            result["originalReplaced"]=capture.replaced
            result["mr4Enabled"]=alignmentRequested
            result["alignmentActivations"]=alignmentRecoveries
            result["playbackClockReady"]=validClock
            result["playbackFrame"]=playbackFrame
            result["automaticLatencyStatus"]=latencyFilter.status
            result["automaticLatencyEnabled"]=currentDeclaredLatency != nil
            result["playbackRecoveryAttempts"]=playbackRetries
            result["sourceActiveProcesses"]=sourceActiveProcesses
            result["sourcePaused"]=sourcePaused
            result["sourcePauseCommands"]=sourcePauses
            result["sourceTimelineResets"]=sourceTimelineResets
            result["sourceTimelineSeeking"]=timelineSeeking
            result["sourceTrackingEnabled"]=sourceProvider != nil
            if let measuredLatency { result["measuredSourceToPlaybackMS"]=measuredLatency*1000 }
            if let median=latencyFilter.medianSeconds { result["stableSourceToPlaybackMS"]=median*1000 }
            result["ioTiming"]=latestIO.dictionary(frequency:AudioGetHostClockFrequency())
            result["outputIOTiming"]=capture.context?.outputIOTiming.consume().dictionary(frequency:AudioGetHostClockFrequency()) ?? [:]
            result["encoderQueueMS"]=capture.context.map { Double($0.history.published.load(ordering:.acquiring)-cursor)/48 } ?? 0
            result["bufferedSeconds"]=capture.context.map { (Double($0.history.published.load(ordering:.acquiring))-playbackFrame)/48_000 } ?? 0
            if let http=server?.metrics {
                result["httpRequests"]=http.requests;result["httpBytes"]=http.bytes
                result["partialSegmentRequests"]=http.parts;result["fullSegmentRequests"]=http.fullSegments
                result["blockingReloadRequests"]=http.blockingReloads
            }
            result["cleanup"]=capture.lastCleanup
            result["error"]=errorText
            result["failureContext"]=failureContext
            result["memoryOnly"]=true
            return result
        }
    }
    func stop() {
        queue.sync {
            timer?.cancel();timer=nil
            wantsPlayback=false
            sourceObservers.removeAll();sourceListObserver=nil
            validClock=false
            alignmentRequested=false
            try? capture.replaceOriginal(false)
            capture.stop();segments?.stop()
        }
        server?.stop();server=nil
    }
    deinit { stop();pcm.deinitialize(count:4096);pcm.deallocate() }
}
