import Foundation
import CoreAudio

/// Client-side control only. None of this code runs inside the AudioServerPlugIn.
enum VirtualLatencyOutput {
    static let timingUID = "com.avanturation.Vanille.LatencyClock.Device"
    static let control: AudioObjectPropertySelector = 0x766C6174

    static func timingDevice() throws -> AudioObjectID {
        guard let object = try HAL.objects(HAL.system, kAudioHardwarePropertyDevices).first(where: {
            (try? HAL.string($0, kAudioDevicePropertyDeviceUID)) == timingUID
        }) else { throw AudioFailure(operation: "Vanille timing driver is not installed or loaded; the original output is unchanged", status: kAudioHardwareBadDeviceError) }
        return object
    }

    static func configure(_ device: AudioObjectID, frames: UInt32) throws {
        try HAL.write(device, control, value: frames)
        // AudioServerPlugIn changes are asynchronous and host-approved. Never assume setter completion.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if try HAL.read(device, kAudioDevicePropertyLatency, default: UInt32.max, scope: kAudioObjectPropertyScopeOutput) == frames { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        throw AudioFailure(operation: "The audio server did not approve the timing configuration", status: kAudioHardwareNotReadyError)
    }

    static func composition(physical: OutputDevice, timing: AudioObjectID, mainTiming: Bool, isPrivate: Bool, uid: String) -> [String: Any] {
        [kAudioAggregateDeviceNameKey: "Vanille Video Output",
         kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: isPrivate,
         kAudioAggregateDeviceIsStackedKey: false,
         kAudioAggregateDeviceMainSubDeviceKey: mainTiming ? timingUID : physical.uid,
         kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: physical.uid, kAudioSubDeviceDriftCompensationKey: mainTiming] as [String: Any],
            [kAudioSubDeviceUIDKey: timingUID, kAudioSubDeviceDriftCompensationKey: !mainTiming] as [String: Any]]]
    }

    /// Read-only with respect to global routing and physical-device properties.
    /// Tests whether real device latency survives aggregation, unlike the earlier safety-offset probe.
    static func probe(physical: OutputDevice) -> [String: Any] {
        let original = DeviceManager().defaultOutput()
        var report: [String: Any] = ["scope": "Private virtual-plus-physical aggregates. No default output change. No Safari acceptance claim.", "audioSaved": false]
        var rows = [[String: Any]]()
        var timing: AudioObjectID = 0
        var previous: UInt32 = 0
        do {
            timing = try timingDevice()
            previous = try HAL.read(timing, control, default: UInt32(0))
            report["timingDriverLoaded"] = true
            report["standaloneDefaultAllowed"] = try HAL.read(timing, kAudioDevicePropertyDeviceCanBeDefaultDevice, default: UInt32.max, scope: kAudioObjectPropertyScopeOutput)
            report["hidden"] = try HAL.read(timing, kAudioDevicePropertyIsHidden, default: UInt32(0))
            for frames: UInt32 in [0, 192_000] {
                try configure(timing, frames: frames)
                for mainTiming in [false, true] {
                    var aggregate: AudioObjectID = 0
                    var row: [String: Any] = ["driverLatencyFrames": frames, "timingIsMain": mainTiming]
                    let observer = HardwareTimingProbe()
                    do {
                        let uid = "com.avanturation.Vanille.virtual-probe.\(UUID().uuidString)"
                        try HAL.check(AudioHardwareCreateAggregateDevice(composition(physical: physical, timing: timing, mainTiming: mainTiming, isPrivate: true, uid: uid) as CFDictionary, &aggregate), "Create virtual timing probe")
                        Thread.sleep(forTimeInterval: 0.2)
                        row["outputChannels"] = try HAL.channelCount(aggregate, scope: kAudioObjectPropertyScopeOutput)
                        row["deviceLatencyFrames"] = try HAL.read(aggregate, kAudioDevicePropertyLatency, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
                        row["safetyOffsetFrames"] = try HAL.read(aggregate, kAudioDevicePropertySafetyOffset, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
                        row["canBeDefault"] = try HAL.read(aggregate, kAudioDevicePropertyDeviceCanBeDefaultDevice, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
                        row["sampleRate"] = try HAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, default: Double(0))
                        row["streams"] = try HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).map { stream -> [String: Any] in
                            ["latencyFrames": (try? HAL.read(stream, kAudioStreamPropertyLatency, default: UInt32(0))) ?? 0,
                             "firstChannel": (try? HAL.read(stream, kAudioStreamPropertyStartingChannel, default: UInt32(0))) ?? 0]
                        }
                        try observer.start(aggregate)
                        Thread.sleep(forTimeInterval: 0.4)
                        row["ioTiming"] = observer.mailbox.consume().dictionary(frequency: AudioGetHostClockFrequency())
                    } catch { row["error"] = error.localizedDescription }
                    observer.stop();row["ioCleanup"] = observer.cleanup
                    if aggregate != 0 { row["destroyStatus"] = AudioHardwareDestroyAggregateDevice(aggregate) }
                    rows.append(row)
                }
            }
        } catch { report["error"] = error.localizedDescription }
        if timing != 0 {
            do { try configure(timing, frames: previous); report["latencyRestored"] = true }
            catch { report["restoreError"] = error.localizedDescription }
        }
        report["cases"] = rows
        report["defaultPreserved"] = DeviceManager().defaultOutput() == original
        return report
    }
}
