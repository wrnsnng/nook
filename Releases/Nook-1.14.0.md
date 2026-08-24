# Nook 1.14.0

A second-chance release, and a fix for the meeting panel's notes field.

- Every meeting note can now ask for its summary again. If Apple
  Intelligence was off, busy, or unwilling when the note was written, open
  the note's action menu and choose Regenerate summary. The transcript you
  already have is written up again on this Mac.
- A second attempt that fails leaves the note exactly as it was and says
  why in plain words: Apple Intelligence turned off, still preparing,
  too long, or whatever else got in the way. You are never left guessing
  whether anything happened.
- Regeneration keeps its hands off everything else. Your flagged moments,
  kept audio, hand-written sections, and My notes are untouched; unsaved
  My notes are written to disk before the summary runs; and a ticked
  action item keeps its tick when it survives into the new write-up.
- Fixed: the My notes field in the meeting panel did not accept typing
  during a recording. Clicking into it now brings Nook forward, so your
  keystrokes land in the field instead of continuing into whatever app is
  frontmost. The field in the floating notes window was never affected.
