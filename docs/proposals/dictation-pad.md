# [Feature]: One dictation surface - finish the quick note pad

## Problem

Nook speaks three voice dialects today and none of them compose:

1. **Hold-to-dictate** types settled text into whatever field has focus,
   then disappears.
2. **The quick note pad** catches dictation when no field has focus or
   when the pad itself is frontmost, but it is shaped like a transcript
   dump: one growing prose body, saved under an generated title, with a
   toolbar of assistant actions bolted underneath.
3. **Meeting capture** has the best live surface of the three (partial
   line, recent finals, pause semantics) and shares none of it.

A person who wants to think out loud for two minutes has no good home.
Hold-to-dictate is per-sentence and lands somewhere else each time. The
pad accepts the words but gives nothing back: no live partial feedback
while speaking, no sense of session, and filing means discovering the
"Open in Library" button after the fact.

## Proposed outcome

Make the quick note pad the single deliberate dictation surface, so the
three behaviors become one continuum:

- **Two inputs, one pad.** Typing and holding-the-shortcut both edit the
  same buffer, with identical placeholder and inset behavior. The pad
  reuses `NookNotesEditor` rather than the hand-rolled placeholder stack
  it carries today, which was flagged in the July interface audit as a
  drift from the component built to fix exactly this.
- **Live partial line while speaking.** When dictating into the pad, show
  the current partial phrase the way the notch panel and indicator do.
  Only settled text enters the buffer (the existing rule); the partial
  lives above or beside it where revision costs nothing.
- **Continuous mode.** A toggle (and an optional activation setting) that
  keeps a session open across utterances instead of ending at key
  release. Pausing the flow must be obvious and reversible; the existing
  hold shortcut still ends a sentence-level segment inside a continuous
  session.
- **Deliberate filing.** On close or explicit save, offer a destination:
  new spoken note (today), append to a chosen existing note, or attach to
  the most recent meeting note's personal notes. Default stays "new
  spoken note"; the picker exists so promotion stops being hidden
  discovery. Continuous autosave behavior is preserved either way.

## Alternatives considered

- **Keep dictation transient and make the pad richer separately.**
  Rejected: two surfaces sharing one recognizer will keep drifting, which
  is how the current split happened.
- **Put continuous mode in the system-wide indicator instead.** Rejected:
  a borderless indicator cannot host editing, and editing is the point of
  a pad.
- **Route everything through meetings-style live transcription.** Wrong
  register: meeting machinery assumes long-form speaker-separated audio
  and a recording lifecycle; short capture needs neither.

## Privacy, permission, network, and storage impact

None new. The pad already saves ordinary Markdown into the library
folder on this Mac. Dictation recognition is on-device. Assistant
actions remain behind the existing per-engine consent gate with the
permanent outbound banner. No new permissions, network paths, or
telemetry.

## Accessibility considerations

- Partial-line region is status text, announced with
  partial-vs-final distinction like the notch captions do today.
- Continuous mode toggle is a labeled switch with keyboard access and a
  visible focus ring (the shared ring landed in 1.11.0).
- Filing destination picker is a standard sheet/dialog with default-
  action Return and cancel-Escape.
- Reduced Motion: pad presentation and partial-line transitions follow
  the existing NookMotion gates.
