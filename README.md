# Nook

**Meetings, tucked away.**

Nook is a native, local-first macOS meeting notebook that lives in the menu bar and anchors its recording prompt to the top edge of the active display.

![Nook icon](Nook/Resources/Brand/NookIconSource-Cobalt.png)

## What it does

- Captures both system audio and your microphone, independent of whether the call is in Teams, Zoom, FaceTime, Webex, Google Meet, or another app.
- Watches visible app/window signals and prompts after a meeting is detected twice.
- Stops automatically after the meeting signal has been gone for roughly 20 seconds.
- Transcribes live with Apple's on-device Speech framework, keeping meeting audio and your microphone as distinct speakers.
- Shows the spoken word as it arrives both in the top panel and in a dedicated live meeting view.
- Turns the live conversation into an on-demand “gist so far” without interrupting capture.
- Pauses and resumes capture without saving or transcribing the paused portion.
- Remembers whether the meeting workspace was compact or expanded and which live view you last used.
- Falls back to a careful second transcription pass over the saved audio if live recognition is interrupted.
- Summarizes with Apple's on-device Foundation Models framework.
- Falls back to a deterministic extractive summary when Apple Intelligence is unavailable.
- Writes a readable Markdown file containing frontmatter, summary, key points, decisions, action items, and a timestamped transcript.
- Provides a date-grouped native library, editable meeting notes and titles, a detachable live-notes window, speaker-aware transcripts, Finder reveal, and raw Markdown editing.
- Supports Auto, Light, and Dark appearance choices, VoiceOver-friendly controls, Reduce Motion, Reduce Transparency, and Increased Contrast.
- Adds Shortcuts actions for starting a recording and opening the library or latest meeting.
- Checks for signed, notarized updates through Sparkle and lets people opt into automatic checks and downloads.
- Uses the display's real menu-bar and camera safe areas for layout and never paints a simulated notch.

## Requirements

- macOS 26 or later.
- A Mac supported by Apple's on-device Speech framework.
- Apple Intelligence enabled for high-quality generated summaries. Transcription still works without it, and Nook has a basic summary fallback.
- Xcode 27 to build the current project.

Speech language assets may require a one-time macOS download. Meeting audio and text are not sent to an application server.

## Build and run

The generated Xcode project is committed, so the shortest route is:

```sh
open Nook.xcodeproj
```

Select the **Nook** scheme and press Run. Or build an ad-hoc local app from Terminal:

```sh
./Scripts/build-app.sh
open build/Nook.app
```

On the first recording, macOS asks for:

1. Microphone access.
2. Speech Recognition access.
3. Screen & System Audio Recording access.

If screen-audio permission is changed, quit and relaunch Nook before trying again.

## Testing a distributed build

Use `build/distribution/Nook-1.4-notarized.zip`, extract it, and move `Nook.app`
to `/Applications` before opening it. Do not keep an older copy of Nook in
Downloads or another Applications folder because Launch Services may open the
wrong build.

When replacing a build that previously failed to request audio access, clear its
stale privacy decisions once before launching the notarized app:

```sh
tccutil reset Microphone com.localfirst.nook
tccutil reset SpeechRecognition com.localfirst.nook
tccutil reset ScreenCapture com.localfirst.nook
```

Start Nook from `/Applications`, begin a recording, and accept the Microphone,
Speech Recognition, and Screen & System Audio Recording prompts. macOS requires
Nook to relaunch after Screen & System Audio Recording is granted; Nook preserves
the pending recording and resumes it after the relaunch.

## Notes and recordings

The default notes folder is:

```text
~/Documents/Nook
```

It can be changed in Settings. Each meeting is one portable Markdown file. Temporary video containers are always deleted after audio extraction. Extracted audio is deleted too unless **Keep extracted meeting audio** is enabled.

The temporary video track is intentionally configured at 2×2 pixels and one frame per second: ScreenCaptureKit needs a capture stream, but Nook only retains the audio.

## Automatic detection

There is no shared public API through which every meeting app reports call state. Nook therefore uses debounced visible-window signals for Zoom, Teams, Google Meet, FaceTime, Webex, Slack Huddles, Around, and Whereby.

Detection is deliberately conservative:

- Two positive scans are required before the prompt appears.
- Five missed scans are required before Nook considers the meeting ended.
- Manual recording is always available from the menu bar with `⇧⌘R`.

Window names can change when meeting apps update. Add or adjust patterns in `MeetingDetector.swift` when necessary.

## Privacy

Nook is designed to keep the data path local:

```text
Meeting audio
  → ScreenCaptureKit system + microphone streams
  → on-device live Speech models
  → timestamped speaker-aware transcript
  → saved-audio refinement when needed
  → on-device Foundation Model
  → Markdown in your chosen folder
```

Always follow applicable recording and consent laws and your organization's policy. Nook intentionally does not try to hide the macOS recording privacy indicator.

## Development

Regenerate the Xcode project after editing `project.yml`:

```sh
xcodegen generate
```

Build and test:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Nook.xcodeproj -scheme Nook \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The `NookSnapshot` development target renders the real SwiftUI hierarchy offscreen for light, dark, compact, live, and notch visual checks.

## Automatic updates

Nook uses [Sparkle 2](https://sparkle-project.org/) for native over-the-air updates. People can check manually from the Nook menu or choose automatic checks and downloads in **Settings → Updates**.

The update chain is deliberately separate from the private source repository:

- Source: private `wrnsnng/nook` repository.
- Binaries and appcast: public `wrnsnng/nook-releases` repository.
- Update archives: Apple Developer ID signed, notarized, stapled, and EdDSA signed.
- Appcast: signed and verified before Nook trusts its contents.
- Private Sparkle key: remains in the local macOS Keychain and is never committed.

Nook 1.4 is the first OTA-capable build, so existing 1.3 installations need one final manual replacement. Releases after 1.4 can arrive through Sparkle.

Prepare a release locally:

```sh
./Scripts/release-update.sh --notes path/to/release-notes.md
```

After the public release repository exists, publish the archive and stable feed:

```sh
./Scripts/release-update.sh \
  --notes path/to/release-notes.md \
  --publish
```

The release script refuses to publish into a repository that is not public. It uses the existing `NookNotary` keychain profile by default and never reads Apple credentials from the repository.

macOS may ask you to allow Sparkle’s release tool to use the signing key; approve that protected Keychain prompt to finish the appcast signature.
