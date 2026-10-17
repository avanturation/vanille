import Foundation
import Synchronization

struct BiquadCoefficients {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static func peak(frequency: Double, gain: Double, sampleRate: Double) -> BiquadCoefficients {
        guard frequency < sampleRate * 0.49, abs(gain) > 0.0001 else { return BiquadCoefficients() }
        // One-octave peaking sections, RBJ coefficients; control-thread calculation only.
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * sqrt(2))
        let a0 = 1 + alpha / a
        return BiquadCoefficients(b0: (1 + alpha*a)/a0, b1: -2*cos(w)/a0,
                                  b2: (1-alpha*a)/a0, a1: -2*cos(w)/a0, a2: (1-alpha/a)/a0)
    }
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let nr = b0 + b1*cos(w) + b2*cos(2*w)
        let ni = -b1*sin(w) - b2*sin(2*w)
        let dr = 1 + a1*cos(w) + a2*cos(2*w)
        let di = -a1*sin(w) - a2*sin(2*w)
        return sqrt((nr*nr+ni*ni)/(dr*dr+di*di))
    }
}

/// Single producer (audio-control queue), single consumer (HAL IOProc).
/// The producer owns back, the consumer owns front; atomic exchange transfers middle.
/// Three fixed slots prevent allocation, reclamation, locks, and torn coefficient sets in IO.
final class ParameterMailbox: @unchecked Sendable {
    static let maxSources = 32
    static let eqMixIndex = maxSources
    static let preampIndex = maxSources + 1
    static let coefficientOffset = maxSources + 2
    static let maxOutputs = 8
    static let outputOffset = coefficientOffset + 10 * 5
    static let timingIndex = outputOffset + maxOutputs * 2
    static let width = timingIndex + 1
    private let slots: UnsafeMutablePointer<Double>
    private let middle = Atomic<Int>(1)
    private var back = 2 // producer only
    private var front = 0 // consumer only
    private var cachedEQ: EQSettings?
    private var cachedRate = 0.0
    private var cachedEQValues = Array(repeating: 0.0, count: 52) // producer only

    init() {
        slots = .allocate(capacity: Self.width * 3)
        slots.initialize(repeating: 0, count: Self.width * 3)
        for slot in 0..<3 {
            let pointer = slots.advanced(by: slot * Self.width)
            for i in 0..<Self.maxSources { pointer[i] = 1 }
            pointer[Self.preampIndex] = 1
            for i in 0..<10 { pointer[Self.coefficientOffset + 5*i] = 1 }
            for i in 0..<Self.maxOutputs { pointer[Self.outputOffset+i*2] = 1 }
        }
    }
    deinit { slots.deinitialize(count: Self.width * 3); slots.deallocate() }

    func publish(gains: [Float], eq: EQSettings, sampleRate: Double, outputs: [DeviceRoute] = [],timingSound:Bool = false) {
        let pointer = slots.advanced(by: back * Self.width)
        for i in 0..<Self.maxSources {
            let gain = i < gains.count ? gains[i] : 1
            pointer[i] = gain.isFinite ? Double(min(1,max(0,gain))) : 1
        }
        if cachedEQ != eq || cachedRate != sampleRate { cacheEQ(eq, sampleRate: sampleRate) }
        cachedEQValues.withUnsafeBufferPointer { source in
            pointer.advanced(by: Self.eqMixIndex).update(from: source.baseAddress!, count: 52)
        }
        for i in 0..<Self.maxOutputs {
            var output = i < outputs.count ? outputs[i] : nil
            output?.sanitize()
            pointer[Self.outputOffset+i*2] = output.map { $0.enabled && !$0.muted ? Double($0.volume) : 0 } ?? 1
            pointer[Self.outputOffset+i*2+1] = output.map { $0.delayMS*sampleRate/1000 } ?? 0
        }
        pointer[Self.timingIndex] = timingSound ? 1 : 0
        back = middle.exchange(back | 4, ordering: .acquiringAndReleasing) & 3
    }
    private func cacheEQ(_ eq: EQSettings, sampleRate: Double) {
        cachedEQ = eq; cachedRate = sampleRate
        cachedEQValues[0] = eq.enabled ? 1 : 0
        // Headroom measures the combined response, including overlap between adjacent bands.
        var maximumDB = 0.0
        let coefficients = zip(EQSettings.frequencies, eq.gains).map {
            BiquadCoefficients.peak(frequency: $0.0, gain: Double($0.1), sampleRate: sampleRate)
        }
        if eq.autoHeadroom {
            for i in 0..<512 {
                let f = 20 * pow(min(20_000, sampleRate * 0.48) / 20, Double(i) / 511)
                let response = coefficients.reduce(1.0) { $0 * $1.magnitude(at: f, sampleRate: sampleRate) }
                maximumDB = max(maximumDB, 20 * log10(max(response, 1e-12)))
            }
        }
        cachedEQValues[1] = pow(10, (Double(eq.preamp) - maximumDB) / 20)
        for i in 0..<10 {
            let c = coefficients[i], offset = 2 + i*5
            cachedEQValues[offset] = c.b0; cachedEQValues[offset+1] = c.b1; cachedEQValues[offset+2] = c.b2
            cachedEQValues[offset+3] = c.a1; cachedEQValues[offset+4] = c.a2
        }
    }
    @inline(__always) func consume() -> UnsafePointer<Double> {
        if middle.load(ordering: .acquiring) & 4 != 0 {
            front = middle.exchange(front, ordering: .acquiringAndReleasing) & 3
        }
        return UnsafePointer(slots.advanced(by: front * Self.width))
    }
}

struct FilterMemory {
    var z1 = 0.0
    var z2 = 0.0
    @inline(__always) mutating func tick(_ x: Double, _ c: UnsafePointer<Double>) -> Double {
        let y = c[0]*x + z1
        z1 = c[1]*x - c[3]*y + z2
        z2 = c[2]*x - c[4]*y
        // Flush denormals so silence doesn't make the DSP needlessly expensive.
        if abs(z1) < 1e-25 { z1 = 0 }
        if abs(z2) < 1e-25 { z2 = 0 }
        return y
    }
}

/// All mutable fields below are owned by the IO thread after start and before stop.
final class StereoDSP {
    let mailbox: ParameterMailbox
    let sampleRate: Double
    private let coefficients: UnsafeMutablePointer<Double>
    private let memories: UnsafeMutablePointer<FilterMemory>
    private let gains: UnsafeMutablePointer<Double>
    private var mix = 0.0
    private var preamp = 1.0
    private var limiterGain = 1.0
    private let gainStep: Double
    private let eqStep: Double
    private let limiterRelease: Double
    private(set) var limitedSamples: UInt64 = 0

    init(sampleRate: Double, mailbox: ParameterMailbox) {
        self.sampleRate = sampleRate; self.mailbox = mailbox
        coefficients = .allocate(capacity: 50); coefficients.initialize(repeating: 0, count: 50)
        for i in 0..<10 { coefficients[i*5] = 1 }
        memories = .allocate(capacity: 20); memories.initialize(repeating: FilterMemory(), count: 20)
        gains = .allocate(capacity: ParameterMailbox.maxSources)
        gains.initialize(repeating: 1, count: ParameterMailbox.maxSources)
        gainStep = 1 / max(1, sampleRate * 0.01)
        eqStep = 1 - exp(-1 / (sampleRate * 0.02))
        limiterRelease = 1 - exp(-1 / (sampleRate * 0.05))
    }
    deinit {
        coefficients.deinitialize(count: 50); coefficients.deallocate()
        memories.deinitialize(count: 20); memories.deallocate()
        gains.deinitialize(count: ParameterMailbox.maxSources); gains.deallocate()
    }
    @inline(__always) func gain(source: Int, parameters p: UnsafePointer<Double>) -> Double {
        let target = p[source]
        let difference = target - gains[source]
        gains[source] += min(gainStep, max(-gainStep, difference))
        return gains[source]
    }
    @inline(__always) func process(left: Double, right: Double, parameters p: UnsafePointer<Double>) -> (Double, Double) {
        mix += (p[ParameterMailbox.eqMixIndex] - mix) * eqStep
        preamp += (p[ParameterMailbox.preampIndex] - preamp) * eqStep
        for i in 0..<50 { coefficients[i] += (p[ParameterMailbox.coefficientOffset+i] - coefficients[i]) * eqStep }
        var l = left, r = right
        for band in 0..<10 {
            let c = UnsafePointer(coefficients.advanced(by: band*5))
            l = memories[band*2].tick(l, c)
            r = memories[band*2+1].tick(r, c)
        }
        l = left + (l*preamp-left)*mix
        r = right + (r*preamp-right)*mix
        guard l.isFinite && r.isFinite else { return (0,0) }
        // Stereo-linked peak protection; unity gain for ordinary unclipped samples.
        let peak = max(abs(l), abs(r))
        let target = peak > 0.98 ? 0.98 / peak : 1
        if target < limiterGain { limiterGain = target; limitedSamples += 1 }
        else { limiterGain += (target-limiterGain)*limiterRelease }
        return (l*limiterGain, r*limiterGain)
    }
}
