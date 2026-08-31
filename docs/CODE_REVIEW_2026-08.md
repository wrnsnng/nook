# Code and product review, August 2026

For the latest measured performance results, implemented follow-up and feature
priorities, see the [31 August follow-up](REVIEW_FOLLOWUP_2026-08-31.md).
The findings and test totals below describe the earlier review, not the current
list of unresolved issues.

A full review of the codebase across four angles: reliability, performance,
data handling and safety, and UX/UI. High-severity findings were verified
against source line by line. Nothing here was run against a live capture,
microphone, or real meeting; those paths still need human acceptance per
AGENTS.md.

Findings are grouped by angle with severity, location, and evidence. The
final section is the prioritised fix order.

## Fix status

All ten prioritised fixes were implemented on 2026-08-22 and covered by new
tests; the full suite passes (160 tests, 24 suites). What automated tests
cannot verify, which needs a human at a Mac:

- R1/R2: a real meeting with pause/resume, a stalled recognizer, and the
  saved-audio fallback path.
- R3: live caption quality during an actual long meeting.
- U2: the discard confirmation alert from all three surfaces.
- U3: Return/Esc answering the consent prompt on a real display, including
  that taking focus does not fight the meeting app unacceptably.
- D2: the changed-externally warning against a sync service touching files.

---

## Reliability

### R1 - HIGH - Silent live-track death produces a transcript trusted as complete

`LiveTranscriptionService.swift:311-321`, `MeetingCoordinator.swift:122-157, 654-665`

If a `SpeechAnalyzer` ends its results sequence without throwing (analyzer
teardown, internal Speech framework reset), the `for try await` loop simply
exits. No callback fires, no error surfaces, the transcript silently stops
growing. `LiveTrack` tracks `lastChangedAt` but nothing monitors it.
`liveTranscriptIsComplete` starts true and is cleared only by
`onRecoverableError`.

At stop, `finishRecording` trusts live segments when
`liveTranscriptIsComplete && total text >= 40`, skipping saved-audio
re-transcription entirely. A 2-hour meeting whose system-audio track dies at
minute 20 saves a 20-minute transcript that looks complete. The fallback path
exists but its trigger depends on a flag with a silent false-negative hole.

Fix shape: detect sequence end during an active session as a recoverable
error, and/or sanity-check live segment coverage against recording duration
at finalize time.

### R2 - HIGH - Pause-finalization timeout leaves a phantom recording

`CaptureService.swift:185-209`, `MeetingCoordinator.swift:295-326`

`pause()` removes the recording output inside the finalization waiter. If the
delegate callback exceeds the deadline, the catch resets `isPaused = false`
and reports "capture is still active", but `removeRecordingOutput` already
succeeded: ScreenCaptureKit writes no further audio to disk. The timer runs,
captions flow, and zero audio reaches disk for the rest of the meeting. At
stop, finalization waits 120 s on an output that can never resolve, then the
meeting fails with only pre-pause segments preserved.

### R3 - MEDIUM - Per-buffer unstructured Task hop for capture ingest

`CaptureService.swift:356-390`

Each audio buffer spawns `Task { @MainActor ... }` to deliver level and ingest
live input. AGENTS.md rule 3 documents why unstructured tasks are unsafe:
no ordering guarantee, and the resampling converter in
`LiveTranscriptionService.swift:523` is stateful. Reordered delivery corrupts
recognition subtly. `DictationAudioSource.swift:60-75` already fixed this
exact pattern with a single-consumer `AsyncStream`; CaptureService predates
it.

### R4 - MEDIUM - Orphaned recordings recoverable only via Settings

The only `recovery.scan()` call site is Settings `.onAppear`
(`AppModel.swift:59`). Processing failure correctly preserves audio, but a
user who misses the transient failure message learns nothing on relaunch.
The comment in `RecordingRecovery.swift:5-10` warns against exactly this
hidden loss.

### R5 - MEDIUM - Second terminate request never replies

`AppDelegate.swift:254-282`. A repeat Cmd-Q during long finalization returns
`.terminateLater` without a matching `reply(toApplicationShouldTerminate:)`,
which can hang quit and invite force-quitting mid-write.

### R6 - LOW/MEDIUM - Dictation edge cases

- No maximum-session watchdog: hold-mode plus Secure Input eating the release
  event leaves the microphone hot indefinitely
  (`DictationCoordinator.swift:241-379`, `GlobalShortcutMonitor.swift:164-207`).
- First-use asset download has no deadline while `finish()` awaits it
  unboundedly (`DictationCoordinator.swift:304-351`). Every other await in
  dictation is deliberately bounded; this one is not.

### Lower-severity reliability notes

- Elapsed clock loses up to ~1 s per pause cycle (`MeetingCoordinator.swift:300`).
- Post-recovery leftovers become permanently invisible when removal fails
  after a successful save (`RecordingRecovery.swift:181-185`).
- Recovery scan swallows directory-read failure (`RecordingRecovery.swift:69-75`).
- Dictation tail dropped silently on converter flush failure
  (`DictationRecognizer.swift:127-131`) while the live path reports the same
  condition (`LiveTranscriptionService.swift:354-356`).
- Quit mid-dictation does not tear down dictation (`AppDelegate.swift:161-163`).
- Duplicate identical stop branches (`CaptureService.swift:300-322`).

### Reliability strengths

The state machine cannot double-start or double-finish (synchronous guards
before any suspension). Stop-during-pause-transition is remembered and
replayed. Unexpected capture death converts into a normal finish of whatever
was captured. Processing failure preserves the recording and names the
folder, re-checking disk rather than trusting the failed call's result. Every
wait is bounded, with comments citing the incidents that set each timeout.
No `fatalError`, no empty catches anywhere. Task hygiene is consistent across
all coordinators.

---

## Performance

### P1 - HIGH - Transcript republish rebuilds everything per update

`LiveTranscriptionService.swift:191-254`, `TranscriptAssembler.swift:4-58`

Every partial and every final from both tracks triggers `publish()`, which
rebuilds full state on the main actor: merge-sort all segments, O(n^2)
dedupe scan with word-set allocations per candidate pair, regex-clean every
segment again. Costs grow with meeting length precisely during Nook's core
scenario. Additionally the merge comparator
(`abs(dt) < 0.08 -> microphone wins`) is not a strict weak ordering because
"within 0.08" is not transitive, so `sorted()` behaviour is formally
undefined.

Fix shape: incremental state, coalesce/dedupe only the tail, cache cleaned
text, fix the comparator to a proper ordering.

### P2 - HIGH - Audio meter republishes at 12.5 Hz forever

`MeetingCoordinator.swift:81, 800-812`. `audioLevel` is `@Published` and
written every 80 ms even at silence (writes continue after values settle).
`@Published` fires regardless of equality, so every observer re-renders at
meter cadence for whole meetings, mostly producing identical output. Gating
writes or moving the meter into a leaf observable removes most steady-state
invalidation app-wide.

Related: `docs/TECHNICAL.md` claims menu-bar label isolation from elapsed
time, but `NookMenuBarLabel` reads the coordinator directly
(`NookApp.swift:103-149`) so it re-renders on meter and transcript updates
too. Menu contents isolation (via `StatusMenuState`) is real and correct.

### P3 - MEDIUM - Capture callback does per-sample Swift-loop RMS

`CaptureService.swift:556-645`. Every sample converted in a plain loop on the
userInteractive capture queue (no vDSP), fresh exact-sized PCM allocation per
buffer, task-per-buffer hop. Individually cheap, collectively allocator churn
on the queue feeding the recording.

### P4 - MEDIUM - Whole library parsed eagerly and reloaded per activation

`MarkdownStore.swift:19-71`, `LibraryView.swift:171-175`. Every note
including transcripts decoded into permanent memory; reload on init, appear,
and every scenePhase activation; deep Equatable walks on each republish;
synchronous main-thread encode/verify/write on save of large notes.

### P5 - MEDIUM - Search rebuilds corpus per keystroke

`LibrarySearchController.swift:26-55`. Debounce and detached matching are
right, but each query joins every transcript and lowercases the result with
no cached index. Scales with library size per keystroke.

### Lower-severity performance notes

- `wordCount` splits the entire transcript at body-evaluation cadence
  (`LiveTranscriptionService.swift:50-54`, read at meter rate in
  `LiveMeetingView.swift:94,130`).
- Live summary re-summarizes the entire meeting every ~28 s with sequential
  model passes growing linearly in length (`MeetingCoordinator.swift:851-892`);
  no length-aware backoff.
- Dictation indicator polls mouse at 60 fps and swaps its root view per level
  sample (`DictationIndicator.swift:205-231, 299-310`).
- New `ISO8601DateFormatter` per date decode (`MarkdownCodec.swift:351-357`).
- Waveform restarts its animation per tick (`NookDesign.swift:362-365`).
- Detector does bounded process ancestry walks every 4 s forever, detached at
  utility priority (acceptable, noted).

### Performance strengths

Streaming `AudioExtractor` keeps memory flat for hour-long inputs.
`DictationAudioSource` is textbook: explicit `@Sendable` tap, buffer copied
before leaving the realtime thread, single ordered consumer via buffered
AsyncStream. Analyzer backlog is bounded (`bufferingNewest(180)`) and
finalization has deadlines with saved-audio fallback. `StatusMenuState` is a
deliberate low-frequency derived model. Transcript surfaces render suffixes,
never full history. Panel layout is event-driven and pixel aligned.

---

## Data handling and safety

### D1 - HIGH - Quick-note action output reaches the document unchecked

`QuickNoteController.swift:271-281`. Dictation has `DictationOutputGuard`,
meetings have the insight grounder, but quick-note actions do
`text = result` (replacing actions) from either the on-device model or the
remote CLI, then save immediately. A drifted rewrite overwrites the user's
saved spoken words, which is exactly what AGENTS.md rule 6 exists to prevent.
This is the only model-backed path without a trust check.

Fix shape: run replacements through a drift check comparable to
`DictationOutputGuard`, or require explicit diff-and-confirm before replacing.

### D2 - MEDIUM - External edits silently overwritten

`MarkdownStore.swift:74-85, 132-158`. Save never compares mtime/content
against the load-time snapshot. Worse, `rawMarkdown(for:)` falls back to the
in-memory reconstruction when the disk read fails, so a later save can
replace real file content with stale app state. Portability is a product
pillar, so divergence must warn, not overwrite.

### D3 - MEDIUM - Codec truncates user content on decode

`MarkdownCodec.swift:152-162`. A user-typed `## ` heading inside "My notes"
terminates that field at decode; the next field-level save re-encodes from
the truncated model, permanently dropping the tail. The round-trip check then
reports "Your Markdown file was left untouched", which is false. Section
matching is also unanchored and case-insensitive, so heading-like fragments
inside transcripts shift boundaries. Anchor parsing to line starts.

### D4 - MEDIUM - Paste-path dictation can land in the wrong window

`TextInsertionService.swift:176-202, 541-561`. `replaceRun` verifies focus
before inserting, but `.pasteOnly` and the streaming-failure fallback post a
global Cmd-V at delivery time without re-checking focus seconds later.
Roughly 500 ms of clipboard exposure per insertion also exists.

### D5 - MEDIUM - Prompt-injection surface into agentic CLIs undocumented

`CommandLineAssistant.swift:47-109`. Transport is clean: no shell, fixed argv
from enum strings, stdin only, consent off by default, persistent warning
while active. But transcribed speech reaches Claude Code / Codex, which have
tool and shell access under their own permission configs, and stdin has no
delimiter concept unlike the on-device path's NOTE delimiters. This risk
should be named in PRIVACY.md; consider restrictive CLI flags.

### Lower-severity data notes

- Debug builds log dictated speech plaintext without rotation or cap
  (`NookDebugLog.swift:68-86`); release uses the capped enum-only event log.
- Meeting-derived titles persisted to UserDefaults contradict PRIVACY.md's
  "not written" wording (`MeetingCoordinator.swift:1073-1077`).
- No fsync after atomic rename: atomicity guaranteed, durability window
  remains (`MarkdownStore.swift:78,149`).
- Editing the `id:` frontmatter line forks identity: two notes point at one
  file and either save clobbers the other (`MarkdownStore.swift:142-158, 247-254`).
- POSIX hardening is best-effort by design and fails open on exotic volumes;
  deliberate and commented.

### Data safety strengths

Summary grounding requires each decision/action item to share meaningful
tokens with a signal-bearing transcript line; deterministic fallback is
honestly labelled as highlights. Event log structurally cannot contain
content (fixed enums, 512 KB cap). Clipboard restore distinguishes read
failure from genuinely empty. On-device transcription confirmed end to end;
the only outbound path is the consented CLI bridge. Minimal entitlements.
Privacy properties pinned by tests.

---

## UX and UI

### U1 - HIGH - Shipped em-dash and a blind enforcement test

`QuickNoteController.swift:74-76` contains "working on is included — never
your recordings" in alert copy, violating the no-em-dash rule.
`NoteAssistant.swift:63` has another. Root cause:
`InterfaceCopyTests.containsEmDashInsideAStringLiteral` resets quote state
per physical line, so em-dashes on continuation lines of multi-line literals
are invisible. Fix the parser first, then sweep.

### U2 - HIGH - Permanent destruction on a single click

Cancel-processing discards a recording irrecoverably with no confirmation
across three surfaces (`NotchPanelView.swift:677-683`,
`LiveMeetingView.swift:477-485`, `StatusMenuView.swift:83-91`). Asymmetric
with the three-button confirmation required merely to change the notes folder
(`SettingsView.swift:66-85`). Orphan-recording Delete calls `removeItem`
directly, permanently, no confirm, on audio whose footer promises "so nothing
was lost" (`SettingsView.swift:377-381`, `RecordingRecovery.swift:115-121`).

### U3 - MEDIUM - Consent prompt cannot be answered from the keyboard

`NotchPanelView.swift:386-397` sets Return/Esc key equivalents, but the panel
is non-activating, shown via `orderFrontRegardless()`, and never made key, so
the shortcuts are inert. The highest-stakes decision moment should be
answerable hands-free.

### U4 - MEDIUM - Accessibility contract soft spots

- Increased Contrast consumed in one place only
  (`NotchPanelView.swift:33-34`); button fills and hairlines stay near
  invisible on black.
- ACCESSIBILITY.md claims Reduce Transparency support; no code reads
  `accessibilityDisplayShouldReduceTransparency`.
- Hidden-recording pause cue is color-only (red vs amber dot),
  `NotchPanelView.swift:164-170`, contra PRODUCT.md:163.
- Custom button styles define pressed/hover but no visible keyboard-focus
  appearance on near-black fills.

### U5 - LOWER severity UX notes

- Shift-Cmd-R works only while Nook owns the menu bar and is taught nowhere,
  making PRODUCT.md's promise conditional (`NookApp.swift:55`).
- Transient banners ("Markdown copied", "Saved") auto-dismiss without a
  VoiceOver announcement (`MeetingDetailView.swift:649-660`).
- Raw `error.localizedDescription` surfaced in six places bypassing copy voice
  and next-action requirements.
- Smallest repeated control 22x22 pt (`NotchPanelView.swift:1233`).
- Completed-state "Open notes" vanishes after 4.8 s with no notification
  fallback (`NotchPanelCoordinator.swift:361-368`).
- Orphan-recovery UI discoverable only by opening Settings.
- Tone drift: "PAUSED" vs "Paused"; Title Case mixed with sentence case.
- Search prompt overstates metadata coverage vs actual fields.
- Closing the library window with a dirty draft shows no warning.

### UX strengths

Recovery-path completeness is exceptional: every recording state reachable
from panel, menu bar, Dock, and library simultaneously. Quit-time protection
is triple-guarded including keep-the-audio messaging. Consent design puts
disclosure at the moment of action with reflex-safe defaults and a persistent
outbound banner. Reduced Motion honored across roughly 60 call sites down
into AppKit frame animations. VoiceOver speaks elapsed time semantically.
The settled-vs-volatile dictation split is a genuinely original solution to
revision cost. The audit launch arguments provide deterministic states for
manual acceptance.

---

## Prioritised fix order

1. R1 staleness/completeness sanity check (invisible loss of hours)
2. R2 pause-timeout phantom state (silent total loss, rare but real)
3. U1 fix em-dash test parser, sweep violations (repo rule broken by its own test gap)
4. D1 guard CLI/model note-action output (rule 6 violation)
5. P1 incremental publish + comparator fix (undefined behavior + core scenario)
6. P2 gate audioLevel writes (two lines, app-wide payoff)
7. R3 ordered single-consumer pump for capture ingest (known bug class)
8. U2/U3 destructive confirms + keyboard-consentable prompt
9. D2/D3 external-edit detection + anchored codec
10. R4 scan for orphan recordings at launch
