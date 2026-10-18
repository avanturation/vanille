# Changelog

## 0.2.0 — development candidate

- Restore the direct Core Audio baseline, keeping later multi-AirPlay and virtual-output work on a separate branch.
- Use native Liquid Glass on supported builds and system material fallback on older SDKs/systems; provide an opaque accessibility fallback.
- Compact device list, single-output selection, existing group controls, inline app levels and separate EQ/settings windows.
- Start new installations from their actual system output rather than speaker-model templates. Preserve existing groups and settings.
- Add MIT licensing, shared version configuration, local release preparation, archive validation and explicit public-release gates.

Automatic HomePod connection and retaining an MR4 system default with the current AirPlay endpoint are not complete. This is not a notarized release.
