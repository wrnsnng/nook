# Nook 1.7.4

Nook now finishes meetings and dictation reliably, and structured notes no
longer confuse transcript text with action items.

- Summaries now use a structured on-device response instead of relying on
  Markdown headings. Every key point, decision, and action is checked against
  the transcript before it reaches the note.
- If the on-device model is unavailable or fails, Nook clearly labels a small
  set of transcript highlights and leaves structured fields empty. It no longer
  presents transcript passages as generated actions.
- Stopping a meeting now waits for both ScreenCaptureKit and the recording file
  to finish. A stop pressed during pause or resume is remembered, and callbacks
  from an older meeting cannot interfere with a newer recording.
- When macOS ends a capture stream unexpectedly, Nook saves any usable partial
  recording instead of failing the whole meeting. The display is also kept
  awake while recording because display sleep terminates system-audio capture.
- Dictation now releases the microphone and speech recognizer after every
  failure, cancellation, and disable action.
- Newly saved notes no longer disappear when an older background folder refresh
  finishes, and motion-heavy dictation indicators now respect Reduce Motion.
- A bounded local lifecycle journal records only fixed event names, never
  meeting titles, transcripts, paths, errors, or dictated words. It stays on
  the Mac and is never uploaded automatically.
