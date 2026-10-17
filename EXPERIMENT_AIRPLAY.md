# Independent AirPlay routing experiment

Branch: `experiment/multi-airplay-routing`, based on production `3398114`.
The production EQ, per-application volume, menu-bar UI and saved settings are unchanged. The experiment is a separate native app and reads a snapshot of the existing gain/EQ/bypass settings without writing them.

## VERIFIED

On 2026-10-18 KST, the system default output was set to MR4 (`CalDigit TS4 Audio - Rear`) using Audio MIDI Setup. The previously connected AirPlay HAL endpoint disappeared. Multi-Output Device offered the wired output and stale/offline members, not two independently connectable HomePod endpoints. Temporarily adding the current AirPlay member while it was connected did not create another endpoint; that checkbox was restored afterwards. No existing user device was deleted.

With MR4 still the system default and **zero AirPlay HAL devices**, an `AVPlayer`-bound `AVRoutePickerView` discovered two remote destinations. Both remote checkboxes could be selected simultaneously, with separate native volume sliders. Selecting Mac instead deselected both remote destinations. The first destination had the native HomePod mini stereo-pair icon; the second had a HomePod icon. The full physical stereo-pair configuration of the second destination was not independently established.

Safari played the public Big Buck Bunny YouTube video. A Core Audio process tap captured the Safari audio; the experiment reused Vanille's DSP, encoded in-memory AAC fragments and delivered them to its own AVPlayer over a tokenized loopback-only HTTP endpoint. The user confirmed that **MR4, HomePod and HomePod mini all produced the audio while the default output remained MR4**.

The user also reported **severe HomePod delay**. This is a simultaneous-output feasibility result, not a successful synchronization or product acceptance result. The initial bridge accumulated approximately 5–6 seconds between captured frames and player time. MR4 alignment could also stay disabled after buffering, which is being corrected separately.

Production regression checks: 63 passed. New retained-history/index-safety/playback-clock concurrency checks: 7 passed. Audio samples were never written to disk; diagnostic files contain numerical measurements only.

## IMPLEMENTED

- Separate AppKit experiment, `Scripts/build-airplay-bridge-lab.sh`.
- Public process taps, private clock aggregate, existing gain ramp/EQ/headroom processing.
- Fixed memory PCM history and independent encoder/control queue.
- `AVAssetWriter(contentType:)` plus segment-data delegate; no output file URL.
- Loopback-only, bounded HTTP connections; no LAN server or external upload.
- AVPlayer plus Apple's native multi-AirPlay picker; remote volume remains in Apple's UI.
- Local MR4 timeline following the player's program date, original-output recovery and watchdog.

## PARTIAL

The first live path proves that captured system audio can reach two app-scoped AirPlay destinations without selecting AirPlay as the default output. It is **not** AVRoutePickerView routing arbitrary system audio by itself: Vanille explicitly captures, processes and supplies that audio as its player's media.

The native picker manages remote selection and volume. Public `AVRouteDetector` only exposes route availability, not selected remote identities or a programmatic AirPlay group API. Remote status/volume management outside the native picker and robust automatic group reconnection remain unresolved. A player clock is not a microphone measurement of speaker arrival time.

## NOT IMPLEMENTED

- Product integration, saved named AirPlay destination groups and automatic identity-based reconnection.
- Verified low-latency playback and acoustic synchronization across all three outputs.
- Proven seamless device-loss/reconnect behavior or protected-service compatibility.
- Private AVOutputContext/MediaRemote, direct AirPlay/RAOP protocol or third-party drivers.

## KNOWN ISSUES

- Initial HLS path adds several seconds of latency and is unsuitable for lip-synchronized video.
- An output can revert to original audio after player buffering and fail to rejoin alignment in the initial build.
- AVPlayer may fall back to the Mac; selected audio route identities are not exposed by the inspected public API. The experiment cannot yet guarantee robust automatic route recovery.
- Only active apps present when the experimental session starts are captured. Production's discovery behavior is retained in the main app, not yet integrated with this bridge.
- Snapshot EQ/application settings are reused; live product controls are not connected to this separate experiment.
- Apple advises against local HLS servers in its authoring guidance. This loopback bridge is a feasibility experiment, not an established production architecture.

## Public references

- [Audio MIDI Setup Multi-Output Device](https://support.apple.com/guide/audio-midi-setup/play-audio-through-multiple-devices-at-once-ams7c093f372/mac)
- [AVRoutePickerView.player](https://developer.apple.com/documentation/avkit/avroutepickerview/player)
- [AVRouteDetector](https://developer.apple.com/documentation/avfoundation/avroutedetector)
- [AVAssetWriter segment-data output](https://developer.apple.com/documentation/avfoundation/avassetwriter/outputfiletypeprofile)
- [HLS authoring guidance](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/)
- [Low-Latency HLS](https://developer.apple.com/documentation/http-live-streaming/enabling-low-latency-http-live-streaming-hls)
- [Custom routing is for non-AirPlay routes](https://developer.apple.com/documentation/avkit/avroutepickerview/customroutingcontroller)
