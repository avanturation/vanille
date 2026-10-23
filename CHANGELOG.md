# Changelog

## 0.2.1 — development candidate

- Fix short system sounds and new audio processes restarting the entire output session. Keep existing physical outputs running and attach independent process readers.
- Preserve application gain, global EQ, per-device gain and automatic output alignment. Helper readers share their parent application's saved level.
- Add bounded input handoff, per-reader fail-open recovery, and callback-safe clock/underrun instrumentation. Distinguish media and system-effects default devices.
- Add actual three-route continuity tests, helper-process churn, effects-route changes, and concurrent buffer safety coverage. See AUDIO_DROPOUT_REPORT.md for measured results and remaining qualification.

## 0.2.0 — development candidate

- Restore the direct Core Audio baseline, keeping later multi-AirPlay and virtual-output work on a separate branch.
- Use native Liquid Glass on supported builds and system material fallback on older SDKs/systems; provide an opaque accessibility fallback.
- Compact device list, single-output selection, existing group controls, inline app levels and separate EQ/settings windows.
- Start new installations from their actual system output rather than speaker-model templates. Preserve existing groups and settings.
- Add MIT licensing, shared version configuration, local release preparation, archive validation and explicit public-release gates.

Automatic HomePod connection and retaining an MR4 system default with the current AirPlay endpoint are not complete. This is not a notarized release.
