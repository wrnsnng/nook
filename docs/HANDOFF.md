# Project status

This page records durable maintainer context. GitHub issues and pull requests are
the source of truth for active work; private task trackers are not required to
contribute.

## Current release

Nook 1.19.0 is the current public release, published August 27, 2026. The
release listing was checked on September 1; the 1.20.0 candidate has not been
published.

- Release builds use stable Xcode 26 and the macOS 26 SDK.
- Distributed builds are Developer ID signed, notarized, stapled, and delivered
  through a signed Sparkle feed.
- The release is available from the
  [binary releases repository](https://github.com/wrnsnng/nook-releases/releases/tag/v1.19.0).
- User-facing changes are mapped in [CHANGELOG.md](../CHANGELOG.md).

## Release 1.20.0 candidate

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
