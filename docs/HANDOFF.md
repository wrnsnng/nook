# Project status

This page records durable maintainer context. GitHub issues and pull requests are
the source of truth for active work; private task trackers are not required to
contribute.

## Current release

Nook 1.22.2 (build 41) is the current public release, published September 27,
2026: multi-selection of notes and a New Folder row, built locally on Xcode 27
from [e987f64](https://github.com/wrnsnng/nook/commit/e987f64a1ab36f7fdcdb0dd6d2b71b9c50d602b9)
(PR #42) the same way as 1.22.1. Earlier the same day came 1.22.1 (build 40)
and 1.22.0 (build 39). All three were released at the maintainer's direction **without** the
hands-on acceptance described under
[Manual release acceptance](#manual-release-acceptance).

- 1.22.1 fixes a crash on macOS 27 when hovering the hidden recording pill
  (AppKit's update-constraints loop; the pill's tooltip was removed), reworks
  the notes page ("In summary", adding items and sections) and is the first
  release built with **stable Xcode 27** (macOS 27 SDK, deployment target
  still macOS 26). Apps linked against the 26 SDK get the older window style
  on macOS 27, including a non-floating sidebar.
- **Local build exception.** GitHub's hosted macOS images stopped at Xcode 26.6
  when Xcode 27 shipped, so the 1.22.1 candidate was built on the maintainer's
  Mac with `Scripts/build-distribution-app.sh` (the same script the
  distribution workflow runs) from a clean checkout of `main` at
  [2aa4f7c](https://github.com/wrnsnng/nook/commit/2aa4f7c965fcce26ee54ec822e4dece2b1d09aeb).
  Its app source is identical to the release PR #40 merge; #41 changed only
  the build script and workflows. Contributor CI tests on the newest stable
  Xcode 26 as a cross-check until the images carry Xcode 27. See
  [OPERATIONS.md](OPERATIONS.md#unsigned-official-configuration-artifact).
- 1.22.0 came from `stable-macos-build` run 36299380707 at
  [8c5450e](https://github.com/wrnsnng/nook/commit/8c5450e2ba02de7f0efb9bcd49a21d0af0bd61bf)
  (release PR #38, which also carried #35, #36 and #37).
- Both: Developer ID signed (team V2KY59725J), notarized, stapled and
  Gatekeeper accepted; every public asset re-downloaded and byte-compared with
  the prepared files; archive and feed EdDSA signatures verified. The previous
  appcast is retained privately by the maintainer for rollback.
- The test action passes a temporary `storageDirectory` to the test host.
  Without it, a fresh local build scanned `~/Documents/Nook`, waited on the
  Documents privacy prompt and stalled the whole run.
- Releases: [v1.22.1](https://github.com/wrnsnng/nook-releases/releases/tag/v1.22.1),
  [v1.22.0](https://github.com/wrnsnng/nook-releases/releases/tag/v1.22.0).
  User-facing changes are in [CHANGELOG.md](../CHANGELOG.md).

## Remaining issue implementation, September 4

### Code-review completion and remaining acceptance, September 5

Code review is now complete for all five draft feature PRs: #22 through
`2eb39a9`, #23 at `d5637d6`, #25 at `9e5ec8c`, #26 at `81c9c83`, and #27 through
`bdee228`. This is code inspection, not physical acceptance or release approval.
The final #22 review reproduced one more explicit-Stop race: a terminal callback
arrived before `stopCapture()` threw, but was ignored, leaving ownership of a
dead stream. Commit `2eb39a9f96a0d5056fcffde2a939d4e96056da13` remembers that
receipt through the stop await without releasing the competing-capture barrier
early. It resets between stops, so a later unconfirmed failure still retains
ownership. The test failed with `stopFailed` in `00-52-36`; ten final focused
repetitions passed 20 tests / 260 cases (`00-53-59`). Full isolated tests passed
1,058 / 1,349 (`00-54-42`, `.build/Issue13ReviewTests`) and combined tests passed
1,185 / 1,624 (`00-54-41`, `.build/IssueCompletionTests`), zero failures/skips.
Both NookSnapshot targets build; pinned generation is unchanged. The focused
commit is clean and pushed; [current #22 CI](https://github.com/wrnsnng/nook/actions/runs/33886644140)
passed (job 101067930490), including contributor tests, Release build and
development-identity/updater checks. All five feature PRs now have completed
code reviews and passing current-head CI. The latest #27 [CI for bdee228](https://github.com/wrnsnng/nook/actions/runs/33885904492)
passed at 2026-09-04 14:55:43 UTC (job 101065479064).

Issues #9/#12/#13 and PRs #22/#23/#27 now separate completed code review from
uncompleted physical acceptance. The remaining gates need real Mac permission
prompts/indicators, microphone/system capture and Speech/model behavior, native
keyboard/VoiceOver/physical IME, recovery/force-quit and storage scenarios,
display/accessibility settings and long-capture/editor performance. No signed
running app, permissions or user recordings changed. #27 must still follow #26,
be retargeted/reverified on main, and pass required acceptance before merge.

### Source-audio recovery review follow-up, September 5

PR #27 now contains `bdee2281933751a80e61b658126ae42538deb2ef` on
`codex/source-audio-recovery`, still stacked on #26 at `81c9c83`. Recovery had
refreshed cached playback only when a completed source package existed. A
synthetic primary-only resumed recording reproduced skipped extraction, omitted
resumed audio and deletion of the originals after saving the incomplete note.
Recovery now re-exports whenever capture parts remain, including absent or
unfinished source packages. An M4A with no remaining captures is still reused.
Failed export keeps the cached bytes, captures and unfinished package. This can
require repairing/removing an unreadable capture deliberately before retrying;
recovery does not silently accept an older, potentially incomplete cached mix.

The four new tone cases failed before the change (`00-43-45`). The first retest
also exposed a fixture assumption that two AAC inputs total exactly two seconds;
the assertion now uses their actual encoded durations with the same 50 ms
tolerance. Five repetitions of extraction/source-writer/source-transcription/
recovery suites passed 70 tests / 615 cases (`00-45-37`). Full isolated tests
passed 1,131 / 1,509 (`00-46-43`, `.build/SourceAudioReviewTests`); the combined
worktree passed 1,184 / 1,622 (`00-46-44`, `.build/IssueCompletionTests`), all with
zero failures/skips. NookSnapshot builds in both, existing test membership is
verified and pinned project generation is unchanged. The root project hash is
still `b0fcbab1fa94d6d62ac26d71e332516a464d8857b67e959e1c897eee4011dafb`.

The clean focused commit is pushed. [CI for bdee228](https://github.com/wrnsnng/nook/actions/runs/33885904492)
is queued/running. Previous #26 `81c9c83` CI and #27 `478a94d` CI passed; these
are historical evidence, not CI for this new fix. Code inspection covered the
writer, pause/stop ownership, source markers, export/transcription selection and
recovery/retention/cleanup, and produced the fix above. Final source-audio review
sign-off, real capture/model/native/accessibility/long-capture acceptance and
merges remain open. No signed running app, permissions or user recordings were
changed. The root combined worktree remains intentionally uncommitted.

Work is on `codex/remaining-issues`; these changes are not in a published
release. The original proposals remain preserved in GitHub issues #7 and
#9 through #15. No issue is considered complete from compilation alone.

- #7: Done/close offers a native destination sheet. All unambiguous Library
  notes are eligible except the pad's own autosaved copy. Spoken-note appends
  preserve existing source bytes; stale targets and self-filing are rejected.
  Source cleanup rechecks its revision, and failed cleanup retains a notice.
  Filing and #11 corrections are isolated together in draft
  [PR #25](https://github.com/wrnsnng/nook/pull/25), commit `9e5ec8c` on
  `codex/quick-note-filing-corrections`, checkout `.build/quick-note-review`.
  This patch is based on main `69fa135`, without #13's lifecycle changes or
  the search, summary and source-audio changes. Standalone verification passed
  1,068 tests / 1,392 cases, zero failures/skips, in
  `Test-Nook-2026.09.04_23-00-05-+1000.xcresult` under `.build/QuickNoteReviewTests`.
  NookSnapshot builds; new files belong to their app/snapshot/test targets.
  Repeated pinned generation is stable with project hash
  `c92338aa67d8b0d272472c7ed93bf1caa5ba61abfa73cc273d981a0d9a7dc83d`.
  Six isolated content renders were inspected in `.build/quick-note-review-renders`:
  filing light/dark, scratch light, item dark, stale correction light and
  correction/save-conflict/CLI disclosure dark at 380x240. The snapshot CLI
  needed its built Sparkle framework in `DYLD_FRAMEWORK_PATH`; no production
  build setting changed. These are not native-sheet interaction or physical
  acceptance. [Contributor CI](https://github.com/wrnsnng/nook/actions/runs/33876007150)
  passed generated-project verification, release-tooling tests, contributor
  tests, Release build and development-identity/updater checks. The PR remains
  draft/unmerged; review, real dictation, physical IME and keyboard/VoiceOver remain.
  A September 5 focused safety review found no new defect in filing ownership,
  stale correction decisions, verified-before-trash ordering or native edit
  refusal/Undo safeguards. No application code changed. The focused pad safety,
  correction parser/controller/routing and hosted-editor suites passed 81 tests /
  139 cases, zero failures/skips, in
  `Test-Nook-2026.09.05_00-01-52-+1000.xcresult`. This does not complete the native-
  sheet lifecycle review or physical acceptance. Issues #7/#11 and PR #25 record
  the scoped evidence and remain open.
  The subsequent September 5 code review completed sheet bindings/actions,
  dismissal/focus ownership and dictation routing, with no new actionable finding.
  PR #25 and #7/#11 now mark code review complete for `9e5ec8c`. Controller gates
  exclude simultaneous filing/correction decisions, actions validate captured
  identities/revisions, and cancellation guards late dictation. This was code
  inspection, not native interaction acceptance. Physical checks and merge remain
  open; the PR stays draft and no application code changed.
- #9: All/Today/Yesterday ranges share the unsaved-editor leave guard and use
  calendar days across daylight-saving changes. Cancellable off-main-actor
  fuzzy search includes transcripts and structured fields. Exact title matches
  lead abbreviations/typos and content matches; file identities stay distinct.
  This slice is now committed separately as `e5aff29` on
  `codex/palette-search-date-navigation` in draft
  [PR #23](https://github.com/wrnsnng/nook/pull/23), isolated at
  `.build/issue-9-review` from main `69fa135`. Its standalone full suite passed
  1,056 tests / 1,356 cases, zero failures/skips, in
  `Test-Nook-2026.09.04_22-43-19-+1000.xcresult` under `.build/Issue9ReviewTests`.
  NookSnapshot builds. The new PaletteSearchTests file is in the regenerated
  project, whose repeated-generation hash is
  `48f308cccbc5dbad47f6a90c7b1ae6310f3f17279448c4889cb94c574eef48a0`.
  The PR excludes #12 summary-session wiring and the #10 Open Questions field;
  its indexing addition remains with that later feature.
  [Contributor CI run 33874489034](https://github.com/wrnsnng/nook/actions/runs/33874489034)
  passed project generation, release-tooling tests, contributor tests, Release
  build and development-identity/updater checks. The PR remains draft/unmerged;
  code review and production native-sheet keyboard/VoiceOver acceptance remain.
  Search review follow-up `d5637d691cc1d81e836c00cb7c50babc4b0d2dda` is committed
  in PR #23. Cancellation now polls between fuzzy word comparisons within a long
  transcript and rejects already-ranked partial hits. The controller already
  refused stale output; this fixes obsolete comparison work continuing through
  the current term's word scan. A cached/uncached checkpoint regression failed
  against the preceding algorithm, which polled only four times, then passed.
  Ten focused repetitions passed 11 tests / 210 cases in
  `Test-Nook-2026.09.04_23-50-23-+1000.xcresult`. Final isolated tests passed
  1,057 tests / 1,358 cases, zero failures/skips, in
  `Test-Nook-2026.09.04_23-51-30-+1000.xcresult`; NookSnapshot builds and pinned
  generation stays unchanged. Source/test fixes were mirrored into the combined
  worktree; `Test-Nook-2026.09.04_23-53-19-+1000.xcresult` passed 1,181 tests /
  1,597 cases, zero failures/skips. No text truncation or modal/selection/leave-
  guard change was introduced. Normalization/tokenization/sorting remain
  synchronous passes, not interruptible deadlines. Follow-up
  [CI run 33880549268](https://github.com/wrnsnng/nook/actions/runs/33880549268)
  passed; job 101047864259 completed at 2026-09-04 13:59:11 UTC. Code review and
  physical native-sheet/keyboard/VoiceOver acceptance
  remain open.
- #13: The real audio-check lifecycle has an injectable start/stop session for
  synthetic tests. Cancelled/failed startup retains a session whose stop failed.
  Meeting/dictation capture refuses to proceed until teardown is confirmed.
  Permission failures offer their matching Settings pane, and copy names normal
  macOS recording indicators.
  This slice is now committed separately as `4b759c3` on
  `codex/audio-check-lifecycle` in draft [PR #22](https://github.com/wrnsnng/nook/pull/22).
  Its isolated checkout is `.build/issue-13-review`; the original combined
  worktree remains unchanged. Standalone full-suite verification passed 1,051
  tests / 1,340 cases, zero failures/skips, in
  `Test-Nook-2026.09.04_22-32-17-+1000.xcresult` under `.build/Issue13ReviewTests`.
  NookSnapshot builds and pinned project regeneration is unchanged.
  [Contributor CI run 33873533028](https://github.com/wrnsnng/nook/actions/runs/33873533028)
  subsequently passed project generation, release-tooling tests, contributor
  tests, Release build and development-identity/updater checks. The PR remains
  draft and unmerged. Code review and physical acceptance are still open.
  Review follow-up is committed as `d646a82742d2889dbe40cdb260e82328b4895325`
  in the same PR. Regression tests first reproduced a stopped candidate being
  ignored before startup returned, a redundant failed cleanup retaining an
  already stopped candidate, and direct task cancellation leaving Starting
  stuck. The service now records the candidate identity and terminal receipt
  across startup/cleanup, preserves explicit Stop's barrier, and releases direct
  cancellation to idle. It also publishes completion when the computed Settings
  Stop/Start control changes without another phase change; that missing signal
  was separately reproduced with an observer assertion. Six new tests cover
  these paths and old-callback isolation. README setup copy is now included in
  the isolated PR, matching the existing combined-worktree guidance.
  Final standalone verification: 1,057 tests / 1,347 cases passed, zero failures/
  skips, `Test-Nook-2026.09.04_23-41-01-+1000.xcresult`. Ten focused repetitions
  passed 19 tests / 240 cases in `Test-Nook-2026.09.04_23-41-33-+1000.xcresult`.
  NookSnapshot builds; pinned generation remains unchanged. Source/test changes
  were mirrored into the original combined worktree without replacing other
  features; its full run `Test-Nook-2026.09.04_23-42-10-+1000.xcresult` passed
  1,180 tests / 1,595 cases with zero failures/skips.
  [Follow-up CI](https://github.com/wrnsnng/nook/actions/runs/33879546012)
  passed for `d646a82` at `2026-09-04T13:48:07Z`, including generated-project,
  release-tooling, contributor tests, Release build and development-identity/
  updater checks. Actual native callback, permission/device, keyboard and
  VoiceOver acceptance remain unverified; this is synthetic ordering evidence.
- #12: Initial, appended, recovered and live-caption rescue notes hand off to
  shared per-file background summary sessions after saving their transcript.
  Progress and explicit Cancel Summary/Retry live above every saved-note tab;
  the existing prose stays visible. A local `summary_status: pending` field
  survives relaunch without automatically starting a model; `pending-append`
  retains the earlier session's actions on Retry. Failed, cancelled,
  stale and timed-out jobs preserve the note, and a successful write-up retains
  the live-caption incomplete-recording warning. Physical recording/recovery
  and keyboard/VoiceOver acceptance still require direct evidence.
  The shared summary portion and #10 item review/questions/recipes/fallback are
  isolated together in draft [PR #26](https://github.com/wrnsnng/nook/pull/26),
  commit `fa7860a` on `codex/saved-note-summary-review`, checkout `.build/summary-review`.
  It is based on main `69fa135`, independently of PRs #22 through #25, and excludes
  source-audio/capture/export changes (including their unused file-identity helper).
  Final standalone tests passed 1,090 tests / 1,405 cases, zero failures/skips,
  in `Test-Nook-2026.09.04_23-10-50-+1000.xcresult` under `.build/SummaryReviewTests`.
  NookSnapshot builds. Nine new source/test files have verified membership;
  repeatable pinned generation has hash
  `3c696873a3ccfd1a8cb260e4db1cd4b4918089bb193850f86bb727582c785eba`.
  Eight isolated content renders were inspected in `.build/summary-review-renders`:
  progress, fallback plus progress, questions, item correction/removal/staleness,
  and 300-point fallback/recipe controls. The fallback detail is 560x1050, not
  minimum-height acceptance. [Initial Contributor CI](https://github.com/wrnsnng/nook/actions/runs/33876908870)
  failed in the process test `aChildThatNeverReadsItsInputAndIgnoresTermCannotOutliveTheDeadline`;
  its quiet log did not retain the failed assertion. Follow-up commit `d4dcba8`
  adds failure-only xcresult summaries without changing application behavior,
  timeouts or assertions. The reporting shell preserves exit 65 even if the
  diagnostic command fails, and emits nothing extra on success. Five local
  process-suite repetitions passed 15 tests / 80 cases in
  `Test-Nook-2026.09.04_23-20-06-+1000.xcresult`; this does not establish the
  original CI failure's cause. [Follow-up CI](https://github.com/wrnsnng/nook/actions/runs/33877575885)
  passed for `d4dcba8`, including tests, Release build and development-identity/
  updater verification (job completed `2026-09-04T13:27:53Z`). Code review,
  actual-model, native-sheet focus/VoiceOver and
  recording/recovery acceptance remain. #12 still requires its separate source
  identity implementation and verification below, not just this summary PR.
  September 5 review reproduced a returned-task cancellation gap: cancelling
  `start`'s task before or during execution stopped work but left `isRunning`
  true, blocking Retry. The UI's existing session-level Cancel was unaffected.
  Commit `81fbddde221c7fb14b3494b1a9cf9aeb8e4b5a7f` adds identity-guarded exit
  cleanup, so an old cancelled task cannot clear a newer request. The regression
  failed in both cases in `Test-Nook-2026.09.05_00-07-03-+1000.xcresult`;
  an earlier method-filter attempt ran zero tests and is not evidence.
  Ten session-suite repetitions passed 17 tests / 350 cases in
  `Test-Nook-2026.09.05_00-07-26-+1000.xcresult`. Full isolated tests passed
  1,091 tests / 1,407 cases in `Test-Nook-2026.09.05_00-07-53-+1000.xcresult`.
  NookSnapshot builds; pinned project generation is unchanged. The exact source/
  test fix is mirrored into the combined worktree, whose full suite passed
  1,182 tests / 1,599 cases in `Test-Nook-2026.09.05_00-08-28-+1000.xcresult`.
  All passing runs had zero failures/skips. No model, save or merge rules changed.
  [CI for #26 at 81fbddd](https://github.com/wrnsnng/nook/actions/runs/33882099624)
  passed at 2026-09-04 14:16:10 UTC, job 101052958914.
  The dependent source branch merged `81fbddd` without history rewriting as
  `92eeaa8815ed3e930603d3a4101e1e7a6a80d1e0`. Its source-audio diff remains
  21 files (+2,519/-123). Full stacked tests passed 1,129 tests / 1,486 cases,
  zero failures/skips, in `Test-Nook-2026.09.05_00-09-37-+1000.xcresult`;
  NookSnapshot builds and pinned generation is unchanged. The merge is pushed,
  the checkout was clean, but [#27 CI at 92eeaa8](https://github.com/wrnsnng/nook/actions/runs/33882283155)
  failed at 2026-09-04 14:16:09 UTC, job 101053561694. The diagnostic summary
  records an empty PID marker in the process-deadline test, not a failed timeout
  or reap assertion. Issues #10/#12 and PRs #26/#27 record these revisions,
  preserve earlier CI failure history and leave acceptance/review/merge open.
  Further summary review found initial/appended merges compared segment UUIDs
  after the session had accepted identical model input. They could discard the
  generated write-up yet clear its pending state. `622bb3d67a4107f62dfc4e423d6cb2ac312657ad`
  shares exact transcript-input comparison across all three purposes, ignoring
  only row UUIDs while retaining count/wording/timing/duration/source checks.
  Expanded tests failed for initial/appended in `00-14-18`, then ten session
  repetitions passed 17 tests / 490 cases in `00-15-01`. Full isolated tests
  passed 1,091 / 1,421 in `00-15-40`; NookSnapshot builds. The commit also removes
  the duplicate Unreleased heading, retaining all release-note text.
  `17e6fa44fab24ab51b27a2070ad463bd7413a864` fixes the test-fixture PID readiness
  race exposed by CI: shell redirection makes an empty file before printf writes
  its number. The helper now waits for a positive PID rather than file existence.
  The empty-file regression reproduced the CI assertion in `00-18-03`; five
  process-suite repetitions passed 16 tests / 100 cases in `00-18-53`, including
  empty/zero/negative/malformed intermediate markers. Timeout, signal escalation
  and reap assertions are unchanged. This explains the observed 33882283155
  failure; the earlier 33876908870 run did not retain its assertion.
  Final isolated tests passed 1,092 / 1,425 in `00-19-48`; combined tests passed
  1,183 / 1,617 in `00-19-34`. All counts are tests / executed cases, zero
  failures/skips. Short result names here mean `Test-Nook-2026.09.05_<time>-+1000.xcresult`
  under the previously named separate derived-data test directories.
  The source branch merged both fixes as `eace31415b77112aba9c189def434e6a784c2a61`,
  resolving only the changelog-heading conflict while retaining both sets of
  release notes. Its code diff remains unchanged relative to the updated base;
  the total is 21 files (+2,519/-121), now that the base owns header deduplication.
  Full stacked tests passed 1,130 / 1,504 in `00-21-01`; NookSnapshot builds and
  pinned generation is unchanged. Source/test fixes are mirrored into the root
  combined worktree. Both PRs remain draft/unmerged and need latest-revision CI,
  remaining review and actual-model/native/physical acceptance.
  Those heads were pushed. [#26 CI at 17e6fa4](https://github.com/wrnsnng/nook/actions/runs/33883176334)
  failed at 2026-09-04 14:23:56 UTC (job 101056502025): the recovery conflict test
  observed zero in-memory notes. [#27 CI at eace314](https://github.com/wrnsnng/nook/actions/runs/33883384182)
  passed at 2026-09-04 14:30:14 UTC (job 101057187430).
  The tracker records the observed PID race as diagnosed and fixed, while
  preserving the uncertainty about the earlier assertion-free CI failure.
  Subsequent review diagnosed the recovery test fixture: its always-empty loader
  erased the saved note when conflict handling reloaded the library. An explicit
  reload reproduced the CI assertion in `00-25-44`. The fixture now uses the real
  decoder restricted to its temporary directory, awaits reload completion, and
  verifies the external summary/personal notes byte-for-byte. Ten recovery-suite
  repetitions passed 33 tests / 410 cases (`00-26-16`), and full isolated/combined
  suites passed 1,092 / 1,425 (`00-27-27`) and 1,183 / 1,617 (`00-26-36`), all with
  zero failures/skips. No production code changed.
  Commit `81c9c834043444774f95c9e5670690acaa150b70` also corrects the minimum summary
  snapshot height from 1,050 to 580 points at width 560. Four light/dark fallback-
  running/questions initial-viewport renders were inspected in
  `.build/summary-review-renders/*-minimum-*-20260905.png`. Tabs, visible review
  controls, fallback provenance and Cancel remain visible; lower document content
  still requires scrolling. These are not physical interaction/VoiceOver/IME
  acceptance. NookSnapshot builds in isolated and combined worktrees, pinned
  generation is stable, and the root project hash remains `b0fcbab1fa94d6d62ac26d71e332516a464d8857b67e959e1c897eee4011dafb`.
  Code review for PR #26 is complete, including generation/merge/write guards,
  compatibility, shared-session lifecycle and item-sheet presentation/focus.
  Actual-model and physical acceptance plus merge remain open. [CI at 81c9c83](https://github.com/wrnsnng/nook/actions/runs/33884144663)
  is queued/running; the dependent source branch has merged this fixture-only
  revision as `478a94dfd7d2bd9ea17f6fc71b1c35c1b7dea5aa` for verification.
  That stack passed 1,130 tests / 1,504 cases, zero failures/skips, in
  `Test-Nook-2026.09.05_00-31-05-+1000.xcresult`. NookSnapshot builds, pinned
  generation is unchanged and the clean merge is pushed. [Latest #27 CI](https://github.com/wrnsnng/nook/actions/runs/33884304862)
  is running. The tracker now marks #26 code review complete while keeping #27
  source review and every actual-model/native/physical gate open.
  The source-audio patch is now committed as `fdf2696` on
  `codex/source-audio-recovery` in draft [PR #27](https://github.com/wrnsnng/nook/pull/27),
  checkout `.build/source-audio-review`. It is stacked on PR #26 at `d4dcba8`,
  not directly on main: source recovery tests exercise the new background-summary
  handoff. Its 21-file diff excludes PRs #22–25 and includes source capture,
  extraction, transcription, lifecycle, recovery, retention, storage accounting,
  six new source/test files, regenerated project and privacy/technical/changelog
  documentation. It also removes the duplicated Unreleased heading inherited
  from PR #26. Full isolated stacked tests passed 1,128 tests / 1,484 cases,
  zero failures/skips, in `Test-Nook-2026.09.04_23-22-38-+1000.xcresult`
  under `.build/SourceAudioReviewTests`; NookSnapshot builds. Membership is
  verified and repeated pinned generation has hash
  `712b09b5d18fec75bf3478d76c29dec1641e82747694aaa359ebb5fcb93c09f5`.
  [Contributor CI](https://github.com/wrnsnng/nook/actions/runs/33877989687)
  passed for `fdf2696` at `2026-09-04T13:31:18Z`, including generated-project,
  release-tooling, contributor tests, Release build and development-identity/
  updater checks. Code review and real-Mac acceptance remain required. After #26 merges,
  retarget and reverify #27 against main before merge. Neither PR is released.
  Source identity now has a local auxiliary capture writer and source-aware
  file-transcription path; both still need review and physical acceptance.
  The legacy mixed-file `transcribeFile` path still emits `.mixed`. The local
  `AudioExtractor` now mixes every audio track of each part, retaining offsets,
  between-part gaps and final silence. A short synthetic silent endpoint is
  needed because the M4A exporter drops final empty composition edits even with
  an explicit export time range. Staged export validation protects the previous
  destination, and cleanup failures remain visible. The
  source-file and writer tests recover labelled synthetic audio through saved
  Markdown, not actual microphone/system capture. Verify actual captured
  metadata and complete sound before closing #12; never infer a speaker
  from track order or stereo channel position without evidence.
- #11: Quick Note now proposes deterministic natural voice corrections after
  inserting the literal command words. Review pauses capture, defaults to
  keeping words, and requires an unchanged note before applying an undoable
  native edit. Missing replacement words are entered in the review. Synthetic
  parser/controller/native-editor/delivery coverage includes exact Unicode,
  stale proposals, library changes, cancellation, external-field literal speech,
  refinement bypass, file conflicts and simulated composition refusal. Real
  dictation, native-sheet keyboard and VoiceOver acceptance remain open.
- #10: Open questions now travel through generation, validation, Markdown and
  saved-note presentation. Explicit General/Standup/One-to-one/Interview recipes
  persist in the note, influence local summary guidance and invalidate old-input
  results. Choosing a recipe never invokes generation. Existing user-written
  Open questions headings retain their original meaning; Nook-owned sections
  use an invisible ownership comment. Item review now opens exact related
  transcript passages in a native sheet for sentences and structured items.
  Local correction and removal require preview/Apply, retain action metadata
  and provide one-shot revision-guarded Undo until the sheet closes. Keyboard
  and accessibility focus request the first source and return to the origin
  or summary section when removal/staleness invalidates it. Fallback origin
  now survives reopening independently of progress, remains labeled during
  Retry and clears only with the accepted summary field. Physical focus and
  actual-model behavior remain to verify.
- #14 and #15: publication wording is reconciled. Physical IME, real audio,
  VoiceOver, force-quit, minimum-hardware and installed-update acceptance remain
  open unless supported by direct evidence. No new durability claim is made.
  The two-file publication correction is committed as `89e46bc` on
  `codex/reconcile-release-status`, isolated at `.build/release-status-review`,
  in [PR #24](https://github.com/wrnsnng/nook/pull/24). Release records were
  re-read September 4: v1.20.0 was published at `2026-09-01T01:39:49Z` and
  v1.20.1 at `2026-09-03T00:01:25Z`, neither draft nor prerelease. No new
  runtime tests, signature/feed verification or physical acceptance are claimed
  for this documentation-only patch.
  [Contributor CI](https://github.com/wrnsnng/nook/actions/runs/33874780284)
  passed at `2026-09-04T12:57:12Z`, including tests, Release build, generated-project
  and development-identity/updater checks. The two-file diff was reviewed against
  the release API records, then squash-merged September 4 at `13:30:32Z` as
  main commit `a46aa7adf50b8391de3c9af4ffe42a2bd88a9d9c`. GitHub confirms the
  merge changes only the two documentation files and retains `69fa135` as parent.
  Issues #14/#15 record the documentation task complete; every outstanding
  physical criterion remains open. No new app release or manual sign-off occurred.
  [Post-merge CI](https://github.com/wrnsnng/nook/actions/runs/33878458218)
  passed for `a46aa7a` at `2026-09-04T13:37:16Z`, including generated-project,
  release-tooling, contributor tests, Release build and development-identity/
  updater checks.

The initial full suite passed 1,043 tests on stable Xcode 26.6. The combined
#7/#9/#13 implementation then passed 1,068 tests with no failures or skips
(`Test-Nook-2026.09.04_18-56-42-+1000.xcresult`). The first
combined filing/search/navigation run passed 117 tests (149 parameter cases),
and the focused audio-check run passed 13 tests (17 parameter cases). Test builds
use `.build/IssueCompletionTests`, separate from any signed local app.
Light/dark filing snapshots were rendered and inspected under
`.build/issue-completion/`; snapshots do not prove native sheet keyboard or
VoiceOver behavior. The older palette fixture draws an overlay, unlike the
production native sheet, so it is not native presentation evidence.

The #12 background-summary integration passed **1,077 tests** (1,384 executed
parameter cases), with zero failures/skips, on the same stable Xcode/Mac mini.
The final run is
`.build/IssueCompletionTests/Logs/Test/Test-Nook-2026.09.04_19-21-45-+1000.xcresult`.
This includes deadline abandonment, exact-note retention, pending-status
round-trips, action-preserving append retry after relaunch, registry ownership,
and recovery-before-summary regression coverage. The generated project contains
`NoteSummarySessions.swift` in both app and snapshot targets and is unchanged
by a second pinned XcodeGen generation. Light/dark full saved-note running and
pending-status renders are under `.build/issue-completion/summary-*.png`; the
pending notice uses primary text and the existing bounded long-message view.
These are synthetic render/storage tests, not physical source-label recovery,
VoiceOver, keyboard-only flow or real capture acceptance.

The #11 correction work passed the full **1,098-test** suite (1,442 executed
parameter cases), zero failures/skips, in
`.build/IssueCompletionTests/Logs/Test/Test-Nook-2026.09.04_19-54-25-+1000.xcresult`.
The real hidden NSTextView tests cover one-step exact Undo/Redo and refusal to
replace disabled, stale, Unicode-equivalent-but-different or composing text.
Injected delivery tests prove that correction runs bypass refinement, retain
their original pad ownership across focus changes, leave external speech
literal, and reject a late callback after Review cancels capture. The native
default-action and physical VoiceOver behavior still require manual acceptance.
The new files are in the generated project; repeated pinned generation keeps
its SHA-256 unchanged. Synthetic light/dark removal, replacement and stale
review renders are in `.build/issue-completion/voice-*.png`. These are view
renders, not evidence that physical recognition or sheet keyboard routing works.
The light/dark minimum-size (380 × 240) conflict fixtures also retain both
privacy/save warnings with Review and Keep Words reachable. Fixture validation
confirms that rendering leaves the external file and the local draft unchanged.

The #12 saved-audio extraction work passes the full **1,110-test** suite (1,464
executed parameter cases), zero failures/skips, in
`.build/IssueCompletionTests/Logs/Test/Test-Nook-2026.09.04_20-23-16-+1000.xcresult`.
The audio suite has 12 tests with 22 parameter cases. Synthetic separate-track
MOV inputs and decoded M4A samples verify every source frequency, both stereo
channels, increasing/decreasing track counts, headroom, offsets and part
boundaries. Video that actually outlasts audio verifies both final and resumed
silent tails. The earlier audio-only empty-tail fixture was invalid: passthrough
removed its empty tail. Replacing that fixture exposed the separate real export
gap, now fixed with a short silent PCM endpoint. Failure, cancellation, invalid
export, file alias, concurrent-change and cleanup-error tests retain the
appropriate source/destination evidence. This does not verify real speech,
source attribution, physical capture or installed-app permissions. No first-track
selection remains in the local extractor; the change is not merged or released.

The first #10 implementation slice passes **1,121 tests** (1,480 executed cases),
zero failures/skips, in
`.build/IssueCompletionTests/Logs/Test/Test-Nook-2026.09.04_20-37-54-+1000.xcresult`.
`SummaryQuestionsTests` adds 11 tests/16 cases for portable storage, legacy
headings, duplicate sections, bounded harvests, source/number filtering, explicit
recipe guidance, stale/Unicode edits, regeneration and merge failure retention.
Merge now carries typed failure provenance from the production summarizer rather
than relying only on matching fallback prose. NookSnapshot builds, new files are
in the generated project, and repeated pinned generation is unchanged.

Light/dark complete-note, narrow-note and 300-point recipe-control renders are
under `.build/issue-completion/summary-questions*.png` and
`summary-recipe-minimum-*.png`. The narrow control stacks its native picker and
Regenerate button rather than clipping them. Initial transparent standalone
renders were unusable and were replaced with the actual ambient background;
the final images were inspected. No physical keyboard/VoiceOver interaction or
actual model behavior is established by these renders and synthetic tests.
Evidence links, item correction and fallback presentation remain open in #10.

The subsequent item-review implementation derives exact references from the
saved transcript without a persisted evidence cache. The first scaffold did
not compile: a private generated schema was inaccessible to its macro, and the
repository deadline helper returns an optional nonthrowing result. Both were
corrected without a toolchain fence. `SummaryItemReviewTests` covers Unicode
ranges, source changes, long tails, contradictory retrieval, unsupported quotes
and quantities, negation/uncertainty, explicit Apply, action dates/completion,
failed saves, cancellation/deadline abandonment, stale revisions/content and
one-shot Undo. Incomplete live-caption warnings cannot be removed as claims.
Feedback/source edits invalidate prior proposals, and feedback is explicitly
transient rather than a durable instruction for future regeneration.

Synthetic `summary-item-review`, `summary-item-removal`, `summary-item-stale`
and `summary-item-empty` snapshot modes use an injected local generator and
verify that rendering does not save changes. These are not actual-model or
physical keyboard/VoiceOver acceptance. The native sheet keeps Back to Item as
the default action and Apply separate. The whole-summary fallback/Retry audit
and manual acceptance remain open; no issue is closed by this implementation.

Final item-review verification: **1,137 tests / 1,504 executed cases passed**,
zero failures/skips, in
`.build/IssueCompletionTests/Logs/Test/Test-Nook-2026.09.04_21-04-51-+1000.xcresult`.
The review suite adds 16 tests/24 cases. NookSnapshot builds and seven final
light/dark review, removal, stale, empty and full-note renders were inspected.
All new files are present in their generated targets; repeated pinned XcodeGen
keeps project hash `852117d653049cf4f4eb6cb35e38a1a498f01f6b6e4c117269c86ba5e7045638`.
The work remains uncommitted and unreleased.

The fallback/Retry follow-up adds `summary_origin` for transcript highlights,
partial extraction and edited fallback. Decode migrates exact known legacy
output without writing files or starting a model. The fallback card keeps its
label during progress and exposes Retry across saved-note tabs; empty results
describe what the write-up contains rather than claiming the conversation had
no actions. Failed merges retain older facts, decisions, actions and questions
and remain retryable as an append; successful merges clear stale pending state.
An empty transcript does not acquire an impossible Retry obligation. A newer
user summary retains its provenance when an optimistic generated-field merge
keeps that text. Item correction retains edited-fallback status and Undo restores
the original classification.

The Foundation Models availability probe on this Mac returned
`appleIntelligenceNotEnabled` on September 4. No setting was changed and no real
model generation was run. Enabling Apple Intelligence and completing actual-model
acceptance requires the user's involvement; this does not block the remaining
source-attribution implementation or code review work.

The earlier #12 file-boundary slice preceded the capture-side writer described
below. `RecordedSourceTranscription` requires one exact versioned
per-track QuickTime input marker, isolates every track (including unknown ones),
and preserves offsets and ordered-part duration when assembling results. It
never treats track order, stereo position or the recognizer's own result label
as source identity. Normal finishing and recovery pass their original capture
parts into this path; entirely unlabelled input retains mixed transcription.
Any failed track, invalid timing, changed file or cancellation rejects a partial
result. Temporary track audio is private and cleaned with reported failures.
Tests use real synthetic multi-track MOV files and injected recognition, not
actual microphones or Speech. The fixture needs explicit PCM reader output to
obtain per-sample timing; offsets may be represented as leading silence inside
a zero-start MOV time range, so its synthetic recognizer measures actual tone
onset. At this checkpoint the capture writer emitted no markers. The subsequent
auxiliary writer implements that boundary locally; legacy unlabelled files
still cannot establish source identity. See the public implementation plan on
#12 for the ownership, fallback and physical-acceptance constraints.

Source-file verification: the full suite passed **1,158 tests / 1,552 executed
cases**, zero failures/skips, in
`Test-Nook-2026.09.04_21-35-40-+1000.xcresult`. The new source suite contributes
10 tests / 21 cases, including real muxed audio, metadata ambiguity, offsets,
legacy fallback, changed-input rejection, cancellation, cleanup failure and
an injected-recognition recovery through persisted Markdown and idempotent retry.
`NookSnapshot` also builds. The new source is in both app and snapshot targets,
the new tests are in the test target, and repeated pinned XcodeGen generation
preserves project hash
`ad9899530c0f3ce61fc17bf22d62d3a7e771bf0bec57174b952c020ae8816000`.

The six final fallback renders generated at 21:19 were also inspected:
`detail-fallback-light`, `detail-fallback-dark`,
`detail-fallback-running-minimum-light`, `detail-fallback-extraction-dark`,
`fallback-card-minimum-light` and `fallback-card-minimum-dark` under
`.build/issue-completion`. The corrected empty-result wording is visible and
the 300-point card fits in both appearances. The narrow detail render is
560 points wide and 1,050 points tall; this is not minimum-window-height or
physical keyboard/VoiceOver acceptance. All work remains uncommitted/unmerged;
the current capture writer, real-source capture, on-device Speech/model behavior
and physical acceptance are not proven by these synthetic tests or images.

### Source capture writer checkpoint, September 4 at 22:19

`SourceAudioRecording` now writes separate explicitly tagged microphone/system
tracks from typed callbacks into per-part private `.sources` packages. The
original MP4 remains the fallback; only finalized companions with valid
file-identity receipts are selected for playback and source-aware transcription.
Sealing, cancellation, bounded buffering, resumed PCM trimming, repeated finish,
internal silent gaps and final tails have synthetic coverage. Pause now retains
the actual successful-removal receipt instead of guessing from the waiter error.
Recovery can use a complete companion without its original MP4. Partial packages
remain visible for Reveal/Delete, including failed cleanup. Artifact ownership,
retention and storage accounting include packages and preserve other recordings.
Privacy and technical documentation records the extra local audio copy and its
limits. This is still uncommitted/unmerged work, not a release announcement.

The expanded writer tests initially failed two tone-amplitude assertions. A
diagnostic run measured 0.28278 and 0.28310 for the internal-gap tones, 0.28258
for the resumed tone, and zero in the expected silent windows. These are
consistent with 0.4-amplitude mono input distributed over two stereo channels,
not missing or shifted sound. The assertions now check both channels against
0.4 / sqrt(2) for mono input and 0.4 for stereo, with AAC tolerance. Both input
layouts are covered; the timeline and silence assertions remain. Diagnostic
forced failures were removed. No production gain change was made to satisfy
an invalid single-channel threshold.

The focused writer suite passed **10 tests / 20 cases** in
`Test-Nook-2026.09.04_22-16-20-+1000.xcresult`. The subsequent full suite passed
**1,170 tests / 1,575 cases**, zero failures/skips, in
`Test-Nook-2026.09.04_22-18-16-+1000.xcresult`. `NookSnapshot` builds, source/test
membership is present, and repeated pinned generation preserves project hash
`b0fcbab1fa94d6d62ac26d71e332516a464d8857b67e959e1c897eee4011dafb`.
`git diff --check` passes. The earlier failed full-suite result remains historical,
not the latest outcome.

Remaining: review and merge; real two-input capture, silence, pause/resume/stop,
failed finalization and recovery/deletion; long-capture resource use and quality;
actual on-device Speech/model behavior; physical keyboard/VoiceOver and other
issue-specific acceptance. Synthetic callbacks do not prove SDK delivery
completeness or physical capture boundaries.

### Source recording review follow-up, September 4 at 22:29

Review found that encoder completion alone authorized a companion receipt.
The writer now reopens the finished asset and checks total duration, exact
source markers, valid track ranges and each source's expected final timestamp.
A full-length system track cannot conceal a shortened microphone track. The
audio identity is captured before asynchronous validation and rechecked before
publication. The cancellation gate prevents delayed validation from publishing
after cancellation or recreating a package removed during cleanup. Tests cover
wrong duration/source sets, corrupt files, a short secondary track, validation
failure, external replacement, cancellation and cleanup while validation waits.
These are container/ownership checks, not proof of audible captured content.

Review also found that recovery could transcribe valid source companions while
reusing an older cached M4A for retained playback, then delete the complete
sources. Companion-backed recovery now re-exports playback even when a cached
mix exists. A synthetic first-part cache plus later resumed part verifies the
new full playback and transcript timeline. Injected re-export failure verifies
that cached bytes and all originals/companions remain, with no note saved.
Legacy recovery without a source companion retains its existing cache behavior.

The combined source-writer/recovery suites passed **47 tests / 75 cases** in
`Test-Nook-2026.09.04_22-27-57-+1000.xcresult`. The final full suite passed
**1,174 tests / 1,588 cases**, zero failures/skips, in
`Test-Nook-2026.09.04_22-28-45-+1000.xcresult`. The generated project is unchanged
from the previous checkpoint. No real audio, model or physical acceptance is
claimed; review and delivery remain open.

## Historical release 1.20.0 candidate evidence

Version 1.20.0, build 36 includes the accumulated review corrections and the
Library/editor work proposed in [issue 15](https://github.com/wrnsnng/nook/issues/15).
The [release acceptance record](RELEASE_1.20.0_ACCEPTANCE.md) tracks packaging,
signing and the remaining hands-on gates. The default contributor identity and
disabled updater are unchanged.

The final September 1 integration passes **1,040 tests**, with zero failures/skips,
two Python tests, and snapshot/optimized builds with warnings treated as errors.
All 145 source/project fingerprints are unchanged across the run. The record is
`.build/performance-review/library-editing-20260901/integration/attempt-05/build-acceptance.json`.

Saving publishes one sorted Library snapshot. Recovery-status observation is
confined to its sidebar section. The editor explicitly creates its native text
engine once; it preserves marked text during unrelated redraws and carries
exact Unicode replacements across the SwiftUI/native boundary. The focused
editor suite has 18 declarations and 30 parameter cases, including complete
accessibility character counts and offscreen text access after scroll/resize.
Simulated Japanese, Chinese and Korean composition is not physical IME or
VoiceOver acceptance.

New recording/recovery tests preserve exact Unicode edits, refuse a same-ID
note restored during recovery, and check both recordings around delayed append
work. Failed audio placement retains the session capture and extracted audio.
These checks narrow stale-work races; they are not filesystem transactions.

Native Release candidates preserve both 20,000-word fixtures and their exact
32-character edits through Save, Undo and Redo. All 1,001 original files remain
unchanged. Native dead-key composition and middle-word selection replacement
also preserve surrounding multilingual text. Both isolated apps quit normally.
The capture uses the 1,033-test production sources; the only change in the final
1,034-test source is the additional accessibility regression test. The subsequent
1,040-test candidate suppresses unchanged action-list, empty-search and absent
prep publications. Six new tests preserve exact revision updates, independent
Reminders receipt/error changes and cancellation. No grouping-cache or row-model
architecture change is included.

The final native checks use the exact 1,040-test production sources. All saved
bodies and original file hashes remain exact through Undo/Redo. Two SwiftUI
recorders failed during trace finalization while Nook remained running and its
save checks passed; those traces are excluded. A separate matching Time Profiler
pair per shape completed successfully, with the same 460 × 364 window and
1,002-note library. Records are under
`.build/performance-review/library-list-final-20260901/`. An initial CPU baseline
with a second pad created on relaunch is also excluded; that synthetic pad was
preserved outside the fixture library before both accepted baseline recordings.
The final comparison reduces main-thread CPU in the same four seconds after
input from 481 to 424 ms for 200 paragraphs and from 484 to 432 ms for one
paragraph, with about 11% less List traversal in both. Typing and broad SwiftUI
layout costs are largely unchanged. This is one accepted pair per shape, with
the final candidate captured first; it does not prove the earlier 257 ms pause
is fixed. See `accepted-cpu-comparison.md` in the final capture directory.

## Earlier draft-recovery and Library evidence

[Issue #14](https://github.com/wrnsnng/nook/issues/14) records the proposal in
[`proposals/DRAFT_RECOVERY.md`](proposals/DRAFT_RECOVERY.md). The local
implementation adds a shared `DraftJournal`, injected into the three draft
controllers by `AppModel`, plus a separate `DraftRecoveryController` and
Library preview. Recovered records never populate live autosaving editors.

The August 31 predecessor reports **1,015 passing tests** in
Xcode's test summary, zero failures/skips, and two passing Python tests, with
warnings treated as errors. The latest record is
`.build/performance-review/design-integration-20260831/library-identity/attempt-01/build-acceptance.json`;
all 145 source/project fingerprints remained unchanged. Snapshot and optimized
builds also pass with warnings as errors. Six new tests cover captured Library
identity through initialization, saving/renaming, nil and optional/inout/key-path
assignments, copied values, Foundation/Unicode paths, equality/hash semantics
and filesystem changes. The original URL remains authoritative for file
operations; normalized identity is refreshed at every address assignment,
including warm decode-cache reloads. No save-revision guard changed.

Five interleaved optimized component trials measure 1,000 FileManager-URL
identity reads at 3.623 to 0.085 ms median. Normalization moves to construction
or address assignment, about 3.6 ms per 1,000 notes; the note value stride grows
by 32 bytes plus retained path storage. All 2,002 URL-source/identity cases agree
and all 1,001 synthetic files remain exact. This component result does not
establish native input latency. The subsequent **1,009/1,015 Release native
comparison** completed after unlock, with the same 20,000-word/200-paragraph
pad, 460-point window and 32-character insertion. Main-thread URL normalization
samples fall from 157.6 to 0.7 ms, and the detected Library microhang falls from
311.908 to 253.474 ms. Equal four-second post-input main work falls from 877.7
to 704.3 ms; sampled typing work is essentially unchanged. A substantial
Library/list/layout pause remains. This fresh Release pair does not use the
older Debug `-O` 334 ms interval as its baseline.

Both target-only traces fully cover the input and subsequent SwiftUI updates;
both recorders exit before inspection. Exact saved bodies and all original
1,001 files match, and cached-build native Undo/Redo preserves exact text and
Saved status. Both fixture apps quit normally. See
`.build/performance-review/library-layout-20260831/native-comparison.json`,
`native-comparison.md` and independent `library-attribution.md`; the initial
locked attempt remains recorded separately. This is one instrumented pair,
not per-key, minimum-hardware, energy or memory acceptance. That comparison
leaves the production text engine unchanged and does not retest its separate
long-paragraph stall. The September 1 candidate above supersedes that scope.

The preceding 1,009 batch adds five data tests and one parameterized
native-layout test. Unchanged personal-note saves verify the
existing file without re-encoding it, and recovery completion keeps its actual
revision. Conflicts, missing/replaced files and exact Unicode edits remain
protected. Shared notice presentation reserves space while keeping the same
native editor, text, selection and first responder at 340pt and 595pt widths.
Earlier numeric-grounding tests cover faithful dates/ranges/clause merges,
currency codes and exact regeneration retention; all thirteen failure cases
verify retained-note wording. Earlier work adds shared Reminders export
arbitration, cancellation/retry and stale-source validation; a UUID prefilter
before full file-identity comparison; and summary failure provenance through
salvage and finalization. A failed regeneration retains every existing field.
Synthetic permission/model boundaries do not establish real EventKit or model
behavior. Reminders arbitration is process-local, with a remaining crash gap
between EventKit save and receipt persistence.

The preceding 969 batch's regeneration/merge/recording ownership regressions and
two light/dark summary-progress renders retain their recorded scope. Repeated
merge protection is window-lifetime state, not a cross-window/restart receipt;
final filesystem checks are not transactions against external writers.

The unlocked Mac allowed a scoped **969 native replay**: immediate palette-to-Ask
input and exact selection return, recorder window cancellation/arbitration,
custom shortcut handoff with defaults restored, duplicate filing-target exclusion,
and saved pad retention through Review Copies/re-raise. No filing target or
Trash action was invoked. Actual on-device regeneration exposed fallback content
incorrectly reported as success; that baseline led to the 990 provenance fix.
A second 969 attempt exercised Cancel and kept the exact source unchanged after
99.52 seconds. Receipts are under
`.build/performance-review/native-replay-34c5d990/`.

The later **990 native replay** under
`.build/performance-review/native-final-f5adc5a9/` passes scoped Keyboard
Navigation checks: Ask typing, Tab/Shift-Tab, example activation, Cancel and exact
selection return; fresh-editor Tab/Undo; storage entry, ten-control traversal,
skipping unavailable buttons, visible scrolled focus, Refresh and Escape/Return
with focus restored to the opener. The note's post-regeneration bytes remained
unchanged through these keyboard checks. An initial inherited Undo-prefix
observation was not reproduced in a fresh editor and remains unattributed.

Keyboard Navigation and VoiceOver were temporarily enabled with approval and
both restored to their original off state. Full Keyboard Access was observed off
and not changed. Automation did not establish VoiceOver cursor movement or spoken
feedback; the complete screen-reader gate remains open. macOS still reports no
microphone. No capture, Finder action, deletion or real Reminders export occurred.

Native regeneration on 990 completed as a reported success, so it did not replay
the fallback-provenance failure. It instead exposed invented numerical claims:
agenda indices became participant counts and a meeting duration. That failure's
original and generated notes are preserved. The validated numeric safeguard
checks digit-bearing literals and nearby spoken context before accepting a
summary/title, and filters unsupported list quantities. This is not semantic
proof: written-out inventions and same-word meaning changes remain possible,
and legitimate paraphrases or metadata-derived quantities can fall back.

A fresh **1,002 native run** under
`.build/performance-review/native-grounding-2754acc3/` rejected an ungrounded
result and kept all existing note content. The exact file comparison found one
removed terminal newline at an unestablished stage, so this is not an exact-byte
native pass. Raw generated output was not captured; the specific numeric branch
cannot be attributed from that run alone. Deterministic tests exercise the
recorded bad numeric output. The notice incorrectly said only the transcript
remained; the 1,003 copy correction states the existing note is unchanged.
That attempt's native replay and canonical-file retry were blocked when the Mac relocked.
Both system settings had already been restored. The captured notice partly
overlays the title. The 1,009 follow-up below addresses those concrete findings.

The follow-up reproduced the newline loss through a whitespace-only personal
draft save: all three terminal-linebreak variants failed before the correction.
The precise UI event that dirtied the historical draft remains unproven. On the
**1,009 native app**, a deliberate trailing Return followed by regeneration
settles My notes without changing any of the original 11,719 file bytes. Cancel
was activated during the first progress stage, and the source still matched
exactly 257.10 seconds later, including its final newline. Two earlier attempts
completed successfully before cancellation; they are retained separately and
are not counted as cancelled/retained-byte passes. Actual title-validation error
and Dismiss checks keep the title visible and preserve the selected word in My
notes. Receipt:
`.build/performance-review/native-notice-b9d4aaf2/native-1009-notice-newline.json`.

A separate 560 × 420 native dark fixture verifies long-to-short-to-long notices,
the corrected retained-summary copy, visible heading/editor, reachable Dismiss
and selection retention. It uses the production components with synthetic
messages, not a real model refusal. Receipt:
`.build/performance-review/notice-layout-2dd2441a/native-1009-notice-layout.json`.
Six offscreen light/dark notice/detail renders pass their layout scopes. Two
additional Library renders have blank offscreen sidebars and are excluded from
sidebar acceptance; the real native sidebar and toolbar were visible. No system
settings or privacy permissions changed, and both newly created native fixtures
exited through normal Quit. Simultaneous Library/detail notices at minimum
window height and VoiceOver announcement behavior remain unverified.

Remaining physical display, real capture/dictation, full
accessibility and installed-update acceptance are separate gates. Earlier 934
filing-warning renders keep their original scope under
`keyboard-handoff/attempt-04/`.

The preceding 913 batch includes assistant availability, active/stopping
disclosures, bounded normal-quit cleanup and a final draft recheck. Its ten
offscreen assistant/conflict renders pass their named scopes. Native 913 Settings
checks pass in light/dark at 620 × 628, including the real header, provider
chooser and persistent-default footer; immediate palette query/safe Return also
passes. No provider, active-CLI quit, VoiceOver or real OS preference was tested.
Earlier panel/recovery and transcript captures retain their recorded versions.

The uninstrumented 902-build palette receipt passes 14 checks, including editor
selection, exact dirty Markdown retention, guarded dispatch, alert exclusion,
Cancel, exact Undo and many/empty/one-result navigation. Settled short and
single-result layouts pass; first-painted-frame appearance remains unverified.
The earlier 901-build transcript replay retains its scoped growth/history/Jump,
native bottom, paused reopen, short-content and reset passes. Quick Note and
notice receipts retain their exact warning/Discard-eligibility and replacement
scroll checks; no real Discard/Trash action was performed. Temporary probes are
removed. AttributeGraph cycles remain unattributed. These results do not
establish full accessibility, capture or release readiness.

Basic storage acceptance passed in light/dark. Native checks on the earlier
870-test binary verify palette child names, Quick Note cold-open/re-raise typing,
silent-audio playback with no search matches, Stop/tab-departure behavior, and a
real detail failure remaining visible for 25.81 seconds until Dismiss without
changing the original file. Ten static layout fixtures passed. These are scoped
results, not complete accessibility or real-capture acceptance; see the
[design acceptance ledger](DESIGN_ACCEPTANCE_2026-08-31.md).
Project generation uses pinned XcodeGen 2.45.4; this implementation remains
uncommitted and unreleased. These results include the subsequent suggestion/search,
CLI, save-boundary, storage and multilingual grounding changes; see the
[current verification status](REVIEW_FOLLOWUP_2026-08-31.md#verification-and-what-remains).

The journal coalesces writes on one serial worker, keeps immutable original
owners/baselines, and invalidates obsolete writes and cleanup retries. Limits
are 16 MiB per encoded checkpoint, 64 MiB per scan/pending batch, and 1,024
entries per scan. Rejected records remain on disk with a visible issue. New
recovered notes are published exclusively with fresh UUIDs; completion intents
and exact read-back distinguish successful saves from interrupted cleanup.
Read-back, editor changes, and asynchronous recovery guards compare exact UTF-8
text, including canonically equivalent Unicode. Source edits preserve note
UUIDs; store mutations distinguish copied files by path. Explicit managed file
rename saves personal edits before moving and rebinds both clean editors to
the resulting file. External renames never redirect an unfinished draft.
Libraries containing duplicate UUIDs now retain distinct file-specific sidebar,
search, and command-palette identities. UUID-only links open a chooser, and
conflicting files open a bounded read-only source preview with native Finder
and refresh controls. Existing unsaved Markdown remains reviewable there.
Editing, recording into a copy, merging, and UUID-based action mutations are
refused while ownership is ambiguous. Ask, Prep and Digest omit conflicting
groups with an explanation, including copies outside a digest's date window.
No UUIDs or source files are automatically rewritten. Move other copies out
of the notes folder to continue using the selected original.

Decode and search caches now validate exact content revisions and file paths,
so a preserved modification time cannot hide changed content. Palette refreshes
keep the highlighted file; if it disappears, Return does nothing until a new
selection is made. Appended recordings retain their destination path through
permission restarts and asynchronous processing. Restart intent waits for the
library load before consuming local preferences, and audio replacement checks
that the destination still has one owner. A same-path, same-UUID external edit
that has already been reloaded remains valid current content; unseen edits are
protected by the store's revision checks.

A local synthetic measurement submitted 500 edits to a 1.08 MB source with a
1.08 MB baseline in approximately 15 ms total and flushed the last checkpoint
in approximately 12 ms. This measures coalescing overhead, not typing/rendering
latency under realistic use. Regression tests cover restart, exact text,
conflicts, folder changes, failures, delayed writes, invalid source, and
private-file handling. Light/dark preview snapshots are available through
`NookSnapshot` modes `draft-recovery-light` and `draft-recovery-dark`.

Additional acceptance on macOS 26.6.2 exercised the actual journal in separate
synthetic processes: 12 cases across all three editor kinds, with 15 owned
processes terminated using SIGKILL. Completed checkpoints and completion
intents survived exactly; an interrupted replacement preserved the prior
complete checkpoint and exposed its temporary file as an issue; resolved
records did not return. All synthetic original file digests were unchanged.
This is a journal harness, not a power-loss test. Full-app coverage is described
below.

Synthetic APFS and HFS+ disk images passed exact file creation, refusal to
replace an existing destination, private modes, and normal temporary-file
cleanup. On a writable ExFAT image, creation and fsync succeeded but
`renameatx_np(..., RENAME_EXCL)` returned `ENOTSUP`. Recovery creation/export
therefore refuses ExFAT destinations and keeps the checkpoint. Real external
hardware, unplugging, network filesystems, and power loss remain unverified.

The interactive synthetic recovery fixture rendered the production sidebar
and sheet correctly inside NavigationSplitView. Return cancelled the discard
alert; Escape closed the preview without removing its record; the native
export panel cancelled without creating a file. Save as New Note created one
new Markdown file with a new UUID and otherwise identical source, retained all
three original fixture hashes, and removed only its completed recovery record.
Expanding the remaining draft list also worked. Small-window snapshots at
590 × 580 and long/invalid/stale source fixtures retained every footer action
in light and dark appearances. A live long-source preview reached the end of
its bounded 100 KB preview with all actions still visible. The accessibility
tree identified the scroll region as read-only. Headless bitmap capture of the
same split-view sidebar can be blank on this macOS version; that is not proof
that the live sidebar is empty. The fixture uses temporary storage before
initializing the store and cannot start capture or invoke an assistant.

A separate full Nook debug app, with a unique acceptance bundle identifier,
synthetic notes and capture/calendar/dictation/provider settings disabled,
also passed an actual Markdown editor force-quit/relaunch check. Cancel Quit
retained the edit, its completed checkpoint matched exact UTF-8, and SIGKILL
followed by relaunch exposed the record without changing any original file.
Save as New Note wrote identical source except for a fresh UUID and removed
only the completed checkpoint. Normal Save and Quit wrote the exact intended
file, left sibling copies unchanged, exited, and cleared the journal. Copied
UUID rows opened their own source, search returned only the matching copy,
and recording/merge controls were disabled. This does not exercise real capture,
permission prompts, provider actions, or installed updates.

The final app also reloaded and searched an externally edited synthetic note
whose nanosecond modification timestamp was preserved. Save and Quit refused
a same-timestamp source conflict, kept the app open, and retained both the
external file and the exact unfinished checkpoint. When a duplicate appeared
during that edit, the detail pane exposed the retained draft separately from
the current disk source; both files remained unchanged. The Open actions
warning wraps within the sidebar, and the duplicate review keeps its refresh
and Finder actions visible in a pinned footer.

Separate full-app force-quit/relaunch checks now also passed for My notes and
Quick Note. Both had exact completed checkpoints before termination and recovered
as new notes with fresh UUIDs, retaining their exact text and clearing only their
completed checkpoints. My notes preserved decomposed Unicode and all 1,001
original fixture files; Quick Note preserved its conflicting external source.
This closes basic full-app restart acceptance for all three editors, not the
full interruption matrix or every last keystroke.

Before release, interrupt normal save, recovered save, folder switch, and cleanup
in the complete app. Check
VoiceOver, full Tab navigation and visible focus, contrast, and small-window
presentation. Return and Escape were exercised in recovery and storage sheets,
but Tab did not move focus on this Mac. A subsequent read-only AppKit check
reported full keyboard access disabled; no system accessibility settings were
changed. This observation does not constitute full keyboard acceptance. Test
sustained dictation and large-document rendering; confirm the final completed
checkpoint is available without claiming that every last keystroke or a power
failure is protected.
Private files are not a security boundary against another process running as
the same user. Cocoa's Trash API still takes a pathname after the journal's
final inode check. Abrupt termination can also leave hidden staging files in
an export/new-note destination; see the privacy document for locations.

## Measured performance and library interaction follow-up

The [31 August review](REVIEW_FOLLOWUP_2026-08-31.md) records current findings
across performance, security, data handling and interface quality, plus six
prioritized feature proposals. It supersedes the earlier review's test totals
and open-work assumptions without erasing that historical analysis.

Two behavior-preserving decoder changes reduced a synthetic 1,000-note cold
load from 6.295 s to 3.011 s on an M4 Pro. The fixture has 120,000 input
transcript segments and 27.4 MB of Markdown; cold means no application decode
cache, with OS file caching left intact. Warm loads stayed about 57–58 ms.
Golden vectors retain the prior transcript UUID bytes, and merge boundary tests
retain text, source and ordering behavior. Same-timestamp external changes
still invalidate the decode and search caches. Cached text matching remains
about 361 ms for this fixture and was not changed.

A separate input-only trace of a 20,000-word Quick Note identified seven
700–728 ms SwiftUI body updates dominated by repeated word counting. The
controller now calculates the count on text changes and reuses it in rendering.
The completed paired trace uses the same single-paragraph pad and four-word
insertion, with no accessibility snapshots during input. The seven after body
updates have a 0.612 ms median and 20.749 ms maximum, down from 705.778 ms and
727.758 ms; updates above 100 ms fell from seven to zero. The final 20,004-word
text saved exactly.

A 2.291-second Severe Hang remained after that first change, involving word
counting, exact comparisons and native layout. Counting now runs on a single
detached consumer with at most one active and one replaceable pending snapshot.
Only the current text revision publishes a count. Pending counts require
discard confirmation, clearing immediately resets the total, and statistics
never delay checkpointing or saving. Regression tests cover stale Unicode
revisions, burst coalescing, pending discard confirmation, failed deletion and
saving while counting is suspended. The worker cancels when its controller is
released. Superseding an edit does not cancel an active count; queued snapshots
coalesce. This bounds snapshot count, not bytes or peak memory.

Prepared input-only captures verified exact 20,004-word saved text. Counting
appears on background threads, with main-thread `text.didSet` sampled weight
falling from 949.7 ms to 154.5 ms. The largest detector interval fell to 1.258 s.
The new SwiftUI export classifies Quick Note activity as Other Updates, with no
matching actual Body rows; do not compare those durations with the earlier
body table or treat missing rows as zero work.

The same words arranged into 200 paragraphs reduced native
`NSTextStorage.endEditing` sampled weight from 850.7 ms to 12.4 ms, but a
614.8 ms detector interval remained. In those async-only traces, exact comparisons
still cost hundreds of sampled milliseconds, and task-suggestion scanning
contributed 381.5 ms. These
inclusive weights overlap and cannot be added. Investigate native layout and
suggestion matching without silently reformatting text or changing text engines.

The latest editor change converts AppKit text snapshots to contiguous UTF-8
once at the binding boundary. Headless AppKit tests retain exact bytes, editor
selection and earlier snapshots after subsequent storage replacement. A
separate optimized storage probe supports reduced repeated bridging costs;
the report records conversion overhead as well as reuse benefits. The final
app comparison is complete. Main-thread `text.didSet` sampled weight fell from
154.5 to 9.5 ms for one paragraph and 157.7 to 9.3 ms for 200 paragraphs; exact
comparison weight fell from 306.3/346.4 to 36.1/36.4 ms. The eight same-category
Quick Note DynamicBody Other Updates in each trace now peak at 0.800/0.985 ms,
versus 19.834/20.690 ms with background counting alone. Conversion itself costs
75.0/75.5 ms of inclusive main-thread samples across the inputs.

The final largest detector intervals are 1,051.841 ms for one paragraph and
362.813 ms for 200 paragraphs. Native single-paragraph layout remains substantial
at 833.7 ms of `NSTextStorage.endEditing` samples. Task-suggestion scanning still
contributes 349.2 ms in the 200-paragraph trace, with two updates around 179 and
170 ms. These inclusive weights overlap. Exact text saved in both captures;
live Undo/Redo also preserved the original paragraphs and restored the exact
insertion and Saved state. Single instrumented runs do not measure end-to-end
input latency or establish smooth editing on shipping builds or minimum hardware.

The accepted captures ran without concurrent builds, benchmarks or analysis jobs.
For the final single-paragraph capture, inspection began while the recorder
process was finalizing; no inspection/reset contamination was detected in the
measured tables. Samples are not an exhaustive event log.
The locked capture and a potentially contended repeat are explicitly excluded.
Sanitized results and raw local evidence remain under the ignored
`.build/performance-review` directory. The isolated app used a unique bundle
identity with capture, calendar, dictation, providers and updates disabled. The
profile apps are closed and both fixtures' preferences/support state are
archived outside active app paths. No real notes or normal app identities or
permissions were changed. The original cached-count and asynchronous-count
binaries/fingerprints remain separate from the latest editor-snapshot build.

In the full-app synthetic check, Cancel during an All-to-Today change kept the
old range, selected file and exact unfinished source. Save wrote the exact
draft before switching to a visible Today note. An external conflict preserved
both versions, kept All selected and showed the refusal; resolving the
synthetic external conflict allowed the retained draft to save. Show All Notes
kept the query and found its Yesterday match. The final compact sidebar hint
no longer obscured Open actions or suggested a spelling problem. The Markdown
editor exposed its name and Save/Revert hint in the accessibility tree.

The initial loading placeholder and automatic reload/phase leave decisions
have deterministic regression coverage. Full VoiceOver/keyboard acceptance and
native progress announcements remain separate manual checks. Three long
transcript microhangs in the earlier trace were dominated by accessibility
hierarchy inspection; they are not evidence of normal scrolling pauses.

The next completed full-app comparison covers background task suggestions.
Named count and suggestion computations appear only on background threads;
the two expensive input-period suggestion updates in the 200-paragraph case
are absent. A later 334 ms microhang remains in library identity/list/layout.
The one-paragraph case still has a 1.063-second native layout/selection hang.
Its typing starts late, and CPU sampling ends before the last SwiftUI update,
so total CPU and detector-count differences cannot support a whole-session
improvement claim. Both new recorders exited before accessibility inspection.
Exact saved text passed for both shapes, and Undo/Redo passed for 200 paragraphs.
The separate native editor experiment and component parser/search benchmarks
are recorded in [the follow-up report](REVIEW_FOLLOWUP_2026-08-31.md#performance).
Those August 31 experiments did not change the production text engine. The
September 1 candidate above integrates the subsequent editor work. Full-app
search latency, minimum-Mac performance, sustained real capture, memory and
energy remain open.

## Current design acceptance

The command-palette overlay left the My notes editor focused. A synthetic
query was inserted into the note while the palette field stayed empty; Undo
restored the original and its file hash remained unchanged. The implementation
now uses a native sheet, initially focuses its search field, provides Close and
Escape, and dispatches other commands after dismissal; Ask now reuses the sheet.
Actual shortcut
bindings drive its hints. Native checks on the 849-test binary now verify that
queries stay in the palette; Escape restores the My notes caret, and Close
restores its selected text. Raw Markdown and sidebar-search selection also
return, native Undo restores the original text, and the source-file hash remains
unchanged. Arrow selection and Ask final focus were observed. The receipt is
`.build/performance-review/design-ui-80331fe5/palette-native-849-acceptance.json`.
That run found two failures: Quick Note opened without editor focus, and the
palette's outer accessibility label replaced query and Close names. Both were
corrected and verified on the 870-test binary in
`.build/performance-review/design-ui-80331fe5/native-870-acceptance.json`.
Cold-opening and re-raising Quick Note accept immediate typing and retain text;
Redo restores the exact combined typing group and the note eventually saves.
Native Undo coalesced both typing episodes into one group. A stale empty-note
warning briefly appeared after Redo. The 875-test native rerun in
`.build/performance-review/design-ui-80331fe5/quick-validation-875-acceptance.json`
establishes cold focus, exact saved text, the empty warning, exact Redo, and
warning clearance before Saved. It also found that an empty saved pad instructs
the person to choose Discard while that control is disabled. The correction is
now covered by six new tests using fake confirmation/deletion and by
`.build/performance-review/design-ui-80331fe5/quick-discard-881-acceptance.json`.
The native check verifies a new empty pad keeps Discard disabled; saved text is
exact; Undo to empty shows the warning with Discard enabled; and Redo restores
exact text and clears the warning before Saved. Original fixture hashes stay
unchanged. No Discard was clicked and no real Trash action was exercised.
Toolbar-origin, backdrop, additional shortcut variants, live data refresh and parent
teardown variants, complete keyboard traversal and actual VoiceOver remain open.
A1 is partial, not a complete palette pass.

The native window presenter establishes the sheet boundary in the shortcut
action. Its uninstrumented 901-build receipt verifies cold/warm immediate
Cmd-K then `discard` without a readiness wait. The later uninstrumented 902
receipt, `.build/performance-review/design-ui-80331fe5/a1-902-acceptance.json`,
passes 14 checks: My notes selection and exact dirty Markdown/selection survive
palette dismissal; dispatch opens Save/Discard/Cancel; Cmd-K while that alert
is open is not queued; Cancel retains the draft; Undo restores the exact
11,705-character original and disables Save/Revert. Many results can become
empty, where Return does nothing, then one safe note, where Return navigates.
The original file hash stays unchanged. Settled short and single-result layouts
were visually inspected at 560 × 121; first-painted-frame appearance remains
unverified. Ledger E21/E25 preserves the earlier and current scopes.
AttributeGraph cycles remain unattributed; an aborted debugger attachment
produced no backtrace. Physical backdrop, toolbar-origin focus, additional shortcuts,
live data refresh, parent teardown and full keyboard/VoiceOver remain open.

Additional 902 checks retain their arrows/search-selection and direct/settled
Ask passes (E28). A later native 913 baseline reproduces empty immediate Ask
input and a changed parent selection, while the toolbar control passes. The
new source replaces palette content with Ask inside its existing native sheet;
a deterministic actual-hosting-view test verifies immediate input ownership.
The same 913 baseline reproduces a Settings recorder swallowing Library search
typing after a mouse window switch. Recording now belongs to its exact host,
cancels on key loss/deactivation/close/detach, and allows one recorder per window.
Cancellation clears held modifiers and stale rejection text. The later isolated
969 replay passes immediate palette-to-Ask typing and exact selection return,
recorder window switching, same-window arbitration, Escape, and a customized
Shift-Cmd-K handoff. Default shortcuts were restored. Full-Library refresh, real
parent teardown, VoiceOver and physical modifier-only acceptance remain open.

The 913 filing baseline exposes two identically named duplicate targets in AX;
neither was clicked, and the screenshot omitted the popover. New source filters
ambiguous targets, guards stale choices, and keeps a persistent warning if filing
succeeds but removing the quick-note copy fails. The next draft is fresh, so it
cannot accidentally repeat the filing. Tests use synthetic files/fake deletion.
Two offscreen 380 × 240 light/dark renders verify the complete retained-copy
warning, Review in Library, Dismiss, empty next-draft editor, provider control
and Done fit. Before/after validators preserve the exact copy and append once.
This does not prove the real pad stays open or its actions work after filing.
The 969 native replay excludes copied UUIDs from the filing choices, retains the
independent target and warning, and preserves saved pad text after Review Copies
and re-raise. No filing target or Trash action was invoked. The menu screenshot
omitted the popover, so this is AX/interaction evidence, not its visual layout.
See ledger E29–E34.

Earlier locked attempts were followed by successful native checks. A separate
fixture launch problem came from missing `Nook.debug.dylib`; copying all matching
executable components and re-signing restored access for those checks. This was test
fixture packaging, not a production Nook defect. Conflict/failure-notice,
playback and transcript follow-state changes are now integrated. Ten static
fixtures verify wrapped Markdown conflicts at 900 × 580, normal and bounded
long failures with visible Dismiss, no-match transcript transport, and narrow
Quick Note conflicts in light/dark, including the Codex warning. Native playback
checks used generated digital silence: Stop remains available with no matches,
the clock advances, and leaving Transcript stops playback. They do not establish
audio quality, microphone/system capture or VoiceOver.

An actual detail error persisted for 25.81 seconds, Dismiss removed it, and its
original file stayed exact. Separate light/dark notice fixtures verify long/short
reflow, scrolling to the final instruction and reachable Dismiss. Repeating a
long result initially retained the previous bottom position despite a new UUID.
The host-identity correction passed a separate 875-test integration. In the
dark 560 × 300 native fixture, the prior notice was at the end and a fresh
identical notice started at the top; Dismiss stayed reachable and cleared it.
The receipt is `.build/performance-review/notice-ui-7a95b865/identity-acceptance.json`.
This closes that recorded replacement-scroll failure, not all notice or
accessibility acceptance.

The final uninstrumented 901-build replay at 900 × 650 uses production
`LiveMeetingView` with synthetic updates only. Light appearance passes growth to
61 passages, focused-passage Page Up, stable history through Append/Partial to
62, Jump return, native scrollbar-bottom reattachment, paused hide/reopen at the
same revision, shrink to one visible passage, and reset to 60 without a false
Jump. Dark appearance passes direct 60-to-one visibility. Four final screenshots
were immediately archived and inspected, including paired history positions.
The receipt is `.build/performance-review/live-follow-ui-6494a046/interaction-final-acceptance.json`.
The eager outer stack and measured visible rectangle replace the failed clamp
approach; baselines remain in ledger E17–E20. Physical momentum, resize/compact,
full navigation, VoiceOver, capture and latency acceptance remain open. The
three fixtures from that 901-build run were quit; no release or commit was made.

Ask keeps its submitted question attached to progress, refusal and answer while
the input remains editable. Cancellation invalidates a request before canceling
its task, including external dismissal; tests reject late noncooperative results.
Folder changes dismiss Ask and the palette and invalidate old callbacks, and
opening refuses notes that still belong to another folder. Synthetic light/dark
answer and refusal snapshots retain the correct original question. A long
progress question initially hid Cancel; it now scrolls, with Cancel visible in
the 560 × 380 fixture in both appearances. These fixtures never invoke a model.

Custom prominent-button text now uses dark ink against the light blue dark-mode
fill. Resolved-color tests pass the 4.5:1 text threshold for enabled idle/pressed
states across both normal and high-contrast AppKit appearances and tested
surfaces. Reduced-motion policy suppresses custom press/status scaling and
Quick Note reflow animation; Increased Contrast strengthens custom outlines and
dividers. The 902-build panel refinement also suppresses compact/hidden press
scaling and animation under Reduce Motion while preserving fill/opacity feedback.
Flag acknowledgment changes its glyph to a checkmark, and the hidden paused
indicator uses a pause glyph instead of relying on color. Six offscreen renders
verify unchanged panel footprint plus light/dark recovery at 360 × 580: two
fully wrapping filenames, filename-specific Finder names, primary title text
and reachable controls. The receipt is
`.build/performance-review/design-integration-20260831/panel-accessibility/foreground/visual-acceptance.json`.
These never-key-window fixtures and policy tests do not establish real pressed
states, preference changes, physical display placement or VoiceOver.
The Mac's read-only accessibility getters reported VoiceOver, Reduce Motion,
Reduce Transparency and Increased Contrast off. Full acceptance with those
settings, remaining narrow-window/error variants, and physical display geometry
remains outstanding. No private accessibility overrides or system-setting changes were
used to claim completion.

Assistant availability now uses shared predicates and rejects stale discovery
results. An unavailable local engine remains an explicit choice state, even if
an external provider was previously approved. The captured running provider owns
its warning through stopping; late output is rejected and a new action waits
for cleanup, while editing/saving remain available. Ordinary Quit requests
cleanup and stays open with an explanation after five seconds if it has not
returned. Drafts are checked again after asynchronous cleanup/finalization, and
both quit gates reset if quitting is cancelled. Regressions cover these paths;
active-provider native Quit and final-save alerts remain unverified. Ten static
renders cover unavailable/running/stopping and conflict states; animated spinners
and the offscreen Settings header are excluded. Native Settings separately
passes its real header/chooser/footer in both appearances. See ledger E26–E27
and [PRIVACY.md](PRIVACY.md#the-command-line-assistant-bridge-opt-in).

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
10. **Dictation writes into other apps.** Only finalized speech may reach a text
    field; volatile recognizer output is revised continuously and belongs in
    Nook's own indicator. Any replacement of already-inserted text must verify
    what it is about to overwrite and abandon the attempt when it does not
    match.
11. **A rewrite is never trusted on its own.** Dictated speech frequently reads
    as an instruction, and a language model will act on it. Model output is
    checked against the transcript and discarded in favour of the spoken words
    when it drifts.
12. **Accessibility access is dictation-only.** It is never requested during
    first-run setup, never required for recording, and must remain absent from
    the meeting permission set.
13. **Multi-session notes are additive.** The `sessions:` and `audioStart:`
    frontmatter keys and the transcript divider lines exist so a note can hold
    several recorded sittings. Older versions must keep decoding those files:
    unknown frontmatter keys are ignored and divider lines are not transcript
    content. Appending or merging regenerates summary and title but must never
    rewrite personal notes.

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
- dictation in hold and toggle modes, into a native Cocoa field (TextEdit,
  Mail), a Chromium or Electron field (Slack, VS Code, a browser text area),
  and a field that accepts neither, confirming the clipboard is restored;
- dictation with Accessibility access absent, then granted without relaunch;
- a dictated question, confirming it is typed rather than answered;
- a spoken code with repeated characters ("the code is A A 7 3") in Clean up,
  confirming nothing is dropped. A debug build logs `heard:` and `typed:` for
  any chunk clean-up altered, which also settles whether the recognizer
  capitalizes letters that were read out as letters — an assumption
  `DisfluencyFilter` documents but has never been checked against real output;
- Markdown save/edit/search and optional audio retention;
- VoiceOver, keyboard navigation, motion, transparency, contrast, light, and
  dark appearance;
- notched and non-notched panel geometry;
- official bundle identity, exact entitlements, code signatures, notarization,
  stapling, and Gatekeeper assessment;
- turning on calendar context, confirming the macOS permission prompt appears
  and a detected meeting is named after its nearby event;
- exporting an action item to Reminders, confirming the Reminders permission
  prompt and that the exported task carries its due date;
- the audio retention sweep, confirming kept audio older than the chosen
  window moves to the Trash on launch and notes are left untouched;
- the quick note pad: opening it by holding the dictation shortcut with no
  text field focused, Return inserting a newline rather than submitting,
  quitting with unsaved text present and confirming it is saved rather than
  discarded, and hands-free capture keeping the microphone live across
  chunks until turned off;
- recording into an existing note across more than one sitting, confirming
  the appended transcript, kept audio, and regenerated summary and title,
  and that personal notes are not rewritten;
- flagging a moment while recording and, when audio is kept, finding and
  playing it back from the note;
- compiling a weekly digest, confirming it refuses an empty week and states
  real counts and conversation time for a week that has meetings;
- asking a question in "Ask your library", confirming a weak match is
  refused rather than guessed and a good match cites the meetings it drew
  from;
- an approaching calendar event with earlier sittings, confirming the prep
  brief card and notification action quote real decisions, key points, and
  past sittings;
- merging two saved notes in both orderings (earlier into later, and later
  into earlier), confirming the combined transcript and kept audio land in
  the correct sequence either way; and
- full-archive update from the previous supported release without losing macOS
  permission grants.

See [ACCESSIBILITY.md](ACCESSIBILITY.md), [PRIVACY.md](PRIVACY.md), and
[OPERATIONS.md](OPERATIONS.md) for detailed acceptance criteria.

## Choosing work

Prefer observed user problems, reproducible platform failures, privacy and
accessibility gaps, and tests that protect existing behavior. Propose major
product or architecture changes in a public issue before implementation. Avoid
reopening settled design decisions without new evidence.
