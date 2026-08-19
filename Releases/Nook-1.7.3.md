# Nook 1.7.3

Nook no longer throws away a recording it could not write up.

- A meeting that failed while being processed used to have its recording
  deleted. The recording is the only copy of that conversation, so it is now
  kept, and Nook tells you where it is.
- Long meetings are given the time they need to finish writing. Finalizing a
  long recording takes longer than a short one, and the old limit was tuned on
  short tests, so real meetings could time out and be lost.
- Quitting Nook while a recording is finishing no longer looks like it has
  hung. It now gives up sooner when you are trying to quit than when you are
  simply stopping a meeting.
- Settings now lists any recordings that never became notes, with their date
  and size. Save one as a note, reveal it in Finder, or delete it once you are
  done. Recovering runs the same on-device transcription and summary a meeting
  normally gets.
