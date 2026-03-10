#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RELEASES_PATH = REPO_ROOT / "site" / "releases.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update site/releases.json for a published release.")
    parser.add_argument("--tag", required=True, help="Release tag, for example v0.1.2")
    parser.add_argument("--version", required=True, help="Marketing version, for example 0.1.2")
    parser.add_argument("--published-at", required=True, help="UTC publish date in YYYY-MM-DD format")
    parser.add_argument("--notes-file", required=True, help="Markdown or text file containing release notes")
    parser.add_argument("--status", default="Current public build", help="Status label for the newest release")
    return parser.parse_args()


def load_releases() -> dict:
    with RELEASES_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def dump_releases(payload: dict) -> None:
    with RELEASES_PATH.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def parse_notes(notes_path: Path) -> list[str]:
    lines = [line.strip() for line in notes_path.read_text(encoding="utf-8").splitlines()]

    bullet_notes = []
    for line in lines:
        if line.startswith("- ") or line.startswith("* "):
            bullet_notes.append(line[2:].strip())

    if bullet_notes:
        return bullet_notes

    paragraph_notes = []
    for line in lines:
        if not line or line.startswith("#"):
            continue
        paragraph_notes.append(line)

    if paragraph_notes:
        return paragraph_notes

    raise SystemExit(f"No usable release notes found in {notes_path}")


def main() -> None:
    args = parse_args()
    notes_path = Path(args.notes_file)
    if not notes_path.is_file():
        raise SystemExit(f"Release notes file not found: {notes_path}")

    payload = load_releases()
    releases = [release for release in payload["releases"] if release["tag"] != args.tag]

    if releases and releases[0]["status"] == "Current public build":
        releases[0]["status"] = "Previous release"

    releases.insert(0, {
        "tag": args.tag,
        "version": args.version,
        "published_at": args.published_at,
        "status": args.status,
        "notes": parse_notes(notes_path),
    })

    payload["releases"] = releases
    dump_releases(payload)


if __name__ == "__main__":
    main()
