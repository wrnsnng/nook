# Changesets

Every pull request that changes what people see or do in Nook adds one file
here. It is the release note for that change, written for people using Nook.

```sh
Scripts/changeset.py add patch "A recording you start yourself keeps going until you stop it."
Scripts/changeset.py add minor --section "Folders" "Nook suggests a folder for a note that is not in one."
```

Or write the file by hand:

```markdown
---
bump: patch
section: Recording
---
- A recording you start yourself keeps going until you stop it.
```

- `bump`: `patch` for fixes, `minor` for new features, `major` for changes
  that break what people rely on.
- `section` (optional): changesets with the same section are grouped under one
  bold heading in the release note.

A pull request that only touches docs, tests or CI needs none. For
anything else nobody will notice, add the `no-changeset` label.

Releasing: `Scripts/changeset.py version --summary "..."` bumps the version,
writes `Releases/Nook-<version>.md` and the changelog entry, and deletes the
files it used. See [docs/OPERATIONS.md](../docs/OPERATIONS.md#version-and-release-note-mapping).
