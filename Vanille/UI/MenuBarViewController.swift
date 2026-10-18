import AppKit

final class ApplicationRow: NSView {
    private let state: AppState
    let application: AudioApplication
    private var token: UUID?
    private let controlled: Bool
    private let detail = UI.text("", size: 10, color: .secondaryLabelColor)
    private let value = UI.text("", size: 11, color: .secondaryLabelColor)
    private var slider: ActionSlider!
    private var mute: ActionButton!
    init(application: AudioApplication, state: AppState) {
        self.application = application; self.state = state
        controlled = state.isControlled(application.id)
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? UI.symbol("app", label: application.name)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        icon.setAccessibilityElement(false)
        let name = UI.text(application.name)
        name.toolTip = application.name
        let more = ActionButton("") { [weak self] in self?.showMenu() }
        more.image = UI.symbol("ellipsis", label: "Options for \(application.name)")
        more.isBordered = false; more.widthAnchor.constraint(equalToConstant: 18).isActive = true
        more.setAccessibilityLabel("Options for \(application.name)")
        slider = ActionSlider(value: Double(state.volume(for: application.id).volume), min: 0, max: 1,
            label: "\(application.name) volume") { [weak self] value in
                guard let self else { return }; self.state.setAppVolume(Float(value), id: self.application.id)
            }
        mute = ActionButton("") { [weak self] in guard let self else { return }; self.state.toggleMute(self.application.id) }
        mute.isBordered = false; mute.widthAnchor.constraint(equalToConstant: 20).isActive = true
        value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 34).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let row: NSStackView
        if controlled {
            name.widthAnchor.constraint(equalToConstant: 80).isActive = true
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            row = UI.horizontal([icon,name,slider,value,mute,more],spacing: 6)
        } else {
            let labels = UI.vertical([name,detail],spacing: 1)
            name.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
            row = UI.horizontal([icon,labels,more],spacing: 8)
        }
        UI.pin(row,to: self); heightAnchor.constraint(equalToConstant: 36).isActive = true
        token = state.observe { [weak self] in self?.update() }; update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func update() {
        let level = state.volume(for: application.id)
        if !slider.isHighlighted { slider.doubleValue = Double(level.volume) }
        value.stringValue = "\(Int((level.volume*100).rounded()))%"
        slider.isEnabled = !level.muted
        mute.image = UI.symbol(level.muted ? "speaker.slash.fill" : "speaker.wave.2",label: level.muted ? "Unmute" : "Mute")
        mute.setAccessibilityLabel("\(level.muted ? "Unmute" : "Mute") \(application.name)")
        mute.setAccessibilityValue(level.muted ? "Muted" : "Not muted")
        if level.bypass { detail.stringValue = "Original audio · Bypass" }
        else if state.saved.processingPaused { detail.stringValue = "Processing paused" }
        else if let output = state.output, !application.outputDevices.contains(output.id) { detail.stringValue = "Uses another output" }
        else if state.metrics.error != nil { detail.stringValue = "Original audio · Processing unavailable" }
        else if state.metrics.originalAudioIDs.contains(application.id) { detail.stringValue = "Original audio · Cannot be processed" }
        else { detail.stringValue = "Original audio · Waiting for processing" }
    }
    private func showMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Protected Content Bypass", action: #selector(toggleBypass), keyEquivalent: "")
        item.target = self; item.state = state.volume(for: application.id).bypass ? .on : .off
        menu.addItem(item)
        menu.addItem(NSMenuItem(title: "Bypassed apps keep their original audio.", action: nil, keyEquivalent: ""))
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX-18,y: bounds.maxY), in: self)
    }
    @objc private func toggleBypass() { state.setBypass(!state.volume(for: application.id).bypass,id: application.id) }
    deinit { if let token { state.removeObserver(token) } }
}

private final class OutputSelectionRow: NSView {
    private let state: AppState
    private let device: OutputDevice
    private let choice: ActionButton
    private var token: UUID?
    init(device: OutputDevice,state: AppState) {
        self.state = state; self.device = device
        choice = ActionButton(device.name) { state.selectSingleOutput(device.uid) }
        super.init(frame: .zero)
        choice.setButtonType(.radio); choice.font = .systemFont(ofSize: 12)
        choice.lineBreakMode = .byTruncatingTail
        choice.setAccessibilityLabel("Use \(device.name) as single output")
        let icon = NSImageView(image: UI.symbol(UI.deviceSymbol(device),label: device.name) ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let kind = UI.text(UI.deviceKind(device),size: 10,color: .secondaryLabelColor)
        kind.isHidden = device.name == UI.deviceKind(device)
        kind.setContentHuggingPriority(.required,for: .horizontal)
        let row = UI.horizontal([icon,choice,kind],spacing: 8)
        UI.pin(row,to: self); heightAnchor.constraint(equalToConstant: 28).isActive = true
        token = state.observe { [weak self] in self?.update() }; update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func update() { choice.state = state.output?.uid == device.uid ? .on : .off }
    deinit { if let token { state.removeObserver(token) } }
}

final class MenuBarViewController: NSViewController {
    let state: AppState
    var showEQ: (() -> Void)?
    var showSettings: (() -> Void)?
    var showGroups: (() -> Void)?
    var onSizeChange: ((NSSize) -> Void)?
    private var token: UUID?
    private var root: NSStackView!
    private let outputName = UI.text("",size: 13,weight: .semibold)
    private let masterValue = UI.text("",size: 11,color: .secondaryLabelColor)
    private let outputIcon = NSImageView()
    private var master: ActionSlider!
    private var groupPicker: ActionPopUp!
    private var preset: ActionPopUp!
    private var eqToggle: ActionButton!
    private var pause: ActionButton!
    private let status = UI.text("",size: 11,color: .secondaryLabelColor)
    private let deviceList = UI.documentStack(spacing: 2)
    private let routeList = UI.documentStack(spacing: 6)
    private let applicationList = UI.documentStack(spacing: 2)
    private var deviceScroll: NSScrollView!, routeScroll: NSScrollView!, appScroll: NSScrollView!
    private var deviceHeight: NSLayoutConstraint!, routeHeight: NSLayoutConstraint!, appHeight: NSLayoutConstraint!
    private var deviceSignature = "", routeSignature = "", appSignature = ""
    init(state: AppState) { self.state = state; super.init(nibName: nil,bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let surface = NativePopoverSurface(frame: NSRect(x: 0,y: 0,width: 360,height: 480)); view = surface
        root = UI.vertical(spacing: 8); UI.pin(root,to: surface.content,inset: 14)
        outputIcon.imageScaling = .scaleProportionallyDown
        outputIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        outputIcon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        outputIcon.setAccessibilityElement(false)
        add(UI.horizontal([outputIcon,outputName],spacing: 8))
        master = ActionSlider(value: 1,min: 0,max: 1,label: "System output volume") { [weak self] in self?.state.setMasterVolume(Float($0)) }
        masterValue.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular)
        masterValue.widthAnchor.constraint(equalToConstant: 36).isActive = true; masterValue.alignment = .right
        add(UI.horizontal([master,masterValue],spacing: 8))
        add(UI.separator())
        add(section("Output Devices",action: ActionButton("AirPlay…") { UI.openSoundSettings() }))
        (deviceScroll,deviceHeight) = list(deviceList,height: 28); add(deviceScroll)
        add(UI.separator())
        let manage = ActionButton("Edit…") { [weak self] in self?.showGroups?() }; manage.bezelStyle = .inline
        add(section("Output Groups",action: manage))
        groupPicker = ActionPopUp(label: "Output group") { [weak self] in self?.state.selectGroup($0 == "current" ? nil : $0) }
        add(groupPicker)
        (routeScroll,routeHeight) = list(routeList,height: 0); add(routeScroll)
        add(UI.separator())
        add(section("Applications"))
        (appScroll,appHeight) = list(applicationList,height: 30); add(appScroll)
        add(UI.separator())
        eqToggle = ActionButton("Equalizer") { [weak self] in guard let self else { return }; self.state.setEQEnabled(!self.state.saved.eq.enabled) }
        eqToggle.setButtonType(.switch); eqToggle.setAccessibilityLabel("Enable equalizer")
        let edit = ActionButton("Open Equalizer…") { [weak self] in self?.showEQ?() }; edit.bezelStyle = .inline
        add(UI.horizontal([eqToggle,NSView(),edit]))
        preset = ActionPopUp(label: "Equalizer preset") { [weak self] in self?.state.selectPreset($0) }; add(preset)
        add(UI.separator())
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 332
        status.setContentCompressionResistancePriority(.defaultLow,for: .horizontal); add(status)
        let settings = ActionButton("Settings…") { [weak self] in self?.showSettings?() }
        settings.bezelStyle = .inline; settings.keyEquivalent = ","; settings.keyEquivalentModifierMask = .command
        pause = ActionButton("Start Processing") { [weak self] in guard let self else { return }; self.state.setPaused(!self.state.saved.processingPaused) }
        add(UI.horizontal([settings,NSView(),pause]))
        token = state.observe { [weak self] in self?.update() }; update()
    }
    private func section(_ title: String,action: NSButton? = nil) -> NSView {
        let label = UI.text(title,size: 11,weight: .semibold,color: .secondaryLabelColor)
        if let action { action.bezelStyle = .inline; return UI.horizontal([label,NSView(),action]) }
        return label
    }
    private func add(_ child: NSView) { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    private func list(_ document: NSStackView,height: CGFloat) -> (NSScrollView,NSLayoutConstraint) {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        NSLayoutConstraint.activate([document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        let constraint = scroll.heightAnchor.constraint(equalToConstant: height); constraint.isActive = true
        return (scroll,constraint)
    }
    private func clear(_ stack: NSStackView) { for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() } }
    private func append(_ child: NSView,to stack: NSStackView) { stack.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    func update() {
        guard isViewLoaded else { return }
        outputName.stringValue = state.output?.name ?? "No Output"
        outputIcon.image = UI.symbol(UI.deviceSymbol(state.output),label: "Current system output")
        if let volume = state.masterVolume {
            if !master.isHighlighted { master.doubleValue = Double(volume) }
            masterValue.stringValue = "\(Int((volume*100).rounded()))%"; master.isEnabled = true
            master.toolTip = "System volume for \(state.output?.name ?? "the current output")"
        } else {
            master.isEnabled = false; masterValue.stringValue = "—"
            master.toolTip = "This device uses its own volume control. Group levels are available while processing."
        }
        let hardwareUIDs = Set(state.routingOutputs.map(\.uid))
        let orderedDevices = state.outputs.sorted { left,right in
            if (left.uid == state.output?.uid) != (right.uid == state.output?.uid) { return left.uid == state.output?.uid }
            let leftHardware = hardwareUIDs.contains(left.uid)
            let rightHardware = hardwareUIDs.contains(right.uid)
            if leftHardware != rightHardware { return leftHardware }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        let devices = orderedDevices.map { "\($0.uid):\($0.name):\($0.transport)" }.joined(separator: ";")
        if deviceSignature != devices || deviceList.arrangedSubviews.isEmpty {
            deviceSignature = devices; clear(deviceList)
            for device in orderedDevices { append(OutputSelectionRow(device: device,state: state),to: deviceList) }
            if state.outputs.isEmpty { append(UI.text("No output devices connected.",size: 12,color: .secondaryLabelColor),to: deviceList) }
            deviceHeight.constant = CGFloat(max(1,min(3,state.outputs.count)))*30
        }
        groupPicker.setItems([("Single Output","current")]+state.saved.outputGroups.map { ($0.name,$0.id) },selected: state.saved.selectedGroupID ?? "current")
        let routes = state.selectedGroup == nil ? [] : state.deviceRoutes
        routeScroll.isHidden = routes.isEmpty
        let routeKey = (state.saved.selectedGroupID ?? "") + routes.map { $0.id+$0.name+String(state.outputDevice(for: $0.id) != nil) }.joined(separator: ";")
        if routeSignature != routeKey || routeList.arrangedSubviews.isEmpty {
            routeSignature = routeKey; clear(routeList)
            for route in routes { append(DeviceRouteRow(route: route,state: state),to: routeList) }
            routeHeight.constant = CGFloat(min(2,routes.count))*40
        }
        let apps = state.applications.map { "\($0.id):\(state.isControlled($0.id))" }.joined(separator: ";")
        if appSignature != apps || applicationList.arrangedSubviews.isEmpty {
            appSignature = apps; clear(applicationList)
            if state.applications.isEmpty { append(UI.text("No apps are playing audio.",size: 12,color: .secondaryLabelColor),to: applicationList) }
            for app in state.applications { append(ApplicationRow(application: app,state: state),to: applicationList) }
            appHeight.constant = state.applications.isEmpty ? 26 : CGFloat(min(3,state.applications.count))*38
        }
        eqToggle.state = state.saved.eq.enabled ? .on : .off
        var presets = state.allPresets.map { ($0.name,$0.id) }
        if state.saved.eq.presetID == "custom" { presets.append(("Custom","custom")) }
        preset.setItems(presets,selected: state.saved.eq.presetID)
        pause.title = state.saved.processingPaused ? "Start Processing" : "Pause Processing"
        status.stringValue = state.notice ?? state.statusText
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 360,height: max(340,root.fittingSize.height+28))
        onSizeChange?(preferredContentSize)
    }
    deinit { if let token { state.removeObserver(token) } }
}
