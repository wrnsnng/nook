# [Feature]: Quick notes that carry structure - checklists, due dates, templates

## Problem

Quick notes are prose-only while meetings produce structured outcomes,
and the gap is artificial. The sidebar's action-item pipeline
(`OpenActionsController` + `MarkdownCodec.actionItemLines`) already
understands `- [ ] item [due: YYYY-MM-DD]` lines under an `## Action
items` heading: it aggregates them, sorts by deadline, shows overdue
chips, and exports to Reminders. But:

- A spoken or typed quick note cannot produce that syntax. There is no
  checklist affordance in the pad, and the spoken-note layout keeps the
  body as pure prose (the older layout's trailing `## Action items`
  sections were removed as clutter).
- So the fastest capture path in the app feeds the least structure into
  the system that rewards structure most. "Send Marco the report" said
  in a meeting becomes a trackable action item; said into a quick note
  it becomes an unfindable sentence.

## Proposed outcome

Let quick notes write the syntax the library already reads.

- **A checklist row in the pad.** One keystroke/button adds `- [ ] `
  at the cursor; typing proceeds normally. No new format is invented:
  what lands in the file is exactly the line shape meetings already use.
- **Spoken-note files grow an `## Action items` section only when one
  exists.** Empty sections stay absent (the lesson from removing them
  before). `MarkdownCodec.actionItemLines` then finds pad-created items
  with zero parser changes, and they surface in the sidebar with due
  dates and Reminders export for free.
- **Due dates on quick-note actions use the existing `[due: ...]`
  suffix**, editable through the same sidebar menu as meeting actions.
- **Optional on-device assist, proposed never trusted.** For looser
  capture ("send Marco the report Friday"), offer a suggestion chip that
  converts the sentence into a checkbox with a parsed date before it is
  written. Rules carried over from the dictation guard philosophy:
  - deterministic parsing first (existing `[due: ...]` codec, fixed
    weekday/date patterns); a model call only when deterministic parsing
    has nothing to offer;
  - the suggestion appears as a diff against the user's own words and is
    applied only on explicit accept;
  - refusal to guess: if confidence is low, no chip appears;
  - off-when-unavailable, and failure degrades to plain text.
- **Templates.** A small set of seeded note skeletons (1:1, standup,
  interview) available when creating a blank note in the library and
  optionally as a starting point in the pad. Templates are static text;
  nothing generates content.

## Alternatives considered

- **Loosen `actionItemLines` to scan checkboxes anywhere in any note.**
  Rejected for now: the section scope is what lets a toggle rewrite
  exactly one line safely and keeps user prose from being misread as
  tasks. A whole-file scan needs its own conflict analysis first.
- **Model-extract actions from finished quick notes in bulk.** Rejected
  as default: silent restructuring of a person's words violates the
  model-output-is-never-trusted contract; the assist above stays
  inline, visible, and opt-in per suggestion.
- **Separate "tasks" data model.** Rejected: portable Markdown with
  line-addressed edits is the storage contract; duplicating state into
  a database creates two truths.

## Privacy, permission, network, and storage impact

Storage: unchanged file format; spoken notes may gain an Action items
section, which older Nook versions already parse (and ignore cleanly).
Network: none for checklists or templates. The optional date-assist uses
the same on-device summarizer stack meetings use; if it routes through
an opted-in CLI engine instead, that engine's existing consent gate and
permanent banner apply unchanged. No new permissions.

## Accessibility considerations

- Checklist insertion is a keyboard command plus a labeled button; the
  checkbox glyph rows get "action item" labels consistent with meeting
  notes.
- Suggestion chips are focusable, announced with their full resulting
  text, and accept via Return; Escape declines without touching the
  buffer.
- Due-date editing reuses the existing popover, which already carries
  default-action and cancel shortcuts.
- Templates render as ordinary editor text; no custom controls.
