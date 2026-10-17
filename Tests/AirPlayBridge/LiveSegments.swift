import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CoreMedia

/// Non-realtime only. AVAssetWriter's segment-data initializer suppresses file writing.
final class LiveSegments:NSObject,AVAssetWriterDelegate {
    struct Segment { let sequence:Int; let start:Double; let duration:Double; let data:Data }
    private let lock = NSLock()
    private var initialization = Data()
    private var segments:[Segment] = []
    private var sequence = 0
    private var writer:AVAssetWriter?
    private var input:AVAssetWriterInput?
    private var format:CMAudioFormatDescription?
    private(set) var submittedFrames:Int64 = 0
    let sampleRate:Double
    let origin = Date()
    var failure:String?

    init(sampleRate:Double) throws {
        self.sampleRate = sampleRate
        super.init()
        var asbd = AudioStreamBasicDescription(mSampleRate:sampleRate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        try HAL.check(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),"Create streaming PCM format")
        let w = AVAssetWriter(contentType:.mpeg4Movie)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds:1,preferredTimescale:48_000)
        w.initialSegmentStartTime = .zero; w.delegate = self
        let i = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:sampleRate,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128_000],sourceFormatHint:format)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { throw AudioFailure(operation:"Create in-memory AAC writer",status:kAudioHardwareUnsupportedOperationError) }
        w.add(i)
        guard w.startWriting() else { throw w.error ?? AudioFailure(operation:"Start in-memory AAC writer",status:-1) }
        w.startSession(atSourceTime:.zero); writer = w; input = i
    }

    /// Producer queue only. Returns false on backpressure; caller retains its cursor.
    func append(_ pcm:UnsafePointer<Float>,frames:Int) throws -> Bool {
        guard let input, let writer, let format, frames>0 else { return false }
        guard writer.status == .writing else { throw writer.error ?? AudioFailure(operation:"AAC stream ended",status:-1) }
        guard input.isReadyForMoreMediaData else { return false }
        let bytes = frames*8
        var block:CMBlockBuffer?
        try HAL.check(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:bytes,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:bytes,flags:0,blockBufferOut:&block),"Allocate encoder sample")
        try HAL.check(CMBlockBufferReplaceDataBytes(with:pcm,blockBuffer:block!,offsetIntoDestination:0,dataLength:bytes),"Copy encoder sample")
        var sample:CMSampleBuffer?
        try HAL.check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault,dataBuffer:block!,formatDescription:format,sampleCount:frames,presentationTimeStamp:CMTime(value:submittedFrames,timescale:CMTimeScale(sampleRate)),packetDescriptions:nil,sampleBufferOut:&sample),"Create encoder sample")
        guard input.append(sample!) else { throw writer.error ?? AudioFailure(operation:"Encode audio segment",status:-1) }
        submittedFrames += Int64(frames)
        return true
    }

    func assetWriter(_ writer:AVAssetWriter,didOutputSegmentData segmentData:Data,segmentType:AVAssetSegmentType,segmentReport:AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        if segmentType == .initialization { initialization = segmentData; return }
        guard segmentData.count<512_000, let track=segmentReport?.trackReports.first,
              track.duration.seconds.isFinite, track.duration.seconds>0,
              track.earliestPresentationTimeStamp.seconds.isFinite else { failure = "Invalid AAC segment report"; return }
        segments.append(Segment(sequence:sequence,start:track.earliestPresentationTimeStamp.seconds,duration:track.duration.seconds,data:segmentData))
        sequence += 1
        if segments.count>12 { segments.removeFirst(segments.count-12) }
    }

    var snapshot:[String:Any] {
        lock.lock();defer { lock.unlock() }
        return ["segmentCount":segments.count,"totalSegments":sequence,"initializationBytes":initialization.count,"retainedEncodedBytes":segments.reduce(initialization.count) { $0+$1.data.count },"lastEndPTS":segments.last.map { $0.start+$0.duration } ?? 0,"error":failure ?? ""]
    }
    var ready:Bool { lock.lock();defer { lock.unlock() }; return !initialization.isEmpty && segments.count>=4 }

    func resource(_ path:String)->MemoryHTTPServer.Response? {
        lock.lock();defer { lock.unlock() }
        if path == "init.mp4" { return initialization.isEmpty ? nil : .init(contentType:"audio/mp4",data:initialization) }
        if path.hasPrefix("s"),path.hasSuffix(".m4s"),let n=Int(path.dropFirst().dropLast(4)),let segment=segments.first(where: { $0.sequence == n }) {
            return .init(contentType:"audio/mp4",data:segment.data)
        }
        guard path == "live.m3u8", !initialization.isEmpty, segments.count>=3 else { return nil }
        let visible = Array(segments.suffix(8))
        let target = max(1,Int(ceil(visible.map(\.duration).max() ?? 1)))
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(visible[0].sequence)\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        let dateFormatter = ISO8601DateFormatter();dateFormatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        for segment in visible {
            playlist += "#EXT-X-PROGRAM-DATE-TIME:\(dateFormatter.string(from:origin.addingTimeInterval(segment.start)))\n#EXTINF:\(String(format:"%.6f",segment.duration)),\ns\(segment.sequence).m4s\n"
        }
        return .init(contentType:"application/vnd.apple.mpegurl",data:Data(playlist.utf8))
    }
    func stop() { input?.markAsFinished();writer?.cancelWriting();input=nil;writer=nil }
    deinit { stop() }
}
