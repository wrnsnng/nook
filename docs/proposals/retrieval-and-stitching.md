# [Feature]: Retrieval and stitching - command palette, Today view, two-way action items

## Problem

The library holds everything Nook knows, but three seams show:

1. **Everything requires navigation.** Starting a recording, opening a
   note, asking the library, or capturing a quick note each live behind
   different surfaces (menu bar menu, sidebar selection, toolbar
   button, dictation shortcut). A keyboard-first user has no single
   accelerator, and none of these are discoverable from the library
   itself.
2. **Quick notes are second-class citizens in browsing.** The sidebar
   groups meetings into Today / Yesterday / This Week / month sections;
   spoken notes land somewhere in that chronology with no sense of a
   day's flow. "What did I do today?" needs an answer that is not
   search.
3. **Action items tick one way.** Sidebar rows toggle their line in the
   file and open notes refresh through the store, but inside a note's
   Notes tab the items render as static circles (`MeetingDetailView`
   action-items section). The most natural place to close out a task,
   rereading the note it came from, is the one place it cannot be done.

## Proposed outcome

- **Command palette on `⌘K`** over the whole app:
  - fuzzy jump to any note by title/content;
  - verbs: new quick note, start recording, ask your library, create
    weekly digest, reveal storage folder;
  - actions from the existing open-actions list, so `⌘K` doubles as a
    task launcher.
  Built as a native sheet/popover with standard list semantics; no
  custom window class.
- **A Today column or filter in the library**: meetings and spoken notes
  interleaved by time for the current day (and yesterday as a step
  back), with the live meeting pinned at top when present. This is a
  presentation of existing store data, not a new model.
- **Two-way action items**: circles in the Notes tab become real
  checkboxes wired to the same one-line file rewrite the sidebar uses.
  Toggling in either place converges because both read back through
  `store.notes`; the work is the affordance, plus guarding against
  editing while a Markdown draft is open (the personal-notes editor
  already models this disable pattern).

## Alternatives considered

- **Menu-bar-only launcher (Raycast-style global hotkey).** Rejected as
  the primary: global hotkeys are scarce, and Nook already reserves its
  only Carbon registration for dictation. In-app `⌘K` covers the
  keyboard path without another permission-shaped surface.
- **Separate Today window.** Rejected: adds a surface to manage, which
  the product promise explicitly avoids. The library already owns
  browsing.
- **Sync action state into a sidecar database for speed.** Rejected:
  files stay the single truth; refresh is already incremental enough at
  library scale.

## Privacy, permission, network, and storage impact

None. All three changes present or edit data that is already local.
No new permissions, no network, no format changes.

## Accessibility considerations

- Palette: VoiceOver list with results announced on change, arrow-key
  navigation, Return default, Escape cancel, visible focus ring.
- Today view keeps the existing section-header pattern
  (`accessibilityAddTraits(.isHeader)`) so rotor navigation survives.
- Note-side checkboxes reuse the sidebar row's label/hint/custom-action
  vocabulary added in 1.11.0, including hit-target floor.
- All motion gated on Reduce Motion per the existing contract.

## Sequencing note

Palette first (it multiplies discoverability of everything else), then
Today view, then two-way checkboxes (smallest, but depends on nothing).
