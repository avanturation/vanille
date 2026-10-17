import Foundation
import CoreAudio

struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        let bits = UInt32(bitPattern: status)
        let bytes: [UInt8] = [24,16,8,0].map { UInt8((bits >> $0) & 0xff) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: bytes, encoding: .ascii)! : String(status)
        return "\(operation) (\(fourCC))"
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioFailure(operation: operation, status: status) }
    }
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> T {
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        var property = address(selector, scope: scope, element: element)
        let status = withUnsafeMutableBytes(of: &result) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Read audio property")
        return result
    }
    static func write<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, value: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws {
        var result = value
        var property = address(selector, scope: scope, element: element)
        let status = withUnsafeBytes(of: &result) {
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
        try check(status, "Change audio property")
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var result: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var property = address(selector)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result), "Read audio name")
        return (result as String?) ?? ""
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read audio list size")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Read audio list")
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func channelCount(_ object: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read channel layout")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, data), "Read channel layout")
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                           element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var property = address(selector, scope: scope, element: element)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &property, &settable) == noErr && settable.boolValue
    }
}

final class HALObservation {
    private let object: AudioObjectID
    private var property: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, queue: DispatchQueue,
          change: @escaping () -> Void) {
        self.object = object; property = HAL.address(selector, scope: scope); self.queue = queue
        block = { _, _ in change() }
        guard AudioObjectAddPropertyListenerBlock(object, &property, queue, block) == noErr else { return nil }
    }
    deinit { AudioObjectRemovePropertyListenerBlock(object, &property, queue, block) }
}
