# Nook interface audit

Audit date: 29 July 2026  
Scope: top panel, live meeting workspace, meeting library, settings, keyboard and
VoiceOver semantics, light/dark/increased-contrast/reduced-motion behavior.

## Anti-pattern verdict

**Fail — the app has a strong native foundation, but several surfaces still read
as assembled from independent experiments.**

The main tells are overuse of decorative glass and capsules, four unrelated
accent families, 99 one-off font sizes, nested rounded surfaces in the notes
experience, and a toolbar that mixes app-level and document-level actions.
These patterns obscure the otherwise distinctive top-edge interaction.

## Executive summary

- Critical: 0
- High: 8
- Medium: 7
- Low: 3
- Quality score before remediation: 6.4/10

The most important work is to establish semantic design tokens, make foreground
contrast independent of the glass behind it, replace the compact recorder with
an actually unobtrusive state, and give notes/library actions a clear ownership
model.

## Remediation result

The release pass resolves all high- and medium-severity findings above:

- The UI now uses one quiet-cobalt brand accent plus semantic success, warning,
  danger, and speaker colors. The app icon follows the same cool palette.
- Semantic text roles replace primary-surface one-off sizing. Direct fixed-size
  font calls fell from 99 to 39; those remaining are almost entirely SF Symbol
  geometry, compact status art, and tightly constrained decorative states.
- Essential copy no longer uses tertiary foreground styling. The live
  accessibility inspection also caught and removed a forced-white inactive
  sidebar selection in light mode.
- Compact capture is a centered 286×30 top-edge rail. Pause/resume stops file
  output and transcription ingestion, freezes elapsed time, and rejoins local
  recording segments at completion.
- My Notes has an always-available accessible editor, explicit safe-save
  feedback, and an independent floating window.
- The library is grouped into Today, Yesterday, This Week, and month sections;
  empty summary rows disappear; blank notes and conversation-derived fallback
  titles are supported.
- Selected-note actions live in the meeting header/context menu, while the only
  global creation action is New note.
- Library and floating-notes windows promote Nook into the Dock and Command-Tab,
  then return it to menu-bar-only behavior after those windows close.
- The running native app was inspected through its accessibility tree in light
  and dark appearances across the library, settings, error recovery, title,
  tabs, editor, and standard About panel.

Residual risk is limited to exercising pause/resume against a fully
Developer-ID-signed capture build on physical hardware; that verification is
part of the release checklist rather than an unresolved interface defect.

## High-severity findings

### A1 — Foreground contrast depends on changing glass

- Location: `NotchPanelView`, `LiveMeetingView`, `SettingsView`
- Category: Accessibility / Theming
- Impact: Secondary and tertiary labels become difficult to read when the
  wallpaper, system appearance, or hover tint changes behind the material.
- Standard: WCAG 1.4.3 Contrast (Minimum)
- Recommendation: Use opaque semantic foreground colors for essential text and
  reserve material transparency for the shell, not text-bearing nested panels.

### A2 — Fixed type values prevent a coherent hierarchy

- Location: all files in `Nook/UI`
- Category: Accessibility / Theming
- Impact: 99 direct `.system(size:)` calls produce small 9–10 point labels,
  inconsistent headings, and layouts that do not scale predictably.
- Standard: WCAG 1.4.4 Resize Text
- Recommendation: Introduce semantic typography tokens and migrate every primary
  surface to those roles.

### A3 — My Notes is an oversized low-contrast inset

- Location: `NotchPanelView.LiveNotesPanel`
- Category: Accessibility / Responsive
- Impact: The editor consumes almost the entire panel, its supporting text is
  9-point tertiary text, and there is no way to keep notes visible independently
  of the camera-aligned transcript.
- Standard: WCAG 1.4.3, 1.4.11
- Recommendation: Use a paper-like editor with an explicit label, strong
  foreground/background contrast, and a detachable floating window.

### A4 — Recording cannot be paused

- Location: `MeetingCoordinator`, `CaptureService`, recording controls
- Category: Interaction / Privacy
- Impact: Users must end a recording to exclude a sensitive or irrelevant
  section, losing the continuity of the meeting note.
- Recommendation: Pause both file output and live transcription, visibly freeze
  elapsed time, and resume into the same final note.

### A5 — Compact recording remains a window-sized object

- Location: `NotchPanelMetrics`, compact branch of `NotchPanelView`
- Category: Responsive / Interaction
- Impact: A 520×96 panel blocks content even after the user asks it to collapse.
- Recommendation: Reduce compact mode to a thin, living audio rail with
  progressive disclosure on hover/click.

### A6 — Library actions have unclear ownership

- Location: `LibraryView.toolbar`, `MeetingDetailView.toolbar`
- Category: Interaction / Information architecture
- Impact: “New recording” is global while Copy Markdown and Show in Finder apply
  only to one selected note, yet all appear in the same toolbar hierarchy.
- Recommendation: Keep one global “New note” action and move document operations
  into the selected meeting header/context menu.

### A7 — The library has no useful grouping

- Location: `LibraryView.sidebar`
- Category: Information architecture
- Impact: A growing flat list becomes slow to scan and gives no temporal
  orientation.
- Recommendation: Add stable smart groups (Today, Yesterday, This Week, month)
  without changing the portable Markdown storage model.

### A8 — Library windows do not participate in normal Mac switching

- Location: `AppDelegate`, `AppModel`
- Category: Accessibility / macOS integration
- Impact: The app remains an accessory after opening its library, so users cannot
  Command-Tab back to it.
- Recommendation: Adopt regular activation while a library/notes window is open
  and return to accessory status after the final normal window closes.

## Medium-severity findings

### A9 — Empty summaries reserve a blank row

- Location: `LibraryView.MeetingRow`
- Impact: Meetings without a nutshell show unexplained whitespace between title
  and metadata.
- Recommendation: Render the summary only when it contains meaningful text.

### A10 — Fallback titles are all date-based

- Location: `SummaryService.heuristicSummary`
- Impact: Without Apple Intelligence, the library becomes a list of
  “Meeting — Day 00:00” entries.
- Recommendation: Derive a conservative short title from the first meaningful
  transcript passage when the on-device model is unavailable.

### A11 — Completed panel requires explicit interaction

- Location: `NotchPanelCoordinator.phaseDidChange`
- Impact: A finished meeting leaves a large panel over the user’s work.
- Recommendation: Keep the result available for several seconds, then dismiss
  automatically while preserving the saved note.

### A12 — Retroactive notes require editing raw Markdown

- Location: `MeetingDetailView`
- Impact: The feature technically exists but is undiscoverable and unsafe for
  non-technical users.
- Recommendation: Add an editable My Notes section with explicit save feedback.

### A13 — Accent colors communicate style more than meaning

- Location: `NookPalette` and all UI surfaces
- Impact: Coral, apricot, iris, lagoon, and leaf compete for attention and behave
  differently between themes.
- Recommendation: Use one cool brand accent, semantic success/warning/danger
  colors, and source-specific tints only where speaker identity matters.

### A14 — Small icon-only controls have weak focus affordance

- Location: notch controls, summary refresh, sidebar footer
- Impact: Keyboard and VoiceOver users can reach most controls, but the visible
  focus/hover target is often only 22–30 points.
- Standard: WCAG 2.4.7 Focus Visible, 2.5.8 Target Size
- Recommendation: Give icon controls a minimum 30-point Mac hit region, visible
  keyboard focus, accurate labels/hints, and stable ordering.

### A15 — Recorder presentation state lacks an explicit contract

- Location: `MeetingCoordinator.showLiveCaptions`
- Impact: The setting doubles as both “captions enabled” and “panel expanded,”
  making persistence and menu wording ambiguous.
- Recommendation: Treat it as the persisted workspace presentation state and
  make compact/expanded labels consistent everywhere.

## Low-severity findings

### A16 — Decorative gradients and shadows are repeated

- Location: `NookAmbientBackground`, panel shell, banners, shelves
- Recommendation: Consolidate these into reusable surfaces and remove shadows
  where material separation is already sufficient.

### A17 — Status wording changes between surfaces

- Examples: Live/Recording, Finish/Stop, New note/New recording.
- Recommendation: Use one vocabulary: Recording, Pause/Resume, Finish, New note.

### A18 — Processing UI contains decorative geometry

- Location: `LiveMeetingView.processing`
- Recommendation: Preserve progress clarity while reducing concentric circles and
  visual weight.

## Patterns and systemic issues

- Semantic design roles are missing; view files directly choose size, weight,
  material, and color.
- Glass is used both as the outer spatial metaphor and as a generic control
  treatment. Only the top-edge shell needs the stronger material identity.
- The app already exposes many useful accessibility labels, but visual focus,
  contrast, and target geometry lag behind its semantic coverage.
- Several requested features already have partial infrastructure: the panel mode
  and expanded state persist, Markdown can already be rewritten, and the summary
  model already produces a title. The UI does not make those capabilities feel
  complete.

## Positive findings

- The panel is anchored to real menu-bar/camera safe areas instead of drawing a
  fake notch.
- Reduced Motion is respected in the major animated surfaces.
- Transcript rows combine speaker, text, and timestamp into useful VoiceOver
  elements.
- Notes remain portable Markdown and the system audio capture is deliberately
  minimal.
- Permission failures have typed recovery routes and correct settings links.

## Remediation order

1. Introduce semantic color, typography, spacing, surface, and control tokens.
2. Rebuild notes, compact recording, and recording controls on those tokens.
3. Add pause/resume and segment-safe audio extraction.
4. Correct library grouping, titles, notes editing, and action hierarchy.
5. Add regular-app activation while normal windows are visible.
6. Verify light, dark, increased contrast, reduced motion, keyboard order, and
   VoiceOver output in the running native app.

## Suggested fix workflows

- `/normalize` for A1, A2, A6, A13, A15, A16, and A17.
- `/harden` for A4, A8, A10, A11, and A12.
- `/adapt` for A3, A5, A7, and text-scaling behavior.
- `/polish` after functional verification for A14 and A18.

## 1.2 regression audit — 29 July 2026

This pass followed the live-meeting, library, Markdown, detached-notes, and About
paths reported during MacBook testing.

### Resolved

- **Personal notes persistence:** saving now rewrites the freshest on-disk note,
  reads it back, decodes it, and verifies the saved `My notes` value before the UI
  reports success.
- **Editor focus:** empty-state copy disappears while the editor has focus, so
  the insertion point no longer overlaps the placeholder. Saving also resigns
  focus predictably.
- **Selected sidebar contrast:** the library now owns its selected-row rendering
  instead of combining AppKit selection styling with a second background. White
  selected text uses a deeper adaptive blue, and VoiceOver receives
  `isSelected`.
- **Color semantics:** `My notes` uses the app accent instead of the speaker
  purple.
- **Detached notes:** opening the floating notes window removes the duplicate
  notes mode from the notch and returns the notch to Transcript. Ending,
  processing, failing, or cancelling a meeting closes the floating window.
- **Notch controls:** the expanded header is reduced to Pause/Resume and Finish;
  compact controls remain visible without hover and meet contrast requirements.
- **Responsive live shelf:** full text controls yield to labelled icon controls
  when horizontal space or text size cannot accommodate them without wrapping.
- **About icon:** the About surface loads the bundled cobalt icon resource rather
  than the potentially stale LaunchServices application icon cache.

### Verification

- 22 automated tests pass, including real temporary-directory Markdown
  persistence/read-back and same-note draft-refresh tests.
- Light and dark library, expanded-notch, and compact-notch snapshots were
  reviewed. A low-contrast compact control state found during that review was
  corrected before release.
- The signed app was exercised through macOS accessibility and screenshots:
  recording, responsive live controls, note detachment, meeting completion,
  window cleanup, selection state, editor focus, Markdown refresh, and both
  About surfaces were verified in the running Release build.
