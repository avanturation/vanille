#if VANILLE_DIAGNOSTICS
import AppKit
import CoreAudio
import Synchronization

// An independent unmuted tap reads Vanille's actual HAL output. No samples are retained.
final class OutputProbe {
    let rms = Atomic<Double>(0)
    let callbacks = Atomic<UInt64>(0)
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var ioProc: AudioDeviceIOProcID?
    func start() throws {
        let own = try HAL.objects(HAL.system,kAudioHardwarePropertyProcessObjectList).filter {
            (try? HAL.read($0,kAudioProcessPropertyPID,default:pid_t(0))) == getpid()
        }
        guard !own.isEmpty else { throw AudioFailure(operation:"Vanille output process not found",status:-1) }
        let description = CATapDescription(stereoMixdownOfProcesses:own)
        description.name = "Vanille verification readback"; description.isPrivate = true; description.muteBehavior = .unmuted
        try HAL.check(AudioHardwareCreateProcessTap(description,&tap),"Create verification tap")
        let uid = try HAL.string(tap,kAudioTapPropertyUID)
        let dict: [String:Any] = [kAudioAggregateDeviceNameKey:"Vanille Verification",
            kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.verification.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey:true,
            kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:uid,kAudioSubTapDriftCompensationKey:true]],
            kAudioAggregateDeviceTapAutoStartKey:false]
        try HAL.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary,&aggregate),"Create verification input")
        try HAL.check(AudioDeviceCreateIOProcID(aggregate, { _,_,input,_,_,_,client in
            guard let client else { return noErr }
            let probe = Unmanaged<OutputProbe>.fromOpaque(client).takeUnretainedValue()
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
            var sum = 0.0; var samples = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize)/4, floats = data.assumingMemoryBound(to:Float.self)
                for i in 0..<count { let sample = Double(floats[i]); sum += sample*sample }
                samples += count
            }
            probe.rms.store(samples > 0 ? sqrt(sum/Double(samples)) : 0,ordering:.relaxed)
            probe.callbacks.wrappingAdd(1,ordering:.relaxed)
            return noErr
        },Unmanaged.passUnretained(self).toOpaque(),&ioProc),"Create verification reader")
        try HAL.check(AudioDeviceStart(aggregate,ioProc),"Start verification reader")
    }
    func stop() {
        if aggregate != 0, let ioProc { AudioDeviceStop(aggregate,ioProc); AudioDeviceDestroyIOProcID(aggregate,ioProc) }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
}

final class LiveVerification: NSObject {
    let state: AppState
    let original: SavedState
    let fixtureID = "com.avanturation.Vanille.TestTone"
    let probe = OutputProbe()
    let reportURL: URL
    let fixtureURL: URL
    var window: NSWindow!
    let log = NSTextView()
    var entries: [[String:Any]] = []
    var baseline = 0.0
    var finished = false
    var initialDefault: AudioObjectID = 0
    var initialTapCount = 0
    var initialDeviceCount = 0
    var timeout: DispatchWorkItem?
    init(state:AppState) {
        self.state = state; original = state.saved
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        reportURL = root.appendingPathComponent("build/live-audio-results.json")
        fixtureURL = root.appendingPathComponent("build/VanilleTestTone.app")
        super.init()
    }
    func run() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:570,height:350),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Vanille Audio Verification"; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = log
        log.isEditable = false; log.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        log.autoresizingMask = [.width]; log.frame = NSRect(x:0,y:0,width:550,height:340)
        window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil)
        append("Starting quiet native 1 kHz test tone (−46 dBFS).")
        append("No audio is recorded. Other apps are bypassed for this test.")
        initialDefault = state.devices.defaultOutput()
        initialTapCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
        initialDeviceCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at:fixtureURL,configuration:config) { [weak self] _,error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.append(error.localizedDescription); self.finish(); return }
                DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.prepare() }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.append("Timed out waiting for permission or an audio callback."); self.finish()
        }
        self.timeout = timeout; DispatchQueue.main.asyncAfter(deadline:.now()+100,execute:timeout)
    }
    private func append(_ text:String) {
        log.textStorage?.append(NSAttributedString(string:text+"\n")); log.scrollToEndOfDocument(nil)
        NSLog("Vanille verification: %@",text)
    }
    private func prepare() {
        guard !finished else { return }
        state.refresh()
        guard state.applications.contains(where: { $0.id == fixtureID }) else {
            append("Waiting for the test tone process…")
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.prepare() }; return
        }
        var test = original
        for app in state.applications { test.applications[app.id] = AppVolume(bypass:app.id != fixtureID,name:app.name) }
        test.applications[fixtureID] = AppVolume(name:"Vanille Test Tone")
        test.processingPaused = false; test.eq = EQSettings()
        state.applyVerificationState(test)
        append("Waiting for the processing callback. macOS may request System Audio Recording permission.")
        waitForEngine(attempt:0)
    }
    private func waitForEngine(attempt:Int) {
        guard !finished else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            guard !self.finished else { return }
            if self.state.metrics.running, self.state.metrics.appIDs.contains(self.fixtureID) {
                do { try self.probe.start(); self.append("Processing and independent output readback started."); self.stage(0) }
                catch { self.append("Readback failed: \(error.localizedDescription)"); self.finish() }
            } else if attempt < 55 {
                if attempt % 5 == 4 { self.state.applyVerificationState(self.state.saved) }
                self.waitForEngine(attempt:attempt+1)
            } else { self.append(self.state.metrics.error ?? "No callback received."); self.finish() }
        }
    }
    private var stages: [(String,Double)] { [
        ("Original level",1), ("70% app volume",0.7), ("0% app volume",0), ("App mute",0),
        ("1 kHz EQ +6 dB",pow(10,6/20.0)), ("50% volume with +6 dB EQ",0.5*pow(10,6/20.0)),
        ("EQ off at 50% volume",0.5), ("Processing paused",0)
    ] }
    private func stage(_ index:Int) {
        guard !finished else { return }
        guard index < stages.count else { finish(); return }
        var test = state.saved; test.applications[fixtureID]!.muted = false
        switch index {
        case 0: break
        case 1: test.applications[fixtureID]!.volume = 0.7
        case 2: test.applications[fixtureID]!.volume = 0
        case 3: test.applications[fixtureID]!.volume = 1; test.applications[fixtureID]!.muted = true
        case 4: test.applications[fixtureID]!.volume = 1; test.eq.enabled = true; test.eq.autoHeadroom = false; test.eq.gains[5] = 6
        case 5: test.applications[fixtureID]!.volume = 0.5
        case 6: test.eq.enabled = false
        case 7: test.processingPaused = true
        default: break
        }
        state.applyVerificationState(test)
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { self.measure(index:index,values:[],remaining:8) }
    }
    private func measure(index:Int,values:[Double],remaining:Int) {
        guard !finished else { return }
        let samples = values + [probe.rms.load(ordering:.relaxed)]
        if remaining > 1 {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.measure(index:index,values:samples,remaining:remaining-1) }; return
        }
        let measured = samples.reduce(0,+)/Double(samples.count)
        if index == 0 { baseline = measured }
        let ratio = baseline > 1e-8 ? measured/baseline : -1, expected = stages[index].1
        let pass = baseline > 1e-5 && abs(ratio-expected) < (expected == 0 ? 0.002 : 0.06)
        entries.append(["test":stages[index].0,"passed":pass,"readbackRMS":measured,"ratio":ratio,"expectedRatio":expected,
            "engineInputRMS":state.metrics.inputRMS,"engineOutputRMS":state.metrics.outputRMS,
            "engineCallbacks":state.metrics.callbacks,"probeCallbacks":probe.callbacks.load(ordering:.relaxed)])
        append(String(format:"%@  %@ · output ratio %.4f (expected %.4f)",pass ? "PASS" : "FAIL",stages[index].0,ratio,expected))
        stage(index+1)
    }
    private func finish() {
        guard !finished else { return }; finished = true; timeout?.cancel()
        probe.stop(); state.audio.stopSynchronously()
        // HAL publishes object removal asynchronously. Check after a control-cycle grace period.
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.completeReport() }
    }
    private func completeReport() {
        let defaultKept = state.devices.defaultOutput() == initialDefault
        let tapCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
        let deviceCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
        entries.append(["test":"Default output unchanged","passed":defaultKept])
        entries.append(["test":"No leaked process taps","passed":tapCount == initialTapCount,"before":initialTapCount,"after":tapCount])
        entries.append(["test":"No leaked aggregate devices","passed":deviceCount == initialDeviceCount,"before":initialDeviceCount,"after":deviceCount])
        for app in NSRunningApplication.runningApplications(withBundleIdentifier:fixtureID) { app.terminate() }
        state.applyVerificationState(original)
        let report: [String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),"system":ProcessInfo.processInfo.operatingSystemVersionString,
            "output":state.output?.name ?? "None","sampleRate":state.output?.sampleRate ?? 0,
            "measurements":entries,"allPassed":entries.count == 11 && entries.allSatisfy { $0["passed"] as? Bool == true },
            "method":"Unmuted process tap independently reads Vanille HAL output. No audio samples are retained."]
        do { let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); try data.write(to:reportURL,options:.atomic)
            append("Report saved: \(reportURL.path)")
        } catch { append("Could not save report: \(error.localizedDescription)") }
        append("Original settings restored. Test tone stopped.")
    }
    deinit { probe.stop() }
}
#endif
