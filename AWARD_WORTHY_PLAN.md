# Nook: award-worthy product direction

Working standard, 29 July 2026. This document turns the Apple Design Award
research and the current-product audit into a set of product decisions. It is
the acceptance bar for the next Nook release, not a visual mood board.

## What the winners consistently do

The strongest Apple Design Award winners do not win by adding ornament. They
make difficult work feel obvious, give the product one unmistakable character,
and polish every transition until it explains what just happened.

- **Complexity disappears.** Capybara AI Meeting Translator pairs serious
  transcription and summary capability with an immediately understandable,
  endearing interface. Crouton keeps attention on the work rather than the
  screen. Procreate Dreams makes deep capability feel ready out of the box.
- **Personality has a job.** grug's hand-drawn character makes a focused utility
  memorable without adding accounts, cloud infrastructure, or extra steps.
  CapWords uses motion and sound to reinforce learning rather than decorate it.
  Gentler Streak uses warmth to reduce pressure.
- **The interface has one coherent metaphor.** Tide Guide ties color, motion,
  glass, and full-screen data to water. Rooms makes its sounds, visuals, and
  interactions feel like one world.
- **Platform behavior is part of the design.** Mela uses system surfaces and
  integrations at the moment they become useful. Universe pairs visual quality
  with excellent Dynamic Type and VoiceOver support.
- **Accessibility is integrated, not bolted on.** Sago Mini Jinja removes
  reading, timers, and task pressure so thoroughly that the inclusive choices
  almost disappear into the experience.
- **Liquid Glass is a control layer.** Apple's guidance is explicit: content
  leads; glass belongs to navigation and controls, and glass-on-glass should be
  avoided. Tint should be reserved for primary actions and state.

Primary research:

- [Apple Design Awards 2026](https://developer.apple.com/design/awards/)
- [Apple Design Awards 2025](https://developer.apple.com/design/awards/2025/)
- [Apple Design Awards 2024](https://developer.apple.com/design/awards/2024/)
- [Apple Design Awards 2023](https://developer.apple.com/design/awards/2023/)
- [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## Current-product verdict

Nook is useful, native, and unusually well positioned. The top-edge recorder,
fully local pipeline, live transcript, on-the-fly summary, portable Markdown,
and focused library form a product with a real reason to exist.

It is not yet award-worthy.

The remaining gap is not missing functionality. It is authorship. Too many
surfaces still use the visual vocabulary of a generic AI dashboard:

1. Blue-purple ambient gradients compete with meeting content.
2. Cobalt, purple, teal, green, yellow, and red all behave like brand colors.
3. Uppercase accent labels, tinted cards, capsules, and nested rounded
   rectangles make the hierarchy feel assembled rather than inevitable.
4. Detected, listening, processing, completed, and error states use unrelated
   SF Symbols and generic progress art. Nook has no recognizable living state.
5. Onboarding describes features instead of letting someone experience the
   transformation from speech to useful note.
6. Processing and completion are technically clear but emotionally generic.
7. The library is polished but not quiet enough for long-form reading.
8. The Mac integration stops at windows, menu bar, shortcuts, and settings; the
   app can offer a more complete command-and-automation surface.

## The product idea

### A quiet place where conversations settle

Nook should feel less like an AI assistant and more like a small, trustworthy
part of the Mac that quietly catches a conversation, shapes it, and tucks it
away.

The signature visual is a **living conversation thread**:

- At rest it is a small speech seed — Nook is available, not demanding.
- On meeting detection it opens slightly, like attention turning toward a
  conversation.
- While recording, speech creates a restrained, responsive thread.
- During processing, the thread aligns into written lines.
- On save, the lines settle into the Nook mark: the conversation has been
  tucked away.
- On error, the thread pauses rather than becoming a loud warning mascot.

This is not a character that speaks, celebrates, or interrupts meetings. It is a
recognizable state language. Motion is silent, purposeful, and optional.

## Visual system

### Color

- One brand accent: quiet cobalt.
- System semantic colors only for destructive, warning, and success states.
- Speaker identity uses symbol/label structure first; color is supplementary.
- Reading surfaces use system background and text colors with a barely warm
  paper tone, not purple atmospheric light.
- Primary actions may receive accent tint. Secondary controls remain neutral.

### Material

- Liquid Glass is reserved for the top-edge shell, toolbars, mode navigation,
  and transient controls.
- Transcript, notes, summary, and Markdown remain solid reading surfaces.
- No glass-on-glass.
- No material merely to make a section look premium.

### Type and hierarchy

- Rounded display type is reserved for the Nook name and rare welcoming states.
- Meeting titles, summaries, transcripts, and notes use system text roles.
- Section labels use sentence case and natural weight, not tracked uppercase.
- Monospaced type is reserved for timestamps and raw Markdown.
- Every visible label earns its place by explaining content, state, or action.

### Shape

- Concentric corners follow their container.
- Capsules are reserved for compact status and segmented navigation, not every
  action.
- Content hierarchy comes from spacing and typography before borders or cards.
- The speech-seed/thread silhouette is the only distinctive brand shape.

### Motion

- `quick`: 0.16–0.2 seconds for hover and acknowledgement.
- `spatial`: 0.34–0.46 seconds for top-panel resize and state morph.
- `settle`: up to 0.7 seconds for processing-to-saved transformation.
- No perpetual motion except a low-amplitude live audio response.
- Reduced Motion replaces scale, travel, blur, and morph with opacity changes.
- Reduced Transparency and Increased Contrast preserve hierarchy without relying
  on material.

## Experience decisions

### First launch

The opening screen demonstrates the product in place:

1. A sample spoken line appears.
2. The thread turns it into one useful point.
3. The point settles into a local Markdown note.

The user controls the preview and can skip it. Permission requests happen only
after the value and privacy model are clear.

### Meeting detected

Use direct language: “A conversation is starting in Teams.” The app offers
`Record` as the single primary action and `Not this one` as a quiet secondary
action. Nook never implies it already recorded before consent.

### Live meeting

The transcript is camera-adjacent, stable, and readable. Controls stay quiet
until hovered or focused. Transcript, gist, and notes are views of the same
conversation—not three competing buttons. When notes are detached, the top
panel says where they went instead of duplicating the editor.

### Processing

The interface explains the local work in plain language while the conversation
thread aligns into lines. It does not show decorative orbiting circles or
anthropomorphize the model.

### Saved

Use a restrained “Tucked away” moment with the destination and a direct `Open`
action. No confetti, sound, or giant green check.

### Library

Treat the library as an editorial reading space:

- calm neutral canvas;
- a clear chronology;
- one selected meeting at a time;
- summary first, source detail second;
- decisions and action items as readable lines, not colorful dashboard cards;
- editing that feels like writing, not filling a form.

### Mac ecosystem

- Menu bar for ambient presence.
- Dock and Command-Tab while library or notes windows are open.
- Keyboard shortcuts for recording, pause/resume, and finish.
- Dock menu for starting a recording and opening recent work.
- App Shortcuts for starting a recording and opening the library/latest note.
- Standard menus, focus, VoiceOver, appearance, contrast, transparency, and
  motion preferences all remain first-class.

## Delight budget

Nook may delight when the delight:

- teaches the speech-to-note transformation;
- reassures the user that recording is local and under their control;
- makes meeting state legible at a glance;
- rewards completion without stealing focus;
- makes an empty or waiting state feel cared for.

Nook must not use delight to:

- interrupt a meeting;
- make light of permission, privacy, storage, or capture failure;
- add sound while recording;
- turn every control into a custom component;
- prolong a task the user is trying to finish.

## Release acceptance bar

The release is only complete when all of the following are true:

- Every primary state uses the same conversation-thread state language.
- No primary screen relies on a blue-purple decorative gradient.
- Glass is confined to navigation/control layers.
- Light, dark, Increased Contrast, Reduced Transparency, and Reduced Motion all
  preserve hierarchy and legibility.
- Onboarding demonstrates value before requesting access.
- Meeting detection, recording, processing, save, and failure form one coherent
  story.
- The top panel remains centered and camera-adjacent across MacBook and external
  displays.
- Every action has a keyboard and VoiceOver path; visible controls have adequate
  Mac hit targets and focus feedback.
- Library reading and editing remain comfortable at minimum and expanded window
  sizes.
- A clean build, unit tests, snapshot review, and live Computer Use inspection
  pass before signing.
- The release is Developer ID signed, notarized, stapled, and verified on a
  second Mac.

