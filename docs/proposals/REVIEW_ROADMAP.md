# Review follow-up proposals

These are reviewable drafts, not shipped features or validated demand. The
engineering fixes and measured evidence are tracked in
[the August 31 review](../REVIEW_FOLLOWUP_2026-08-31.md). Major product or
architecture changes must be proposed publicly before implementation. The
native text-layout investigation was published on September 1, 2026 as
[issue 15](https://github.com/wrnsnng/nook/issues/15), before its implementation.
The other proposals below remain drafts unless they link an existing issue.

The existing public issues were checked on August 31, 2026. Evidence-linked
summaries already have [issue 10](https://github.com/wrnsnng/nook/issues/10);
checklists and fixed template starters already have
[issue 8](https://github.com/wrnsnng/nook/issues/8). Extend those discussions
where appropriate instead of presenting implemented features as new proposals.

## Faster opening of large libraries

**Problem:** the measured 1,000-note synthetic library still needs about three
seconds of cold decode work. Constructing every transcript segment before the
library is usable makes reading one recent note depend on decoding all notes.

**Proposed outcome:** load identity and sidebar metadata first, then decode
full note content when reading, searching or acting on it. Markdown remains the
source of truth; any index is disposable derived data. Do not combine this with
a new storage format, sync system or database migration.

Start with an architecture spike comparing a metadata parser and deferred full
decode against the current loader, on identical files. Reading bytes to verify
an exact content revision remains necessary; timestamps and file size alone
cannot authorize a cache hit. Metadata entries must carry canonical file path,
UUID and full-content revision, including when multiple files share a UUID.

Required behavior before integration:

- Explicit unloaded/loading/ready/failed states. Missing decoded content must
  never look like an empty transcript, empty summary or successful search.
- No save, merge, append, task mutation, summary generation or export from a
  partial model. Load the complete exact source first and retain conflict guards.
- Search covers unloaded notes and reports progress; it must not silently search
  only what the person has opened. Cancelled searches stop obsolete work.
- Background results are rejected after folder changes, file replacement,
  same-timestamp edits, deletion and managed or external rename.
- Keyboard focus, selection, accessible result counts and drafts survive loading.
- Corrupt or obsolete index data is discarded without changing Markdown or
  unfinished drafts. No content index is sent off the Mac.
- Measure time to usable library, opening a long transcript, complete search,
  peak memory and rebuild time. Report cold and warm runs separately. A faster
  sidebar that delays or loses search does not satisfy the proposal.

**Decision needed:** publish the architecture proposal, then review the spike's
correctness and performance evidence before replacing the loader.

## Native text layout for long paragraphs

**Problem:** after reducing Nook's counting and comparison costs, an enormous
single paragraph still produces substantial native layout/selection work.
An isolated AppKit experiment reproduced the difference without Nook's saving,
recovery, SwiftUI or task suggestions.

Across three trials of the same 20,000-word paragraph and 32-character insertion,
cumulative synchronous key-handler time averaged 895.6 ms with TextKit 2 and
96.5 ms with explicit TextKit 1. Both restored exact text and selection through
Undo/Redo. TextKit 1 with noncontiguous layout averaged 99.4 ms, giving no clear
extra benefit. At 200 paragraphs, the corresponding means were 86.6, 76.5 and
74.8 ms. Actual text layout width was 407 points in every trial. These are
synthetic handler measurements, not end-to-end input latency or a shipping-app
speedup. The production editor was unchanged during that experiment.

**Proposed investigation:** compare explicit engine construction in an isolated
Nook integration after publishing this proposal. Never inspect `layoutManager`
on a live TextKit 2 view to test its engine: that can trigger a compatibility
switch. Do not change engines mid-edit, insert paragraph breaks into a person's
text, or disable valid layout for difficult content.

Required acceptance before adopting another engine:

- Realistic typing cadence and start/middle/end insertion, deletion, selection
  replacement, scrolling and resizing on ordinary and large notes.
- Exact save/reload, Undo/Redo grouping and selection, including NFC/NFD, CRLF,
  emoji and bidirectional text. The existing composed-café fixture does not
  establish this broader coverage.
- Japanese, Chinese and Korean composition, dead keys and marked-text updates,
  plus dictation insertion and checklist commands.
- Keyboard navigation and VoiceOver reading/editing without lost content or
  misleading caret position. Faster accessibility enumeration is not permission
  to omit text.
- Minimum supported hardware, memory and end-to-end input/caret measurements.
  Retain the current engine if the improvement causes correctness regressions.

**Status:** the investigation was published as
[issue 15](https://github.com/wrnsnng/nook/issues/15) before implementation. The
September 1 candidate explicitly creates TextKit 1, preserves marked text during
unrelated updates and transports exact Unicode replacements. Its integration
passes 1,040 tests; the focused native-editor suite has 18 declarations and 30
parameter cases. Actual app Save/Undo/Redo passes both 20,000-word fixtures.
The [release acceptance record](../RELEASE_1.20.0_ACCEPTANCE.md) records the
remaining physical input, VoiceOver, hardware and publication gates. The
standalone prototype alone is not approval to ship the integration.

## Personal vocabulary for dictation

**Problem:** recurring names and specialist terms create repetitive corrections.

**First useful scope:** a local editor for explicit replacement rules, with a
test phrase, per-app overrides, import/export and immediate disable/undo. The
person supplies the terms; Nook does not mine Contacts, clipboard, recordings or
documents. Start with deterministic replacements, not another model call.

Acceptance includes word boundaries, NFC/NFD, mixed scripts, overlapping rules,
case choices, numbers, empty replacements and secure-field refusal. Show what
will change before enabling an imported rule set. Never rewrite existing notes.
Validate the workflow with frequent dictation users before expanding it to
speech-recognizer vocabulary hints.

## Evidence behind decisions and actions

The 990 native review produced a fluent but unsupported summary that turned
agenda indices into participant counts and duration. The validated numeric guard
addresses that bounded failure; it cannot establish every sentence's
meaning. This strengthens the case for source evidence on summary claims as
well as decisions and actions. Generated fluency must not stand in for proof.

Extend issue 10 with passage-level links tied to both file identity and source
revision. A decision/action opens its supporting words in at most two actions,
with a keyboard route back to the originating item. Audio jumping is offered
only when retained audio exists; it must not enable retention implicitly.

Distinguish supported, unsupported and stale evidence. A changed source must
invalidate the old link rather than silently pointing at unrelated text.
Do not invent an owner, speaker identity, date or supporting quote. Keep personal
annotations distinct from generated claims. Test duplicate UUIDs, transcript
correction, missing audio and partial/fallback summaries.

## Review a meeting and prepare for the next one

Add an optional compact post-meeting review to the existing Prep and Open actions
flows. People confirm decisions, owners and dates, then carry only reviewed open
commitments forward. Unstated owners/dates remain empty, and completed tasks must
not return as open. Reopening or regenerating a review preserves personal notes
and task state. No automatic assignments, messages or Reminders writes.

Validate whether people prefer this immediately after a meeting or when preparing
for the next sitting. Use explicit feedback rather than adding telemetry.

## Recover or correct the last dictation

Offer a memory-only latest-utterance card with original and delivered words,
Copy, Save as Note, and explicit retry. Explain its expiry and replacement by the
next utterance. Successful utterances have no persistent history by default.

Never retain secure-field attempts, retry into a newly focused field, or claim an
insertion succeeded merely because text was transcribed. Test focus changes,
clipboard restoration, unavailable target apps, cancelled rewriting, quit and
memory cleanup. Saving requires an explicit action and the normal draft guards.

## User-authored meeting templates

Extend fixed template starters with local headings and review sections, optional
series defaults, and a preview before applying to an existing note. Templates
remain useful without a model. Preserve annotations, checklist state and the
source revision. Templates cannot select an external provider or weaken output
guards. Test applying to a nonempty note, cancelling, Undo and conflicting edits.

## Share only selected meeting content

Provide a preview that selects summary, decisions and tasks, with Markdown and
rich text as the initial formats. Personal notes, transcript, audio and local
paths are excluded by default. The destination is chosen explicitly; there is
no automatic sending. Verify exclusions in actual output and metadata, including
citations and filenames. Preserve the local note and its private annotations.

## Demand and release evidence

Interview five frequent dictation users and five people with many meetings using
synthetic or voluntarily supplied tasks. Observe correction effort, evidence
retrieval, follow-up completion and recovery success. These interviews have not
been conducted; feature priority remains a hypothesis.

None of these proposals replaces real capture, long-session memory/energy,
permissions, VoiceOver, external hardware or installed-update acceptance. Use
[HANDOFF.md](../HANDOFF.md) for the release checklist. Cloud meeting bots, team
workspaces, ambient recording, voiceprints and mobile sync remain outside these
proposals and require separate product/privacy designs.
