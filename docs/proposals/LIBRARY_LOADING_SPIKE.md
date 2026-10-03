# Metadata-first library loading

Public proposal: [issue #45](https://github.com/wrnsnng/nook/issues/45).
Implementation: [PR #46](https://github.com/wrnsnng/nook/pull/46), based on the
editor focus fix in [PR #47](https://github.com/wrnsnng/nook/pull/47).
This is proposed code, not a released feature.

## Integrated behavior, October 3, 2026

A cold `MarkdownStore` first discovers separate metadata entries, then loads
complete notes in the background. The library exposes those entries in a native
sidebar with loading/count copy. Selecting one reads and validates its exact
revision and displays a complete, read-only preview. Once the full snapshot
arrives, the normal sidebar/editor takes over and preserves the selected file
identity. Search and cross-library actions retain their existing loading guard.

`store.notes` contains only complete models. Summary sessions, saved drafts,
open actions, prep, digests, folder suggestions, palette search, multi-selection
and all mutation workflows retain their full-content contract. Existing note
snapshots skip the extra discovery scan on warm reloads. The search controller
prepares revision-keyed documents off the main actor after full publication;
queries still publish complete results, never a partial catalog.

Discovery reuses the codec's metadata semantics, reads and hashes all file
bytes and distinguishes copies by path plus UUID. Selected-note reads refuse
body-only edits with unchanged size/date, missing sources and identity changes.
Cancellation and reload generations reject late results after reload, save or
folder changes, including away/back. Preview tasks cancel when selection changes.
The early sidebar uses the same unsaved-draft navigation guard as the normal
sidebar. Failed discovery falls through to the existing full-loader error path;
a failed preview provides an explicit retry.

This is intentionally bounded: discovery adds work before the existing complete
loader. It does not replace full models with a persistent index or reduce their
steady-state memory. There are no file-format, network, model, privacy or
credential changes. Native input/accessibility and minimum-hardware acceptance
remain required before release.

## Integrated measurements

Apple M4 Pro Mac mini, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), optimized Debug
(`SWIFT_OPTIMIZATION_LEVEL=-O`, retaining existing DEBUG test hooks). Three fresh
stores load the same 1,001-note / 130,000-segment / 31,611,951-byte synthetic fixture
as the historical comparison below. The fixture digest is identical. No other
build or benchmark ran during this final measurement. OS caches were not flushed.

| Production-store operation | Median of three trials |
| --- | ---: |
| Metadata published for first rows | 226 ms |
| Open the 10,000-segment note while full loading continues | 90 ms |
| Complete library published, measured from startup | 2,879 ms |
| First complete transcript search after publication, including 160 ms debounce | 258 ms |

[All three raw trials](library-loading-integrated-results.json) include process
high-water RSS, which peaked at about 665 MiB including fixture generation and
the test host. Unlike the streaming prototype, this integration retains all
complete notes. No production memory reduction is claimed. The earlier full
loader median was 2,679 ms: early browsing arrives roughly 2.45 seconds sooner,
while complete loading takes roughly 200 ms longer. These are publication
measurements, not a measured time to first interactive rendered frame. Search
checks all 1,000 transcript-only matches, including unopened notes.

Reproduce with the ordinary model setup and the benchmark command below, using
`TEST_RUNNER_NOOK_LIBRARY_BENCHMARK=integrated` instead of `baseline` or `metadata`.
The benchmark writes `.build/library-benchmark-integrated.json` and is disabled
in normal test runs.

## Integrated verification

The final full optimized Debug suite passed 1,387 declarations / 1,848 cases,
zero failures and zero runtime warnings. One opt-in benchmark was skipped; its
integrated mode then passed separately. Results are
`Test-Nook-2026.10.03_20-32-50-+1000.xcresult` and
`Test-Nook-2026.10.03_20-33-57-+1000.xcresult` under `.build/LibrarySpikeTests/Logs/Test`.
The production discovery implementation is also used by the original spike's
correctness suite, avoiding a separate scanner that could diverge.

New integration tests verify separate early/full publication, preview contents,
complete search of unopened content, folder away/back rejection, save-vs-load
ordering, same-size/date body edits, missing sources, copied IDs and unreadable
files. Existing draft, identity, search, mutation and hosted-editor suites pass.
The editor warning fix is isolated in PR #47.

`NookSnapshot` has `library-loading-light` and `library-loading-dark` modes that
hold only the synthetic full scan for ten seconds. Real window captures were
inspected in both appearances before and after publication: all sections are
visible, progress copy wraps, and the selected note survives the handoff. That
inspection caught and fixed colliding section-row IDs. This is visual synthetic
acceptance, not keyboard/VoiceOver, physical IME or minimum-hardware acceptance.
Offscreen snapshots do not reliably render native sidebar materials; use the
existing `NOOK_SNAPSHOT_WINDOWED=1` mode for this check.

XcodeGen 2.46.0 includes the new app, snapshot and test sources; repeated
generation is stable. No signed running app, permissions or personal notes were
changed. All implementation work is in an isolated worktree.

## Historical spike evidence

The following is the original experiment and recommendation, before UI
integration. Its statements that the UI is unchanged describe that earlier
revision, not the integrated behavior above. The original raw comparison is
preserved to keep the benchmark provenance reviewable.

<details>
<summary>Original read-only spike and measurements</summary>


Public proposal: [issue #45](https://github.com/wrnsnng/nook/issues/45).
Baseline: main at `04dec1d`, after the one-level folder and speaker-label work.

This is a read-only experiment. `MarkdownStore.loadNotes` and the production
Library still load complete notes. No UI, saving, search, identity, model or
network behavior changes. The older August measurements do not describe this
revision and are not used as the before result.

## Implementation

`MarkdownCodec.decodeMetadata` returns a separate `Metadata` value with identity,
kind, title, dates, source and session-aware duration. It reuses the codec's
frontmatter, escaping and date/session helpers. It does not parse transcript,
summary, actions or personal notes. A missing title uses the existing heading
fallback semantics, scanning only until a heading is found.

The loader in `NookTests/LibraryLoadingSpike.swift` exists only in the test
bundle. It discovers the same root and one-level folder scope, reads and hashes
all file bytes, and caches metadata by standardized path and exact revision.
It never caches solely by date or size, and rescans prune removed paths.
Copied UUIDs keep distinct file identities.

Opening an entry re-reads its source and refuses a changed revision before
calling the complete production decoder. Search visits every entry, building
a disposable document cache with the production document builder and term
matcher. Cache keys include file identity and exact revision; a hit still
re-reads and hashes the file to refuse changes since discovery. It retains one
decoded note at a time and throws on cancellation or an incomplete catalog.
A per-file autorelease pool also releases the codec’s temporary Foundation
objects, which otherwise accumulate across the streaming loop.
It has no write operations and never manufactures an incomplete `MeetingNote`.

This is snapshot validation, not a filesystem transaction. A write after the
snapshot read still requires the existing save-time revision guards. Root
folder enumeration errors abort discovery; individual unreadable folders/files
become issues. Search refuses to call an incomplete catalog complete.

## Reproduction

Use XcodeGen 2.46.0 and the model setup in `CONTRIBUTING.md`. Keep unsigned test
build products separate from any signed running app.

```sh
xcodegen generate
xcodebuild test -quiet -project Nook.xcodeproj -scheme Nook \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/LibrarySpikeTests CODE_SIGNING_ALLOWED=NO \
  -only-testing:NookTests/LibraryLoadingSpikeTests

TEST_RUNNER_NOOK_LIBRARY_BENCHMARK=baseline xcodebuild test -quiet \
  -project Nook.xcodeproj -scheme Nook -configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/LibrarySpikeTests CODE_SIGNING_ALLOWED=NO \
  -only-testing:NookTests/LibraryLoadingBenchmarkTests

TEST_RUNNER_NOOK_LIBRARY_BENCHMARK=metadata xcodebuild test -quiet \
  -project Nook.xcodeproj -scheme Nook -configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/LibrarySpikeTests CODE_SIGNING_ALLOWED=NO \
  -only-testing:NookTests/LibraryLoadingBenchmarkTests
```

Each benchmark invocation creates and removes its own synthetic temporary
library. It writes aggregate results to `.build/library-benchmark-MODE.json`.
The benchmark is disabled in ordinary test runs and has no latency thresholds.

The fixture contains 1,000 ordinary notes with 120 alternating-source segments
each, half in a child folder, plus a 10,000-segment note. The query occurs only
in the ordinary notes' transcripts. Every run checks all 1,000 expected hits,
1,001 discovered notes and all 10,000 segments when opening the long note.

Each mode runs three trials, using an empty application cache for each cold
scan and immediately repeating with that cache for the warm scan. OS file
caches are not flushed. Baseline search includes building the production search
document cache; repeated search reuses it. The prototype streams full decodes for its first search and reuses cached
documents for the second, while revalidating every source file. Fixture
generation is outside all timing intervals. Fixture encoding and each measured
synchronous phase have autorelease pools so temporary Foundation objects do
not accumulate across trials. Timing uses monotonic uptime in an optimized
Debug test build with `SWIFT_OPTIMIZATION_LEVEL=-O`. Debug retains the
existing test hooks required by the full test target; this is not a shipping
Release binary measurement.
The fixture uses fixed identities/dates and reports a digest of all file
revisions; the two modes must have identical fixture digests.

Memory is process high-water RSS from `getrusage`, including the app test host,
fixture generation and allocator retention. Modes run in separate processes.
Only the first trial's catalog high-water mark precedes search work; later
catalog values can inherit an earlier search peak. This is not a precise
allocation attribution, sustained memory profile or minimum-hardware result.

## Measurements, October 3, 2026

Apple M4 Pro Mac mini, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a).
The table reports medians of three trials per mode. Both modes used exactly
31,611,951 bytes of synthetic Markdown and the same fixture revision digest.
[Raw aggregate measurements](library-loading-results.json) include every trial.
No other build or benchmark ran during these measurements.

| Operation | Current full loader | Metadata-first prototype |
| --- | ---: | ---: |
| Cold catalog ready | 2,679 ms | 207 ms |
| Warm catalog refresh | 77 ms | 52 ms |
| Open 10,000-segment note after catalog | <1 ms | 86 ms |
| First complete transcript search after catalog | 93 ms | 2,675 ms |
| Repeated complete transcript search | 37 ms | 63 ms |
| First catalog process high-water RSS | 623 MiB | 226 MiB |
| Highest process RSS over three trials | 658 MiB | 283 MiB |

Metadata discovery is about 13 times faster. It shifts full decoding to the
first search or opened note; startup plus first search is approximately the
same total work, not a 13-fold end-to-end speedup. The UI is not connected, so
these are catalog timings, not measured time to an interactive window.

An initial uncached streaming search took about 2.6 seconds on every query.
The revised spike retains revision-keyed search documents, bringing repeats
to 63 ms while still verifying source bytes on every query. It never retains
full decoded models for all notes. Cache eviction/budgets and background index
scheduling are deliberately left for integration design.

The first memory experiment also exposed temporary Foundation objects retained
across the streaming loop and benchmark phases. Explicit autorelease pools
prevent that accumulation. The table uses only the corrected harness; preliminary
runs are excluded. These high-water figures include the test host, allocator
retention and fixture generation (about 223 MiB). They support investigating
lower memory use, but do not establish a production memory reduction.

**Recommendation:** proceed with a separately reviewed UI integration design,
using metadata for discovery and background revision-keyed search indexing.
Do not replace `store.notes` with partial models. Preserve the current loader
until all consumers and the first-search progress/failure experience are adapted.

## Integration gates

A fast catalog is not yet a usable Library. The experiment does not implement
sidebar publication, selection, focus, draft preservation or accessible loading
announcements. Production integration needs explicit unloaded/loading/ready/
failed states and generation checks for folder changes, including away/back.

The current `store.notes` collection feeds summary sessions, open actions,
prep briefs, digests, folder suggestions, palette search, multi-selection and
mutation workflows. Replacing it with only opened notes would silently omit
content. Every such consumer must either use an appropriate metadata view or
request complete content with progress, cancellation and failure handling.

Before integration, resolve repeated-search cost, bound cache memory and
measure rebuilds, full UI opening, long-note interaction and folder-switch
races. Test duplicate UUIDs, malformed input, late results, same-timestamp edits,
external/managed rename and deletion. All mutation paths must retain exact
revision checks and obtain complete models first. No persistent index is
introduced by this spike.

## Verification

The full optimized Debug suite passed 1,381 test declarations / 1,841 executed
cases, zero failures. The one skipped declaration is the opt-in benchmark;
baseline and metadata modes each passed separately. The new correctness suite
has seven declarations / 16 cases, covering metadata compatibility, Unicode,
session duration, copied IDs, folders, cold/warm search equivalence, body-only
and header edits with unchanged size/date, rename, deletion, corrupt UTF-8 and
cancellation. This does not exercise native UI loading or folder-generation
publication, which are not implemented in the spike.

The full run recorded view-update/publishing warnings in the unchanged
`NookNotesEditor.swift`. Their cause was not investigated in this work; passing
tests do not establish that those editor warnings are harmless.

XcodeGen 2.46.0 includes all three new test sources. Repeated generation produced
identical project files. No signed running app, permission settings, personal
notes or recordings were changed. The original dirty checkout was left intact;
all work was done in the separate `codex/library-loading-spike` worktree.

</details>
