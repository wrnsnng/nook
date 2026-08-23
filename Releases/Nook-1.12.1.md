# Nook 1.12.1

Fixes a crash in the quick note pad.

- Holding the dictation shortcut with nowhere to type, which opens the
  quick note pad, crashed the app on first render in 1.12.0. The pad's
  window is built by hand rather than through a declared scene, and it
  was missing one of the objects the new live-partial and hands-free
  features read. It is injected now.
