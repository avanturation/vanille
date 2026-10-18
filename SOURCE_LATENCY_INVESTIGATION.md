# Source-player latency investigation

2026-10-18 KST. This continues the A/V work; the external-player acceptance test has not passed.

The earlier single-aggregate probe did not inspect safety offset or the aggregate's owned AudioSubDevice objects. That was insufficient investigation. Eight private configurations were now inspected, both stopped and running, including single/two-device layouts, alternate clock sources, stacked arrangements, owned-subdevice property writes, and live composition updates. No default output or physical-device property was changed.

Declaring 192,000 extra output frames at 48 kHz did propagate into the aggregate's **safety offset**: 50 became 192,050 frames. Device latency stayed 50 frames, stream latency stayed zero for MR4, and AU presentation latency stayed 1.042 ms. A live composition update also changed safety offset. The actual IO output timestamp still led the callback by roughly 11.7 ms rather than four seconds.

An ordinary source AVPlayer was then run against private aggregates, without source-clock override, seeks, rate scheduling, or video correction. Two 12-second cases used synthetic audio only. The source player's command-to-media-time difference was approximately 166 ms with the normal declaration and 118 ms with the four-second safety declaration. The player clock matched the selected aggregate in both cases. A four-second source-time compensation was not observed. This audio probe is not a Safari video acceptance test and does not establish mathematical impossibility across all public APIs.

Both probes preserved the MR4 default and cleaned up IO and aggregates with `noErr`. Numeric records are in `Reports/AVSync/system-latency-matrix.json` and `Reports/AVSync/unmodified-source-player.json`. User audio was not saved.

The user has now explicitly authorized development and verification of an Apple AudioServerPlugIn virtual-output path, including relaxing the earlier driver restriction and the literal MR4 system-default requirement for this experiment. This is **development authorization, not an installed or verified driver**. Installation will require a concrete built artifact, isolated test results, and a description of system changes. The new path must report downstream output latency through the actual selected output device; it must still be validated with unmodified Safari video and all requested speakers.
