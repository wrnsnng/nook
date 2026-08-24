# Nook 1.13.0

A hardening release. A full review of everything shipped this month found
the places Nook could still lose words, and this version closes them.

- Nothing you type is discarded quietly any more. My notes save when you
  click away, switch notes, or quit; the quick note pad saves before Nook
  quits and refuses to close over a failed save; notes typed during a
  meeting survive a crash and come back with the recovered recording.
- Merging two notes is safe in both directions. The combined note keeps
  your typed title, your ticked and dated action items, and both notes'
  hand-written sections, and the file that moves to the Trash is always
  the one that was absorbed.
- Renaming a note, saving notes, or filing a spoken note no longer resets
  ticked action items or drops headings you wrote yourself. Notes edited
  in another app are reloaded rather than overwritten.
- Long meetings summarize now. Nook condenses in passes sized to the
  on-device model, shows which part it is working through, and stops
  waiting after a fair deadline instead of holding your note hostage.
  When a summary cannot be written, the note says why in plain words.
- If a recording cannot be finalized, the live captions you watched are
  saved as the note instead of being thrown away, and the recording is
  kept for a full recovery.
- The quick note pad has one calm row of controls. Return always types a
  newline, Done and Discard mean what they say, Esc closes, the window
  remembers its place, and a date in your own words offers to become a
  task with its due day named properly.
- Dictation will not type or paste into a password field, and it delivers
  to the field you started in, never whichever window took focus while
  you spoke. A session cannot hold the microphone open forever.
- The meeting prompt no longer takes your keyboard away from the meeting
  app, and it waits to be answered instead of vanishing after eight
  seconds.
- The library sidebar keeps your meetings in view: prep and open actions
  collapse and cap instead of pushing notes below the fold, and arrow
  keys move the selection.
- Ask your library answers faster, can be cancelled, and no longer stalls
  the app while it reads. Calendar checks are lighter and follow your
  actual schedule.
- Settings gains a General pane, the privacy page names the one exception
  to local-only processing, and About reports how the app is really
  signed instead of assuming.
- Note actions that run through Claude Code or Codex now start those
  tools with their own tools and outside configuration switched off, so
  your note is the only thing in the room.
