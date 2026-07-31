# Nook project handoff

Last updated: 31 July 2026

## Current state

Nook 1.6.3 (build 11) is the current public release.

- Apple notarization accepted and ticket stapled.
- Gatekeeper accepts the distributed app.
- Stable Sparkle feed advertises 1.6.3 (11).
- Full archive and build-10-to-11 delta are public.
- Release builds come from stable Xcode 26 and the macOS 26.5 SDK.
- 42 automated tests pass.
- Current source work is on `agent/release-nook-1-6`.
- Draft PR: `https://github.com/wrnsnng/nook/pull/1`
- Release: `https://github.com/wrnsnng/nook-releases/releases/tag/v1.6.3`

## What is working

- Manual and detected meeting starts.
- Screen/system audio and microphone capture.
- On-device live transcript with separate Meeting/You sources.
- Expanded Transcript, Summary, and My notes workspace.
- Compact top-edge recording controls.
- Fully hidden camera-edge timer with direct restore.
- Pause, resume, and finish from the top panel and native menus.
- Cancel/discard during accidental processing.
- Detached notes close at meeting end.
- Generated meeting titles with safe timestamp fallback.
- Editable personal notes save back into the Markdown source.
- Searchable local meeting library.
- Light, dark, and automatic appearance.
- Developer ID signing, notarization, Sparkle archives, deltas, and stable feed.
- Current cobalt icon in the app, About view, Dock, and app switcher.
- Provider-aware meeting detection and end recognition for Teams, Zoom,
  Google Meet, Webex, FaceTime, Slack Huddles, Around, and Whereby.

## Important constraints

1. **Detection is heuristic.** Meeting app window names can change. Manual start
   must remain first-class.
2. **Speech quality is OS-dependent.** Language assets, microphone quality,
   overlapping speech, and Apple Speech availability affect results.
3. **No full diarization.** Nook distinguishes system audio from microphone
   audio, not every individual remote participant.
4. **Foundation Models are optional.** Apple Intelligence improves summaries;
   deterministic fallback remains necessary.
5. **Screen permission requires relaunch.** Preserve the pending meeting start
   through that relaunch.
6. **Signing identity and toolchain are part of distribution behavior.** Do
   not distribute ad-hoc builds or builds produced with beta Xcode.
7. **The top panel is display-specific.** Always test a notched MacBook and a
   non-notched external display.
8. **macOS 26 is the current minimum.** Supporting older systems would require
   an explicit compatibility project.

## Manual regression checklist

### First run and permissions

- [ ] Fresh install launches an introduction or visible top-edge confirmation.
- [ ] Microphone prompt appears and recovery copy matches macOS.
- [ ] Speech Recognition prompt appears.
- [ ] Screen & System Audio Recording opens the correct Privacy & Security pane.
- [ ] Relaunch resumes the pending start once permission is granted.
- [ ] Denying each permission leaves a recoverable app, not a loop.

### Recording

- [ ] Manual start works from the menu and `⇧⌘R`.
- [ ] Detected meeting prompt is subtle and accepts/declines correctly.
- [ ] Menu-bar icon becomes a recording symbol and fixed-width timer.
- [ ] Native menu shows Pause and Finish immediately after start.
- [ ] Pause stops capture/transcription and Resume continues safely.
- [ ] Compact controls have independent Expand, Hide, Pause, and Finish targets.
- [ ] Hidden state shows a timer/red dot beside the MacBook camera.
- [ ] Hidden indicator restores compact controls.
- [ ] External display hidden indicator is centered and does not draw a fake
      notch.
- [ ] Expanded panel stays centered through Transcript/Summary/Notes resizing.
- [ ] Four to five recent caption lines remain readable.

### Notes and completion

- [ ] Inline notes insertion point and placeholder align.
- [ ] Detached notes do not duplicate the inline editor.
- [ ] Detached notes close when the meeting ends.
- [ ] Finish works from top panel, menu-bar menu, app menu, and Dock menu.
- [ ] Accidental processing can be cancelled and discarded.
- [ ] Completed meeting receives a useful content-based title when possible.
- [ ] Personal notes appear in the saved Markdown file.
- [ ] Raw Markdown save/revert works and protects unsaved changes.
- [ ] Search finds terms in title, summary, outcomes, notes, and transcript.

### Update flow

- [ ] A notarized 1.6.2 build detects 1.6.3.
- [ ] Delta update succeeds from build 10 to build 11.
- [ ] App relaunches as 1.6.3 (11).
- [ ] Fresh download opens normally on macOS 26.5.1 without a Gatekeeper
      override.
- [ ] Existing Microphone, Speech, and Screen Capture grants remain valid.
- [ ] Dock icon remains cobalt after update.

### Accessibility and appearance

- [ ] VoiceOver names every icon-only control.
- [ ] Keyboard focus reaches all actions in a logical order.
- [ ] Reduce Motion removes non-essential movement.
- [ ] Increased Contrast improves separation.
- [ ] Auto, Light, and Dark render correctly.
- [ ] Text remains legible at larger accessibility sizes where macOS permits.

## Recommended next work

1. Run the full checklist on a clean notched MacBook using the OTA update path.
2. Merge PR #1 after that hardware pass.
3. Capture failures and product follow-ups as Linear issues in the Nook project.
4. Improve meeting detection patterns only from observed false positives or
   misses; avoid speculative app matching.
5. Add an in-app diagnostics/export screen for permission state and recent
   capture errors before broader distribution.
6. Add release-channel support only if beta and stable audiences need to
   diverge.
7. Consider opt-in speaker naming only with a robust local implementation.

## Where to resume

Start with:

1. `README.md`
2. `docs/PRODUCT.md`
3. `docs/TECHNICAL.md`
4. `docs/OPERATIONS.md`
5. This handoff

Then inspect the open Linear Nook project and PR #1. Avoid reopening resolved
design questions without new observed evidence.
