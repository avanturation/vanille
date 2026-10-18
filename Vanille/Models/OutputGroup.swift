import Foundation

struct DeviceRoute: Codable, Equatable, Identifiable {
    static let systemAirPlayID = "system.airplay.current"
    var id: String // Core Audio Device UID, or an explicitly unassigned configuration slot.
    var name: String
    var enabled = true
    var volume: Float = 1
    var muted = false
    var delayMS: Double = 0
    var isAssigned: Bool { !id.hasPrefix("unassigned.") }
    mutating func sanitize() {
        volume = volume.isFinite ? min(1,max(0,volume)) : 1
        delayMS = delayMS.isFinite ? min(3_000,max(0,delayMS)) : 0
    }
}

enum OutputRouting {
    static func device(for id:String,in outputs:[OutputDevice]) -> OutputDevice? {
        if id == DeviceRoute.systemAirPlayID {
            let airplay = outputs.filter(\.isAirPlay)
            return airplay.count == 1 ? airplay[0] : nil
        }
        return outputs.first { $0.uid == id }
    }
}

struct OutputGroup: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var devices: [DeviceRoute]
    // New users start with their real system output. Groups are explicitly created
    // from discovered devices; existing saved groups are decoded unchanged.
    static var defaults: [OutputGroup] { [] }
}

enum LatencyAlignment {
    /// Align reported device + stream + safety latency. This is an initial estimate, not an acoustic measurement.
    static func offsets(_ milliseconds:[Double?]) -> [Double]? {
        guard !milliseconds.isEmpty else { return nil }
        let values = milliseconds.compactMap { $0 }
        guard values.count == milliseconds.count, values.allSatisfy({ $0.isFinite && $0>=0 }), let slowest = values.max() else { return nil }
        let offsets = values.map { slowest-$0 }
        return offsets.allSatisfy { $0<=3_000 } ? offsets : nil
    }
}
