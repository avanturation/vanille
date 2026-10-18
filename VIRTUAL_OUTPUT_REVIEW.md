# Virtual output installation review

This is an A/V synchronization experiment on `experiment/latency-aware-output`. The existing production app and its EQ, application gain and speaker-routing implementation are preserved.

## IMPLEMENTED

- A Swift AudioServerPlugIn using Apple's public ABI, with one hidden 48 kHz stereo output. It is ineligible for standalone default selection and discards its copy of aggregate audio.
- A host-approved configuration handshake for changing the actual output latency property. The standard latency property remains read-only; the app uses the declared `vlat` control to request a change.
- Native inspection of private aggregates containing the timing device and MR4. The probe restores the original latency and never selects a different system default.
- An installer and a recoverable removal package.

## VERIFIED

- Native arm64 build, ad hoc code signature, CFPlugIn factory discovery and instance loading.
- 61 isolated checks against the actual built binary, including 100,000 concurrent clock/configuration calls, malformed data, retained CF property ownership, device identity, fixed format, duplicate starts, timestamp rate and denied/aborted configuration changes.
- Before installation, the native app reports the missing driver and preserves MR4 as the default. No audio is intercepted by this probe.

## PARTIAL

The isolated fake host verifies ABI and internal behavior. It does not verify loading in Apple's audio host, aggregate latency propagation, source-player video scheduling, physical sound or protected playback. The normal AirPlay bridge remains available in Music Mode.

## NOT IMPLEMENTED / NOT VERIFIED

Automatic source-aware compensation through the new virtual path is not yet enabled. Safari/YouTube plus MR4 and both HomePod groups must pass the actual A/V acceptance test before Video Mode is labeled synchronized. No video-frame capture, DRM interception or player-script workaround is introduced.

## Exact installation changes

`Install-Vanille-Video-Timing.pkg` adds only `/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver` (plus the normal macOS installer receipt). It refuses to overwrite an existing bundle. Bundle relocation is disabled. It verifies the installed signature and restarts `coreaudiod` once so macOS can load the plug-in; all Mac audio may stop briefly. The package requires macOS administrator authentication. It does not install a kernel extension, background helper, network service or login item, and does not change SIP or privacy permissions.

The local build is ad hoc signed, not Developer ID signed or notarized. System-host compatibility still requires the on-machine test. A restart of the audio service may be insufficient on some system versions; that will be recorded rather than hidden.

For recovery, stop Vanille processing and restore MR4 first. `Remove-Vanille-Video-Timing.pkg` verifies the bundle identifier, moves only this driver into `/Library/Audio/Plug-Ins/Vanille Disabled Drivers/` with a timestamp, and restarts the audio service. The driver remains recoverable. Existing Apple, CalDigit, Background Music and other installed drivers are not modified.

Development was authorized by the user. Installation and its audio-service restart require the separate approval described with these concrete files. Until then no system driver directory is changed.

References: [Apple AudioServerPlugIn sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in), [output latency](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency). The installed SDK's `AudioServerPlugIn.h` defines the host configuration handshake and forbids calling client HAL APIs from inside a plug-in; this implementation obeys that restriction.
