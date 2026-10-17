import AppKit
import AVFAudio
import Synchronization

final class ToneState: @unchecked Sendable {
    let amplitude = Atomic<Double>(0.005)
    let frequency = Atomic<Double>(1000)
    var phase = 0.0 // render thread only
}
final class ToneDelegate: NSObject, NSApplicationDelegate {
    let engine = AVAudioEngine()
    let tone = ToneState()
    var source: AVAudioSourceNode?
    var window: NSWindow!
    let status = NSTextField(labelWithString:"A quiet 1 kHz test tone is playing (−46 dBFS).")
    func applicationDidFinishLaunching(_ notification:Notification) {
        let frequency = (Bundle.main.object(forInfoDictionaryKey:"VanilleTestFrequency") as? Double) ?? 1000
        tone.frequency.store(frequency,ordering:.relaxed)
        status.stringValue = "A quiet \(Int(frequency)) Hz test tone is playing (−46 dBFS)."
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:170),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = (Bundle.main.object(forInfoDictionaryKey:"CFBundleName") as? String) ?? "Vanille Test Tone"; window.isReleasedWhenClosed = false
        let stop = NSButton(title:"Stop & Quit",target:self,action:#selector(quit)); stop.bezelStyle = .rounded
        let stack = NSStackView(views:[status,stop]); stack.orientation = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        stack.centerXAnchor.constraint(equalTo:window.contentView!.centerXAnchor).isActive = true
        stack.centerYAnchor.constraint(equalTo:window.contentView!.centerYAnchor).isActive = true
        let format = engine.outputNode.inputFormat(forBus:0)
        let sampleRate = format.sampleRate
        let stereo = AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:2)!
        let state = tone
        let node = AVAudioSourceNode(format:stereo) { _, _, frames, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            let amplitude = state.amplitude.load(ordering:.relaxed)
            let increment = 2*Double.pi*state.frequency.load(ordering:.relaxed)/sampleRate
            for frame in 0..<Int(frames) {
                let sample = Float(sin(state.phase)*amplitude)
                state.phase += increment; if state.phase >= 2*Double.pi { state.phase -= 2*Double.pi }
                for buffer in buffers { if let data = buffer.mData { data.assumingMemoryBound(to:Float.self)[frame] = sample } }
            }
            return noErr
        }
        source = node; engine.attach(node); engine.connect(node,to:engine.mainMixerNode,format:stereo)
        do { try engine.start() } catch { status.stringValue = "Test tone failed: \(error.localizedDescription)" }
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline:.now()+180) { [weak self] in self?.quit() }
    }
    @objc func quit() { engine.stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) { engine.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = ToneDelegate(); app.delegate = delegate; app.run()
