import AppKit
import AVKit
import CoreAudio
import Network

func pulseWAV(synchronization:Bool=false) -> Data {
    let rate = 48_000, frames = rate*(synchronization ? 150 : 120)
    var result = Data()
    func ascii(_ text:String) { result.append(Data(text.utf8)) }
    func u16(_ value:UInt16) { var v=value.littleEndian; withUnsafeBytes(of:&v) { result.append(contentsOf:$0) } }
    func u32(_ value:UInt32) { var v=value.littleEndian; withUnsafeBytes(of:&v) { result.append(contentsOf:$0) } }
    ascii("RIFF"); u32(UInt32(36+frames*4)); ascii("WAVEfmt "); u32(16); u16(1); u16(2)
    u32(UInt32(rate)); u32(UInt32(rate*4)); u16(4); u16(16); ascii("data"); u32(UInt32(frames*4))
    result.append(Data(count:frames*4))
    result.withUnsafeMutableBytes { raw in
        let pcm=raw.baseAddress!.advanced(by:44).assumingMemoryBound(to:Int16.self)
        for i in 0..<frames {
            let position = i % (rate*2)
            let envelope = position<rate/10 ? min(1,Double(position)/240)*min(1,Double(rate/10-position)/240) : 0
            let x=synchronization ? SyncCue.sample(Int64(i),rate:Double(rate)) : 0.025*envelope*sin(2*Double.pi*880*Double(i)/Double(rate))
            let value = Int16(x*32767).littleEndian
            pcm[i*2]=value;pcm[i*2+1]=value
        }
    }
    return result
}

final class BridgeLabDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    let player = AVPlayer()
    let detector = AVRouteDetector()
    let status = NSTextField(wrappingLabelWithString:"")
    let details = NSTextView()
    let manager = DeviceManager()
    var server:MemoryHTTPServer?
    var baseURL:URL?
    var timer:Timer?
    var wav:Data = Data()
    var syncWAV=Data()
    var fixtureStatus="Preparing owned video"
    var latencyPropagation:[String:Any]=[:]
    var sourcePlayerLatency:[String:Any]=[:]
    var virtualSourcePlayerLatency:[String:Any]=[:]
    var virtualLatencyProbe:[String:Any]=[:]
    var virtualRoute:LatencyDeclaredRoute?
    var lastVirtualRoute:[String:Any]=[:]
    private var virtualProbeRunning=false
    private var virtualAttempt=UUID()
    private var virtualPreparing=false
    private var virtualRequest:VirtualRouteRequest?
    var sourcePlayerProbe:LatencyAwarePlayerProbe?
    let syncWAVLock=NSLock()
    let controlledVideo=ControlledVideo()
    let videoHolder=NSView()
    let mode=NSSegmentedControl(labels:["Music Mode","Video Mode"],trackingMode:.selectOne,target:nil,action:nil)
    let cases=NSPopUpButton()
    let runButton=NSButton(title:"Run 90-second Comparison",target:nil,action:nil)
    let liveSystemButton=NSButton(title:"Live System Audio",target:nil,action:nil)
    let scope=NSTextField(wrappingLabelWithString:"")
    var measurement:SyncMeasurement?
    var lastMeasurement:[String:Any]=[:]
    var observation:NSKeyValueObservation?
    var live:LiveBridgeSession?
    var liveError=""
    var streamCheckReport="Not run"
    let replaceButton=NSButton(checkboxWithTitle:"Include MR4",target:nil,action:nil)
    let localVolume=NSSlider(value:1,minValue:0,maxValue:1,target:nil,action:nil)
    var lastLive:[String:Any]=[:]
    let reportURL = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/airplay-bridge.json")

    func applicationDidFinishLaunching(_ notification:Notification) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Vanille AirPlay Bridge Experiment"; window.isReleasedWhenClosed = false
        let menu=NSMenu();let appItem=NSMenuItem();menu.addItem(appItem)
        let appMenu=NSMenu();appMenu.addItem(withTitle:"Quit AirPlay Experiment",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu;NSApp.mainMenu=menu
        let playback=NSMenuItem(title:"Playback",action:nil,keyEquivalent:"");let playbackMenu=NSMenu()
        let pause=NSMenuItem(title:"Pause Player",action:#selector(pausePlayer),keyEquivalent:"p");pause.target=self;playbackMenu.addItem(pause)
        let resume=NSMenuItem(title:"Resume Player",action:#selector(resumePlayer),keyEquivalent:"r");resume.target=self;playbackMenu.addItem(resume)
        playback.submenu=playbackMenu;menu.addItem(playback)
        let checks=NSMenuItem(title:"Native Stream Checks",action:#selector(runStreamChecks),keyEquivalent:"t");checks.target=self;playbackMenu.addItem(checks)
        let before=NSMenuItem(title:"Before Video Compensation",action:#selector(beforeVideo),keyEquivalent:"b");before.target=self;playbackMenu.addItem(before)
        let after=NSMenuItem(title:"Follow Audio for Video",action:#selector(afterVideo),keyEquivalent:"f");after.target=self;playbackMenu.addItem(after)
        let latency=NSMenuItem(title:"Latency Propagation Probe",action:#selector(probeLatency),keyEquivalent:"l");latency.target=self;playbackMenu.addItem(latency)
        let sourceProbe=NSMenuItem(title:"Source Player Latency Declaration",action:#selector(probeSourcePlayer),keyEquivalent:"Y");sourceProbe.target=self;playbackMenu.addItem(sourceProbe)
        let virtualProbe=NSMenuItem(title:"Virtual Output Latency Probe",action:#selector(probeVirtualOutput),keyEquivalent:"L");virtualProbe.target=self;playbackMenu.addItem(virtualProbe)
        let videoRouting=NSMenuItem(title:"Start Experimental Video Routing",action:#selector(startVirtualVideo),keyEquivalent:"v");videoRouting.target=self;playbackMenu.addItem(videoRouting)
        let virtualSource=NSMenuItem(title:"Virtual Output Source Player Probe",action:#selector(probeVirtualSourcePlayer),keyEquivalent:"V");virtualSource.target=self;playbackMenu.addItem(virtualSource)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        let intro = NSTextField(wrappingLabelWithString:"Music Mode routes sound to the selected speakers. Video Mode preserves external players’ original audio. The comparison measures only the supplied test clip.")
        intro.font = .systemFont(ofSize:12)
        let picker = AVRoutePickerView(); picker.player = player; picker.setAccessibilityLabel("AirPlay destinations for experimental player")
        liveSystemButton.target=self;liveSystemButton.action=#selector(liveSystem);liveSystemButton.bezelStyle = .rounded
        let row = NSStackView(views:[picker,button("Play Quiet Pulse",#selector(play)),button("Live Pulse",#selector(livePulse)),liveSystemButton,button("Use MR4 for Video",#selector(stop))]); row.spacing = 8
        replaceButton.target=self;replaceButton.action=#selector(replaceOriginal)
        localVolume.target=self;localVolume.action=#selector(volumeChanged);localVolume.setAccessibilityLabel("MR4 experimental volume")
        let localRow=NSStackView(views:[replaceButton,NSTextField(labelWithString:"MR4"),localVolume]);localRow.spacing=10
        localVolume.widthAnchor.constraint(equalToConstant:150).isActive=true
        mode.target=self;mode.action=#selector(modeChanged);mode.selectedSegment=0
        mode.setAccessibilityLabel("Audio or controlled video mode")
        cases.addItems(withTitles:["MR4 only","HomePod as system output","Vanille to HomePod","Full output group"])
        cases.setAccessibilityLabel("A/V comparison route")
        runButton.target=self;runButton.action=#selector(runComparison);runButton.bezelStyle = .rounded;runButton.isEnabled=false
        let comparison=NSStackView(views:[mode,cases,runButton]);comparison.spacing=8
        scope.font = .systemFont(ofSize:11);scope.textColor = .secondaryLabelColor
        scope.stringValue="External video: synchronization unsupported in multi-speaker mode. The comparison uses an owned test clip; no video capture. Preparing clip…"
        videoHolder.wantsLayer=true;videoHolder.layer=controlledVideo.layer;videoHolder.isHidden=true
        status.font = .systemFont(ofSize:12)
        details.isEditable = false; details.font = .monospacedSystemFont(ofSize:11,weight:.regular); details.autoresizingMask = [.width]; details.frame = NSRect(x:0,y:0,width:730,height:350)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = details
        for v in [intro,row,localRow,comparison,scope,videoHolder,status,scroll] { root.addArrangedSubview(v) }
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),intro.widthAnchor.constraint(equalTo:root.widthAnchor),status.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:250)])
        videoHolder.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        videoHolder.heightAnchor.constraint(equalToConstant:180).isActive=true
        scope.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        detector.isRouteDetectionEnabled = true
        observation = player.observe(\.status,options:[.new]) { [weak self] _,_ in DispatchQueue.main.async { self?.refresh() } }
        window.center(); window.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.refresh() }
        DispatchQueue.global(qos:.userInitiated).async {
            let wav = pulseWAV()
            DispatchQueue.main.async { self.wav = wav; self.startServer() }
        }
        DispatchQueue.global(qos:.utility).async {
            do {
                let file=FileManager.default.temporaryDirectory.appendingPathComponent("Vanille-Owned-Sync-\(UUID().uuidString).mov")
                let audio=pulseWAV(synchronization:true)
                try ControlledVideoFixture.create(at:file)
                DispatchQueue.main.async {
                    self.syncWAVLock.lock();self.syncWAV=audio;self.syncWAVLock.unlock();self.controlledVideo.loadOwnedFixture(file)
                    self.runButton.isEnabled=true
                    self.fixtureStatus="Ready: generated silent 34-second cue movie"
                    self.scope.stringValue="Video Mode corrects this owned timing clip only. External Safari/Chrome/DRM video keeps its original path; synchronized multi-speaker video is unsupported."
                }
            } catch { DispatchQueue.main.async { self.fixtureStatus="Failed: \(error.localizedDescription)";self.scope.stringValue="Controlled video unavailable: \(error.localizedDescription)" } }
        }
        refresh()
    }
    func button(_ name:String,_ selector:Selector)->NSButton { let b=NSButton(title:name,target:self,action:selector);b.bezelStyle = .rounded;return b }
    func startServer() {
        let wav = self.wav
        let s = MemoryHTTPServer { [weak self] path in
            if path == "pulse.wav" { return .init(contentType:"audio/wav",data:wav) }
            if path == "sync.wav",let self {
                self.syncWAVLock.lock();let data=self.syncWAV;self.syncWAVLock.unlock()
                if !data.isEmpty { return .init(contentType:"audio/wav",data:data) }
            }
            return nil
        }
        server = s
        s.onReady = { [weak self] url in self?.baseURL = url; self?.refresh() }
        s.onError = { [weak self] error in self?.status.stringValue = error }
        do { try s.start() } catch { status.stringValue = error.localizedDescription }
    }
    @objc func play() {
        stopLive()
        guard let baseURL else { return }
        player.replaceCurrentItem(with:AVPlayerItem(url:baseURL.appendingPathComponent("pulse.wav")))
        player.volume = 0.5; player.play()
        refresh()
    }
    @objc func livePulse() { startLive(tone:true) }
    @objc func liveSystem() {
        guard mode.selectedSegment==0 else {
            stop();liveError="External video cannot be synchronized by this bridge. Original audio is preserved. Use Music Mode for audio-only routing.";refresh();return
        }
        startLive(tone:false)
    }
    private func startLive(tone:Bool,syncTone:Bool=false) {
        stop();liveError=""
        player.audioOutputDeviceUniqueID=nil
        do {
            guard let device=try manager.outputs().first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { throw AudioFailure(operation:"Set the system output to MR4 first",status:-1) }
            let settings=StateStore().load()
            let apps=tone ? [] : try ProcessAudioManager().applications().filter {
                !$0.id.hasPrefix("com.avanturation.Vanille") && !(settings.applications[$0.id]?.bypass ?? false) && ($0.outputDevices.isEmpty || $0.outputDevices.contains(device.id))
            }
            guard tone || !apps.isEmpty else { throw AudioFailure(operation:"Play Safari, Chrome or another app before starting live capture",status:-1) }
            let session=try LiveBridgeSession(player:player,device:device,apps:apps,settings:settings,tone:tone,syncTone:syncTone)
            live=session
            session.onFailure = { [weak self] error in self?.liveError=error;self?.player.pause();self?.player.replaceCurrentItem(with:nil);self?.refresh() }
        } catch { liveError=error.localizedDescription }
        refresh()
    }
    private func stopLive() {
        if let live { live.stop();lastLive=live.snapshot };live=nil;replaceButton.state = .off
        if let virtualRoute { virtualRoute.restore();lastVirtualRoute=virtualRoute.snapshot };virtualRoute=nil
    }
    @objc func stop() {
        virtualRequest?.cancel();virtualRequest=nil
        virtualAttempt=UUID();virtualPreparing=false
        if let measurement { measurement.onFinish=nil;measurement.stop();lastMeasurement=measurement.summary };measurement=nil
        controlledVideo.stop();stopLive();player.pause();player.replaceCurrentItem(with:nil);refresh()
    }
    @objc func modeChanged() {
        stop();videoHolder.isHidden=mode.selectedSegment==0
        scope.stringValue=mode.selectedSegment==0 ? "Music Mode: existing multi-speaker gain/EQ path." : "Video Mode: external apps use original sound. Multi-speaker A/V sync is available for the controlled test only, pending verification."
    }
    @objc func beforeVideo() { controlledVideo.setCompensated(false) }
    @objc func afterVideo() { controlledVideo.setCompensated(true) }
    @objc func probeLatency() {
        guard let outputs=try? manager.outputs(),let device=outputs.first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { return }
        let secondary=outputs.first { $0.transport==kAudioDeviceTransportTypeBuiltIn && $0.channels==2 && $0.id != device.id }
        DispatchQueue.global(qos:.utility).async {
            let report=SystemLatencyMatrix.run(primary:device,secondary:secondary)
            DispatchQueue.main.async { self.latencyPropagation=report;self.refresh() }
        }
    }
    @objc func probeSourcePlayer() {
        guard let baseURL,fixtureStatus.hasPrefix("Ready"),let device=try? manager.outputs().first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { return }
        sourcePlayerProbe?.cancel();sourcePlayerLatency=["status":"Running two 12-second native source-player comparisons"]
        sourcePlayerProbe=LatencyAwarePlayerProbe(physical:device,url:baseURL.appendingPathComponent("sync.wav")) { [weak self] report in self?.sourcePlayerLatency=report;self?.refresh() }
        refresh()
    }
    @objc func probeVirtualOutput() {
        guard !virtualProbeRunning,!virtualPreparing,virtualRoute == nil,live == nil,measurement == nil,let device=try? manager.outputs().first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { return }
        virtualProbeRunning=true
        virtualLatencyProbe=["status":"Checking private virtual output; system default stays unchanged"]
        DispatchQueue.global(qos:.utility).async {
            let report=VirtualLatencyOutput.probe(physical:device)
            DispatchQueue.main.async { self.virtualProbeRunning=false;self.virtualLatencyProbe=report;self.refresh() }
        }
    }
    @objc func probeVirtualSourcePlayer() {
        guard !virtualProbeRunning,!virtualPreparing,virtualRoute == nil,live == nil,measurement == nil,
              let baseURL,fixtureStatus.hasPrefix("Ready"),let device=try? manager.outputs().first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { return }
        let rows=virtualLatencyProbe["cases"] as? [[String:Any]] ?? []
        guard let verified=rows.first(where: { ($0["driverLatencyFrames"] as? UInt32)==192_000 && ($0["deviceLatencyFrames"] as? UInt32 ?? 0)>=192_000 && $0["error"] == nil }) else {
            virtualSourcePlayerLatency=["error":"Run the installed virtual-output property probe first"];refresh();return
        }
        sourcePlayerProbe?.cancel();virtualProbeRunning=true
        virtualSourcePlayerLatency=["status":"Comparing ordinary player with zero, four seconds, and warm zero true device latency"]
        sourcePlayerProbe=LatencyAwarePlayerProbe(physical:device,url:baseURL.appendingPathComponent("sync.wav"),virtualTiming:true,
            mainTiming:verified["timingIsMain"] as? Bool ?? false) { [weak self] report in
                self?.virtualProbeRunning=false;self?.virtualSourcePlayerLatency=report;self?.refresh()
            }
        refresh()
    }
    @objc func startVirtualVideo() {
        guard !virtualProbeRunning,!virtualPreparing else { return }
        // The route constructor validates real host latency before changing the default.
        let rows=virtualLatencyProbe["cases"] as? [[String:Any]] ?? []
        let verified=rows.first(where: {
            ($0["driverLatencyFrames"] as? UInt32)==192_000 && ($0["deviceLatencyFrames"] as? UInt32 ?? 0)>=192_000 &&
                ($0["isPrivate"] as? Bool)==false && ($0["requestedStacked"] as? Int)==1 && $0["error"] == nil
        })
        let useTiming=verified?["timingIsMain"] as? Bool ?? true
        stop();liveError="";virtualPreparing=true
        let attempt=UUID();virtualAttempt=attempt
        let request=VirtualRouteRequest();virtualRequest=request
        do {
            guard let device=try manager.outputs().first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { throw AudioFailure(operation:"Restore MR4 before testing video output",status:-1) }
            let settings=StateStore().load()
            let apps=try ProcessAudioManager().applications().filter {
                !$0.id.hasPrefix("com.avanturation.Vanille") && !(settings.applications[$0.id]?.bypass ?? false) && ($0.outputDevices.isEmpty || $0.outputDevices.contains(device.id))
            }
            guard !apps.isEmpty else { throw AudioFailure(operation:"Play the Safari test video before starting this experiment",status:-1) }
            player.audioOutputDeviceUniqueID=nil
            DispatchQueue.global(qos:.userInitiated).async { [self] in
                do {
                    // Initial value comes from the earlier 3.7–4.6 s measurements, not a user delay control.
                    let route=try LatencyDeclaredRoute(physical:device,frames:192_000,mainTiming:useTiming)
                    do { try route.activate(cancelled: { request.cancelled.load(ordering:.acquiring) }) }
                    catch {
                        route.restore();let report=route.snapshot
                        DispatchQueue.main.async {
                            guard self.virtualAttempt==attempt else { return }
                            self.virtualPreparing=false;self.lastVirtualRoute=report;self.liveError=error.localizedDescription;self.refresh()
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        guard self.virtualAttempt==attempt else { route.restore();return }
                        self.virtualPreparing=false;self.virtualRoute=route
                        do {
                            let session=try LiveBridgeSession(player:self.player,device:device,apps:apps,settings:settings,tone:false,
                                captureDeviceUID:LatencyDeclaredRoute.uid,expectedDefault:route.object)
                            self.live=session
                            try session.replaceOriginal(true)
                            session.onFailure={ [weak self] error in
                                self?.liveError=error;self?.player.pause();self?.player.replaceCurrentItem(with:nil)
                                self?.stopLive();self?.refresh()
                            }
                            self.mode.selectedSegment=1;self.videoHolder.isHidden=true
                            self.scope.stringValue="Experimental source-player latency declaration. Safari/YouTube A/V has not passed verification. No video capture or timeline changes."
                        } catch { self.liveError=error.localizedDescription;self.stopLive() }
                        self.refresh()
                    }
                } catch { DispatchQueue.main.async {
                    guard self.virtualAttempt==attempt else { return }
                    self.virtualPreparing=false;self.liveError=error.localizedDescription;self.refresh()
                } }
            }
        } catch { virtualPreparing=false;liveError=error.localizedDescription;refresh() }
    }
    @objc func runComparison() {
        let selected=cases.indexOfSelectedItem
        let labels=["mr4-only","homepod-default","vanille-homepod","full-group"]
        stop();liveError=""
        let commandHost=AudioGetCurrentHostTime()
        do {
            guard let baseURL,let device=try manager.outputs().first(where: { $0.id==manager.defaultOutput() }) else { throw AudioFailure(operation:"Comparison output unavailable",status:-1) }
            guard selected==1 ? device.isAirPlay : !device.isAirPlay else { throw AudioFailure(operation:selected==1 ? "Select HomePod in macOS Sound before this comparison" : "Restore MR4 as macOS output before this comparison",status:-1) }
            if selected<2 {
                player.audioOutputDeviceUniqueID=device.uid
                player.replaceCurrentItem(with:AVPlayerItem(url:baseURL.appendingPathComponent("sync.wav")))
                player.volume=1;player.play()
            } else {
                startLive(tone:true,syncTone:true)
                guard live != nil else { return }
            }
            mode.selectedSegment=1;videoHolder.isHidden=false
            controlledVideo.setCompensated(true);controlledVideo.follow(audio:player,live:live)
            let url=reportURL.deletingLastPathComponent().appendingPathComponent("avsync-\(labels[selected]).json")
            let run=SyncMeasurement(label:labels[selected],url:url,device:device,player:player,live:live,video:controlledVideo,commandHost:commandHost)
            measurement=run
            run.onFinish = { [weak self] in self?.stop() }
            scope.stringValue=selected>=2 ? "Select the intended HomePod destinations in AirPlay. For Full Group, then enable Include MR4. Recording numerical timing for 90 seconds; no audio is saved." : "Native default-output comparison: 90 seconds of numerical timing. The video follows the native player's audio clock."
        } catch { liveError=error.localizedDescription }
        refresh()
    }
    @objc func replaceOriginal() {
        do { try live?.replaceOriginal(replaceButton.state == .on) }
        catch { replaceButton.state = .off;liveError=error.localizedDescription }
        refresh()
    }
    @objc func volumeChanged() { live?.setLocalVolume(localVolume.doubleValue) }
    @objc func runStreamChecks() {
        guard streamCheckReport != "Running" else { return }
        streamCheckReport="Running"
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let report:String
            do { report=try runAirPlaySegmentChecks().report } catch { report="FAIL \(error.localizedDescription)" }
            DispatchQueue.main.async { self?.streamCheckReport=report;self?.refresh() }
        }
    }
    @objc func pausePlayer() { player.pause();refresh() }
    @objc func resumePlayer() {
        guard live != nil,player.currentItem != nil else { player.play();return }
        player.pause()
        live?.prepareForSeek()
        // Pausing a live utility must not turn it into a growing delayed recording.
        player.seek(to:.positiveInfinity) { [weak self] finished in
            DispatchQueue.main.async { if finished { self?.player.play() };self?.refresh() }
        }
    }
    @objc func refresh() {
        liveSystemButton.isEnabled=mode.selectedSegment==0
        liveSystemButton.toolTip=mode.selectedSegment==0 ? "Route audio using the current gain and EQ settings" : "External video keeps its original audio. Choose Music Mode for multi-speaker audio."
        let outputs = (try? manager.outputs()) ?? []
        let current = outputs.first { $0.id == manager.defaultOutput() } ?? virtualRoute.map {
            OutputDevice(id:$0.object,uid:LatencyDeclaredRoute.uid,name:"Vanille Video Output",channels:4,sampleRate:48_000,transport:kAudioDeviceTransportTypeAggregate)
        }
        let time = player.currentTime().seconds
        let item = player.currentItem
        if let live,live.ready,!live.startedItem,let base=live.baseURL {
            live.startedItem=true
            let item=AVPlayerItem(url:base.appendingPathComponent("live.m3u8"))
            item.preferredForwardBufferDuration=0.35
            item.configuredTimeOffsetFromLive=CMTime(seconds:1.05,preferredTimescale:48_000)
            item.automaticallyPreservesTimeOffsetFromLive=true
            player.replaceCurrentItem(with:item);player.volume=1;player.play()
        }
        let http=server?.metrics
        let liveSnapshot=live?.snapshot ?? lastLive
        replaceButton.isEnabled=live != nil
        replaceButton.state=liveSnapshot["mr4Enabled"] as? Bool == true ? .on : .off
        let report:[String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),"defaultOutput":current?.name ?? "Unknown","defaultTransport":current.map { $0.isAirPlay ? "AirPlay" : "Local" } ?? "Unknown","halAirPlayCount":outputs.filter(\.isAirPlay).count,"halOutputNames":outputs.map(\.name),"routesDetected":detector.multipleRoutesDetected,"playerStatus":player.status.rawValue,"itemStatus":item?.status.rawValue ?? -1,"timeControlStatus":player.timeControlStatus.rawValue,"playerTime":time.isFinite ? time : -1,"waitingReason":player.reasonForWaitingToPlay?.rawValue ?? "","error":(player.error ?? item?.error)?.localizedDescription ?? liveError,"loopbackOnly":true,"audioSaved":false,"requests":http?.requests ?? 0,"bytesSent":http?.bytes ?? 0,"selectedRemoteIdentitiesAvailableInPublicAPI":false,"live":liveSnapshot,"scope":"Experimental memory-only system-audio bridge. Three acoustic outputs require listener verification."]
        var diagnosticReport=report
        diagnosticReport["nativeStreamChecks"]=streamCheckReport
        diagnosticReport["videoMode"]=mode.selectedSegment==1
        diagnosticReport["fixturePreparation"]=fixtureStatus
        diagnosticReport["latencyPropagationProbe"]=latencyPropagation
        diagnosticReport["sourcePlayerLatency"]=sourcePlayerLatency
        diagnosticReport["virtualSourcePlayerLatency"]=virtualSourcePlayerLatency
        diagnosticReport["virtualLatencyProbe"]=virtualLatencyProbe
        diagnosticReport["virtualOutput"]=virtualRoute?.snapshot ?? lastVirtualRoute
        diagnosticReport["virtualOutputPreparing"]=virtualPreparing
        diagnosticReport["video"]=controlledVideo.snapshot
        diagnosticReport["comparison"]=measurement?.summary ?? lastMeasurement
        if let item {
            let recommended=item.recommendedTimeOffsetFromLive.seconds
            diagnosticReport["recommendedLiveOffset"]=recommended.isFinite ? recommended : -1
            diagnosticReport["seekableEnd"]=item.seekableTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds } ?? -1
            if let access=item.accessLog()?.events.last {
                diagnosticReport["mediaRequests"]=access.numberOfMediaRequests
                diagnosticReport["startupTime"]=access.startupTime
                diagnosticReport["stalls"]=access.numberOfStalls
            }
        }
        diagnosticReport["playerOutputDeviceExplicit"]=player.audioOutputDeviceUniqueID != nil
        diagnosticReport["defaultOutputLatencyWritable"]=current.map { HAL.isSettable($0.id,kAudioDevicePropertyLatency,scope:kAudioObjectPropertyScopeOutput) } ?? false
        diagnosticReport["externalVideoPlaybackFlag"]=player.isExternalPlaybackActive
        if let timebase=item?.timebase {
            let clock=CMTimebaseCopyUltimateSourceClock(timebase)
            var id:AudioDeviceID=0
            var tracking:DarwinBoolean=false
            let result=CMAudioDeviceClockGetAudioDevice(clock,deviceUIDOut:nil,deviceIDOut:&id,trackingDefaultDeviceOut:&tracking)
            diagnosticReport["clockDeviceQueryStatus"]=result
            diagnosticReport["clockDeviceMatchesDefault"]=id != 0 && id == manager.defaultOutput()
            diagnosticReport["clockDeviceName"]=(try? HAL.string(id,kAudioObjectPropertyName)) ?? "Unavailable"
        }
        if let data=try? JSONSerialization.data(withJSONObject:diagnosticReport,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:reportURL,options:.atomic); details.string = String(decoding:data,as:UTF8.self) }
        status.stringValue = "System output: \(current?.name ?? "Unknown") · Player: \(player.timeControlStatus == .playing ? "playing" : "stopped / buffering") · AirPlay destinations detected: \(detector.multipleRoutesDetected ? "yes" : "no")"
    }
    func applicationWillTerminate(_ notification:Notification) { sourcePlayerProbe?.cancel();stop();server?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let app = NSApplication.shared
let delegate = BridgeLabDelegate(); app.delegate = delegate; app.run()
