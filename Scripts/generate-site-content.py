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
            f"            <li>{escape(note)}</li>" for note in release["notes"]
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
    <link rel="icon" href="/favicon.svg" type="image/svg+xml">
    <link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
  </head>
  <body>
    <div class="page">

      <header class="header">
        <a href="/" class="header-lockup">
          <img class="header-icon" src="/favicon.svg" alt="" width="24" height="24">
          <span class="header-name">{escape(product["name"])}</span>
        </a>
        <nav class="header-links">
          <a href="/">App page</a>
          <a href="{escape(site["downloads_url"])}" class="header-download">Download</a>
        </nav>
      </header>

      <section class="hero">
        <h1>Release notes</h1>
        <p class="hero-sub">
          What changed in {escape(product["name"])}. Binaries live on
          <a href="{escape(site["releases_url"])}">GitHub Releases</a>;
          the Sparkle appcast is generated locally during release publishing.
        </p>
        <div class="hero-actions">
          <a class="btn btn-primary" href="{escape(site["downloads_url"])}">Download the latest release</a>
          <a class="btn btn-ghost" href="/">Back to the app page</a>
        </div>
      </section>

      <main class="release-list">
{cards_markup}
      </main>

      <footer class="footer">
        <div class="footer-links">
          <a href="/">App page</a>
          <a href="/appcast.xml">Appcast</a>
          <a href="/privacy">Privacy</a>
          <a href="{escape(site["changelog_url"])}">Full changelog on GitHub</a>
        </div>
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
