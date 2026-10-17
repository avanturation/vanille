import AppKit

final class ApplicationRow: NSView {
    private let state: AppState
    let application: AudioApplication
    private let nameLabel: NSTextField
    private let detailLabel = UI.text("", size: 11, color: .secondaryLabelColor)
    private let valueLabel = UI.text("100%", size: 11, color: .secondaryLabelColor)
    private var slider: ActionSlider!
    private var mute: ActionButton!
    private var token: UUID?
    private let controlled: Bool

    init(application: AudioApplication, state: AppState) {
        self.application = application; self.state = state; controlled = state.isControlled(application.id)
        nameLabel = UI.text(application.name)
        super.init(frame: .zero)
        let image = NSImageView()
        image.image = application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? UI.symbol("app", label: application.name)
        image.imageScaling = .scaleProportionallyDown
        image.setAccessibilityLabel(application.name)
        image.widthAnchor.constraint(equalToConstant: 22).isActive = true
        image.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let more = ActionButton("") { [weak self] in self?.showMenu() }
        more.image = UI.symbol("ellipsis", label: "Options for \(application.name)")
        more.isBordered = false; more.setAccessibilityLabel("Options for \(application.name)")
        more.widthAnchor.constraint(equalToConstant: 24).isActive = true
        mute = ActionButton("") { [weak self] in guard let self else { return }; self.state.toggleMute(self.application.id) }
        mute.isBordered = false; mute.widthAnchor.constraint(equalToConstant: 24).isActive = true
        mute.setAccessibilityLabel("Mute \(application.name)")
        mute.isHidden = !controlled
        slider = ActionSlider(value: Double(state.volume(for: application.id).volume), min: 0, max: 1,
            label: "\(application.name) volume") { [weak self] value in
                guard let self else { return }; self.state.setAppVolume(Float(value), id: self.application.id)
            }
        slider.isHidden = !controlled
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right; valueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        valueLabel.isHidden = !controlled; detailLabel.isHidden = controlled
        let title = UI.horizontal([nameLabel, NSView(), mute, more], spacing: 3)
        let bottom = UI.horizontal(controlled ? [slider, valueLabel] : [detailLabel])
        let text = UI.vertical([title, bottom], spacing: 1)
        for row in [title, bottom] { row.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        let root = UI.horizontal([image, text], spacing: 9)
        UI.pin(root, to: self)
        heightAnchor.constraint(equalToConstant: 48).isActive = true
        token = state.observe { [weak self] in self?.update() }; update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update() {
        let v = state.volume(for: application.id)
        if !slider.isHighlighted { slider.doubleValue = Double(v.volume) }
        valueLabel.stringValue = "\(Int((v.volume*100).rounded()))%"
        mute.image = UI.symbol(v.muted ? "speaker.slash.fill" : "speaker.wave.2", label: v.muted ? "Unmute" : "Mute")
        mute.setAccessibilityValue(v.muted ? "Muted" : "Not muted")
        slider.isEnabled = !v.muted
        if v.bypass { detailLabel.stringValue = "Original audio · Protected Content Bypass" }
        else if state.saved.processingPaused { detailLabel.stringValue = "Original audio · Processing paused" }
        else if let output = state.output, !application.outputDevices.contains(output.id) {
            detailLabel.stringValue = "Original audio · Uses another output"
        } else if state.metrics.error != nil { detailLabel.stringValue = "Original audio · Processing unavailable" }
        else if state.metrics.originalAudioIDs.contains(application.id) { detailLabel.stringValue = "Original audio · Audio cannot be processed" }
        else { detailLabel.stringValue = "Original audio · Waiting for processing" }
    }
    private func showMenu() {
        let menu = NSMenu()
        let bypass = NSMenuItem(title: "Protected Content Bypass", action: #selector(toggleBypass), keyEquivalent: "")
        bypass.target = self; bypass.state = state.volume(for: application.id).bypass ? .on : .off
        menu.addItem(bypass)
        let info = NSMenuItem(title: "Bypassed apps keep their original audio.", action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX-20,y: bounds.maxY), in: self)
    }
    @objc private func toggleBypass() { state.setBypass(!state.volume(for: application.id).bypass, id: application.id) }
    deinit { if let token { state.removeObserver(token) } }
}

final class MenuBarViewController: NSViewController {
    let state: AppState
    var showEQ: (() -> Void)?
    var showSettings: (() -> Void)?
    var onSizeChange: ((NSSize) -> Void)?
    private var token: UUID?
    private var outputPicker: ActionPopUp!
    private var master: ActionSlider!
    private let masterValue = UI.text("", size: 11, color: .secondaryLabelColor)
    private let masterNote = UI.text("", size: 11, color: .secondaryLabelColor)
    private var eqToggle: ActionButton!
    private var preset: ActionPopUp!
    private var pause: ActionButton!
    private let status = UI.text("", size: 11, color: .secondaryLabelColor)
    private let applicationList = UI.vertical(spacing: 7)
    private var appScroll: NSScrollView!
    private var scrollHeight: NSLayoutConstraint!
    private var root: NSStackView!
    private let profileRow = UI.horizontal([], spacing: 6)
    private var appSignature = ""
    private var profileSignature = ""

    init(state: AppState) { self.state = state; super.init(nibName: nil,bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.frame = NSRect(x:0,y:0,width:348,height:420); view = effect
        root = UI.vertical(spacing: 10); UI.pin(root,to: effect,inset: 14)
        outputPicker = ActionPopUp(label: "Output device") { [weak self] in self?.state.selectOutput($0) }
        let outputRow = UI.horizontal([UI.text("Output",weight: .medium), NSView(), outputPicker])
        outputPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 246).isActive = true
        add(outputRow)
        let speaker = NSImageView(image: UI.symbol("speaker.wave.2",label: "Output volume")!)
        speaker.widthAnchor.constraint(equalToConstant: 18).isActive = true
        master = ActionSlider(value: 1,min: 0,max: 1,label: "Output volume") { [weak self] in self?.state.setMasterVolume(Float($0)) }
        masterValue.widthAnchor.constraint(equalToConstant: 36).isActive = true
        masterValue.alignment = .right; masterValue.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular)
        add(UI.horizontal([speaker,master,masterValue]))
        add(masterNote)
        add(UI.separator())
        add(UI.text("Applications",size: 11,weight: .semibold,color: .secondaryLabelColor))
        appScroll = NSScrollView(); appScroll.drawsBackground = false; appScroll.hasVerticalScroller = true
        appScroll.autohidesScrollers = true; appScroll.borderType = .noBorder
        applicationList.translatesAutoresizingMaskIntoConstraints = false
        appScroll.documentView = applicationList
        applicationList.leadingAnchor.constraint(equalTo: appScroll.contentView.leadingAnchor).isActive = true
        applicationList.trailingAnchor.constraint(equalTo: appScroll.contentView.trailingAnchor).isActive = true
        applicationList.topAnchor.constraint(equalTo: appScroll.contentView.topAnchor).isActive = true
        scrollHeight = appScroll.heightAnchor.constraint(equalToConstant: 36); scrollHeight.isActive = true
        add(appScroll)
        add(UI.separator())
        eqToggle = ActionButton("Equalizer") { [weak self] in guard let self else { return }; self.state.setEQEnabled(!self.state.saved.eq.enabled) }
        eqToggle.setButtonType(.switch); eqToggle.setAccessibilityLabel("Enable equalizer")
        let edit = ActionButton("Edit Equalizer…") { [weak self] in self?.showEQ?() }; edit.bezelStyle = .inline
        add(UI.horizontal([eqToggle,NSView(),edit]))
        preset = ActionPopUp(label: "Equalizer preset") { [weak self] in self?.state.selectPreset($0) }
        add(preset)
        add(UI.separator())
        add(profileRow)
        add(UI.separator())
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        status.setContentCompressionResistancePriority(.defaultLow,for: .horizontal)
        add(status)
        let settings = ActionButton("Settings…") { [weak self] in self?.showSettings?() }
        settings.bezelStyle = .inline; settings.keyEquivalent = ","; settings.keyEquivalentModifierMask = .command
        pause = ActionButton("Start Processing") { [weak self] in guard let self else { return }; self.state.setPaused(!self.state.saved.processingPaused) }
        add(UI.horizontal([settings,NSView(),pause]))
        token = state.observe { [weak self] in self?.update() }
        update()
    }
    private func add(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    func update() {
        guard isViewLoaded else { return }
        outputPicker.setItems(state.outputs.map { ($0.name,$0.uid) }, selected: state.output?.uid)
        outputPicker.isEnabled = !state.outputs.isEmpty
        if state.outputs.isEmpty { outputPicker.setItems([("No Output", "none")],selected: "none") }
        master.isEnabled = state.masterVolume != nil
        if let value = state.masterVolume {
            if !master.isHighlighted { master.doubleValue = Double(value) }
            masterValue.stringValue = "\(Int((value*100).rounded()))%"
            masterNote.isHidden = true
        } else {
            masterValue.stringValue = "—"; masterNote.isHidden = false
            masterNote.stringValue = "Volume is controlled by this output device."
        }
        eqToggle.state = state.saved.eq.enabled ? .on : .off
        var presets = state.allPresets.map { ($0.name,$0.id) }
        if state.saved.eq.presetID == "custom" { presets.append(("Custom","custom")) }
        preset.setItems(presets,selected: state.saved.eq.presetID)
        pause.title = state.saved.processingPaused ? "Start Processing" : "Pause Processing"
        status.stringValue = state.notice ?? state.statusText
        status.textColor = state.metrics.error != nil ? .secondaryLabelColor : .secondaryLabelColor
        let signature = state.applications.map { "\($0.id):\(state.isControlled($0.id))" }.joined(separator: ";")
        if signature != appSignature || applicationList.arrangedSubviews.isEmpty {
            appSignature = signature
            for v in applicationList.arrangedSubviews { applicationList.removeArrangedSubview(v); v.removeFromSuperview() }
            if state.applications.isEmpty {
                let text = UI.text("No apps are playing audio.",size: 12,color: .secondaryLabelColor)
                applicationList.addArrangedSubview(text)
                text.heightAnchor.constraint(equalToConstant: 30).isActive = true
            } else {
                for app in state.applications {
                    let row = ApplicationRow(application: app,state: state)
                    applicationList.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: applicationList.widthAnchor).isActive = true
                }
            }
            scrollHeight.constant = CGFloat(min(4,state.applications.count))*55 + (state.applications.isEmpty ? 32 : -7)
        }
        let profiles = state.saved.profiles
        let pSignature = profiles.map { $0.id+$0.name }.joined()
        if pSignature != profileSignature || profileRow.arrangedSubviews.isEmpty {
            profileSignature = pSignature
            for v in profileRow.arrangedSubviews { profileRow.removeArrangedSubview(v); v.removeFromSuperview() }
            if profiles.isEmpty { profileRow.addArrangedSubview(UI.text("No profiles",size: 11,color: .secondaryLabelColor)) }
            for profile in profiles.prefix(3) {
                let button = ActionButton(profile.name) { [weak self] in self?.state.applyProfile(profile.id) }
                button.setContentCompressionResistancePriority(.defaultLow,for: .horizontal)
                profileRow.addArrangedSubview(button)
            }
        }
        view.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height + 28
        preferredContentSize = NSSize(width:348,height:max(330,height))
        onSizeChange?(preferredContentSize)
    }
    deinit { if let token { state.removeObserver(token) } }
}
