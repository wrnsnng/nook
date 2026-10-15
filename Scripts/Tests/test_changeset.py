import importlib.util
from pathlib import Path
import tempfile
import textwrap
import unittest


MODULE_PATH = Path(__file__).parents[1] / "changeset.py"
SPEC = importlib.util.spec_from_file_location("changeset", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
changeset = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(changeset)


def write(directory: Path, name: str, text: str) -> Path:
    path = directory / name
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    return path


class ChangesetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_largest_bump_decides_the_next_version(self) -> None:
        write(self.dir, "a.md", "---\nbump: patch\n---\n- Fix.\n")
        write(self.dir, "b.md", "---\nbump: minor\n---\n- Feature.\n")
        found = changeset.pending(self.dir)
        bump = changeset.largest_bump(found)
        self.assertEqual(bump, "minor")
        self.assertEqual(changeset.next_version("1.23.1", bump), "1.24.0")
        self.assertEqual(changeset.next_version("1.23.1", "major"), "2.0.0")
        self.assertEqual(changeset.next_version("1.23.1", "patch"), "1.23.2")

    def test_readme_is_not_a_changeset(self) -> None:
        write(self.dir, "README.md", "# Changesets\n")
        self.assertEqual(changeset.pending(self.dir), [])

    def test_unknown_bump_is_refused(self) -> None:
        write(self.dir, "a.md", "---\nbump: huge\n---\n- Fix.\n")
        with self.assertRaises(changeset.ChangesetError):
            changeset.pending(self.dir)

    def test_empty_note_is_refused(self) -> None:
        write(self.dir, "a.md", "---\nbump: patch\n---\n\n")
        with self.assertRaises(changeset.ChangesetError):
            changeset.pending(self.dir)

    def test_release_note_groups_sections_after_unsectioned_notes(self) -> None:
        write(self.dir, "a.md", "---\nbump: patch\nsection: Folders\n---\n- Folder fix.\n")
        write(self.dir, "b.md", "---\nbump: patch\n---\nA prose fix that\nwraps.\n")
        note = changeset.release_note(
            "1.23.2", "Two fixes.", changeset.pending(self.dir)
        )
        self.assertTrue(note.startswith("# Nook 1.23.2\n\nTwo fixes.\n\n"))
        self.assertIn("- A prose fix that\n  wraps.\n\n**Folders**\n\n- Folder fix.\n", note)
        self.assertTrue(note.rstrip().endswith("remote model."))

    def test_changelog_entry_goes_below_unreleased(self) -> None:
        log = "# Changelog\n\n## Unreleased\n\n## 1.23.1\n\n- Old.\n"
        found = [changeset.Changeset(self.dir / "a.md", "patch", None, "- New.")]
        result = changeset.insert_changelog(
            log, changeset.changelog_entry("1.23.2", found)
        )
        self.assertIn(
            "## Unreleased\n\n## 1.23.2\n\n[Release notes](Releases/Nook-1.23.2.md)\n\n- New.\n\n## 1.23.1",
            result,
        )

    def test_notes_left_under_unreleased_are_not_silently_split(self) -> None:
        log = "## Unreleased\n\n- Hand-written.\n\n## 1.23.1\n"
        with self.assertRaises(changeset.ChangesetError):
            changeset.insert_changelog(log, "## 1.23.2\n\n")

    def test_project_settings_are_rewritten_in_place(self) -> None:
        project = '    MARKETING_VERSION: "1.23.1"\n    CURRENT_PROJECT_VERSION: "43"\n'
        self.assertEqual(changeset.read_setting(project, "CURRENT_PROJECT_VERSION"), "43")
        updated = changeset.write_setting(project, "MARKETING_VERSION", "1.24.0")
        self.assertIn('MARKETING_VERSION: "1.24.0"', updated)
        self.assertIn('CURRENT_PROJECT_VERSION: "43"', updated)

    def test_docs_and_tests_need_no_changeset(self) -> None:
        for path in ["docs/OPERATIONS.md", "NookTests/X.swift", "AGENTS.md",
                     ".github/workflows/ci.yml", "Scripts/Tests/test_x.py"]:
            self.assertTrue(changeset.EXEMPT.match(path), path)
        for path in ["Nook/Services/MeetingCoordinator.swift", "project.yml",
                     "Scripts/release-update.sh"]:
            self.assertFalse(changeset.EXEMPT.match(path), path)


if __name__ == "__main__":
    unittest.main()
