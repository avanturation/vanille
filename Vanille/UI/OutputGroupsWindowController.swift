import AppKit

final class ActionTextField: NSTextField,NSTextFieldDelegate {
    var onCommit:((String)->Void)?
    convenience init(_ value:String,label:String,commit:@escaping(String)->Void) {
        self.init(string:value); onCommit = commit; target = self; action = #selector(invoke); delegate = self
        controlSize = .small; font = .systemFont(ofSize:12); setAccessibilityLabel(label)
    }
    @objc private func invoke() { onCommit?(stringValue) }
    func controlTextDidEndEditing(_ obj:Notification) { onCommit?(stringValue) }
}
final class ActionStepper:NSStepper {
    var onChange:((Double)->Void)?
    convenience init(value:Double,change:@escaping(Double)->Void) {
        self.init(frame:.zero); minValue = 0; maxValue = 3000; increment = 1; doubleValue = value
        onChange = change; target = self; action = #selector(invoke); controlSize = .small
    }
    @objc private func invoke() { onChange?(doubleValue) }
}

final class DeviceRouteRow:NSView {
    private let state:AppState
    private let id:String
    private var token:UUID?
    private var enabled:ActionButton!
    private var slider:ActionSlider!
    private var mute:ActionButton!
    private let value = UI.text("",size:11,color:.secondaryLabelColor)
    private let delay = UI.text("",size:10,color:.secondaryLabelColor)
    private let unavailable = UI.text("",size:11,color:.secondaryLabelColor)
    init(route:DeviceRoute,state:AppState) {
        self.state = state; id = route.id; super.init(frame:.zero)
        enabled = ActionButton(route.name) { [weak self] in guard let self else { return }; self.state.updateRoute(self.id) { $0.enabled.toggle() } }
        enabled.setButtonType(.switch); enabled.font = .systemFont(ofSize:12); enabled.lineBreakMode = .byTruncatingTail
        mute = ActionButton("") { [weak self] in guard let self else { return }; self.state.updateRoute(self.id) { $0.muted.toggle() } }
        mute.isBordered = false; mute.widthAnchor.constraint(equalToConstant:24).isActive = true
        mute.setAccessibilityLabel("Mute \(route.name)")
        slider = ActionSlider(value:Double(route.volume),min:0,max:1,label:"\(route.name) output volume") { [weak self] v in
            guard let self else { return }; self.state.updateRoute(self.id) { $0.volume = Float(v); $0.muted = false }
        }
        value.widthAnchor.constraint(equalToConstant:36).isActive = true; value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
        delay.widthAnchor.constraint(equalToConstant:72).isActive = true; delay.alignment = .right
        let top = UI.horizontal([enabled,NSView(),mute],spacing:4)
        let bottom = UI.horizontal([slider,value,delay],spacing:6)
        let root = UI.vertical([top,bottom,unavailable],spacing:1)
        for row in [top,bottom,unavailable] { row.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        UI.pin(root,to:self); token = state.observe { [weak self] in self?.update() }; update()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func update() {
        guard let route = state.deviceRoutes.first(where: { $0.id == id }) else { return }
        let connected = state.outputs.contains { $0.uid == id }
        enabled.state = route.enabled ? .on : .off; enabled.isEnabled = connected
        if !slider.isHighlighted { slider.doubleValue = Double(route.volume) }
        slider.isEnabled = connected && route.enabled && !route.muted
        slider.isHidden = !connected; value.isHidden = !connected; delay.isHidden = !connected; mute.isHidden = !connected
        unavailable.isHidden = connected
        unavailable.stringValue = route.isAssigned ? "Disconnected · Original audio remains available" : "Not assigned · Choose an output in Edit Groups"
        value.stringValue = "\(Int((route.volume*100).rounded()))%"
        delay.stringValue = "Delay \(Int(route.delayMS)) ms"
        mute.image = UI.symbol(route.muted ? "speaker.slash.fill" : "speaker.wave.2",label:route.muted ? "Unmute" : "Mute")
        mute.isEnabled = route.enabled
    }
    deinit { if let token { state.removeObserver(token) } }
}

private final class GroupDeviceEditor:NSView {
    let state:AppState
    let groupID:String
    let index:Int
    private var token:UUID?
    private var alias:ActionTextField!
    private var picker:ActionPopUp!
    private var volume:ActionSlider!
    private var enable:ActionButton!
    private var mute:ActionButton!
    private var delay:ActionTextField!
    private var stepper:ActionStepper!
    private let volumeValue = UI.text("",size:11,color:.secondaryLabelColor)
    private var route:DeviceRoute? {
        guard let g = state.saved.outputGroups.first(where: { $0.id == groupID }), g.devices.indices.contains(index) else { return nil }; return g.devices[index]
    }
    init(state:AppState,groupID:String,index:Int) {
        self.state = state; self.groupID = groupID; self.index = index; super.init(frame:.zero)
        alias = ActionTextField(route?.name ?? "Output",label:"Output name") { [weak self] name in
            self?.change { $0.name = String(name.prefix(80)) }
        }
        alias.widthAnchor.constraint(equalToConstant:155).isActive = true
        picker = ActionPopUp(label:"Audio device") { [weak self] uid in
            guard let self else { return }; self.state.assignGroupDevice(groupID:self.groupID,index:self.index,uid:uid)
        }
        let remove = ActionButton("") { [weak self] in guard let self else { return }; self.state.removeGroupDevice(self.groupID,index:self.index) }
        remove.image = UI.symbol("minus.circle",label:"Remove output"); remove.isBordered = false; remove.widthAnchor.constraint(equalToConstant:24).isActive = true
        let top = UI.horizontal([alias,picker,remove])
        enable = ActionButton("Enabled") { [weak self] in self?.change { $0.enabled.toggle() } }; enable.setButtonType(.switch)
        mute = ActionButton("Mute") { [weak self] in self?.change { $0.muted.toggle() } }; mute.setButtonType(.switch)
        volume = ActionSlider(value:1,min:0,max:1,label:"Output volume") { [weak self] v in self?.change { $0.volume = Float(v); $0.muted = false } }
        volumeValue.widthAnchor.constraint(equalToConstant:35).isActive = true
        let middle = UI.horizontal([enable,mute,UI.text("Volume",size:11),volume,volumeValue])
        delay = ActionTextField("0",label:"Additional output delay in milliseconds") { [weak self] text in
            if let v = Double(text) { self?.change { $0.delayMS = v } }
        }
        delay.alignment = .right; delay.widthAnchor.constraint(equalToConstant:60).isActive = true
        let formatter = NumberFormatter(); formatter.minimum = 0; formatter.maximum = 3000; formatter.allowsFloats = false; delay.formatter = formatter
        stepper = ActionStepper(value:0) { [weak self] v in self?.change { $0.delayMS = v } }
        stepper.setAccessibilityLabel("Adjust delay in milliseconds")
        let bottom = UI.horizontal([UI.text("Additional Delay",size:11),delay,stepper,UI.text("ms",size:11,color:.secondaryLabelColor),NSView()])
        let root = UI.vertical([top,middle,bottom,UI.separator()],spacing:6)
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        UI.pin(root,to:self); token = state.observe { [weak self] in self?.update() }; update()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func change(_ body:(inout DeviceRoute)->Void) { state.updateGroupRoute(groupID:groupID,index:index,change:body) }
    private func update() {
        guard let r = route else { return }
        let options = [("Not assigned","")] + state.routingOutputs.map { ($0.isAirPlay ? "AirPlay (current system connection)" : $0.name,$0.uid) }
        var choices = options
        if r.isAssigned && !state.routingOutputs.contains(where: { $0.uid == r.id }) { choices.append(("Disconnected",r.id)) }
        picker.setItems(choices,selected:r.isAssigned ? r.id : "")
        enable.state = r.enabled ? .on : .off; mute.state = r.muted ? .on : .off
        if !volume.isHighlighted { volume.doubleValue = Double(r.volume) }
        volumeValue.stringValue = "\(Int((r.volume*100).rounded()))%"
        if delay.currentEditor() == nil { delay.doubleValue = r.delayMS }
        stepper.doubleValue = r.delayMS
        let connected = state.outputs.contains { $0.uid == r.id }
        volume.isEnabled = connected; mute.isEnabled = connected; delay.isEnabled = connected; stepper.isEnabled = connected
    }
    deinit { if let token { state.removeObserver(token) } }
}

final class OutputGroupsWindowController:NSWindowController,NSWindowDelegate {
    let state:AppState
    private var token:UUID?
    private var selectedID:String?
    private var picker:ActionPopUp!
    private let rows = UI.documentStack(spacing:12)
    private let note = UI.text("",size:11,color:.secondaryLabelColor)
    private var signature = ""
    private var timingButton:ActionButton!
    private var useButton:ActionButton!
    private var matchButton:ActionButton!
    private let activeStatus = UI.text("",size:11,color:.secondaryLabelColor)
    init(state:AppState) {
        self.state = state; selectedID = state.saved.selectedGroupID ?? state.saved.outputGroups.first?.id
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:580),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "Output Groups"; w.isReleasedWhenClosed = false; w.minSize = NSSize(width:590,height:540)
        super.init(window:w); w.delegate = self; build(); token = state.observe { [weak self] in self?.update() }; update(); w.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func build() {
        let host = NSView(); window?.contentView = host; let root = UI.vertical(spacing:12); UI.pin(root,to:host,inset:18)
        picker = ActionPopUp(label:"Output group") { [weak self] id in self?.selectedID = id; self?.signature = ""; self?.update() }
        useButton = ActionButton("Use Group") { [weak self] in self?.state.selectGroup(self?.selectedID) }
        let rename = ActionButton("Rename…") { [weak self] in self?.rename() }
        let add = ActionButton("New…") { [weak self] in self?.newGroup() }
        let delete = ActionButton("Delete") { [weak self] in guard let self, let id = self.selectedID else { return }; self.state.deleteGroup(id); self.selectedID = nil; self.update() }
        root.addArrangedSubview(UI.horizontal([picker,useButton,rename,add,delete]))
        root.addArrangedSubview(activeStatus)
        let intro = UI.text("Copy stereo audio to each enabled output. Match Device Timing sets an initial delay; the timing sound helps you check the result.",size:12,color:.secondaryLabelColor)
        intro.maximumNumberOfLines = 3; intro.lineBreakMode = .byWordWrapping; intro.preferredMaxLayoutWidth = 584
        intro.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); root.addArrangedSubview(intro)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        rows.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = rows
        rows.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor).isActive = true
        rows.trailingAnchor.constraint(equalTo:scroll.contentView.trailingAnchor).isActive = true
        rows.topAnchor.constraint(equalTo:scroll.contentView.topAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive = true
        root.addArrangedSubview(scroll)
        timingButton = ActionButton("Play Timing Sound") { [weak self] in guard let self else { return }; self.state.toggleTimingSound(groupID:self.selectedID) }
        matchButton = ActionButton("Match Device Timing") { [weak self] in guard let self else { return }; self.state.matchDeviceTiming(groupID:self.selectedID) }
        matchButton.toolTip = "Sets initial delays from the timing reported by macOS. This does not measure the sound in your room."
        root.addArrangedSubview(UI.horizontal([
            ActionButton("Add Output") { [weak self] in guard let self, let id = self.selectedID else { return }; self.state.addGroupDevice(id) },timingButton,matchButton,NSView(),
            ActionButton("Sound Settings…") { UI.openSoundSettings() }
        ]))
        let hint = UI.text("Start with Match Device Timing, then play the timing sound. If two pulses are still separate, add delay to the speaker you hear first. The sound stops after 90 seconds.",size:11,color:.secondaryLabelColor)
        hint.maximumNumberOfLines = 3; hint.lineBreakMode = .byWordWrapping; hint.preferredMaxLayoutWidth = 584
        hint.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); root.addArrangedSubview(hint)
        note.maximumNumberOfLines = 4; note.lineBreakMode = .byWordWrapping; note.preferredMaxLayoutWidth = 584
        note.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); root.addArrangedSubview(note)
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
    }
    private func update() {
        if !state.saved.outputGroups.contains(where: { $0.id == selectedID }) { selectedID = state.saved.outputGroups.first?.id }
        picker.setItems(state.saved.outputGroups.map { ($0.name,$0.id) },selected:selectedID)
        let active = selectedID != nil && state.saved.selectedGroupID == selectedID
        useButton.title = active ? "In Use" : "Use Group"; useButton.isEnabled = selectedID != nil && !active
        activeStatus.stringValue = active ? (state.saved.processingPaused ? "This group is selected. Start processing to apply it." : "This group is in use.") : "Editing this group. Choose Use Group to apply its settings."
        timingButton.title = state.saved.timingSound ? "Stop Timing Sound" : "Play Timing Sound"
        let group = state.saved.outputGroups.first { $0.id == selectedID }
        matchButton.isEnabled = (group?.devices.filter { route in route.enabled && state.outputs.contains { $0.uid == route.id } }.count ?? 0)>=2
        timingButton.isEnabled = state.saved.timingSound || (group?.devices.contains(where: { route in
            route.enabled && state.outputs.contains(where: { $0.uid == route.id })
        }) ?? false)
        let newSignature = (group?.id ?? "") + (group?.devices.map { $0.id+$0.name }.joined(separator:";") ?? "")
        if signature != newSignature {
            signature = newSignature
            for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
            if let group { for index in group.devices.indices {
                let row = GroupDeviceEditor(state:state,groupID:group.id,index:index); rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive = true
            } }
        }
        note.stringValue = state.notice ?? "Connect AirPlay in Control Center → Sound. macOS exposes one system AirPlay output; two HomePod pairs are not independently available here. Each output can be added once. AirPlay delay requires manual listening."
    }
    func windowWillClose(_ notification:Notification) { state.stopTimingSound() }
    private func newGroup() {
        UI.prompt(title:"New Output Group",message:"Name the group.",window:window) { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.state.addGroup(name:name); self.selectedID = self.state.saved.outputGroups.last?.id; self.update()
        }
    }
    private func rename() {
        guard let id = selectedID, let group = state.saved.outputGroups.first(where: { $0.id == id }) else { return }
        UI.prompt(title:"Rename Output Group",message:"Name the group.",initial:group.name,window:window) { [weak self] in if let name = $0 { self?.state.renameGroup(id,name:name) } }
    }
    deinit { if let token { state.removeObserver(token) } }
}
