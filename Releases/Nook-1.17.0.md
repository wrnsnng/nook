# Nook 1.17.0

Regenerating a summary now shows its work, and no longer gives up when a
single section of a long meeting trips Apple's guardrails.

- Regenerate summary now shows live progress where your summary lives:
  "Re-reading this conversation", the part counter as it climbs, then
  "Writing up what it heard", until the new write-up replaces the old.
  No more staring at a greyed-out menu item wondering whether anything is
  happening.
- Fixed: meetings containing coarse language could come back as
  "Apple Intelligence declined to summarize". The write-up keeps names,
  figures, and dates exact while phrasing coarse language for a written
  work record, and if one section is still declined twice, that section
  steps aside instead of taking the whole summary with it.
