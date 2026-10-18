# Release preparation

Version: Config/Version.xcconfig. Current candidate: 0.2.0 (2).

This is an **ad hoc signed development candidate**, not a notarized public macOS release. The source repository is public. No GitHub Release or binary upload is performed by the preparation script.

## Reproduce

```sh
./Scripts/test.sh
./Scripts/prepare-release.sh
```

The script creates `build/release/Vanille.app`, an arm64 zip, MIT license, this notice and a SHA-256 checksum. It validates a freshly extracted archive, minimum OS, resolved version, signature and absence of diagnostics, third-party runtimes and virtual-output experiments. Temporary files and paths are derived from the checkout and standard system directories.

Xcode: open Vanille.xcodeproj, choose the shared Vanille scheme and Release. Xcode and the standalone script read the same version configuration. macOS 15 uses native popover material; a build made with SDK 26 or newer lets NSPopover adopt Liquid Glass on macOS 26+. macOS 27 uses the same public component. Builds made with an older SDK retain the native material fallback.

## Before publishing a binary

- Run the baseline wired + one system AirPlay acceptance scenario, including real video, pause/play/seek, gain/EQ and original-output recovery. Record the system default explicitly.
- Verify first launch, denied audio permission, missing/disconnected devices and existing settings migration on a clean user account.
- Check Light/Dark, Reduce Transparency, Increase Contrast, VoiceOver and keyboard navigation on the target OS versions.
- Use a Developer ID identity and hardened runtime, submit to Apple's notarization service, staple and validate Gatekeeper on a clean Mac. Current scripts deliberately make no notarization claim.
- Resolve or prominently document the current system-AirPlay connection/default-output limitation. Automatic HomePod connection and multiple independent AirPlay endpoints are not release features.
- Create and review release notes and checksums, then publish the verified artifact. Never include build diagnostics, private device identifiers or captured audio.

Automatic updates are not implemented. Experimental latency drivers are not distributed with this candidate. Existing installations from an experiment are untouched; this app does not use those devices.
