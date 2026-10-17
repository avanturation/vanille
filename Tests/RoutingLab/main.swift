import AppKit
import CoreAudio
import AVKit
import Synchronization

final class AggregateProbe {
    let callbacks = Atomic<UInt64>(0)
    let outputChannels = Atomic<Int>(0)
    var device:AudioObjectID = 0
    var ioProc:AudioDeviceIOProcID?
    var report:[String:Any] = [:]
    func start(_ devices:[OutputDevice]) throws {
        let composition:[String:Any] = [kAudioAggregateDeviceNameKey:"Vanille Routing Probe",
            kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.routing-probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,
            kAudioAggregateDeviceMainSubDeviceKey:devices[0].uid,
            kAudioAggregateDeviceSubDeviceListKey:devices.enumerated().map { i,d in
                [kAudioSubDeviceUIDKey:d.uid,kAudioSubDeviceDriftCompensationKey:i != 0] as [String:Any]
            }]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&device),"Create wired + AirPlay aggregate")
        report["aggregateOutputChannels"] = try HAL.channelCount(device,scope:kAudioObjectPropertyScopeOutput)
        report["activeSubdeviceCount"] = try HAL.objects(device,kAudioAggregateDevicePropertyActiveSubDeviceList).count
        report["outputs"] = devices.map { ["name":$0.name,"transport":fourCC($0.transport),"sampleRate":$0.sampleRate] as [String:Any] }
        report["formats"] = try HAL.objects(device,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput).map { id -> [String:Any] in
            let f = try HAL.read(id,kAudioStreamPropertyVirtualFormat,default:AudioStreamBasicDescription())
            return ["rate":f.mSampleRate,"channels":f.mChannelsPerFrame,"format":fourCC(f.mFormatID),"flags":f.mFormatFlags,"bits":f.mBitsPerChannel]
        }
        try HAL.check(AudioDeviceCreateIOProcID(device,{ _,_,_,_,output,_,client in
            guard let client else { return noErr }
            let probe = Unmanaged<AggregateProbe>.fromOpaque(client).takeUnretainedValue()
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            var channels = 0
            for b in buffers { channels += Int(b.mNumberChannels); if let p = b.mData { memset(p,0,Int(b.mDataByteSize)) } }
            probe.outputChannels.store(channels,ordering:.relaxed); probe.callbacks.wrappingAdd(1,ordering:.relaxed)
            return noErr
        },Unmanaged.passUnretained(self).toOpaque(),&ioProc),"Register multi-output callback")
        let start = AudioDeviceStart(device,ioProc)
        report["startStatus"] = start
        try HAL.check(start,"Start wired + AirPlay IO")
    }
    func stop() {
        report["callbacks"] = callbacks.load(ordering:.relaxed)
        report["callbackOutputChannels"] = outputChannels.load(ordering:.relaxed)
        if let ioProc, device != 0 { report["stopStatus"] = AudioDeviceStop(device,ioProc); report["destroyIOStatus"] = AudioDeviceDestroyIOProcID(device,ioProc) }
        ioProc = nil
        if device != 0 { report["destroyAggregateStatus"] = AudioHardwareDestroyAggregateDevice(device); device = 0 }
    }
    deinit { stop() }
}

func fourCC(_ value:UInt32) -> String {
    String(bytes:[24,16,8,0].map { UInt8((value >> $0)&255) },encoding:.ascii) ?? "\(value)"
}
func dictionary(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector) -> [String:Any]? {
    var a = HAL.address(selector), size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    var value:Unmanaged<CFDictionary>?
    guard AudioObjectGetPropertyData(object,&a,0,nil,&size,&value) == noErr else { return nil }
    return value?.takeRetainedValue() as? [String:Any]
}
func describe(_ id:AudioObjectID) -> [String:Any] {
    var d: [String:Any] = ["id":id,"name":(try? HAL.string(id,kAudioObjectPropertyName)) ?? "Unknown"]
    d["uid"] = try? HAL.string(id,kAudioDevicePropertyDeviceUID)
    d["class"] = fourCC((try? HAL.read(id,kAudioObjectPropertyClass,default:UInt32(0))) ?? 0)
    d["transport"] = fourCC((try? HAL.read(id,kAudioDevicePropertyTransportType,default:UInt32(0))) ?? 0)
    d["outputChannels"] = try? HAL.channelCount(id,scope:kAudioObjectPropertyScopeOutput)
    d["inputChannels"] = try? HAL.channelCount(id,scope:kAudioObjectPropertyScopeInput)
    d["sampleRate"] = try? HAL.read(id,kAudioDevicePropertyNominalSampleRate,default:Double(0))
    d["latencyFrames"] = try? HAL.read(id,kAudioDevicePropertyLatency,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
    d["safetyOffsetFrames"] = try? HAL.read(id,kAudioDevicePropertySafetyOffset,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
    d["bufferFrames"] = try? HAL.read(id,kAudioDevicePropertyBufferFrameSize,default:UInt32(0))
    d["clockDomain"] = try? HAL.read(id,kAudioDevicePropertyClockDomain,default:UInt32(0))
    if (d["class"] as? String) == "aagg" { d["composition"] = dictionary(id,kAudioAggregateDevicePropertyComposition) }
    if (d["class"] as? String) == "edev" {
        d["composition"] = dictionary(id,kAudioEndPointDevicePropertyComposition)
        d["endpoints"] = ((try? HAL.objects(id,kAudioEndPointDevicePropertyEndPointList)) ?? []).map(describe)
    }
    return d
}
final class RoutingLabDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    let text = NSTextView()
    let manager = DeviceManager()
    var player:AVPlayer?
    var timer:Timer?
    var probe:AggregateProbe?
    var probeReport:[String:Any] = [:]
    let path = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/routing-feasibility.json")
    func applicationDidFinishLaunching(_ notification:Notification) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:580),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Vanille Routing Feasibility"; window.isReleasedWhenClosed = false
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8; root.alignment = .leading
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        actions.addArrangedSubview(button("Refresh HAL",#selector(refresh)))
        actions.addArrangedSubview(button("Sound Settings…",#selector(sound)))
        actions.addArrangedSubview(button("Audio MIDI Setup…",#selector(midi)))
        actions.addArrangedSubview(button("Probe Wired + AirPlay IO",#selector(probeRouting)))
        let label = NSTextField(labelWithString:"AirPlay picker below routes this test player only; it does not route system audio.")
        label.font = .systemFont(ofSize:12)
        let picker = AVRoutePickerView(); player = AVPlayer(url:URL(fileURLWithPath:"/System/Library/Sounds/Glass.aiff")); picker.player = player
        let routeRow = NSStackView(views:[picker,button("Test Player Sound",#selector(play))]); routeRow.orientation = .horizontal
        let systemPicker = AVRoutePickerView()
        systemPicker.setAccessibilityLabel("AirPlay picker without a player")
        let systemRow = NSStackView(views:[NSTextField(labelWithString:"No-player picker (scope test):"),systemPicker]); systemRow.orientation = .horizontal
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text
        text.isEditable = false; text.font = .monospacedSystemFont(ofSize:11,weight:.regular); text.autoresizingMask = [.width]
        text.frame = NSRect(x:0,y:0,width:700,height:500)
        root.addArrangedSubview(actions); root.addArrangedSubview(label); root.addArrangedSubview(routeRow); root.addArrangedSubview(systemRow); root.addArrangedSubview(scroll)
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),scroll.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350)])
        window.center(); window.makeKeyAndOrderFront(nil); refresh()
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.refresh() }
    }
    func button(_ title:String,_ action:Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
    @objc func refresh() {
        let devices = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyDevices)) ?? []).map(describe)
        let boxes = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyBoxList)) ?? []).map { id -> [String:Any] in
            var d = describe(id); d["uid"] = try? HAL.string(id,kAudioBoxPropertyBoxUID)
            d["transport"] = fourCC((try? HAL.read(id,kAudioBoxPropertyTransportType,default:UInt32(0))) ?? 0)
            d["acquired"] = try? HAL.read(id,kAudioBoxPropertyAcquired,default:UInt32(0))
            d["acquiredSettable"] = HAL.isSettable(id,kAudioBoxPropertyAcquired)
            d["devices"] = ((try? HAL.objects(id,kAudioBoxPropertyDeviceList)) ?? []).map(describe)
            return d
        }
        let transports = ((try? HAL.objects(HAL.system,kAudioHardwarePropertyTransportManagerList)) ?? []).map { id -> [String:Any] in
            var d = describe(id); d["bundleID"] = try? HAL.string(id,kAudioPlugInPropertyBundleID)
            d["endpoints"] = ((try? HAL.objects(id,kAudioTransportManagerPropertyEndPointList)) ?? []).map(describe)
            d["devices"] = ((try? HAL.objects(id,kAudioPlugInPropertyDeviceList)) ?? []).map(describe)
            return d
        }
        let report:[String:Any] = ["date":ISO8601DateFormatter().string(from:Date()),"system":ProcessInfo.processInfo.operatingSystemVersionString,"defaultOutputID":manager.defaultOutput(),"devices":devices,"boxes":boxes,"transportManagers":transports,"aggregateProbe":probeReport]
        do {
            let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed])
            try data.write(to:path,options:.atomic)
            let summary = "Default output: \(manager.defaultOutput())\n\n" + devices.map { d in
                "\(d["name"] ?? "") · \(d["transport"] ?? "") · \(d["outputChannels"] ?? 0) outputs · \(d["sampleRate"] ?? 0) Hz · latency \(d["latencyFrames"] ?? 0) frames"
            }.joined(separator:"\n") + "\n\nBoxes: \(boxes.count)\nTransport managers: \(transports.count)\n" + transports.map { "\($0)" }.joined(separator:"\n") + "\n\nAggregate probe:\n\(probeReport)"
            if text.string != summary { text.string = summary }
        } catch { text.string = "Snapshot failed: \(error.localizedDescription)" }
    }
    @objc func probeRouting() {
        guard probe == nil else { return }
        let outputs = (try? manager.outputs()) ?? []
        guard let airplay = outputs.first(where: { $0.isAirPlay }), let wired = outputs.first(where: { $0.transport == kAudioDeviceTransportTypeUSB }) else {
            probeReport = ["error":"A wired output and a system-connected AirPlay output are required."]; refresh(); return
        }
        let p = AggregateProbe(); probe = p
        do {
            try p.start([wired,airplay]); probeReport = p.report; refresh()
            DispatchQueue.main.asyncAfter(deadline:.now()+3) {
                p.stop(); self.probeReport = p.report; self.probe = nil; self.refresh()
            }
        } catch { p.stop(); probeReport = p.report; probeReport["error"] = error.localizedDescription; probe = nil; refresh() }
    }
    @objc func sound() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
    @objc func midi() { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Audio MIDI Setup.app")) }
    @objc func play() { player?.seek(to:.zero); player?.play() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = RoutingLabDelegate(); app.delegate = delegate; app.run()
