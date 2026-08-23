# Changelog

Nook follows a user-facing release-note model. Each published version has a
Markdown note in [`Releases/`](Releases/) and a matching `v<version>` release in
the [binary releases repository](https://github.com/wrnsnng/nook-releases/releases).

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

- [1.7.4](Releases/Nook-1.7.4.md), current stable release, build 17.

## Previous releases

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
