# Nook 1.18.1

Fixed: structured summaries could still fail outright on newer macOS
builds. Apple renamed the errors its on-device model reports, so a
refused chunk, an unreadable answer, or an overflow at the write-up step
could each end a long meeting with only transcript highlights.

- Summaries now survive every failure the model can report under either
  name: a declined part retries neutrally and steps aside instead of
  failing the meeting, an answer that cannot be parsed falls back to
  plain text, and if the write-up itself cannot run, the facts,
  decisions, and actions harvested from your transcript become the note
  rather than nothing.
- When a summary still cannot be produced, the note now says exactly
  why. Sensitive content flags and unreadable answers get their own
  explanations instead of one generic line.
