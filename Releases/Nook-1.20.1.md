# Nook 1.20.1

Fixed: Nook used far more processor time than it should have while a
meeting was recording. The library window redrew itself many times a
second for a clock that had not changed, which made fans spin up and
drained battery through long meetings.

- Recording is much lighter on the processor. The audio meter, the
  elapsed clock and the live captions now refresh only the small pieces
  of the screen that show them, instead of redrawing the whole library
  window, the meeting panel and the menu bar many times a second.
- The saved recovery language for an unfinished recording is chosen the
  same way whether or not the library window has finished opening.

Nook remains local-first. Audio, transcripts, summaries and notes stay on this
Mac unless you explicitly consent to the existing optional CLI note-action
provider. This release adds no telemetry or remote model service.
