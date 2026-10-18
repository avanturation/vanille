import Foundation
import CoreAudio
import CoreFoundation
import Synchronization
import Darwin

// A hidden timing participant for an aggregate that also contains a physical output.
// This device deliberately has no input stream, network access, audio storage or HAL-client calls.
// It must never be selected as a standalone output: it discards its output copy.
enum LatencyClock {
    static let device: AudioObjectID = 2
    static let stream: AudioObjectID = 3
    static let rate = 48_000.0
    static let period: UInt32 = 16_384 // AudioServerPlugIn requires at least 10,923 frames.
    static let maximumLatency: UInt32 = 480_000
    static let latencyControl: AudioObjectPropertySelector = 0x766C6174 // 'vlat', frames at 48 kHz
    static let deviceUID = "com.avanturation.Vanille.LatencyClock.Device" as CFString
    static let bundleID = "com.avanturation.Vanille.LatencyClock" as CFString
    static let name = "Vanille Video Timing" as CFString
    static let maker = "Vanille" as CFString
    static let empty = "" as CFString
    static let modelUID = "com.avanturation.Vanille.LatencyClock.Model" as CFString
    static let typeUUID = CFUUIDCreateFromString(nil, "443ABAB8-E7B3-491A-B985-BEB9187030DB" as CFString)!
    static let interfaceUUID = CFUUIDCreateFromString(nil, "EEA5773D-CC43-49F1-8E00-8F96E7D23B17" as CFString)!
    static let unknownUUID = CFUUIDCreateFromString(nil, "00000000-0000-0000-C000-000000000046" as CFString)!
    static let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
}

private final class ClockState {
    let references = Atomic<UInt32>(0)
    let latency = Atomic<UInt32>(0)
    let ioClients = Atomic<UInt32>(0)
    let writes = Atomic<UInt64>(0)
    let frames = Atomic<UInt64>(0)
    let epoch: UInt64
    let ticksPerFrame: Double
    // Only lifecycle/control callbacks use this lock. No realtime callback touches it.
    let lifecycle = NSLock()
    var clients = Set<UInt32>()
    var running = Set<UInt32>()
    var host: AudioServerPlugInHostRef?

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerFrame = 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer) / LatencyClock.rate
        epoch = mach_absolute_time()
    }
}
private let clockState = ClockState()

private enum PropertyValue {
    case word(UInt32), number(Double), string(CFString), ids([UInt32]), range(AudioValueRange)
    case format(AudioStreamBasicDescription), rangedFormat(AudioStreamRangedDescription)
    case custom(AudioServerPlugInCustomPropertyInfo)

    var size: UInt32 {
        switch self {
        case .word: return 4
        case .number: return 8
        case .string: return UInt32(MemoryLayout<CFString?>.size)
        case .ids(let values): return UInt32(values.count * 4)
        case .range: return UInt32(MemoryLayout<AudioValueRange>.size)
        case .format: return UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        case .rangedFormat: return UInt32(MemoryLayout<AudioStreamRangedDescription>.size)
        case .custom: return UInt32(MemoryLayout<AudioServerPlugInCustomPropertyInfo>.size)
        }
    }
    func copy(to output: UnsafeMutableRawPointer, capacity: UInt32, used: UnsafeMutablePointer<UInt32>) -> OSStatus {
        used.pointee = 0
        guard capacity >= size else { return kAudioHardwareBadPropertySizeError }
        func put<T>(_ value: T) {
            var value = value
            withUnsafeBytes(of: &value) { bytes in
                if let base = bytes.baseAddress, !bytes.isEmpty { output.copyMemory(from: base, byteCount: bytes.count) }
            }
        }
        switch self {
        case .word(let v): put(v)
        case .number(let v): put(v)
        case .string(let v): put(Unmanaged.passRetained(v).toOpaque()) // HAL owns returned CF object.
        case .ids(let v): v.withUnsafeBytes { if let base = $0.baseAddress, !$0.isEmpty { output.copyMemory(from: base, byteCount: $0.count) } }
        case .range(let v): put(v)
        case .format(let v): put(v)
        case .rangedFormat(let v): put(v)
        case .custom(let v): put(v)
        }
        used.pointee = size
        return noErr
    }
}

private func validObject(_ object: AudioObjectID) -> Bool {
    object == kAudioObjectPlugInObject || object == LatencyClock.device || object == LatencyClock.stream
}

// Property queries are control-plane operations. Allocating small returned lists here is intentional.
private func property(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                      qualifierSize: UInt32 = 0, qualifier: UnsafeRawPointer? = nil) -> PropertyValue? {
    guard validObject(object), address.mElement == kAudioObjectPropertyElementMain else { return nil }
    let scope = address.mScope
    guard scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput else { return nil }
    switch address.mSelector {
    case kAudioObjectPropertyBaseClass: return .word(kAudioObjectClassID)
    case kAudioObjectPropertyClass:
        return .word(object == 1 ? kAudioPlugInClassID : object == 2 ? kAudioDeviceClassID : kAudioStreamClassID)
    case kAudioObjectPropertyOwner: return .word(object == 1 ? kAudioObjectUnknown : object == 2 ? 1 : 2)
    case kAudioObjectPropertyName: return .string(LatencyClock.name)
    case kAudioObjectPropertyManufacturer: return .string(LatencyClock.maker)
    case kAudioObjectPropertyOwnedObjects:
        if object == 1 { return .ids([2]) }
        if object == 2 { return .ids(scope == kAudioObjectPropertyScopeInput ? [] : [3]) }
        return .ids([])
    default: break
    }
    if object == kAudioObjectPlugInObject, scope == kAudioObjectPropertyScopeGlobal {
        switch address.mSelector {
        case kAudioPlugInPropertyBundleID: return .string(LatencyClock.bundleID)
        case kAudioPlugInPropertyDeviceList: return .ids([2])
        case kAudioPlugInPropertyTranslateUIDToDevice:
            guard qualifierSize == MemoryLayout<CFString?>.size, let qualifier else { return .word(kAudioObjectUnknown) }
            let candidate = qualifier.load(as: UnsafeRawPointer?.self).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() }
            return .word(candidate.map { CFEqual($0, LatencyClock.deviceUID) } == true ? 2 : kAudioObjectUnknown)
        case kAudioPlugInPropertyBoxList, kAudioPlugInPropertyClockDeviceList: return .ids([])
        case kAudioPlugInPropertyResourceBundle: return .string(LatencyClock.empty)
        default: return nil
        }
    }
    if object == LatencyClock.device {
        switch address.mSelector {
        case kAudioDevicePropertyDeviceUID: return .string(LatencyClock.deviceUID)
        case kAudioDevicePropertyModelUID: return .string(LatencyClock.modelUID)
        case kAudioDevicePropertyTransportType: return .word(kAudioDeviceTransportTypeVirtual)
        case kAudioDevicePropertyRelatedDevices: return .ids([2])
        case kAudioDevicePropertyClockDomain: return .word(0)
        case kAudioDevicePropertyDeviceIsAlive: return .word(1)
        case kAudioDevicePropertyDeviceIsRunning: return .word(clockState.ioClients.load(ordering: .acquiring) > 0 ? 1 : 0)
        case kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return .word(0)
        case kAudioDevicePropertyIsHidden: return .word(1)
        case kAudioDevicePropertyLatency: return .word(scope == kAudioObjectPropertyScopeOutput ? clockState.latency.load(ordering: .acquiring) : 0)
        case kAudioDevicePropertySafetyOffset: return .word(0)
        case kAudioDevicePropertyStreams: return .ids(scope == kAudioObjectPropertyScopeInput ? [] : [3])
        case kAudioObjectPropertyControlList: return .ids([])
        case kAudioDevicePropertyNominalSampleRate: return .number(LatencyClock.rate)
        case kAudioDevicePropertyAvailableNominalSampleRates: return .range(AudioValueRange(mMinimum: LatencyClock.rate, mMaximum: LatencyClock.rate))
        case kAudioDevicePropertyZeroTimeStampPeriod: return .word(LatencyClock.period)
        case kAudioDevicePropertyClockAlgorithm: return .word(AudioDeviceClockAlgorithmSelector.algorithmRaw.rawValue)
        case kAudioDevicePropertyClockIsStable: return .word(1)
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return scope == kAudioObjectPropertyScopeOutput ? .ids([1, 2]) : nil
        case LatencyClock.latencyControl:
            return scope == kAudioObjectPropertyScopeGlobal ? .string(String(clockState.latency.load(ordering: .acquiring)) as CFString) : nil
        case kAudioObjectPropertyCustomPropertyInfoList:
            return .custom(AudioServerPlugInCustomPropertyInfo(mSelector: LatencyClock.latencyControl,
                mPropertyDataType: kAudioServerPlugInCustomPropertyDataTypeCFString,
                mQualifierDataType: kAudioServerPlugInCustomPropertyDataTypeNone))
        default: return nil
        }
    }
    if object == LatencyClock.stream {
        switch address.mSelector {
        case kAudioStreamPropertyIsActive: return .word(1)
        case kAudioStreamPropertyDirection: return .word(0)
        case kAudioStreamPropertyTerminalType: return .word(kAudioStreamTerminalTypeSpeaker)
        case kAudioStreamPropertyStartingChannel: return .word(1)
        case kAudioStreamPropertyLatency: return .word(0)
        case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat: return .format(LatencyClock.format)
        case kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats:
            return .rangedFormat(AudioStreamRangedDescription(mFormat: LatencyClock.format,
                mSampleRateRange: AudioValueRange(mMinimum: LatencyClock.rate, mMaximum: LatencyClock.rate)))
        default: return nil
        }
    }
    return nil
}

private func sameFormat(_ value: AudioStreamBasicDescription) -> Bool {
    let f = LatencyClock.format
    return value.mSampleRate == f.mSampleRate && value.mFormatID == f.mFormatID && value.mFormatFlags == f.mFormatFlags &&
        value.mBytesPerPacket == f.mBytesPerPacket && value.mFramesPerPacket == f.mFramesPerPacket &&
        value.mBytesPerFrame == f.mBytesPerFrame && value.mChannelsPerFrame == f.mChannelsPerFrame && value.mBitsPerChannel == f.mBitsPerChannel
}

private func makeInterface() -> AudioServerPlugInDriverInterface {
    return AudioServerPlugInDriverInterface(_reserved: nil, QueryInterface: { _, uuid, output in
        guard let output else { return HRESULT(bitPattern: 0x80000005) } // E_POINTER, signed ABI
        output.pointee = nil
        let requested = CFUUIDCreateFromUUIDBytes(nil, uuid)
        guard CFEqual(requested, LatencyClock.interfaceUUID) || CFEqual(requested, LatencyClock.unknownUUID) else { return HRESULT(bitPattern: 0x80000004) } // E_NOINTERFACE
        _ = clockState.references.wrappingAdd(1, ordering: .relaxed)
        output.pointee = UnsafeMutableRawPointer(driverReference)
        return S_OK
    }, AddRef: { _ in clockState.references.wrappingAdd(1, ordering: .relaxed).newValue }, Release: { _ in
        // The static singleton remains allocated for the process lifetime.
        var old = clockState.references.load(ordering: .relaxed)
        while old > 0 {
            let change = clockState.references.compareExchange(expected: old, desired: old - 1, ordering: .relaxed)
            if change.exchanged { return old - 1 }
            old = change.original
        }
        return 0
    }, Initialize: { _, host in
        clockState.lifecycle.lock(); defer { clockState.lifecycle.unlock() }
        clockState.host = host
        return noErr
    }, CreateDevice: { _, _, _, output in output.pointee = kAudioObjectUnknown; return kAudioHardwareUnsupportedOperationError },
    DestroyDevice: { _, _ in kAudioHardwareUnsupportedOperationError }, AddDeviceClient: { _, object, info in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        clockState.lifecycle.lock(); defer { clockState.lifecycle.unlock() }
        clockState.clients.insert(info.pointee.mClientID)
        return noErr
    }, RemoveDeviceClient: { _, object, info in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        clockState.lifecycle.lock(); defer { clockState.lifecycle.unlock() }
        clockState.clients.remove(info.pointee.mClientID)
        clockState.running.remove(info.pointee.mClientID)
        clockState.ioClients.store(UInt32(clockState.running.count), ordering: .releasing)
        return noErr
    }, PerformDeviceConfigurationChange: { _, object, frames, _ in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        guard frames <= UInt64(LatencyClock.maximumLatency) else { return kAudioHardwareIllegalOperationError }
        // Only the host's approved configuration callback can change presentation latency.
        clockState.latency.store(UInt32(frames), ordering: .releasing)
        return noErr
    }, AbortDeviceConfigurationChange: { _, object, _, _ in object == LatencyClock.device ? noErr : kAudioHardwareBadObjectError },
    HasProperty: { _, object, _, address in DarwinBoolean(property(object, address.pointee) != nil) }, IsPropertySettable: { _, object, _, address, output in
        guard validObject(object) else { return kAudioHardwareBadObjectError }
        guard property(object, address.pointee) != nil else { return kAudioHardwareUnknownPropertyError }
        let s = address.pointee.mSelector
        output.pointee = DarwinBoolean((object == 2 && (s == LatencyClock.latencyControl || s == kAudioDevicePropertyNominalSampleRate)) ||
            (object == 3 && (s == kAudioStreamPropertyPhysicalFormat || s == kAudioStreamPropertyVirtualFormat || s == kAudioStreamPropertyIsActive)))
        return noErr
    }, GetPropertyDataSize: { _, object, _, address, qualifierSize, qualifier, output in
        output.pointee = 0
        guard validObject(object) else { return kAudioHardwareBadObjectError }
        guard let value = property(object, address.pointee, qualifierSize: qualifierSize, qualifier: qualifier) else { return kAudioHardwareUnknownPropertyError }
        output.pointee = value.size
        return noErr
    }, GetPropertyData: { _, object, _, address, qualifierSize, qualifier, capacity, used, output in
        used.pointee = 0
        guard validObject(object) else { return kAudioHardwareBadObjectError }
        guard let value = property(object, address.pointee, qualifierSize: qualifierSize, qualifier: qualifier) else { return kAudioHardwareUnknownPropertyError }
        return value.copy(to: output, capacity: capacity, used: used)
    }, SetPropertyData: { _, object, _, address, _, _, size, data in
        guard validObject(object) else { return kAudioHardwareBadObjectError }
        guard property(object, address.pointee) != nil else { return kAudioHardwareUnknownPropertyError }
        switch (object, address.pointee.mSelector) {
        case (2, LatencyClock.latencyControl):
            // Custom properties can marshal CFString/CFPropertyList or no data.
            // Raw UInt32 is NOT a supported AudioServerPlugIn custom-property wire type.
            guard size == MemoryLayout<UnsafeRawPointer?>.size else { return kAudioHardwareBadPropertySizeError }
            guard let pointer = data.loadUnaligned(as: UnsafeRawPointer?.self) else { return kAudioHardwareIllegalOperationError }
            let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(object) == CFStringGetTypeID(),
                  let frames = UInt32((object as! CFString) as String) else { return kAudioHardwareIllegalOperationError }
            guard frames <= LatencyClock.maximumLatency else { return kAudioHardwareIllegalOperationError }
            if frames == clockState.latency.load(ordering: .acquiring) { return noErr }
            clockState.lifecycle.lock(); let host = clockState.host; clockState.lifecycle.unlock()
            guard let host else { return kAudioHardwareNotReadyError }
            return host.pointee.RequestDeviceConfigurationChange(host, 2, UInt64(frames), nil)
        case (2, kAudioDevicePropertyNominalSampleRate):
            guard size == 8 else { return kAudioHardwareBadPropertySizeError }
            return data.loadUnaligned(as: Double.self) == LatencyClock.rate ? noErr : kAudioHardwareIllegalOperationError
        case (3, kAudioStreamPropertyPhysicalFormat), (3, kAudioStreamPropertyVirtualFormat):
            guard size == MemoryLayout<AudioStreamBasicDescription>.size else { return kAudioHardwareBadPropertySizeError }
            return sameFormat(data.loadUnaligned(as: AudioStreamBasicDescription.self)) ? noErr : kAudioDeviceUnsupportedFormatError
        case (3, kAudioStreamPropertyIsActive):
            guard size == 4 else { return kAudioHardwareBadPropertySizeError }
            return data.loadUnaligned(as: UInt32.self) == 1 ? noErr : kAudioHardwareIllegalOperationError
        default: return kAudioHardwareUnsupportedOperationError
        }
    }, StartIO: { _, object, client in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        clockState.lifecycle.lock(); defer { clockState.lifecycle.unlock() }
        guard clockState.clients.contains(client) else { return kAudioHardwareIllegalOperationError }
        clockState.running.insert(client)
        clockState.ioClients.store(UInt32(clockState.running.count), ordering: .releasing)
        return noErr
    }, StopIO: { _, object, client in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        clockState.lifecycle.lock(); defer { clockState.lifecycle.unlock() }
        clockState.running.remove(client)
        clockState.ioClients.store(UInt32(clockState.running.count), ordering: .releasing)
        return noErr
    }, GetZeroTimeStamp: { _, object, _, sample, host, seed in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        let now = mach_absolute_time()
        let elapsed = now >= clockState.epoch ? now - clockState.epoch : 0
        let periodTicks = clockState.ticksPerFrame * Double(LatencyClock.period)
        let periods = floor(Double(elapsed) / periodTicks)
        sample.pointee = periods * Double(LatencyClock.period)
        host.pointee = clockState.epoch + UInt64(periods * periodTicks)
        seed.pointee = 1 // Epoch remains stable across client start/stop cycles.
        return noErr
    }, WillDoIOOperation: { _, object, _, operation, willDo, inPlace in
        guard object == LatencyClock.device else { return kAudioHardwareBadObjectError }
        willDo.pointee = DarwinBoolean(operation == AudioServerPlugInIOOperation.writeMix.rawValue)
        inPlace.pointee = true
        return noErr
    }, BeginIOOperation: { _, object, _, _, _, _ in object == LatencyClock.device ? noErr : kAudioHardwareBadObjectError },
    DoIOOperation: { _, object, stream, _, operation, frames, _, buffer, _ in
        guard object == LatencyClock.device, stream == LatencyClock.stream else { return kAudioHardwareBadObjectError }
        guard operation == AudioServerPlugInIOOperation.writeMix.rawValue else { return kAudioHardwareUnsupportedOperationError }
        guard frames == 0 || buffer != nil else { return kAudioHardwareIllegalOperationError }
        _ = clockState.writes.wrappingAdd(1, ordering: .relaxed)
        _ = clockState.frames.wrappingAdd(UInt64(frames), ordering: .relaxed)
        return noErr // Timing participant only. The physical aggregate subdevice retains its copy.
    }, EndIOOperation: { _, object, _, _, _, _ in object == LatencyClock.device ? noErr : kAudioHardwareBadObjectError })
}

private let driverInterface: UnsafeMutablePointer<AudioServerPlugInDriverInterface> = {
    let value = UnsafeMutablePointer<AudioServerPlugInDriverInterface>.allocate(capacity: 1)
    value.initialize(to: makeInterface())
    return value
}()
private let driverReference: AudioServerPlugInDriverRef = {
    let reference = AudioServerPlugInDriverRef.allocate(capacity: 1)
    reference.initialize(to: driverInterface)
    return reference
}()

@_cdecl("VanilleLatencyClockFactory")
public func VanilleLatencyClockFactory(_ allocator: CFAllocator?, _ requestedType: CFUUID?) -> UnsafeMutableRawPointer? {
    guard let requestedType, CFEqual(requestedType, LatencyClock.typeUUID) else { return nil }
    // Force initialization of all state on the loading thread, before any realtime callback.
    _ = clockState.epoch
    _ = LatencyClock.format
    _ = LatencyClock.deviceUID
    _ = clockState.references.wrappingAdd(1, ordering: .relaxed)
    return UnsafeMutableRawPointer(driverReference)
}
