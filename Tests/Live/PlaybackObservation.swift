#if VANILLE_DIAGNOSTICS
import AppKit
import CoreAudio
import AudioToolbox
import Synchronization

/// Observes an actual player without replacing its settings, audio or video path.
final class PlaybackObservation:NSObject {
    let state:AppState
    private let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var window:NSWindow!
    private var apps:NSPopUpButton!
    private let log = NSTextView()
    private var timer:Timer?
    private var probes:[OutputProbe] = []
    private var baseline = EngineMetrics()
    private var processes:[AudioObjectID] = []
    private var beginSequence:UInt64 = 0
    private var seconds = 0
    private var targetName = ""
    private var finalizing = false
    private var samplePoints:[[String:Any]] = []
    init(state:AppState) { self.state = state; super.init() }
    func show() {
        state.refresh()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:360),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Vanille Playback Observation"; window.isReleasedWhenClosed = false
        apps = NSPopUpButton()
        for app in state.applications where state.isControlled(app.id) {
            apps.addItem(withTitle:app.name); apps.lastItem?.representedObject = app.id
        }
        if apps.itemTitles.contains("Safari") { apps.selectItem(withTitle:"Safari") }
        let start = NSButton(title:"Observe 3 Minutes",target:self,action:#selector(run)); start.bezelStyle = .rounded
        start.isEnabled = apps.numberOfItems>0
        let row = NSStackView(views:[apps,start]); row.spacing = 8
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = log
        log.isEditable = false; log.font = .monospacedSystemFont(ofSize:11,weight:.regular); log.autoresizingMask = [.width]
        log.frame = NSRect(x:0,y:0,width:610,height:280)
        let body = UI.vertical([row,scroll]); UI.pin(body,to:window.contentView!,inset:16)
        scroll.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true
        window.center(); window.makeKeyAndOrderFront(nil)
        append("Keep the selected app playing. Settings and the original video path stay in use.\nReal system alerts and repeated quiet transient app launches are requested. No samples, URLs or video frames are saved.")
    }
    private func append(_ text:String) { log.textStorage?.append(NSAttributedString(string:text+"\n")); log.scrollToEndOfDocument(nil) }
    @objc private func run(_ sender:NSButton) {
        guard timer==nil, let id = apps.selectedItem?.representedObject as? String,
              let app = state.applications.first(where: { $0.id==id }), state.isControlled(id) else { return }
        processes = app.processes; targetName = app.name; apps.isEnabled = false; sender.isEnabled = false
        do {
            let outputs = state.outputs.filter { state.metrics.outputUIDs.contains($0.uid) }
            guard !outputs.isEmpty else { append("No active processed output."); return }
            probes = outputs.map { _ in OutputProbe() }
            for i in outputs.indices { try probes[i].start(deviceUID:outputs[i].uid) }
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [self] in
                self.baseline = self.state.metrics
                self.beginSequence = self.state.audio.diagnostics.snapshot().last?.sequence ?? 0
                self.state.audio.diagnostics.record("playbackObservationBegin","outputs=\(outputs.count)")
                let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer,forMode:.common); self.timer = timer
                self.append("Observing \(self.targetName) through \(outputs.count) real output(s).")
            }
        } catch { append(error.localizedDescription); for probe in probes { probe.stop() } }
    }
    private func tick() {
        seconds += 1
        let m = state.metrics
        samplePoints.append(["second":seconds,"callbacks":m.callbacks,"frames":m.sampleFrames,"rms":probes.map { $0.rms.load(ordering:.relaxed) },
            "queuedFrames":processes.map { m.processQueuedFrames[$0] ?? [] },
            "sourceUnderruns":processes.map { m.processUnderruns[$0] ?? 0 },"sourceOverruns":processes.map { m.processOverruns[$0] ?? 0 }])
        if [5,25,55,85,115,145,175].contains(seconds) {
            state.audio.diagnostics.record("playbackObservationAlert"); AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }
        if [12,62,122].contains(seconds) {
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            NSWorkspace.shared.openApplication(at:root.appendingPathComponent("build/VanilleTestTransient.app"),configuration:config) { _,_ in }
            state.audio.diagnostics.record("playbackObservationTransientStart")
        }
        if [15,65,125].contains(seconds) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier:"com.avanturation.Vanille.TestTransient") { app.terminate() }
        }
        if seconds%30==0 { append("\(seconds)s: output callbacks=\(m.callbacks), gaps=\(m.callbackGaps), original player path in use.") }
        if seconds>=180 { finish() }
    }
    private func finish() {
        guard !finalizing else { return }; finalizing = true; timer?.invalidate(); timer = nil
        let m = state.metrics
        let events = state.audio.diagnostics.snapshot().filter { $0.sequence>beginSequence }
        let restarts = events.filter { $0.kind=="outputStreamStart" || $0.kind=="outputStreamStop" }.count
        let present = processes.allSatisfy { m.processUnderruns[$0] != nil }
        let carrierOK = present && processes.allSatisfy {
            m.processUnderruns[$0]==baseline.processUnderruns[$0] && m.processOverruns[$0]==baseline.processOverruns[$0]
                && m.processCaptureGaps[$0]==baseline.processCaptureGaps[$0]
        }
        let outputOK = m.callbackGaps==baseline.callbackGaps && m.sampleDiscontinuities==baseline.sampleDiscontinuities && restarts==0
        let signal = samplePoints.contains { ($0["rms"] as? [Double])?.allSatisfy({ $0>1e-6 }) == true }
        func median(_ values:[UInt64]) -> Double {
            let values = values.sorted(); return values.isEmpty ? 0 : Double(values[values.count/2])
        }
        var driftFrames:[Double] = [], driftOK = true
        for index in processes.indices {
            let queued = samplePoints.compactMap { point -> [UInt64]? in
                guard let list = point["queuedFrames"] as? [[UInt64]], list.indices.contains(index), list[index].count>=4 else { return nil }
                return list[index]
            }
            guard queued.count>=60 else { driftOK = false; continue }
            let difference = median(Array(queued.suffix(30)).map { $0[3] })-median(Array(queued.prefix(30)).map { $0[3] })
            let quantum = queued.map { $0[2] }.max() ?? 0
            driftFrames.append(difference)
            if quantum==0 || abs(difference)>Double(quantum*2) { driftOK = false }
        }
        for probe in probes { probe.stop() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = (try? encoder.encode(events)) ?? Data("[]".utf8)
        let report:[String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),"player":targetName,"durationSeconds":seconds,"signalReadBack":signal,
            "outputLifecycleEvents":restarts,"originalCaptureProcessesPresent":present,"carrierContinuous":carrierOK,"outputClockContinuous":outputOK,
            "allPassed":carrierOK && outputOK && signal && driftOK,"queueDriftFrames":driftFrames,"queueDriftWithinTwoQuanta":driftOK,"samples":samplePoints,"events":(try? JSONSerialization.jsonObject(with:encoded)) ?? [],
            "scope":"Live original player, independent HAL stream readback and per-process ring/clock counters. No video frames, URLs or audio samples retained. No acoustic A/V judgment." ]
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("build/playback-observation.json"),options:.atomic)
        }
        append("\(report["allPassed"] as? Bool == true ? "PASS" : "FAIL"): output lifecycle=\(restarts), carrier=\(carrierOK), output clock=\(outputOK).")
    }
    deinit { timer?.invalidate(); for probe in probes { probe.stop() } }
}
#endif
