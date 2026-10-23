#if VANILLE_DIAGNOSTICS
import AppKit
import AudioToolbox
import CoreAudio
import Synchronization

/// Quiet native fixtures and independent per-device readback. No audio is retained.
final class ContinuityVerification: NSObject {
    let state:AppState
    let original:SavedState
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let toneID = "com.avanturation.Vanille.TestTone"
    private let otherID = "com.avanturation.Vanille.TestToneB"
    private let pulseID = "com.avanturation.Vanille.TestPulse"
    private var window:NSWindow!
    private let log = NSTextView()
    private var mode: NSPopUpButton!
    private var runButton:NSButton!
    private var probes:[OutputProbe] = []
    private var outputs:[OutputDevice] = []
    private var monitoringSequence:UInt64 = 0
    private var stages:[[String:Any]] = []
    private var originalDefault:AudioObjectID = 0
    private var originalSystemDefault:AudioObjectID = 0
    private var originalTapCount = 0, originalDeviceCount = 0
    private var timeout:DispatchWorkItem?
    private var running = false
    private var currentMode = "current"
    init(state:AppState) { self.state = state; original = state.saved; super.init() }
    func show() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:430),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Vanille Continuity Verification"; window.isReleasedWhenClosed = false
        let content = NSStackView(); content.orientation = .vertical; content.spacing = 10; content.alignment = .leading
        mode = NSPopUpButton(); mode.addItems(withTitles:["Current Output Group","AirPlay Only","Wired Only"])
        runButton = NSButton(title:"Run",target:self,action:#selector(run)); runButton.bezelStyle = .rounded
        let row = NSStackView(views:[mode,runButton]); row.spacing = 10
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = log
        log.isEditable = false; log.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        log.autoresizingMask = [.width]; log.frame = NSRect(x:0,y:0,width:680,height:350)
        content.addArrangedSubview(row); content.addArrangedSubview(scroll)
        UI.pin(content,to:window.contentView!,inset:16)
        scroll.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        window.center(); window.makeKeyAndOrderFront(nil)
        append("Measures continuous 1 kHz audio while a second app starts/stops and system alerts play.\nQuiet test tones only; other apps keep original audio. No samples are recorded.")
    }
    private func append(_ message:String) {
        log.textStorage?.append(NSAttributedString(string:message+"\n")); log.scrollToEndOfDocument(nil)
    }
    @objc private func run() {
        guard !running else { return }; running = true; runButton.isEnabled = false; mode.isEnabled = false
        currentMode = ["current","airplay","wired"][mode.indexOfSelectedItem]
        state.refresh()
        originalDefault = state.devices.defaultOutput(); originalSystemDefault = state.devices.defaultSystemOutput()
        let routes:[OutputDevice]
        if currentMode == "current" { routes = state.deviceRoutes.filter(\.enabled).compactMap { state.outputDevice(for:$0.id) } }
        else if currentMode == "airplay" { routes = Array(state.routingOutputs.filter(\.isAirPlay).prefix(1)) }
        else { routes = Array((state.routingOutputs.filter { $0.transport == kAudioDeviceTransportTypeUSB }+state.routingOutputs.filter { !$0.isAirPlay }).prefix(1)) }
        outputs = routes
        guard !routes.isEmpty else { append("Requested output is not connected."); finish(error:"No requested output"); return }
        state.audio.diagnostics.record("continuityTestBegin", "mode=\(currentMode) outputs=\(routes.count) mediaAndSystemSame=\(originalDefault == originalSystemDefault)")
        var paused = original; paused.processingPaused = true; paused.timingSound = false
        state.applyVerificationState(paused); state.audio.stopSynchronously()
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            self.originalTapCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
            self.originalDeviceCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
            self.openFixture("VanilleTestTone.app") { self.prepare() }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(error:"Test timeout") }
        self.timeout = timeout; DispatchQueue.main.asyncAfter(deadline:.now()+150,execute:timeout)
    }
    private func openFixture(_ name:String, completion:@escaping ()->Void) {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        NSWorkspace.shared.openApplication(at:root.appendingPathComponent("build/"+name),configuration:configuration) { _,error in
            DispatchQueue.main.async {
                if let error { self.finish(error:error.localizedDescription) }
                else { DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:completion) }
            }
        }
    }
    private func prepare() {
        state.refresh()
        var test = original
        for app in state.applications { test.applications[app.id] = AppVolume(bypass:app.id != toneID,name:app.name) }
        test.applications[toneID] = AppVolume(volume:0.7,name:"Continuity tone")
        test.applications[otherID] = AppVolume(volume:0.4,name:"Concurrent app")
        test.applications[pulseID] = AppVolume(volume:0.4,name:"Short effects")
        test.eq = EQSettings(enabled:true,gains:[0,0,0,0,0,3,0,0,0,0],autoHeadroom:false)
        test.processingPaused = false; test.timingSound = false
        let group = OutputGroup(id:"verification.continuity",name:"Continuity",devices:outputs.map { DeviceRoute(id:$0.uid,name:$0.name) })
        test.outputGroups.append(group); test.selectedGroupID = group.id
        state.applyVerificationState(test); waitForEngine(0)
    }
    private func waitForEngine(_ attempt:Int) {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            guard self.running else { return }
            if self.state.metrics.appIDs.contains(self.toneID) && self.state.metrics.running {
                do {
                    self.probes = self.outputs.map { _ in OutputProbe() }
                    for i in self.outputs.indices { try self.probes[i].start(deviceUID:self.outputs[i].uid,analysisSeconds:0.05) }
                    DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.beginMonitoring() }
                } catch { self.finish(error:error.localizedDescription) }
            } else if attempt<25 { self.waitForEngine(attempt+1) }
            else { self.finish(error:self.state.metrics.error ?? "No processing callback") }
        }
    }
    private func beginMonitoring() {
        guard running else { return }
        for probe in probes {
            let reference = probe.amplitude1000.load(ordering:.relaxed)
            guard reference>1e-5 else { finish(error:"No measurable carrier on an output"); return }
            probe.continuityReference.store(reference,ordering:.relaxed)
        }
        monitoringSequence = state.audio.diagnostics.snapshot().last?.sequence ?? 0
        state.audio.diagnostics.record("continuityMonitoringStart")
        append("Monitoring \(outputs.count) hardware output(s). EQ +3 dB and app gain 70% remain active.")
        perform(0)
    }
    private func perform(_ index:Int) {
        guard running else { return }
        guard index<12 else { finish(error:nil); return }
        let names = ["Second app starts","Second app exits","System alert","Short-effect process starts","Short-effect process exits","System alert"]
        let stage = index%6
        stages.append(["event":names[stage],"hostTime":mach_absolute_time()])
        state.audio.diagnostics.record("continuityStimulus", "index=\(index) \(names[stage])")
        append("\(index+1)/12 \(names[stage])")
        if stage==0 || stage==3 {
            openFixture(stage==0 ? "VanilleTestToneB.app" : "VanilleTestPulse.app") {
                DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { self.perform(index+1) }
            }
        } else {
            if stage==1 || stage==4 {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier:stage==1 ? otherID : pulseID) { app.terminate() }
            } else { AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert) }
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.perform(index+1) }
        }
    }
    private func finish(error:String?) {
        guard running else { return }; running = false; timeout?.cancel()
        for probe in probes { probe.continuityReference.store(0,ordering:.relaxed) }
        let timeline = state.audio.diagnostics.snapshot().filter { $0.sequence>monitoringSequence }
        let measurements = probes.map { probe -> [String:Any] in
            let minimum = probe.continuityMinimum.load(ordering:.relaxed)
            return ["minimumCarrierAmplitude":minimum.isFinite ? minimum : 0,"lowCarrierWindows":probe.continuityLowWindows.load(ordering:.relaxed),"analyzedWindows":probe.continuityWindows.load(ordering:.relaxed),"maximumReadbackCallbackGapMS":probe.continuityMaximumGapMS.load(ordering:.relaxed)]
        }
        let restarts = timeline.filter { $0.kind == "outputStreamStart" }.count
        let stops = timeline.filter { $0.kind == "outputStreamStop" }.count
        let mediaKept = state.devices.defaultOutput()==originalDefault
        let effectsKept = state.devices.defaultSystemOutput()==originalSystemDefault
        let signalPass = probes.count==outputs.count && !probes.isEmpty && probes.allSatisfy {
            $0.continuityWindows.load(ordering:.relaxed)>100 && $0.continuityLowWindows.load(ordering:.relaxed)==0 && $0.continuityMaximumGapMS.load(ordering:.relaxed)<40
        }
        let metrics = state.metrics
        var paused = state.saved; paused.processingPaused = true; paused.timingSound = false
        state.applyVerificationState(paused); state.audio.stopSynchronously()
        for probe in probes { probe.stop() }
        for id in [toneID,otherID,pulseID] { for app in NSRunningApplication.runningApplications(withBundleIdentifier:id) { app.terminate() } }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            let taps = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
            let devices = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
            let cleanup = taps==self.originalTapCount && devices==self.originalDeviceCount
            let eventsData = (try? JSONEncoder().encode(timeline)) ?? Data("[]".utf8)
            let events = (try? JSONSerialization.jsonObject(with:eventsData)) ?? []
            let report:[String:Any] = ["mode":self.currentMode,"date":ISO8601DateFormatter().string(from:Date()),"error":error ?? "","outputs":self.outputs.map { $0.isAirPlay ? "System AirPlay" : "Wired/physical" },"mediaAndSystemEffectsSameDevice":self.originalDefault==self.originalSystemDefault,"mediaDefaultUnchanged":mediaKept,"systemEffectsDefaultUnchanged":effectsKept,"outputRestartsDuringCarrier":restarts,"outputStopsDuringCarrier":stops,"signalPass":signalPass,"measurements":measurements,"events":events,"stimuli":self.stages,"engineCallbackGaps":metrics.callbackGaps,"maximumEngineCallbackGapMS":metrics.maximumCallbackGapMS,"inputBufferShortfalls":metrics.inputShortfalls,"outputSampleDiscontinuities":metrics.sampleDiscontinuities,"resourcesCleaned":cleanup,"allPassed":error==nil && signalPass && restarts==0 && stops==0 && mediaKept && effectsKept && cleanup,"scope":"Independent HAL stream readback of quiet native fixtures, with real system-alert requests. Not an acoustic measurement, actual messenger send or browser-video qualification."]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:self.root.appendingPathComponent("build/continuity-\(self.currentMode).json"),options:.atomic)
            }
            self.state.applyVerificationState(self.original)
            self.append("\(report["allPassed"] as? Bool == true ? "PASS" : "FAIL"): restarts=\(restarts), stops=\(stops), signal=\(signalPass), cleanup=\(cleanup). \(error ?? "")\nOriginal settings restored; fixtures stopped.")
        }
    }
}
#endif
