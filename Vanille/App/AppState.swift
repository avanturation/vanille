import AppKit
import CoreAudio
import ServiceManagement

/// UI state and discovery live on the main thread. DSP is owned by AudioController.
final class AppState {
    let store: StateStore
    let devices = DeviceManager()
    let processes = ProcessAudioManager()
    let audio = AudioController()
    private(set) var saved: SavedState
    private(set) var outputs: [OutputDevice] = []
    private(set) var applications: [AudioApplication] = []
    private(set) var output: OutputDevice?
    private(set) var masterVolume: Float?
    private(set) var metrics = EngineMetrics()
    private(set) var notice: String?
    private var subscribers: [UUID: () -> Void] = [:]
    private var observations: [HALObservation] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private var sleeping = false
    private var shuttingDown = false
    private var lastDiscoveryError: String?
    private var initializedRoutes = false
    private var discoverySignature = ""
    private var timingTimeout:DispatchWorkItem?
    private var pausedBeforeTiming = true
    var allPresets: [EQPreset] { EQPreset.defaults + saved.customPresets }
    var processing: Bool { !saved.processingPaused && !sleeping }
    var selectedGroup: OutputGroup? { saved.outputGroups.first { $0.id == saved.selectedGroupID } }
    var deviceRoutes: [DeviceRoute] {
        selectedGroup?.devices ?? output.map { [saved.deviceSettings[$0.uid] ?? DeviceRoute(id:$0.uid,name:$0.name)] } ?? []
    }
    var routingOutputs: [OutputDevice] {
        outputs.filter { $0.transport != kAudioDeviceTransportTypeAggregate && $0.transport != kAudioDeviceTransportTypeVirtual }
    }
    var missingOutputCount: Int { deviceRoutes.filter { r in r.enabled && !outputs.contains { $0.uid == r.id } }.count }
    var statusText: String {
        if let error = metrics.error { return error }
        if output == nil { return "No audio output available." }
        if saved.processingPaused { return "Audio processing is paused." }
        if saved.timingSound && metrics.running { return "Timing sound is playing. Add delay to the speaker you hear first." }
        if !deviceRoutes.isEmpty && deviceRoutes.allSatisfy({ !$0.enabled }) { return "All group outputs are disabled. Original audio is playing." }
        if missingOutputCount > 0 { return "\(missingOutputCount) configured output(s) are unavailable. Original audio or the remaining outputs are in use." }
        if metrics.running { return "\(metrics.outputUIDs.count) output(s) active. Speaker synchronization is not calibrated." }
        if applications.isEmpty { return "Play audio in an app to adjust its volume." }
        return "Apps using original audio are not affected by EQ."
    }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    init(store: StateStore = StateStore()) {
        self.store = store; saved = store.load(); notice = store.loadWarning
    }
    func start() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyServiceRestarted] {
            if let observation = HALObservation(HAL.system, selector, queue: .main, change: { [weak self] in
                self?.refresh(retry: selector == kAudioHardwarePropertyServiceRestarted)
            }) {
                observations.append(observation)
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true; self?.audio.stopSynchronously(); self?.notify()
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false; self?.refresh(retry: true)
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh()
        if let uid = saved.selectedOutputUID, outputs.contains(where: { $0.uid == uid }), output?.uid != uid {
            selectOutput(uid)
        }
    }
    @discardableResult func observe(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID(); subscribers[token] = callback; return token
    }
    func removeObserver(_ token: UUID) { subscribers.removeValue(forKey: token) }
    private func notify() { for callback in Array(subscribers.values) { callback() } }
    func refresh(retry: Bool = false) {
        guard !shuttingDown else { return }
        do {
            outputs = try devices.outputs()
            output = outputs.first { $0.id == devices.defaultOutput() }
            applications = try processes.applications()
            masterVolume = output.flatMap { devices.volume($0.id) }
            if !initializedRoutes {
                initializedRoutes = true
                if let wired = routingOutputs.first(where: { $0.transport == kAudioDeviceTransportTypeUSB })
                    ?? routingOutputs.first(where: { !$0.isAirPlay }) {
                    for i in saved.outputGroups.indices {
                        for j in saved.outputGroups[i].devices.indices where saved.outputGroups[i].devices[j].id == "unassigned.wired" {
                            saved.outputGroups[i].devices[j].id = wired.uid
                            saved.outputGroups[i].devices[j].name = wired.name
                        }
                    }
                    store.save(saved)
                }
            }
            lastDiscoveryError = nil
            for app in applications where saved.applications[app.id] == nil {
                saved.applications[app.id] = AppVolume(name: app.name)
            }
            if output == nil, let fallback = outputs.first(where: { !$0.isAirPlay }) ?? outputs.first {
                // Only recover when HAL reports no valid default. Don't override a valid user's route.
                try devices.select(fallback); output = fallback
            }
        } catch { lastDiscoveryError = error.localizedDescription; notice = lastDiscoveryError }
        // Ignore our own private Aggregate's add/remove notifications. Retry failures only when
        // the visible hardware/default actually changed, or on an explicit user/service retry.
        let signature = outputs.map { "\($0.uid):\($0.id):\($0.sampleRate):\($0.channels)" }.joined(separator:";") + ":default=\(output?.id ?? 0)"
        let hardwareChanged = signature != discoverySignature; discoverySignature = signature
        updateEngine(retry: retry || hardwareChanged)
        audio.snapshot { [weak self] value in
            guard let self, !self.shuttingDown else { return }
            self.metrics = value; self.notify()
        }
        notify()
    }
    private func updateEngine(retry: Bool = false) {
        var state = saved
        if sleeping { state.processingPaused = true }
        audio.reconcile(apps: applications, output: output, availableOutputs: outputs, state: state, retry: retry)
    }
    private func changed(retry: Bool = false) {
        store.save(saved); updateEngine(retry: retry); notify()
    }
    func volume(for id: String) -> AppVolume { saved.applications[id] ?? AppVolume() }
    func isControlled(_ id: String) -> Bool { metrics.running && metrics.appIDs.contains(id) && processing }
    func setAppVolume(_ value: Float, id: String) {
        var v = volume(for: id); v.volume = min(1,max(0,value)); v.muted = false
        saved.applications[id] = v; changed()
    }
    func toggleMute(_ id: String) {
        var v = volume(for: id); v.muted.toggle(); saved.applications[id] = v; changed()
    }
    func setBypass(_ bypass: Bool, id: String) {
        var v = volume(for: id); v.bypass = bypass; saved.applications[id] = v; changed(retry: true)
    }
    func setPaused(_ paused: Bool) {
        if paused { timingTimeout?.cancel(); timingTimeout = nil; saved.timingSound = false }
        saved.processingPaused = paused; changed(retry: true)
    }
    func restoreOriginalAudio() {
        saved.processingPaused = true
        timingTimeout?.cancel(); timingTimeout = nil; saved.timingSound = false
        audio.stopSynchronously(); metrics = EngineMetrics(); changed()
        notice = "Original audio restored. Processing is paused."; notify()
    }
    func selectOutput(_ uid: String) {
        guard let device = outputs.first(where: { $0.uid == uid }) else { return }
        audio.stopSynchronously(); metrics = EngineMetrics()
        do { try devices.select(device); saved.selectedOutputUID = uid; notice = nil }
        catch { notice = error.localizedDescription }
        store.save(saved); refresh(retry: true)
    }
    func setMasterVolume(_ value: Float) {
        guard let output else { return }
        do { try devices.setVolume(value, on: output.id); masterVolume = value }
        catch { notice = error.localizedDescription }
        notify()
    }
    func setEQEnabled(_ value: Bool) { saved.eq.enabled = value; changed() }
    func setBand(_ index: Int, value: Float) {
        guard saved.eq.gains.indices.contains(index) else { return }
        saved.eq.gains[index] = min(12,max(-12,value)); saved.eq.presetID = "custom"; changed()
    }
    func setPreamp(_ value: Float) { saved.eq.preamp = min(0,max(-24,value)); changed() }
    func setAutoHeadroom(_ value: Bool) { saved.eq.autoHeadroom = value; changed() }
    func selectPreset(_ id: String) {
        guard let preset = allPresets.first(where: { $0.id == id }) else { return }
        saved.eq.gains = preset.gains; saved.eq.preamp = preset.preamp
        saved.eq.presetID = id; changed()
    }
    func resetEQ() { selectPreset("flat") }
    func savePreset(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = EQPreset(id: UUID().uuidString, name: name, gains: saved.eq.gains, preamp: saved.eq.preamp)
        saved.customPresets.append(preset); saved.eq.presetID = preset.id; changed()
    }
    func renamePreset(id: String, name: String) {
        guard let index = saved.customPresets.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saved.customPresets[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); changed()
    }
    func deletePreset(_ id: String) {
        saved.customPresets.removeAll { $0.id == id }
        if saved.eq.presetID == id { saved.eq.presetID = "custom" }
        changed()
    }
    func applyProfile(_ id: String) {
        guard let profile = saved.profiles.first(where: { $0.id == id }) else { return }
        notice = nil
        audio.stopSynchronously(); metrics = EngineMetrics()
        if let uid = profile.outputUID {
            if let device = outputs.first(where: { $0.uid == uid }) {
                do { try devices.select(device); saved.selectedOutputUID = uid; output = device }
                catch { notice = "The profile's output could not be selected. Current output kept." }
            } else { notice = "The profile's output is unavailable. Current output kept." }
        }
        saved.eq = profile.eq
        // Current user bypass choices win: a profile must never silently re-enable protected apps.
        for (key, var value) in profile.applications {
            value.bypass = saved.applications[key]?.bypass ?? value.bypass
            saved.applications[key] = value
        }
        if let volume = profile.masterVolume, let output {
            if devices.volume(output.id) != nil { try? devices.setVolume(volume, on: output.id) }
            else { notice = "This output uses its own volume control. EQ and app settings were restored." }
        }
        changed(retry: true); refresh()
    }
    func saveProfile(_ id: String?, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = AudioProfile(id: id ?? UUID().uuidString, name: trimmed, outputUID: output?.uid,
            masterVolume: masterVolume, eq: saved.eq, applications: saved.applications)
        if let index = saved.profiles.firstIndex(where: { $0.id == profile.id }) { saved.profiles[index] = profile }
        else { saved.profiles.append(profile) }
        changed()
    }
    func deleteProfile(_ id: String) { saved.profiles.removeAll { $0.id == id }; changed() }
    func renameProfile(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = saved.profiles.firstIndex(where: { $0.id == id }) else { return }
        saved.profiles[index].name = trimmed; changed()
    }
    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { notice = "Allow Vanille in System Settings → General → Login Items." }
        } catch { notice = error.localizedDescription }
        notify()
    }
    func clearNotice() { notice = nil; notify() }
    func selectGroup(_ id: String?) {
        saved.selectedGroupID = id; notice = nil; changed(retry:true)
    }
    func toggleTimingSound(groupID:String?) {
        if saved.timingSound { stopTimingSound(); return }
        let routes = saved.outputGroups.first(where: { $0.id == groupID })?.devices ?? deviceRoutes
        guard routes.contains(where: { route in route.enabled && outputs.contains(where: { $0.uid == route.id }) }) else {
            notice = "Assign and enable a connected output before playing the timing sound."; notify(); return
        }
        pausedBeforeTiming = saved.processingPaused
        saved.selectedGroupID = groupID; saved.processingPaused = false; saved.timingSound = true; notice = nil
        changed(retry:true)
        let timeout = DispatchWorkItem { [weak self] in self?.stopTimingSound() }
        timingTimeout = timeout; DispatchQueue.main.asyncAfter(deadline:.now()+90,execute:timeout)
    }
    func stopTimingSound() {
        guard saved.timingSound else { return }
        timingTimeout?.cancel(); timingTimeout = nil; saved.timingSound = false
        saved.processingPaused = pausedBeforeTiming; changed(retry:true)
    }
    func matchDeviceTiming(groupID:String?) {
        guard let groupID, let i = saved.outputGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let indices = saved.outputGroups[i].devices.indices.filter { j in
            let r = saved.outputGroups[i].devices[j]
            return r.enabled && outputs.contains { $0.uid == r.id }
        }
        guard indices.count>=2 else { notice = "Connect and enable at least two outputs to match their timing."; notify(); return }
        let latencies = indices.map { j in outputs.first { $0.uid == saved.outputGroups[i].devices[j].id }?.reportedLatencyMS }
        guard let offsets = LatencyAlignment.offsets(latencies) else {
            notice = "macOS could not provide a usable timing estimate for every output. Existing delays were kept."; notify(); return
        }
        for (offset,j) in zip(offsets,indices) { saved.outputGroups[i].devices[j].delayMS = offset.rounded() }
        saved.selectedGroupID = groupID
        notice = "Initial timing matched using macOS device information. Listen to the timing sound to check the result."
        changed(retry:true)
    }
    func updateRoute(_ id:String, change:(inout DeviceRoute)->Void) {
        if let groupID = saved.selectedGroupID, let i = saved.outputGroups.firstIndex(where: { $0.id == groupID }),
           let j = saved.outputGroups[i].devices.firstIndex(where: { $0.id == id }) {
            change(&saved.outputGroups[i].devices[j]); saved.outputGroups[i].devices[j].sanitize()
        } else if let d = outputs.first(where: { $0.uid == id }) {
            var route = saved.deviceSettings[id] ?? DeviceRoute(id:id,name:d.name)
            change(&route); route.sanitize(); saved.deviceSettings[id] = route
        }
        changed()
    }
    func updateGroupRoute(groupID:String,index:Int,change:(inout DeviceRoute)->Void) {
        guard let i = saved.outputGroups.firstIndex(where: { $0.id == groupID }), saved.outputGroups[i].devices.indices.contains(index) else { return }
        change(&saved.outputGroups[i].devices[index]); saved.outputGroups[i].devices[index].sanitize(); changed()
    }
    func assignGroupDevice(groupID:String,index:Int,uid:String) {
        guard let i = saved.outputGroups.firstIndex(where: { $0.id == groupID }), saved.outputGroups[i].devices.indices.contains(index) else { return }
        if saved.outputGroups[i].devices.enumerated().contains(where: { $0.offset != index && $0.element.id == uid }) {
            notice = "Each output can appear only once in a group."; notify(); return
        }
        if uid.isEmpty { saved.outputGroups[i].devices[index].id = "unassigned.\(UUID().uuidString)" }
        else if let d = routingOutputs.first(where: { $0.uid == uid }) {
            let keepRoleName = saved.outputGroups[i].devices[index].id.hasPrefix("unassigned.")
            saved.outputGroups[i].devices[index].id = uid
            if !keepRoleName { saved.outputGroups[i].devices[index].name = d.name }
        }
        changed(retry:true)
    }
    func addGroup(name:String) { saved.outputGroups.append(OutputGroup(name:name,devices:[])); changed() }
    func renameGroup(_ id:String,name:String) {
        guard let i = saved.outputGroups.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        saved.outputGroups[i].name = name.trimmingCharacters(in:.whitespacesAndNewlines); changed()
    }
    func deleteGroup(_ id:String) {
        saved.outputGroups.removeAll { $0.id == id }; if saved.selectedGroupID == id { saved.selectedGroupID = nil }; changed(retry:true)
    }
    func addGroupDevice(_ id:String) {
        guard let i = saved.outputGroups.firstIndex(where: { $0.id == id }), saved.outputGroups[i].devices.count < 8 else { return }
        saved.outputGroups[i].devices.append(DeviceRoute(id:"unassigned.\(UUID().uuidString)",name:"Output")); changed()
    }
    func removeGroupDevice(_ id:String,index:Int) {
        guard let i = saved.outputGroups.firstIndex(where: { $0.id == id }), saved.outputGroups[i].devices.indices.contains(index) else { return }
        saved.outputGroups[i].devices.remove(at:index); changed(retry:true)
    }
    #if VANILLE_DIAGNOSTICS
    func applyVerificationState(_ value: SavedState) {
        saved = value; updateEngine(retry: true); refresh()
    }
    #endif
    func shutdown() {
        shuttingDown = true; timer?.invalidate(); timingTimeout?.cancel()
        if saved.timingSound { saved.processingPaused = pausedBeforeTiming }
        saved.timingSound = false; observations.removeAll()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll(); audio.stopSynchronously(); store.save(saved, immediately: true)
    }
}
