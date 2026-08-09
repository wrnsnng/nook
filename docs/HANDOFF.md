# Project status

This page records durable maintainer context. GitHub issues and pull requests are
the source of truth for active work; private task trackers are not required to
contribute.

## Current release

Nook 1.6.4 (build 12) is the current public release.

- Release builds use stable Xcode 26 and the macOS 26 SDK.
- Distributed builds are Developer ID signed, notarized, stapled, and delivered
  through a signed Sparkle feed.
- The release is available from the
  [binary releases repository](https://github.com/wrnsnng/nook-releases/releases/tag/v1.6.4).
- User-facing changes are mapped in [CHANGELOG.md](../CHANGELOG.md).

## Durable constraints

1. **Detection is heuristic.** Meeting app windows change; manual start must
   remain first-class.
2. **Recording requires consent.** Detection can prompt but must not silently
   start capture.
3. **Speech quality is OS-dependent.** Language assets, microphones, overlapping
   speech, and Apple Speech availability affect results.
4. **Speaker separation is source-based.** Nook distinguishes system audio from
   the user's microphone, not every remote participant.
5. **Foundation Models are optional.** The deterministic summary fallback must
   remain useful.
6. **Screen capture permission requires relaunch.** Pending user intent must be
   handled transparently across that relaunch.
7. **Toolchain and identity are release behavior.** Contributor builds use a
   development identity; official builds require stable Xcode 26 and the stable
   distribution identity.
8. **The panel is display-specific.** Geometry changes need both notched MacBook
   and non-notched external-display testing.
9. **macOS 26 is the current minimum.** Older-system support requires an explicit
   compatibility design.

## Historical toolchain regression

Versions 1.6.2 and 1.6.3 exposed why release and contributor toolchains must be
explicit. An SDK/compiler fence removed live audio conversion from stable builds
while newer local toolchains retained it, and an empty Speech analyzer could
wait indefinitely during finalization. Version 1.6.4 moved conversion to
`AVAudioConverter`, added direct conversion tests, and bounded empty-input
finalization.

Treat behavior that differs by Xcode or SDK as a release blocker. CI covers the
stable toolchain, while new-SDK experimentation belongs on a separate branch and
must not silently alter release output.

## Manual release acceptance

Automated tests cannot fully exercise macOS privacy prompts, physical displays,
live system audio, or an installed update. Before an official release, verify:

- fresh permission grant, denial, recovery, and required relaunch;
- manual and detected starts, pause/resume, finish, cancellation, and failure
  cleanup;
- live captions and saved-audio transcription with synthetic content;
- Markdown save/edit/search and optional audio retention;
- VoiceOver, keyboard navigation, motion, transparency, contrast, light, and
  dark appearance;
- notched and non-notched panel geometry;
- official bundle identity, exact entitlements, code signatures, notarization,
  stapling, and Gatekeeper assessment; and
- full-archive update from the previous supported release without losing macOS
  permission grants.

See [ACCESSIBILITY.md](ACCESSIBILITY.md), [PRIVACY.md](PRIVACY.md), and
[OPERATIONS.md](OPERATIONS.md) for detailed acceptance criteria.

## Choosing work

Prefer observed user problems, reproducible platform failures, privacy and
accessibility gaps, and tests that protect existing behavior. Propose major
product or architecture changes in a public issue before implementation. Avoid
reopening settled design decisions without new evidence.
