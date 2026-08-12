#!/usr/bin/env python3
"""Turn a release note into the HTML Sparkle shows in its update dialog.

Sparkle's `generate_appcast --embed-release-notes` reads an HTML file sitting
beside the archive and named after it. Markdown is ignored, so notes written as
`Releases/Nook-<version>.md` never reached anyone: every update Nook has ever
offered showed an empty "What's New".

Deliberately dependency free. Release tooling runs on a maintainer's machine
before signing, and adding a package manager to that path would be a poor trade
for a converter this small. It understands only what release notes actually
use: headings, paragraphs, bullet lists, bold, italics, inline code, and links.

Usage: release-notes-html.py <notes.md> <output.html>
"""

import html
import re
import sys


def inline(text: str) -> str:
    """Escape the text, then re-introduce the few spans notes rely on."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", out)
    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', out)
    return out


def convert(markdown: str) -> str:
    lines = markdown.splitlines()
    parts: list[str] = []
    paragraph: list[str] = []
    in_list = False

    def flush_paragraph() -> None:
        if paragraph:
            parts.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            parts.append("</ul>")
            in_list = False

    for line in lines:
        stripped = line.strip()

        if not stripped:
            flush_paragraph()
            close_list()
            continue

        heading = re.match(r"^(#{1,3})\s+(.*)$", stripped)
        if heading:
            flush_paragraph()
            close_list()
            # The note's H1 repeats the version Sparkle already shows in its
            # own header, so it starts at H2 to avoid saying it twice.
            level = min(len(heading.group(1)) + 1, 4)
            parts.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            continue

        bullet = re.match(r"^[-*]\s+(.*)$", stripped)
        if bullet:
            flush_paragraph()
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append(f"<li>{inline(bullet.group(1))}</li>")
            continue

        close_list()
        paragraph.append(stripped)

    flush_paragraph()
    close_list()
    return "\n".join(parts)


# A bare fragment, deliberately.
#
# `generate_appcast` embeds release notes directly into the appcast only when
# the HTML carries no DOCTYPE, `html`, or `body` tags. A full document is
# instead treated as a file to link to, which needs somewhere to host it and
# leaves the update dialog empty when there is nowhere. Embedded notes travel
# inside the signed feed and need no hosting at all.
#
# Styling is left to Sparkle, which renders these in a web view that already
# follows the system appearance. A stylesheet here would only risk fighting it.
TEMPLATE = "{body}\n"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64

    source, destination = sys.argv[1], sys.argv[2]
    with open(source, encoding="utf-8") as handle:
        markdown = handle.read()

    body = convert(markdown)
    if not body.strip():
        print(f"No release-note content found in {source}", file=sys.stderr)
        return 65

    with open(destination, "w", encoding="utf-8") as handle:
        handle.write(TEMPLATE.format(body=body))
    return 0


if __name__ == "__main__":
    sys.exit(main())
