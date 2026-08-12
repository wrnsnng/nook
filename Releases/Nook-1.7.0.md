# Nook 1.7.0

Nook can now take dictation anywhere on your Mac, and catch a thought when
there is nowhere to put it.

## Speak into any text field

Hold a shortcut, say the thing, let go. Your words appear in whichever text
field you were already working in: a message, a search box, a document. Settled
words arrive as you speak them, and a small indicator by the pointer shows what
Nook is currently hearing.

Choose how much Nook tidies what you said:

- **Verbatim** keeps every word.
- **Clean up** drops hesitations and stutters. Nothing else changes.
- **Polish** rewrites rambling speech as clear written sentences.
- **Custom** follows an instruction you write yourself.

Every rewrite is checked against what you actually said. If the wording drifts
too far, your own words are typed instead, so a question you dictate is written
down rather than answered.

The shortcut is yours to choose, including holding modifiers on their own such
as Control and Option. Hold to talk, or press once to start and again to stop.

## Or speak into a note

With nothing selected, the same shortcut opens a small note instead. Nothing has
to be open first: no app, no file, no window. The note saves as ordinary
Markdown into your notes folder, named from what you said, and appears in the
library alongside your meetings.

Notes can tidy themselves up, summarise, find the things you committed to, or
expand into something longer. That runs with Apple Intelligence on this Mac. If
you already use Claude Code or the Codex CLI, Nook can use those instead with
the subscription you already have, and it will always tell you plainly before
anything leaves your Mac.

## Also in this release

- Guided first-run setup covers microphone, speech recognition, and both macOS
  system-audio consent steps before your first recording.
- Nook is now open source under the Apache License 2.0.

## Privacy

Dictation records only your microphone, needs no screen access, and transcribes
on this Mac. Typing into other apps requires Accessibility access, which Nook
asks for only when you switch dictation on, and nothing else in Nook uses it.

Sending a note to Claude or Codex is the single exception to Nook keeping
everything local. It is off by default, asks before the first time, and says so
plainly while it is on.
