# Changelog

Nook follows a user-facing release-note model. Each published version has a
Markdown note in [`Releases/`](Releases/) and a matching `v<version>` release in
the [binary releases repository](https://github.com/wrnsnng/nook-releases/releases).

## Unreleased

## Unreleased

- Recordings, recovered recordings and live-caption rescue notes save their
  words before summary enrichment. Saved notes show background progress,
  non-destructive cancellation and Retry without hiding the transcript or
  current write-up. Unfinished summaries remain retryable after relaunch.
- Fallback write-ups are explicitly labeled and keep a visible Retry action
  after reopening. Their origin stays separate from progress and failure
  messages. Failed note merging retains earlier facts, decisions and questions;
  successful merging clears stale pending status.
- Review related transcript passages from a summary sentence, key point,
  decision, action or question. Request a local correction or preview removal,
  then explicitly apply it. Undo is available until the review closes. Stale
  notes, source changes and incomplete-recording warnings remain protected.
- Meeting summaries retain supported open questions in their own section.
  Choose General, Standup, One-to-one or Interview emphasis on a saved meeting,
  then explicitly regenerate on this Mac. Recipe selection does not start a
  model, and existing user-written Open questions headings keep their meaning.

## 1.20.1

[Release notes](Releases/Nook-1.20.1.md)

- Recording no longer pins a CPU core: the Library window had begun
  re-laying itself out on every audio meter tick, and the meter, clock and
  live captions now publish to the small views that draw them instead of
  to every window holding the meeting coordinator.

## 1.20.0

[Release notes](Releases/Nook-1.20.0.md)

- Saving publishes one sorted Library snapshot, and draft-recovery status
  updates stay within their sidebar section instead of invalidating the whole
  Library. The native editor is configured at creation for long-paragraph
  editing without changing engines during an edit.
- Unchanged action lists, empty searches and absent prep briefs no longer
  broadcast redundant Library updates. Changed file revisions, Reminders
  receipts, errors and cancelled searches still update their own state.
- Unrelated interface updates preserve active text composition. Explicit
  Unicode-only replacements reach the native editor without replacing its
  view, selection or focus.
- Delayed recording summaries preserve Unicode-only edits, and recovery refuses
  to overwrite a same-ID note restored while processing. Appended recordings
  recheck both audio files before using their timeline or replacing kept audio;
  a failed placement retains the session's original capture and extracted audio.
- Library rows reuse their captured file identity instead of repeatedly
  normalizing paths during rendering. Saving, renaming and reloading refresh
  the identity while preserving original file URLs and copied-note ownership.
- Saving My notes no longer reformats the file when only surrounding whitespace
  changed. Original line breaks are kept, and a completed draft can be reconciled
  after interrupted recovery cleanup without creating another note.
- Library and detail notices reserve space above the content instead of covering
  the title. Replacing or dismissing a notice keeps the editor and its selection.
- Summary validation checks numeric wording against the transcript, including
  quantities, percentages, currencies and codes. If a regenerated summary
  fails that check, the existing note stays unchanged.
- Sending an action to Reminders prevents overlapping exports across Library
  windows, rechecks the source after permission, and keeps failed attempts
  retryable. An unrelated successful export no longer hides an export failure.
- Selecting a saved note skips path normalization for unrelated note IDs,
  while copied notes still require their full file identity to match.
- A failed summary regeneration keeps the existing summary even when useful
  transcript highlights can be recovered. Fallback text no longer mislabels
  every generation failure as a refusal. Regeneration errors now explain that
  the existing note was kept, rather than claiming only the transcript remains.
- Summary regeneration has an explicit Cancel control, rejects late results
  after a notes-folder change, and preserves newer edits down to exact Unicode
  bytes. Changed transcript or summary guidance requires a fresh request.
- Merging settles unfinished drafts before taking its inputs and checks both
  source files again before saving and cleanup. Cancellation, changed files,
  uncertain saves and failed Trash operations explain what was retained;
  repeated callbacks cannot append the same pair again in that window.
  A selected clean Markdown editor advances to the merged source.
- Recording recovery stays bound to its original folder across extraction,
  transcription and summarization. Typed live notes stay beside their original
  recording when the Library folder changes.
- Merging rechecks recording file identity around asynchronous work and cleanup,
  so a replaced or modified recording is not used with an older timeline or
  removed by a failed-cleanup fallback.
- The command palette uses a native sheet with a named search field and Close
  control. Ask replaces the palette within its existing sheet; other commands
  run after dismissal. Shortcut hints follow your bindings.
  Native presentation keeps immediate query typing in the palette.
  Search and Close retain distinct accessibility names, and opening or re-raising
  Quick Note puts the cursor in its editor.
- Shortcut recording belongs to its Settings window and cancels when that
  window loses focus, closes or detaches, or Nook deactivates. Starting another
  recorder in the same window cancels the first; cancellation clears stale
  rejection text and held modifiers.
- Quick Note filing excludes ambiguous meeting copies and rejects stale targets.
  If the meeting saves but the quick-note copy cannot be removed, a persistent
  warning explains the retained copy and the next draft starts fresh.
- Conflict instructions wrap in small windows. Detail action failures remain
  visible until dismissed, and long failure messages scroll with Dismiss kept
  outside the scrolling text. A new notice starts at the top even when its text
  matches the previous notice.
- Transcript playback keeps Stop available when a search has no matches and
  stops when you leave the Transcript tab.
- Live transcripts gain a Jump to latest control for returning after scrolling
  back through earlier lines. Returning to the bottom resumes following, and
  short transcripts remain visible after longer content is replaced.
- Ask keeps answers attached to the question that produced them, cancels on
  dismissal, and keeps Cancel reachable for long questions. Changing notes
  folders closes Ask and the palette instead of retaining old destinations.
- Prominent buttons gain more readable dark-mode text. Custom button presses,
  saved-status transitions and Quick Note reflow respect Reduce Motion, while
  Increased Contrast strengthens custom outlines and dividers. Compact and
  hidden panel presses also honor Reduce Motion without losing visible feedback.
- Compact Flag acknowledgment uses a checkmark, and the hidden paused indicator
  uses a pause symbol, so neither state depends on color alone.
- Large libraries decode transcripts more quickly without changing their text
  or identifiers. Quick Note counts words in the background and reuses the
  result during interface updates, without delaying saves or draft recovery.
- Quick Note also checks for dated tasks in the background. Old suggestions
  disappear as soon as the words change, and reopening refreshes relative dates.
  Programmatic editor replacements preserve exact Unicode text, and typing
  clears an obsolete empty-note validation warning. Discard remains available
  after clearing a saved pad, while a new empty pad has nothing to discard.
- Common library searches use a faster matcher while preserving Unicode
  behavior. Superseded searches and closed search controllers cancel their work.
- Settings gains a storage overview with locations, file sizes and review
  actions for notes, recordings, drafts, temporary save copies, caches and logs.
  It does not open file contents, follow links or delete unfinished writing.
- New notes cannot overwrite a file created during save preparation. Existing
  notes are checked again before replacement, and recovery cleanup refuses
  changed copies even when cleanup is retried.
- CLI note actions limit process output, pass only a small explicit environment,
  and stop their process group on cancellation or timeout. Failed or oversized
  responses leave the note unchanged.
- Quick Note and Settings explain when the selected assistant is unavailable.
  Refreshing availability never silently switches to an external provider.
  A running provider's warning stays visible while it stops, late output is
  rejected, and another action waits for cleanup. Editing and saving stay usable.
- Normal Quit waits for assistant cleanup and stays open if it has not finished
  within five seconds. Drafts are checked again after asynchronous shutdown
  work, and cancelling quit restores the normal operation gates.
- Today and All changes preserve unsaved Markdown until Save, Discard or Cancel
  settles the decision. Background reloads and meeting completion use the same
  protection instead of changing the selected note behind the editor.
- Library loading, load failures and empty Today results have distinct states.
  Empty search feedback stays compact and names the active range; Show All
  Notes keeps the search while expanding it to the whole library.
- Search and library reloads detect external edits even when file timestamps
  stay unchanged. Copied notes keep distinct rows, search results and command
  palette selections; conflicting IDs open a read-only file review.
- Duplicate note IDs no longer route action edits or appended recordings to
  an arbitrary copy. Library answers, prep and weekly digests omit conflicting
  copies with an explanation. Permission restarts wait for the original
  destination to load and keep its file path through the retry.
- Unfinished My notes, Markdown edits, and quick notes gain local recovery
  checkpoints. After restart, recovered drafts can be reviewed, copied,
  exported, or saved as separate notes without overwriting their originals.
- Draft checkpoints preserve exact Unicode text. Markdown source edits cannot
  change a note’s ID, copied files with duplicate IDs stay separate during
  saves and deletion, and editors remain usable after an explicit file rename.
- Recovery controls remain visible in short windows and with long draft text.
  Failed-copy rows show wrapping filenames, and Finder controls name the file
  they reveal. Draft titles and filenames use primary text for readability.
  Unsupported recovery destinations keep the draft and explain how to save
  somewhere else.
- Audio conversion hands each input buffer over once under a lock, removing
  Swift concurrency warnings while preserving the complete resampled stream.
- Saved-audio transcription has a recording-length-aware deadline and responds
  to cancellation without waiting for a stalled Speech cleanup call.
- Automatic audio retention leaves recovery-only recordings and interrupted
  capture remnants untouched. Audio whose note was deleted remains available
  in Recovery until explicitly removed.
- Saves compare exact file contents so fast external edits are not overwritten.
  My notes, Quick Note and Markdown drafts retain their original save baseline
  after a conflict, and Save and Quit refuses to discard an unsaved edit.
- Rebuilding a weekly digest preserves its title, annotations, tasks and custom
  sections. Digests can now save nonempty My notes.
- Transcript playback finds the correct kept recording, respects audio that
  starts partway through a note, and exposes passage controls to VoiceOver.
  Transcript-wide display state is computed once per update instead of per row.
- Live transcripts keep repeated phrases and corrections. Echo removal pairs
  only matching, overlapping microphone and system segments, one pair at a time.
  Recovered recording parts remain chronological after the ninth resumed part.
- Dictation rewrites conservatively check numeric literals, negation and short
  utterances, keeping the original words when those checks fail.
- Note actions refuse incompatible CLI installations rather than omitting
  required protections. Codex's local file-read access is disclosed explicitly,
  and prior Codex consent must be renewed before another note action.

## 1.19.0

- Meeting words are saved before summary work begins. New meetings and sessions
  appended to an existing note keep their transcript even if summarization is
  cancelled, times out, or fails.
- Note titles now have an explicit edit state with Return to save and Escape to
  cancel. Renames reject empty or conflicting names and wait for unsaved
  Markdown changes instead of risking the file.
- Summaries are easier to scan, stay grounded in My notes and flagged moments,
  and no longer let template checklist items appear as open actions. Nearby
  transcript lines from the same speaker are visually grouped.
- Spoken notes have their own focused detail view, vocabulary, and word count
  instead of looking like incomplete meetings.
- Settings has clearer Keyboard, Dictation, and Listening groups. Shortcut
  recording no longer shifts the layout, explains scope and conflicts, and
  supports modifier-only combinations.
- Listening settings gains a local audio input check with separate You and
  Meeting meters. It records nothing, transcribes nothing, and leaves no file.
- Recoverable recordings now appear in the library with Recover, Reveal, and
  Delete actions, useful metadata, and visible cleanup errors.
- Quick Note, dictation, summary regeneration, deletion, and recovery now ignore
  stale asynchronous results. Deletion uses the Trash only and preserves the
  note when the Trash is unavailable.

## 1.18.1

- Fixed: structured summaries failed on newer macOS builds, where Apple
  renamed the errors its model reports. Refusals, unparsable typed
  answers, and overflows now degrade the same way under both names: a
  declined chunk retries neutrally then steps aside, an unreadable
  answer falls back to plain text with a locally parsed prose pass, and
  a failed write-up salvages the facts, decisions, and actions
  harvested from the raw transcript.
- Sensitive content flags and malformed answers now explain themselves
  in the note instead of reading as one generic failure.

## 1.18.0

- Fixed: profanity in a transcript tripped Apple's input screening and
  blocked summaries outright. Model input is now masked through a fixed
  word list; stored transcripts keep every original word.
- Regeneration progress labels its passes, so shrinking totals between
  condensing rounds no longer read as broken arithmetic.
- Live captions in the meeting panel are left aligned.

## 1.17.0

- Regenerate summary shows live progress in place of the gist prose:
  stage wording and the part counter while condensing runs, then the
  write-up phase, dissolving into the new summary when it lands.
- Fixed: coarse language in a transcript could make Apple Intelligence
  decline a chunk and abort the whole summary. Instructions now keep
  specifics exact while paraphrasing coarse language, and a declined
  chunk retries once neutrally then steps aside instead of failing the
  meeting.

## 1.16.0

- Long meetings summarize with their specifics intact: condensing keeps
  labelled facts, decisions, actions, and questions in close-to-spoken
  wording, and a candidate ledger harvested from the raw transcript
  reaches the write-up without passing through any narrative round.
- The final pass knows the meeting's duration and word count, prefers
  the specific over the general, and may write proportionally longer
  summaries for longer meetings.

## 1.15.1

- Fixed: My notes stopped accepting typing the moment a recording
  started, in both the meeting panel and the detached window. Render
  passes at the audio meter's rate kept blurring the field; focus is now
  requested once and can no longer be revoked by a refresh.

## 1.15.0

- Every Nook keyboard shortcut is user remappable from Settings, Keyboard,
  with live rebinding of the global flag hotkey, per-action and full reset,
  and shared-combination warnings that include dictation.
- Fixed long meetings reporting "too long for the on-device model":
  condensing stalled once answers stopped packing into chunks, so rounds
  never shrank the material; chunk budgets now hold two answers side by
  side and round counts are sized to the meeting.

## 1.14.0

- Meeting notes gain Regenerate summary: the on-device write-up runs again
  over the saved transcript, a second failure names its reason and leaves
  the note untouched, pending My notes saves commit first, and ticked
  action items keep their ticks when they survive.
- Clicking into the meeting panel's My notes field now brings Nook
  forward, so typing lands in the field during a recording instead of
  continuing into the frontmost application.

## 1.13.0

- Drafts survive everything: My notes save on blur, navigation, and quit;
  the quick note pad saves before quitting and keeps a failed save on
  screen; live meeting notes persist to disk and return with a recovered
  recording.
- Merges keep typed titles, ticked and dated action items, and
  hand-written sections from both notes, and always trash the absorbed
  file rather than the combined one.
- Whole-note saves stopped being lossy: completion state and unmodelled
  sections round-trip; external edits are reloaded, not overwritten;
  hands-free capture grows one file instead of several.
- Summaries of long meetings condense hierarchically with progress and a
  deadline; the live summary no longer cancels itself; failed
  finalization saves the live captions instead of discarding them;
  summary failures name their reason.
- Quick note pad redesigned: one control row, Return always a newline,
  Done, Discard, Esc, remembered frame, minimum size, honest hands-free
  toggle, app accent asset.
- Dictation refuses password fields on every path, re-checks delivery
  focus, and bounds sessions and asset installs; the CLI bridge runs
  Claude Code and Codex with tools and outside configuration disabled.
- Detection prompt is non-activating and persistent, collapsing to a
  compact Record affordance after a minute.
- Library sidebar caps and collapses prep and open actions, gains arrow
  key navigation; palette groups and hints; prep briefs speak plainly
  with actions; ask sheet suggests questions and cancels cleanly.
- Settings gains a General pane; the privacy pane names the CLI
  exception; About derives its signing line from the real code
  signature; onboarding shares one header treatment; every duration
  formats through one authority.
- Library and detail panes no longer re-render on audio meter ticks;
  library answers chunk off the main thread with a pruned vector store.

## 1.12.1

- Fix a crash when dictation opened the quick note pad: the pad's
  hand-built window was missing the environment object its new live
  partial and hands-free features read, so the first render trapped.

## 1.12.0

- Quick note gains hands-free capture, a live partial line while
  speaking, and a "File into" menu that appends words to a meeting's
  personal notes.
- Checklist lines in quick notes are real action items: parsed wherever
  they sit in the body, surfaced in the sidebar, datable, and
  exportable to Reminders.
- Deterministic task suggestions turn spoken dates into one-tap dated
  tasks without inventing or reordering words.
- New note templates: 1:1, Standup, Interview.
- ⌘K command palette over verbs, notes, and open actions with full
  keyboard navigation.
- Today scope in the library sidebar; action items tick from inside the
  note through the same single-line file rewrite as the sidebar.

## 1.11.0

- Record into an existing note or merge two saved notes: one continuous
  transcript with visible gap markers, kept audio that joins so moment
  playback still works, regenerated summary and title, and personal
  notes that are never rewritten.
  (Correction: the gap markers are divider lines in the saved Markdown
  file. The app's own transcript view does not parse or display them.)
- Prep briefs: an approaching calendar event with earlier sittings gains
  a quiet library card and a notification action, quoting decisions,
  key points, mentioned actions, and past sittings from local notes.
- Action items carry due dates with quick-set menus, overdue chips, a
  soonest-first sidebar sort, and Reminders export that includes the
  date.
- A spoken quick note can be promoted into a meeting note, keeping its
  prose as personal notes.
- The library can move notes to the Trash itself.
- Weekly digests state real conversation time across sittings.
- Keyboard focus is visible across custom controls, and the recording
  consent prompt highlights what Return will do.
- Meeting titles save when the field loses focus instead of vanishing on
  navigate-away.
- Weekly digest refuses empty weeks rather than saving zero-count notes;
  failures render as warnings instead of confirmations.
- Larger compact-rail controls, one shared elapsed-clock format past the
  hour, single motion element in expanded recording, and VoiceOver
  actions for ticking off and exporting action items.

## 1.10.2

- Turning on calendar context now shows the macOS permission prompt. Nook
  was missing entitlements macOS requires before it will ask, so the
  request was refused silently and the switch turned itself back off.
- Adding action items to Reminders is fixed by the same change.

## 1.10.1

- Setup gains an optional calendar step: turn on meeting context at the one
  moment it makes sense, using the same switch as Settings. Leaving it off
  never asks for Calendar access, and either choice can be revisited later.
- The final setup screen names a few things worth knowing: flagging moments,
  asking your library questions, and weekly digests.
- Calendar copy states its sources plainly: events come from every account in
  System Settings, Internet Accounts, including iCloud, Google, and Exchange.
  There is nothing to link or sign in to inside Nook.

## 1.10.0

- "Ask your library": ask a question across every note and get an answer
  drawn only from your own passages, citing the meetings it used. Weak
  matches are refused rather than guessed; retrieval runs entirely on this
  Mac via on-device embeddings, cached under Application Support.
- "Create weekly digest" compiles the last seven days of meetings into one
  note: deterministic counts, decisions deduplicated across meetings, up to
  two highlights per meeting, flagged-moment totals, and an optional
  on-device overview paragraph.
  (Correction: `DigestBuilder` supports the optional overview paragraph, but
  no caller in the app supplies one, so every digest is the deterministic
  facts alone.)
- New `digest` note kind; unknown kinds in older files still decode as
  meetings.
- Spoken formatting commands: "new paragraph" and "new line" become real
  breaks through a fixed substitution table; ordinary sentences containing
  those words pass through untouched.
- Per-app dictation styles in Settings: the frontmost app can keep its own
  style, resolved at the moment dictation starts.
- Opt-in audio retention: kept extracted audio older than a chosen window is
  moved to the Trash on launch. Off by default.
- Shortcuts gains finish-recording, pause/resume, and latest-note-text
  intents.

## 1.9.0

- Optional, opt-in calendar context: a nearby event enriches detection with
  its real title and attendee count, and a once-per-event notification fires
  one to ten minutes before an event starts. Access is requested only when
  the setting is enabled; reads stay on-device.
- Live moments: Option-Command-F, panel button, or menu command flags the
  current recording offset (double-presses within a second ignored). Moments
  persist in frontmatter, render as jump chips in Notes, and mark their
  transcript line.
- Transcript playback when kept audio exists, seeking by segment offset with
  a position-following highlight and a small transport.
- "Open actions" sidebar section aggregating unchecked items across notes.
  Toggling rewrites exactly that line of the file; items can be exported to
  Reminders on request, asking for access at first use.
- Library reloads reuse cached decodes keyed by each file's modification
  date instead of re-decoding everything on every activation.

## 1.8.1

- Recording no longer floods the main actor, which stalled the elapsed timer
  until it visibly jumped ahead:
  - partial transcription results are throttled to ten updates per second,
    with finalized speech still published immediately;
  - audio levels are read as a polled latest value instead of one task hop
    per buffer;
  - the live word count is maintained incrementally instead of recounting
    every segment on each repaint.
- The level meter no longer rises during a pause.

## 1.8.0

- A live transcript whose recognizer stops mid-meeting is no longer trusted as
  complete. Sequence end during an active session is reported, and transcript
  coverage is checked against the recorded duration before the live pass is
  preferred over saved-audio refinement.
- A pause whose recording-output finalization times out keeps its paused state
  instead of restoring "recording" while nothing writes to disk.
- Cancelling during processing asks for confirmation, with the safe choice on
  Return, across the panel, meeting window, and menu bar.
- The meeting-detected prompt takes focus when it appears so its Return and
  Esc shortcuts work; recording surfaces remain non-activating.
- Quick-note Tidy up and Expand rewrites go through the same drift guard as
  dictation, with a wider growth allowance for Expand.
- The Markdown source editor records a file's modification date at load,
  refuses to save over external changes, and no longer falls back to an
  in-memory reconstruction when the file cannot be read.
- Markdown section parsing is anchored to whole heading lines, and My notes
  ends only at headings Nook writes, so user sub-headings survive re-saving.
- Live captions are assembled incrementally (`LiveSegmentMerger`) instead of
  rebuilding merged, deduplicated, coalesced state per partial revision, and
  the merge sort comparator is now a strict ordering.
- The audio meter publishes level changes only when they are perceptible,
  instead of republishing every observer at 12.5 Hz through silence.
- Capture audio reaches live transcription through one ordered buffered
  stream rather than one unstructured task per buffer.
- Recordings kept after processing failure are scanned for at launch once the
  library first loads, not only from Settings.

## 1.7.4

- Structured summaries now use a typed on-device response and validate each
  key point, decision, and action against the transcript. A failed generation
  can no longer put transcript passages into action items.
- Meeting capture now waits for both the stream and recording file to finish,
  blocks overlapping captures, ignores stale callbacks, and keeps usable audio
  when ScreenCaptureKit stops unexpectedly.
- A stop requested while pause or resume is finishing is now carried out
  instead of being silently discarded.
- Dictation reliably releases its microphone and recognizer after every error,
  cancellation, or disable action.
- A background folder refresh can no longer make a newly saved note disappear.
- Nook keeps the display awake during capture because display sleep terminates
  its ScreenCaptureKit audio stream.
- Added bounded, content-free local lifecycle diagnostics to make release
  failures diagnosable without recording meeting text or sending telemetry.

## 1.7.3

- Recordings are no longer deleted when processing fails. When processing
  fails the recording is the only copy of the conversation, and Nook now names
  the folder it was kept in.
- Finalizing a recording is allowed the time a long meeting needs. The previous
  limit was tuned on short tests and could time out on a real meeting, which
  destroyed it.
- Quitting uses a shorter finalization deadline than stopping, so Nook does not
  appear wedged and invite a force quit mid-write.
- Settings lists recordings that never became notes, and can turn one into a
  note with the same on-device transcription and summary a meeting gets.

## 1.7.2

- Nook now keeps the Mac awake while recording. Idle sleep tore down the
  capture stream and ended recordings with no warning, which is why meetings
  the user was only listening to stopped after roughly twenty minutes. Display
  sleep is deliberately left alone.
- A capture stream that stops for any other reason now finishes the meeting and
  saves what was recorded, rather than leaving a meeting that looks live.
- Releases publish a `Nook.zip.sha256` beside the download.

## 1.7.1

- Fixed dictation in Chrome, Safari, and Electron apps including Claude,
  ChatGPT, Obsidian, and Proton Mail. Web content describes itself to macOS
  only when asked, so Nook saw no text field and opened a note instead.
- Nook now decides where dictated words belong when you stop speaking rather
  than when you start, so a note no longer appears mid-sentence and a field
  that takes a moment to become available still receives the text.
- A quick note left open no longer captures dictation meant for another app.
- Dictation reports when it heard nothing, instead of closing silently.

## 1.7.0

- Added dictation. Hold a shortcut anywhere on the Mac, speak, and Nook types
  what you said into whatever text field already has focus. Settled words appear
  as you speak them, and a small indicator by the pointer shows what Nook is
  currently hearing.
- Dictation offers four styles: **Verbatim** keeps every word, **Clean up**
  removes hesitations and stutters, **Polish** rewrites rambling speech as
  written prose, and **Custom** follows an instruction you write yourself.
- Every rewrite is checked against what was actually said. When the wording
  drifts too far, your own words are typed instead, so a dictated question is
  written down rather than answered.
- The dictation shortcut is fully configurable, including modifier-only
  combinations such as holding Control and Option on their own, with a choice
  between hold-to-talk and press-to-start-and-stop.
- Dictation is off by default and asks for Accessibility access only when you
  switch it on. It captures the microphone alone, needs no screen recording, and
  everything stays on the Mac.
- Added a guided first-run setup that explains Nook’s local workflow and walks
  through microphone, speech recognition, and both macOS system-audio consent
  layers before the first recording.
- Prepared the source project for public collaboration under the Apache License
  2.0, with the Nook identity covered by a separate trademark policy.
- Builds from source now mark themselves in the menu bar, so a development build
  and an installed release can be told apart at a glance.

## Current release

- [1.13.0](Releases/Nook-1.13.0.md), current stable release, build 27.

## Previous releases

- [1.12.1](Releases/Nook-1.12.1.md)
- [1.12.0](Releases/Nook-1.12.0.md)
- [1.11.0](Releases/Nook-1.11.0.md)
- [1.10.2](Releases/Nook-1.10.2.md)
- [1.10.1](Releases/Nook-1.10.1.md)
- [1.10.0](Releases/Nook-1.10.0.md)
- [1.9.0](Releases/Nook-1.9.0.md)
- [1.8.1](Releases/Nook-1.8.1.md)
- [1.8.0](Releases/Nook-1.8.0.md)
- [1.7.4](Releases/Nook-1.7.4.md)
- [1.7.3](Releases/Nook-1.7.3.md)
- [1.7.2](Releases/Nook-1.7.2.md)
- [1.7.1](Releases/Nook-1.7.1.md)
- [1.7.0](Releases/Nook-1.7.0.md)
- [1.6.4](Releases/Nook-1.6.4.md)
- [1.6.3](Releases/Nook-1.6.3.md)
- [1.6.2](Releases/Nook-1.6.2.md)
- [1.6](Releases/Nook-1.6.md)
- [1.5](Releases/Nook-1.5.md)
- [1.4](Releases/Nook-1.4.md)

Release-note files should be named `Releases/Nook-<version>.md`, committed with
the version change, and describe user-visible behavior rather than internal task
history. `MARKETING_VERSION` maps to `<version>` and the GitHub tag; the numeric
`CURRENT_PROJECT_VERSION` is the monotonically increasing Sparkle build number.

See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the release checklist.
