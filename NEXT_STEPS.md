# Next steps

1. Keep the continuous physical output session and independent process readers. Retain the measured notification/new-app regression tests; qualify actual messenger effects, Safari pause/seek, long playback, sleep/wake, reader failure and output reconnection before public release. Measure acoustic A/V timing again: existing DSP/output alignment remains, while input handoff adds one actual callback quantum as a scheduling guard.
2. Resolve the current system default/connection lifetime behavior with native measurements. Selecting the wired default removed the AirPlay endpoint even with an Aggregate open. Do not change the renderer based on an assumed cause or mark automatic HomePod connection complete.
3. Repeat the full real-video pause/play/seek scenario on this baseline with the system default explicitly recorded, then run longer playback, device disconnect/reconnect, sleep/wake, permission denial and forced-exit recovery. Software readback is not acoustic verification.
4. Finish native UI QA on clean macOS 15/26/27 accounts: Light/Dark, transparency/contrast accessibility, keyboard, VoiceOver, first launch and settings migration. Native glass is structural and stays outside the audio thread.
5. Complete public release gates: Developer ID signing, hardened runtime, notarization, clean-machine Gatekeeper verification and a reviewed release artifact. The current candidate is ad hoc signed; automatic updates are later work.
6. Only after the one-AirPlay path retains its latency and stability, evaluate an additional independently connectable AirPlay output. Keep those experiments in separate branches. No HLS or virtual-output path is added to this baseline to claim broader device support.

Profiles, per-device EQ and per-app destinations remain below these priorities. Existing per-app gain, Global EQ and profile behavior are retained.
