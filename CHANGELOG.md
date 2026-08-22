# Changelog

Nook follows a user-facing release-note model. Each published version has a
Markdown note in [`Releases/`](Releases/) and a matching `v<version>` release in
the [binary releases repository](https://github.com/wrnsnng/nook-releases/releases).

## Unreleased

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
