# Independent AirPlay routing experiment

Branch: `experiment/multi-airplay-routing`, based on production `3398114`.
The production EQ, per-application volume, menu-bar UI and saved settings are unchanged. The experiment is a separate native app and reads a snapshot of the existing gain/EQ/bypass settings without writing them.

## VERIFIED

On 2026-10-18 KST, the system default output was set to MR4 (`CalDigit TS4 Audio - Rear`) using Audio MIDI Setup. The previously connected AirPlay HAL endpoint disappeared. Multi-Output Device offered the wired output and stale/offline members, not two independently connectable HomePod endpoints. Temporarily adding the current AirPlay member while it was connected did not create another endpoint; that checkbox was restored afterwards. No existing user device was deleted.

With MR4 still the system default and **zero AirPlay HAL devices**, an `AVPlayer`-bound `AVRoutePickerView` discovered two remote destinations. Both remote checkboxes could be selected simultaneously, with separate native volume sliders. Selecting Mac instead deselected both remote destinations. The first destination had the native HomePod mini stereo-pair icon; the second had a HomePod icon. The full physical stereo-pair configuration of the second destination was not independently established.

Safari played the public Big Buck Bunny YouTube video. A Core Audio process tap captured the Safari audio; the experiment reused Vanille's DSP, encoded in-memory AAC fragments and delivered them to its own AVPlayer over a tokenized loopback-only HTTP endpoint. The user confirmed that **MR4, HomePod and HomePod mini all produced the audio while the default output remained MR4**.

After the initial severe HomePod delay report, MR4 playback was tied to the player's program-date timeline. The user then explicitly reported that **MR4 and the HomePods were in sync with one another, but audio was out of sync with video**. This is a qualitative listening confirmation, not a microphone measurement or a long-duration drift test. The video acceptance test still fails.

The original bridge accumulated approximately 5–6 seconds between captured frames and player time. Partial-segment HLS reduced some observed offsets, but playback still measured roughly **3.6–4.8 seconds**, including after a live-edge seek. AVPlayer recommended a 3-second live offset on this system. A more aggressive 106.7 ms part experiment still measured about 4.1 seconds and was reverted. HTTP counters show predominantly full-segment consumption, so a partial-segment manifest is not claimed as proof of low-latency playback.

Pausing restores the original path while retaining the user's MR4 inclusion choice. Resume now seeks to the live edge and automatically re-arms local alignment; it no longer deliberately plays the entire pause backlog. The final native timing-tone test observed inclusion retained, original replacement off during pause, automatic activation on resume, and a 3.6-second immediate post-resume offset. When the native picker returned to Mac, the public Core Media device clock matched the local output; the new safety guard stopped playback/capture and cleared original replacement. This checks state and IO/aggregate teardown on explicit route return, **not independent browser-output readback or every possible network loss**.

Production regression checks: 63 passed. Retained-history/index-safety/playback-clock concurrency checks: 7 passed. Native in-app AAC/manifest/retention checks: **8 passed**. The shell sandbox could not access the native AAC service and reports those checks as SKIP; the same checks were run successfully inside the native app. Audio samples were never written to disk; diagnostic files contain numerical measurements only. See [AIRPLAY_AV_SYNC.md](AIRPLAY_AV_SYNC.md) and `Tests/Results/AirPlay-*`.

## IMPLEMENTED

- Separate AppKit experiment, `Scripts/build-airplay-bridge-lab.sh`.
- Public process taps, private clock aggregate, existing gain ramp/EQ/headroom processing.
- Fixed memory PCM history and independent encoder/control queue.
- `AVAssetWriter(contentType:)` plus segment-data delegate; no output file URL.
- Loopback-only, bounded HTTP connections; no LAN server or external upload.
- AVPlayer plus Apple's native multi-AirPlay picker; remote volume remains in Apple's UI.
- Local MR4 timeline following the player's program date, original-output recovery and watchdog.
- Partial-segment manifest, bounded blocking reload/preload handling, and numerical HTTP/playback diagnostics.
- Sticky MR4 inclusion, live-edge resume, explicit local-clock fallback detection, 90-second timing-test limit.
- **Use MR4 for Video** stops the bridge and returns to original playback. There are no user delay controls.

## PARTIAL

The first live path proves that captured system audio can reach two app-scoped AirPlay destinations without selecting AirPlay as the default output. It is **not** AVRoutePickerView routing arbitrary system audio by itself: Vanille explicitly captures, processes and supplies that audio as its player's media.

The native picker manages remote selection and volume. Public `AVRouteDetector` only exposes route availability, not selected remote identities or a programmatic AirPlay group API. Remote status/volume management outside the native picker and robust automatic group reconnection remain unresolved. A player clock is not a microphone measurement of speaker arrival time.

## NOT IMPLEMENTED

- Product integration, saved named AirPlay destination groups and automatic identity-based reconnection.
- Lip-synchronized video from Safari/Chrome/VLC while all three outputs are in use.
- Quantified acoustic synchronization and long-duration drift stability across all three outputs.
- Proven seamless device-loss/reconnect behavior or protected-service compatibility.
- Private AVOutputContext/MediaRemote, direct AirPlay/RAOP protocol or third-party drivers.

## KNOWN ISSUES

- The HLS/AirPlay path still adds several seconds of latency and is unsuitable for lip-synchronized video in another app. Lowering part sizes and forward buffering did not solve it.
- A live-edge seek can discard pause backlog, but cannot remove the underlying AirPlay/player buffering.
- Selected audio route identities are not exposed by the inspected public API. Returning explicitly to Mac is now detected safely through a local device clock match, but the experiment cannot yet guarantee recovery from every route failure or reconnect automatically.
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
