import Foundation
import CoreAudio
import Synchronization

final class VirtualRouteRequest {
    let cancelled=Atomic<Bool>(false)
    func cancel() { cancelled.store(true,ordering:.releasing) }
}

/// Client-side control only. None of this code runs inside the AudioServerPlugIn.
enum VirtualLatencyOutput {
    static let timingUID = "com.avanturation.Vanille.LatencyClock.Device"
    static let control: AudioObjectPropertySelector = 0x766C6174

    static func timingDevice() throws -> AudioObjectID {
        // Hidden devices are intentionally absent from kAudioHardwarePropertyDevices.
        let uid = timingUID as CFString
        var qualifier: UnsafeMutableRawPointer? = Unmanaged.passUnretained(uid).toOpaque()
        var object: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = HAL.address(kAudioHardwarePropertyTranslateUIDToDevice)
        try HAL.check(AudioObjectGetPropertyData(HAL.system, &property, UInt32(MemoryLayout.size(ofValue: qualifier)), &qualifier, &size, &object), "Resolve hidden Vanille timing device")
        guard object != 0 else { throw AudioFailure(operation: "Vanille timing driver is not installed or loaded; the original output is unchanged", status: kAudioHardwareBadDeviceError) }
        return object
    }

    static func configure(_ device: AudioObjectID, frames: UInt32) throws {
        let text = String(frames) as CFString
        let payload = Unmanaged.passUnretained(text).toOpaque()
        try withExtendedLifetime(text) { try HAL.write(device, control, value: payload) }
        // AudioServerPlugIn changes are asynchronous and host-approved. Never assume setter completion.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if try HAL.read(device, kAudioDevicePropertyLatency, default: UInt32.max, scope: kAudioObjectPropertyScopeOutput) == frames { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        throw AudioFailure(operation: "The audio server did not approve the timing configuration", status: kAudioHardwareNotReadyError)
    }

    static func composition(physical: OutputDevice, timing: AudioObjectID, mainTiming: Bool, isPrivate: Bool, uid: String, stacked:Int=0) -> [String: Any] {
        [kAudioAggregateDeviceNameKey: "Vanille Video Output",
         kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: isPrivate ? 1 : 0,
         kAudioAggregateDeviceIsStackedKey: stacked,
         kAudioAggregateDeviceMainSubDeviceKey: mainTiming ? timingUID : physical.uid,
         kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: physical.uid, kAudioSubDeviceDriftCompensationKey: mainTiming ? 1 : 0] as [String: Any],
            [kAudioSubDeviceUIDKey: timingUID, kAudioSubDeviceDriftCompensationKey: mainTiming ? 0 : 1] as [String: Any]]]
    }

    static func actualComposition(_ object:AudioObjectID)->[String:Any] {
        var property=HAL.address(kAudioAggregateDevicePropertyComposition),pointer:Unmanaged<CFDictionary>?
        var size=UInt32(MemoryLayout.size(ofValue:pointer))
        guard AudioObjectGetPropertyData(object,&property,0,nil,&size,&pointer)==noErr,
              let dictionary=pointer?.takeRetainedValue() as? [String:Any] else { return [:] }
        return dictionary
    }

    /// Read-only with respect to global routing and physical-device properties.
    /// Tests whether real device latency survives aggregation, unlike the earlier safety-offset probe.
    static func probe(physical: OutputDevice) -> [String: Any] {
        let original = DeviceManager().defaultOutput()
        var report: [String: Any] = ["scope": "Private and unselected public virtual-plus-physical aggregates. No default output change. No Safari acceptance claim.", "audioSaved": false]
        var rows = [[String: Any]]()
        var timing: AudioObjectID = 0
        var previous: UInt32 = 0
        do {
            timing = try timingDevice()
            previous = try HAL.read(timing, kAudioDevicePropertyLatency, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
            report["timingDriverLoaded"] = true
            report["timingReportedDefaultEligibility"] = try HAL.read(timing, kAudioDevicePropertyDeviceCanBeDefaultDevice, default: UInt32.max, scope: kAudioObjectPropertyScopeOutput)
            report["hidden"] = try HAL.read(timing, kAudioDevicePropertyIsHidden, default: UInt32(0))
            report["physicalCanBeDefault"]=try HAL.read(physical.id,kAudioDevicePropertyDeviceCanBeDefaultDevice,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
            for frames: UInt32 in [0, 192_000] {
                try configure(timing, frames: frames)
                for (isPrivate, mainTiming, stacked) in [(true,false,0),(true,true,0),(false,false,0),(false,true,0),(false,false,1),(false,true,1)] {
                    var aggregate: AudioObjectID = 0
                    var row: [String: Any] = ["driverLatencyFrames": frames, "timingIsMain": mainTiming, "isPrivate":isPrivate, "requestedStacked":stacked]
                    let observer = HardwareTimingProbe()
                    do {
                        let uid = "com.avanturation.Vanille.virtual-probe.\(UUID().uuidString)"
                        try HAL.check(AudioHardwareCreateAggregateDevice(composition(physical: physical, timing: timing, mainTiming: mainTiming, isPrivate: isPrivate, uid: uid,stacked:stacked) as CFDictionary, &aggregate), "Create virtual timing probe")
                        Thread.sleep(forTimeInterval: 0.2)
                        let actual=actualComposition(aggregate)
                        row["actualStacked"]=actual[kAudioAggregateDeviceIsStackedKey] ?? "absent"
                        row["actualPrivate"]=actual[kAudioAggregateDeviceIsPrivateKey] ?? "absent"
                        row["outputChannels"] = try HAL.channelCount(aggregate, scope: kAudioObjectPropertyScopeOutput)
                        row["deviceLatencyFrames"] = try HAL.read(aggregate, kAudioDevicePropertyLatency, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
                        row["safetyOffsetFrames"] = try HAL.read(aggregate, kAudioDevicePropertySafetyOffset, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
                        row["canBeDefault"] = try HAL.read(aggregate, kAudioDevicePropertyDeviceCanBeDefaultDevice, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
                        row["aggregateHidden"]=try HAL.read(aggregate,kAudioDevicePropertyIsHidden,default:UInt32(0))
                        row["sampleRate"] = try HAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, default: Double(0))
                        row["streams"] = try HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).map { stream -> [String: Any] in
                            ["latencyFrames": (try? HAL.read(stream, kAudioStreamPropertyLatency, default: UInt32(0))) ?? 0,
                             "firstChannel": (try? HAL.read(stream, kAudioStreamPropertyStartingChannel, default: UInt32(0))) ?? 0]
                        }
                        try observer.start(aggregate)
                        Thread.sleep(forTimeInterval: 0.4)
                        row["canBeDefaultWhileRunning"]=try HAL.read(aggregate,kAudioDevicePropertyDeviceCanBeDefaultDevice,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
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

/// Owns a public aggregate, never a standalone null output. Lifecycle is driven by
/// explicit app actions and the audio-engine failure path, not UI refresh ticks.
final class LatencyDeclaredRoute {
    static let uid = "com.avanturation.Vanille.VideoOutput.Experiment"
    let physical: OutputDevice
    private(set) var object: AudioObjectID = 0
    private(set) var timing: AudioObjectID = 0
    private var previousLatency: UInt32 = 0
    private var previousDefault: AudioObjectID = 0
    private(set) var cleanup = [String: Int32]()
    private(set) var declaredFrames: UInt32 = 0
    private(set) var mainTiming = false
    private var canBeDefault:UInt32=0
    private var hidden:UInt32=0
    private var activationWaitMS=0.0

    init(physical: OutputDevice, frames: UInt32, mainTiming: Bool) throws {
        self.physical = physical; self.mainTiming = mainTiming
        previousDefault = DeviceManager().defaultOutput()
        guard previousDefault == physical.id, physical.channels == 2, !physical.isAirPlay,
              abs(physical.sampleRate - 48_000) < 1 else {
            throw AudioFailure(operation: "Restore MR4 before creating the experimental video output", status: -1)
        }
        do {
            let existing = try HAL.objects(HAL.system, kAudioHardwarePropertyDevices).filter {
                (try? HAL.string($0, kAudioDevicePropertyDeviceUID)) == Self.uid
            }
            // Do not silently take ownership of a device left by another instance.
            guard existing.isEmpty else { throw AudioFailure(operation: "An earlier Vanille experimental output still exists; restore it before retrying", status: -1) }
            timing = try VirtualLatencyOutput.timingDevice()
            previousLatency = try HAL.read(timing, kAudioDevicePropertyLatency, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
            try VirtualLatencyOutput.configure(timing, frames: frames)
            try HAL.check(AudioHardwareCreateAggregateDevice(VirtualLatencyOutput.composition(physical: physical, timing: timing,
                mainTiming: mainTiming, isPrivate: false, uid: Self.uid,stacked:1) as CFDictionary, &object), "Create latency-aware system output")
            Thread.sleep(forTimeInterval: 0.2)
            let channels = try HAL.channelCount(object, scope: kAudioObjectPropertyScopeOutput)
            canBeDefault=try HAL.read(object,kAudioDevicePropertyDeviceCanBeDefaultDevice,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
            hidden=try HAL.read(object,kAudioDevicePropertyIsHidden,default:UInt32(0))
            guard channels == 2 else {
                throw AudioFailure(operation: "The virtual aggregate cannot provide a mirrored stereo output", status: -1)
            }
            let latency = try HAL.read(object, kAudioDevicePropertyLatency, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
            guard latency >= frames, latency <= frames + 4_800 else {
                throw AudioFailure(operation: "The aggregate did not expose the real downstream latency; original output retained", status: -1)
            }
            declaredFrames = frames
        } catch { restore(); throw error }
    }

    func activate(cancelled:()->Bool = {false}) throws {
        guard object != 0, DeviceManager().defaultOutput() == previousDefault else {
            throw AudioFailure(operation: "Default output changed before activating video routing", status: -1)
        }
        guard !cancelled() else { throw AudioFailure(operation:"Video output request cancelled",status:-1) }
        try HAL.write(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, value: object)
        let started=Date(),deadline=started.addingTimeInterval(3)
        repeat {
            if cancelled() { throw AudioFailure(operation:"Video output request cancelled",status:-1) }
            let current=DeviceManager().defaultOutput()
            if current==object { activationWaitMS=Date().timeIntervalSince(started)*1000;return }
            if current != previousDefault { throw AudioFailure(operation:"Another output was selected during video setup",status:-1) }
            Thread.sleep(forTimeInterval:0.02)
        } while Date()<deadline
        activationWaitMS=Date().timeIntervalSince(started)*1000
        throw AudioFailure(operation: "The audio server did not select the experimental output", status: -1)
    }

    func restore() {
        guard object != 0 || timing != 0 else { return }
        if object != 0, DeviceManager().defaultOutput() == object {
            do {
                let alive = (try? HAL.read(physical.id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0))) == 1
                let fallback = alive ? physical.id : (try DeviceManager().outputs().first { !$0.isAirPlay && $0.channels > 0 }?.id ?? 0)
                guard fallback != 0 else { throw AudioFailure(operation: "No original output is available", status: -1) }
                try HAL.write(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, value: fallback)
                cleanup["restoreDefault"] = noErr
            } catch {
                cleanup["restoreDefault"] = (error as? AudioFailure)?.status ?? -1
                // Keep the physical aggregate alive if restoring the default failed.
                return
            }
        }
        if object != 0 {
            cleanup["destroyAggregate"] = AudioHardwareDestroyAggregateDevice(object)
            if cleanup["destroyAggregate"] != noErr { return }
            object = 0
        }
        if timing != 0 {
            do { try VirtualLatencyOutput.configure(timing, frames: previousLatency); cleanup["restoreLatency"] = noErr; timing = 0 }
            catch { cleanup["restoreLatency"] = (error as? AudioFailure)?.status ?? -1 }
        }
    }
    var snapshot: [String: Any] {
        ["aggregateExists": object != 0, "isSystemDefault": object != 0 && DeviceManager().defaultOutput() == object,
         "declaredFrames": declaredFrames, "declaredMS": Double(declaredFrames) / 48,
         "canBeDefault":canBeDefault,"hidden":hidden,"activationWaitMS":activationWaitMS,
         "timingIsMain": mainTiming, "cleanup": cleanup, "externalVideoSyncVerified": false]
    }
    deinit { restore() }
}
