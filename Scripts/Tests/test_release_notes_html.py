import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).parents[1] / "release-notes-html.py"
SPEC = importlib.util.spec_from_file_location("release_notes_html", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
release_notes_html = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_notes_html)


class ReleaseNotesHTMLTests(unittest.TestCase):
    def test_wrapped_bullet_remains_one_list_item(self) -> None:
        result = release_notes_html.convert(
            """
            # Nook 1.7.4

            - A release note that wraps onto a second line for source
              readability remains one item in Sparkle.
            - Another item.
            """
        )

        self.assertIn(
            "<li>A release note that wraps onto a second line for source readability remains one item in Sparkle.</li>",
            result,
        )
        self.assertEqual(result.count("<li>"), 2)
        self.assertNotIn("</ul>\n<p>readability", result)

    def test_blank_line_ends_a_list_before_the_next_paragraph(self) -> None:
        result = release_notes_html.convert(
            """
            - One item.

            A separate paragraph.
            """
        )

        self.assertIn("</ul>\n<p>A separate paragraph.</p>", result)


if __name__ == "__main__":
    unittest.main()
