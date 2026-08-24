# Nook 1.15.1

Fixed: taking notes during a meeting.

The My notes field, in the meeting panel and in the detached window,
stopped accepting typing as soon as a recording started. While Nook
captures audio it refreshes its interface many times a second, and one of
those refreshes kept taking the keyboard away from the field you were
typing in. Focus is now requested once and honoured once, so the field
keeps the keyboard for as long as the conversation runs.
