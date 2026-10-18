import Foundation
import CoreAudio
import CoreFoundation
import Darwin
import Synchronization

// Loads the actual built binary into this unprivileged test process, not the system audio server.
let bundlePath = CommandLine.arguments.dropFirst().first ?? "build/VanilleLatencyClock.driver"
let binary = bundlePath + "/Contents/MacOS/VanilleLatencyClock"
guard let handle = dlopen(binary, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
guard let symbol = dlsym(handle, "VanilleLatencyClockFactory") else { fatalError("Missing public CFPlugIn factory") }
typealias Factory = @convention(c) (CFAllocator?, CFUUID?) -> UnsafeMutableRawPointer?
let factory = unsafeBitCast(symbol, to: Factory.self)
let typeUUID = CFUUIDCreateFromString(nil, "443ABAB8-E7B3-491A-B985-BEB9187030DB" as CFString)!
let interfaceUUID = CFUUIDCreateFromString(nil, "EEA5773D-CC43-49F1-8E00-8F96E7D23B17" as CFString)!
let unknownUUID = CFUUIDCreateFromString(nil, "00000000-0000-0000-C000-000000000046" as CFString)!
let randomUUID = CFUUIDCreate(nil)!
var results = [(String, Bool)]()
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    let pass = condition(); results.append((name, pass)); print("\(pass ? "PASS" : "FAIL") \(name)")
}
let plugIn = CFPlugInCreate(nil, URL(fileURLWithPath: bundlePath, isDirectory: true) as CFURL)
let factories = plugIn.flatMap { CFPlugInFindFactoriesForPlugInTypeInPlugIn(typeUUID, $0) } as? [CFUUID]
check("Native CFPlugIn factory discovery", factories?.count == 1)
let pluginInstance = factories?.first.flatMap { CFPlugInInstanceCreate(nil, $0, typeUUID) }
check("Native CFPlugIn instance creation", pluginInstance != nil)
check("Factory rejects another plug-in type", factory(nil, randomUUID) == nil)
check("Factory rejects nil type", factory(nil, nil) == nil)
guard let raw = factory(nil, typeUUID) else { fatalError("Factory failed") }
let reference = raw.assumingMemoryBound(to: UnsafeMutablePointer<AudioServerPlugInDriverInterface>?.self)
guard let pointer = reference.pointee else { fatalError("Null interface") }
let api = pointer.pointee
var queried: UnsafeMutableRawPointer?
check("Driver QueryInterface", api.QueryInterface(raw, CFUUIDGetUUIDBytes(interfaceUUID), &queried) == noErr && queried == raw)
check("IUnknown QueryInterface", api.QueryInterface(raw, CFUUIDGetUUIDBytes(unknownUUID), &queried) == noErr && queried == raw)
check("QueryInterface rejects unsupported interface", api.QueryInterface(raw, CFUUIDGetUUIDBytes(randomUUID), &queried) != noErr && queried == nil)
check("QueryInterface handles nil output", api.QueryInterface(raw, CFUUIDGetUUIDBytes(interfaceUUID), nil) != noErr)
let added = api.AddRef(raw)
check("Reference retain/release balance", api.Release(raw) == added - 1)

final class HostState {
    let lock = NSLock()
    var requests = [(UInt32, UInt64)]()
    var notices = 0
    var rejectRequest = false
}
let hostState = HostState()
let host = UnsafeMutablePointer<AudioServerPlugInHostInterface>.allocate(capacity: 1)
host.initialize(to: AudioServerPlugInHostInterface(PropertiesChanged: { _, _, count, _ in
    hostState.lock.lock(); hostState.notices += Int(count); hostState.lock.unlock(); return noErr
}, CopyFromStorage: { _, _, output in output.pointee = nil; return kAudioHardwareUnknownPropertyError },
WriteToStorage: { _, _, _ in noErr }, DeleteFromStorage: { _, _ in noErr },
RequestDeviceConfigurationChange: { _, device, action, _ in
    hostState.lock.lock(); defer { hostState.lock.unlock() }
    if hostState.rejectRequest { return kAudioHardwareIllegalOperationError }
    hostState.requests.append((device, action)); return noErr
}))
check("Fake host initialization", api.Initialize(reference, host) == noErr)
let global = kAudioObjectPropertyScopeGlobal, output = kAudioObjectPropertyScopeOutput, input = kAudioObjectPropertyScopeInput
func address(_ selector: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal, _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}
func word(_ object: UInt32, _ selector: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> UInt32 {
    var a = address(selector, scope), value: UInt32 = .max, used: UInt32 = 0
    let status = api.GetPropertyData(reference, object, 0, &a, 0, nil, 4, &used, &value)
    if status != noErr || used != 4 { return .max }
    return value
}
func size(_ object: UInt32, _ selector: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> UInt32 {
    var a = address(selector, scope), size: UInt32 = .max
    let status = api.GetPropertyDataSize(reference, object, 0, &a, 0, nil, &size)
    return status == noErr ? size : .max
}
func setWord(_ object: UInt32, _ selector: UInt32, _ value: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> OSStatus {
    var a = address(selector, scope), value = value
    return api.SetPropertyData(reference, object, 0, &a, 0, nil, 4, &value)
}
let control: UInt32 = 0x766C6174
check("Plug-in publishes one device", size(1, kAudioPlugInPropertyDeviceList) == 4 && word(1, kAudioPlugInPropertyDeviceList) == 2)
check("Object ownership", word(2, kAudioObjectPropertyOwner) == 1 && word(3, kAudioObjectPropertyOwner) == 2)
check("Device and stream class", word(2, kAudioObjectPropertyClass) == kAudioDeviceClassID && word(3, kAudioObjectPropertyClass) == kAudioStreamClassID)
check("Hidden timing participant", word(2, kAudioDevicePropertyIsHidden) == 1)
check("Cannot become standalone default", word(2, kAudioDevicePropertyDeviceCanBeDefaultDevice, output) == 0 && word(2, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, output) == 0)
check("No input stream", size(2, kAudioDevicePropertyStreams, input) == 0)
check("One stereo output stream", word(2, kAudioDevicePropertyStreams, output) == 3 && word(3, kAudioStreamPropertyStartingChannel) == 1)
check("No volume controls to confuse aggregate", size(2, kAudioObjectPropertyControlList) == 0)
check("Initial output latency is zero", word(2, kAudioDevicePropertyLatency, output) == 0)
check("Required zero timestamp period", word(2, kAudioDevicePropertyZeroTimeStampPeriod) >= 10_923)
var a = address(kAudioDevicePropertyLatency, output), settable: DarwinBoolean = true
check("Standard latency property is read-only", api.IsPropertySettable(reference, 2, 0, &a, &settable) == noErr && !settable.boolValue)
check("Standard latency cannot be changed without handshake", setWord(2, kAudioDevicePropertyLatency, 1, output) != noErr)
a = address(control); settable = false
check("Declared custom control is writable", api.IsPropertySettable(reference, 2, 0, &a, &settable) == noErr && settable.boolValue && size(2, kAudioObjectPropertyCustomPropertyInfoList) == MemoryLayout<AudioServerPlugInCustomPropertyInfo>.size)
check("Latency request succeeds", setWord(2, control, 192_000) == noErr)
check("Request sent to host", hostState.requests.count == 1 && hostState.requests[0].0 == 2 && hostState.requests[0].1 == 192_000)
check("Latency remains unchanged until host accepts", word(2, kAudioDevicePropertyLatency, output) == 0)
check("Host can abort without changing latency", api.AbortDeviceConfigurationChange(reference, 2, 192_000, nil) == noErr && word(2, kAudioDevicePropertyLatency, output) == 0)
check("Host-approved change applies", api.PerformDeviceConfigurationChange(reference, 2, 192_000, nil) == noErr && word(2, kAudioDevicePropertyLatency, output) == 192_000)
check("Input latency remains zero", word(2, kAudioDevicePropertyLatency, input) == 0)
check("Safety offset remains independent", word(2, kAudioDevicePropertySafetyOffset, output) == 0)
check("Repeated equal latency does not restart IO", setWord(2, control, 192_000) == noErr && hostState.requests.count == 1)
check("Reject implausible latency", setWord(2, control, 480_001) != noErr && word(2, control) == 192_000)
check("Reject invalid host action", api.PerformDeviceConfigurationChange(reference, 2, UInt64.max, nil) != noErr && word(2, control) == 192_000)
hostState.rejectRequest = true
check("Host rejection propagates safely", setWord(2, control, 96_000) != noErr && word(2, control) == 192_000)
hostState.rejectRequest = false
var short: UInt16 = 5
check("Reject malformed setter size", api.SetPropertyData(reference, 2, 0, &a, 0, nil, 2, &short) == kAudioHardwareBadPropertySizeError)
var used: UInt32 = .max, shortOut: UInt32 = 0xDEADBEEF
check("Short read does not overwrite buffer", api.GetPropertyData(reference, 2, 0, &a, 0, nil, 2, &used, &shortOut) == kAudioHardwareBadPropertySizeError && shortOut == 0xDEADBEEF && used == 0)
a = address(0xFFFFFFFF)
check("Unknown properties are absent", !api.HasProperty(reference, 2, 0, &a).boolValue)
a = address(kAudioObjectPropertyClass, global, 99)
check("Invalid elements are absent", !api.HasProperty(reference, 2, 0, &a).boolValue)
a = address(kAudioObjectPropertyClass)
check("Invalid object fails safely", api.GetPropertyData(reference, 999, 0, &a, 0, nil, 4, &used, &shortOut) == kAudioHardwareBadObjectError)

// HAL owns returned CF strings. Exercise that ownership instead of leaking property results.
a = address(kAudioDevicePropertyDeviceUID)
var stringPointer: UnsafeMutableRawPointer?
let stringStatus = api.GetPropertyData(reference, 2, 0, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: stringPointer)), &used, &stringPointer)
let uid = stringPointer.map { Unmanaged<CFString>.fromOpaque($0).takeRetainedValue() }
check("Stable device UID and CF ownership", stringStatus == noErr && uid.map { CFEqual($0, "com.avanturation.Vanille.LatencyClock.Device" as CFString) } == true)
a = address(kAudioPlugInPropertyTranslateUIDToDevice)
var qualifier: UnsafeMutableRawPointer? = uid.map { Unmanaged.passUnretained($0).toOpaque() }
var translated: UInt32 = 0
check("UID translation", api.GetPropertyData(reference, 1, 0, &a, UInt32(MemoryLayout.size(ofValue: qualifier)), &qualifier, 4, &used, &translated) == noErr && translated == 2)

var format = AudioStreamBasicDescription()
a = address(kAudioStreamPropertyPhysicalFormat)
check("Interleaved stereo Float32 format", api.GetPropertyData(reference, 3, 0, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: format)), &used, &format) == noErr && format.mSampleRate == 48_000 && format.mBytesPerFrame == 8 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32)
check("Same format is accepted", api.SetPropertyData(reference, 3, 0, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: format)), &format) == noErr)
format.mSampleRate = 44_100
check("Unsupported rate cannot silently change clock", api.SetPropertyData(reference, 3, 0, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: format)), &format) != noErr)

var client = AudioServerPlugInClientInfo(mClientID: 42, mProcessID: getpid(), mIsNativeEndian: true, mBundleID: nil)
check("Unknown client cannot start", api.StartIO(reference, 2, 42) != noErr)
check("Client registration", api.AddDeviceClient(reference, 2, &client) == noErr)
check("IO starts", api.StartIO(reference, 2, 42) == noErr && word(2, kAudioDevicePropertyDeviceIsRunning) == 1)
check("Duplicate start is idempotent", api.StartIO(reference, 2, 42) == noErr)
var willDo: DarwinBoolean = false, inPlace: DarwinBoolean = false
let write = AudioServerPlugInIOOperation.writeMix.rawValue
let read = AudioServerPlugInIOOperation.readInput.rawValue
check("Native write operation in place", api.WillDoIOOperation(reference, 2, 42, write, &willDo, &inPlace) == noErr && willDo.boolValue && inPlace.boolValue)
check("No input capture operation", api.WillDoIOOperation(reference, 2, 42, read, &willDo, &inPlace) == noErr && !willDo.boolValue)
var cycle = AudioServerPlugInIOCycleInfo(), pcm = [Float](repeating: 0.125, count: 1024)
let writeStatus = pcm.withUnsafeMutableBytes { api.DoIOOperation(reference, 2, 3, 42, write, 512, &cycle, $0.baseAddress, nil) }
check("Write preserves physical aggregate's buffer", writeStatus == noErr && pcm.allSatisfy { $0 == 0.125 })
check("Null audio buffer rejected", api.DoIOOperation(reference, 2, 3, 42, write, 512, &cycle, nil, nil) != noErr)
check("Wrong stream rejected", api.DoIOOperation(reference, 2, 99, 42, write, 0, &cycle, nil, nil) != noErr)
check("Zero-frame write safe", api.DoIOOperation(reference, 2, 3, 42, write, 0, &cycle, nil, nil) == noErr)
var sample1 = 0.0, host1: UInt64 = 0, seed1: UInt64 = 0
check("Zero timestamp query", api.GetZeroTimeStamp(reference, 2, 42, &sample1, &host1, &seed1) == noErr && host1 > 0 && seed1 == 1)
usleep(350_000)
var sample2 = 0.0, host2: UInt64 = 0, seed2: UInt64 = 0
_ = api.GetZeroTimeStamp(reference, 2, 42, &sample2, &host2, &seed2)
var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
let hostSeconds = Double(host2 - host1) * Double(timebase.numer) / Double(timebase.denom) / 1e9
check("Monotonic timestamp at 48 kHz", sample2 > sample1 && host2 > host1 && seed2 == seed1 && abs((sample2 - sample1) / 48_000 - hostSeconds) < 0.000001)
check("IO stops after duplicate starts", api.StopIO(reference, 2, 42) == noErr && word(2, kAudioDevicePropertyDeviceIsRunning) == 0)
check("Client removal", api.RemoveDeviceClient(reference, 2, &client) == noErr)
var sample3 = 0.0, host3: UInt64 = 0, seed3: UInt64 = 0
_ = api.GetZeroTimeStamp(reference, 2, 42, &sample3, &host3, &seed3)
check("Stable clock epoch across stops", sample3 >= sample2 && host3 >= host2 && seed3 == seed2)

// Exercise actual C function pointers repeatedly while the control plane changes latency.
let concurrentFailures = Atomic<UInt32>(0)
DispatchQueue.concurrentPerform(iterations: 4) { worker in
    for i in 0..<25_000 {
        if worker == 0 {
            if api.PerformDeviceConfigurationChange(reference, 2, UInt64(i % 5) * 48_000, nil) != noErr { _ = concurrentFailures.wrappingAdd(1, ordering: .relaxed) }
        } else {
            var sample = 0.0, host: UInt64 = 0, seed: UInt64 = 0
            if api.GetZeroTimeStamp(reference, 2, 42, &sample, &host, &seed) != noErr || !sample.isFinite || host == 0 || seed != 1 { _ = concurrentFailures.wrappingAdd(1, ordering: .relaxed) }
        }
    }
}
check("100,000 concurrent clock/configuration calls", concurrentFailures.load(ordering: .relaxed) == 0)
check("Latency can return to zero", api.PerformDeviceConfigurationChange(reference, 2, 0, nil) == noErr && word(2, control) == 0)
let passed = results.filter { $0.1 }.count
print("\(passed)/\(results.count) latency driver checks passed. Driver was not installed; physical audio and Safari A/V are not verified.")
if let destination = ProcessInfo.processInfo.environment["VANILLE_DRIVER_REPORT"] {
    let report: [String: Any] = ["passed": passed, "total": results.count, "installed": false,
        "physicalAudioVerified": false, "externalVideoSyncVerified": false,
        "checks": results.map { ["name": $0.0, "passed": $0.1] }]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination), options: .atomic)
}
exit(passed == results.count ? 0 : 1)
