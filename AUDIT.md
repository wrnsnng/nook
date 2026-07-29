# Nook product audit

Audited 29 July 2026 against the built native macOS app.

## Remediation status

**Resolved in the current packaged build.** The original report below is retained as the pre-remediation baseline.

The rebuilt app was re-audited through Computer Use in light and dark modes. The critical data-loss issue and all high-severity findings were corrected, including title-bar corruption, contradictory search selection, fragmentary transcripts, invisible file failures, folder-switch ambiguity, false checkbox affordances, incorrect accessible names, truncated permission recovery, and synchronous library/search work.

The remediation also added grounded action/decision generation, stable same-timestamp transcript ordering, visible copy confirmation, semantic headings and list items, adaptive-contrast accents, a compact settings window, a quieter sidebar, a Canvas-based audio meter, and explicit high-contrast top-panel actions. Fifteen automated tests now cover the underlying failure modes.

## Original anti-patterns verdict (pre-remediation)

**Fail — the main library currently reads as AI-generated despite several strong native foundations.**

The strongest tells are the repeated glass capsules, decorative ambient gradients, oversized centered empty state, uppercase micro-labels, repeated “stays on this Mac” badges, and multiple controls competing for primary emphasis. The design has personality, but it often decorates information instead of clarifying hierarchy. The top panel is much more coherent because its constraints force restraint.

The biggest problem is not taste, however. `backgroundExtensionEffect()` visibly mirrors and inverts real content into the title bar. This makes the app look broken before a user evaluates any finer design choice.

## Evidence and scope

The audit used Computer Use against the compiled SwiftUI app rather than relying on previews. The following were operated and inspected:

- A populated library containing four real local meeting files.
- Notes, Transcript, and Markdown tabs.
- Matching and empty transcript-search states.
- Library-wide search and selection behavior.
- Dirty Markdown navigation without saving.
- Sidebar shown and hidden.
- Listening, Privacy, and About settings.
- Recording permission failure in the library and standalone top panel.
- Empty-library state.
- Populated and empty light/dark states.
- Live transcript workspace with mixed system/microphone passages.
- Live top panel with four caption lines, captions on and off.

The live state was injected through the app's existing `MeetingCoordinator.setPreviewState` development hook because Screen & System Audio Recording access is currently denied. The rendered windows, controls, accessibility tree, transitions, and panel were the real built app, not static snapshots.

## Executive summary

- **1 critical**, **9 high**, **9 medium**, and **3 low** issues.
- Overall product quality: **54/100**.
- The highest-priority problems are unsaved-edit loss, title-bar rendering corruption, inconsistent search selection, unreliable transcript grouping, and invisible storage errors.
- The top panel's structure, dark-mode palette, local-file model, live speaker separation, and several accessibility labels are worth preserving.

## Critical issue

### C1. Markdown edits are discarded without warning

- **Location:** `Nook/UI/MeetingDetailView.swift:25`, `Nook/UI/LibraryView.swift:190`
- **Category:** Resilience / UX
- **Evidence:** A marker was added to the Markdown editor, enabling Save and Revert. Selecting another meeting immediately replaced the detail view with no confirmation. Returning to the first note showed the original file.
- **Impact:** A user can lose a substantial manual edit by clicking another meeting, closing the window, or allowing the selected note to be replaced after a reload.
- **Standard:** macOS document behavior; WCAG 3.3.6 Error Prevention (AAA).
- **Recommendation:** Treat dirty Markdown as document state. Intercept note changes, window close, storage reload, and destructive navigation with Save / Discard / Cancel. Preserve the draft until a decision is made.
- **Suggested command:** `/harden`

## High-severity issues

### H1. Title-bar extension visibly mirrors and inverts content

- **Location:** `Nook/UI/LibraryView.swift:80`
- **Category:** Visual / Responsive
- **Evidence:** In the running app, meeting titles appeared upside down in the title bar. The live screen also reflected “LIVE” and the privacy badge; the empty sidebar reflected its Meetings header.
- **Impact:** Every main workflow looks graphically corrupted and unfinished. In some note views the real heading is partly obscured while its reflection dominates.
- **Recommendation:** Remove `backgroundExtensionEffect()` from the split view or provide a dedicated, non-semantic background layer that is safe to extend. Keep actual content below the unified toolbar safe area.
- **Suggested command:** `/polish`

### H2. Library search can show a meeting that is absent from the results

- **Location:** `Nook/UI/LibraryView.swift:23`, `Nook/UI/LibraryView.swift:85`
- **Category:** Interaction / State
- **Evidence:** Searching for “Rich” reduced the sidebar to one matching meeting while the detail pane continued showing the previously selected, non-matching meeting.
- **Impact:** The interface contradicts itself. Users can copy, edit, or review the wrong meeting while believing they are operating on the search result.
- **Recommendation:** When filtering begins, retain the selection only if it remains in `filteredNotes`; otherwise select the first result or show an explicit “Choose a result” detail state. Restore the prior selection predictably when search is cleared.
- **Suggested command:** `/harden`

### H3. Short speech fragments are presented as separate “passages”

- **Location:** `Nook/Services/LiveTranscriptionService.swift:196`, `Nook/UI/MeetingDetailView.swift:283`
- **Category:** Core UX
- **Evidence:** A 14-word meeting became six passages: “Hello, this is” / “the” / “live” / “scribe.” / “Um, which” / “I think should be working now.”
- **Impact:** The transcript is difficult to read, creates excessive vertical noise, weakens search context, and feeds low-quality structure to summary generation.
- **Recommendation:** Coalesce adjacent final segments from the same source using punctuation, silence duration, and a bounded time/word window. Store conversational utterances, not raw speech-result emissions.
- **Suggested command:** `/normalize`

### H4. Storage and parsing failures are invisible

- **Location:** `Nook/Services/MarkdownStore.swift:23`, `Nook/Services/MarkdownStore.swift:32`, `Nook/UI/LibraryView.swift`
- **Category:** Resilience / Data trust
- **Evidence:** `lastError` is written but never presented. Unreadable or invalid Markdown files are silently dropped by `compactMap`.
- **Impact:** Meetings can disappear from the app with no explanation even though files still exist. This undermines the core local-file promise.
- **Recommendation:** Publish structured load diagnostics, show a persistent library banner, identify skipped filenames, and offer Reveal in Finder / Retry. Clear stale errors after successful reloads.
- **Suggested command:** `/harden`

### H5. Changing the notes folder looks like data loss

- **Location:** `Nook/Services/MarkdownStore.swift:68`, `Nook/UI/SettingsView.swift:64`
- **Category:** UX / Data continuity
- **Description:** Choosing a new folder immediately switches the library. Existing files are neither moved nor explained.
- **Impact:** The library can suddenly become empty, leading users to believe meetings were deleted.
- **Recommendation:** Make the choice explicit: “Use existing folder” or “Move N meetings here.” Preview the destination, explain that old files remain in the previous folder, and provide a reversible path back.
- **Suggested command:** `/onboard`

### H6. Action items look interactive but are not

- **Location:** `Nook/UI/MeetingDetailView.swift:196`
- **Category:** Interaction / Accessibility
- **Evidence:** Action items use an empty square visually identical to a checkbox, but the row is plain text. The real notes also rendered “None.” as an unchecked action.
- **Impact:** Users try to complete an affordance that cannot respond. Placeholder output adds a fake task.
- **Recommendation:** Either make actions genuine persisted checkboxes or use a non-interactive bullet. Normalize model placeholders such as “None,” “N/A,” and “No action items” to an empty section.
- **Suggested command:** `/clarify`

### H7. Toolbar controls expose incorrect accessible names

- **Location:** `Nook/UI/MeetingDetailView.swift:54`
- **Category:** Accessibility
- **Evidence:** The accessibility tree reported the Markdown-copy button as “Copy” and the folder button as “Move,” with their real purpose only in Help text.
- **Impact:** VoiceOver users cannot confidently distinguish copying Markdown from other copy actions, and “Move” is actively misleading for “Show note in Finder.”
- **Standard:** WCAG 2.5.3 Label in Name; 4.1.2 Name, Role, Value.
- **Recommendation:** Add explicit accessibility labels and values: “Copy meeting as Markdown” and “Show meeting file in Finder.” Announce completion after copying.
- **Suggested command:** `/clarify`

### H8. Permission failure is truncated and its actions look disabled

- **Location:** `Nook/UI/NotchPanelCoordinator.swift:29`, `Nook/UI/NotchPanelView.swift:390`
- **Category:** Accessibility / Error recovery
- **Evidence:** The real 520-point panel clipped the recovery sentence after “Enable Nook…”. Permissions and Dismiss were rendered as very low-contrast gray glass controls.
- **Impact:** The most important recovery state does not fully explain the next step and makes available actions appear unavailable.
- **Recommendation:** Increase the failure width or shorten the copy, make “Open Settings” the clear primary action, use a conventional secondary Dismiss button, and reserve enough contrast independent of the desktop behind the glass.
- **Suggested command:** `/harden`

### H9. Library loading and full-text search run synchronously on the main actor

- **Location:** `Nook/Services/MarkdownStore.swift:4`, `Nook/Services/MarkdownStore.swift:23`, `Nook/UI/LibraryView.swift:23`
- **Category:** Performance / Scalability
- **Description:** Every reload reads and decodes all Markdown files synchronously. Every search keystroke scans title, summary, source, and reconstructed transcript text for every note.
- **Impact:** The four-note library is fast, but a realistic multi-year library will stall typing, activation, and window presentation.
- **Recommendation:** Load/decode off the main actor, cache normalized searchable text, debounce search, and apply results back on the main actor. Add a loading state for large folders.
- **Suggested command:** `/optimize`

## Medium-severity issues

### M1. Timestamps are nearly invisible, especially in dark mode

- **Location:** `Nook/UI/MeetingDetailView.swift:500`, `Nook/UI/LiveMeetingView.swift:440`
- **Category:** Accessibility / Theming
- **Evidence:** Timestamps use tertiary text plus 0.68–0.70 opacity. They were difficult to see in the real dark transcript.
- **Impact:** Low-vision users and anyone scanning a meeting timeline lose orientation.
- **Standard:** WCAG 1.4.3 Contrast (Minimum).
- **Recommendation:** Use secondary label color at full opacity and validate the resulting contrast in both appearances and Increase Contrast mode.
- **Suggested command:** `/colorize`

### M2. Decorative decision icon is announced as “Selected”

- **Location:** `Nook/UI/MeetingDetailView.swift:174`
- **Category:** Accessibility
- **Evidence:** The notes accessibility tree inserted an image named “Selected” between Decisions and its text.
- **Impact:** VoiceOver implies a selection state that does not exist.
- **Recommendation:** Hide the decorative checkmark from accessibility and give the containing section an appropriate heading.
- **Suggested command:** `/harden`

### M3. Notes have weak semantic navigation

- **Location:** `Nook/UI/MeetingDetailView.swift:137`
- **Category:** Accessibility
- **Evidence:** The accessibility tree flattened Summary, Key points, Decisions, and Action items into a small number of long text elements without heading traits.
- **Impact:** VoiceOver users cannot efficiently jump between the document's major sections.
- **Recommendation:** Apply heading traits/levels to section titles and expose list items individually with concise labels.
- **Suggested command:** `/harden`

### M4. Copy actions provide no confirmation

- **Location:** `Nook/UI/MeetingDetailView.swift:423`, `Nook/UI/LibraryView.swift:141`
- **Category:** Feedback
- **Description:** Copy Markdown and Copy transcript update the clipboard silently.
- **Impact:** Users repeat the command or switch applications to discover whether it worked.
- **Recommendation:** Show a brief native confirmation in the toolbar/button label and announce it through accessibility.
- **Suggested command:** `/delight`

### M5. The live control shelf has competing primary actions

- **Location:** `Nook/UI/LiveMeetingView.swift:195`
- **Category:** Visual hierarchy
- **Evidence:** “Notch captions on” is a bright orange glass control next to a bright red Finish meeting button.
- **Impact:** A reversible display preference competes with the meeting-ending action and adds visual weight to the least important control.
- **Recommendation:** Make captions a quiet icon toggle or menu item; reserve prominent color for Finish meeting.
- **Suggested command:** `/quieter`

### M6. “Notch” terminology is now wrong

- **Location:** `Nook/UI/StatusMenuView.swift:27`, `Nook/UI/SettingsView.swift:37`, `Nook/UI/LiveMeetingView.swift:220`
- **Category:** UX writing / Adaptation
- **Evidence:** The UI says “beneath the notch” and “Notch captions” even on an external display and after the simulated notch was removed.
- **Impact:** The product describes hardware that may not exist and makes the external-display experience feel secondary.
- **Recommendation:** Use “top captions,” “top panel,” or simply “live captions.”
- **Suggested command:** `/clarify`

### M7. Sidebar rows are overpacked and heavily truncated

- **Location:** `Nook/UI/LibraryView.swift:246`
- **Category:** Responsive / Information architecture
- **Evidence:** At the real 286–300 point sidebar width, most summaries ended in ellipses and metadata was compressed into a fourth line.
- **Impact:** Rows are tall yet still fail to help users distinguish similarly named meetings.
- **Recommendation:** Prioritize title, date/time, source, and one strong summary line. Move duration or secondary metadata to hover/context. Consider grouping by date.
- **Suggested command:** `/distill`

### M8. Fixed 10–11 point metadata is overused

- **Location:** `Nook/UI/LibraryView.swift`, `Nook/UI/MeetingDetailView.swift`, `Nook/UI/LiveMeetingView.swift`, `Nook/UI/NotchPanelView.swift`
- **Category:** Accessibility / Responsive
- **Description:** Important counts, timestamps, filenames, statuses, and controls repeatedly use fixed 10–11 point sizes.
- **Impact:** Information becomes fragile under larger-text and high-density display settings.
- **Recommendation:** Use semantic text styles where possible, establish a minimum metadata style, and reflow rather than shrink in constrained regions.
- **Suggested command:** `/adapt`

### M9. Audio visualization animates layout at roughly 29 updates per second

- **Location:** `Nook/UI/NookDesign.swift:106`, `Nook/Services/MeetingCoordinator.swift:290`
- **Category:** Performance
- **Description:** Published `audioLevel` updates every 34 ms and drives animated bar heights across up to 36 bars.
- **Impact:** It can trigger broad SwiftUI invalidation and repeated layout during recording, exactly when capture and speech analysis are already CPU intensive.
- **Recommendation:** Isolate the meter observation, reduce update frequency, and animate a drawing/transform rather than laying out every bar on each sample.
- **Suggested command:** `/optimize`

## Low-severity issues

### L1. Empty sidebar consumes space without teaching anything

- **Location:** `Nook/UI/LibraryView.swift:121`
- **Category:** Empty state
- **Description:** With no notes, the sidebar is a large blank column plus a footer.
- **Recommendation:** Collapse it by default for first launch or use it for one concise explanation of where notes will appear.
- **Suggested command:** `/onboard`

### L2. Settings panes leave large unused regions

- **Location:** `Nook/UI/SettingsView.swift:9`, `Nook/App/NookApp.swift`
- **Category:** Layout
- **Evidence:** Listening and Privacy occupy the top half of a fixed 640×540 content frame; About is a sparse centered composition.
- **Recommendation:** Reduce the fixed height or build a more compact native settings layout that sizes to its content.
- **Suggested command:** `/polish`

### L3. Privacy reassurance is repeated too often

- **Location:** `Nook/UI/NookDesign.swift:72`, `Nook/UI/LibraryView.swift:200`, `Nook/UI/LiveMeetingView.swift:89`, `Nook/UI/SettingsView.swift:88`
- **Category:** UX writing / Anti-pattern
- **Description:** Local library, Local, Private, Stays on this Mac, No cloud account, and several explanatory sentences repeat the same fact.
- **Impact:** Repetition dilutes rather than strengthens trust.
- **Recommendation:** Keep one persistent local indicator in the recording context and explain the model fully in Privacy settings.
- **Suggested command:** `/distill`

## Patterns and systemic issues

1. **State is local to views rather than protected as document state.** This causes dirty-edit loss and contradictory selection/search behavior.
2. **The design system treats glass, capsules, tiny uppercase labels, and reassurance badges as defaults.** Hierarchy is often decorative rather than task-driven.
3. **Secondary and tertiary text are used below a practical readable threshold.** Dark mode is cohesive but exposes the contrast problem.
4. **The four-note happy path masks scalability problems.** File decoding, indexing, and search are all synchronous.
5. **The snapshot renderer did not reproduce the title-bar extension behavior.** Visual regression coverage needs at least one launched-window test.

## Positive findings

- The top panel is now genuinely flush with the screen edge and does not draw a fake camera notch.
- Four caption lines remained visible and speaker sources were distinguishable in the real panel.
- The compact captions-off panel is restrained and readable.
- Dark mode has a cohesive warm palette and generally preserves the product's personality.
- Transcript and live rows provide useful combined accessibility labels and timestamp values.
- Panel icon controls have explicit accessibility labels.
- Reduce Motion is respected in most custom transitions and symbol effects.
- Search empty states are clear, and transcript result counts update correctly.
- Notes are ordinary local Markdown files with collision-safe filenames.
- The status menu provides useful keyboard shortcuts for recording, library, settings, and quit.

## Recommendations by priority

1. **Immediate:** Fix dirty-edit protection, remove the broken title-bar extension, synchronize selection with filtered results, and surface file-load errors.
2. **Short term:** Coalesce transcript utterances, correct accessibility names/semantics, redesign the permission state, and make action-item affordances truthful.
3. **Medium term:** Move indexing/search off the main actor, simplify the sidebar and live controls, improve contrast, and remove notch-specific language.
4. **Long term:** Add launched-window visual regression coverage, performance tests with hundreds of long notes, and a deliberate document-management model.

## Suggested remediation sequence

1. `/harden` — data-loss guards, selection integrity, storage errors, permission recovery.
2. `/polish` — remove the title-bar corruption and repair layout hierarchy.
3. `/normalize` — transcript grouping and placeholder cleanup.
4. `/clarify` + `/distill` — labels, affordances, and repeated privacy copy.
5. `/adapt` — sidebar, text sizing, settings sizing, and external-display language.
6. `/optimize` — asynchronous indexing/search and isolated audio-meter rendering.
7. `/audit` — repeat the same Computer Use matrix against the corrected release.
