# Changelog

Nook follows a user-facing release-note model. Each published version has a
Markdown note in [`Releases/`](Releases/) and a matching `v<version>` release in
the [binary releases repository](https://github.com/wrnsnng/nook-releases/releases).

## Unreleased

Nothing yet.

## 1.7.0

- Added dictation. Hold a shortcut anywhere on the Mac, speak, and Nook types
  what you said into whatever text field already has focus. Settled words appear
  as you speak them, and a small indicator by the pointer shows what Nook is
  currently hearing.
- Dictation offers four styles: **Verbatim** keeps every word, **Clean up**
  removes hesitations and stutters, **Polish** rewrites rambling speech as
  written prose, and **Custom** follows an instruction you write yourself.
- Every rewrite is checked against what was actually said. When the wording
  drifts too far, your own words are typed instead, so a dictated question is
  written down rather than answered.
- The dictation shortcut is fully configurable, including modifier-only
  combinations such as holding Control and Option on their own, with a choice
  between hold-to-talk and press-to-start-and-stop.
- Dictation is off by default and asks for Accessibility access only when you
  switch it on. It captures the microphone alone, needs no screen recording, and
  everything stays on the Mac.
- Added a guided first-run setup that explains Nook’s local workflow and walks
  through microphone, speech recognition, and both macOS system-audio consent
  layers before the first recording.
- Prepared the source project for public collaboration under the Apache License
  2.0, with the Nook identity covered by a separate trademark policy.
- Builds from source now mark themselves in the menu bar, so a development build
  and an installed release can be told apart at a glance.

## Current release

- [1.7.0](Releases/Nook-1.7.0.md) — current stable release, build 13.

## Previous releases

- [1.6.4](Releases/Nook-1.6.4.md)
- [1.6.3](Releases/Nook-1.6.3.md)
- [1.6.2](Releases/Nook-1.6.2.md)
- [1.6](Releases/Nook-1.6.md)
- [1.5](Releases/Nook-1.5.md)
- [1.4](Releases/Nook-1.4.md)

Release-note files should be named `Releases/Nook-<version>.md`, committed with
the version change, and describe user-visible behavior rather than internal task
history. `MARKETING_VERSION` maps to `<version>` and the GitHub tag; the numeric
`CURRENT_PROJECT_VERSION` is the monotonically increasing Sparkle build number.

See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the release checklist.
