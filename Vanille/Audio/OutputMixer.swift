import Foundation

/// A shared stereo history feeds independently addressed hardware output streams.
/// Delay is an actual PCM read-head offset, not a hardware volume setting or a UI-only value.
final class OutputMixer {
    let destinations: Int
    private let capacity: Int
    private let history: UnsafeMutablePointer<Double>
    private let gains: UnsafeMutablePointer<Double>
    private let delays: UnsafeMutablePointer<Int>
    private let previousDelays: UnsafeMutablePointer<Int>
    private let fades: UnsafeMutablePointer<Double>
    private let gainStep: Double
    private let fadeStep: Double
    private var position = 0

    init(sampleRate:Double,destinations:Int) {
        self.destinations = destinations
        capacity = Int(sampleRate*3)+RenderContext.maximumFrames+2
        history = .allocate(capacity:capacity*2); history.initialize(repeating:0,count:capacity*2)
        gains = .allocate(capacity:destinations); gains.initialize(repeating:1,count:destinations)
        delays = .allocate(capacity:destinations); delays.initialize(repeating:0,count:destinations)
        previousDelays = .allocate(capacity:destinations); previousDelays.initialize(repeating:0,count:destinations)
        fades = .allocate(capacity:destinations); fades.initialize(repeating:1,count:destinations)
        gainStep = 1/max(1,sampleRate*0.01); fadeStep = 1/max(1,sampleRate*0.03)
    }
    deinit {
        history.deinitialize(count:capacity*2); history.deallocate()
        gains.deinitialize(count:destinations); gains.deallocate()
        delays.deinitialize(count:destinations); delays.deallocate()
        previousDelays.deinitialize(count:destinations); previousDelays.deallocate()
        fades.deinitialize(count:destinations); fades.deallocate()
    }
    func beginBlock(_ p:UnsafePointer<Double>) {
        for i in 0..<destinations {
            let target = min(capacity-2,max(0,Int(p[ParameterMailbox.outputOffset+i*2+1].rounded())))
            if target != delays[i] { previousDelays[i] = delays[i]; delays[i] = target; fades[i] = 0 }
        }
    }
    @inline(__always) func push(left:Double,right:Double) { history[position*2] = left; history[position*2+1] = right }
    @inline(__always) func read(destination i:Int,parameters p:UnsafePointer<Double>) -> (Double,Double) {
        let targetGain = p[ParameterMailbox.outputOffset+i*2]
        gains[i] += min(gainStep,max(-gainStep,targetGain-gains[i]))
        fades[i] = min(1,fades[i]+fadeStep)
        var new = position-delays[i]; if new < 0 { new += capacity }
        var old = position-previousDelays[i]; if old < 0 { old += capacity }
        let fade = fades[i], gain = gains[i]
        let l = (history[old*2]+(history[new*2]-history[old*2])*fade)*gain
        let r = (history[old*2+1]+(history[new*2+1]-history[old*2+1])*fade)*gain
        return (l,r)
    }
    @inline(__always) func advance() { position += 1; if position == capacity { position = 0 } }
}
