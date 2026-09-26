# Nook 1.20.0 release acceptance

Candidate version: **1.20.0**, Sparkle build **36**.

## Publication status checked September 4, 2026

The [1.20.0 binary release](https://github.com/wrnsnng/nook-releases/releases/tag/v1.20.0)
was published September 1 and was followed by
[1.20.1](https://github.com/wrnsnng/nook-releases/releases/tag/v1.20.1) on September 3. The
candidate validation below is historical, not a current claim that publication
is pending. This reconciliation checked the release listing only; it did not
re-verify archive signatures, the signed update feed, or an installed update.
The hands-on checklist remains open because publication is not its evidence.

This release includes the accumulated review fixes, the Library publication and
observation changes, and the native editor work proposed in
[issue 15](https://github.com/wrnsnng/nook/issues/15). The original publication
gate required binary-release and signed-update-feed verification.

## Candidate validation

- The release repository's current version is 1.19.0, build 35. Version 1.20.0
  and build 36 were unused at the September 1 preflight; check again before
  publication.
- The local Developer ID identity matches the previous release. The previous
  public archive's SHA-256 matched GitHub's asset digest, and its app contains
  both Intel and Apple silicon architectures.
- The configured notarization profile is available. Two bounded lookups of the
  existing Sparkle public key timed out. Key access must complete and match the
  embedded public key before update signing; no key was exported or replaced.
- Full integration passes **1,040 tests**, zero failures/skips, plus two Python
  tests. Snapshot and optimized builds pass with Swift/Clang warnings treated
  as errors. All 145 source/project fingerprints remain unchanged across the
  accepted run under stable Xcode 26.6.
- The editor's focused suite passes 18 test declarations with 30 parameter
  cases. It hosts the real Nook editor and covers exact Unicode replacements in
  both directions, insertion, selection, Undo/Redo, checklist insertion,
  resizing, focus and simulated composition, commit and cancellation. The full
  accessibility text and character count remain available, including offscreen
  Unicode/CRLF ranges after scrolling and resizing.
- The first full integration attempt exposed composition and exact-text
  synchronization defects. Both were corrected; the failures were retained in
  the local test records rather than treated as accepted behavior.

The accepted integration is recorded in
`.build/performance-review/library-editing-20260901/integration/attempt-05/build-acceptance.json`.
The final native candidate uses identical production code. Native Save, Undo and Redo preserve exact text in
both 20,000-word fixtures, with every original file in each 1,001-note library
unchanged. Actual macOS dead-key composition and middle-word selection
replacement also preserve the surrounding multilingual text. Both isolated
apps quit normally. These use development identities, not an installed update.
The final controller tests also verify quiet unchanged refreshes, current file
revisions, independent Reminders receipts/errors, and pending-search cancellation.

The first editor/Library comparison is recorded in
`.build/performance-review/library-editing-20260901/matched-comparison.md`.
It shows a large long-paragraph typing improvement and fewer Library row updates,
with a separate roughly 257 ms post-save List/layout pause remaining. The final
controller candidate has matching successful Time Profiler recordings under
`.build/performance-review/library-list-final-20260901/`. Two failed SwiftUI
recordings and an initial baseline with an extra synthetic pad are retained but
excluded from performance acceptance. In the final comparison, main-thread CPU
over the same four seconds after input falls from 481 to 424 ms for 200
paragraphs and from 484 to 432 ms for one paragraph. List traversal falls about
11% in both workloads. Typing and broad layout costs are largely unchanged.
There is one accepted capture per variant/workload, with the final candidate
recorded first. The CPU template does not establish that the earlier 257 ms
pause is fixed. No frame-rate or stall-free claim follows from these measurements.

Artifact verification will be recorded when packaging finishes. Local test-run
records, synthetic fixture files, Instruments traces and signing records are
excluded from the source distribution.

## Hands-on checks required before publication

These checks remain open. Automated tests, simulated marked text and isolated
development identities do not complete them. Follow the full
[manual release checklist](HANDOFF.md#manual-release-acceptance) and
[privacy-permission QA process](OPERATIONS.md#privacy-permission-qa) on the
candidate that will be distributed.

- [ ] Real recording and dictation: microphone and system audio, manual and
  detected starts, pause/resume, finish/cancel, saved transcript and playback,
  appending another sitting, and interrupted-recording recovery. Verify Cocoa,
  Chromium and unsupported-field delivery, clipboard restoration, dictated
  questions and repeated letters/numbers.
- [ ] Real input and accessibility: Japanese, Chinese and Korean composition,
  dead keys, selection, scrolling and resizing in Quick Note, My notes and
  Markdown; VoiceOver reading/editing and keyboard-only navigation. Check the
  changed controls in both appearances and with the relevant accessibility
  display settings. Simultaneous external replacement during composition does
  not have a new conflict-merging policy.
- [ ] Permissions and local integrations: fresh grant, denial, revocation and
  relaunch, including both screen-access consent layers; Calendar and
  Reminders permissions and outcomes; actual retention-to-Trash behavior.
- [ ] Physical displays: the changed meeting-panel controls on a notched
  MacBook and a non-notched display.
- [ ] Installed update: update from the previous supported official release
  using the candidate's real archive, preserve existing notes and macOS grants,
  then verify launch, recording and dictation from `/Applications/Nook.app`.

Signing, notarization, Gatekeeper, archive signatures and feed checks are
separate release-tooling requirements. None of those proves the hands-on
behaviors above.

## Publication guardrails

Use stable Xcode 26 and pinned XcodeGen 2.45.4. Keep the default development
identity and disabled updater in `project.yml`; the official artifact workflow
opts in explicitly. The source changes, version, generated project, release
notes and changelog belong in the same reviewed source commit.

Review the prepared archive and feed before publication. The current release
script is not resumable: running it a second time with `--publish` re-signs the
app and then refuses the existing versioned archives. Do not delete verified
outputs to get past that guard. Publish only the already verified artifacts,
with their recorded digests, through the documented release upload sequence.

Do not replace an existing version's public assets or promote the update feed
while acceptance is incomplete. Keep private signing and notarization records
out of commits, pull requests, issues and uploaded CI artifacts.
