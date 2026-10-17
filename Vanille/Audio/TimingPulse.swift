import Foundation

/// A quiet, local calibration sound. Generated only on explicit request; never recorded.
final class TimingPulse {
    private let sampleRate:Double
    private var position = 0
    private var gain = 0.0
    init(sampleRate:Double) { self.sampleRate = sampleRate }
    @inline(__always) func sample(enabled:Bool) -> Double {
        let step = 1/(sampleRate*0.005)
        gain += min(step,max(-step,(enabled ? 1.0 : 0)-gain))
        if gain==0 { position = 0; return 0 }
        let t = Double(position)/sampleRate
        let envelope = max(0,min(1,t/0.005,(0.1-t)/0.005))
        let signal = 0.03*gain*envelope*sin(2*Double.pi*880*t)
        position += 1; if position>=Int(sampleRate*4) { position = 0 }
        return signal
    }
}
