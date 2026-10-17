import AppKit

final class EqualizerWindowController: NSWindowController {
    private let state: AppState
    private var token: UUID?
    private var preset: ActionPopUp!
    private var enabled: ActionButton!
    private var autoHeadroom: ActionButton!
    private var preamp: ActionSlider!
    private let preampValue = UI.text("0 dB",size: 11,color: .secondaryLabelColor)
    private var sliders: [ActionSlider] = []
    private var values: [NSTextField] = []
    private var rename: ActionButton!
    private var delete: ActionButton!
    private let scope = UI.text("EQ applies to processed apps. Bypassed apps retain original audio.",size: 11,color: .secondaryLabelColor)

    init(state: AppState) {
        self.state = state
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:530,height:370),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Equalizer"; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VanilleEqualizer")
        super.init(window:window)
        build(); token = state.observe { [weak self] in self?.update() }; update(); window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func build() {
        let content = NSView(); window?.contentView = content
        let root = UI.vertical(spacing:14); UI.pin(root,to:content,inset:20)
        enabled = ActionButton("Enable Equalizer") { [weak self] in guard let self else { return }; self.state.setEQEnabled(!self.state.saved.eq.enabled) }
        enabled.setButtonType(.switch)
        let reset = ActionButton("Reset") { [weak self] in self?.state.resetEQ() }
        root.addArrangedSubview(UI.horizontal([enabled,NSView(),reset]))
        preset = ActionPopUp(label:"Equalizer preset") { [weak self] in self?.state.selectPreset($0) }
        let save = ActionButton("Save…") { [weak self] in self?.savePreset() }
        rename = ActionButton("Rename…") { [weak self] in self?.renamePreset() }
        delete = ActionButton("Delete") { [weak self] in guard let self else { return }; self.state.deletePreset(self.state.saved.eq.presetID) }
        root.addArrangedSubview(UI.horizontal([preset,save,rename,delete],spacing:8))
        let bands = UI.horizontal([],spacing:10); bands.distribution = .fillEqually
        for index in EQSettings.frequencies.indices {
            let f = EQSettings.frequencies[index]
            let value = UI.text("0.0",size:11,color:.secondaryLabelColor)
            value.alignment = .center; value.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
            let slider = ActionSlider(value:0,min:-12,max:12,label:"\(Int(f)) hertz gain in decibels") { [weak self] in self?.state.setBand(index,value:Float($0)) }
            slider.isVertical = true
            slider.numberOfTickMarks = 5; slider.allowsTickMarkValuesOnly = false
            slider.onReset = { [weak self] in self?.state.setBand(index,value:0) }
            slider.heightAnchor.constraint(equalToConstant:150).isActive = true
            let frequency = UI.text(f >= 1_000 ? "\(Int(f/1_000))k" : "\(Int(f))",size:11,color:.secondaryLabelColor)
            frequency.alignment = .center
            let column = UI.vertical([value,slider,frequency],spacing:5); column.alignment = .centerX
            bands.addArrangedSubview(column); sliders.append(slider); values.append(value)
        }
        root.addArrangedSubview(bands)
        preamp = ActionSlider(value:0,min:-24,max:0,label:"Preamp in decibels") { [weak self] in self?.state.setPreamp(Float($0)) }
        preampValue.widthAnchor.constraint(equalToConstant:53).isActive = true; preampValue.alignment = .right
        root.addArrangedSubview(UI.horizontal([UI.text("Preamp"),preamp,preampValue]))
        autoHeadroom = ActionButton("Auto Headroom") { [weak self] in guard let self else { return }; self.state.setAutoHeadroom(!self.state.saved.eq.autoHeadroom) }
        autoHeadroom.setButtonType(.switch)
        autoHeadroom.toolTip = "Reduces gain to allow for the combined EQ boost. Peak protection remains active."
        root.addArrangedSubview(autoHeadroom)
        scope.maximumNumberOfLines = 2; scope.lineBreakMode = .byWordWrapping
        scope.preferredMaxLayoutWidth = 490; scope.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        root.addArrangedSubview(scope)
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
    }
    func update() {
        let eq = state.saved.eq
        enabled.state = eq.enabled ? .on : .off
        var presets = state.allPresets.map { ($0.name,$0.id) }
        if eq.presetID == "custom" { presets.append(("Custom","custom")) }
        preset.setItems(presets,selected:eq.presetID)
        for i in sliders.indices {
            if !sliders[i].isHighlighted { sliders[i].doubleValue = Double(eq.gains[i]) }
            values[i].stringValue = String(format:"%+.1f",eq.gains[i])
            sliders[i].setAccessibilityValueDescription(String(format:"%+.1f decibels",eq.gains[i]))
        }
        if !preamp.isHighlighted { preamp.doubleValue = Double(eq.preamp) }
        preampValue.stringValue = String(format:"%.1f dB",eq.preamp)
        autoHeadroom.state = eq.autoHeadroom ? .on : .off
        let custom = state.saved.customPresets.contains { $0.id == eq.presetID }
        rename.isEnabled = custom; delete.isEnabled = custom
        scope.stringValue = state.saved.processingPaused ? "Processing is paused. Start processing from the menu bar to hear EQ changes." : "EQ applies to processed apps. Bypassed apps retain original audio."
    }
    private func savePreset() {
        UI.prompt(title:"Save Equalizer Preset",message:"Name this equalizer setting.",window:window) { [weak self] in if let name = $0 { self?.state.savePreset(name:name) } }
    }
    private func renamePreset() {
        let id = state.saved.eq.presetID
        let name = state.allPresets.first { $0.id == id }?.name ?? ""
        UI.prompt(title:"Rename Preset",message:"Choose a new name.",initial:name,window:window) { [weak self] in if let name = $0 { self?.state.renamePreset(id:id,name:name) } }
    }
    deinit { if let token { state.removeObserver(token) } }
}
