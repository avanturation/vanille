import Foundation
import CoreAudio

struct AppVolume: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var bypass = false
    var name: String = ""
}

struct EQSettings: Codable, Equatable {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    var enabled = false
    var gains = Array(repeating: Float(0), count: 10)
    var preamp: Float = 0
    var autoHeadroom = true
    var presetID = "flat"

    var effectivePreamp: Float {
        guard enabled else { return 0 }
        return preamp - (autoHeadroom ? max(0, gains.max() ?? 0) : 0)
    }
    mutating func sanitize() {
        gains = (0..<10).map { i in
            let value = i < gains.count ? gains[i] : 0
            return value.isFinite ? min(12, max(-12, value)) : 0
        }
        preamp = preamp.isFinite ? min(0, max(-24, preamp)) : 0
    }
}

struct EQPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var gains: [Float]
    var preamp: Float = 0
    var builtIn = false
    static let defaults = [
        EQPreset(id: "flat", name: "Flat", gains: [0,0,0,0,0,0,0,0,0,0], builtIn: true),
        EQPreset(id: "bass", name: "Bass Boost", gains: [5,4,3,1,0,0,0,0,0,0], builtIn: true),
        EQPreset(id: "clarity", name: "Clarity", gains: [-2,-1,-1,0,1,2,3,3,2,1], builtIn: true),
        EQPreset(id: "vocal", name: "Vocal", gains: [-3,-2,-1,0,2,3,3,1,0,-1], builtIn: true),
        EQPreset(id: "cinema", name: "Cinema", gains: [3,2,0,-1,0,2,3,2,1,0], builtIn: true),
        EQPreset(id: "night", name: "Night", gains: [-6,-4,-2,0,2,3,2,0,-2,-3], preamp: -3, builtIn: true)
    ]
}

struct AudioProfile: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var outputUID: String?
    var masterVolume: Float?
    var eq: EQSettings
    var applications: [String: AppVolume] = [:]
    static let defaults: [AudioProfile] = [
        AudioProfile(id: "desktop", name: "Desktop", eq: EQSettings()),
        AudioProfile(id: "music", name: "Music", eq: EQSettings(enabled: true, gains: EQPreset.defaults[1].gains, presetID: "bass")),
        AudioProfile(id: "cinema", name: "Cinema", eq: EQSettings(enabled: true, gains: EQPreset.defaults[4].gains, presetID: "cinema"))
    ]
}

struct SavedState: Codable {
    var schema = 1
    var applications: [String: AppVolume] = [
        "com.apple.Music": AppVolume(bypass: true, name: "Music"),
        "com.apple.TV": AppVolume(bypass: true, name: "TV")
    ]
    var eq = EQSettings()
    var customPresets: [EQPreset] = []
    var profiles = AudioProfile.defaults
    var selectedOutputUID: String?
    var processingPaused = true
    var outputGroups = OutputGroup.defaults
    var selectedGroupID: String?
    var deviceSettings: [String:DeviceRoute] = [:]
    // Deliberately absent from CodingKeys: test sound can never resume after an app restart.
    var timingSound = false
    init() {}
    enum CodingKeys: String, CodingKey {
        case schema, applications, eq, customPresets, profiles, selectedOutputUID, processingPaused
        case outputGroups, selectedGroupID, deviceSettings
    }
    init(from decoder:Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self,forKey:.schema) ?? 1
        applications = try c.decodeIfPresent([String:AppVolume].self,forKey:.applications) ?? applications
        eq = try c.decodeIfPresent(EQSettings.self,forKey:.eq) ?? eq
        customPresets = try c.decodeIfPresent([EQPreset].self,forKey:.customPresets) ?? []
        profiles = try c.decodeIfPresent([AudioProfile].self,forKey:.profiles) ?? profiles
        selectedOutputUID = try c.decodeIfPresent(String.self,forKey:.selectedOutputUID)
        processingPaused = try c.decodeIfPresent(Bool.self,forKey:.processingPaused) ?? true
        outputGroups = try c.decodeIfPresent([OutputGroup].self,forKey:.outputGroups) ?? outputGroups
        selectedGroupID = try c.decodeIfPresent(String.self,forKey:.selectedGroupID)
        deviceSettings = try c.decodeIfPresent([String:DeviceRoute].self,forKey:.deviceSettings) ?? [:]
    }

    mutating func sanitize() {
        eq.sanitize()
        for key in Array(applications.keys) {
            let value = applications[key]!.volume
            applications[key]!.volume = value.isFinite ? min(1, max(0, value)) : 1
        }
        for i in profiles.indices { profiles[i].eq.sanitize() }
        for i in outputGroups.indices {
            var seen: Set<String> = []
            outputGroups[i].devices = outputGroups[i].devices.filter { seen.insert($0.id).inserted }.prefix(8).map { var d = $0; d.sanitize(); return d }
        }
        for key in Array(deviceSettings.keys) { deviceSettings[key]?.sanitize() }
        if !outputGroups.contains(where: { $0.id == selectedGroupID }) { selectedGroupID = nil }
        customPresets = customPresets.filter { $0.gains.count == 10 && $0.gains.allSatisfy(\.isFinite) }
        for i in customPresets.indices {
            customPresets[i].gains = customPresets[i].gains.map { min(12, max(-12, $0)) }
            customPresets[i].preamp = customPresets[i].preamp.isFinite ? min(0, max(-24, customPresets[i].preamp)) : 0
        }
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channels: Int
    let sampleRate: Double
    let transport: UInt32
    var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }
}

struct AudioApplication: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleURL: URL?
    var processes: [AudioObjectID]
    var pids: [pid_t]
    var outputDevices: Set<AudioObjectID>
}
