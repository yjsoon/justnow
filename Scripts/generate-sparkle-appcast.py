#!/usr/bin/env python3

import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile


REPO_ROOT = Path(__file__).resolve().parent.parent
RELEASES_PATH = REPO_ROOT / "site" / "releases.json"
SITE_APPCAST_PATH = REPO_ROOT / "site" / "appcast.xml"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a Sparkle appcast for a JustNow release.")
    parser.add_argument("--tag", required=True, help="Release tag, for example v0.1.1")
    parser.add_argument("--archive", required=True, help="Path to the signed zip archive for the release")
    parser.add_argument("--generate-appcast-bin", required=True, help="Path to Sparkle's generate_appcast binary")
    parser.add_argument("--key-account", required=True, help="Sparkle keychain account name")
    parser.add_argument("--download-url-prefix", required=True, help="Public download URL prefix ending with the release tag path")
    parser.add_argument("--site-url", required=True, help="Public site URL, for example https://justnow.tk.sg")
    parser.add_argument("--release-notes-url", required=True, help="Public full release notes URL")
    return parser.parse_args()


def load_release(tag: str) -> tuple[dict, dict]:
    with RELEASES_PATH.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    for release in payload["releases"]:
        if release["tag"] == tag:
            return payload, release

    raise SystemExit(f"Release {tag} was not found in {RELEASES_PATH}")


def write_notes_file(staging_dir: Path, archive_name: str, release: dict) -> None:
    notes_path = staging_dir / f"{archive_name}.md"
    notes = "\n".join(f"- {note}" for note in release["notes"])
    notes_path.write_text(notes + "\n", encoding="utf-8")


def has_real_appcast_entries(appcast_path: Path) -> bool:
    if not appcast_path.exists():
        return False

    content = appcast_path.read_text(encoding="utf-8")
    return "<enclosure " in content and "sparkle:version" in content


def archive_requires_ed_signature(archive_path: Path) -> bool:
    with ZipFile(archive_path) as archive:
        plist_candidates = sorted(
            name for name in archive.namelist()
            if name.endswith(".app/Contents/Info.plist")
        )

        for plist_name in plist_candidates:
            with archive.open(plist_name) as handle:
                info = plistlib.load(handle)
            if info.get("SUPublicEDKey"):
                return True

    return False


def current_item_has_ed_signature(appcast_path: Path, archive_name: str) -> bool:
    root = ET.fromstring(appcast_path.read_text(encoding="utf-8"))
    enclosure_tag = "enclosure"
    signature_key = f"{{{SPARKLE_NS}}}edSignature"

    for enclosure in root.iter(enclosure_tag):
        url = enclosure.attrib.get("url", "")
        if url.endswith(f"/{archive_name}") or url.endswith(archive_name):
            return signature_key in enclosure.attrib

    return False


def normalise_feed_urls(appcast_path: Path, site_url: str, release_notes_url: str) -> None:
    ET.register_namespace("sparkle", SPARKLE_NS)
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    link_tag = "link"
    notes_tag = f"{{{SPARKLE_NS}}}fullReleaseNotesLink"

    for item in root.findall("./channel/item"):
        link = item.find(link_tag)
        if link is not None:
            link.text = site_url

        notes_link = item.find(notes_tag)
        if notes_link is not None:
            notes_link.text = release_notes_url

    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)


def main() -> None:
    args = parse_args()
    archive_path = Path(args.archive)
    if not archive_path.is_file():
        raise SystemExit(f"Archive not found: {archive_path}")

    _, release = load_release(args.tag)

    with tempfile.TemporaryDirectory(prefix="justnow-sparkle-") as staging_root:
        staging_dir = Path(staging_root)
        staged_archive = staging_dir / archive_path.name
        shutil.copy2(archive_path, staged_archive)
        write_notes_file(staging_dir, archive_path.stem, release)

        if has_real_appcast_entries(SITE_APPCAST_PATH):
            shutil.copy2(SITE_APPCAST_PATH, staging_dir / "appcast.xml")

        subprocess.run(
            [
                args.generate_appcast_bin,
                str(staging_dir),
                "--account",
                args.key_account,
                "--download-url-prefix",
                args.download_url_prefix,
                "--embed-release-notes",
                "--link",
                args.site_url,
                "--full-release-notes-url",
                args.release_notes_url,
                "--maximum-deltas",
                "0",
            ],
            check=True,
        )

        shutil.copy2(staging_dir / "appcast.xml", SITE_APPCAST_PATH)

    normalise_feed_urls(SITE_APPCAST_PATH, args.site_url, args.release_notes_url)

    if archive_requires_ed_signature(archive_path) and not current_item_has_ed_signature(SITE_APPCAST_PATH, archive_path.name):
        raise SystemExit(
            "Generated appcast is missing sparkle:edSignature for a Sparkle-enabled archive. "
            "Check the configured EdDSA key before publishing."
        )


if __name__ == "__main__":
    main()
