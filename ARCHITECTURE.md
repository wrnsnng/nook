# Nook architecture

Nook uses a small set of native services coordinated on the main actor.

```text
MeetingDetector ──detected/ended──▶ MeetingCoordinator ◀── notch + library UI
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
```

## Components

- `MeetingDetector`: polls Core Graphics window metadata every four seconds and debounces transitions.
- `CaptureService`: requests permissions, records through ScreenCaptureKit, and forwards synchronized PCM buffers from system audio and microphone capture.
- `LiveTranscriptionService`: runs one on-device progressive transcriber per audio source, merges their shared timeline, removes duplicates, and publishes partial words as they arrive.
- `AudioExtractor`: exports only the audio track through AVFoundation.
- `TranscriptionService`: runs a saved-audio fallback pass when the live transcript is too short or unavailable.
- `SpeechAssets`: centralizes Speech permission, locale matching, model installation, and asset reservation.
- `SummaryService`: uses `SystemLanguageModel.default` locally, chunking long transcripts before producing final structured notes.
- `MarkdownCodec`: owns the stable, human-readable file format.
- `MarkdownStore`: scans, saves, edits, and reveals Markdown files without a database.
- `MeetingCoordinator`: owns the recording state machine and temporary-file lifecycle.
- `NotchPanelCoordinator`: measures the display’s camera-safe geometry and animates a borderless SwiftUI panel directly out of the physical notch area.
- `NookSnapshot`: a development-only renderer used to verify real SwiftUI layouts offscreen across appearances and window sizes.

## Failure behavior

- Permissions errors are shown in the notch panel with a direct System Settings button.
- If live captions pause, the recording continues safely and Nook retries from the saved audio before summarizing.
- If Foundation Models is unavailable or generation fails, notes use the heuristic summarizer.
- Transcription failures preserve temporary audio so a failed session can be recovered manually.
- Finished MP4 containers are deleted. M4A audio is deleted unless the keep-audio setting is enabled.
