# Nook 1.8.0

Nook now catches silent transcription loss, asks before destroying a
recording, and keeps long meetings fast.

- A live transcript whose recognizer stops partway through a meeting is no
  longer saved as if it were complete. Nook checks how much of the recording
  the live words actually cover and fills the gap with its careful on-device
  second listen.
- Pausing can no longer leave a meeting that shows as recording while nothing
  reaches disk. When the file-close confirmation is slow, Nook keeps the
  paused state instead of pretending capture is still active.
- Cancelling during processing now asks first. The safe choice takes Return,
  so a reflexive keypress keeps the meeting rather than deleting the audio.
- The prompt asking to record a detected meeting can be answered from the
  keyboard: Return records, Esc declines. Recording surfaces still never take
  focus on their own.
- Tidy up and Expand rewrites are checked against the words you spoke. A
  rewrite that stops being recognisably your note is refused and your own
  words kept, so a dictated request can no longer overwrite itself with an
  answer.
- Editing Markdown source refuses to save over a file that changed outside
  Nook, and the editor no longer falls back to remembered text when a file
  cannot be read.
- Sub-headings you type inside My notes survive editing and re-saving, and
  heading-like text inside transcripts or summaries can no longer shift where
  sections begin or end.
- Recordings that were kept after a processing failure are surfaced when Nook
  launches, not only in Settings, so a kept conversation is harder to miss.
- Live captions stay responsive through hours of speech: finalized lines are
  folded in incrementally instead of rebuilding the whole transcript on every
  spoken word, and recordings idle at silence without invalidating the
  interface dozens of times per second.
