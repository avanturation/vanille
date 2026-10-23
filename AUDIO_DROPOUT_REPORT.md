# Short-sound audio dropout — 0.2.1 (3)

2026-10-24 KST. Branch: `fix/continuous-audio-process-churn`. This report supersedes compilation-only or historical results for this bug.

## Root cause and evidence

`AudioController.reconcile` included every application's process IDs in its output graph signature. A short effect, a newly playing application or an additional helper changed the signature and executed `engine.stop()` followed by recreation of all taps, the physical-output Aggregate and its IOProc. This reset ongoing audio and DSP history. AVAudioEngine and intentional volume ducking were not involved. The media/system-effects defaults and 48 kHz format remained unchanged in the reproduction; input buffer shortfalls were zero.

A native app played a quiet continuous 1 kHz carrier while a second app, transient effect process and system alert were repeatedly started/stopped. Independent unmuted taps read the two actual output streams. Before the fix there were **8 output stop/start cycles**, minimum carrier amplitude **0** on both outputs, and **185 wired / 97 AirPlay** low-amplitude 50 ms windows. Event host timestamps associate the interruptions with process-list rebuilds. See [baseline-current.json](Reports/Dropout/2026-10-24/baseline-current.json).

An intermediate fixed tap pool removed explicit restarts but still updated tap descriptions inside the same Aggregate. On this Mac those HAL updates stalled its callback: **9 gaps**, maximum **234.96 ms**, and both carrier minima still zero. It was rejected, not shipped. See [rejected-shared-tap-pool.json](Reports/Dropout/2026-10-24/rejected-shared-tap-pool.json). Adding buffer capacity or a restart delay would not fix that cause.

## IMPLEMENTED

- Keep the existing physical wired + one macOS system AirPlay Aggregate and output IOProc running across process discovery, helper changes, effect sounds and ordinary silence.
- Attach an independent, immutable single-process tap reader through its own private input-only Aggregate. Starting/stopping one reader cannot reconfigure the output Aggregate or another process's reader. Helpers use the parent application's existing saved gain/mute/bypass.
- Feed the existing RenderContext/DSP through bounded preallocated SPSC input slots. Preserve existing app gain ramps, 10-band EQ/headroom/limiter, per-device gain and automatic output delay calculation. No UI redesign, new virtual output, hardware buffer-size change, HLS, protocol implementation or additional AirPlay connection.
- Use one actual producer/output callback quantum as an input phase guard. At the tested 48 kHz the producer is 512 frames (about 10.7 ms). Memory capacity is a bound, not a prefill/latency target. This small input handoff cost must be included in later acoustic A/V qualification; zero added latency is not claimed.
- Restore only a failed input to its original path. Unsupported capture formats also remain original. Only real output/device/format changes, explicit pause or output failure stop the output session.
- Observe media default (`kAudioHardwarePropertyDefaultOutputDevice`) separately from system-effects default (`kAudioHardwarePropertyDefaultSystemOutputDevice`). Changing the effects device alone does not rebuild media output. Effects on a different device retain that original route.
- Record engine/output start-stop, tap and capture Aggregate lifecycle, output reconfiguration/format notifications, host/sample timestamp gaps, input ring overruns/underruns and source failures. Callbacks update atomic counters; the control queue performs bounded logging. No audio samples are persisted or uploaded.

## VERIFIED

Environment: Mac mini M4, arm64, macOS 27.0 (26A428), Swift 6.4 / SDK 27. Actual outputs: CalDigit TS4 Audio - Rear (MR4) and one macOS-connected AirPlay stereo pair; both 48 kHz stereo. The media default remained AirPlay. This does not claim that macOS can keep MR4 literally selected as default while retaining its current AirPlay endpoint.

Each native continuity run includes a second application's start/exit, the carrier application's nested helper start/exit, two short-effect process start/exit pairs, four native system-alert requests, and two changes of the separate system-effects output. Settings/defaults and test resources are restored. Tests use a separate 440 Hz transient so it cannot phase-cancel the measured 1 kHz carrier.

| Real output path | Output restarts | Output clock/sample gaps | Carrier under/overruns | Low carrier windows | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Wired + one system AirPlay | 0 | 0 / 0 | 0 / 0 | 0 / 637 on each | PASS |
| One system AirPlay only | 0 | 0 / 0 | 0 / 0 | 0 / 634 | PASS |
| Wired only | 0 | 0 / 0 | 0 / 0 | 0 / 635 | PASS |

Maximum physical output callback interval was 10.69 ms (combined), 2.69 ms (AirPlay only), 10.71 ms (wired only); these are callback periods, not acoustic latency. Carrier ring occupancy stayed bounded at 512–1024 frames (combined/wired) and 128–1024 frames (AirPlay only), producer quantum 512. There was no observed clock discontinuity or accumulating queue growth in these roughly 32-second runs. JSON evidence: [combined](Reports/Dropout/2026-10-24/fixed-current.json), [AirPlay](Reports/Dropout/2026-10-24/fixed-airplay.json), [wired](Reports/Dropout/2026-10-24/fixed-wired.json).

- **72 offline checks passed**, including existing DSP/format/settings tests, unchanged output alignment, isolated-input continuity, bounded queue overrun rejection, nonfinite input rejection and concurrent producer/consumer ordering across 128,000 stereo frames.
- **17 native app gain/EQ/recovery checks passed** on this implementation: real gain/mute, EQ gain, two-app independent volume/mute, combined EQ, bypass and original-output recovery. [gain-eq.json](Reports/Dropout/2026-10-24/gain-eq.json).

- **12 native multi-output checks passed**: both physical streams, independent device gain/mute, 120 ms actual test offset, EQ on both streams, automatic alignment changing actual PCM, pause and safe stop/resource restoration. The test offsets are diagnostic-only; no user delay control was added. [output-routing.json](Reports/Dropout/2026-10-24/output-routing.json).
- Local optimized arm64 release app **0.2.1 (3)** built successfully. Fresh archive extraction passes strict ad hoc signature, minimum macOS 15, menu-bar-only metadata, MIT license and absence of diagnostic/virtual-output bundle checks. Full Xcode is not installed locally; Xcode CI is recorded separately.

- **Safari YouTube native live observation passed for 180 seconds** through wired + one system AirPlay. Seven system-alert requests and three quiet transient process start/exit pairs ran while the original Safari player kept playing. Output stop/start events **0**, additional output clock/sample gaps **0**, additional Safari ring under/overruns **0 / 0**, additional Safari capture gaps **0**. Both real outputs returned signal. First/last 30-second median queue occupancy differed by **512 frames**, one actual producer quantum; occupancy remained bounded at 512–1024 frames, with no observed growing backlog. One Safari input underrun existed before monitoring at startup and stayed at one; it is not counted as a steady-playback pass. [safari-playback.json](Reports/Dropout/2026-10-24/safari-playback.json).

- The user subsequently confirmed during the Safari test: **“끊김 없고 영상과 맞음”** (no interruption; video and sound match). This verifies the tested wired + one system AirPlay listening scenario. Exact speaker-arrival latency was not measured and other networks/devices/durations are not covered by that confirmation.
- [GitHub Xcode CI](https://github.com/avanturation/vanille/actions/runs/40006766162) passed on **macOS 15 and macOS 26** for implementation commit `1549988dcb7305e1103cf576fe22f136dc55396e`: Release Xcode project build, 72 DSP/buffer checks, release preparation and fresh archive validation on both runners.

## PARTIAL

- Actual native alert requests and independently launched short effects cover the notification/process-churn path. No message was sent to another person to simulate a messenger send; that exact application's effect remains a manual regression case.
- Stream readback measures PCM submitted to physical outputs. It cannot establish exact audible A/V latency or prove absence of a sub-window audible click. The new user confirmation covers the tested Safari scenario, not instrumented acoustic calibration or every application.
- The connected AirPlay endpoint cannot be selected as the system-effects default on this Mac. Distinct effects/media routes and effects-route changes were tested; shared AirPlay effects/media routing was not.
- Input capture currently requires Float32 stereo at the output sample rate; unsupported combinations bypass. Native 44.1/96 kHz combinations and long-duration drift require further qualification.

## NOT IMPLEMENTED

New virtual output devices, independent network HomePod connection/grouping, asynchronous input resampling, acoustic auto-calibration, video manipulation, DRM detection/bypass circumvention, or UI redesign. Existing explicit protected-content bypass remains; no video frames are accessed.

## KNOWN ISSUES / release limits

Automatic system-AirPlay connection and MR4-as-literal-default retention remain pre-existing limitations. Two independent HomePod groups are not a feature of this branch. Force-exit, sleep/wake, Core Audio server restart, denied permission on a clean account and all teardown-error combinations have not been newly fault-injected for this fix. A failed reader is isolated, but original-path restoration can take the 1.5-second watchdog interval if the reader stops responding silently.

The app is an ad hoc signed development candidate, not a Developer ID signed/notarized public release. No blanket guarantee is made for all applications, DRM services, networks or playback durations.

Archived experimental evidence also includes a first passing isolated-input run and a rejected nonorthogonal transient test: using a second 1 kHz source can acoustically/PCM phase-cancel the 1 kHz carrier even with zero clock/queue faults. The final regression fixture uses 440 Hz; the production DSP was not altered to make that test pass.
