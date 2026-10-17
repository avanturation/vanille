import AppKit
import AVKit
import CoreAudio
import Network

func pulseWAV() -> Data {
    let rate = 48_000, frames = rate*120
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
            let value = Int16(0.025*envelope*sin(2*Double.pi*880*Double(i)/Double(rate))*32767).littleEndian
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
    var observation:NSKeyValueObservation?
    var live:LiveBridgeSession?
    var liveError=""
    var streamCheckReport="Not run"
    let replaceButton=NSButton(checkboxWithTitle:"Include MR4",target:nil,action:nil)
    let localVolume=NSSlider(value:1,minValue:0,maxValue:1,target:nil,action:nil)
    var lastLive:[String:Any]=[:]
    let reportURL = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/airplay-bridge.json")

    func applicationDidFinishLaunching(_ notification:Notification) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Vanille AirPlay Bridge Experiment"; window.isReleasedWhenClosed = false
        let menu=NSMenu();let appItem=NSMenuItem();menu.addItem(appItem)
        let appMenu=NSMenu();appMenu.addItem(withTitle:"Quit AirPlay Experiment",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu;NSApp.mainMenu=menu
        let playback=NSMenuItem(title:"Playback",action:nil,keyEquivalent:"");let playbackMenu=NSMenu()
        let pause=NSMenuItem(title:"Pause Player",action:#selector(pausePlayer),keyEquivalent:"p");pause.target=self;playbackMenu.addItem(pause)
        let resume=NSMenuItem(title:"Resume Player",action:#selector(resumePlayer),keyEquivalent:"r");resume.target=self;playbackMenu.addItem(resume)
        playback.submenu=playbackMenu;menu.addItem(playback)
        let checks=NSMenuItem(title:"Native Stream Checks",action:#selector(runStreamChecks),keyEquivalent:"t");checks.target=self;playbackMenu.addItem(checks)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        let intro = NSTextField(wrappingLabelWithString:"Multi-speaker audio experiment. Keep macOS output on MR4. This mode delays sound behind video. Use MR4 for Video restores the original sound immediately.")
        intro.font = .systemFont(ofSize:12)
        let picker = AVRoutePickerView(); picker.player = player; picker.setAccessibilityLabel("AirPlay destinations for experimental player")
        let row = NSStackView(views:[picker,button("Play Quiet Pulse",#selector(play)),button("Live Pulse",#selector(livePulse)),button("Live System Audio",#selector(liveSystem)),button("Use MR4 for Video",#selector(stop))]); row.spacing = 8
        replaceButton.target=self;replaceButton.action=#selector(replaceOriginal)
        localVolume.target=self;localVolume.action=#selector(volumeChanged);localVolume.setAccessibilityLabel("MR4 experimental volume")
        let localRow=NSStackView(views:[replaceButton,NSTextField(labelWithString:"MR4"),localVolume]);localRow.spacing=10
        localVolume.widthAnchor.constraint(equalToConstant:150).isActive=true
        status.font = .systemFont(ofSize:12)
        details.isEditable = false; details.font = .monospacedSystemFont(ofSize:11,weight:.regular); details.autoresizingMask = [.width]; details.frame = NSRect(x:0,y:0,width:730,height:350)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = details
        for v in [intro,row,localRow,status,scroll] { root.addArrangedSubview(v) }
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),intro.widthAnchor.constraint(equalTo:root.widthAnchor),status.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:250)])
        detector.isRouteDetectionEnabled = true
        observation = player.observe(\.status,options:[.new]) { [weak self] _,_ in DispatchQueue.main.async { self?.refresh() } }
        window.center(); window.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.refresh() }
        DispatchQueue.global(qos:.userInitiated).async {
            let wav = pulseWAV()
            DispatchQueue.main.async { self.wav = wav; self.startServer() }
        }
        refresh()
    }
    func button(_ name:String,_ selector:Selector)->NSButton { let b=NSButton(title:name,target:self,action:selector);b.bezelStyle = .rounded;return b }
    func startServer() {
        let wav = self.wav
        let s = MemoryHTTPServer { path in path == "pulse.wav" ? .init(contentType:"audio/wav",data:wav) : nil }
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
    @objc func liveSystem() { startLive(tone:false) }
    private func startLive(tone:Bool) {
        stop();liveError=""
        do {
            guard let device=try manager.outputs().first(where: { $0.id==manager.defaultOutput() }),!device.isAirPlay else { throw AudioFailure(operation:"Set the system output to MR4 first",status:-1) }
            let settings=StateStore().load()
            let apps=tone ? [] : try ProcessAudioManager().applications().filter {
                !$0.id.hasPrefix("com.avanturation.Vanille") && !(settings.applications[$0.id]?.bypass ?? false) && ($0.outputDevices.isEmpty || $0.outputDevices.contains(device.id))
            }
            guard tone || !apps.isEmpty else { throw AudioFailure(operation:"Play Safari, Chrome or another app before starting live capture",status:-1) }
            let session=try LiveBridgeSession(player:player,device:device,apps:apps,settings:settings,tone:tone)
            live=session
            session.onFailure = { [weak self] error in self?.liveError=error;self?.player.pause();self?.player.replaceCurrentItem(with:nil);self?.refresh() }
        } catch { liveError=error.localizedDescription }
        refresh()
    }
    private func stopLive() { if let live { live.stop();lastLive=live.snapshot };live=nil;replaceButton.state = .off }
    @objc func stop() { stopLive();player.pause();player.replaceCurrentItem(with:nil);refresh() }
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
        let outputs = (try? manager.outputs()) ?? []
        let current = outputs.first { $0.id == manager.defaultOutput() }
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
    func applicationWillTerminate(_ notification:Notification) { stopLive();player.pause();server?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let app = NSApplication.shared
let delegate = BridgeLabDelegate(); app.delegate = delegate; app.run()
