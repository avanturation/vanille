import AppKit
import AVFoundation
import QuartzCore
import CoreVideo

enum ControlledVideoFixture {
    /// Only our own generated, silent video is written. No user video is opened
    /// and no system/browser/protected video frames are captured or inspected.
    static func create(at url:URL) throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:180,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:160_000,AVVideoMaxKeyFrameIntervalKey:30]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:180])
        guard writer.canAdd(input) else { throw AudioFailure(operation:"Create controlled video fixture",status:-1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AudioFailure(operation:"Start controlled video fixture",status:-1) }
        writer.startSession(atSourceTime:.zero)
        func buffer(_ white:Bool) throws -> CVPixelBuffer {
            var p:CVPixelBuffer?
            try HAL.check(CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_32BGRA,nil,&p),"Allocate synthetic video")
            CVPixelBufferLockBaseAddress(p!,[])
            memset(CVPixelBufferGetBaseAddress(p!)!,white ? 255 : 0,CVPixelBufferGetBytesPerRow(p!)*180)
            CVPixelBufferUnlockBaseAddress(p!,[])
            return p!
        }
        let dark=try buffer(false),light=try buffer(true),deadline=Date().addingTimeInterval(45)
        for frame in 0..<1020 {
            while !input.isReadyForMoreMediaData,writer.status == .writing,Date()<deadline { Thread.sleep(forTimeInterval:0.001) }
            guard Date()<deadline,writer.status == .writing,
                  adaptor.append(SyncCue.lit(Double(frame)/30) ? light : dark,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else {
                writer.cancelWriting();throw writer.error ?? AudioFailure(operation:"Encode synthetic video",status:-1)
            }
        }
        input.markAsFinished()
        let finished=DispatchSemaphore(value:0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout:.now()+15) == .success,writer.status == .completed else { writer.cancelWriting();throw writer.error ?? AudioFailure(operation:"Finish synthetic video",status:-1) }
    }
}

/// Moves the owned video timeline to the existing audio timeline. It never adds
/// audio delay. This control queue continues independently of UI refreshes.
final class ControlledVideo {
    let player=AVPlayer()
    let layer:AVPlayerLayer
    private let queue=DispatchQueue(label:"Vanille.AVSync.Video",qos:.userInitiated)
    private var timer:DispatchSourceTimer?
    private var audio:AVPlayer?
    private var live:LiveBridgeSession?
    private var output:AVPlayerItemVideoOutput?
    private var prepared=false,preparing=false,running=false,compensated=true
    private var lastAdjustment=0.0
    private var adjustments=0
    private var sourceClock:CMClock?
    private var values:[String:Any]=[:]
    private let frequency=AudioGetHostClockFrequency()

    init() {
        player.automaticallyWaitsToMinimizeStalling=false
        player.isMuted=true
        layer=AVPlayerLayer(player:player);layer.videoGravity = .resizeAspect
        let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer
        timer.schedule(deadline:.now(),repeating:.milliseconds(20),leeway:.milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() };timer.resume()
    }
    func loadOwnedFixture(_ url:URL) {
        queue.async {
            self.player.pause();self.prepared=false;self.preparing=false
            let item=AVPlayerItem(url:url)
            // This output is attached exclusively to our generated silent clip.
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[:]);item.add(output);self.output=output
            self.player.replaceCurrentItem(with:item)
        }
    }
    func follow(audio:AVPlayer,live:LiveBridgeSession?) { queue.sync { self.audio=audio;self.live=live;running=true;lastAdjustment=0;adjustments=0 } }
    func setCompensated(_ value:Bool) { queue.sync { compensated=value;lastAdjustment=0 } }
    func stop() { queue.sync { running=false;player.pause();audio=nil;live=nil } }
    var snapshot:[String:Any] { queue.sync { values } }

    private func tick() {
        guard let item=player.currentItem else { return }
        if item.status == .readyToPlay,!prepared,!preparing {
            preparing=true
            player.preroll(atRate:1) { [weak self] ready in self?.queue.async { self?.prepared=ready;self?.preparing=false } }
        }
        guard prepared,running,let audio else { return }
        let host=AudioGetCurrentHostTime(),now=Double(host)/frequency
        var reference:AVSyncReference
        if let live { reference=live.avReference(compensated:compensated) }
        else {
            let before=AudioGetCurrentHostTime(),time=audio.currentTime().seconds,after=AudioGetCurrentHostTime()
            reference=AVSyncReference(seconds:time,host:before+(after-before)/2,valid:audio.timeControlStatus == .playing && time.isFinite,rate:Double(audio.rate))
        }
        guard reference.valid,reference.host != 0 else { player.pause();values=["ready":prepared,"referenceValid":false,"compensated":compensated];return }
        let fullTarget=reference.seconds+(Double(host)-Double(reference.host))/frequency*reference.rate
        guard fullTarget>=0,fullTarget.isFinite else { player.pause();return }
        // The generated file contains two 17-second cue cycles. Reusing its
        // first cycle keeps diagnostics small; this is not arbitrary media.
        let target=fullTarget.truncatingRemainder(dividingBy:SyncCue.period)
        let clock:CMClock=compensated ? audio.currentItem?.timebase.map { CMTimebaseCopyUltimateSourceClock($0) } ?? CMClockGetHostTimeClock() : CMClockGetHostTimeClock()
        let clockChanged=sourceClock.map { !CFEqual($0,clock) } ?? true
        if clockChanged { sourceClock=clock;player.sourceClock=clock;lastAdjustment=0 }
        let current=player.currentTime().seconds
        if lastAdjustment==0 || player.rate==0 || current.isFinite && abs(current-target)>0.08 && now-lastAdjustment>1 {
            // Advancing both timestamps to a near-future host time gives the
            // video decoder a short preparation interval without delaying audio.
            let lead=0.10
            player.setRate(Float(reference.rate),time:CMTime(seconds:target+lead,preferredTimescale:48_000),atHostTime:CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),CMTime(seconds:lead,preferredTimescale:1_000_000)))
            lastAdjustment=now;adjustments += 1
        }
        var result:[String:Any]=["ready":prepared,"referenceValid":true,"compensated":compensated,"audioReferenceSeconds":fullTarget,"cuePhaseSeconds":target,"videoTimeSeconds":current.isFinite ? current : -1,"timebaseResidualMS":current.isFinite ? (current-target)*1000 : 0,"timelineAdjustments":adjustments,"settling":now-lastAdjustment<0.25,"usesAudioSourceClock":compensated,"rate":player.rate,"correction":"owned video timeline only; no extra audio delay"]
        if let output {
            let request=output.itemTime(forHostTime:now)
            var display=CMTime.invalid
            if output.copyPixelBuffer(forItemTime:request,itemTimeForDisplay:&display) != nil,display.seconds.isFinite {
                result["decodedVideoPTS"]=display.seconds
                result["decodedFrameResidualMS"]=(display.seconds-target)*1000
            }
        }
        values=result
    }
    deinit { timer?.cancel();player.pause() }
}
