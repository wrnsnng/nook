# Nook 1.8.1

Recording no longer slows its own interface: the elapsed timer keeps a steady
second even during long, talkative meetings.

- Partial transcription results are delivered to the interface at most ten
  times per second instead of on every revision, while finished sentences
  still appear immediately.
- Audio levels reach the recording meter as a single polled value rather than
  one background task per audio buffer.
- The live word count is maintained as lines arrive instead of recounting the
  whole transcript every time the interface updates.
- The level meter stays flat while a meeting is paused.
