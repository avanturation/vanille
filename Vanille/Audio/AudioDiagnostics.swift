import Foundation
import CoreAudio
import Synchronization
import os

struct AudioEvent: Codable {
    let sequence: UInt64
    let hostTime: UInt64
    let time: Date
    let kind: String
    let detail: String
}

/// Control-thread only. No audio, process names or device UIDs are retained.
/// A bounded event history supplements unified logging for native regression tests.
final class AudioDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioEvent] = []
    private var sequence: UInt64 = 0
    private let logger = Logger(subsystem: "com.avanturation.Vanille", category: "AudioLifecycle")
    func record(_ kind: String, _ detail: String = "") {
        lock.lock()
        sequence &+= 1
        let event = AudioEvent(sequence: sequence, hostTime: mach_absolute_time(), time: Date(), kind: kind, detail: detail)
        if events.count == 4096 { events.removeFirst(1024) }
        events.append(event)
        lock.unlock()
        logger.info("\(kind, privacy: .public) \(detail, privacy: .public)")
    }
    func snapshot() -> [AudioEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Single realtime producer. The control queue only reads atomic counters.
/// No locks, logging, strings, allocation or file IO in observe().
final class CallbackTelemetry: @unchecked Sendable {
    let gaps = Atomic<UInt64>(0)
    let maximumGapTicks = Atomic<UInt64>(0)
    let sampleDiscontinuities = Atomic<UInt64>(0)
    let inputShortfalls = Atomic<UInt64>(0)
    let invalidSamples = Atomic<UInt64>(0)
    let secondsPerTick: Double
    private let sampleRate: Double
    private var previousHost: UInt64 = 0
    private var previousSample: Double?
    private var previousFrames = 0
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer)/Double(timebase.denom)*1e-9
    }
    @inline(__always) func observe(now: AudioTimeStamp, output: AudioTimeStamp, frames: Int) {
        let host = now.mFlags.contains(.hostTimeValid) ? now.mHostTime : mach_absolute_time()
        if previousHost != 0, host > previousHost, previousFrames > 0 {
            let elapsed = host-previousHost
            if elapsed > maximumGapTicks.load(ordering: .relaxed) { maximumGapTicks.store(elapsed,ordering: .relaxed) }
            if Double(elapsed)*secondsPerTick > Double(previousFrames)/sampleRate*1.75+0.002 {
                gaps.wrappingAdd(1,ordering: .relaxed)
            }
        }
        if output.mFlags.contains(.sampleTimeValid) {
            if let previousSample, previousFrames > 0, abs(output.mSampleTime-previousSample-Double(previousFrames))>0.5 {
                sampleDiscontinuities.wrappingAdd(1,ordering: .relaxed)
            }
            previousSample = output.mSampleTime
        }
        previousHost = host; previousFrames = frames
    }
    var maximumGapMS: Double { Double(maximumGapTicks.load(ordering:.relaxed))*secondsPerTick*1000 }
}
