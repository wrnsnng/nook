# Nook 1.23.1

A fix for recordings that ended too early.

- A recording you start yourself keeps going until you stop it. Playing a
  video in Slack during a meeting could make Nook think a Slack call had
  started, and when the video ended Nook stopped the recording and finished
  the transcript. Recordings started from a detected meeting still stop when
  that meeting ends.
- Release downloads no longer carry Finder metadata files. Apps unpacked by
  tools other than Archive Utility, including many managed-Mac installers,
  failed signature checks inside Sparkle.framework and Gatekeeper refused to
  open them.
