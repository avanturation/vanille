import AppKit
import CoreAudio

final class ProcessAudioManager {
    func applications() throws -> [AudioApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var groups: [String: AudioApplication] = [:]
        for id in try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? HAL.read(id, kAudioProcessPropertyPID, default: pid_t(0)), pid != ownPID,
                  (try? HAL.read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) == 1 else { continue }
            let rawBundleID = (try? HAL.string(id, kAudioProcessPropertyBundleID)) ?? ""
            let running = NSRunningApplication(processIdentifier: pid)
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
