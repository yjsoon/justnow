#!/usr/bin/env python3

import json
from datetime import datetime, timezone
from html import escape
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = REPO_ROOT / "site" / "releases.json"
RELEASE_NOTES_PATH = REPO_ROOT / "site" / "releases" / "index.html"


def load_source() -> dict[str, Any]:
    with SOURCE_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_release_date(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=timezone.utc)


def release_label(value: str) -> str:
    release_date = parse_release_date(value)
    return f"{release_date.strftime('%B')} {release_date.day}, {release_date.year}"


def render_release_notes(source: dict[str, Any]) -> str:
    site = source["site"]
    product = source["product"]
    releases = source["releases"]
    cards = []

    for release in releases:
        notes = "\n".join(
            f"            <li>{escape(note)}</li>"
            for note in release["notes"]
        )
        cards.append(
            f"""        <article class="release-card">
          <h2>{escape(release["tag"])}</h2>
          <div class="release-meta">
            <span>{escape(release["status"])}</span>
            <span>{escape(release_label(release["published_at"]))}</span>
          </div>
          <ul>
{notes}
          </ul>
        </article>"""
        )

    cards_markup = "\n".join(cards)

    return f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{escape(product["name"])} Release Notes</title>
    <meta name="description" content="Release notes for {escape(product["name"])}.">
    <link rel="stylesheet" href="/styles.css">
  </head>
  <body>
    <div class="page-shell">
      <header class="hero">
        <p class="eyebrow">Release notes</p>
        <h1>What changed in {escape(product["name"])}.</h1>
        <p class="lede">
          This page is generated from <code>site/releases.json</code>. Binaries remain on GitHub Releases,
          while the Sparkle appcast is generated locally during release publishing.
        </p>
        <div class="hero-actions">
          <a class="button button-primary" href="{escape(site["downloads_url"])}">Download the latest release</a>
          <a class="button button-secondary" href="/">Back to the app page</a>
        </div>
      </header>

      <main class="release-list">
{cards_markup}
      </main>

      <footer class="site-footer">
        <a href="/">App page</a>
        <a href="/appcast.xml">Appcast</a>
        <a href="{escape(site["changelog_url"])}">Full changelog on GitHub</a>
      </footer>
    </div>
  </body>
</html>
"""


def main() -> None:
    source = load_source()
    RELEASE_NOTES_PATH.parent.mkdir(parents=True, exist_ok=True)
    RELEASE_NOTES_PATH.write_text(render_release_notes(source), encoding="utf-8")


if __name__ == "__main__":
    main()
