# Virtual output installation review

This is an A/V synchronization experiment on `experiment/latency-aware-output`. The existing production app and its EQ, application gain and speaker-routing implementation are preserved.

## IMPLEMENTED

- A Swift AudioServerPlugIn using Apple's public ABI, with one hidden 48 kHz stereo output. It is ineligible for standalone default selection and discards its copy of aggregate audio.
- A host-approved configuration handshake for changing the actual output latency property. The standard latency property remains read-only; the app uses the declared `vlat` control to request a change.
- Native inspection of private aggregates containing the timing device and MR4. The probe restores the original latency and never selects a different system default.
- An installer and a recoverable removal package.

## VERIFIED

- Native arm64 build, ad hoc code signature, CFPlugIn factory discovery and instance loading.
- 67 isolated checks against the actual 0.1.1 binary, including the host-supported CFString custom-property wire type, 100,000 concurrent clock/configuration calls, malformed data, retained CF property ownership, device identity, fixed format, duplicate starts, timestamp rate and denied/aborted configuration changes.
- Before installation, the native app reports the missing driver and preserves MR4 as the default. No audio is intercepted by this probe.
- Version 0.1.0 was installed with explicit user authorization. The installed signature and binary hash match the tested bundle. Hidden UID lookup succeeds on the real HAL. Its raw UInt32 custom control was rejected by the real host (`who?`); the isolated fake host did not catch that marshalling restriction. Version 0.1.1 fixes the declaration and payload to CFString and adds corresponding regression checks. Its on-machine update test is pending.

## PARTIAL

The isolated fake host verifies ABI and internal behavior. It does not verify loading in Apple's audio host, aggregate latency propagation, source-player video scheduling, physical sound or protected playback. The normal AirPlay bridge remains available in Music Mode.

## NOT IMPLEMENTED / NOT VERIFIED

The app has a gated experimental public aggregate and source-player probe, preserving the existing capture, EQ, application gain and MR4 physical-render path. The experimental route cannot start until an installed private probe confirms real latency propagation and default-output eligibility. Automatic source-aware compensation is not yet verified. Safari/YouTube plus MR4 and both HomePod groups must pass the actual A/V acceptance test before Video Mode is labeled synchronized. No video-frame capture, DRM interception or player-script workaround is introduced.

## Exact installation changes

`Update-Vanille-Video-Timing-0.1.1.pkg` updates only `/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver` (plus the normal macOS installer receipt). It recognizes the exact installed 0.1.0 bundle identifier and binary SHA-256, and moves that bundle into `/Library/Audio/Plug-Ins/Vanille Disabled Drivers/` before applying the correction. It refuses unrecognized versions and symbolic links. Bundle relocation is disabled. It verifies the installed signature and restarts `coreaudiod` once so macOS can load the plug-in; all Mac audio may stop briefly. The package requires macOS administrator authentication. It does not install a kernel extension, background helper, network service or login item, and does not change SIP or privacy permissions.

The local build is ad hoc signed, not Developer ID signed or notarized. System-host compatibility still requires the on-machine test. A restart of the audio service may be insufficient on some system versions; that will be recorded rather than hidden.

For recovery, stop Vanille processing and restore MR4 first. `Remove-Vanille-Video-Timing.pkg` verifies the bundle identifier, moves only this driver into `/Library/Audio/Plug-Ins/Vanille Disabled Drivers/` with a timestamp, and restarts the audio service. The driver remains recoverable. Existing Apple, CalDigit, Background Music and other installed drivers are not modified.

Development, installation and the audio-service restart were explicitly authorized by the user. Automatic approval review blocked the agent's Install-button click; the user completed installation and administrator authentication directly. Applying 0.1.1 requires the same manual macOS authentication step. No other driver is modified.

References: [Apple AudioServerPlugIn sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in), [output latency](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency). The installed SDK's `AudioServerPlugIn.h` defines the host configuration handshake and forbids calling client HAL APIs from inside a plug-in; this implementation obeys that restriction.
