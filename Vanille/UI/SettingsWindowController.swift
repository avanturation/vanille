import AppKit

final class SettingsWindowController: NSWindowController {
    private let state: AppState
    private var token: UUID?
    private var login: ActionButton!
    private var pause: ActionButton!
    private let message = UI.text("",size:11,color:.secondaryLabelColor)
    private let bypassList = UI.documentStack(spacing:10)
    private var bypassSignature = ""
    private var profiles: ActionPopUp!
    private var selectedProfile: String?
    private let profileDetails = UI.text("",size:12,color:.secondaryLabelColor)
    private let diagnostics = UI.text("",size:12,color:.secondaryLabelColor)

    init(state:AppState) {
        self.state = state
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:490,height:420),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Vanille Settings"; window.isReleasedWhenClosed = false; window.setFrameAutosaveName("VanilleSettings")
        super.init(window:window)
        build(); token = state.observe { [weak self] in self?.update() }; update(); window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func build() {
        let tabs = NSTabView(); tabs.tabViewType = .topTabsBezelBorder
        let host = NSView(); window?.contentView = host; UI.pin(tabs,to:host,inset:14)
        let general = UI.vertical(spacing:14)
        login = ActionButton("Launch at login") { [weak self] in guard let self else { return }; self.state.setLaunchAtLogin(!self.state.launchAtLogin) }
        login.setButtonType(.switch)
        pause = ActionButton("Pause audio processing") { [weak self] in guard let self else { return }; self.state.setPaused(!self.state.saved.processingPaused) }
        pause.setButtonType(.switch)
        general.addArrangedSubview(login); general.addArrangedSubview(pause)
        general.addArrangedSubview(ActionButton("Restore Default Audio") { [weak self] in self?.state.restoreOriginalAudio() })
        general.addArrangedSubview(UI.separator())
        general.addArrangedSubview(ActionButton("System Audio Recording Permission…") { UI.openAudioPrivacy() })
        general.addArrangedSubview(ActionButton("Sound Settings & AirPlay…") { UI.openSoundSettings() })
        let privacy = UI.text("Audio is processed in local memory and routed by macOS. Vanille does not save audio, capture video, or upload audio to a server.",size:12,color:.secondaryLabelColor)
        privacy.maximumNumberOfLines = 3; privacy.lineBreakMode = .byWordWrapping
        general.addArrangedSubview(privacy)
        message.maximumNumberOfLines = 3; message.lineBreakMode = .byWordWrapping; general.addArrangedSubview(message)
        general.addArrangedSubview(NSView())
        tab("General",body:general,in:tabs)

        let bypass = UI.vertical(spacing:12)
        let explanation = UI.text("Protected Content Bypass",size:13,weight:.semibold)
        bypass.addArrangedSubview(explanation)
        let note = UI.text("Checked apps play through their original output. Their volume and EQ are not processed. Music and TV are bypassed by default. If a browser's protected audio stops, bypass that browser here.",size:12,color:.secondaryLabelColor)
        note.maximumNumberOfLines = 5; note.lineBreakMode = .byWordWrapping; bypass.addArrangedSubview(note)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        bypassList.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = bypassList
        bypassList.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor).isActive = true
        bypassList.trailingAnchor.constraint(equalTo:scroll.contentView.trailingAnchor).isActive = true
        bypassList.topAnchor.constraint(equalTo:scroll.contentView.topAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        bypass.addArrangedSubview(scroll)
        tab("Bypass",body:bypass,in:tabs)

        let profileBody = UI.vertical(spacing:14)
        profileBody.addArrangedSubview(UI.text("Audio Profiles",size:13,weight:.semibold))
        profiles = ActionPopUp(label:"Audio profile") { [weak self] in self?.selectedProfile = $0; self?.update() }
        profileBody.addArrangedSubview(profiles)
        profileDetails.maximumNumberOfLines = 4; profileDetails.lineBreakMode = .byWordWrapping
        profileBody.addArrangedSubview(profileDetails)
        profileBody.addArrangedSubview(UI.horizontal([
            ActionButton("Apply") { [weak self] in guard let self, let id = self.selectedProfile else { return }; self.state.applyProfile(id) },
            ActionButton("Update with Current Settings") { [weak self] in guard let self, let id = self.selectedProfile,
                let p = self.state.saved.profiles.first(where: { $0.id == id }) else { return }; self.state.saveProfile(id,name:p.name) }
        ]))
        profileBody.addArrangedSubview(UI.horizontal([
            ActionButton("Save New…") { [weak self] in self?.saveProfile() },
            ActionButton("Rename…") { [weak self] in self?.renameProfile() },
            ActionButton("Delete") { [weak self] in guard let self, let id = self.selectedProfile else { return }; self.state.deleteProfile(id); self.selectedProfile = nil; self.update() }
        ]))
        let pNote = UI.text("Profiles save the output, output volume, EQ, and app levels. Unavailable outputs are skipped. Your current bypass choices are kept.",size:12,color:.secondaryLabelColor)
        pNote.maximumNumberOfLines = 4; pNote.lineBreakMode = .byWordWrapping
        profileBody.addArrangedSubview(pNote); profileBody.addArrangedSubview(NSView())
        for field in [privacy,message,note,profileDetails,pNote] {
            field.preferredMaxLayoutWidth = 426
            field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        }
        tab("Profiles",body:profileBody,in:tabs)

        let diagnosticBody = UI.vertical(spacing:14)
        diagnosticBody.addArrangedSubview(UI.text("Audio Diagnostics",size:13,weight:.semibold))
        diagnostics.maximumNumberOfLines = 12; diagnostics.lineBreakMode = .byWordWrapping
        diagnostics.preferredMaxLayoutWidth = 426
        diagnosticBody.addArrangedSubview(diagnostics)
        diagnosticBody.addArrangedSubview(UI.horizontal([
            ActionButton("Refresh") { [weak self] in self?.state.refresh() },
            ActionButton("Copy Diagnostics") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.diagnostics.stringValue,forType:.string)
            }
        ]))
        let diagnosticNote = UI.text("No audio is saved. Review device names before sharing diagnostics. AirPlay connections are managed by macOS Sound.",size:12,color:.secondaryLabelColor)
        diagnosticNote.maximumNumberOfLines = 3; diagnosticNote.lineBreakMode = .byWordWrapping
        diagnosticNote.preferredMaxLayoutWidth = 426
        diagnosticBody.addArrangedSubview(diagnosticNote)
        diagnosticBody.addArrangedSubview(ActionButton("Project & Support…") {
            NSWorkspace.shared.open(URL(string:"https://github.com/avanturation/vanille")!)
        })
        diagnosticBody.addArrangedSubview(NSView()); tab("Diagnostics",body:diagnosticBody,in:tabs)
    }
    private func tab(_ name:String,body:NSStackView,in tabs:NSTabView) {
        let view = NSView(); UI.pin(body,to:view,inset:18)
        for child in body.arrangedSubviews where !(child is NSButton) { child.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true }
        let item = NSTabViewItem(identifier:name); item.label = name; item.view = view; tabs.addTabViewItem(item)
    }
    private func update() {
        login.state = state.launchAtLogin ? .on : .off
        pause.state = state.saved.processingPaused ? .on : .off
        message.stringValue = state.notice ?? state.statusText
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development"
        let output = state.output.map { "\($0.name) · \($0.channels) channels · \(Int($0.sampleRate)) Hz" } ?? "Unavailable"
        let latency = state.output?.reportedLatencyMS.map { String(format:"%.2f ms (reported by macOS)",$0) } ?? "Unavailable"
        diagnostics.stringValue = "Vanille \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nOutput: \(output)\nOutput latency: \(latency)\nActive group: \(state.selectedGroup?.name ?? "Single Output")\nProcessed outputs: \(state.metrics.outputUIDs.count)\nProcessed apps: \(state.metrics.appIDs.count)\nAudio callbacks: \(state.metrics.callbacks)\n\(state.statusText)"
        let entries = state.saved.applications.filter { id,_ in
            if id.hasPrefix("com.avanturation.Vanille.") && id != "com.avanturation.Vanille.OtherSystemAudio" { return false }
            if let range = id.range(of:".helper",options:.caseInsensitive), state.saved.applications[String(id[..<range.lowerBound])] != nil { return false }
            return true
        }.sorted { ($0.value.name.isEmpty ? $0.key : $0.value.name).localizedStandardCompare($1.value.name.isEmpty ? $1.key : $1.value.name) == .orderedAscending }
        let signature = entries.map { "\($0.key):\($0.value.name):\($0.value.bypass)" }.joined(separator:";")
        if signature != bypassSignature {
            bypassSignature = signature
            for v in bypassList.arrangedSubviews { bypassList.removeArrangedSubview(v); v.removeFromSuperview() }
            for (id,value) in entries {
                let displayName = id == "systemsoundserverd" ? "System Sounds" : (value.name.isEmpty ? id : value.name)
                let button = ActionButton(displayName) { [weak self] in guard let self else { return }; self.state.setBypass(!self.state.volume(for:id).bypass,id:id) }
                button.setButtonType(.switch); button.state = value.bypass ? .on : .off
                button.setAccessibilityLabel("Bypass \(button.title)")
                bypassList.addArrangedSubview(button)
            }
        }
        if !state.saved.profiles.contains(where: { $0.id == selectedProfile }) { selectedProfile = state.saved.profiles.first?.id }
        profiles.setItems(state.saved.profiles.map { ($0.name,$0.id) },selected:selectedProfile)
        if let profile = state.saved.profiles.first(where: { $0.id == selectedProfile }) {
            let output = profile.outputUID.flatMap { uid in state.outputs.first { $0.uid == uid }?.name } ?? (profile.outputUID == nil ? "Current output" : "Unavailable output")
            let eq = state.allPresets.first { $0.id == profile.eq.presetID }?.name ?? "Custom"
            profileDetails.stringValue = "\(output)\nEQ: \(profile.eq.enabled ? eq : "Off") · \(profile.applications.count) saved app settings"
        } else { profileDetails.stringValue = "Save the current audio settings as a profile." }
    }
    private func saveProfile() {
        UI.prompt(title:"Save Audio Profile",message:"Save your current output, EQ, and app levels.",window:window) { [weak self] in
            if let name = $0 { self?.state.saveProfile(nil,name:name) }
        }
    }
    private func renameProfile() {
        guard let id = selectedProfile, let profile = state.saved.profiles.first(where: { $0.id == id }) else { return }
        UI.prompt(title:"Rename Profile",message:"Choose a new name.",initial:profile.name,window:window) { [weak self] in
            guard let self, let name = $0 else { return }
            // Rename preserves the saved configuration.
            self.state.renameProfile(id,name:name)
        }
    }
    deinit { if let token { state.removeObserver(token) } }
}
