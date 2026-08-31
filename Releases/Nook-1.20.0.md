# Nook 1.20.0

This release makes larger notebooks easier to work in and gives unfinished
writing more protection.

- Library updates do less repeated work when notes are saved or background
  checks finish. Large libraries decode and search more efficiently,
  while copied notes keep their own file identities and selection.
- Long paragraphs use an explicitly configured native editor. Quick Note
  counts words and checks dated task suggestions in the background, keeping
  those tasks out of the typing path.
- Unfinished My notes, Markdown edits and Quick Notes have local recovery
  checkpoints. Review, copy, export or save recovered writing as a separate
  note without overwriting the original.
- Saves, merges, recovery and summary updates recheck their original inputs.
  Detected changes to notes, file locations and recordings stop stale work
  from replacing newer content, while recoverable drafts are retained.
- Summary validation checks numeric wording against the transcript. Failed
  regeneration preserves the existing summary, and a visible Cancel control
  cancels the request and rejects late results.
- The command palette uses a native sheet, note notices leave room for the
  editor, and long error messages keep their controls reachable. Keyboard
  focus, dark-mode contrast and reduced-motion behavior are more consistent.
- Live transcripts have a Jump to latest control. Playback keeps Stop
  available during searches and stops when you leave the transcript.
- Settings includes a storage overview for notes, recordings, drafts and other
  local files. Reviewing storage does not delete unfinished writing. Automatic
  audio retention leaves recoverable recordings alone.
- Reminders exports prevent overlapping attempts, recheck the source after
  permission and keep failures retryable. Recovery and note-action failures
  remain visible instead of being hidden by unrelated success.
- Optional CLI note actions have stricter process, output and cancellation
  limits. Provider consent and warnings remain explicit; updating Nook does
  not enable an external assistant.

Nook remains local-first. Audio, transcripts, summaries and notes stay on this
Mac unless you explicitly consent to the existing optional CLI note-action
provider. This release adds no telemetry or remote model service.
