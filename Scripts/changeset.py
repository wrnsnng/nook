#!/usr/bin/env python3
"""Collect release notes as changesets and turn them into a release.

Each pull request that changes what people see adds one file to `.changeset/`:

    ---
    bump: patch
    section: Recording
    ---
    - A recording you start yourself keeps going until you stop it.

`bump` is `patch`, `minor` or `major`. `section` is optional; changesets that
share one are grouped under a bold heading, as hand-written notes already are.
The body is written for people using Nook, not for reviewers.

`version` consumes every pending changeset: it bumps `MARKETING_VERSION` by the
largest requested level, increments `CURRENT_PROJECT_VERSION` (Sparkle's build
number, which must never be reused), writes `Releases/Nook-<version>.md`, adds
the CHANGELOG entry and deletes the files it used. Review and edit the note
before releasing; the summary line in particular is yours to write.

Deliberately dependency free, like the rest of the release tooling.

Usage:
  changeset.py add <patch|minor|major> [--section NAME] [--name SLUG] NOTE...
  changeset.py status
  changeset.py version --summary "One sentence about the release." [--dry-run]
  changeset.py check [--base REF]
"""

import argparse
import datetime
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHANGESET_DIR = ROOT / ".changeset"
BUMPS = ("patch", "minor", "major")
LOCAL_FIRST_FOOTER = (
    "Nook remains local-first. This release adds no telemetry, network service or\n"
    "remote model."
)


class ChangesetError(Exception):
    pass


@dataclass
class Changeset:
    path: Path
    bump: str
    section: str | None
    body: str


def parse(path: Path) -> Changeset:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", text, re.DOTALL)
    if not match:
        raise ChangesetError(f"{path.name}: missing --- front matter")
    fields: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if not line.strip():
            continue
        key, sep, value = line.partition(":")
        if not sep:
            raise ChangesetError(f"{path.name}: unreadable line {line!r}")
        fields[key.strip()] = value.strip()
    bump = fields.get("bump", "")
    if bump not in BUMPS:
        raise ChangesetError(f"{path.name}: bump must be one of {', '.join(BUMPS)}")
    body = match.group(2).strip()
    if not body:
        raise ChangesetError(f"{path.name}: the note is empty")
    return Changeset(path, bump, fields.get("section") or None, body)


def pending(directory: Path = CHANGESET_DIR) -> list[Changeset]:
    if not directory.is_dir():
        return []
    files = sorted(
        p for p in directory.glob("*.md") if p.name.lower() != "readme.md"
    )
    return [parse(p) for p in files]


def next_version(current: str, bump: str) -> str:
    parts = current.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise ChangesetError(f"MARKETING_VERSION {current!r} is not x.y.z")
    major, minor, patch = (int(p) for p in parts)
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def largest_bump(changesets: list[Changeset]) -> str:
    return max((c.bump for c in changesets), key=BUMPS.index)


def as_bullets(body: str) -> str:
    """A changeset written as prose becomes one bullet."""
    if body.lstrip().startswith("- "):
        return body
    lines = body.splitlines()
    return "\n".join(["- " + lines[0]] + ["  " + l if l else l for l in lines[1:]])


def release_note(version: str, summary: str, changesets: list[Changeset]) -> str:
    out = [f"# Nook {version}", "", summary.strip(), ""]
    unsectioned = [c for c in changesets if c.section is None]
    sections: dict[str, list[Changeset]] = {}
    for c in changesets:
        if c.section is not None:
            sections.setdefault(c.section, []).append(c)
    if unsectioned:
        out += [as_bullets(c.body) for c in unsectioned]
        out.append("")
    for name, items in sections.items():
        out += [f"**{name}**", ""]
        out += [as_bullets(c.body) for c in items]
        out.append("")
    out.append(LOCAL_FIRST_FOOTER)
    return "\n".join(out) + "\n"


def changelog_entry(version: str, changesets: list[Changeset]) -> str:
    bullets = "\n".join(as_bullets(c.body) for c in changesets)
    return (
        f"## {version}\n\n"
        f"[Release notes](Releases/Nook-{version}.md)\n\n"
        f"{bullets}\n\n"
    )


def insert_changelog(changelog: str, entry: str) -> str:
    marker = "## Unreleased\n"
    index = changelog.find(marker)
    if index < 0:
        raise ChangesetError("CHANGELOG.md has no '## Unreleased' heading")
    after = index + len(marker)
    rest = changelog[after:].lstrip("\n")
    if rest and not rest.startswith("## "):
        raise ChangesetError(
            "CHANGELOG.md has notes under Unreleased. Move them into "
            "changesets first so they are not split across two places."
        )
    return changelog[:after] + "\n" + entry + rest


def read_setting(project: str, key: str) -> str:
    match = re.search(rf'^\s*{key}:\s*"([^"]+)"', project, re.MULTILINE)
    if not match:
        raise ChangesetError(f"project.yml has no {key}")
    return match.group(1)


def write_setting(project: str, key: str, value: str) -> str:
    return re.sub(
        rf'^(\s*{key}:\s*)"[^"]+"', rf'\g<1>"{value}"', project,
        count=1, flags=re.MULTILINE,
    )


def command_add(args: argparse.Namespace) -> int:
    note = " ".join(args.note).strip()
    if not note:
        raise ChangesetError("write the note people will read")
    slug = args.name or re.sub(r"[^a-z0-9]+", "-", note.lower())[:48].strip("-")
    CHANGESET_DIR.mkdir(exist_ok=True)
    path = CHANGESET_DIR / f"{slug or 'change'}.md"
    if path.exists():
        stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
        path = CHANGESET_DIR / f"{slug}-{stamp}.md"
    front = [f"bump: {args.bump}"]
    if args.section:
        front.append(f"section: {args.section}")
    path.write_text(
        "---\n" + "\n".join(front) + "\n---\n" + as_bullets(note) + "\n",
        encoding="utf-8",
    )
    print(path.relative_to(ROOT))
    return 0


def command_status(_: argparse.Namespace) -> int:
    changesets = pending()
    if not changesets:
        print("No pending changesets.")
        return 0
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    current = read_setting(project, "MARKETING_VERSION")
    bump = largest_bump(changesets)
    print(f"{len(changesets)} pending; next release {current} -> "
          f"{next_version(current, bump)} ({bump})")
    for c in changesets:
        print(f"  {c.bump:<5} {c.path.name}")
    return 0


def command_version(args: argparse.Namespace) -> int:
    changesets = pending()
    if not changesets:
        raise ChangesetError("no pending changesets in .changeset/")
    project_path = ROOT / "project.yml"
    project = project_path.read_text(encoding="utf-8")
    current = read_setting(project, "MARKETING_VERSION")
    build = read_setting(project, "CURRENT_PROJECT_VERSION")
    version = next_version(current, largest_bump(changesets))
    new_build = str(int(build) + 1)

    note_path = ROOT / "Releases" / f"Nook-{version}.md"
    if note_path.exists():
        raise ChangesetError(f"{note_path.relative_to(ROOT)} already exists")
    note = release_note(version, args.summary, changesets)
    changelog_path = ROOT / "CHANGELOG.md"
    changelog = insert_changelog(
        changelog_path.read_text(encoding="utf-8"),
        changelog_entry(version, changesets),
    )

    if args.dry_run:
        print(f"Nook {current} ({build}) -> {version} ({new_build})\n")
        print(note)
        return 0

    project = write_setting(project, "MARKETING_VERSION", version)
    project = write_setting(project, "CURRENT_PROJECT_VERSION", new_build)
    project_path.write_text(project, encoding="utf-8")
    note_path.write_text(note, encoding="utf-8")
    changelog_path.write_text(changelog, encoding="utf-8")
    for c in changesets:
        c.path.unlink()

    print(f"Nook {current} ({build}) -> {version} ({new_build})")
    print(f"Wrote {note_path.relative_to(ROOT)}; review it before releasing.")
    print("Now run `xcodegen generate` and commit the version, project, "
          "release note and changelog together.")
    return 0


def changed_files(base: str) -> list[tuple[str, str]]:
    output = subprocess.run(
        ["git", "diff", "--name-status", "--no-renames", f"{base}...HEAD"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    rows = []
    for line in output.splitlines():
        status, _, path = line.partition("\t")
        rows.append((status, path))
    return rows


# Paths that never change the shipped app, so a pull request touching only
# these needs no changeset.
EXEMPT = re.compile(
    r"^(\.github/|\.changeset/|docs/|Scripts/Tests/|NookTests/|Releases/|"
    r"[^/]+\.md$)"
)


def command_check(args: argparse.Namespace) -> int:
    pending()  # Fails on any malformed changeset, added in this PR or not.
    rows = changed_files(args.base)
    added = [
        p for s, p in rows
        if s == "A" and p.startswith(".changeset/") and p.endswith(".md")
        and not p.lower().endswith("readme.md")
    ]
    if added:
        print(f"Changeset found: {', '.join(added)}")
        return 0
    if all(EXEMPT.match(p) for _, p in rows):
        print("Only docs, tests or CI changed; no changeset needed.")
        return 0
    print(
        "This pull request changes Nook but adds no changeset. Run\n"
        "  Scripts/changeset.py add patch \"What people will notice.\"\n"
        "or add the no-changeset label if nobody will notice.",
        file=sys.stderr,
    )
    return 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    add = commands.add_parser("add", help="write a new changeset")
    add.add_argument("bump", choices=BUMPS)
    add.add_argument("note", nargs="+")
    add.add_argument("--section")
    add.add_argument("--name", help="file name, without .md")
    add.set_defaults(run=command_add)

    status = commands.add_parser("status", help="list pending changesets")
    status.set_defaults(run=command_status)

    version = commands.add_parser("version", help="consume changesets into a release")
    version.add_argument("--summary", required=True)
    version.add_argument("--dry-run", action="store_true")
    version.set_defaults(run=command_version)

    check = commands.add_parser("check", help="require a changeset in a PR")
    check.add_argument("--base", default="origin/main")
    check.set_defaults(run=command_check)

    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except ChangesetError as error:
        print(f"changeset: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
