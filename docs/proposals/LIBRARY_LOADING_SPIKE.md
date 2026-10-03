# Metadata-first library loading spike

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
