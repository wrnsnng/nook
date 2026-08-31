# Design and accessibility acceptance, 31 August 2026

This is the acceptance ledger for Nook's existing product and accessibility
contract. The full design/accessibility objective remains open. It does not add
features or claim Apple Design Award readiness from test counts or visual polish.

Requirements come from [PRODUCT.md](PRODUCT.md) and
[ACCESSIBILITY.md](ACCESSIBILITY.md). Implementation history and detailed
limitations remain in [HANDOFF.md](HANDOFF.md) and
[the review follow-up](REVIEW_FOLLOWUP_2026-08-31.md).

## Status and evidence rules

- **Pass:** the specific criterion and conditions named in the row were checked.
  A synthetic layout pass is not a VoiceOver, hardware, or whole-surface pass.
- **Partial:** relevant implementation or evidence exists, but the complete
  criterion is not established, or a measured limitation remains.
- **Not verified:** no accepted evidence establishes the stated criterion for
  this pass. A missing manual check is not, by itself, a proven defect.

The latest evidence includes **1,040 passing integrated Xcode tests, zero failures
and skips**, two passing Python tests, snapshot/optimized builds with warnings
treated as errors, and 145 unchanged source/project fingerprints. Production
source is uninstrumented. E1 now includes native editing/composition and complete
accessibility text, sorted Library publication, exact Unicode recording updates,
restored-note recovery and appended-audio ownership regressions. These extend the
prior captured-identity, Reminders concurrency/source validation and
summary failure-provenance and numeric-grounding regressions; E36 records the scoped UUID lookup
benchmark. E34 verifies selected native handoff/recorder/filing-menu cases on
969; E35 exercises real summary Cancel and preserves the failure baseline that
led to the provenance fix. The 990 fixture initially waited for unlock (E37), then passed scoped keyboard
checks (E38). Native regeneration exposed invented numeric facts (E39). E40 later rejects
an ungrounded result while retaining content on 1,002, with a terminal-newline
caveat. E41 verifies byte-preserving whitespace preflight/Cancel and unobstructed
native error/title layout on 1,009; E42 verifies retained-copy and long-notice
layout/selection in a synthetic native host. E43 measures the identity cache at
component level; E44 records the initially locked matching Release fixtures.
E45 now verifies the native comparison after unlock: less normalization and a
shorter but still substantial Library pause, with exact saves and Undo/Redo.
E46 measures the subsequent editor/Library candidate in both 20,000-word shapes;
E47 verifies native dead keys and selection plus complete native accessibility
text in the hosted test. The candidate removes the measured long-paragraph
typing hang but retains a separate roughly 257 ms post-save List/layout pause.
E48 measures the final controller guards on the 1,040-test source: about 11–12%
less post-input main-thread CPU and 11% less List traversal in both shapes.
Typing and broad layout work are essentially unchanged. Its different CPU
template does not establish that E46's remaining pause is fixed.
Earlier renders retain their
recorded scope. This is not complete accessibility, hardware or release acceptance.
This includes conflict/failure-notice, layout, playback, live-transcript
follow-state, palette focus/name, Quick Note empty-validation and notice
host-identity corrections, plus the empty saved pad's Discard eligibility.
Native checks verify warning clearance before Saved on exact Redo, corrected
Discard availability without clicking it, and replacement scroll reset for an
identical long notice. Final uninstrumented receipts verify cold/warm immediate
palette typing with selected-note isolation, and scoped transcript follow,
history, native bottom return, paused reopen, short visibility and reset flows.
The later uninstrumented 902 receipt also verifies editor selection/exact Undo,
dirty-draft alert handling and many/empty/one-result navigation. Settled short
and one-result layouts pass; first-painted-frame appearance remains unverified,
not a proven UI defect. AttributeGraph cycle cause remains unknown. The 902
panel/recovery refinement adds non-color status cues, Reduce Motion press policy
and file identification, with six offscreen renders; real settings and VoiceOver
remain unverified.

The 913 batch adds assistant availability/cancellation/shutdown and final-draft
recheck regressions, ten offscreen assistant/conflict renders, and native
light/dark Settings/header/chooser/footer plus immediate palette query/safe
Return checks. Active-CLI native Quit and final-save alerts remain unverified.
Additional 902 checks pass direct toolbar-to-Ask and settled Ask input, but two
immediate palette-to-Ask-then-type attempts left the field empty; cause is
unattributed, not a proven Nook defect. Native full-Library refresh and parent
teardown are not established by deterministic presenter tests.

The earlier live attempt was blocked by a locked Mac. A later isolated fixture
launch omitted `Nook.debug.dylib`, causing launch failure and UI timeouts despite
an on-disk signature check. Copying all matching executable components and
re-signing the fixture restored native UI access; this was fixture packaging,
not a production Nook defect. A native receipt on the 849-test binary
establishes palette query isolation, My notes caret/selection restoration, raw
Markdown and sidebar-search selection restoration, native Undo and an unchanged
source-file hash. Ask received final focus. Its two failures, Quick Note initial
focus and palette query/Close names, were corrected and verified on the 870-test
binary. That native receipt also verifies silent-audio playback controls and an
actual detail error's persistence and dismissal. Ten static fixtures passed on
the 870-test build. A1 remains partial; those scoped passes do not establish all
variants, VoiceOver or real capture. Enabled-button live appearance remains
unverified. Static Ask
fixtures, including the long-question progress state at 560 × 380, passed in
light and dark appearances without invoking a model.

An earlier read-only settings observation reported VoiceOver, Reduce Motion,
Reduce Transparency, Increased Contrast, and full keyboard access off. The later
Keyboard pane observation records Keyboard Navigation off and no microphone
found. The latest isolated replay rechecked Keyboard Navigation and VoiceOver,
both off, and the same missing-microphone warning (E34). E38 later temporarily
enabled Keyboard Navigation and VoiceOver with approval, then restored both off.
Full Keyboard Access was observed off and not changed. Other preferences were
not changed. Screen-reader speech/cursor acceptance was not established. Tab not moving in an earlier sheet check, with full
keyboard access reported off, neither completes keyboard acceptance nor proves
a Nook keyboard defect.

### Evidence register

Paths below are relative to the repository root; subsequent bare filenames in
a row share the first artifact's directory. The `.build` artifacts are
ignored local evidence and will not exist in a clean checkout. Keep this durable
summary with the source; retain the matching local artifacts for verification.
Do not publish raw traces, accessibility trees, environment metadata, or real
meeting content. Older app captures prove only their recorded version and case;
they are not automatically reruns of the latest 1,040-test source.

| ID | Authoritative evidence | What it establishes and limits |
| --- | --- | --- |
| E1 | `.build/performance-review/library-editing-20260901/integration/attempt-05/build-acceptance.json` | Final September 1 integration: 1,040 tests, zero failures/skips, two Python tests, snapshot/optimized builds with warnings as errors, and 145 unchanged source/project fingerprints. Native editor composition, exact Unicode replacement, full accessibility text, sorted Library publication, recovery races and appended-audio ownership extend prior coverage. Six additional tests verify quiet controller refreshes while retaining exact revision authority, independent Reminders receipt/error changes and cancellation. Native versions/cases remain separately scoped; numeric grounding is not semantic proof. |
| E2 | `.build/performance-review/design-batch-acceptance.json` | Synthetic Ask answer/refusal attribution, long answer, and long progress-question footer in both appearances; 560 × 380 long-question canvas; no real model invoked. |
| E3 | `.build/performance-review/design-ui-80331fe5/palette-baseline-evidence.json`, `accessibility-settings-observed.json`, `manifest.json` | The old overlay left the underlying editor focused and inserted the query there; its field stayed empty and background AX controls remained exposed. Settings observation establishes the recorded settings only. The manifest records the repaired isolated bundle's executable components. These are not a post-fix focus pass. |
| E4 | `.build/performance-review/storage-ui-89001288/acceptance.json` | Synthetic light/dark counts, long paths, partial/missing/link states, scrolling, reachable Done/footer, Return/Escape, reopen, and a harmless Review in Library callback. Full Tab, VoiceOver, Finder reveal, and minimum-screen checks were not completed. |
| E5 | `.build/performance-review/ui-591ee2b2/scope-acceptance.json` | Synthetic Cancel retains range/owner/exact draft; Save writes before scope change; Show All retains the query; conflict keeps both versions; Markdown AX name/hint present. Does not establish full VoiceOver or focus traversal. |
| E6 | `.build/performance-review/ui-suggestions-b96bf64a/personal-recovery-acceptance.json`, `quick-recovery-acceptance.json`, `undo-redo-acceptance.json` | Completed My notes/Quick Note checkpoints recovered after owned-process SIGKILL, exact text/fresh UUIDs, originals retained, completed records removed; exact Quick Note Undo/Redo. My notes includes decomposed Unicode. Does not cover every interruption point or every last keystroke. |
| E7 | `.build/performance-review/ui-suggestions-b96bf64a/analysis-summary.json`, `.build/performance-review/ui-async-e939f21e/contiguous-ready-comparison.json` | Instrumented long-note observations with explicit coverage and category limits. Single runs are not end-to-end input latency, energy, peak-memory, shipping-build, or minimum-hardware acceptance. |
| E8 | [HANDOFF: unreleased draft recovery](HANDOFF.md#unreleased-draft-recovery) | Earlier full-app Markdown restart/save/conflict and duplicate-file checks; synthetic recovery-sheet keyboard/layout checks and process/disk-image checks. Preserve its stated version and scope limits; these were not all repeated on the latest binary. |
| E9 | `.build/performance-review/design-layout-baseline/acceptance.json` | Baseline static renders confirm clipped Markdown conflict instructions at 900 × 580 and clipped long failure-banner cause/recovery text at 560 × 180. Quick Note conflict instructions/controls fit at 380 × 240 in light/local and dark/Codex fixtures, including the persistent provider warning; exact source/draft checks pass. Live UI was not completed because state requests timed out. No provider invocation or screen-reader behavior is established. |
| E10 | `.build/performance-review/design-ui-80331fe5/palette-native-849-acceptance.json` | Native checks on the 849-test binary establish query isolation; My notes caret/selection, raw Markdown and sidebar-search selection restoration; native Undo; and an unchanged source-file hash. Ask final focus was observed. Its Quick Note initial-focus and palette query/Close name failures are preserved as baseline; E11 checks their corrections. Remaining A1 variants, complete keyboard and actual VoiceOver are excluded. |
| E11 | `.build/performance-review/design-ui-80331fe5/native-870-acceptance.json` | On the 870-test binary: distinct palette query/Close names; Quick Note cold-open/re-raise focus, immediate typing, retained text, exact Redo and eventual save; silent-audio no-match playback clock/Stop/tab-departure; actual detail error visible for 25.81 seconds until Dismiss with original file exact. Undo grouped both typing episodes together. A transient stale empty-note warning appeared after Redo; E14 checks its correction. No real capture, audio quality, full keyboard or VoiceOver pass. |
| E12 | `.build/performance-review/design-integration-20260831/layout-acceptance.json` | Ten static 870-build fixtures: complete Markdown conflict text and Save/Revert at 900 × 580; normal failure text/Dismiss at 560 × 180; bounded pathological failures; no-match transcript transport at 560 × 580; Quick Note conflict at 380 × 240 in light/dark, including the Codex warning. Source/draft exactness checked. Static pathological rendering does not prove scrolling or dismissal; no provider, audio or system-permission operation. |
| E13 | `.build/performance-review/notice-ui-7a95b865/baseline-acceptance.json` | Separate light/dark 560 × 300 native notice fixture: long/short reflow, final instruction reachable by scrolling, Dismiss outside scroll and light dismissal. Repeating a long result retained the old bottom position despite a new UUID; E15 checks that correction. No actual VoiceOver, full keyboard or OS-setting acceptance. |
| E14 | `.build/performance-review/design-ui-80331fe5/quick-validation-875-acceptance.json` | Native 875-test app: cold focus, exact text saved, empty warning established, Redo restores exact text and clears the warning before Saved. It found the empty saved pad's disabled Discard control; E16 checks its correction. No deletion was attempted. |
| E15 | `.build/performance-review/notice-ui-7a95b865/identity-acceptance.json` | Dark 560 × 300 native notice fixture after the host-identity correction and matching 875-test integration: prior notice at the end, fresh identical notice starts at the top, Dismiss remains reachable and clears it. Closes that recorded replacement-scroll failure only; earlier light/dark end/reflow scope stays in E13. No VoiceOver or system-settings claim. |
| E16 | `.build/performance-review/design-ui-80331fe5/quick-discard-881-acceptance.json` | Native 881-test app: new empty pad disables Discard; exact text saves; Undo to empty establishes the warning and enables Discard; Redo restores exact text and clears the warning before Saved. Original fixtures unchanged. No Discard click or real Trash action, so this is an eligibility/state pass only. |
| E17 | `.build/performance-review/live-follow-ui-6494a046/baseline-acceptance.json` | Native 881-build replay of production `LiveMeetingView` at 900 × 650 using synthetic updates only. Passes initial bottom, wheel-history position through Append/Partial, Jump to bottom and paused reopen without a revision. Found content-growth/latest-partial, Jump-surface and AX/Page Up discoverability failures; E18 checks corrections. A physical scrollbar drag did expose Jump. No real capture or VoiceOver proof. |
| E18 | `.build/performance-review/live-follow-ui-6494a046/scroll-correction-acceptance.json` | Native 890-build synthetic replay: light/dark growth follows latest and Jump is opaque/readable; light AX-history and Page Up show Jump, history stays at its passage through Append/Partial, Jump returns to latest, and paused reopen works without a revision. First AX assignment encountered a retired element; a fresh observation/retry reached history. Found the 62-to-one blank viewport; E20 records the unsuccessful clamp candidate. No real capture, VoiceOver, physical momentum, resize/compact or input-latency acceptance. |
| E19 | `.build/performance-review/design-ui-80331fe5/palette-881-acceptance.json`, `palette-initial-focus-890-failure.json` | Baseline: Up/Down, query focus, Return-selected-note and AX exclusion pass. One immediate query lost a character during a build; six subsequent idle trials passed. The 890-build `defaultFocus` candidate still lost leading characters and changed background selection. E21 records final immediate-input correction. No physical backdrop or toolbar-origin focus pass. |
| E20 | `.build/performance-review/live-follow-ui-6494a046/short-content-clamp-893-acceptance.json`, `short-content-clamp-893-failure.png`, `short-content-clamp-893-failure.txt` | Baseline 893-build repeat passes growth/history/Jump/reopen but fails 62-to-one visibility despite its automated result. AX assignment needed a fresh observation/retry. History/growth screenshots expired before archival; failure image/text retained. E22 records the successful final correction; this historical receipt is not a current-failure claim. |
| E21 | `.build/performance-review/design-ui-80331fe5/palette-final-acceptance.json`, `palette-traditional-editor-acceptance.json`, `palette-traditional-probe-acceptance.json` | Final uninstrumented 901 build: cold/warm immediate Cmd-K then `discard`, no readiness wait, exact query and selected-note isolation through Close/Escape. Separate instrumented 901 receipts establish synchronous attached/key/field-editor flags, many/empty/one layouts, Return dispatch, My notes selection and unsaved Markdown selection/exact 11,705-character Undo with original hash unchanged; E25 adds later uninstrumented editor/dispatch acceptance. Initial short-sheet capture compresses the parent; cause unknown, no blanket opening-appearance pass or proven UI-defect claim. No full A1, VoiceOver, toolbar or backdrop pass. |
| E22 | `.build/performance-review/live-follow-ui-6494a046/interaction-final-acceptance.json` | Final uninstrumented 901 production-view replay, 900 × 650. Light: growth to 61 follows; focus visible passage then Page Up; Append/Partial to 62 preserves passage 051 position; Jump; second Page Up then native AX scrollbar 1 reattaches; paused hide/reopen at revision 5; short one at revision 6 visible; reset 60 has no false Jump. Dark: direct 60-to-one visible. Four final screenshots archived immediately and visually inspected. Fixed-size synthetic flow only, no capture, physical momentum, resize, VoiceOver or latency acceptance. |
| E23 | `.build/performance-review/design-ui-80331fe5/cycle-debugger-attempt.json` | AttributeGraph cycles remain unattributed. Owned LLDB attachment stayed pending for over 70 seconds; no backtrace obtained. Owned debugger processes were terminated cleanly; no speculative source fix or proven user-visible defect is inferred. |
| E24 | `.build/performance-review/design-integration-20260831/panel-accessibility/foreground/visual-acceptance.json` | Six offscreen synthetic renders on the 902 build: two fully wrapping filenames, filename-specific Finder names, explicit primary recovery title text and controls fit at 360 × 580 in light/dark. Panel flag/checkmark and recording-dot/pause-glyph states retain the existing footprint. Tests verify Reduce Motion press policy retains fill/opacity feedback. Never-key-window renders are not native pressed-state, real preference, keyboard, VoiceOver or physical display acceptance. |
| E25 | `.build/performance-review/design-ui-80331fe5/a1-902-acceptance.json` | Uninstrumented 902 native receipt: 14 passing checks. My notes selection; exact dirty Markdown/selection through dismissal; dispatch opens Save/Discard/Cancel; Cmd-K during the alert is not queued; Cancel retains the draft; Undo restores exact 11,705-character original and disables Save/Revert. Many-to-empty Return is a no-op; replacement one-result Return selects the safe note. Original file hash unchanged. Settled short and one-result screenshots visually pass at 560 × 121. First-painted frame, toolbar/backdrop, custom shortcuts, live data refresh, parent teardown and complete keyboard/VoiceOver remain unverified. |
| E26 | `.build/performance-review/design-integration-20260831/assistant-accessibility/visual-acceptance.json` | Ten offscreen 913 renders: unavailable/running/stopping Quick Note and Codex conflict cases retain full synthetic note, warnings and controls at 380 × 240 light/dark. Unavailable Settings chooser/footer fits at 620 × 540. The animated spinner and offscreen segmented header are excluded. Injected assistant stubs are released; no real provider, native keyboard/VoiceOver, OS setting or hardware acceptance. |
| E27 | `.build/performance-review/design-ui-80331fe5/native-913-acceptance.json` | Native 913 light/dark Settings at 620 × 628: real header, chooser, local description and full persistent-default footer pass; menu choices name providers and Escape leaves On this Mac selected. Dictation stays off. Immediate Cmd-K/query/safe Return passes; original file hash unchanged. Light restored, Settings closed, no OS preferences changed. No native unavailable engine, provider invocation, active-CLI Quit, final-save-alert or full accessibility/hardware pass. |
| E28 | `.build/performance-review/design-ui-80331fe5/a1-902-additional-acceptance.json`, `keyboard-settings-observed-20260831.json` | Seven additional 902 native checks pass arrows/query focus, sidebar selection, direct toolbar-to-Ask immediate typing, settled Ask input and original hash. Two immediate palette-to-Ask-then-type attempts left Ask empty; delivery/dismissal/focus cause is unattributed. Toolbar keyboard-focus restoration remains unverified. Separate read-only Keyboard pane observation records Keyboard Navigation off and no microphone found; no setting changed or other accessibility preference rechecked. |
| E29 | `.build/performance-review/design-ui-80331fe5/a1-handoff-baseline-913.json` | Native 913 baseline: immediate palette-to-Ask input leaves the question empty and changes parent selection; direct toolbar input passes. Cmd-W did not establish parent teardown, and external file replacement did not establish a full-Library refresh cycle. Original file restored exactly. E34 later verifies the 934 in-place handoff correction natively on 969. |
| E30 | `.build/performance-review/design-ui-80331fe5/shortcut-window-baseline-913.json` | Native 913 baseline: after arming Settings Search Commands recorder and using the Window menu to Library, ordinary search typing is swallowed; recorder remains armed with rejection. Escape cancelled; shortcuts remained at defaults. E34 verifies corrected window cancellation/arbitration and keyed customization on 969. Physical modifier-only recording remains open. |
| E31 | `.build/performance-review/design-ui-80331fe5/filing-duplicate-baseline-913.json` | Native/AX 913 baseline: two identically named duplicate filing choices without file disambiguation. Neither target clicked; synthetic files unchanged. Screenshot omitted the popover, so no visual-layout claim. E32 adds retained-copy warning fit/state checks; E34 verifies duplicate filtering, independent target and retained pad through Review Copies/re-raise on 969, without filing or Trash. |
| E32 | `.build/performance-review/design-integration-20260831/keyboard-handoff/attempt-04/visual-acceptance.json`, `native-replay-deferred.json` | Two individually inspected offscreen 934 filing-copy-retained renders at 380 × 240 points, light/dark: full two-line warning, Review in Library, Dismiss, empty editor, provider control and Done fit. Production fixture validators verify one append, exact retained source, simulated Trash failure and fresh pad before/after capture. No presented-panel lifetime, action/focus, real Trash, VoiceOver or settings pass. At that point native replay was deferred by a locked Mac. Later E34 supplies selected native checks on 969; it does not exercise retained-copy failure actions. |
| E33 | `.build/performance-review/design-integration-20260831/merge-regeneration/attempt-04/visual-acceptance.json`, `native-replay-deferred.json` | Two individually inspected 380 × 180 offscreen light/dark actual summary-progress cards: full headline, five-digit part/total and Cancel fit. Static, activation-prohibited presentation only; no real model, button action, focus, VoiceOver, preference or animated-presence acceptance. The matching 969 build receipt remains in the same directory. Native replay was deferred at that point; E34–E35 later establish selected native checks on that build. |
| E34 | `.build/performance-review/native-replay-34c5d990/native-969-acceptance.json`, `manifest.json`, `accessibility-prerequisites.json` | Uninstrumented 969 native replay: immediate palette-to-Ask typing and exact parent-selection return; recorder window cancellation, same-window arbitration and Escape; custom Shift-Cmd-K handoff, defaults restored; duplicate filing targets excluded while an independent target and warning remain; Review Copies/re-raise retains saved pad. Filing menu is AX/interaction evidence, screenshot omitted popover. No filing/Trash, provider, Reminders, capture or VoiceOver. Keyboard Navigation and VoiceOver off; no microphone found; settings unchanged. |
| E35 | `.build/performance-review/native-replay-34c5d990/regeneration-fallback-baseline.json`, `regeneration-cancel-acceptance.json` | Real on-device generation on synthetic 969 source exposed salvage incorrectly reported as success, replacing the existing summary/title. Underlying model failure unknown; baseline retained. A second attempt exercised Cancel and retained the exact pre-attempt file after 99.52 seconds. This is real cancellation evidence, not acceptance of the first fallback result. E1 adds deterministic correction coverage. |
| E36 | `.build/performance-review/identity-lookup-20260831/summary.json`, `analysis.md` | Production identity/model types with a synthetic notes-array lookup wrapper; 13,054 compatibility comparisons. Five interleaved optimized trials, no build/profile overlap: 1,000-note last lookup median 2.282 to 0.083 ms, 10,000-note last 23.104 to 0.793 ms. First-row cost unchanged. Not native typing latency or closure of the Library/long-paragraph stalls. |
| E37 | `.build/performance-review/native-final-f5adc5a9/manifest.json`, `native-replay-deferred.json` | Complete 990 app copied with all matching executable components, plain audit-library launcher, isolated identity and synthetic library, ad-hoc signature verified. Initially locked before launch/replay. The user later unlocked the Mac; E38–E39 record subsequent native results. The specific provenance-failure branch was not reproduced; E1 is its deterministic evidence. |
| E38 | `.build/performance-review/native-final-f5adc5a9/native-990-keyboard-acceptance.json`, `accessibility-settings-restored.json` | Actual 990 Keyboard Navigation pass: immediate Ask typing, Tab/Shift-Tab order, example Space, Cancel Space/exact selection return; fresh-editor Tab/Undo; Privacy-to-storage keyboard entry, ten-control traversal skipping unavailable buttons, visible focus automatically scrolled into view, Escape/reopen/Refresh/Return and opener focus restoration. Note bytes unchanged through keyboard checks. Both approved temporary settings restored off; Full Keyboard Access off, unchanged. VO commands did not establish cursor/feedback, so no screen-reader pass. No live slow-scan Cancel, Finder, deletion, recovery traversal or capture. Earlier inherited Undo-prefix anomaly is retained, not reproduced in fresh editor. |
| E39 | `.build/performance-review/native-final-f5adc5a9/regeneration-grounding-failure.json`, `regeneration-before.md`, `regeneration-ungrounded-after.md` | Real on-device generation on 990 reports success but invents 18 participants/18 minutes/40 discussion items from numbered repetitive transcript lines. Native screenshot and exact before/after source retained. This is a grounding failure, not a summary-quality pass; it did not exercise failure-provenance retention. |
| E40 | `.build/performance-review/native-grounding-2754acc3/native-1002-regeneration-retention.json`, `regeneration-retained-wrong-copy.png` | Real 1,002 on-device run reports ungrounded output and retains all existing content. Only file difference is removal of one terminal newline at an unestablished stage; not an exact-byte native pass. Raw model output not captured, so the numeric rejection branch is not separately proven. Old notice falsely says only transcript remained; E1 tests corrected regeneration-specific copy. Captured notice partly overlays the title. Mac relocked before Dismiss/canonical-baseline retry/final-copy replay; both temporary settings had already been restored. |
| E41 | `.build/performance-review/native-notice-b9d4aaf2/native-1009-notice-newline.json`, `title-validation-notice.png`, `notice-dismissed.png` | Uninstrumented 1,009 native app: a deliberately whitespace-only My notes draft reaches Saved during actual regeneration without changing any of 11,719 original bytes. Cancel is activated during the first progress stage; source remains exact, including its final newline, 257.10 seconds later. A real empty-title error reserves space above the complete title/header; Dismiss retains selected text and exact source. Two preceding successful generations are preserved but do not count as retained/cancelled byte evidence. The corresponding pre-fix regression fails all three terminal-linebreak variants. No real model refusal, VoiceOver or new system-preference acceptance; fixture closed normally. |
| E42 | `.build/performance-review/notice-layout-2dd2441a/native-1009-notice-layout.json`, `.build/performance-review/design-integration-20260831/notice-newline/attempt-01/layout-acceptance.json` | 1,009 native dark 560 × 420 component fixture: long→short→long→Dismiss preserves selected text, full heading/editor access, bounded message and reachable Dismiss. The short message uses corrected production retained-note copy; no model runs in this host. Six notice/detail light/dark offscreen renders pass their scoped layouts. Two additional offscreen Library sidebars render blank and are excluded from sidebar acceptance; E41's actual sidebar/toolbar are visible. Simultaneous Library/detail failures at minimum height and VoiceOver announcements remain unverified. |
| E43 | `.build/performance-review/library-layout-20260831/component-summary.json`, `component-analysis.md` | Five interleaved optimized production-model trials: 1,000 FileManager-URL identity reads fall from 3.623 to 0.085 ms median; normalization moves to construction/reassignment at about 3.6 ms per 1,000 notes. All 2,002 URL-source cases match and 1,001 synthetic file digests remain unchanged. Note value stride grows by 32 bytes plus retained path storage. No native frame/input-latency, peak-memory or stall-resolution claim. |
| E44 | `.build/performance-review/library-layout-20260831/baseline-manifest.json`, `after-manifest.json`, `native-comparison-deferred.json` | Matching 1,009/1,015 Release app copies, full source fingerprints and identical synthetic libraries use isolated identities and verified ad-hoc signatures. The initial attempt stopped before baseline launch because the Mac was locked. E45 records the completed comparison after unlock; the initial block remains historical evidence. |
| E45 | `.build/performance-review/library-layout-20260831/native-comparison.json`, `native-comparison.md`, `library-attribution.md` | One matching 30-second Release pair with the same 20,000 words/200 paragraphs, 460-point window and 32-character suffix. Target-only samples cover the complete input and subsequent updates; no concurrent analysis or inspection. Main URL-normalization samples fall 157.6→0.7 ms, grouping fingerprint 36.1→1.7 ms, and the detected Library microhang 311.908→253.474 ms. Sampled typing work is essentially unchanged. Both saved bodies and 1,001 original files remain exact; cached-build native Undo/Redo and Saved pass. Both apps quit normally. Source remains the accepted 1,015 build. Single-pair, symbolication and sampling limits apply; list/layout, long-paragraph, minimum-hardware, memory and energy acceptance remain open. |
| E46 | `.build/performance-review/library-editing-20260901/matched-comparison.json`, `matched-comparison.md` | One fully covered, target-only Release pair per 20,000-word shape. One-paragraph sampled native key handling falls 885.0→131.9 ms and text layout 858.8→27.6 ms. Recorded Library row-child updates fall 5,010→4,008 in both shapes. The old 894 ms typing hang is absent; a 257 ms post-save List/layout microhang remains in the one-paragraph candidate. Exact Save/Undo/Redo and 1,001 original-file hashes pass; both apps quit normally. This uses the earlier 1,034-test production state, before the final controller changes; its added accessibility declaration is test-only. No per-key, energy, minimum-hardware or physical accessibility claim. |
| E47 | `.build/performance-review/library-editing-20260901/editor-targeted/attempt-03/Tests.xcresult`, `after-native-dead-key-save.json`, `after-native-selection-save.json` | Hosted real editor: 18 declarations/30 cases cover editing, checklist selection, exact Unicode replacements, focus, simulated composition, and complete accessibility text/character count including offscreen Unicode/CRLF after scroll/resize. Actual app Option-e/e produces é, and middle-word replacement preserves surrounding multilingual text exactly on disk. This does not test physical Japanese/Chinese/Korean input methods, VoiceOver speech/caret behavior or dictation. |
| E48 | `.build/performance-review/library-list-final-20260901/accepted-cpu-comparison.json`, `accepted-cpu-comparison.md`, `cpu-export-receipt.json`, `cpu-hang-export-receipt.json` | Final 1,040-test controller source against E46's production candidate, one accepted matching Time Profiler pair per 20,000-word shape. Target-PID filtering and complete input-relative coverage pass. Four-second post-input main CPU falls 481→424 ms for 200 paragraphs and 484→432 ms for one paragraph; List traversal falls 286→256 and 285→253 ms. Typing and broad layout are essentially unchanged. Exact Save/Undo/Redo and all 1,001 original hashes pass; both apps quit normally. Two final SwiftUI recorder finalization failures and an initial 1,003-note CPU baseline are excluded; accepted libraries each have 1,002 notes. All four CPU potential-hangs tables are empty, including the baseline, so this does not establish that E46's 257 ms interval is fixed. No SwiftUI update/group/hitch schema is available. Single pairs, final-before-baseline order, burst cadence and 1 ms sampling limit the comparison; no human input-latency or broad responsiveness claim. |

## Surface and state matrix

Action IDs refer to the concrete remaining checks below. “Partial” applies to the
whole criterion even when a narrower behavior has a recorded pass.

| Surface / state | Required experience | Status and evidence | Remaining action |
| --- | --- | --- | --- |
| Menu bar: idle, recording, paused | Recognizable state and timer without color alone; current actions; menu items remain stable while its clock ticks. | **Not verified** for live interaction in this pass. Implementation and contract exist; synthetic tests are not real recording/menu acceptance. | A5, H1: open the menu while recording/paused, hold pointer/focus on an item across timer ticks, and use pause/finish independently. |
| Top panel: idle confirmation | Clear start action, unobtrusive appearance, correct physical position. | **Not verified** for current live/display acceptance. | A2–A3, H1–H2. |
| Top panel: meeting detected | Explicit Record / Not now choice; detection never starts capture by itself. | **Not verified** for current live consent/focus acceptance. | A5, H1: detect a synthetic meeting, decline, then accept in a separate case. |
| Top panel: expanded recording | Transcript, Summary, and My notes are usable; pause, finish, and collapse are independent; live text does not steal editing focus. | **Not verified** for full live interaction. | A2–A3, A5, H1–H2; type/select/undo while transcript and meters update. |
| Live transcript: follow/latest/history/reopen | New words stay visible while following; history holds its passage; Jump remains legible; short content stays visible. | **Partial:** final E22 corrects the recorded short-content failure and passes scoped growth/history/Jump/native-bottom/reopen/reset flows. Dark final evidence is direct 60-to-one only. Full navigation, physical momentum, resize, VoiceOver and capture remain open. | A2–A3, A6 and H1; preserve E22's exact sequence. |
| Top panel: compact recording | Timer/waveform and transport remain understandable; expand/hide do not conceal the route to finish. | **Partial:** E24 offscreen flag-to-checkmark feedback retains the footprint; motion policy is tested. Full live keyboard/VoiceOver and physical placement remain unverified. | A2–A3, A5, H1–H2. |
| Top panel: hidden recording | Restore is reachable; a person can still pause/finish without finding an invisible control; adjacent menu items remain usable. | **Partial:** E24 offscreen recording-dot/paused-glyph states provide non-color feedback without resizing. Physical geometry and full keyboard/VoiceOver remain unverified. | A2–A3, A5, H1–H2; finish through alternate menu/Dock/shortcut routes. |
| Top panel: processing | Progress has a name; available Cancel/discard is unambiguous; waiting does not masquerade as a saved note. | **Not verified** for announcements and real processing/cancellation. | A2, A5, H1. |
| Top panel: completed | “Meeting saved” corresponds to completed persistence; Open notes reaches the right file without focus surprise. | **Partial:** persistence paths have automated coverage (E1); this complete live transition is not established. | A5, H1; inspect saved source and focused destination. |
| Top panel: permission/start/capture error | Explain the exact setting or recovery action; Retry/settings/dismiss stay reachable without losing retained work. | **Not verified** for actual macOS prompts and error presentation. | A2–A3, A5, H1. |
| Dictation: off, listening, settled text, rewriting, insertion failure | Explicit opt-in and microphone state; settled words go only to the intended field; errors preserve the sentence and clipboard; controls remain reachable. | **Partial:** output-guard and lifecycle regressions pass (E1). Real speech, cross-app insertion, permission recovery, and indicator accessibility remain unverified. | A5, H1, H3. |
| Library: loading, load failure, empty library, empty Today, no matches | Distinct explanations and next actions; progress is named; feedback does not cover navigation; Show All preserves the query. | **Partial:** scope/search behavior and actual empty-search presentation were inspected (E5, follow-up); full state announcements and small-window failure layout remain open. | A2–A4. |
| Library: browse/search/scope and source identity | Predictable native selection; preserve owner, query, and unsaved words; duplicate UUIDs never select an arbitrary file. | **Partial:** scope/conflict tests and synthetic live cases pass (E1, E5, E8). Full Tab/VoiceOver and all transition combinations remain open. | A1, A2, A4. |
| Detail: Notes / My notes / title | Comfortable reading; normal cursor, selection, Undo/Redo; committed and unfinished states distinguishable; background updates preserve words. | **Partial:** exact My notes restart recovery and scope continuity pass (E5–E6); native palette cancellation restores its caret/selection and Undo returns the original text (E10). Live capture-driven focus and complete keyboard flow remain open. | A2–A5, H1. |
| Floating Notes: detach/edit/close/reopen | Shared live notes remain intact and editable; the detached window has a normal cursor/selection and does not steal focus during transcript updates; closing it does not stop access to meeting controls. | **Not verified** as a complete detached-window workflow in this pass. Shared editor regression coverage does not establish this interaction. | A2–A5, H1; detach, edit from each surface, close/reopen, and verify the resulting personal notes. |
| Detail: raw Markdown, dirty/save/revert/conflict | Explicit save/revert; Save/Discard/Cancel retain the right owner and exact source; conflict never falsely reports success. | **Partial:** exact save/conflict/restart and AX name/hint evidence exists (E5, E8); palette query isolation, selection restoration and native Undo pass (E10). E12 corrects the E9 baseline clipping: full conflict text and Save/Revert fit at 900 × 580 in light/dark. Full assistive and remaining live layout flow remain open. | A1–A4. |
| Detail: transcript/search/audio/flagged moments | Search and scrolling reach all content; source/time remain understandable; optional playback has independent, named controls and honest unavailable/error states. | **Partial:** large transcript observations and playback regressions exist (E1, E7). E11 verifies generated-silence playback with no-match clock/Stop and tab-departure stopping; E12 verifies transport layout. Real capture/audio quality and VoiceOver traversal are not accepted. | A2–A4, A6, H1. |
| Quick Note: blank/editing/count pending/saving/saved/suggestion/conflict/discard | A normal editor; pending statistics do not imply lost text; suggestions never act on stale words; discard is safe; Return inserts a line. | **Partial:** exact saves, Undo/Redo, recovery and worker/suggestion safety pass in recorded cases (E1, E6–E7). E11 corrects focus; E12 retains narrow conflict controls/Codex warning. E16 corrects Discard eligibility and preserves exact Redo/warning clearance, without clicking Discard. Actual confirmation/deletion, full keyboard, hands-free capture, accessibility settings and live narrow-window behavior remain open. | A1–A4, A6, H3; keep fake-deletion tests distinct from a native deletion pass. |
| Note actions / summary regeneration: progress/cancel/refusal/error/completion | The action and provider are clear; progress/cancel stay reachable; failures and late results cannot replace newer writing; successful output retains supported meaning and editability. | **Partial:** action-output, availability, cancellation, stopping disclosure, bounded quit and final-save regressions pass (E1); E26 covers named narrow static states. E35 exercises on-device Cancel and records the provenance failure; E40 records native rejection with a newline caveat. E41 verifies corrected whitespace preflight/Cancel with the exact original bytes; E42 verifies corrected retained-copy presentation in a synthetic host. Native provider operation/quit, final-save alerts, remaining regeneration outcomes and full assistive flow remain open. | A2–A4, A7; test edits during work, cancellation, unavailable provider/model, refusal, and save failure. |
| Record into a note / merge saved notes | The chosen file and consequence are clear; personal notes survive; multiple sittings, transcript gaps, and retained audio remain in chronological order. | **Partial:** ownership/combination, draft settling, both-source/audio validation, partial/uncertain completion, queued scope and clean-editor refresh regressions pass (E1); complete merge-picker keyboard/VoiceOver and real appended-capture flows are not accepted. | A2–A4, A7, H1; merge earlier into later and later into earlier, then inspect exact note/audio outcomes. |
| Command palette: open/query/arrows/selection/cancel/dispatch | Query owns focus from initial typing; cancel preserves caret/selection; correct row runs once; destination retains focus. | **Partial:** E21 immediate-input checks and E25 uninstrumented editor/Undo, alert, many/empty/one dispatch and settled short-layout checks pass. E27–E28 retain query/arrow/search passes. E29 records the 913 Ask handoff failure; E34 verifies its in-place correction, exact selection return and a custom shortcut natively on 969. First frame and cycles remain unverified/unattributed. | Complete A1: remaining dispatch timing, toolbar/backdrop and shortcut variants, native live data refresh/parent teardown and full keyboard/VoiceOver. |
| Ask: initial/examples/question draft | Useful local examples and a named field; entering the next question does not relabel the previous answer; cancel preserves underlying note drafts. | **Partial:** session regressions and synthetic attribution pass (E1–E2). E28 passes direct toolbar and settled Ask input; E29 records a later handoff failure. E34 verifies the in-place correction on 969; E38 adds 990 Keyboard Navigation tab/example/Cancel and exact selection-return checks. Full VoiceOver and real answer flow remain open. | A1–A4, A7. |
| Ask: progress, answer, refusal, error, dismissal | Submitted question stays attached; progress/error is understandable; Cancel remains reachable; cancellation rejects late results; citations stay within the owning library. | **Partial:** answer/refusal/long-question layouts and cancellation/ownership regressions pass (E1–E2). No actual model was invoked for those fixtures; announcements and cross-window folder changes need live acceptance. | A2–A4, A7. |
| Prep / Open actions / Digest | Clear source attribution and omission warnings; complete/due/export commands name their consequence; no stale or ambiguous mutation. | **Partial:** deterministic aggregation/ownership and Reminders concurrency, retry and stale-source coverage pass (E1); duplicate warnings were inspected (E8). No real EventKit save occurred in those tests. Full keyboard/VoiceOver, calendar context, and Reminders export remain open. | A2–A4, A7, H4. |
| Recovery: preview, invalid/stale source, export, save, discard, failure | Read-only review first; exact source remains recoverable; footer actions stay reachable; Return must not accidentally discard; failures remain actionable. | **Partial:** specific live sheet, exact-save and restart cases pass (E6, E8). E24 verifies narrow offscreen filenames, distinct Finder names, primary titles and reachable controls. Full keyboard/VoiceOver and complete interruption matrix remain open. | A2–A4, A8; keep durability limits explicit. |
| Duplicate-file review | Each file is identifiable; retained draft stays separate from disk source; unsafe editing is refused; Finder/refresh remain reachable. | **Partial:** file-specific source/search and retained-draft checks pass (E1, E8). Long-path, keyboard, and VoiceOver cases need completion. | A2–A4. |
| Settings: storage overview | Honest scoped counts and partial/missing/unavailable status; long paths readable; scan cancel/reopen safe; review/reveal never silently deletes writing. | **Partial:** basic light/dark layout and Return/Escape/reopen/review callback pass (E4); scanner regressions pass (E1). E38 adds actual ten-control Tab order, skipped unavailable buttons, visible scrolled focus, Refresh and Escape/Return with opener focus restored. Finder reveal, full VoiceOver, slow-scan Cancel, other preferences and minimum-screen fit remain open. | A2–A4, A8. |
| Shortcut recording | Only the owning Settings window receives recorded keys; cancellation is clear; modifier-only and keyed bindings retain their distinct policies. | **Partial:** E30 reproduces cross-window swallowing on 913. The 934 suite tests exact window identity, deactivation/close/detach cleanup, one active recorder per window and modifier policies. E34 verifies native window switching, same-window arbitration, Escape and keyed customization. Physical modifier-only and full assistive acceptance remain open. | A1–A3, A5: physical modifier-only input, complete keyboard/VoiceOver and remaining shortcut variants. |
| Quick Note filing | An unambiguous current meeting receives the words once; partial success names retained copies and keeps the next draft independent. | **Partial:** E31 records duplicate-choice ambiguity. The 934 suite covers duplicate/stale refusal, failed source removal, persistent warning and fresh next draft. E32 adds narrow static warning/controls and state validation. E34 verifies native duplicate filtering, independent target, warning and retained pad after Review Copies/re-raise. Actual filing/partial-failure window lifetime, menu layout and Trash remain open. | A2–A4, A7: complete menu layout/assistive flow and actual filing; use controlled deletion failures, not unrequested real Trash. |
| Settings: appearance, shortcuts, privacy/provider consent, retention | Native controls with unique names; visible current state; shortcuts/hints agree; external processing and destructive retention require explicit choices. | **Partial:** binding, consent and policy tests pass (E1); E27 passes named native light/dark assistant Settings/header/menu/footer cases. Complete settings traversal, live preference-dependent visuals and provider invocation remain open. | A2–A3, A5; H3–H4 where permissions are involved. |
| Cross-surface failure notices | The cause and recovery instruction are readable; no critical step disappears into truncation or an inaccessible transient message. | **Partial:** E12 corrects static clipping; E11 verifies actual persistence/Dismiss. E13/E15 verify long-message scrolling and replacement reset. E41 now reserves native title/header space and preserves selection through Dismiss; E42 verifies long/short/long reflow and corrected retained-copy presentation. Simultaneous Library/detail failures at minimum height and full announcement/keyboard flow await acceptance. | A2–A3, A5. |
| Welcome/setup and errors | Plain rationale before permissions; no unexplained blank/dead end; returning from Settings/relaunch preserves a usable recovery route. | **Not verified** as a complete fresh-install accessibility flow. | A2–A3, A5, H1. |

## Cross-cutting checks

| Criterion | Status | Evidence and remaining boundary |
| --- | --- | --- |
| Ask synthetic answer/refusal attribution, long answer, and long-question progress footer at 560 × 380 in light/dark | **Pass, synthetic layout only** | E2. The question and reachable Cancel were inspected without a model. Does not establish announcements, Tab order, or real generation. |
| Storage fixture counts, long paths, scroll/footer and Done, Return/Escape, reopen, review callback | **Pass, recorded fixture only** | E4. Finder, assistive technology, and smallest-screen fit were explicitly excluded. |
| Quick Note conflict at 380 × 240, light/local and dark/Codex | **Pass, static fixture only** | E9, repeated in E12. Full conflict instruction and controls fit; persistent Codex warning remains visible; source/draft checks pass. This does not establish provider operation or screen-reader behavior. |
| Wrapped Markdown conflict, normal/bounded failure notices and no-match transport | **Pass, named static fixtures only** | E12 closes the recorded E9 clipping cases. Ten renders across both appearances do not establish all live resizing, scroll interaction or accessibility settings. |
| Exact draft/save/Undo behavior in the recorded scope and restart cases | **Pass, named cases only** | E5–E6 and E8. No claim that every keystroke survives termination or every save phase was interrupted. |
| Palette query isolation and cancellation restoration in My notes, raw Markdown and sidebar search | **Pass, recorded native cases only** | E25 uninstrumented checks verify My notes selection, exact dirty Markdown/selection, guarded dispatch, Cancel and exact Undo. Sidebar-search restoration retains its E10 scope; not every editor case was repeated. |
| Palette immediate input boundary | **Pass, recorded native cases only** | E21: cold/warm immediate Cmd-K then exact query, no readiness wait; Close/Escape preserve selected note. E25 verifies immediate query isolation from both editors and settled short layouts. First-painted frame, full keyboard, physical backdrop and toolbar-origin focus are excluded. |
| Palette dirty-draft alert and many/empty/one result transitions | **Pass, recorded 902 native cases only** | E25: dispatch presents Save/Discard/Cancel, Cmd-K during the alert is not queued, Cancel retains exact draft; empty Return does nothing and verified single-result Return navigates. No destructive action, live result-data refresh or parent-teardown pass. |
| Silent-audio no-match playback and actual detail-error persistence | **Pass, recorded native cases only** | E11: clock advances, Stop is reachable and works, tab departure stops playback; a real detail error persists for 25.81 seconds until Dismiss with its original file exact. No audio quality, capture or full assistive-technology acceptance. |
| Long-notice scrolling, reflow and replacement | **Pass, recorded native cases only** | E13 establishes light/dark end/reflow and reachable Dismiss. E15 closes the repeated identical-result bottom-retention failure in the dark fixture and verifies Dismiss. These checks do not establish all replacements, full keyboard or VoiceOver. |
| Notice/title separation and editor continuity | **Pass, recorded 1,009 cases only** | E41 verifies an actual detail error leaves the title/header unobstructed and Dismiss retains selected text and source bytes. E42 verifies long/short/long notices and selection in the dark component fixture. E1 checks native editor identity/first responder at two widths. Concurrent notices, full keyboard and VoiceOver remain open. |
| Quick Note empty-warning recovery and Discard eligibility | **Pass, recorded native state checks only** | E14 verifies warning clearance; E16 verifies a new empty pad disables Discard, an emptied saved pad enables it, and exact Redo clears the warning before Saved. No Discard click or real Trash action; six E1 tests use fake confirmation/deletion. |
| Live transcript history/follow/short content | **Pass, recorded final native replay only** | E22 verifies the full stated light sequence and dark direct shrink; four screenshots retained. Passage focus is established before Page Up. Native bottom uses AX scrollbar assignment, not physical-momentum or VoiceOver proof. |
| Enabled prominent-button text contrast | **Pass, tested color combinations only** | E1 and follow-up: at least 4.5:1 for enabled idle/pressed text in tested normal/high-contrast AppKit appearances and surfaces. Whole-screen, disabled/focus appearance, and live setting changes remain partial. |
| Keyboard traversal and focus return across all surfaces | **Partial** | E21/E25 verify named palette input/editor/alert/Return cases. E22 verifies Page Up after explicit passage focus. E38 adds actual Keyboard Navigation Tab/Shift-Tab, Space, exact Ask selection return, storage traversal/scrolled focus and Escape/Return. Remaining surfaces, physical backdrop and toolbar-origin focus remain open. |
| VoiceOver names, order, actions, dynamic announcements, and background exclusion | **Not verified** | E38 temporarily enabled VoiceOver and restored it off. App-targeted VO commands did not establish cursor movement/activation or spoken feedback; a plain Space on the focused Close button worked. This is a tool/evidence limitation, not a proven Nook VoiceOver defect. AX inspection and synthetic tests do not establish a screen-reader pass. |
| Reduce Motion | **Partial** | Policy tests cover custom press/status scaling, compact/hidden panel presses and Quick Note reflow, retaining fill/opacity feedback (E1, E24). Inspect all transitions with the real setting enabled, including native sheets, while preserving focus/state. |
| Reduce Transparency | **Partial** | Implemented materials/policies do not establish real preference behavior. Inspect text, controls, dividers, disabled states, and overlapping surfaces with the setting enabled. |
| Increased Contrast | **Partial** | Resolved-color and outline/divider policy tests pass. Real setting changes, both appearances, focus, and control states remain open. |
| Auto/Light/Dark and text/window sizing | **Partial** | Some synthetic/live light/dark fixtures pass. Auto switching, every error/long-content state, supported text-size settings, and physical screen fit are not complete. |
| Large-content responsiveness | **Partial; responsiveness gate remains open** | E45 reduces normalization and its Library microhang from 311.908 to 253.474 ms. E46 removes the measured long-paragraph typing hang but retains a separate 257 ms post-save List/layout interval. E48's final controller guards reduce post-input main CPU about 11–12% and List traversal about 11%; typing and broad layout are unchanged, and the different CPU template cannot close E46's pause. E43 retains initialization/memory tradeoffs. Exact saves and single-pair sampled gains do not prove smooth editing. |

Earlier transcript detector intervals of 342–378 ms were associated with
automation's accessibility hierarchy enumeration. They are not evidence of
ordinary search/scroll freezes. The later input-only Quick Note hangs above are
separate observations. SwiftUI **View Body Updates** and **Other Updates** are
different categories, and overlapping inclusive CPU samples must not be added.

## Remaining software acceptance actions

Use synthetic notes and an isolated app identity. Record the exact source/build,
fixture, window dimensions, appearance, macOS settings, actions, observed focus,
and file/checkpoint results. A failure should record its reproducible steps and
expected behavior, not be converted to a pass by widening the claim.

1. **A1, palette and editor boundary, partial:** E10 records query isolation,
   My notes caret/selection, raw Markdown and sidebar-search selection
   restoration, native Undo and unchanged source-file hash on the 849-test app;
   Ask final focus was observed. E11 verifies the corrected Quick Note initial
   and re-raise editor focus and distinct palette query/Close names on the
   870-test app. E21 now passes final cold/warm immediate typing without a
   readiness delay and preserves selected-note isolation through Close/Escape.
   E25 repeats editor selection/exact Undo and many/empty/one/Return cases
   uninstrumented on 902, including the unsaved-draft alert and no queued palette
   after Cancel. Settled short layouts pass; establish first-painted-frame
   appearance separately. Attribute cycle messages only when evidence identifies
   their source. Complete toolbar-origin and physical blocked-backdrop checks,
   remaining shortcut variants, live data refresh/disappearing results, duplicate-file
   rows and active parent teardown. Background controls
   must never receive query typing or backdrop activation, cancellation must
   preserve caret/selection/Undo, and a dispatched window must retain final focus.
   E28 adds arrows/search-selection and direct toolbar/settled Ask passes;
   E29 later reproduces empty Ask and changed parent selection. E34 verifies
   the in-place correction natively on 969, including immediate custom-shortcut
   input, exact selection return, recorder window switching and same-window
   arbitration. E27 retains its immediate query/safe Return scope. Physical
   modifier-only recording and broader assistive traversal remain open.
   E1 presenter refresh/teardown tests do not replace native full-Library checks.
2. **A2, keyboard and VoiceOver:** Record Keyboard Navigation and Full Keyboard
   Access settings explicitly and test the intended enabled modes through
   normal System Settings. Check Tab/Shift-Tab, visible focus, Space/Return,
   Escape/default actions, and context menus. With VoiceOver enabled, complete
   note editing, conflict resolution, recovery, storage review, and playback;
   verify names/order/actions and one understandable progress/success/failure
   transition without stealing the writing cursor. Confirm decorative and
   background modal content do not obstruct navigation. Restore the tester's
   prior settings after the checks.
3. **A3, appearance/settings/geometry:** Inspect normal and Increased Contrast
   in light/dark, Reduce Transparency, and Reduce Motion using real macOS
   settings. Include enabled idle/hover/pressed, disabled, and keyboard-focused
   controls. Check library at its 900 × 580 minimum, Ask at 560 × 380, the
   460-point Quick Note performance fixture and 380 × 240 conflict fixture,
   recovery at its supported minimum, and storage's
   620 × 620 sheet on the smallest supported display. Exercise long paths,
   long questions/refusals, invalid source, and save failures. Footer actions
   must remain reachable; supported text-size changes must not overlap controls.
   Include simultaneous Library and detail failures at minimum window height;
   E41/E42 establish single-notice cases only.
4. **A4, continuity and boundaries:** Repeat search, Today/All, reload, source
   conflict, duplicate appearance, window reopen, and Save/Discard/Cancel while
   each editor has unsaved text. Keep exact Unicode/whitespace and file owners.
   Switch library folders through another window with Ask/palette open, while
   dismissing, and during a delayed/failed reload. Old citations/commands must
   not target matching UUIDs in the new folder; reopening must explain a stale
   snapshot. A same-folder reload must not close a valid Ask session.
   Include the detached Floating Notes window and both merge orderings; verify
   personal notes and file ownership through each transition.
5. **A5, status/consent/control:** Walk every menu/top-panel/setup state in the
   surface matrix. Check that recording, pause, saving, saved, failure, and
   local/external processing have distinguishable text/shape/name, not color
   alone. Confirm independent recovery/transport controls and exact permission
   guidance. Connect simulated state checks to H1 before claiming real capture.
   E15 verifies a new identical long notice resets to the top with Dismiss
   reachable; complete the remaining keyboard/announcement and replacement
   variants. E16 verifies the corrected empty saved Quick Note's Discard
   eligibility; still verify its deliberate confirmation/deletion flow without
   changing unrelated notes. Retain exact Redo and warning-clearance behavior.
6. **A6, large content:** Use the recorded 1,001-note/3,000-passage transcript
   and 20,000-word one/200-paragraph pads. Check search, scrolling, selection,
   editing, Undo/Redo, exact save, and assistive traversal. Keep input-only
   profiling separate from accessibility hierarchy inspection. Record remaining
   hangs rather than calling detector silence a smoothness pass. Repeat on
   representative supported hardware before making broad responsiveness claims.
   E45 completes the captured-identity comparison with the same 200-paragraph
   pad, 460-point editor and 32-character suffix, with complete coverage and
   recorder exit before inspection. E46 then reduces long-paragraph editing
   work but retains a 257 ms post-save List/layout pause. E48 reduces subsequent
   post-input CPU with controller publication guards; the CPU-template detector
   is silent for both variants, so it cannot establish that pause is fixed.
   Investigate remaining list/layout and grouping-cache invalidation separately,
   preserving exact saves and Undo/Redo. Repeat controlled captures rather than
   treating one pair or a different template as broad responsiveness acceptance.
   For live transcripts, scroll back with a trackpad, scrollbar, keyboard, and
   VoiceOver while partial/final lines arrive; history must stay readable until
   returning to the bottom or choosing Jump to latest. Test touching a trackpad
   without scrolling, momentum, resizing, short content, and paused reopen.
   E22 now passes the recorded light growth/history/Jump/native-bottom/reopen/
   short/reset sequence and dark direct short-content case at 900 × 650.
   Extend that coverage to physical momentum, resize/compact, full keyboard and
   VoiceOver without replacing the recorded sequence with a simpler case.
   Preserve the visible passage rather than comparing normalized scrollbar
   fractions across content growth. Do not infer a VoiceOver pass from AX
   scrollbar assignment or hide the recorded AX identity refresh/retry.
7. **A7, Ask and follow-through:** With synthetic source notes, verify a useful
   answer/citation and weak-match refusal, draft question B while A answers,
   retry, and external dismissal. Confirm the submitted question remains clear
   and old results never reappear. Exercise Prep/Digest empty/duplicate/failure
   states and Open actions completion/due controls; test calendar/Reminders
   permissions separately under H4. Do not invoke an external CLI without its
   existing explicit consent path.
   The overlapping-first-export Reminders race now has shared reservation,
   cancellation/retry, fresh-receipt and source/generation recheck regressions
   (E1). Real permission/save acceptance remains separate under H4; process
   arbitration does not close the EventKit-save/receipt crash gap.
   Exercise note actions and summary regeneration through progress, cancel,
   unsupported/refused output, model/provider failure, and save failure while
   preserving newer edits; check the editor's existing Undo behavior after
   completion.
8. **A8, recovery and storage:** Complete per-record review/save/export/discard
   using keyboard and VoiceOver. Verify long/stale/invalid previews, retained
   errors, deliberate destructive confirmation, and Finder reveal of only the
   selected synthetic location. Interrupt normal/recovered save, folder switch,
   and cleanup at additional full-app points. Confirm storage never clears
   drafts/staging files and explains untracked exports/backups/other folders.

## Hardware, permissions, and release gates

These gates are separate from software layout passes. A synthetic coordinator,
permission status stub, disk image, or passing build cannot close them.

| Gate | Status | Required acceptance |
| --- | --- | --- |
| H1: microphones, system audio, capture permissions, real meeting lifecycle | **Not verified in this pass** | E28 and E34's Keyboard pane reported no microphone found. Fresh grant/denial/recovery/relaunch; manual and detected starts; microphone/system audio; pause interval excluded; finish/cancel/failure; real live and saved transcription; append/flag/audio playback. Use consented synthetic speech. |
| H2: physical display geometry | **Not verified** | Notched MacBook and non-notched external display; expanded/compact/hidden positioning, display changes, and neighboring menu items. Check smallest-screen sheet fit and recovery controls. |
| H3: real dictation and input methods | **Not verified** | Hold/toggle/hands-free modes; native Cocoa and Chromium/Electron fields; rejected insertion and clipboard restoration; missing then granted Accessibility permission; question-as-text, repeated characters, Unicode and marked-text composition, selection and Undo. An inactive marked-text probe is insufficient. |
| H4: calendar, Reminders, retained audio | **Not verified as complete live flows** | Explicit opt-in and real OS prompts; calendar naming/Prep; requested reminder carries its due date; chosen retention moves only eligible kept audio and leaves notes untouched. |
| H5: installed update and identity | **Not verified** | Official release signing/notarization/Gatekeeper and update from the prior supported release without losing permissions or notes. Contributor/synthetic app builds do not establish this. |
| H6: external storage and interruption limits | **Partial, synthetic filesystem evidence only** | APFS/HFS+ disk-image cases pass; ExFAT exclusive recovery creation fails closed as documented in HANDOFF. Real drives, unplugging, network filesystems, and power loss remain unverified. Keep that limit explicit; do not promise every-last-keystroke or power-loss protection. |

## Recording the next result

Update the relevant row only after its stated actions complete. Add a sanitized
evidence artifact with the matching source fingerprint, dimensions/settings,
expected and observed outcome, and explicit exclusions. Link its path in the
register and preserve any previous failure as baseline evidence. A screenshot,
automated AX inspection, and a screen-reader interaction establish different
things and should remain separately identified.

No acceptance percentage or award prediction is assigned. Final uninstrumented
integration passes 1,040 tests and snapshot/optimized builds with warnings as
errors. E34 establishes scoped native handoff, recorder and filing-menu passes
on 969; E35 establishes actual summary cancellation and retains the provenance
failure baseline. E37 records the initial lock; E38 later establishes scoped keyboard passes on
990 with both temporary settings restored. E39 preserves a numeric grounding
failure exposed by actual generation. E40 retains content on native rejection
with a final-newline caveat. E41 verifies exact whitespace preflight/Cancel and
notice/title separation; E42 verifies retained-message copy and selection in a
synthetic native host. Concurrent notices and full VoiceOver remain open.
E43 records scoped identity-cache gains and costs; E45 confirms less native
normalization work with a remaining 253 ms Library pause. E46 then demonstrates
the long-paragraph editor gain with a separate 257 ms Library pause still open.
E47 establishes only its named native/accessibility cases.
E48 supports the final controller guards with lower post-input CPU in both
shapes, without establishing another typing gain or closure of E46's pause.
First-painted palette appearance, cycle cause, full A1, native live data refresh/
parent teardown, actual filing/Trash, provider Quit/final-save alerts, VoiceOver,
physical keyboard, real capture and macOS preference acceptance remain open.
Release publication remains subject to the separate candidate acceptance record.
