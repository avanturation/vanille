import AppKit
import CoreAudio
import Darwin

final class ProcessAudioManager {
    func applications() throws -> [AudioApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
        var groups: [String: AudioApplication] = [:]
        for id in try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? HAL.read(id, kAudioProcessPropertyPID, default: pid_t(0)), pid != ownPID,
                  (try? HAL.read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) == 1 else { continue }
            let rawBundleID = (try? HAL.string(id, kAudioProcessPropertyBundleID)) ?? ""
            var running = NSRunningApplication(processIdentifier: pid)
            if running?.bundleURL == nil {
                var ancestor = pid
                for _ in 0..<16 {
                    var info = proc_bsdinfo()
                    guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                          info.pbi_ppid > 1, info.pbi_ppid != UInt32(ancestor) else { break }
                    ancestor = pid_t(info.pbi_ppid)
                    if let parent = runningApps.first(where: { $0.processIdentifier == ancestor }), parent.bundleURL != nil {
                        running = parent; break
                    }
                }
            }
            if running?.bundleURL == nil, let owner = runningApps.filter({
                guard let id = $0.bundleIdentifier else { return false }
                return rawBundleID.lowercased().hasPrefix(id.lowercased()+".")
            }).max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) { running = owner }
            let url = running?.bundleURL
            // The outermost .app owns Chromium/WebKit helpers. No PID is persisted.
            let outerURL: URL? = url.flatMap { url in
                let components = url.pathComponents
                guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return url }
                return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(index + 1))))
            }
            let bundle = outerURL.flatMap(Bundle.init(url:))
            let bundleID = bundle?.bundleIdentifier ?? rawBundleID
            guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? running?.localizedName ?? bundleID
            let devices = Set((try? HAL.objects(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? [])
            if var group = groups[bundleID] {
                group.processes.append(id); group.pids.append(pid); group.outputDevices.formUnion(devices)
                groups[bundleID] = group
            } else {
                groups[bundleID] = AudioApplication(id: bundleID, name: name, bundleURL: outerURL, processes: [id], pids: [pid], outputDevices: devices)
            }
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
