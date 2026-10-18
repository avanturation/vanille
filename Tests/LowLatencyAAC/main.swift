import AppKit
import AVKit
import Network

// Feasibility probe only: generated quiet audio, no system capture or routing changes.
// ADTS is Apple's documented AAC transport. This is an HTTP media stream, not
// an implementation of the AirPlay protocol. All audio stays in local memory.
final class AACLiveProbe {
    private let queue=DispatchQueue(label:"Vanille.AACLiveProbe")
    private var listener:NWListener?
    private var clients=[UUID:NWConnection]()
    private var origins=[UUID:Int64]()
    private var pending=[UUID:Int]()
    private var timer:DispatchSourceTimer?
    private let source:AVAudioPCMBuffer
    private let compressed:AVAudioCompressedBuffer
    private let converter:AVAudioConverter
    private var frames:Int64=0,packets=0,requests=0
    private var error=""
    private let token=UUID().uuidString
    var onReady:((URL)->Void)?

    init() throws {
        let pcm=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48_000,channels:2,interleaved:false)!
        let aac=AVAudioFormat(settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48_000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128_000])!
        guard let converter=AVAudioConverter(from:pcm,to:aac),let source=AVAudioPCMBuffer(pcmFormat:pcm,frameCapacity:1024) else { throw NSError(domain:"VanilleAAC",code:1) }
        self.converter=converter;self.source=source
        compressed=AVAudioCompressedBuffer(format:aac,packetCapacity:1,maximumPacketSize:max(1024,converter.maximumOutputPacketSize))
    }
    func start() throws {
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters);self.listener=listener
        listener.stateUpdateHandler={ [weak self,weak listener] state in
            guard let self else { return }
            if case .ready=state,let port=listener?.port?.rawValue {
                let url=URL(string:"http://127.0.0.1:\(port)/\(self.token)/live.aac")!
                DispatchQueue.main.async { self.onReady?(url) }
            }
            if case .failed(let error)=state { self.error=error.localizedDescription }
        }
        listener.newConnectionHandler={ [weak self] in self?.accept($0) };listener.start(queue:queue)
        let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer
        timer.schedule(deadline:.now(),repeating:.nanoseconds(Int(1_000_000_000.0*1024/48_000)),leeway:.milliseconds(1))
        timer.setEventHandler { [weak self] in self?.encode() };timer.resume()
    }
    private func accept(_ connection:NWConnection) {
        guard clients.count<4 else { connection.cancel();return }
        let id=UUID();clients[id]=connection;pending[id]=0
        connection.stateUpdateHandler={ [weak self] state in
            if case .failed=state { self?.remove(id) }
            if case .cancelled=state { self?.remove(id) }
        }
        connection.start(queue:queue);receive(connection,id:id,previous:Data())
    }
    private func remove(_ id:UUID) { clients.removeValue(forKey:id);origins.removeValue(forKey:id);pending.removeValue(forKey:id) }
    private func receive(_ connection:NWConnection,id:UUID,previous:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] bytes,_,complete,error in
            guard let self else { return }
            var request=previous;if let bytes { request.append(bytes) }
            guard request.count<=8192,error==nil else { connection.cancel();return }
            guard request.range(of:Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection,id:id,previous:request) };return
            }
            self.requests += 1
            let first=String(decoding:request,as:UTF8.self).components(separatedBy:"\r\n")[0]
            guard first.hasPrefix("GET /\(self.token)/live.aac ") || first.hasPrefix("HEAD /\(self.token)/live.aac ") else { connection.cancel();return }
            let header=Data("HTTP/1.1 200 OK\r\nContent-Type: audio/aac\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nAccept-Ranges: none\r\nConnection: keep-alive\r\n\r\n".utf8)
            connection.send(content:header,completion:.contentProcessed { [weak self] error in
                guard error==nil else { connection.cancel();return }
                if first.hasPrefix("HEAD ") { connection.cancel() }
                else { self?.queue.async { self?.origins[id]=self?.frames ?? 0 } }
            })
        }
    }
    private func encode() {
        guard let channels=source.floatChannelData else { return }
        source.frameLength=1024
        for i in 0..<1024 {
            let value=Float(0.005*sin(2*Double.pi*660*Double(frames+Int64(i))/48_000))
            channels[0][i]=value;channels[1][i]=value
        }
        var supplied=false,conversionError:NSError?
        let status=converter.convert(to:compressed,error:&conversionError) { _,inputStatus in
            guard !supplied else { inputStatus.pointee = .noDataNow;return nil }
            supplied=true;inputStatus.pointee = .haveData;return self.source
        }
        if supplied { frames += 1024 }
        if let conversionError { error=conversionError.localizedDescription;return }
        guard status == .haveData,compressed.packetCount>0,compressed.byteLength>0 else { return }
        let descriptions=compressed.packetDescriptions
        for packet in 0..<Int(compressed.packetCount) {
            let offset=descriptions.map { Int($0[packet].mStartOffset) } ?? 0
            let size=descriptions.map { Int($0[packet].mDataByteSize) } ?? Int(compressed.byteLength)
            let length=size+7
            guard offset>=0,size>0,offset+size<=Int(compressed.byteLength),length<8192 else { error="Invalid AAC packet";return }
            var data=Data([0xFF,0xF1,0x4C,UInt8(0x80|(length>>11)),UInt8((length>>3)&0xFF),UInt8(((length&7)<<5)|0x1F),0xFC])
            data.append(Data(bytes:compressed.data.advanced(by:offset),count:size));packets += 1
            var chunk=Data(String(data.count,radix:16).utf8);chunk.append(Data("\r\n".utf8));chunk.append(data);chunk.append(Data("\r\n".utf8))
            for id in Array(origins.keys) {
                guard let connection=clients[id] else { continue }
                guard (pending[id] ?? 0)<262_144 else { connection.cancel();continue }
                pending[id,default:0] += chunk.count
                connection.send(content:chunk,completion:.contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.pending[id]=max(0,(self.pending[id] ?? 0)-chunk.count)
                    if error != nil { connection.cancel() }
                })
            }
        }
    }
    var snapshot:[String:Any] {
        queue.sync { ["sourceFrames":frames,"packets":packets,"requests":requests,"activeMediaConnections":origins.count,"firstConnectionSourceFrame":origins.values.min() ?? -1,"error":error,"loopbackOnly":true,"audioSaved":false] }
    }
    func stop() { queue.sync { timer?.cancel();timer=nil;listener?.cancel();listener=nil;for c in clients.values { c.cancel() };clients.removeAll();origins.removeAll() } }
}

final class Delegate:NSObject,NSApplicationDelegate {
    let player=AVPlayer()
    let label=NSTextField(wrappingLabelWithString:"Select AirPlay speakers, then Start. Generated quiet AAC only; system audio is unchanged.")
    var probe:AACLiveProbe?,window:NSWindow!,timer:Timer?
    let report=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/live-aac-probe.json")
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu=NSMenu(),item=NSMenuItem();menu.addItem(item);let submenu=NSMenu();submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=submenu;NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="Vanille live AAC feasibility probe"
        let picker=AVRoutePickerView();picker.player=player
        let start=NSButton(title:"Start generated AAC",target:self,action:#selector(start));let stop=NSButton(title:"Stop",target:self,action:#selector(stop))
        let row=NSStackView(views:[picker,start,stop]);row.spacing=12
        let root=NSStackView(views:[row,label]);root.orientation = .vertical;root.alignment = .leading;root.spacing=16;root.frame=NSRect(x:16,y:16,width:528,height:180);root.autoresizingMask=[.width,.height];window.contentView!.addSubview(root)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        player.automaticallyWaitsToMinimizeStalling=false
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.refresh() }
    }
    @objc func start() {
        stop()
        do {
            let p=try AACLiveProbe();probe=p
            p.onReady={ [weak self] url in
                guard let self else { return }
                let item=AVPlayerItem(url:url);item.preferredForwardBufferDuration=0.1;self.player.replaceCurrentItem(with:item);self.player.playImmediately(atRate:1)
            };try p.start()
        } catch { label.stringValue=error.localizedDescription }
    }
    @objc func stop() { player.pause();player.replaceCurrentItem(with:nil);probe?.stop();probe=nil }
    private func refresh() {
        if probe != nil,player.currentItem?.status == .readyToPlay,player.timeControlStatus == .paused { player.playImmediately(atRate:1) }
        var d=probe?.snapshot ?? [:];let time=player.currentTime().seconds
        d["date"]=ISO8601DateFormatter().string(from:Date());d["playerTime"]=time.isFinite ? time : -1;d["transport"]=player.timeControlStatus.rawValue;d["itemStatus"]=player.currentItem?.status.rawValue ?? -1
        d["playerError"]=(player.error ?? player.currentItem?.error)?.localizedDescription ?? ""
        if time.isFinite,time>0,let frames=d["sourceFrames"] as? Int64,let origin=d["firstConnectionSourceFrame"] as? Int64,origin>=0 { d["generatedToPlayerTimelineMS"]=(Double(frames-origin)/48_000-time)*1000 }
        if let event=player.currentItem?.accessLog()?.events.last { d["stalls"]=event.numberOfStalls;d["startupTime"]=event.startupTime }
        if let data=try? JSONSerialization.data(withJSONObject:d,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:report,options:.atomic);label.stringValue=String(decoding:data,as:UTF8.self) }
    }
    func applicationWillTerminate(_ notification:Notification) { stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let app=NSApplication.shared,delegate=Delegate();app.delegate=delegate;app.run()
