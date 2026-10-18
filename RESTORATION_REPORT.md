# Restored baseline and native UI — 2026-10-18

**The original direct Core Audio renderer has been restored. The user confirmed that wired + one system AirPlay output matches video. The system default during that confirmation was AirPlay. Retaining MR4 literally as the macOS default and connecting a cold HomePod automatically have not passed.**

## IMPLEMENTED

- Work is based on `main` / `3398114`, whose audio implementation is `14084e9094477faf7f8b68212c2a00546bdf3f59`. The audio engine, process manager, HAL helpers, EQ DSP, mixer and pulse code are preserved unchanged.
- The complex multi-AirPlay / latency-driver work is preserved separately on `experiment/airplay-latency-archive`, commit `6a14b3c`. The incomplete AAC transport probe is explicitly archived as incomplete. No part of that transport or virtual-output driver is in this app's processing path or package.
- Baseline pipeline: process taps → existing app gain → existing 10-band EQ → existing PCM output gain / automatic device timing → private wired + one system AirPlay Aggregate. No encoder, HLS server or virtual default output is inserted.
- Native 360-point NSPopover, system-managed Liquid Glass through NSPopover on eligible SDK/OS combinations, native material fallback, semantic system colors and an opaque Reduce Transparency / Increase Contrast path. Native output list, current hardware volume, group controls, compact app rows and separate EQ/settings windows.
- Generic new-user defaults: no assumed speaker models or phantom preconnected groups. Existing saved groups, aliases, app levels, bypass and profiles remain. Main group levels are disabled until the actual processing route is active.
- On launch, a valid current system output takes precedence over a saved in-app preference. This prevents the UI update's restart from replacing a live AirPlay connection with a previously selected wired output. A missing default falls back to available hardware; a valid hidden/foreign default is not overwritten.
- MIT license and third-party notices, shared 0.2.0 (2) version configuration, local release preparation, archive validation and documented signing/notarization gates. No binary release is published automatically.

## VERIFIED

| Test | Result and scope |
| --- | --- |
| Restored baseline, actual app gain/EQ | **17/17** native independent readback checks passed: gain, mute, EQ, combined processing, two apps, bypass, exit recovery and teardown. Default was system AirPlay |
| Native UI build, actual app gain/EQ | **17/17** repeated with the current wired + one AirPlay group preserved, including two simultaneous apps, EQ and gain together, bypass and teardown. The diagnostic harness now keeps the selected route instead of silently substituting AirPlay-only output |
| Restored baseline, wired + one AirPlay | **12/12** actual HAL readback checks passed: two signals, independent levels/mute, EQ, real delay path, automatic OS-reported timing, stop and no leaked resources |
| Native UI build, wired + one AirPlay | **12/12** repeated on the real two-output path. Independent levels/mute, EQ, actual 120/400 ms diagnostic offsets, automatic timing and stop/cleanup passed. Delay controls remain absent from the user interface |
| Video listening | User: **“두 스피커와 영상이 맞음”**, Chrome video, MR4 plus one system AirPlay, system default AirPlay. Qualitative listening; no acoustic millisecond measurement |
| Offline DSP/settings | **63 checks passed**, including real PCM, ramps, clipping bounds, delay, concurrent parameter snapshots, persistence and migration without speaker templates |
| System output transition | **Failed required variant:** selecting wired as the system default removed the AirPlay endpoint from the real HAL. A second existing Aggregate was open during the comparison; it began with four output channels and ended with two callback channels. No renderer fix was assumed from that observation |
| New UI startup | Saved preference was wired, actual system default AirPlay. The updated app reopened with AirPlay unchanged and two processed outputs active. This verifies reuse of an existing connection, not cold discovery/connection |
| Native UI inspection | Actual 360-point popover in Light and Dark appearances, live device states, disabled inactive group levels, app icons/levels, separate 10-band EQ, group editor, settings and read-only diagnostics inspected through accessibility and screenshots. Keyboard Settings shortcut works. Appearance override exists only in the diagnostic build |
| Release archive validation | Fresh extraction, strict ad hoc signature, arm64, macOS 15 minimum, resolved 0.2.0 version, menu-bar flag and license passed. Diagnostic candidate was correctly rejected by the release-only check |

Numeric reports are in [Reports/Restoration](Reports/Restoration). The reports contain no audio samples, private endpoint UIDs or network speaker names. The older reports under Tests/Results remain historical evidence rather than a claim that every variant passed today.

## PARTIAL

- **Wired-default retention:** two-output video playback passes with the system AirPlay connection retained. The explicit MR4-default variant does not currently pass on this Mac. Selecting the wired source is not reported as a successful AirPlay connection.
- **AirPlay experience:** the app can reuse the single connected HAL AirPlay endpoint and open the official macOS Sound settings. It cannot independently discover/connect named HomePods through this baseline. No app-only route picker is presented as a system router.
- **Synchronization:** existing device/stream/safety timing is preserved. Reported AirPlay stream delay changed between approximately 205 and 225 ms in native observations; these are software properties, not measured acoustic latency. No extra multisecond buffer was added.
- **Accessibility:** native controls, labels, system colors and display-option handling are implemented. Full VoiceOver listening, all keyboard paths, global contrast/transparency toggles and clean-account first launch still require a release qualification pass. Do not infer those from a screenshot or compile.
- **Older OS support:** minimum macOS 15 is retained; native Liquid Glass requires SDK 26+ and runtime macOS 26+. The installed environment is macOS 27. Older-system build checks are distinct from physical runtime tests.

## NOT IMPLEMENTED

- Automatic cold HomePod discovery/connection or multiple independently connected system AirPlay outputs.
- Additional HomePod mini routing in this baseline. It is deliberately below the verified two-output path.
- Automatic DRM detection, actual Netflix/TV+/protected Music qualification, captured video, DRM/HDCP processing.
- Developer ID signing, hardened-runtime notarization qualification, automatic updates or a published public binary release.

## KNOWN ISSUES

- Changing the macOS default away from the connected AirPlay route can remove it. Reconnect through macOS Sound; the app does not silently substitute a different HomePod.
- A post-UI diagnostic run that substituted an AirPlay-only aggregate received no processing callback and failed before signal measurements. Original output and all test resources were restored. The wired + AirPlay route started normally and passed all 17 signal checks; AirPlay-only processing requires separate investigation. Both reports are retained.
- An initial 11/12 routing run read a nonzero last spectral window after the engine stopped, without recording callback freshness. That observation alone cannot establish continued audio. The diagnostic now checks callback freshness, allows two analysis windows for continuing readers and requires the engine to be stopped. The subsequent 12/12 result has fresh callback activity and zero signal on both outputs, with the engine stopped; no production audio code was changed for this correction. The initial report is retained as `native-ui-routing-held-readback.json`.
- Protected content may require an explicit app bypass. No audio/frame capture workaround is used to force it through the engine. Bypassed audio remains on its original route.
- Network disconnect/recovery, sleep/wake, force termination, Core Audio restart and denied capture permission have not all been physically retested in this restoration. Their error paths remain implemented; they are not all marked verified.
- The installed experimental timing driver on the developer machine is left untouched and is not required by this app. Experimental and baseline apps must not process the same system audio together.
- The current zip is a development candidate. It is ad hoc signed, not notarized, and is not described as a finished public release.

## API and design provenance

The installed SDK is macOS 27. Its AppKit headers expose `NSGlassEffectView` from macOS 26 and `effectIsInteractive` from macOS 27. The SwiftUICore interface exposes `glassEffect`. These were reviewed, but the popover uses standard AppKit styling: Apple recommends allowing NSPopover to own its material rather than nesting an effect view. Native AppKit controls and regular titled auxiliary windows are retained. Light/Dark visual QA used an app-local diagnostic appearance override; it did not change the user's global appearance setting.

[Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [Apple Multi-Output guidance](https://support.apple.com/guide/audio-midi-setup/play-audio-through-multiple-devices-at-once-ams7c093f372/mac), [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). SDK 27 headers confirm NSGlassEffectView availability from macOS 26. This implementation follows Apple's standard-popover guidance: NSPopover owns the glass, with no additional effect view in its content. [Chorus](https://www.theodorehq.com/chorus/) informed information density and device organization; its branding, assets and layout were not copied.
