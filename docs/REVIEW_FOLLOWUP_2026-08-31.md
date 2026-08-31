# Nook review follow-up, 31 August 2026

Nook's strongest opportunity is a trustworthy voice notebook: capture a thought
quickly, keep the person's words safe, find the supporting passage, and finish
the follow-up. The current implementation has much of this product already.
The next investment should make that whole experience dependable and accessible
before adding more destinations, assistants or recording modes.

This report follows the [original code review](CODE_REVIEW_2026-08.md). It
distinguishes locally implemented fixes, measured results, remaining risks and
proposed features. The accumulated changes are being prepared for 1.20.0;
[release acceptance](RELEASE_1.20.0_ACCEPTANCE.md) records its publication status.
Measurements and acceptance use synthetic content, never real meetings.

## September 1 Library and editor follow-up

The next candidate publishes each save as one sorted Library snapshot and
observes draft-recovery status within its sidebar section. Following the public
[native-editor proposal](https://github.com/wrnsnng/nook/issues/15), it explicitly
creates TextKit 1 without switching engines during an edit. The native boundary
also preserves active marked text across unrelated redraws and carries exact
NFC/NFD replacements that ordinary Swift String equality would treat as equal.

The first accepted September 1 integration passes 1,034 tests, with warnings
treated as errors, plus snapshot/optimized builds and two Python tests. Its
focused editor suite has 18 declarations and 30 parameter cases. The final
accessibility test proves complete character counts and offscreen content access
after scroll/resize; it does not establish VoiceOver interaction. Earlier failing
composition and exact-replacement cases were corrected and retained as evidence.

One matching Release pair per input uses 1,001 unchanged base notes, a saved
20,000-word pad, the same observed 460-point window and a 32-character burst.
Each target-only 30-second trace covers the complete input and subsequent
updates, without accessibility inspection or concurrent builds/analysis.

| First September 1 candidate comparison | Before | After |
| --- | ---: | ---: |
| Native key handling, one paragraph, inclusive samples | 885.0 ms | 131.9 ms |
| AppKit text layout, one paragraph, inclusive samples | 858.8 ms | 27.6 ms |
| Main-thread work, one-paragraph interaction window | 1,709.1 ms | 896.2 ms |
| Main-thread work, 200-paragraph interaction window | 995.8 ms | 902.6 ms |
| Recorded Library row-child updates, either shape | 5,010 | 4,008 |

The roughly 894 ms typing hang is absent from the candidate's one-paragraph
recording. A **257 ms post-save Library/List microhang remains** there; no
detector interval appears in the candidate's 200-paragraph recording. Broad
List/layout timings do not uniformly improve, and background sampled work
increases. These are overlapping sampled costs and recorded update counts,
not per-key input latency, visible redraw counts, frame rate or energy savings.
There is one pair per shape; the burst scheduling is not identical.

Native Save, Undo and Redo preserve every expected byte in both shapes, and all
1,001 original files remain unchanged. A further native dead-key and middle-word
selection check preserves surrounding emoji, bidirectional and decomposed text.
Both isolated apps quit normally. The capture uses the 1,033-test production
source; the 1,034th declaration is test-only. Receipts and scope are in
`.build/performance-review/library-editing-20260901/matched-comparison.json`
and `matched-comparison.md`. Physical input methods, VoiceOver, minimum hardware,
capture and installed-update acceptance remain separate gates.

### Final controller publication experiment, 1,040 tests

The final integration passes **1,040 tests with zero failures or skips**, plus
snapshot/optimized builds with warnings as errors and two Python tests. The
additional controller changes avoid broadcasting unchanged Open actions,
empty search and absent Prep state. Refreshes still check exact source revisions
and Reminders receipts, preserve unrelated reminder errors, resolve duplicate
source errors, cancel pending searches and advance generation guards. Regression
tests cover those boundaries. No grouping-cache or Library view refactor is
included.

One accepted matching Time Profiler pair per 20,000-word shape compares these
guards with the preceding candidate, which already uses TextKit 1. Both accepted
libraries contain exactly 1,001 unchanged original notes plus one saved pad.
The four preparation screenshots match at 460 × 364 pixels; the same underlying
63,000-word Library note and Notes tab were observed. Each input is a 32-character
automation burst, with no accessibility inspection during recording. Explicit
target-PID filtering and full sampled-window coverage pass. The interaction
window begins 100 ms before the first sampled key/input callback and ends four
seconds after the last sampled input interval.

| Final controller comparison, inclusive sampled CPU | 200 paragraphs before | Final | One paragraph before | Final |
| --- | ---: | ---: | ---: | ---: |
| Four seconds after input, main thread | 481 ms | 424 ms | 484 ms | 432 ms |
| Post-input List traversal | 286 ms | 256 ms | 285 ms | 253 ms |
| Typing, main thread | 217 ms | 215 ms | 238 ms | 248 ms |
| AppKit text layout, interaction window | 6 ms | 5 ms | 26 ms | 27 ms |
| Post-input SwiftUI layout | 215 ms | 218 ms | 214 ms | 217 ms |

Post-input main CPU falls **11.9% and 10.7%**, while List traversal falls **10.5%
and 11.2%**. Typing and broad layout work are essentially unchanged; the single
one-paragraph final run has slightly more typing work. These overlapping sampled
weights support less redundant post-save work, not another editor speedup,
per-key latency, visible redraw counts or energy savings.

All accepted recorders and exports exit successfully. Two final SwiftUI
recordings failed during recorder finalization with SIGTRAP; the app continued
working and saved exactly. Those failed captures, the original before SwiftUI
recordings, and an initial CPU baseline containing 1,003 notes are excluded.
The extra synthetic pad was preserved outside the corrected baseline library.
The accepted CPU template's four potential-hangs tables contain no intervals in
either variant. **This does not establish that the earlier 257 ms post-save
pause is fixed:** that earlier candidate is the CPU baseline and also has no
detected interval under this different template. SwiftUI update counters, update
groups and hitch schemas are absent, so there is no final row-count or
group-duration claim.

This is one accepted capture per variant and shape. Final captures occurred
before accepted baselines, leaving order and warm-cache effects uncontrolled;
burst scheduling also differs. These 1 ms CPU samples must not be compared
directly with the earlier SwiftUI template's 0.1 ms samples. Missing frames can
reflect sampling, optimization or symbolication, not absent work. Exact Save,
Undo and Redo and all 1,001 original hashes pass in both variants; both apps quit
normally. Binary hashes and all 145 source fingerprints match their manifests.
The accepted analysis and exclusions are recorded in
`.build/performance-review/library-list-final-20260901/accepted-cpu-comparison.json`
and `accepted-cpu-comparison.md`. Repeated responsiveness measurements, the
remaining Library pause, minimum hardware, VoiceOver, capture and installed
update acceptance remain open.

## Performance

Two measured decoder changes are implemented in
[MarkdownCodec](../Nook/Services/MarkdownCodec.swift) and
[TranscriptAssembler](../Nook/Services/TranscriptAssembler.swift): construct
stable transcript UUIDs directly from the same digest bytes, and reject
ineligible speaker/gap pairs before counting both passages' words. Neither
change alters the saved format, text normalization, merge rules or identity.
Golden compatibility vectors and merge-boundary tests protect those properties.

An optimized production-source benchmark measured the following wall times:

| Workload | Before | After | Interpretation |
| --- | ---: | ---: | --- |
| Cold decode/load, 100 notes | 653 ms | 300 ms | About 54% less work |
| Cold decode/load, 1,000 notes | 6.295 s | 3.011 s | About 52% less work |
| Warm decode/load, 1,000 notes | 56.6 ms | 58.3 ms | No demonstrated improvement |
| Cached-document matching, 1,000 notes | 370 ms | 361 ms | Still a bottleneck; semantics unchanged |

The 1,000-note fixture contains 120,000 input transcript segments and 27.4 MB
of Markdown. Cold means an empty application decode cache, not a purged OS disk
cache. Cold figures are three-trial means; the final range is 3.000–3.018 s.
The environment is an M4 Pro running macOS 26.6.2, Swift 6, optimized compilation.
The app loads off the main actor, so these are work costs, not measured UI
freezes. Changing every fixture file while preserving its modification timestamp
still invalidated all revisions and search results correctly.

Quick Note had a separate, serious rendering cost. In a clean input-only trace
of a 20,000-word pad, seven actual `QuickNoteView.body` updates took about
700–728 ms. Repeated calls through `statusText` and the computed word count
dominated the sampled stacks. The controller now counts on text changes and
the toolbar reuses that value, including its accessibility label. Counts retain
the previous Unicode/whitespace semantics and follow dictation correction,
programmatic replacement and clearing.

The first completed comparison uses the same 20,000-word single paragraph and the
same four-word insertion in the isolated optimized app. Both 18-second traces
exclude accessibility snapshots during typing; the accepted repeat ran without
concurrent builds, benchmarks or analysis jobs.

| Quick Note instrumented observation | Before | Cached-count rendering |
| --- | ---: | ---: |
| Actual body updates | 7 | 7 |
| Median body update | 705.778 ms | 0.612 ms |
| Maximum body update | 727.758 ms | 20.749 ms |
| Body updates over 100 ms | 7 | 0 |

The rendering bottleneck was substantially reduced, but long-pad typing was not
fixed. That cached-count trace still contained a **2.291-second Severe Hang**.
Its sampled stacks include synchronous per-edit word counting, exact-text
comparison, and native text layout/selection work. Inclusive stack costs
overlap and cannot be added. A later 592 ms interval contains almost no sampled
word-counting work, so moving the count alone cannot be assumed to remove every
stall.
The exact inserted text and the final 20,004-word Saved state were verified.

These are single instrumented runs of an extreme one-paragraph fixture, without
per-keystroke signposts. Body durations are not end-to-end input latency, and
this is not shipping-build or minimum-hardware acceptance. An earlier locked
capture and a potentially contended repeat are excluded from the comparison.

The next implemented change moves statistics off the main actor. One detached
consumer counts the active snapshot while a bounded stream retains only the
newest pending edit. Results publish only for their exact text revision; the
old total is hidden while counting, without hiding an authoritative Saved
status. Pending counts always require discard confirmation. Empty text resets
the count immediately. Checkpoint submission and saving keep their existing
paths and never wait for statistics. An active count can finish after
a newer edit arrives; this bounds snapshot count, not bytes or peak memory.

In a prepared input-only trace, main-thread `text.didSet` sampled weight fell
from **949.7 ms to 154.5 ms**, and counting appeared only on background threads
(47.4 ms of sampled weight). The largest detected interval fell from 2.291 s to
**1.258 s**. A stall still remains. These inclusive sample weights overlap; they
are not individual-keystroke timings. The newer build's SwiftUI export labels
Quick Note activity as **Other Updates** and has no matching actual Body rows,
so the earlier body table cannot be extended with a comparable third column.

A separate experiment replaced spaces with newlines to arrange the same 20,000
words into 200 paragraphs, preserving character count, width, caret position
and inserted suffix. Sampled native `NSTextStorage.endEditing` work fell from
850.7 ms to 12.4 ms. The largest detector interval was still 614.8 ms; exact
comparisons remained substantial and task-suggestion scanning became prominent.
This supports investigating long-paragraph layout. It does not justify silently
reformatting a person's text or replacing the native text engine.

A subsequent implemented improvement converts AppKit's incoming text snapshot to
contiguous UTF-8 once before the existing binding assignment. It preserves exact
bytes, including composed/decomposed Unicode, and leaves the editor's text and
selection untouched. A separate optimized 20,000-word storage probe measured
4.58 ms for a foreign-storage comparison versus 2.65 ms for conversion plus one
comparison against a native baseline. Reusing one conversion for three
comparisons took 3.13 ms versus 13.70 ms without conversion. This pays an initial
allocation/conversion cost; those probe figures are not app latency.

The completed app comparison uses the same prepared single-paragraph and
200-paragraph inputs, with the same insertion, editor width and caret position.
The table compares background counting alone with background counting plus the
contiguous snapshot. Both final captures cover the typing region, with no
sampled accessibility hierarchy inspection or late second editing cluster.
For the final single-paragraph capture, inspection began while the recorder
process was finalizing. No inspection/reset contamination was detected in the
measured tables; samples are not an exhaustive event log. The 200-paragraph
capture waited for full recorder exit before inspection.

| Observation | One paragraph, before | One paragraph, after | 200 paragraphs, before | 200 paragraphs, after |
| --- | ---: | ---: | ---: | ---: |
| Main-thread `text.didSet` sampled weight | 154.5 ms | 9.5 ms | 157.7 ms | 9.3 ms |
| Main-thread exact comparison sampled weight | 306.3 ms | 36.1 ms | 346.4 ms | 36.4 ms |
| Quick Note DynamicBody Other Update maximum | 19.834 ms | 0.800 ms | 20.690 ms | 0.985 ms |
| Native `NSTextStorage.endEditing` sampled weight | 850.7 ms | 833.7 ms | 12.4 ms | 12.3 ms |
| `refreshTaskSuggestion` sampled weight | 54.6 ms | 19.4 ms | 381.5 ms | 349.2 ms |
| Largest detected interval | 1,258.193 ms | 1,051.841 ms | 614.836 ms | 362.813 ms |

The SwiftUI row compares eight updates in the same **Other Updates** category
in each capture; it is not comparable with the earlier actual Body table.
Conversion itself costs 75.0/75.5 ms of inclusive main-thread samples across the
single/200-paragraph inputs. The improvement comes from reusing that conversion,
not eliminating its cost. Inclusive sample weights overlap and cannot be added.
These are single instrumented runs, without per-keystroke latency measurements.

Exact inserted text and the final 20,004-word Saved state were verified in both
cases. A live Undo/Redo check on the final 200-paragraph pad preserved the original
text, removed the inserted suffix on Undo, and restored the exact text and saved
state on Redo. Long-paragraph native layout remains substantial. In the final
200-paragraph trace, two suggestion-related updates still took about 179 and
170 ms. Neither result establishes smooth editing on minimum supported hardware.

The full-app fixture separately contains 1,001 notes and 83,000 input segments,
including a 3,000-passage transcript. Five transcript-related **Other Updates**
took 19–36 ms; actual **View Body Updates** were all below 0.224 ms. Three
342–378 ms detector intervals were dominated by accessibility hierarchy
enumeration during automation inspection. They must not be described as ordinary
search/scroll freezes. Accessibility scaling still deserves investigation;
removing accessible content to improve a benchmark would be the wrong fix.

The subsequent implementation moves task suggestions onto the same bounded
background consumer as word counting. Counts publish before suggestion parsing;
both results must match the current exact revision. A new edit immediately hides
an old suggestion, and a stale button action cannot rewrite newer words. Reopening
refreshes relative dates while keeping a current count. Fixed date expressions
are compiled once rather than rebuilt for each paragraph. The native editor now
also applies programmatic NFC/NFD replacements exactly, and autosave observes the
exact text revision rather than canonical String equality.

The subsequent full-app comparison confirms that the named word-count and
suggestion computations now appear only on background threads. In the
200-paragraph case, two input-period updates previously spent about 179 and
170 ms in synchronous suggestion work; those expensive updates are absent from
the new trace. A later 334 ms microhang remains in library identity, list and
layout work. The one-paragraph capture still has a 1.063-second hang, largely
native text layout and selection repair. Exact saved text was verified in both
cases, and Undo/Redo retained exact text in the 200-paragraph case.

The new single-paragraph input occurred late in the recording. Its CPU samples
end before the last SwiftUI update, so total sampled CPU and detector counts
cannot support a whole-session improvement claim against the earlier capture.
Typing and the reported hang are within coverage. Both recorders exited before
accessibility inspection, and no hierarchy-copy or programmatic replacement
frames were sampled. These remain single instrumented runs, not per-keystroke
latency, minimum-hardware, memory or energy acceptance.

An optimized standalone comparison with the frozen earlier parser passed 11,264
Unicode/date-cue cases with identical paragraph bytes, labels and dates. Five
interleaved trials measured these medians, including the final cancellation checks:

| Parser workload | Earlier parser | Reused patterns |
| --- | ---: | ---: |
| One paragraph without a cue | 9.276 ms | 8.635 ms |
| 200 paragraphs without a cue | 118.050 ms | 10.308 ms |
| 200 paragraphs recalling a past weekday | 136.301 ms | 11.157 ms |

The search matcher now uses literal lookup only for lowercase ASCII letters and
digits, validates complete Character boundaries, and falls back to the existing
matcher for partial candidates or other query characters. Broader Foundation
search substitutions were rejected after they changed Unicode results. The final
helper matched the original across 84,445 differential cases. On 1,000 synthetic
notes with 120,000 segments and 23.9 MB of search documents, five optimized trials
measured selective matching at 338 to 77.8 ms mean and absent ASCII matching at
409 to 89.0 ms. A common title query was 2.11 to 2.24 ms; not every query improved.
Unicode and punctuation queries retain the original matcher. Search cancellation
now reaches detached work, and controller teardown cancels an active search.

These are component benchmarks, not end-to-end typing or search latency. The
search figures exclude the 160 ms debounce. The background-suggestion app
comparison described above covers typing in the newer editor batch, not search
latency. The isolated native experiment below narrows the long-paragraph cost
without changing the production text engine.

Remaining priorities:

1. Address the remaining native long-paragraph layout and subsequent library
   identity/list/layout work. The suggestion worker's full-app comparison is
   complete, with the shorter single-paragraph coverage caveat above. Preserve
   exact-content checks and the parser's Unicode boundaries, cue precedence and
   rejection of past events. A native engine change still needs a separate
   proposal and input-method, undo, selection and accessibility acceptance.
2. Verify search responsiveness in the full app and investigate expensive
   non-ASCII queries without weakening canonical equivalence or Character
   boundaries. The exact-document cache is already cheap compared with matching.
3. Propose metadata-first library loading and lazy transcript decoding for large
   libraries. Three seconds on this Mac is still substantial cold work. Preserve
   exact revision validation and copied-file identity when designing an index.
   The [architecture and feature proposal drafts](proposals/REVIEW_ROADMAP.md)
   specify acceptance gates; no new public issue has been published yet.
4. Profile real 60–120 minute capture, dictation, finalization, memory and energy
   on the minimum supported Mac. These CPU/UI probes cannot establish battery
   life, speech latency, leak freedom or audio continuity.
5. Examine repeated detail-header eligibility work and exact-text comparisons
   only after reproducing their cost without accessibility snapshots. Measure
   before and after each bounded change, following Apple's
   [SwiftUI performance workflow](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).

An isolated native editor experiment narrows the long-paragraph investigation.
Three trials per configuration typed the same 32-character suffix into 20,000
synthetic words. Each used a fresh editor with identical 407-point text/container
width (460-point window, 424-point scroll view). All 18 exports, 576 key handlers,
passed independent fixture/suffix hashes, exact Undo/Redo and caret-position
checks, with no text-engine switch notifications.

| Native configuration | One paragraph, mean handler sum | 200 paragraphs, mean handler sum |
| --- | ---: | ---: |
| TextKit 2 | 895.6 ms | 86.6 ms |
| TextKit 1 | 96.5 ms | 76.5 ms |
| TextKit 1, noncontiguous layout | 99.4 ms | 74.8 ms |

These sums cover synchronous `super.keyDown` work across 32 characters. They
exclude event-queue delay and asynchronous drawing; no xctrace samples or Nook
bindings ran in this probe. TextKit 1 is a promising investigation, and the
additional noncontiguous setting shows no clear benefit in these trials. No
production engine changed. The [native-layout proposal draft](proposals/REVIEW_ROADMAP.md#native-text-layout-for-long-paragraphs)
requires integrated typing, selection, Unicode, real input-method and VoiceOver
acceptance before adoption. Neither this result nor an inactive marked-text
range proves IME correctness.

Raw benchmarks, source fingerprints and sanitized profiler reports remain local
under `.build/performance-review`. Raw trace metadata is not a shareable report.

One additional bounded change filters selection lookups by UUID before building
each candidate's full file identity. Same-UUID candidates still require the
original complete path comparison; copied files and ordering retain their
existing semantics. An optimized standalone probe compiled the unchanged
production note, transcript and identity types, with a synthetic array wrapper
instead of MarkdownStore lifecycle. All 13,054 compatibility comparisons passed.
Five interleaved trials on 1,000 notes measured median last-row lookup at
2.282 ms before and 0.083 ms after; a missing UUID fell from 2.377 to 0.082 ms.
First-row lookup was unchanged at about 0.00227 ms. At 10,000 notes, last-row
lookup fell from 23.104 to 0.793 ms. Timings excluded fixture construction and
did not overlap builds or profiles. The receipt is
`.build/performance-review/identity-lookup-20260831/summary.json`.
This demonstrates less component work, not full-app latency or resolution of
the remaining 334 ms Library interval or native long-paragraph stall.

Further attribution of that earlier Library interval places 65.5 ms of inclusive
main-thread samples under identity construction in rows, ForEach IDs and grouping
fingerprints. These callers are separate from the UUID-prefilter lookup above.
Foundation path normalization can consult the filesystem for bridged URLs, so
the claim that this computation never reads the filesystem was incorrect.

The implemented correction captures the normalized identity when a note is
initialized or its file URL is assigned. Repeated rendering reads that value.
Every assignment refreshes it, including equal URLs and warm decode-cache
reloads; filesystem changes alone do not silently change a displayed identity.
The original URL remains unchanged for file operations. A private address
wrapper compares and hashes only that original URL, preserving note equality
while keeping copied UUIDs distinct by path. Save-revision guards, document
serialization and the production text engine are unchanged.

Five interleaved optimized component trials compile frozen before/after
production model sources and use the loader's FileManager URL construction.
For 1,000 synthetic notes, the per-pass medians are:

| Identity workload | Before | Captured identity |
| --- | ---: | ---: |
| Read every Library identity once | 3.623 ms | 0.085 ms |
| Construct the notes | 0.051 ms | 3.660 ms |
| Reassign every existing file URL | 0.060 ms | 3.674 ms |

This moves normalization to the address boundary rather than removing its cost.
All 2,002 URL-source/identity cases match across both binaries, and all 1,001
synthetic file digests remain unchanged. The note value stride increases from
224 to 256 bytes, plus retained path String storage; this is not a peak-memory
measurement. The receipt and complete trial ranges are in
`.build/performance-review/library-layout-20260831/component-summary.json`.

The subsequent native comparison completed after the Mac was unlocked. Both
frozen apps use Release builds, the same 1,001 base notes plus one saved pad,
the same 20,000 words in 200 paragraphs, a 460-point window and the same
32-character insertion. Both traces contain only the expected target process,
one sampled typing cluster, and complete coverage of the edit and subsequent
SwiftUI updates. No builds, benchmarks, analysis or accessibility inspection
run during capture; both recorders exit before inspection.

| Fresh Release comparison | Before cache | Captured identity |
| --- | ---: | ---: |
| Main-thread URL normalization, inclusive samples | 157.6 ms | 0.7 ms |
| Grouping fingerprint, inclusive samples | 36.1 ms | 1.7 ms |
| Main-thread work in equal four-second post-input windows | 877.7 ms | 704.3 ms |
| Largest detected Library microhang | 311.908 ms | 253.474 ms |

The normalization and fingerprint figures cover the sampled interaction through
four seconds after typing. These inclusive categories overlap; do not add them.
Row, ForEach/key-path and fingerprint stacks lose their sampled normalization
work. Initializer frames are absent in both optimized builds, so their absence
is not evidence of zero calls; inlining and symbolication limit named-frame
attribution. This fresh Release pair is separate from the older Debug `-O`
334 ms observation and must not be presented as a direct extension of it.

Sampled typing work is essentially unchanged. The remaining 253 ms pause
contains substantial list traversal, layout and exact-comparison work. Not every
metric improves: the maximum detail DynamicBody Other Update rises from 18.393
to 21.311 ms in this pair. Quick Note's ten DynamicBody Other Updates stay below
1.605 ms; these are not actual `QuickNoteView.body` rows. This is one
instrumented pair, not per-keystroke, minimum-hardware, memory or energy
acceptance. It improves a measured source of work without establishing smooth
editing. The separate long-paragraph native-layout stall was not retested.

Both saved bodies match every expected Unicode byte, and all original 1,001
files remain exact in each library. Native Undo in the cached build restores
the original 20,000-word body; Redo restores the suffix and the 20,004-word Saved
status. Both apps quit normally. The receipt is
`.build/performance-review/library-layout-20260831/native-comparison.json`,
with independent attribution in `library-attribution.md`. All 145 source/project
fingerprints still match the accepted integration; this native pass changes no
production code or text engine.

## Security

The reviewed changes keep the local-first default. No analytics, crash uploader,
remote model or new network path was added. The optional installed CLI bridge
remains an explicit per-provider exception.

- CLI actions now refuse incompatible installations when required restrictions
  are unavailable. Codex's broader local file-read access is disclosed, and its
  prior consent must be renewed. Fixed arguments and stdin avoid shell
  interpolation; Nook does not read another application's credentials.
- Dictation guards now conservatively reject changes to numeric literals,
  negation and short utterances. Original words remain the fallback. These
  checks reduce specific mistakes; they cannot prove arbitrary paraphrases are
  semantically faithful.
- Recovery validates private files, bounds encoded records and scans, and
  publishes new notes exclusively. Unsupported destinations retain the draft
  instead of silently weakening the no-overwrite rule.

The important residual boundary is that Nook is unsandboxed and its Markdown,
audio and recovery checkpoints are plaintext. Owner-only permissions are not
encryption or protection from another process running as the same user. The
external CLI must honor its own flags; Nook does not independently confine it.
An opted-in Codex invocation may read other accessible files and send information
from them to its provider. See [PRIVACY.md](PRIVACY.md) and
[CommandLineAssistant](../Nook/Services/Notes/CommandLineAssistant.swift).

The CLI runner now bounds help stdout at 256 KiB, action stdout at 2 MiB, and
stderr at 64 KiB; a failure shows at most 4 KiB of diagnostics. Oversized responses
are refused as a whole. It drains nonblocking pipes together, uses an owned
process group, and applies cancellation and 10-second help/90-second action
deadlines with TERM/KILL cleanup. Its environment is constructed from account
paths, a fixed search path, a temporary directory and UTF-8 locale; arbitrary
API-key, proxy and runtime-injection variables are not forwarded. Synthetic
process tests cover blocked input, simultaneous output, output floods, ignored
TERM, inherited descriptors and descendants retaining pipes. This is process
cleanup, not confinement; a deliberately escaping tool remains outside that
guarantee. Custom environment-dependent CLI setups may no longer work unchanged.

Quick Note now keeps the captured external provider's warning until the actual
operation returns, including a stopping state after a provider change or consent
revocation. Late output is rejected; another action cannot overlap cleanup, but
editing and saving remain available. Availability refresh cannot silently select
a previously approved external provider in place of an unavailable local model.
Ordinary Quit waits for assistant cleanup, refuses to exit after a five-second
wait if cleanup is incomplete, and rechecks drafts after asynchronous cleanup
and meeting finalization. Both quit gates reset when Nook stays open. These
paths have deterministic regressions, not active-CLI native shutdown acceptance.
Force Quit and power loss bypass normal cleanup.

Independently enforced CLI file-read isolation needs its own feasibility and
product review.
The expanded grounding tests now cover long weekday/month changes, ordered
calendar markers, removed or invented negation in the supported languages,
amounts/codes, short names, faithful multilingual tidying and expansion, and
instructions spoken as content. Ambiguous words such as modal "may" need date
context; common Japanese negative endings are checked within unspaced clauses.
The focused run passed 18 test functions with 96 cases, and the integrated suite
also passes. Arbitrary long names, written-out quantities, negation scope, tense
and general paraphrase meaning remain limitations. Do not market these lexical
checks as a security sandbox or semantic guarantee.

## Data handling

The implemented batch addresses the most consequential data-loss paths:

- Saves compare exact content revisions, including same-timestamp external
  edits. Editors retain their original save baseline after a conflict.
- Copied note UUIDs remain distinct files in the library, search and command
  palette. Ambiguous UUID links open a chooser. Editing, action mutations,
  merging and appended recording refuse ambiguous ownership.
- Raw Markdown cannot change a note's UUID. Explicit managed renames rebind clean
  editors; an external rename never silently redirects an unfinished draft.
- All three draft types checkpoint exact UTF-8. Recovery opens a separate review
  surface and creates a new note with a fresh UUID, rather than replaying over
  the original. Completion intents and exact read-back distinguish a successful
  save from interrupted cleanup.
- Audio retention leaves unfinished/orphaned recovery recordings alone. Digest
  rebuilds preserve annotations and user task state. Failed Trash operations
  keep the note and report the failure.

There are deliberate limits. Unresolved checkpoints do not expire, backups and
Trash may retain copies, and abrupt termination can leave hidden staging files.
The interval after the latest completed checkpoint is not guaranteed. File
ownership is path plus UUID, not immutable inode provenance. A reloaded external
edit is valid current content; ordinary revision checking is not a transaction
with every other filesystem writer. Process-kill testing is not power-loss
testing. Recovery creation/export currently refuses unsupported ExFAT exclusive
publication while retaining its source checkpoint.

The storage overview described below exposes known locations and sizes; exports
cannot be inventoried reliably because their destinations are chosen by the user.
Deletion remains an explicit Library or Finder action, and deleting a live copy
does not erase backups. Never evict unfinished writing to meet a cache budget or
promise transactional durability against uncooperative concurrent writers.
The detailed acceptance boundaries are in [HANDOFF.md](HANDOFF.md).

Normal note writes now prepare private 0600 `.nook-write-<UUID>.tmp` files beside
the destination, revalidate an existing file immediately before replacement,
and exclusively publish new files. Recovery cleanup checks exact preview content
and file identity, including on retry after a rescan. A refreshed My notes model
cannot authorize an old draft through canonically equivalent but different
Unicode bytes. Deterministic tests interleave a competing writer and interrupt
preparation/publication. These protections still do not turn comparison and
replacement into a transaction with every other filesystem writer.

The subsequent merge/regeneration pass adds an explicit summary Cancel control
and immediate request invalidation. Results remain tied to the original folder
generation, including a change away and back to the same path. New transcript or
bounded summary guidance invalidates old output; newer user-owned fields are
preserved using exact UTF-8 comparisons. A fresh request can start after Cancel
without accepting late progress or completion from the previous request.

Merge inputs are captured only after raw Markdown has been deliberately settled
and personal drafts have saved. Both source revisions, folder generation and
target drafts are checked before publication and again around audio work and
cleanup. A queued merge also validates the generation captured by its UI action.
Confirmed saves refresh only a clean Markdown editor for the surviving file.
If the text saves but cleanup fails, both notes remain reviewable and a persistent
notice warns against merging them again. A failed post-publication read-back is
reported as uncertain, with no cleanup. A window-lifetime pair guard prevents
immediate repeated or reversed callbacks; it is not a durable receipt across
windows, relaunches or process loss.

Recording sidecars stay beside the captured recording, not the Library's current
folder. Recovery captures its original folder generation through extraction,
transcription, summarization, save and cleanup. Merge audio checks use regular-file
identity, size and modification/change timestamps around asynchronous work and
failed-Trash fallbacks. They avoid loading entire recordings on the main actor;
an external writer can still race a final check and file operation. Synthetic
regressions do not establish real microphone/system-audio, power-loss or live
merge-picker/cancellation acceptance.

The overlapping-first-export Reminders race is now corrected. A shared
main-actor coordinator reserves each action across Library controllers, checks
fresh persisted receipts after permission and merges successful receipts.
Cancellation releases a suspended request's reservation without letting its
late callback release or overwrite a newer retry. The source action, exact
revision, unchecked state, folder and generation are revalidated before export.
An unrelated successful export does not hide another action's failure. Tests
use an injected permission/save client and memory-only receipts, with no actual
EventKit access, system permission or Reminders save. Existing persisted key
format and title/due-date behavior remain compatible. Arbitration covers one
app process; a crash between an EventKit save and receipt persistence can still
leave a duplicate-export risk. It is not a cross-process or atomic transaction.

A native on-device regeneration in the isolated 969-test app exposed a separate
failure-provenance bug: the write-up failed but recovered transcript highlights
were returned as a success, replacing the existing summary and title. The
underlying model failure was not established; the old fallback wording could
mislabel any failure as a refusal. The correction carries the actual failure
through salvage, final validation and event logging. Regeneration retains every
existing field, while consumers of `.insights` can still use grounded fallback
content. Transcript-first capture retains its already-saved useful scaffold.
Eight deterministic tests cover 20 cases without invoking a model, including
six failure reasons, zero regeneration commits, exact Unicode preservation,
scaffold retention, cancellation and overflow retry. The native failure baseline
is retained under `.build/performance-review/native-replay-34c5d990/`.

The later 990 native replay exposed a different grounding gap. Its on-device
summary presented agenda indices as 18 participants, 18 minutes and 40 discussion
items. Prose previously received shape checks; list grounding also lacked numeric
context checks. The new deterministic guard indexes digit-bearing literals and
nearby spoken wording, including units, signs, percentages, currency symbols,
uppercase ISO currency codes and code punctuation. A rejected summary/title
becomes `.ungrounded`, preserving the existing note during regeneration;
unsupported list items are filtered individually. Transcript timestamps alone
cannot support a generated quantity. Original and generated synthetic sources
remain under `.build/performance-review/native-final-f5adc5a9/`.

Twelve new test declarations cover the captured invention, exact regeneration
retention, supported amounts/codes, dates/ranges, faithful sentence merging and
currency substitutions. Independent review corrected false rejections of normal
date/range/merged-sentence wording before final acceptance. This is a bounded
surface check, not proof of meaning: written-out numerical inventions and claims
that reuse the same local wording remain possible. Some legitimate paraphrases,
numeric reformatting or durations derived only from capture metadata can fall
back. Source-linked review of generated claims remains a product priority.

A subsequent 1,002 native run reported an ungrounded result and retained all
existing note content. The only file difference was removal of the final newline;
the exact stage of that normalization was not established. This is a content
retention result, not an exact-byte native pass. The raw generated answer was
not captured, so the numeric guard's particular branch is not established by
that run. The retained result exposed misleading first-capture copy claiming
only the transcript remained. Regeneration now has separate messages for all
thirteen failure reasons, starting with “Your existing note is unchanged.”
The final 1,003 integration verifies those messages and preservation behavior.
The Mac relocked before the canonical-baseline retry or final-copy replay; both
accessibility settings had already been restored. The older notice partly
covers the title in the captured window, leaving notice-layout acceptance open.
Receipt: `.build/performance-review/native-grounding-2754acc3/native-1002-regeneration-retention.json`.


The Settings storage overview counts metadata in known locations and reports
partial/unavailable scans. It includes current-library temporary save copies,
notes and recordings, active-identity drafts, known caches and logs. Review
actions lead to the existing Library controls or Finder; the overview never
clears unfinished writing or follows links. Exports, backups, Trash, other notes
folders and external CLI data are explicitly outside its inventory. Scans are
bounded and cancellable between filesystem calls; a stalled kernel call is not
subject to a hard timeout. Basic interactive acceptance passed in light and dark
appearances: counts matched the synthetic fixtures, long paths wrapped without
horizontal clipping, partial/missing states remained visible, and scrolling
reached the footer disclosures while Done stayed reachable. Return and Escape
closed the sheet, reopening worked, and Review in Library dismissed it and
called its harmless fixture callback once. Full keyboard, VoiceOver,
accessibility preferences, Finder reveal and minimum-screen acceptance remain
outstanding. No system settings were changed.

## UX and UI

The current pass fixes specific breaks in continuity: Today/All changes wait for
the raw Markdown save/discard/cancel decision; Cancel or save failure keeps the
previous range; background reloads and meeting-phase changes use the same editor
leave guard. Loading, load failure, an empty Today range and no search matches
have distinct explanations. Empty Today offers Show All Notes. Search feedback
occupies a compact, scope-aware sidebar row rather than an overlay that covers
other sections. The raw Markdown editor has an explicit accessibility name and
save/revert hint.

The earlier recovery pass also keeps actions visible in small windows, preserves
unfinished words when copies appear, and exposes failures where the person can
act on them. These are central to design quality: a quiet-looking notebook must
also make its state and consequences understandable.

The later design pass reproduced a command-palette focus failure: typing a
query changed My notes behind the overlay. It now uses a native sheet with
initial query focus and Close/Escape. Other commands execute after dismissal;
Ask now reuses the sheet. The
original synthetic note was restored exactly. Shortcut hints follow the actual
bindings, and action rows refresh while open. Native checks on the 849-test
binary verify query isolation, My notes caret/selection restoration, raw
Markdown and sidebar-search selection restoration, native Undo, and an unchanged
source-file hash. Ask received final focus. The recorded cases are in
`.build/performance-review/design-ui-80331fe5/palette-native-849-acceptance.json`.
That run also found missing Quick Note editor focus and overridden palette
query/Close names. Both were corrected and verified on the 870-test app in
`.build/performance-review/design-ui-80331fe5/native-870-acceptance.json`.
Quick Note accepts immediate typing on cold-open and re-raise, retains its text,
and eventually saves. Native Undo grouped both typing episodes together; Redo
restored the exact whole group. A stale empty-note warning briefly appeared
after Redo. The native 875-test rerun verifies cold focus, exact saved text,
the empty warning, exact Redo and warning clearance before Saved. That rerun
also found that an empty saved pad instructs the person to choose Discard while
the control is disabled. The correction is included in the 881-test build with
six new tests using fake confirmation/deletion. Its native check verifies a new
empty pad keeps Discard disabled, while Undo from exact saved text to empty
shows the warning and enables Discard. Redo restores the exact words and clears
the warning before Saved; original fixtures remain unchanged. No Discard click
or real Trash action was performed. Toolbar/backdrop, additional shortcut variants,
live data refresh, parent teardown, complete keyboard traversal and VoiceOver
remain open. The
[design acceptance ledger](DESIGN_ACCEPTANCE_2026-08-31.md) records A1 as partial.

The native window presenter passes uninstrumented cold/warm immediate
Cmd-K then `discard` without a readiness wait on the 901 build. The later
902-build receipt passes 14 native checks: My notes selection and exact dirty
Markdown/selection survive dismissal; command dispatch opens Save/Discard/Cancel;
Cmd-K during that alert is not queued; Cancel retains the draft; Undo restores
the exact 11,705-character original and disables Save/Revert. Many results can
become empty, where Return does nothing, then one safe note, where Return
navigates. The original file hash remains unchanged. Settled short and
single-result layouts pass at 560 × 121; first-painted-frame appearance remains
unverified. The receipt is
`.build/performance-review/design-ui-80331fe5/a1-902-acceptance.json` (ledger E25).
AttributeGraph cycles remain unattributed; the aborted debugger attach yielded
no backtrace. A1 remains partial, including physical backdrop, toolbar-origin
focus, additional shortcut variants, live data refresh, parent teardown and full keyboard/VoiceOver.

Additional 902 native checks retain their arrows/search-selection and direct/
settled Ask passes. A subsequent 913 baseline reproduces empty immediate Ask
input and changed parent selection while the toolbar control passes. New source
replaces palette content with Ask inside the same sheet, with a deterministic
actual-hosting-view immediate-input test. Another 913 baseline confirms Settings
shortcut recording swallowed Library search typing after a mouse window switch.
Recording now uses the exact host, cancels on key loss/deactivation/close/detach,
arbitrates one recorder per window and clears cancellation state. The 934 suite
passes. The later 969 native replay verifies immediate palette-to-Ask typing,
exact parent-selection return, recorder window switching, same-window
arbitration, Escape, and a customized Shift-Cmd-K handoff. Default shortcuts
were restored. Full-Library refresh, parent teardown and assistive input still
need live acceptance.

A third 913 baseline exposes indistinguishable duplicate filing choices through
AX only; neither target was clicked and the screenshot omitted the popover.
The new filing guard excludes ambiguous/stale destinations, preserves a warning
when the target saves but quick-note-copy removal fails, and starts the next
draft fresh. Its tests use synthetic files/fake deletion. Two offscreen renders
at 380 × 240 in light/dark verify the complete two-line warning, Review in Library,
Dismiss, empty editor, provider control and Done fit. Before/after validators
verify one target append, exact retained source and a fresh pad. This is not
native filing, window-lifetime, action, focus or real Trash acceptance. Ledger
E29–E32 preserves the baselines and visual/deferred-native receipts. E34 adds a
969 native replay: copied UUIDs are excluded, an independent target remains,
and Review Copies followed by pad re-raise retains the exact saved text. No
filing target or Trash action was invoked. The menu screenshot omitted the
popover, so its layout remains unverified.

Ten static fixtures on the 870-test build verify full Markdown conflict
instructions and Save/Revert at 900 × 580, normal failure text and Dismiss at
560 × 180, bounded pathological failures, transcript transport with no matches,
and Quick Note conflict controls at 380 × 240 in light/dark, including the Codex
warning. Native playback used generated digital silence: its clock advanced
with no search matches, Stop remained reachable, and tab departure stopped it.
An actual detail error remained visible for 25.81 seconds until Dismiss, while
the original file hash stayed unchanged. These checks do not establish real
capture, audio quality, screen-reader behavior or preference-dependent visuals.

A separate light/dark notice fixture verifies long/short reflow and scrolling
to the final instruction with Dismiss outside the scroll region. Repeating a
long result exposed retained bottom scroll position even with a new UUID.
The host-identity correction passed a separate 875-test integration. Its dark
560 × 300 native repeat verifies a fresh identical long result starts at the top
after the prior result was scrolled to the end; Dismiss remains reachable and
clears it. The receipt is
`.build/performance-review/notice-ui-7a95b865/identity-acceptance.json`.
Earlier light/dark scrolling and reflow observations retain their original
scope; this does not establish all notice variants or VoiceOver.
Final uninstrumented replay uses production `LiveMeetingView` at 900 × 650 with
synthetic updates only. Light appearance passes growth, focused-passage Page Up,
stable visible history through Append/Partial, Jump return, native bottom
reattachment, paused reopen without a revision, shrink to one and reset without
a false Jump. Dark appearance passes direct 60-to-one visibility. Four final
screenshots were archived immediately and inspected. The eager outer stack and
measured visible rectangle resolve the recorded cases that the clamp candidate
did not. The receipt is
`.build/performance-review/live-follow-ui-6494a046/interaction-final-acceptance.json`;
ledger E17–E20 retains the baselines. No real capture, VoiceOver, physical-momentum,
resize/compact or latency pass is implied.

Ask now keeps each answer or refusal paired with its submitted question while
the field can hold the next draft. External dismissal cancels work and rejects
late results, including retries of the same question. Library-folder changes
close Ask and the palette and reject stale callbacks; opening refuses retained
models from another folder. Synthetic snapshots verify answer/refusal attribution
in both appearances. A long question previously hid Cancel during progress; it
now scrolls while Cancel remains visible at 560 × 380. No model was invoked.

Custom prominent buttons now use readable dark ink on the dark-mode blue fill,
and their pressed fill preserves contrast. Resolved-color tests meet 4.5:1 for
enabled idle and pressed text in normal/high-contrast AppKit appearances.
Reduce Motion suppresses custom press/status scaling and Quick Note reflow;
Increased Contrast strengthens custom outlines and dividers. These tests
verify policy and color resolution, not real preference changes or VoiceOver.
The 902-build refinement extends Reduce Motion to compact/hidden panel presses
without removing fill/opacity feedback. Flag acknowledgment changes to a
checkmark, and hidden paused status uses a pause glyph instead of color alone.
Six offscreen renders verify the unchanged panel footprint and light/dark
recovery at 360 × 580, including two fully wrapping filenames, filename-specific
Finder names, explicit primary title text and reachable controls. Their receipt,
`.build/performance-review/design-integration-20260831/panel-accessibility/foreground/visual-acceptance.json`,
does not establish real pressed states, key-window appearance, system preferences
or VoiceOver. Remaining live control/window variants and the complete
accessibility matrix remain outstanding.

The 913 batch adds ten offscreen renders: unavailable/running/stopping Quick
Note and Codex conflicts at 380 × 240 retain the full synthetic note, warnings
and controls; unavailable Settings chooser/footer fits at 620 × 540. The
animated spinner and offscreen segmented header are excluded. Separate native
913 Settings checks pass the real header, chooser and persistent-default footer
in light/dark at 620 × 628; provider menu choices name recipients and Escape
keeps On this Mac selected. Dictation remained off. Immediate palette query and
safe Return pass, the original file hash stays unchanged, and the isolated app
returns to Light with Settings closed. No provider, OS preference change or
active-CLI Quit was exercised. See ledger E26–E27.

For the Apple Design Award quality ambition, prioritize the following acceptance
work. These are proposed quality gates, not claims of completed verification:

| Area | Required experience |
| --- | --- |
| Keyboard and VoiceOver | Complete capture, note editing, conflict resolution, recovery and playback with clear focus and a predictable Return/Escape contract. |
| Reading and writing | Comfortable text size and line length, a quiet writing surface, useful hierarchy, and reachable actions at the minimum supported window size. |
| State continuity | Selection, cursor and unsaved words survive search, scope changes, background processing, window reopening and failures. |
| Status and consent | Recording, pause, saved, saving, failure and local/external processing are distinguishable without color. Never imply successful save before it completes. |
| Materials and motion | Native materials belong to navigation and controls; writing remains legible. Test both appearances, Reduce Motion, Reduce Transparency and Increased Contrast. |
| Large content | Realistic long notes remain editable; transcript navigation and assistive hierarchy traversal scale without hiding content. |

Apple's design guidance emphasizes platform conventions and accessibility, and
the 2026 awards recognize interaction and inclusivity alongside visual craft.
An award is not guaranteed by a visual style or feature count.
[Mac design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/),
[accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility/),
[2026 awards](https://www.apple.com/newsroom/2026/06/apple-reveals-winners-of-the-2026-apple-design-awards/).

## High-value feature recommendations

These are hypotheses to validate with frequent dictation users and people who
spend substantial time in meetings. Effort estimates are rough ranges for one
experienced Mac engineer with design support; release acceptance is additional.
Major features need a public proposal before implementation.

| Priority | Feature and unmet need | Scope and estimated effort | Acceptance and privacy constraints |
| --- | --- | --- | --- |
| 1 | **My vocabulary:** stop correcting the same names and specialist terms. | Local terminology/replacement editor, per-app overrides, import/export and a test phrase. Start with transparent deterministic replacements; investigate Apple Speech hints separately. 2–3 weeks. | Explicit reversible rules, Unicode and boundary coverage, no silent rewriting of old notes. Do not mine Contacts, clipboard or documents. |
| 2 | **Show the evidence:** verify why a decision or action was written. | Passage-level source links on decisions/actions and precise Ask citations, tied to the source file revision, with optional audio jump. 3–5 weeks. | Supporting words reachable in at most two actions. Changed files show stale-source state. No invented speaker/owner/date; no extra audio retention. |
| 3 | **Review, then prepare:** make the next sitting start with the right unfinished work. | Optional compact post-meeting review; confirm owners/dates and carry reviewed open commitments into existing Prep and Open actions. 2–4 weeks. | Completed tasks do not return as open; unstated owners/dates stay empty. No automatic assignment, messaging or Reminders export. |
| 4 | **Last dictation, recover or correct:** avoid repeating a thought after an insertion or rewrite mistake. | Memory-only latest-utterance card with original/delivered wording, Copy, Save as Note and explicit retry. 1–2 weeks. | Never insert into a newly focused field or retain secure-field attempts. Clearly disclose expiry; successful utterances get no persistent history by default. |
| 5 | **Useful meeting templates:** different meetings need different outputs. | User-authored local headings/review sections, optional series default, preview before applying to an existing note. 2–3 weeks. | Preserve annotations and task state; remain useful without a model. Template instructions cannot weaken guards or select an external provider. |
| 6 | **Share only what I meant:** produce a useful recap without exposing the private notebook. | Preview and choose summary, decisions and tasks; Markdown/rich text first. 1–3 weeks. | My notes, transcript, audio and local paths excluded by default. Verify excluded content is absent from output and metadata. Destination chosen explicitly. |

Do not reintroduce existing features as new work. Nook already has per-app
dictation styles, hands-free Quick Note, fixed template starters, local note
actions, flagged moments, transcript search/audio playback, meeting-level Ask
citations, weekly digests, action dates/completion, Reminders export, recurring
prep and a command palette. The opportunities above extend their missing parts.

Primary product documentation provides useful signals, not proof of user demand:
Superwhisper documents vocabulary/replacements and original-versus-processed
history; Granola exposes the passage behind enhanced notes; MacWhisper pairs
local speaker grouping with user correction. Nook can adopt the interaction
benefits without adopting cloud storage, indefinite history or identity claims.
[Superwhisper vocabulary](https://superwhisper.com/docs/get-started/interface-vocabulary),
[history](https://superwhisper.com/docs/get-started/interface-history),
[Granola evidence](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes),
[MacWhisper speakers](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper).

After these, validate demand for direct transcript correction with summary
invalidation, project-scoped search/Ask, and explicit local audio/subtitle import.
Defer cloud meeting bots, team workspaces, autonomous follow-up, ambient recording,
screen-context collection, voiceprints and a full task manager. Mobile capture
and sync require a separate conflict, encryption and retention design.

Interview five frequent dictation users and five meeting-heavy users on realistic
tasks. Observe correction effort, time to find evidence, follow-up completion and
recovery success. Ask for voluntary feedback rather than adding telemetry.

## Verification and what remains

The August 31 integration, before the September 1 follow-up above, reports **1,015 passed, zero failed
and zero skipped**, with warnings treated as errors, plus two passing Python
script tests. The record is
`.build/performance-review/design-integration-20260831/library-identity/attempt-01/build-acceptance.json`;
all 145 source/project fingerprints remained unchanged. Snapshot and optimized
builds also pass with warnings as errors. Six new declarations cover identity
capture and refresh, copied values, original URLs, Foundation/Unicode paths,
optional/inout/key-path writes, equality/hash compatibility and filesystem
changes. All ten Library identity test cases are present and pass in the Xcode
result. The preceding 1,009 batch's byte-preserving personal-note saves,
conflict/replacement/Unicode guards, recovery reconciliation and native editor
continuity through notice changes remain covered. The preceding 1,003 result
contains the numeric-grounding and retained-message corrections; the 990 result
already included Reminders and summary-provenance corrections. Dynamic
parameter executions are recorded separately in Xcode, not added to that count.
The UUID-prefilter and captured-identity component benchmarks are not native
smoothness passes. The latter's subsequent Release app comparison now confirms
less repeated normalization and a shorter 253 ms Library pause, with exact
saves and cached-build native Undo/Redo. Typing work is essentially unchanged;
list/layout work and the separate long-paragraph stall remain open. One native
pair does not establish general responsiveness or minimum-hardware acceptance.

The 969 native replay now verifies immediate palette-to-Ask input and exact
selection return, recorder window switching/arbitration/Escape, customized
shortcut handoff, duplicate filing-target exclusion and saved pad retention
through Review Copies/re-raise. No actual filing or Trash was invoked. A real
on-device regeneration exposed the fallback-provenance failure, retained as
baseline evidence; a second attempt exercised Cancel with its source unchanged
after 99.52 seconds. The 990 correction has deterministic regression evidence.
The later 990 native replay passes scoped Keyboard Navigation checks for Ask,
selection return, fresh-editor Tab/Undo and storage traversal/dismissal. The
regeneration completed as success but invented numeric facts; the captured
output is retained as a grounding failure baseline. Both temporarily enabled
system settings were restored. VoiceOver speech/cursor acceptance remains open.
Receipts: `.build/performance-review/native-replay-34c5d990/`
and `.build/performance-review/native-final-f5adc5a9/`.

The final integration corrected a test macro's Sendable-closure compilation
issue and a synthetic decision fixture missing a supported decision phrase.
Production grounding was not weakened. The 990 passing run followed both fixes.
The initial numeric guard then passed 999 tests but was withheld after independent
review found common wording false rejections and a currency-code gap. Three
additional test declarations and bounded corrections yield the accepted 1,002
result; independent source re-review found no further blocking issue in scope.
The final retained-message correction then passed the 1,003 integration.
The next native follow-up reproduced the terminal-newline loss through a
whitespace-only personal draft save: three variants fail before the correction.
The store now verifies an unchanged field against the existing file/revision
without re-encoding it, and recovery completion references those original bytes.
No global Markdown serialization policy changed. The historical UI event that
introduced the whitespace remains unproven.

The 1,009 native replay deliberately inserts a trailing Return in My notes,
starts on-device regeneration, verifies My notes is Saved during the first
progress stage, and activates Cancel. All 11,719 source bytes, including the
terminal newline, are unchanged during progress and 257.10 seconds after Cancel.
Two preceding attempts completed successfully and legitimately rewrote their
summaries; those outcomes are not claimed as retained-byte evidence. A real
title-validation failure now occupies its own space above the title. Dismiss
preserves the selected word and exact saved source. A separate native dark
fixture verifies long/short/long replacement, the corrected retained-note copy,
and selection through Dismiss. The fixture's copy is synthetic, not a fresh
model-backed refusal. Receipts:
`.build/performance-review/native-notice-b9d4aaf2/native-1009-notice-newline.json`
and `.build/performance-review/notice-layout-2dd2441a/native-1009-notice-layout.json`.
Six notice/detail renders pass their scoped light/dark layout checks; two
additional offscreen Library sidebars render blank and do not establish sidebar
acceptance. Actual native sidebar/toolbar layout was visible. Both new fixture
apps closed normally, with no new system-setting or permission changes.
Concurrent Library/detail failures at minimum height and VoiceOver announcements
remain unverified.
Earlier 969 summary-progress and 934 filing-warning renders retain their original
static scope. None of these results closes the remaining full accessibility,
hardware, large-content or release gates.

Native 870-test checks verify the corrected palette names, Quick Note cold-open
and re-raise focus/typing, silent-audio no-match playback/Stop/tab departure, and
persistent detail failure/Dismiss with the original file unchanged. Earlier
849-test checks verify palette query isolation and editor/search restoration.
Basic storage acceptance also passed in its recorded fixture. Later 875-test
native checks verify the Quick Note empty warning clears on exact Redo before
Saved, and the separate dark notice fixture verifies new identical results reset
from the old bottom to the top. The notice host-identity correction has its own
accepted 875-test build receipt. The 881-test native check verifies corrected
Discard eligibility for an empty saved pad, exact Redo and warning clearance,
without clicking Discard or invoking Trash. Six new fake-confirmation/deletion
tests cover the guards; that is not a live deletion pass.

Native 902-build checks now verify the editor selection/exact Undo, dirty-draft
alert and many/empty/one-result cases described above without instrumentation.
Settled short/one-result layouts pass; first-painted-frame appearance remains
unverified. Earlier 901-build immediate-input and transcript replay receipts
retain their stated scopes. AttributeGraph cycles remain unattributed; no
blanket native pass is claimed. Full A1, physical backdrop/toolbar-origin behavior,
additional shortcut variants, live data refresh, parent teardown, VoiceOver,
real preferences, capture and broader accessibility acceptance remain incomplete.
The additional 902 immediate palette-to-Ask boundary has a later 913 failure baseline; its 934
correction now has the scoped 969 native replay above. Ten 913 offscreen
assistant/conflict renders and native Settings/menu/query checks retain their scope, not active-provider
Quit, final-save-alert or complete accessibility acceptance. The 969 handoff,
recorder and filing-menu replay does not establish actual filing/Trash or
physical modifier-only input. No release or commit was made.

Successful earlier native checks followed locked attempts and correction of an
isolated Debug fixture missing `Nook.debug.dylib`. That was fixture packaging,
not a production defect or proof of current desktop availability. The latest
990 native replay followed that locked attempt. Keyboard Navigation and
VoiceOver were temporarily enabled with approval, then restored off. Full
Keyboard Access stayed off. Automation did not establish screen-reader feedback,
and macOS still reported no microphone found. Remaining palette variants, enabled-button
inspection, complete keyboard/VoiceOver and real accessibility-setting checks
remain open in the
[design acceptance ledger](DESIGN_ACCEPTANCE_2026-08-31.md).
Project generation uses pinned XcodeGen 2.45.4. No release or commit was made.

Isolated full-app acceptance verified Cancel, exact save-before-scope-change,
external conflict refusal with both versions retained, and recovery of that
retained draft after the synthetic conflict was resolved. Show All Notes kept
the query and found the archive result. The final empty-search presentation and
Markdown accessibility label were inspected in the actual app. Earlier recovery
and process-kill evidence is detailed in [HANDOFF.md](HANDOFF.md).

Full-app force-quit/relaunch recovery now covers Markdown, My notes and Quick
Note. Each verified its completed checkpoint before termination, recovered exact
text into a new note with a fresh UUID, preserved the original sources, and
removed only the completed checkpoint. The My notes case includes decomposed
Unicode. These checks do not establish power-loss durability or cover every
interruption point during save, folder switch and cleanup.

The cached-count, background-count and contiguous-snapshot traces are complete.
They establish the rendering improvement, off-main-thread calculation and
reduced repeated comparison costs while exposing the
remaining long-pad costs described above. Regression coverage verifies stale
results, burst coalescing, Unicode whitespace, pending-count discard safety,
failed deletion, checkpoint/save independence and worker teardown. Native
snapshot tests preserve exact UTF-8, selection and earlier snapshots after
later storage edits.

The optimized app builds, source fingerprints and local traces are retained
separately for each measured version. Both isolated profile apps are closed and
their unique preference/support state is archived outside the active app paths.
Capture, calendar, dictation, providers and updates were disabled. Normal app
identities, notes and permissions were not changed. Final native Undo/Redo and
exact saved text were verified in the isolated app.

Release acceptance still requires real capture, permissions, long dictation,
external hardware, full keyboard/VoiceOver and an installed update. Those checks
are not implied by the passing synthetic suite or the instrumented comparison.
