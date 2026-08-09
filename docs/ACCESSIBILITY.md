# Accessibility

Accessibility is part of Nook's product contract, not a release-afterthought.
Contributions should preserve independent control, understandable state, and a
usable recovery path throughout recording and processing.

## Supported behavior

- Icon-only controls have specific accessibility labels and help text.
- Recording, paused, processing, success, and failure states do not rely on
  color alone.
- Expand, hide, restore, pause, resume, finish, and cancel remain independent
  controls.
- Keyboard shortcuts remain available when the top panel is compact or hidden.
- Reduce Motion removes non-essential movement and spring-like transitions.
- Reduce Transparency preserves readable opaque surfaces.
- Increased Contrast strengthens outlines and foreground separation.
- Auto, Light, and Dark appearance choices remain user-controlled.
- Text editors expose a normal insertion point, selection, and undo behavior.

## Contributor checklist

For a relevant UI change, verify:

### VoiceOver

- Every actionable control has a concise, unique name.
- State is announced for toggles, recording, pause, and progress.
- Reading and focus order match the visual task order.
- Decorative images are hidden from the accessibility tree.
- Dynamic transcript updates do not repeatedly steal focus.

### Keyboard

- Tab and Shift-Tab reach controls in a predictable order.
- Buttons activate with standard keyboard behavior.
- Escape, default actions, and documented shortcuts behave consistently.
- A user can recover the meeting panel and finish recording without a pointer.

### Motion, contrast, and appearance

- Reduce Motion removes non-essential scale, slide, and spring effects.
- Reduce Transparency does not reduce text contrast or erase boundaries.
- Increased Contrast produces visibly stronger separation.
- Light and dark appearances remain legible without color-only meaning.
- Focus indicators and disabled states remain distinguishable.

### Layout

- Controls do not overlap at supported accessibility text sizes.
- The panel remains centered and reachable on notched and non-notched displays.
- The hidden indicator does not cover neighboring menu-bar items.
- Long localized-style strings and filesystem paths truncate intentionally.

## Snapshot and audit states

The `NookSnapshot` target and debug `--audit-*` launch arguments render
deterministic synthetic states. They are useful for appearance and geometry
checks, but do not replace VoiceOver, keyboard, permission, or physical-display
testing.

Current audit states are documented in [TECHNICAL.md](TECHNICAL.md). Never use
real meeting content in accessibility fixtures, screenshots, or bug reports.

## Reporting an accessibility issue

Use the bug-report template and include the macOS accessibility settings,
interaction method, Nook state, and expected focus or announcement. Use synthetic
content and redact identifying information. A vulnerability that exposes meeting
content should follow [SECURITY.md](../SECURITY.md).
