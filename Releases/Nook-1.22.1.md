# Nook 1.22.1

A fix for a crash on macOS 27, a clearer notes page, and Nook's first build
for macOS 27.

**Fixes**

- Nook no longer quits when you point at the hidden recording pill beside the
  camera on macOS 27.
- Notices such as "Folder deleted" float over the window instead of pushing
  everything down while they show.

**Notes page**

- The summary is now called "In summary" and leads the page on a soft tint,
  with even spacing between its paragraphs.
- Add key points, decisions, action items and open questions, not just edit
  them: each list ends with an Add row, and sections the summary did not
  produce can be added below the last one.
- My notes shows a soft field while you type in it.
- Reviewing a summary line has a calmer correction field.

**Everywhere else**

- Built with Xcode 27, so on macOS 27 Nook has the current system look,
  including the floating sidebar. Nook still runs on macOS 26.
- Note titles in the sidebar are medium weight instead of bold.
- New Folder sits in the bar at the bottom of the sidebar, as in Notes.
- The notch shows Nook's icon when nothing is happening.
- Setup's buttons match the rest of the app.

Nook remains local-first. This release adds no telemetry, network service or
remote model.
