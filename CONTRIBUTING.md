# Contributing

Build the shared Vanille scheme or run `Scripts/build.sh` with Swift 6 / macOS command line tools. Run `Scripts/test.sh` before a pull request. Regenerate the checked-in project with `ruby Scripts/generate-project.rb` when adding source files.

Use only public Apple APIs and system UI. Keep UI state, device discovery and audio rendering separate. No allocation, file/network work, heavy locks or UI calls belong in a realtime callback. Preserve the direct wired + one system AirPlay baseline and its measured latency before expanding routing.

Describe exact hardware/OS, the selected macOS default output, the failure trigger and whether a result is software readback or actual listening. Never upload recorded system audio, raw personal device identifiers or private diagnostics. Review diagnostic device names before sharing them.

New user defaults must work without HomePods and must not assume a speaker model. Preserve existing settings and original audio on errors. Unverified behavior must remain marked partial.

Release candidates are produced locally by `Scripts/prepare-release.sh`; publishing a binary requires the separate signing, notarization and hardware gates in RELEASE.md. Contributions are made under the repository's MIT license.
