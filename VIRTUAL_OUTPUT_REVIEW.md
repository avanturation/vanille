# Virtual output installation review

This is an A/V synchronization experiment on `experiment/latency-aware-output`. The existing production app and its EQ, application gain and speaker-routing implementation are preserved.

## IMPLEMENTED

- A Swift AudioServerPlugIn using Apple's public ABI, with one hidden 48 kHz stereo output. The app never selects it standalone; it discards its copy of aggregate audio. Version 0.1.2 reports underlying output eligibility so a physical-plus-timing aggregate can become a default output. Hidden UID lookup and actual aggregate default selection now pass on the native HAL.
- A host-approved configuration handshake for changing the actual output latency property. The standard latency property remains read-only; the app uses the declared `vlat` control to request a change.
- Native inspection of private aggregates containing the timing device and MR4. The probe restores the original latency and never selects a different system default.
- An installer and a recoverable removal package.

## VERIFIED

- Native arm64 build, ad hoc code signature, CFPlugIn factory discovery and instance loading.
- 75 isolated checks against the actual 0.1.2 binary, including host-supported CFString marshalling, host-approved device configuration, reserved action bits, 100,000 concurrent clock/configuration calls, malformed data, retained CF property ownership, device identity, fixed format, duplicate starts, timestamp rate and denied/aborted configuration changes.
- Before installation, the native app reports the missing driver and preserves MR4 as the default. No audio is intercepted by this probe.
- Version 0.1.0 was installed with explicit user authorization. The installed signature and binary hash match the tested bundle. Hidden UID lookup succeeds on the real HAL. Its raw UInt32 custom control was rejected by the real host (`who?`); the isolated fake host did not catch that marshalling restriction. Version 0.1.1 fixes the declaration and payload to CFString and adds corresponding regression checks.
- Version 0.1.1 was installed and matched its tested binary. The real host accepts the corrected custom property. With the timing device as the aggregate clock, actual device latency becomes 192,000 frames (4 seconds), then restores to zero. With MR4 as the clock it remains 50 frames and shifts into safety offset. All probe IO and aggregates clean up with `noErr`.
- An unmodified source AVPlayer reports approximately 4.113 seconds command-to-media-time in the 4-second case. The first zero-latency case had a 1.904-second cold start, so those two startup measurements alone are insufficient for an exact differential or acoustic claim.
- Twelve stopped/running, private/public and stacked/unstacked configurations show that `stacked=1` is mirrored stereo (2 channels) on this system, whereas `stacked=0` exposes four channels. Every 0.1.1 aggregate reports default eligibility zero because the timing subdevice reports zero. A real default-selection request returned success but the selected device stayed MR4 throughout a 3-second observation; cleanup restored driver latency and destroyed the unused aggregate. This prompted the eligibility fix in 0.1.2.
- Version **0.1.2 is installed**. Its binary SHA-256 is `a2be92bb28915da07186f931e3953830a9b765ced9685bbc82ddb0a8011f327d`, matching the tested bundle. The native physical-plus-timing aggregate is eligible and actually becomes the default output. The original menu-bar app must be stopped to avoid its independent output-recovery policy overriding this selection.
- Safari/YouTube continuous playback: the user confirmed that both HomePod destinations, physical MR4 and video generally match after the direct-MR4 render fix. Automatic client-side latency reporting was verified on the real HAL (4,000 → 3,400ms in one Chrome run). Subsequent transport-control testing **failed** with long waits, sync changes and speaker dropouts. See [current status](VIDEO_MODE_STATUS.md).

## PARTIAL

The isolated fake host verifies ABI and internal behavior. It does not verify loading in Apple's audio host, aggregate latency propagation, source-player video scheduling, physical sound or protected playback. The normal AirPlay bridge remains available in Music Mode.

## NOT IMPLEMENTED / NOT VERIFIED

The app has a gated experimental public aggregate and source-player probe, preserving the existing capture, EQ, application gain and MR4 physical-render path. Installed-driver latency propagation and default eligibility now pass. Continuous Safari playback has a qualitative user pass, but pause/play/seek, long sessions, network recovery and DRM still require acceptance. Process-aware transport recovery is implemented and under native test. No video-frame capture, DRM interception or player-script workaround is introduced. This client update uses the installed 0.1.2 driver without another installation.

## Exact installation changes

`Update-Vanille-Video-Timing-0.1.2.pkg` updates only `/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver` (plus the normal macOS installer receipt). It recognizes the exact installed 0.1.0 or 0.1.1 bundle identifier and binary SHA-256, and moves that bundle into `/Library/Audio/Plug-Ins/Vanille Disabled Drivers/` before applying the correction. It refuses unrecognized versions and symbolic links. Bundle relocation is disabled. It verifies the installed signature and restarts `coreaudiod` once so macOS can load the plug-in; all Mac audio may stop briefly. The package requires macOS administrator authentication. It does not install a kernel extension, background helper, network service or login item, and does not change SIP or privacy permissions.

The local build is ad hoc signed, not Developer ID signed or notarized. System-host compatibility still requires the on-machine test. A restart of the audio service may be insufficient on some system versions; that will be recorded rather than hidden.

For recovery, stop Vanille processing and restore MR4 first. `Remove-Vanille-Video-Timing.pkg` verifies the bundle identifier, moves only this driver into `/Library/Audio/Plug-Ins/Vanille Disabled Drivers/` with a timestamp, and restarts the audio service. The driver remains recoverable. Existing Apple, CalDigit, Background Music and other installed drivers are not modified.

Development, installation and the audio-service restart were explicitly authorized by the user. Automatic approval review blocked the agent's Install-button click; the user completed 0.1.0, 0.1.1 and 0.1.2 installation and administrator authentication directly. No further installation is pending for this client update. No other driver is modified.

References: [Apple AudioServerPlugIn sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in), [output latency](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency). The installed SDK's `AudioServerPlugIn.h` defines the host configuration handshake and forbids calling client HAL APIs from inside a plug-in; this implementation obeys that restriction.
