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
  → temporary recording deleted unless audio retention is enabled
```

There is no Nook account, meeting bot, sync service, advertising SDK, analytics
SDK, or application server in this path.

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

## Transcription and summaries

Apple's Speech framework performs transcription on-device. macOS may contact
Apple to download a selected language model; Nook does not include meeting
content in that asset request.

When available, Apple's Foundation Models framework creates summaries on-device.
When it is unavailable or fails, Nook uses deterministic local extraction.
Nook does not send transcripts to a hosted language model.

## Files and retention

The default notes folder is `~/Documents/Nook`. A user can select another folder
in Settings. Each completed note is a plaintext Markdown file containing
timestamps, source application, title, summary, key points, decisions, action
items, personal notes, and transcript.

Temporary capture and extracted-audio files live in a hidden `.recordings`
folder inside the selected notes folder while Nook processes a meeting.

- Temporary MP4 containers are deleted after successful processing.
- Extracted M4A audio is deleted unless **Keep extracted meeting audio** is on.
- Cancelling processing discards the meeting's temporary files.
- Nook attempts to clean up partial files after processing failures. Cleanup
  failures are surfaced rather than treated as success.

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

## User control

Users can:

- disable automatic meeting detection;
- decline any detected recording;
- pause, finish, or cancel a recording;
- choose the notes folder;
- choose whether extracted audio is retained;
- edit, move, or delete Markdown and retained audio with ordinary file tools;
- disable automatic update checks or downloads; and
- revoke Nook's permissions in System Settings.

## Consent and responsible use

Recording, transcription, notification, employment, and data-retention rules
vary by jurisdiction and organization. The person operating Nook is responsible
for obtaining required consent and following applicable law and policy.

Report a suspected privacy or security vulnerability privately through
[SECURITY.md](../SECURITY.md). Do not attach real meeting content to a public
issue.
