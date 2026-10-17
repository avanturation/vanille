import Foundation
import CoreAudio

final class DeviceManager {
    func outputs() throws -> [OutputDevice] {
        try HAL.objects(HAL.system, kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = try? HAL.string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.avanturation.Vanille."),
                  let channels = try? HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput), channels > 0,
                  (try? HAL.read(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0))) == 1 else { return nil }
            return OutputDevice(id: id, uid: uid,
                name: (try? HAL.string(id, kAudioObjectPropertyName)) ?? "Audio Output",
                channels: channels,
                sampleRate: (try? HAL.read(id, kAudioDevicePropertyNominalSampleRate, default: Double(0))) ?? 0,
                transport: (try? HAL.read(id, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func defaultOutput() -> AudioObjectID {
        (try? HAL.read(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))) ?? 0
    }
    func select(_ device: OutputDevice) throws {
        try HAL.write(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, value: device.id)
    }
    private func volumeElements(_ id: AudioObjectID) -> [UInt32] {
        if HAL.isSettable(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput) { return [0] }
        let channels = (try? HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)) ?? 0
        return channels > 0 ? (1...UInt32(channels)).filter {
            HAL.isSettable(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0)
        } : []
    }
    func volume(_ id: AudioObjectID) -> Float? {
        let elements = volumeElements(id)
        let values = elements.compactMap { try? HAL.read(id, kAudioDevicePropertyVolumeScalar, default: Float(1), scope: kAudioObjectPropertyScopeOutput, element: $0) }
        return values.isEmpty ? nil : values.reduce(0,+) / Float(values.count)
    }
    func setVolume(_ value: Float, on id: AudioObjectID) throws {
        let elements = volumeElements(id)
        guard !elements.isEmpty else { throw AudioFailure(operation: "This output uses its own volume control", status: kAudioHardwareUnsupportedOperationError) }
        for element in elements {
            try HAL.write(id, kAudioDevicePropertyVolumeScalar, value: min(1,max(0,value)), scope: kAudioObjectPropertyScopeOutput, element: element)
        }
        if value > 0, HAL.isSettable(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) {
            try? HAL.write(id, kAudioDevicePropertyMute, value: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        }
    }
}
