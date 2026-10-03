# Draft recovery across process death

October 3, 2026, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple M4 Pro.

`DraftProcessRecoveryTests` runs `NookRecoveryProbe`, a test-only target, with
marked temporary directories containing synthetic data. The real My Notes,
Markdown and Quick Note controllers write about 108 KB of unfinished text,
including decomposed Unicode, Japanese, emoji, CRLF and trailing whitespace.
The child acknowledges a flushed checkpoint and remains alive without normal
Quit cleanup. The parent sends SIGKILL to that owned process and confirms its
signal termination. A fresh process scans and saves the checkpoint as a new
note through `DraftRecoveryController`.

Each editor runs against an unchanged original, an externally edited original,
and a renamed (unavailable) original library directory. All nine cases pass.
Assertions check exact bytes (only the identity line changes for Markdown), a
new note identity, no overwrite of original files, and checkpoint cleanup.

The complete suite passes 1,376 declarations / 1,835 cases, with zero failures,
skips or runtime warnings. The test result is
`Test-Nook-2026.10.03_20-26-37-+1000.xcresult` in the isolated worktree's
`.build/Tests/Logs/Test`. The probe and test are explicitly present in the
XcodeGen 2.46.0 generated project. The shipping application does not depend on
the probe; contributor identity and updater defaults are unchanged.

Reproduce after following the model setup in CONTRIBUTING.md:

```sh
xcodegen generate
xcodebuild test -quiet -project Nook.xcodeproj -scheme Nook \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/RecoveryTests \
  CODE_SIGNING_ALLOWED=NO -only-testing:NookTests/DraftProcessRecoveryTests
```

This establishes survival of an acknowledged checkpoint across process death,
not final-keystroke or power-loss durability. Renaming a synthetic directory is
not physical volume removal. It does not certify installed-app force-quit UI,
parked-draft interaction, failed-cleanup dialogs, destructive confirmations,
VoiceOver, physical input methods or sustained large-draft typing. Those remain
in [issue #14](https://github.com/wrnsnng/nook/issues/14) and HANDOFF's manual
release acceptance. No signed app, user library, capture or permissions changed.
