#!/usr/bin/env python3
"""Publish a prebuilt stable release, signed Sparkle feed, and existing Pages site."""

import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from zipfile import ZipFile


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SITE_URL = "https://justnow.tk.sg"
PROJECT = "justnow-site"


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True, capture_output=capture).stdout


def fetch(url, token=None):
    headers = {"Cache-Control": "no-cache"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        return response.read()


def check_cloudflare_target():
    account = os.environ["CLOUDFLARE_ACCOUNT_ID"]
    if not re.fullmatch(r"[a-f0-9]{32}", account):
        raise SystemExit("Invalid Cloudflare account ID")
    payload = json.loads(fetch(
        f"https://api.cloudflare.com/client/v4/accounts/{account}/pages/projects/{PROJECT}",
        os.environ["CLOUDFLARE_API_TOKEN"],
    ))
    project = payload.get("result") or {}
    if (not payload.get("success") or project.get("name") != PROJECT
            or project.get("production_branch") != "main"
            or "justnow.tk.sg" not in project.get("domains", [])):
        raise SystemExit("Cloudflare account/project/production branch/domain mismatch")


def check_forward_release(tag, info, metadata, feed):
    if info["CFBundleShortVersionString"] != tag[1:]:
        raise SystemExit("Archive version does not match tag")
    build = int(info["CFBundleVersion"])
    current_builds = [int(item.findtext(f"{{{SPARKLE_NS}}}version"))
                      for item in ET.fromstring(feed).findall("./channel/item")]
    latest = metadata["releases"][0]
    if current_builds and (build < max(current_builds)
                          or (build == max(current_builds) and latest["tag"] != tag)):
        raise SystemExit("Refusing to roll back the deployed stable release/build")


def validate_feed(tag, archive, info, feed):
    expected_url = f"https://github.com/{os.environ['GH_REPO']}/releases/download/{tag}/{archive.name}"
    items = [item for item in ET.fromstring(feed).findall("./channel/item")
             if item.find("enclosure") is not None
             and item.find("enclosure").get("url") == expected_url]
    if len(items) != 1:
        raise SystemExit("Feed must contain exactly one enclosure for this release ZIP")
    item = items[0]
    enclosure = item.find("enclosure")
    if (item.findtext(f"{{{SPARKLE_NS}}}version") != str(info["CFBundleVersion"])
            or item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") != tag[1:]
            or enclosure.get("length") != str(archive.stat().st_size)):
        raise SystemExit("Feed build/version/archive size mismatch")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    if not signature:
        raise SystemExit("Feed enclosure has no EdDSA signature")
    return signature


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    tag = parser.parse_args().tag
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise SystemExit("Expected stable tag vX.Y.Z")
    for name in ("SPARKLE_PRIVATE_KEY", "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "GH_REPO"):
        if not os.environ.get(name):
            raise SystemExit(f"Missing CI configuration: {name}")
    if os.environ["GH_REPO"] != "yjsoon/justnow":
        raise SystemExit("This publisher is configured only for yjsoon/justnow")

    check_cloudflare_target()
    archive = Path(f"dist/JustNow-{tag}-macos.zip")
    dmg = Path(f"dist/JustNow-{tag}-macos.dmg")
    if not archive.is_file() or not dmg.is_file():
        raise SystemExit("Both prebuilt release artifacts are required")
    with ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("JustNow.app/Contents/Info.plist"))

    # Deployed metadata/feed are the release ledger; CI never pushes generated files.
    # Fail closed if they cannot be read, rather than replacing history with an old tag's copy.
    metadata = json.loads(fetch(f"{SITE_URL}/releases.json?release={tag}"))
    previous_feed = fetch(f"{SITE_URL}/appcast.xml?release={tag}")
    check_forward_release(tag, info, metadata, previous_feed)
    Path("site/releases.json").write_text(json.dumps(metadata, indent=2) + "\n")
    Path("site/appcast.xml").write_bytes(previous_feed)

    tools = Path(run("bash", "Scripts/ensure-sparkle-tools.sh", capture=True).strip())
    with tempfile.TemporaryDirectory(prefix="justnow-publish-") as temporary:
        scratch = Path(temporary)
        key = scratch / "sparkle-key"
        key.touch(mode=0o600)
        key.write_text(os.environ["SPARKLE_PRIVATE_KEY"])
        account = "sg.tk.JustNow"
        run(str(tools / "bin/generate_keys"), "--account", account, "-f", str(key), capture=True)
        public_key = run(str(tools / "bin/generate_keys"), "--account", account, "-p", capture=True).strip()
        if not info.get("SUPublicEDKey") or public_key != info["SUPublicEDKey"]:
            raise SystemExit("Sparkle private key does not match the app's existing SUPublicEDKey")

        existing = subprocess.run(
            ["gh", "release", "view", tag, "--json", "isDraft,isPrerelease,body,publishedAt,assets"],
            capture_output=True, text=True,
        )
        if existing.returncode:
            run("gh", "release", "create", tag, "--verify-tag", "--draft",
                "--title", f"JustNow {tag}", "--generate-notes")
        release = json.loads(run("gh", "release", "view", tag, "--json",
                                 "isDraft,isPrerelease,body,publishedAt,assets", capture=True))
        if release["isPrerelease"]:
            raise SystemExit("Refusing to publish a prerelease to the stable site/feed")
        notes = scratch / "notes.md"
        notes.write_text(release["body"] or "")
        date = (release["publishedAt"] or datetime.now(timezone.utc).isoformat())[:10]
        run("python3", "Scripts/update-site-release.py", "--tag", tag, "--version", tag[1:],
            "--published-at", date, "--notes-file", str(notes))
        run("python3", "Scripts/generate-site-content.py")
        # Separate Sparkle executables must not depend on interactive keychain ACL prompts.
        run("env", f"SPARKLE_ED_KEY_FILE={key}", "bash", "Scripts/generate-sparkle-appcast.sh", tag)
        signature = validate_feed(tag, archive, info, Path("site/appcast.xml").read_bytes())
        run(str(tools / "bin/sign_update"), "--ed-key-file", str(key), "--verify", str(archive), signature)
        key.unlink()

        # Never overwrite an asset. Reruns can reuse it only when its bytes are identical.
        names = {asset["name"] for asset in release["assets"]}
        for artifact in (archive, dmg):
            if artifact.name not in names:
                run("gh", "release", "upload", tag, str(artifact))
            run("gh", "release", "download", tag, "--pattern", artifact.name, "--dir", str(scratch))
            remote = scratch / artifact.name
            if hashlib.sha256(remote.read_bytes()).digest() != hashlib.sha256(artifact.read_bytes()).digest():
                raise SystemExit("Published asset differs from the validated local artifact; refusing replacement")

        if release["isDraft"]:
            run("gh", "release", "edit", tag, "--draft=false", "--latest")
        # Recheck the target immediately before the production mutation.
        check_cloudflare_target()
        run("bash", "Scripts/deploy-public-site.sh", "--project-name", PROJECT, "--branch", "main",
            "--commit-hash", run("git", "rev-parse", "HEAD", capture=True).strip(),
            "--commit-message", f"Release {tag} (tag source + generated metadata/feed)")

        for attempt in range(12):
            try:
                for path in ("releases.json", "appcast.xml", "releases/index.html"):
                    if fetch(f"{SITE_URL}/{path}?release={tag}&attempt={attempt}") != Path("site", path).read_bytes():
                        raise ValueError(f"Public {path} does not match the generated release")
                fetch(SITE_URL + "/")
                print(f"Verified public website and signed feed for {tag}")
                break
            except (OSError, ValueError):
                if attempt == 11:
                    raise
                time.sleep(10)


if __name__ == "__main__":
    main()
