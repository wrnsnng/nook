# Privacy and data handling

Nook is designed so meeting content stays on the Mac. This document describes
what the app observes, stores, sends, and deletes. It is a product description,
not legal advice.

## Data-flow summary

```text
local meeting metadata (optional detection)
  → user chooses Record
  → ScreenCaptureKit system audio + microphone audio
  → on-device Speech transcription
  → on-device Foundation Models summary, or deterministic fallback
  → plaintext Markdown in the selected notes folder
  → temporary recording deleted; extracted audio deleted unless kept, and
    kept audio later swept by age if audio retention is enabled
```

Dictation is a separate path with the same property:

```text
user holds the dictation shortcut
  → microphone audio via AVAudioEngine
  → on-device Speech transcription
  → deterministic clean-up, or an on-device Foundation Models rewrite
  → text inserted into the focused text field
```

There is no Nook account, meeting bot, sync service, advertising SDK, analytics
SDK, or application server in either path.

## Meeting detection

New users choose whether Nook should notice likely meetings. When enabled, Nook
checks local visible-window metadata and Core Audio process activity every few
seconds. It can inspect:

- application names and bundle identifiers;
- visible window titles for supported meeting providers;
- process names and a bounded process-parent chain; and
- whether a matching application process has active audio input or output.

Detection data is evaluated in memory on the Mac. It is not sent to Nook or
written to a detection history. A detected title may be used as a suggested note
title after the user chooses to record. Notifications use generic meeting text
to avoid placing a window title in Notification Center.

Detection is heuristic and can be disabled at any time in Settings. Manual
recording remains available when detection is off.

## Calendar context (opt-in)

Off by default and never prompted for at launch. When "Use my calendar for
meeting context" is switched on in Settings, Nook asks macOS for calendar
access at that moment, then:

- names a detected meeting after its nearby event, instead of an app window
  title; and
- posts one quiet notification shortly before an event starts.

Event titles, attendee counts, and times are read from the Mac's local
calendar store (which includes every account signed in under Internet
Accounts, such as iCloud, Google, or Exchange), used in memory, and never sent
anywhere. Nothing about events
is logged or written into notes beyond the note title the user accepts by
recording. Disabling the switch stops all calendar reads.

macOS grants calendar access as full access to events, not a read-only grant.
EventKit does not offer a narrower scope for reading event details, so this is
the permission macOS presents even though Nook only ever reads events: it
never creates, edits, or deletes anything in your calendar.

The pre-meeting notification shows the event's title and, when the library
holds no earlier sitting of that series, how many people were invited. It
never shows attendee names, locations, or descriptions.

Exporting an action item to Reminders is a separate, on-request write that
asks for full Reminders access the first time it is used. Each export creates
one reminder in your default Reminders list, carrying only the action item's
own text as its title and, when the item has a due date, that date at 09:00 as
the reminder's due time. Nothing else about the note is written to Reminders.

Prep briefs are assembled on this Mac from the local library when a calendar
event with earlier sittings approaches. No new data is collected and nothing
leaves the machine; the brief quotes saved notes only.

## Recording and permissions

Nook requests macOS-controlled access to:

- **Microphone**, for the user's side of the meeting;
- **Speech Recognition**, for on-device transcription; and
- **Screen & System Audio Recording**, for meeting audio from other apps.

macOS may separately ask Nook to confirm direct screen and audio access without
using the private window picker for every meeting. Guided setup triggers that
consent by fetching shareable-content metadata only; it does not start or save
a test recording.

Nook starts capture only after the user invokes a manual recording or accepts a
detected-meeting prompt. It does not hide the macOS recording indicator. The
ScreenCaptureKit stream includes a 2×2-pixel, one-frame-per-second video track
because the capture API requires a stream; the track is not used as useful
screen video and its temporary container is deleted after processing.

Pausing removes the recording output and stops forwarding audio to live
transcription until the user resumes.

## Dictation and Accessibility access

Dictation is off by default. Turning it on requires one additional
macOS-controlled permission:

- **Accessibility**, so Nook can place text into the field that has focus.

This is the broadest permission Nook asks for, and it deserves to be understood
rather than clicked through. Granting it lets an app read and control other
apps' interfaces. Nook uses it for exactly two operations: reading which element
currently has keyboard focus, and writing text into that element. It does not
read the surrounding document, observe other applications, or record keystrokes.

Nook never requests Accessibility access during first-run setup or for meeting
recording. It is requested only when a user first switches dictation on, and
dictation is the only feature that stops working if it is revoked.

Dictation captures the microphone through `AVAudioEngine` rather than
ScreenCaptureKit, so it needs no screen-recording access and captures no system
audio — only the user's own voice, only while the shortcut is held or a toggled
session is running. The macOS microphone indicator is active throughout.

Some applications do not accept direct text insertion. For those, Nook falls
back to placing the text on the clipboard and synthesising a paste, then
restoring the previous clipboard contents. During that brief window the dictated
text is on the system clipboard and readable by other software.

Rewrites for the **Polish** and **Custom** styles use the on-device Foundation
Models framework, the same as meeting summaries. Dictated speech is not sent to
a hosted model. **Verbatim** and **Clean up** use no model at all; clean-up is a
fixed list of hesitation words removed by ordinary string handling.

Every rewrite is compared against what was actually said before it is inserted.
If the wording has drifted too far — which is what happens when a model answers
dictated speech instead of transcribing it — the user's own words are inserted
instead.

Holding the dictation shortcut with no text field focused opens the quick note
pad instead of typing into an app. Its optional hands-free mode keeps the
microphone open across pauses in speech, appending each recognized chunk to
the note, until the user turns hands-free off; the same on-device recognition
and rewrite guarantees apply to every chunk.

## Transcription and summaries

Apple's Speech framework performs transcription on-device. macOS may contact
Apple to download a selected language model; Nook does not include meeting
content in that asset request.

When available, Apple's Foundation Models framework creates summaries on-device.
When it is unavailable or fails, Nook uses deterministic local extraction.
Nook does not send transcripts to a hosted language model.

## The command-line assistant bridge (opt-in)

Note actions can optionally run through a Claude Code or Codex CLI already
installed and signed in on the Mac. This is the one exception to Nook keeping
everything local, and it is off by default with consent required separately
for each provider. The first action run against a given provider shows a
warning naming what is about to happen; declining keeps the note untouched.

When a run is confirmed:

- only the text of the note currently being acted on is sent, never other
  notes, recordings, or transcripts;
- it is sent over standard input to the CLI tool's own non-interactive mode,
  with no shell involved, so nothing in a note can be read as a command; and
- the tool runs under the subscription the user already signed into on that
  Mac. Nook does not read, store, or transmit any credential; there is
  nothing for Nook to leak because it never holds one.

Both tools are agents by default: they read and write files, run commands, and
call whatever MCP servers, hooks, and custom instructions their user has
configured, under the permissions that user already granted for their own work.
A note is dictated speech and other people's writing, and it routinely reads as
instructions. Nook therefore runs these tools stripped down to what a rewrite
needs, rather than as the user's own configured agent:

| Tool | What Nook adds |
| --- | --- |
| Claude Code | `--tools ""` (no built-in tools), `--strict-mcp-config` with no MCP configuration of its own (no MCP servers), `--permission-mode manual` (nothing runs unapproved, and a print-mode run has nobody there to approve it), `--safe-mode` (no CLAUDE.md, skills, plugins, hooks, or custom agents), `--no-session-persistence` |
| Codex | `--sandbox read-only` (commands cannot write or reach the network), `--ignore-user-config` (no MCP servers, no user configuration), `--ignore-rules`, `--ephemeral` |

`--no-session-persistence` and `--ephemeral` are the reason the note is not
left behind in a session transcript inside `~/.claude` or `~/.codex` after the
run. Authentication is untouched by all of these, which is what lets the bridge
keep using the subscription the user already has.

Nook reads each tool's own `--help` once per app run and uses only the flags
that installed version advertises. If the help cannot be read, every flag above
is passed anyway: a run that fails visibly is better than one that quietly runs
without restriction.

Handling of that text once it reaches the CLI tool, and any request the tool
makes from there, is covered by that provider's own terms and privacy policy,
not Nook's.

## Shortcuts

Nook exposes a small set of Shortcuts actions: starting, pausing, or finishing
a recording, opening the library or the latest meeting, and reading back the
latest note's text. Each action runs only when a Shortcut invokes it. The
note-text action hands that text to the Shortcut that asked for it, and
anything the user's own Shortcut does with it from there, such as sending it
to another app, is outside Nook.

## Files and retention

The default notes folder is `~/Documents/Nook`. A user can select another folder
in Settings. Each completed note is a plaintext Markdown file containing
timestamps, source application, title, summary, key points, decisions, action
items, personal notes, and transcript.

A note can hold more than one recorded sitting: recording into an existing
note, or merging two saved notes, appends the new material to the same file.
Those files additionally list their recorded sittings in the frontmatter. Kept
audio remains one file per note inside the recordings folder; when earlier
audio was already gone before a later sitting was appended, the frontmatter
records where the kept audio begins on the combined timeline.

Kept audio is deleted only when the user asks, or when the optional audio
retention setting is switched on: extracted audio older than the chosen
window moves to the Trash on launch. Notes are never touched by retention.
"Ask your library" stores derived embedding vectors under Application
Support (`NookAsk`), never beside the notes; deleting that folder removes
everything it knows.

Temporary capture and extracted-audio files live in a hidden `.recordings`
folder inside the selected notes folder while Nook processes a meeting.

- Temporary MP4 containers are deleted after successful processing.
- A recording is kept when processing fails, because at that point it is the
  only copy of the conversation. Settings lists anything kept this way with its
  date and size, so it can be turned into a note or deleted rather than sitting
  on disk unnoticed.
- Extracted M4A audio is deleted unless **Keep extracted meeting audio** is on.
- Merging two notes that both kept audio combines them into one continuous
  file. That work happens in a transient `merged-<UUID>.m4a` file inside the
  recordings folder, which replaces the kept audio it was built from once the
  merge succeeds and never survives past that step.
- Cancelling processing discards the meeting's temporary files.
- Nook attempts to clean up partial files after processing failures. Cleanup
  failures are surfaced rather than treated as success.

A weekly digest note is compiled entirely from notes already saved in the
library: counts, decisions, and highlights it quotes from them. Building one
reads existing notes but collects nothing new and sends nothing anywhere.

Plaintext files are readable by software and people with access to the selected
folder. Depending on macOS and user configuration, Documents or another selected
folder may be included in iCloud Drive, Time Machine, enterprise backup, search
indexing, or third-party sync. Choose a location consistent with the sensitivity
of your meetings.

Changing the notes folder can copy existing Markdown files, but originals remain
in the previous location until the user removes them.

## Network activity

Contributor builds use a separate development bundle identity and keep the
production updater disabled. Official builds use Sparkle to contact the public
GitHub releases repository for update metadata and archives. These requests can
reveal ordinary connection metadata such as IP address, app version, and request
time to network operators and GitHub, but do not contain meeting audio, notes,
or transcripts.

Official updates are protected with HTTPS, a signed appcast, EdDSA archive
signatures, Apple Developer ID signing, and notarization.

Links to the project website or GitHub open only when a user activates them.

## Logs and diagnostics

Nook has no application telemetry or remote crash-reporting integration. macOS
and Apple frameworks may create local diagnostic or permission logs. Review and
redact logs before sharing them: filenames, paths, window titles, errors, or
framework output can identify a meeting or user.

Nook also keeps a bounded local operational journal in `~/Library/Logs`. Its
entries come from a fixed list of lifecycle events such as capture started,
capture stopped, or processing failed. It contains no meeting titles, dictated
words, transcript text, filenames, paths, or error descriptions, and it is never
uploaded automatically. Each installed build identity uses its own journal.

## User control

Users can:

- disable automatic meeting detection;
- leave dictation off, or turn it off and revoke Accessibility access;
- choose whether dictated speech is rewritten at all;
- decline any detected recording;
- pause, finish, or cancel a recording;
- choose the notes folder;
- choose whether extracted audio is retained;
- edit, move, or delete Markdown and retained audio with ordinary file tools;
  deleting a note from the library moves its Markdown file to the Trash;
- disable automatic update checks or downloads; and
- revoke Nook's permissions in System Settings.

## Consent and responsible use

Recording, transcription, notification, employment, and data-retention rules
vary by jurisdiction and organization. The person operating Nook is responsible
for obtaining required consent and following applicable law and policy.

Report a suspected privacy or security vulnerability privately through
[SECURITY.md](../SECURITY.md). Do not attach real meeting content to a public
issue.
