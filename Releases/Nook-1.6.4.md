# Nook 1.6.4

This update restores live transcription and fixes meetings that could never
finish processing.

- Live captions work again. Meeting audio is now converted into the format the
  on-device recognizer expects, so the spoken word appears while you record.
- Finishing a meeting no longer stops at "Securing the audio on this Mac".
  Post-processing now always completes, saves, or reports a clear error.
- When live captions are interrupted, Nook reliably falls back to a second
  transcription pass over the saved audio instead of stalling.
- Recordings are no longer left stranded when transcription cannot finish.

If a recent meeting was stuck in processing, its recording was preserved.

Everything remains processed and stored locally on your Mac.
