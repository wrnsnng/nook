# Nook architecture

Nook is a native SwiftUI/AppKit application whose service graph is coordinated
on the main actor. Meeting content stays in local system frameworks and files;
Sparkle is the only application network component.

```text
MeetingDetector ──detected/ended──▶ MeetingCoordinator ◀── top panel + library UI
                                         │
                                  CaptureService
                                  ╱             ╲
                 system + mic PCM               local MP4
                       │                             │
             LiveTranscriptionService         AudioExtractor
                 ╱               ╲                  │ M4A
        Meeting speaker        You speaker     fallback transcription
                 ╲               ╱                  │
                  timestamped merged transcript ◀───╯
                               │
                         SummaryService
                               │ structured insights
                         MarkdownStore
                               │
                         ~/Documents/Nook/*.md

NookUpdateController ──▶ signed Sparkle appcast
                              │
                    EdDSA + Developer ID verification
                              │
                       atomic app replacement
```

## Components

- `AppModel` is the composition root for services, windows, notifications, and
  application lifecycle.
- `MeetingDetector` polls local Core Graphics window metadata and Core Audio
  process activity, then debounces likely meeting transitions.
- `MeetingCoordinator` owns consent, recording state, pause/resume, processing,
  error recovery, and the temporary-file lifecycle.
- `CaptureService` records through ScreenCaptureKit and forwards synchronized
  system and microphone PCM buffers.
- `LiveTranscriptionService` runs one progressive on-device transcriber per
  source, merges their shared timeline, removes duplicates, and publishes
  partial speech.
- `AudioExtractor` exports the recording's audio track through AVFoundation.
- `TranscriptionService` runs a saved-audio fallback when live recognition is
  incomplete.
- `SpeechAssets` centralizes Speech permission, locale matching, model
  installation, and asset reservation.
- `SummaryService` uses `SystemLanguageModel.default` locally and falls back to
  deterministic extraction.
- `MarkdownCodec` owns the stable, human-readable note format.
- `MarkdownStore` scans, saves, edits, and reveals Markdown files without a
  database.
- `NotchPanelCoordinator` positions the top-edge SwiftUI panel using the real
  display and camera-safe geometry.
- `NookSnapshot` renders production SwiftUI views offscreen for visual checks.
- `NookUpdateController` owns Sparkle update checks and user preferences in
  official builds; contributor builds keep the updater disabled.

## Trust boundaries

Nook intentionally crosses several sensitive macOS boundaries:

1. Meeting detection reads window and process metadata locally.
2. Capture uses macOS-granted Screen & System Audio Recording and Microphone
   access only after a user starts a recording.
3. Speech and Foundation Models process meeting content on-device.
4. Markdown and optional audio leave process memory as plaintext user files.
5. Official builds use Sparkle to fetch executable updates, then verify signed
   feed metadata, EdDSA archive signatures, and Apple code signing.

The application currently runs without App Sandbox because of its capture and
user-selected storage model. Hardened Runtime is enabled for distributed builds.
Changes near capture, storage, or updates require security and privacy review.

## Update trust chain

Source collaboration and binary distribution use separate repositories. The
public source repository never needs release credentials, while the public
releases repository hosts notarized archives and a stable appcast that installed
copies can read anonymously.

```text
reviewed source commit
  → credential-free tests and unsigned official-configuration build
  → local maintainer signing with Developer ID
  → Apple notarization + stapled ticket
  → Sparkle EdDSA-signed archive and appcast
  → public GitHub release assets over HTTPS
  → Sparkle verifies feed + archive + Developer ID
  → atomic install and relaunch
```

`project.yml`, `NookUpdateFeed`, and release tooling share one feed convention.
Tests should fail if the embedded feed URL or public key drifts.

## Failure behavior

- Permission errors provide a direct route to the relevant System Settings pane.
- If live captions stop, capture continues and Nook can retry from saved audio.
- If Foundation Models is unavailable, the deterministic summarizer remains.
- Cancellation discards recording artifacts and returns to an idle state.
- Successful processing removes temporary MP4 files and removes M4A audio unless
  retention is enabled.
- Failures must preserve an honest recovery path without silently losing or
  indefinitely retaining sensitive data.

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for implementation detail and
[docs/PRIVACY.md](docs/PRIVACY.md) for the data lifecycle.
