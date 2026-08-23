# Nook 1.10.2

Calendar context can ask for permission properly now.

- Turning on "Use my calendar for meeting context" presents the real macOS
  permission dialog. Previously the request was refused before any prompt
  could appear, and the switch turned itself back off.
- If you tried calendar context before this version, turn the switch on
  again after updating; it asks as expected now.
- The same fix covers adding an action item to Reminders.
