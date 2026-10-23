# vanille

A native macOS menu bar audio controller. Swift, AppKit and public Core Audio APIs; no web UI, external packages, account or audio upload.

**Development preview.** The restored direct Core Audio path is the baseline: wired output plus **one macOS system AirPlay connection**. App volume and EQ are real PCM processing. Multiple independent HomePod connections, automatic AirPlay connection and the experimental virtual output are outside this release.

The latest dropout fix and actual test scope are in [AUDIO_DROPOUT_REPORT.md](AUDIO_DROPOUT_REPORT.md). Version **0.2.1** keeps the physical output session running when audio processes start or exit. Native continuity tests passed on wired, one system AirPlay, and their combined output. EQ and application gain remain in the existing DSP path.

The earlier restoration is documented in [RESTORATION_REPORT.md](RESTORATION_REPORT.md). The user confirmed that that wired + one AirPlay path matches video. Keeping MR4 literally selected as the macOS default while retaining AirPlay did not pass: macOS removed the AirPlay endpoint. The current fix does not claim to resolve that separate connection limitation.

## Build and run

Requirements: Apple Silicon, macOS 15+, Swift 6 / Xcode 16 or newer command line tools. macOS 27 is the current hardware test environment. Liquid Glass requires a build made with SDK 26+ and macOS 26+; other supported builds use native popover material.

```sh
git clone --branch fix/continuous-audio-process-churn https://github.com/avanturation/vanille.git
cd vanille
./Scripts/build.sh
open build/Vanille.app
```

Or open `Vanille.xcodeproj` and build its shared **Vanille** scheme. No developer-specific paths, package installation, driver or administrator access is required. Version and build number live in `Config/Version.xcconfig`.

For a local candidate zip:

```sh
./Scripts/test.sh
./Scripts/prepare-release.sh
```

This creates `build/release/Vanille.app`, `Vanille-macos-arm64.zip`, license and checksums. It does not publish a GitHub Release. Current builds are ad hoc signed and **not Developer ID signed or notarized**; they are not a completed public binary release. See [RELEASE.md](RELEASE.md).

## Use

- Click the speaker in the menu bar. The first launch opens the controls with processing paused. There is no persistent Dock icon.
- The top slider controls the actual system output when the device supports hardware volume. Unsupported hardware volume is disabled.
- **Output Devices** lists live Core Audio outputs. Selecting a device chooses a single output. **Output Groups → Edit…** creates named groups from connected devices; existing groups remain saved.
- Start processing to apply group levels, app volume and EQ. Group sliders are unavailable while their processing path is inactive.
- Playing apps show an icon, real volume slider and mute. Unsupported or bypassed audio shows its state without a working-looking slider.
- Open **Equalizer** for the ten bands, preamp, Auto Headroom and presets. Double-click a band to reset it. Built-in and custom presets change the actual DSP.
- **Pause Processing** or **Settings → Restore Default Audio** returns captured apps to their original output. Settings also contains profiles, launch at login, bypass and local diagnostics.

The standard `NSPopover` adopts native Liquid Glass on eligible systems. Following Apple’s adoption guidance, no extra glass/effect view is inserted into its content. Light/Dark appearance follows macOS. Reduce Transparency or Increase Contrast selects an opaque system background. Controls remain AppKit sliders, radio buttons, checkboxes, menus and pop-up buttons. No simulated glass, graphs or nested glass cards are used.

## AirPlay scope

Connect an AirPlay speaker using macOS **Sound** or Control Center first; **AirPlay…** opens the official Sound settings. Vanille sees the current system-connected AirPlay endpoint, not a public directory of independently connectable HomePods. It does not pretend an app-only AirPlay picker controls all system audio.

The baseline groups that connected endpoint with a wired device in a private Core Audio Aggregate. It directly renders PCM, without HLS/AAC buffering or a virtual system output. Timing uses device, stream and safety values reported by macOS; there is no user delay slider. Those values are not an acoustic calibration or a promise for every network.

On the current macOS 27 test machine, switching the system default from AirPlay to the wired output removed the AirPlay endpoint, including while another Aggregate was open. Automatic connection and retaining wired-default selection remain **partial/unimplemented**, as detailed in the restoration report. Unavailable members are shown as disconnected and are never presented as playing.

## Permission and protected content

Starting processing uses Apple's **System Audio Recording** authorization through Core Audio process taps. `NSAudioCaptureUsageDescription` explains the local processing. If denied, keep original audio and use **System Settings → Privacy & Security → Screen & System Audio Recording** before retrying. Menu labels vary by macOS version.

No screen capture, video-frame access, HDCP bypass, decryption or protected-content API is used. **Protected Content Bypass** excludes an app from capture and processing. Music and TV start bypassed. Use browser bypass for protected playback that cannot be processed. Automatic DRM detection is not implemented; actual Netflix/TV+/protected Music playback is not verified. Bypassed audio retains its original route and is not duplicated to the processing group.

Audio buffers stay in memory. Settings are stored atomically in the standard per-user Application Support directory using bundle identifiers and device UIDs. No audio file, telemetry service, server or network authentication is used by this baseline app.

## Development

The UI and audio callbacks are separate. The renderer uses preallocated buffers and atomic parameter snapshots; the interface does not schedule audio. This branch preserves the tested baseline audio engine, DSP, output mixer, HAL and process manager unchanged.

- [Architecture](ARCHITECTURE.md)
- [Restoration and current verification](RESTORATION_REPORT.md)
- [Full historical test report](TEST_REPORT.md)
- [Release gates](RELEASE.md)
- [Next steps](NEXT_STEPS.md)
- [Contribution guide](CONTRIBUTING.md)
- [MIT license](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md)

The later multi-AirPlay, virtual-output and incomplete transport probes are preserved on `experiment/airplay-latency-archive`; they are not packaged or required here. The installed experimental driver on a development machine is left untouched.
