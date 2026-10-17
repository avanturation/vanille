import Foundation
import Synchronization

/// One producer, multiple readers. Readers use completed history, never the writing block.
/// Raw storage has a fixed capacity; unavailable/overwritten ranges return silence.
final class PCMHistory:@unchecked Sendable {
    let capacity:Int64
    let samples:UnsafeMutablePointer<Float>
    let published = Atomic<Int64>(0)
    private var cursor:Int64 = 0
    init(sampleRate:Double) {
        capacity = Int64(sampleRate*48)
        samples = .allocate(capacity:Int(capacity)*2);samples.initialize(repeating:0,count:Int(capacity)*2)
    }
    deinit { samples.deinitialize(count:Int(capacity)*2);samples.deallocate() }
    @inline(__always) func push(_ left:Float,_ right:Float) {
        let slot=Int(cursor%capacity)*2;samples[slot]=left;samples[slot+1]=right;cursor += 1
    }
    @inline(__always) func commit() { published.store(cursor,ordering:.releasing) }
    @inline(__always) func sample(at frame:Double,head:Int64)->(Float,Float) {
        guard frame.isFinite,frame>=0,frame<Double(head-1),frame<Double(Int64.max-1) else { return (0,0) }
        let base=Int64(frame)
        guard base+1<head,base>=max(0,head-capacity+16_384) else { return (0,0) }
        let a=Int(base%capacity)*2,b=Int((base+1)%capacity)*2,part=Float(frame-Double(base))
        return (samples[a]+(samples[b]-samples[a])*part,samples[a+1]+(samples[b+1]-samples[a+1])*part)
    }
    func copy(from frame:Int64,count:Int,to pointer:UnsafeMutablePointer<Float>)->Bool {
        let head=published.load(ordering:.acquiring)
        guard frame>=max(0,head-capacity+16_384),frame+Int64(count)<=head else { return false }
        for i in 0..<count { let slot=Int((frame+Int64(i))%capacity)*2;pointer[i*2]=samples[slot];pointer[i*2+1]=samples[slot+1] }
        return true
    }
}

struct PlaybackAnchor { var frame:Double=0;var host:UInt64=0;var valid=false }
final class PlaybackClock:@unchecked Sendable {
    private let storage:UnsafeMutablePointer<PlaybackAnchor>
    private let middle=Atomic<Int>(1)
    private var back=2,front=0
    init() { storage = .allocate(capacity:3);storage.initialize(repeating:PlaybackAnchor(),count:3) }
    deinit { storage.deinitialize(count:3);storage.deallocate() }
    func publish(_ anchor:PlaybackAnchor) { storage[back]=anchor;back=middle.exchange(back|4,ordering:.acquiringAndReleasing)&3 }
    @inline(__always) func consume()->PlaybackAnchor {
        if middle.load(ordering:.acquiring)&4 != 0 { front=middle.exchange(front,ordering:.acquiringAndReleasing)&3 }
        return storage[front]
    }
}
