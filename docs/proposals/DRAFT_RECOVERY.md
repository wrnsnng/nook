# [Feature]: Recover unfinished writing after Nook closes unexpectedly

**Status:** Proposed publicly in [issue #14](https://github.com/wrnsnng/nook/issues/14).
This file records the design and acceptance criteria. The first phase was
included in [1.20.0](https://github.com/wrnsnng/nook-releases/releases/tag/v1.20.0),
published September 1, 2026; the release listing was checked September 4.
Publication does not establish completion of manual acceptance. Automated
regression checks and light/dark snapshots are recorded; manual Mac acceptance
remains in
[`../HANDOFF.md`](../HANDOFF.md).

## Problem

Nook protects unfinished writing during normal navigation and quit: refused
personal-note saves remain in memory, the Markdown editor asks before leaving,
and the quick note pad refuses to close when it cannot save. These safeguards
do not survive a crash, force quit, or restart. A file conflict can leave the
newest writing only in memory for much longer than an ordinary autosave delay.

Live meeting notes have a separate recovery sidecar beside the recording. That
mechanism does not cover edits to saved notes, parked personal-note drafts, raw
Markdown edits, or the quick note pad. Extending recording recovery directly
would also put these drafts under the wrong lifecycle and cleanup rules.

## Proposed outcome

Keep a local recovery checkpoint for each unfinished edit and make surviving
checkpoints discoverable after the app restarts. The first phase recovers the
user's words without deciding how to reconcile them with a file that may have
changed or been deleted elsewhere.

The existing note remains authoritative. A recovery checkpoint is a separate,
temporary copy of unfinished writing, never permission to overwrite that note.

## Phase 1: review, copy, save a new note, or discard

Add a small **Recovered drafts** section beside recording recovery in the
library, visible only when there are checkpoints from an earlier app session.
Each entry identifies the editor, note title when known, last checkpoint time,
and original library. A draft from a different library remains visible with
that location stated; switching folders must not hide the only surviving copy.
Content is not shown in system notifications.

Opening an entry presents a read-only, selectable preview with these actions:

- **Copy:** Copy the recovered text on request. Explain that copying puts it on
  the system clipboard, where other software may read it. Copying does not
  remove the recovery checkpoint.
- **Save as New Note:** Create a separate note in the explicitly displayed
  current library, using a new UUID and a collision-safe filename. Do not
  append to, replace, restore, or recreate the original file. Confirm the write
  and read it back before marking the recovery complete.
- **Discard Recovery Copy:** Ask before removing the checkpoint and state that
  the original note is unaffected. Prefer moving the recovery file to the
  Trash so a mistake remains reversible. If that fails, retain the entry and
  show the failure; do not silently unlink it.
- **Close:** Leave the checkpoint unchanged. Dismissing the preview is not a
  decision to discard it.

Saving raw Markdown needs one additional boundary. Two files cannot inherit
the same Nook note UUID. A safely parseable raw draft can be cloned with only a
narrowly validated identity replacement, preserving its other source bytes,
including unknown frontmatter and sections. If that cannot be done safely,
offer **Copy** and **Export Source** instead, explain why a new library note
cannot be created yet, and retain the checkpoint. Export Source writes the
exact editor text as a `.txt` file chosen with a native save dialog. Do not
re-encode malformed source into an apparently successful but lossy new note.

Recovered entries are separate from the live editors. Launch, library reload,
selection changes, and quit must never place them into the personal-note
controller's automatically retried parked drafts, open a quick note pad, start
dictation, or run an assistant action. The app must be able to quit while an
unreviewed recovery remains safely on disk.

## What a checkpoint contains

Use a versioned, typed record with a stable draft identifier, editor kind,
creation time, checkpoint time, current text, and the original context. Preserve
text exactly as held in the editor, including an empty replacement for a
nonempty original. A select-all-delete is an edit, not a reason to fall back to
an older checkpoint.

| Editor | Original context retained with the edited text |
| --- | --- |
| My notes | Library identity, original file URL, note UUID, note title, and the original `savedText` used by the field's conflict check |
| Markdown source | Library identity, original file URL, note UUID, note title, `originalMarkdown`, and the exact content revision captured by the same read |
| Quick note pad | Stable draft UUID and start time; for an already saved pad, its original note identity, complete saved base, and content revision |

The content revision is the existing SHA-256 digest of file bytes, not its
modification date. A reload cannot substitute a newer revision or personal-note
baseline into the checkpoint. That would turn recovery into permission to erase
an external edit.

Library identity includes the captured standardized, symlink-resolved directory
URL. Original file identity includes its captured path and note UUID. UUID alone
is insufficient: copying a library copies its note identifiers. Never derive a
checkpoint's owner from whichever `storageURL` happens to be selected when an
asynchronous write eventually finishes. Any later migration of these identities
needs an explicit design; a renamed or unavailable library does not authorize a
guess at the destination.

A new quick note receives a stable draft identifier before its first checkpoint
or save. Record enough completion evidence to recognize a crash after its note
was successfully written but before its checkpoint was removed. Match the
intended destination, fresh note UUID, and expected content revision; identical
text elsewhere is not sufficient proof.

## Checkpoint timing and ordering

Proposed initial scheduling targets are a checkpoint after 400 ms without an
edit and at least once every 2 seconds during sustained editing. Flush pending
state before orderly editor replacement, library changes, and normal quit.
These are targets to validate under load, not a guarantee that the final
keystroke survives process termination or a power failure.

An idle-only debounce is insufficient because continuous dictation can keep
postponing it. Equally, writing a large Markdown document synchronously on every
keystroke would make the editor worse. Use one ordered writer with immutable
snapshots, coalescing superseded pending checkpoints per draft. Measure typing
latency and large-document write cost before finalizing the intervals.

The following ordering rules are required:

1. Capture text, owner, original baseline, and revision as one consistent state.
   Programmatic loads set multiple properties; their intermediate values must
   not produce a checkpoint under the previous note's identity.
2. Accept only the newest revision for a given draft. One unstructured task per
   edit is not an ordering mechanism.
3. Saving or discarding invalidates outstanding writes before cleanup. A late
   checkpoint cannot recreate an entry that was already resolved.
4. Write atomically within the private recovery directory. If a write fails,
   preserve the previous complete checkpoint and the current in-memory edit.
5. Remove or resolve a checkpoint only after the intended note write succeeds
   and read-back verification passes. A crash between those steps must be safe
   to reconcile without creating a second recovered note.
6. Keep current-session checkpoints out of the recovered list. They remain
   owned by their live controllers until restart; ordinary typing must not add
   a duplicate recovery card beside the note being edited.

Checkpoint failure is visible but nonmodal: explain that the latest writing
could not be protected for recovery, keep ordinary saving available, and offer
a retry. Do not claim **Saved** for a successful checkpoint; that label means
the actual note file was written. A checkpoint timestamp must mean the write
completed, not merely that work was queued. Cleanup failures remain visible
until resolved instead of silently disappearing from the list.

## Deletion, conflicts, and library changes

Deleting a note through Nook invalidates pending writes for that note. If
deletion also removes unfinished writing, the confirmation must explicitly
include those recovery copies. Resolve the matching checkpoints only after the
original was successfully moved to the Trash; otherwise retain them as
unavailable-original recoveries. A failed deletion must preserve both the note
and drafts. Tests must cover a crash between the Trash operation and recovery
cleanup.

An original deleted, moved, or made unreadable outside Nook is not proof that
its unfinished writing should be destroyed. Keep that checkpoint reviewable and
label the original as unavailable. It remains copy/export/new-note only. Do not
pass it to `MarkdownStore.save` with a missing revision and recreate its former
path. The explicit Save as New Note action always creates a distinct identity.

Changing the notes folder must retain draft ownership in the old folder,
checkpoint all affected live edits, and leave recovered copies discoverable.
The current folder selection cannot redirect a pending save. Copying existing
Markdown into a new folder does not migrate or merge draft ownership.

Conflicts are not resolved by retries in this phase. Previewing, copying, and
saving a new note leave the original unchanged, including when another program
preserves its modification date while changing its bytes.

## Storage, privacy, and retention

Store checkpoints under
`~/Library/Application Support/<bundle-identifier>/Drafts`, separately for
official and development builds. Use non-content-derived filenames. This is
local plaintext containing unfinished writing and, where necessary, its
original baseline; it is not encrypted storage or a security boundary against
software running as the same user.

- Create and verify the recovery directory with mode `0700` before any content
  is written. Keep checkpoint and temporary files at `0600` throughout the
  atomic write, rather than tightening permissions only after exposing them.
- Reject symlink or nonregular checkpoint files. Validate record version,
  identity, field sizes, and revision shape before loading. Corrupt or newer
  records are retained and reported, not silently deleted or replayed.
- Bound concurrent writes and preview decoding. Set and test explicit maximum
  record and scan sizes before implementation; exceeding a limit must show an
  actionable warning rather than silently truncate text or drop older drafts.
- Remove resolved checkpoints; keep unresolved ones until an explicit user
  decision. Do not introduce age-based deletion, an eviction quota, or reuse
  audio-retention cleanup for unfinished writing.
- Do not store note text, titles, paths, or failure descriptions in the
  operational event journal. No telemetry, new permissions, credentials,
  assistant calls, or network activity are involved.

The implementation must update `docs/PRIVACY.md` in the same change. Explain
the location, contents, owner-only permissions, retention, deletion behavior,
and the possibility that Time Machine, enterprise backup, or other software
copies these files. Explain that deleting a checkpoint from Nook does not
remove earlier backup copies. The user must be able to find and remove
recovery copies without knowing a hidden directory path.

## Tests and acceptance

Use synthetic content and injectable directories, clocks, and write failures.
Required automated behavior includes:

- Restart with active personal notes, multiple parked drafts, raw Markdown, a
  new quick note, and an already saved quick note. Recover the latest completed
  checkpoint with its original owner and conflict baseline intact.
- Restart after external edits, including same-timestamp edits. Launch,
  navigation, preview, Copy, and quit leave every original byte unchanged.
- Two libraries contain the same note UUID. Their checkpoints remain distinct;
  changing folders cannot write into the copied note or change ownership.
- Deleted, moved, unreadable, and malformed originals never cause recreation
  or silent checkpoint deletion. Recovery remains inspectable/exportable.
- Save, discard, and note deletion race with a pending checkpoint. Completion
  invalidates late writes, and restart cannot resurrect resolved content.
- Simulate termination after saving a new recovered note but before journal
  cleanup. Reconciliation recognizes the exact completed result and does not
  create a duplicate. A changed destination does not count as completion.
- Continuous editing triggers bounded periodic checkpoints. A stopped process
  loses at most the edits after its last completed checkpoint; tests must not
  assert that work still queued was persisted.
- Disk-full, permission, atomic-write, read-back, and cleanup failures preserve
  the last valid copy and surface an accurate status.
- Empty replacements, Unicode, long text, raw frontmatter, and unknown Markdown
  sections survive recovery without truncation or unintended interpretation.
- Directory/file modes are private, symlinks are rejected, and malformed,
  oversized, or unsupported records remain discoverable as recovery issues.

Manual acceptance on a Mac must cover real force quit during each editor,
relaunch, switching libraries, an unavailable volume, external edits while
Nook is closed, recovery into an existing busy library, and failed cleanup.
Verify light and dark appearance, VoiceOver, keyboard-only navigation, visible
focus, Increased Contrast, Reduce Motion, and Reduce Transparency. Destructive
confirmation defaults to keeping the draft. No recovery interaction may start
the microphone or send content to a provider.

Performance acceptance includes sustained typing and dictation into a large
Markdown draft while checkpoints are written, with no visible input stalls or
unbounded queued snapshots. Crash-recovery claims must state the tested
checkpoint interval and its limits; power-loss durability needs separate
filesystem-level validation.

## Integration boundaries

Compose one journal service in `AppModel` and inject it into the three draft
controllers. Observe edits at the controller boundary so view disappearance,
dictation results, and model-result application cannot bypass checkpointing.
Keep recovery presentation separate from `RecordingRecovery` and its audio
cleanup. Preserve existing save/quit guards while adding checkpoints; a backup
copy is not a substitute for honoring an explicit Save command.

Phase 1 does not change note format, add sync, retain dictation audio, journal
transient recognition guesses, introduce version history, or promise automatic
merging. Regenerate the Xcode project for added implementation/test files and
run the existing conflict, privacy, copy, and quit regressions as well as the
new recovery suite.

## Phase 2: restore and compare deliberately

A later proposal can add **Restore to Editor** and an explicit comparison or
merge surface. Restoration must preserve the original baseline and exact file
identity; it cannot become a reload that authorizes overwriting external
changes. Personal-note comparison may merge independently changed fields when
their original baseline still matches. Raw Markdown needs a source-level
three-way comparison, and ambiguous edits must remain a user decision.

Only an explicit, reviewable action may replace content in an existing note.
Deleted-note restoration, library relocation, and checkpoint version history
need their own semantics before they are offered. Keeping recovery copies
independent in Phase 1 makes these additions possible without turning the
first release into a hidden autosave or replay system.
