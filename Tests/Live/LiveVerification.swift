#if VANILLE_DIAGNOSTICS
import AppKit
import CoreAudio
import Synchronization

// An independent unmuted tap reads Vanille's actual HAL output. No samples are retained.
final class OutputProbe {
    let rms = Atomic<Double>(0)
    let callbacks = Atomic<UInt64>(0)
    let amplitude1000 = Atomic<Double>(0)
    let amplitude440 = Atomic<Double>(0)
    let lastPulseEdge = Atomic<Double>(0)
    private var pulseEnergy = 0.0, pulseFrames = 0, pulseWasHigh = false
    private var sampleRate = 48_000.0, secondsPerTick = 1e-9
    private var c1 = 0.0, c2 = 0.0
    private var s11 = 0.0, s12 = 0.0, s21 = 0.0, s22 = 0.0
    private var windowFrames = 9600, frameCount = 0
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var ioProc: AudioDeviceIOProcID?
    func start(deviceUID:String? = nil,stream:Int = 0,analysisSeconds:Double = 0.2) throws {
        let own = try HAL.objects(HAL.system,kAudioHardwarePropertyProcessObjectList).filter {
            (try? HAL.read($0,kAudioProcessPropertyPID,default:pid_t(0))) == getpid()
        }
        guard !own.isEmpty else { throw AudioFailure(operation:"Vanille output process not found",status:-1) }
        let description:CATapDescription
        if let deviceUID { description = CATapDescription(processes:own,deviceUID:deviceUID,stream:UInt(stream)) }
        else { description = CATapDescription(stereoMixdownOfProcesses:own) }
        description.name = "Vanille verification readback"; description.isPrivate = true; description.muteBehavior = .unmuted
        try HAL.check(AudioHardwareCreateProcessTap(description,&tap),"Create verification tap")
        let uid = try HAL.string(tap,kAudioTapPropertyUID)
        let format = try HAL.read(tap,kAudioTapPropertyFormat,default:AudioStreamBasicDescription())
        sampleRate = format.mSampleRate
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer)/Double(timebase.denom)*1e-9
        windowFrames = Int((format.mSampleRate*analysisSeconds).rounded())
        c1 = 2*cos(2*Double.pi*1000/format.mSampleRate); c2 = 2*cos(2*Double.pi*440/format.mSampleRate)
        let dict: [String:Any] = [kAudioAggregateDeviceNameKey:"Vanille Verification",
            kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.verification.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey:true,
            kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:uid,kAudioSubTapDriftCompensationKey:true]],
            kAudioAggregateDeviceTapAutoStartKey:false]
        try HAL.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary,&aggregate),"Create verification input")
        try HAL.check(AudioDeviceCreateIOProcID(aggregate, { _,_,input,time,_,_,client in
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
            if let buffer = buffers.first, let data = buffer.mData, buffer.mNumberChannels > 0 {
                let floats = data.assumingMemoryBound(to:Float.self), channels = Int(buffer.mNumberChannels)
                for frame in 0..<(Int(buffer.mDataByteSize)/(4*channels)) {
                    let sample = Double(floats[frame*channels]); probe.analyze(sample)
                    probe.analyzePulse(sample,time:Double(time.pointee.mHostTime)*probe.secondsPerTick+Double(frame)/probe.sampleRate)
                }
            }
            probe.callbacks.wrappingAdd(1,ordering:.relaxed)
            return noErr
        },Unmanaged.passUnretained(self).toOpaque(),&ioProc),"Create verification reader")
        try HAL.check(AudioDeviceStart(aggregate,ioProc),"Start verification reader")
    }
    @inline(__always) private func analyzePulse(_ sample:Double,time:Double) {
        pulseEnergy += sample*sample; pulseFrames += 1
        if pulseFrames >= Int(sampleRate*0.005) {
            let high = sqrt(pulseEnergy/Double(pulseFrames))>0.0001
            if high && !pulseWasHigh { lastPulseEdge.store(time,ordering:.relaxed) }
            pulseWasHigh = high; pulseFrames = 0; pulseEnergy = 0
        }
    }
    @inline(__always) private func analyze(_ sample:Double) {
        let x1 = sample+c1*s11-s12; s12 = s11; s11 = x1
        let x2 = sample+c2*s21-s22; s22 = s21; s21 = x2
        frameCount += 1
        if frameCount == windowFrames {
            amplitude1000.store(2*sqrt(max(0,s11*s11+s12*s12-c1*s11*s12))/Double(windowFrames),ordering:.relaxed)
            amplitude440.store(2*sqrt(max(0,s21*s21+s22*s22-c2*s21*s22))/Double(windowFrames),ordering:.relaxed)
            frameCount = 0; s11 = 0; s12 = 0; s21 = 0; s22 = 0
        }
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
    var baselineA = 0.0, baselineB = 0.0
    let secondID = "com.avanturation.Vanille.TestToneB"
    var finished = false
    var initialDefault: AudioObjectID = 0
    var initialTapCount = 0
    var initialDeviceCount = 0
    var configuredOutputCount = 0
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
        var paused = original; paused.processingPaused = true; paused.timingSound = false
        state.applyVerificationState(paused); state.audio.stopSynchronously()
        // Measure an idle baseline, excluding the user's pre-test engine. HAL removes objects asynchronously.
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [self] in
            guard !self.finished else { return }
            self.initialTapCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
            self.initialDeviceCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            NSWorkspace.shared.openApplication(at:self.fixtureURL,configuration:config) { [weak self] _,error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error { self.append(error.localizedDescription); self.finish(); return }
                    DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.prepare() }
                }
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
        // Exercise the user's actual route, including the restored wired + AirPlay
        // clock. Do not silently replace it with an AirPlay-only aggregate.
        if let i = test.outputGroups.firstIndex(where: { $0.id == test.selectedGroupID }) {
            for j in test.outputGroups[i].devices.indices {
                test.outputGroups[i].devices[j].volume = 1
                test.outputGroups[i].devices[j].muted = false
            }
        }
        test.deviceSettings = [:]
        configuredOutputCount = state.deviceRoutes.filter { $0.enabled && state.outputDevice(for:$0.id) != nil }.count
        append("Testing the current route (\(configuredOutputCount) configured output(s)).")
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
                if attempt == 4 {
                    let fixture = self.state.applications.first { $0.id == self.fixtureID }
                    let usesDefault = self.state.output.map { fixture?.outputDevices.contains($0.id) == true } ?? false
                    self.append("Fixture uses current default: \(usesDefault). Engine status: \(self.state.metrics.error ?? self.state.statusText)")
                }
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
        guard index < stages.count else { beginMultipleApps(); return }
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
    private func beginMultipleApps() {
        append("Testing independent control of two simultaneous applications…")
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at:fixtureURL.deletingLastPathComponent().appendingPathComponent("VanilleTestToneB.app"),configuration:config) { _,error in
            DispatchQueue.main.async {
                if let error { self.append(error.localizedDescription); self.finish(); return }
                DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.multiStage(0) }
            }
        }
    }
    private func multiStage(_ index:Int) {
        guard !finished else { return }
        guard index < 6 else { finish(); return }
        state.refresh()
        var test = state.saved
        if index == 0 {
            test.eq = EQSettings(); test.processingPaused = false
            test.applications[fixtureID] = AppVolume(name:"Vanille Test Tone")
            test.applications[secondID] = AppVolume(name:"Vanille Test Tone B")
        }
        if index == 1 { test.applications[fixtureID]!.volume = 0.3 }
        if index == 2 { test.applications[secondID]!.muted = true }
        if index == 3 {
            test.applications[secondID]!.muted = false
            test.eq.enabled = true; test.eq.autoHeadroom = false; test.eq.gains[5] = 6
        }
        if index == 4 { test.applications[fixtureID]!.bypass = true }
        if index == 5 {
            test.applications[fixtureID]!.bypass = false; test.applications[fixtureID]!.volume = 1
            test.eq = EQSettings()
            for app in NSRunningApplication.runningApplications(withBundleIdentifier:secondID) { app.terminate() }
        }
        state.applyVerificationState(test)
        DispatchQueue.main.asyncAfter(deadline:.now()+3) {
            let a = self.probe.amplitude1000.load(ordering:.relaxed), b = self.probe.amplitude440.load(ordering:.relaxed)
            if index == 0 { self.baselineA = a; self.baselineB = b }
            let ratioA = self.baselineA > 1e-6 ? a/self.baselineA : -1
            let ratioB = self.baselineB > 1e-6 ? b/self.baselineB : -1
            let eqB = BiquadCoefficients.peak(frequency:1000,gain:6,sampleRate:self.state.output?.sampleRate ?? 48_000).magnitude(at:440,sampleRate:self.state.output?.sampleRate ?? 48_000)
            let expectedA = [1.0,0.3,0.3,0.3*pow(10,6/20.0),0,1][index]
            let expectedB = [1.0,1,0,eqB,eqB,0][index]
            let names = ["Two simultaneous apps", "Independent app volume", "Independent app mute", "Global EQ over two apps", "Protected Content Bypass path", "Recovery after audio process exit"]
            let pass = self.baselineA > 1e-5 && self.baselineB > 1e-5 && abs(ratioA-expectedA)<0.06 && abs(ratioB-expectedB)<0.06
            self.entries.append(["test":names[index],"passed":pass,"ratioA":ratioA,"ratioB":ratioB,"expectedA":expectedA,"expectedB":expectedB,
                "activeAppCount":self.state.metrics.appIDs.count,"engineCallbacks":self.state.metrics.callbacks])
            self.append(String(format:"%@  %@ · A %.4f / B %.4f",pass ? "PASS" : "FAIL",names[index],ratioA,ratioB))
            self.multiStage(index+1)
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true; timeout?.cancel()
        var paused = state.saved; paused.processingPaused = true
        state.applyVerificationState(paused)
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
        for app in NSRunningApplication.runningApplications(withBundleIdentifier:secondID) { app.terminate() }
        state.applyVerificationState(original)
        let report: [String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),"system":ProcessInfo.processInfo.operatingSystemVersionString,
            "output":state.output?.name ?? "None","sampleRate":state.output?.sampleRate ?? 0,"configuredOutputCount":configuredOutputCount,
            "measurements":entries,"allPassed":entries.count == 17 && entries.allSatisfy { $0["passed"] as? Bool == true },
            "method":"Unmuted process tap independently reads Vanille HAL output. No audio samples are retained."]
        do { let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); try data.write(to:reportURL,options:.atomic)
            append("Report saved: \(reportURL.path)")
        } catch { append("Could not save report: \(error.localizedDescription)") }
        append("Original settings restored. Test tone stopped.")
    }
    deinit { probe.stop() }
}

/// Signal readback from each real aggregate output stream. This does not measure sound in the room.
final class RoutingVerification:NSObject {
    let state:AppState
    let original:SavedState
    let fixtureID = "com.avanturation.Vanille.TestPulse"
    let probes = [OutputProbe(),OutputProbe()]
    let combinedProbe = OutputProbe()
    let log = NSTextView()
    var window:NSWindow!
    var entries:[[String:Any]] = []
    var baseline = [0.0,0.0], baselineDelay = 0.0
    var finished = false
    var initialDefault:AudioObjectID = 0, initialTapCount = 0, initialDeviceCount = 0
    var outputs:[OutputDevice] = []
    var timeout:DispatchWorkItem?
    private var stoppedProbeCallbacks:[UInt64] = []
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    init(state:AppState) { self.state = state; original = state.saved; super.init() }
    private func append(_ text:String) { log.textStorage?.append(NSAttributedString(string:text+"\n")); log.scrollToEndOfDocument(nil); NSLog("Vanille routing verification: %@",text) }
    func run() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:360),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Vanille Multi-Output Verification"; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = log
        log.isEditable = false; log.font = .monospacedSystemFont(ofSize:11,weight:.regular); log.autoresizingMask = [.width]; log.frame = NSRect(x:0,y:0,width:630,height:350)
        window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil)
        state.refresh()
        guard let wired = state.routingOutputs.first(where: { $0.transport == kAudioDeviceTransportTypeUSB }),
              let airplay = state.routingOutputs.first(where: { $0.isAirPlay }) else { append("Connect a wired output and one system AirPlay output first."); return }
        outputs = [wired,airplay]
        initialDefault = state.devices.defaultOutput()
        var paused = original; paused.processingPaused = true; paused.timingSound = false
        state.applyVerificationState(paused); state.audio.stopSynchronously()
        append("Testing two real outputs: \(wired.name) + \(airplay.name).")
        append("Quiet 100 ms pulses; no samples are recorded. Speaker acoustics are not measured.")
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            guard !self.finished else { return }
            self.initialTapCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
            self.initialDeviceCount = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            NSWorkspace.shared.openApplication(at:self.root.appendingPathComponent("build/VanilleTestPulse.app"),configuration:config) { _,error in
                DispatchQueue.main.async {
                    if let error { self.append(error.localizedDescription); self.finish(); return }
                    DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.prepare() }
                }
            }
        }
        let t = DispatchWorkItem { [weak self] in guard let self, !self.finished else { return }; self.append("Routing verification timed out."); self.finish() }
        timeout = t; DispatchQueue.main.asyncAfter(deadline:.now()+150,execute:t)
    }
    private func prepare() {
        guard !finished else { return }; state.refresh()
        guard state.applications.contains(where: { $0.id == fixtureID }) else { DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.prepare() }; return }
        var test = original
        for app in state.applications { test.applications[app.id] = AppVolume(bypass:app.id != fixtureID,name:app.name) }
        test.applications[fixtureID] = AppVolume(name:"Vanille Test Pulse")
        test.eq = EQSettings(); test.processingPaused = false
        test.manualTimingForVerification = true
        let group = OutputGroup(id:"verification.two-output",name:"Verification",devices:outputs.map { DeviceRoute(id:$0.uid,name:$0.name) })
        test.outputGroups.append(group); test.selectedGroupID = group.id
        state.applyVerificationState(test); waitForEngine(0)
    }
    private func waitForEngine(_ attempt:Int) {
        guard !finished else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            guard !self.finished else { return }
            if self.state.metrics.running && self.state.metrics.outputUIDs.count == 2 {
                do {
                    for i in 0..<2 { try self.probes[i].start(deviceUID:self.outputs[i].uid,stream:0,analysisSeconds:1) }
                    try self.combinedProbe.start(analysisSeconds:1)
                    self.append("Independent taps opened on physical output devices; combined process tap also active."); self.stage(0)
                } catch { self.append("Stream readback failed: \(error.localizedDescription)"); self.finish() }
            } else if attempt<30 { self.waitForEngine(attempt+1) }
            else { self.append(self.state.metrics.error ?? "Two-output engine did not start."); self.finish() }
        }
    }
    private func phaseDifference() -> Double {
        let a = probes[0].lastPulseEdge.load(ordering:.relaxed), b = probes[1].lastPulseEdge.load(ordering:.relaxed)
        var d = (b-a).truncatingRemainder(dividingBy:1)
        if d>0.5 { d -= 1 }; if d < -0.5 { d += 1 }; return d
    }
    private func stage(_ index:Int) {
        guard !finished else { return }
        guard index<6 else { beginTimingSoundCheck(); return }
        var test = state.saved
        let g = test.outputGroups.firstIndex { $0.id == "verification.two-output" }!
        if index==1 { test.outputGroups[g].devices[0].volume = 0.3 }
        if index==2 { test.outputGroups[g].devices[1].muted = true }
        if index==3 { test.outputGroups[g].devices[1].muted = false; test.outputGroups[g].devices[0].volume = 1; test.outputGroups[g].devices[1].delayMS = 120 }
        if index==4 { test.eq.enabled = true; test.eq.autoHeadroom = false; test.eq.gains[5] = 6 }
        if index==5 { test.processingPaused = true }
        state.applyVerificationState(test)
        // Two pulse periods give both readers a fresh edge and steady Goertzel window.
        DispatchQueue.main.asyncAfter(deadline:.now()+3.5) { self.measure(index:index,values:[],remaining:15) }
    }
    private func measure(index:Int,values:[[Double]],remaining:Int) {
        guard !finished else { return }
        let values = values + [probes.map { $0.amplitude1000.load(ordering:.relaxed) }]
        if remaining>1 { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.measure(index:index,values:values,remaining:remaining-1) }; return }
        // One full pulse period per spectral window keeps amplitude independent of pulse phase.
        let measured = (0..<2).map { i in values.map { $0[i] }.max() ?? 0 }
        if index==0 { baseline = measured; baselineDelay = phaseDifference() }
        let ratios = (0..<2).map { baseline[$0]>1e-7 ? measured[$0]/baseline[$0] : -1 }
        let boost = pow(10,6/20.0)
        let expected = [[1.0,1.0],[0.3,1],[0.3,0],[1,1],[boost,boost],[0,0]][index]
        let delay = phaseDifference()-baselineDelay
        let delayOK = index != 3 || abs(delay-0.120)<0.018
        let pass = zip(ratios,expected).allSatisfy { abs($0-$1)<0.13 } && baseline.allSatisfy { $0>1e-5 } && delayOK
        let name = ["Two hardware streams carry the same signal","Independent wired output volume","Independent AirPlay output mute","120 ms output delay","Global EQ on both output streams","Pause restores original path"][index]
        entries.append(["test":name,"passed":pass,"ratios":ratios,"expected":expected,"relativeDelayMS":delay*1000,"engineCallbacks":state.metrics.callbacks,"outputCount":state.metrics.outputUIDs.count,
            "readbackAmplitudes":measured,"probeCallbacks":probes.map { $0.callbacks.load(ordering:.relaxed) },"combinedAmplitude":combinedProbe.amplitude1000.load(ordering:.relaxed),"engineInputRMS":state.metrics.inputRMS,"engineOutputRMS":state.metrics.outputRMS])
        append(String(format:"%@ %@ · wired %.3f / AirPlay %.3f · delay %.1f ms",pass ? "PASS" : "FAIL",name,ratios[0],ratios[1],delay*1000))
        stage(index+1)
    }
    private func beginTimingSoundCheck() {
        append("Verifying the built-in timing sound with no captured applications…")
        for p in probes { p.stop() }; combinedProbe.stop()
        var test = state.saved
        for app in state.applications { test.applications[app.id] = AppVolume(bypass:true,name:app.name) }
        let g = test.outputGroups.firstIndex { $0.id == "verification.two-output" }!
        for i in test.outputGroups[g].devices.indices {
            test.outputGroups[g].devices[i].volume = 1; test.outputGroups[g].devices[i].muted = false; test.outputGroups[g].devices[i].delayMS = 0
        }
        test.eq = EQSettings(); test.processingPaused = false; test.timingSound = true
        state.applyVerificationState(test); waitForTimingSound(0)
    }
    private func waitForTimingSound(_ attempt:Int) {
        guard !finished else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            guard !self.finished else { return }
            if self.state.metrics.running && self.state.metrics.appIDs.isEmpty {
                do {
                    for i in 0..<2 { try self.probes[i].start(deviceUID:self.outputs[i].uid,analysisSeconds:4) }
                    self.timingSoundStage(0)
                } catch { self.append(error.localizedDescription); self.finish() }
            } else if attempt<12 { self.waitForTimingSound(attempt+1) }
            else { self.append(self.state.metrics.error ?? "Timing sound engine did not start."); self.finish() }
        }
    }
    private func timingSoundStage(_ index:Int) {
        guard !finished else { return }
        guard index<4 else { finish(); return }
        if index>0 {
            var test = state.saved
            let g = test.outputGroups.firstIndex { $0.id == "verification.two-output" }!
            if index==1 { test.outputGroups[g].devices[1].delayMS = 400 }
            else if index==2 { test.manualTimingForVerification = false }
            else { test.timingSound = false; test.processingPaused = true }
            state.applyVerificationState(test)
            if index == 3 {
                // A process tap can stop delivering callbacks when its source stops.
                // Its last spectral value is then held, not a new audible signal.
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                    self.stoppedProbeCallbacks = self.probes.map { $0.callbacks.load(ordering:.relaxed) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+9) {
            guard !self.finished else { return }
            let amplitudes = self.probes.map { $0.amplitude1000.load(ordering:.relaxed) }
            let a = self.probes[0].lastPulseEdge.load(ordering:.relaxed), b = self.probes[1].lastPulseEdge.load(ordering:.relaxed)
            var phase = (b-a).truncatingRemainder(dividingBy:4)
            if phase>2 { phase -= 4 }; if phase < -2 { phase += 4 }
            if index==0 { self.baselineDelay = phase }
            let delay = phase-self.baselineDelay
            let pass:Bool
            if index==0 { pass = amplitudes.allSatisfy { $0>0.0001 } && self.state.metrics.appIDs.isEmpty }
            else if index==1 { pass = abs(delay-0.4)<0.018 && amplitudes.allSatisfy { $0>0.0001 } }
            else if index==2 {
                let offsets = LatencyAlignment.offsets(self.outputs.map(\.reportedLatencyMS)) ?? []
                let expected = offsets.count == 2 ? (offsets[1]-offsets[0])/1000 : 99
                pass = abs(delay-expected)<0.018 && amplitudes.allSatisfy { $0>0.0001 }
            } else {
                let callbacks = self.probes.map { $0.callbacks.load(ordering:.relaxed) }
                pass = self.stoppedProbeCallbacks.count == self.probes.count && !self.state.metrics.running
                    && callbacks.indices.allSatisfy { i in
                        callbacks[i] == self.stoppedProbeCallbacks[i] || amplitudes[i]<1e-8
                    }
            }
            let name = ["Built-in timing sound without application capture","Timing sound applies 400 ms per-device offset","Automatic device timing changes actual output without user delay settings","Timing sound stops safely"][index]
            var entry:[String:Any] = ["test":name,"passed":pass,"amplitudes":amplitudes,"relativeDelayMS":delay*1000,"capturedApplications":self.state.metrics.appIDs.count,"appliedOutputDelaysMS":self.state.metrics.outputDelayMS]
            if index == 3 {
                entry["engineRunning"] = self.state.metrics.running
                entry["probeCallbacksAfterSettling"] = self.stoppedProbeCallbacks
                entry["probeCallbacksAtEnd"] = self.probes.map { $0.callbacks.load(ordering:.relaxed) }
                entry["observation"] = "No callbacks after settling means the source stream stopped; spectral values are held. Continuing callbacks must report silence after two analysis windows."
            }
            self.entries.append(entry)
            self.append(String(format:"%@ %@ · relative delay %.1f ms",pass ? "PASS" : "FAIL",name,delay*1000))
            self.timingSoundStage(index+1)
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true; timeout?.cancel()
        var paused = state.saved; paused.processingPaused = true; state.applyVerificationState(paused)
        for p in probes { p.stop() }; combinedProbe.stop(); state.audio.stopSynchronously()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier:fixtureID) { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            let taps = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTapList)) ?? []).count
            let devices = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).count
            self.entries.append(["test":"Default system output unchanged","passed":self.state.devices.defaultOutput() == self.initialDefault])
            self.entries.append(["test":"No leaked tap or aggregate","passed":taps == self.initialTapCount && devices == self.initialDeviceCount])
            let report:[String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),"system":ProcessInfo.processInfo.operatingSystemVersionString,"outputs":self.outputs.map(\.name),"measurements":self.entries,
                "allPassed":self.entries.count == 12 && self.entries.allSatisfy { $0["passed"] as? Bool == true },
                "scope":"Two actual HAL output streams only. No microphone or acoustic synchronization measurement; two independent HomePod pairs remain unavailable."]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:self.root.appendingPathComponent("build/live-routing-results.json"),options:.atomic) }
            self.state.applyVerificationState(self.original); self.append("Test finished; original settings restored.")
        }
    }
}
#endif
