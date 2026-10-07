import importlib.util
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile


SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("publisher", SCRIPTS / "ci-release-publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
REAL_RUN = subprocess.run
OLD_FEED = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:version>22</sparkle:version>
<enclosure url="https://github.com/yjsoon/justnow/releases/download/v1.5.2/JustNow-v1.5.2-macos.zip"
length="91" sparkle:edSignature="historical-signature" /></item></channel></rss>'''
NEW_FEED = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:version>23</sparkle:version>
<sparkle:shortVersionString>1.5.3</sparkle:shortVersionString>
<enclosure url="https://github.com/yjsoon/justnow/releases/download/v1.5.3/JustNow-v1.5.3-macos.zip"
length="SIZE" sparkle:edSignature="synthetic-signature" /></item>
<item><sparkle:version>22</sparkle:version>
<enclosure url="https://github.com/yjsoon/justnow/releases/download/v1.5.2/JustNow-v1.5.2-macos.zip"
length="91" sparkle:edSignature="historical-signature" /></item></channel></rss>'''


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        previous = Path.cwd()
        os.chdir(self.temporary.name)
        self.addCleanup(os.chdir, previous)
        Path("Scripts").mkdir()
        Path("site/releases").mkdir(parents=True)
        Path("dist").mkdir()
        for name in ("update-site-release.py", "generate-site-content.py"):
            shutil.copy2(SCRIPTS / name, Path("Scripts", name))
        self.metadata = {
            "site": {"downloads_url": "https://github.com/yjsoon/justnow/releases/latest",
                     "releases_url": "https://github.com/yjsoon/justnow/releases",
                     "changelog_url": "https://github.com/yjsoon/justnow/blob/main/CHANGELOG.md"},
            "product": {"name": "JustNow"},
            "releases": [{"tag": "v1.5.2", "version": "1.5.2", "published_at": "2026-09-11",
                          "status": "Current public build", "notes": ["Older notes"]}],
        }
        self.info = {"CFBundleVersion": "23", "CFBundleShortVersionString": "1.5.3",
                     "SUPublicEDKey": "existing-public-key"}
        self.archive = Path("dist/JustNow-v1.5.3-macos.zip")
        with ZipFile(self.archive, "w") as archive:
            archive.writestr("JustNow.app/Contents/Info.plist", plistlib.dumps(self.info))
        Path("dist/JustNow-v1.5.3-macos.dmg").write_bytes(b"synthetic DMG")
        self.feed = NEW_FEED.replace(b"SIZE", str(self.archive.stat().st_size).encode())
        self.calls = []
        self.deployed = False
        self.public_key = "existing-public-key"
        self.bad_signature = False
        self.bad_download = False
        self.release = {"isDraft": True, "isPrerelease": False, "body": "- A new feature\n- A fix",
                        "publishedAt": None, "assets": []}
        self.project = {"success": True, "result": {"name": "justnow-site", "production_branch": "main",
                                                    "domains": ["justnow.tk.sg"]}}
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"GH_REPO": "yjsoon/justnow", "SPARKLE_PRIVATE_KEY": "synthetic-key",
                                "CLOUDFLARE_API_TOKEN": "synthetic-token",
                                "CLOUDFLARE_ACCOUNT_ID": "a" * 32}).start()
        patch("sys.argv", ["ci-release-publish.py", "v1.5.3"]).start()
        patch.object(publisher, "fetch", side_effect=self.fetch).start()
        patch.object(publisher, "run", side_effect=self.run_command).start()
        patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)).start()

    def fetch(self, url, token=None):
        if "api.cloudflare.com" in url:
            return json.dumps(self.project).encode()
        if self.deployed:
            path = url.split("justnow.tk.sg/")[1].split("?")[0]
            return Path("site", path).read_bytes() if path else b"homepage"
        if "releases.json" in url:
            return json.dumps(self.metadata).encode()
        return OLD_FEED

    def run_command(self, *args, capture=False):
        self.calls.append(args)
        if args[0] == "python3":
            REAL_RUN(args, check=True)
        elif args[1] == "Scripts/ensure-sparkle-tools.sh":
            return "tools\n"
        elif args[0].endswith("generate_keys"):
            if "-f" in args:
                key = Path(args[-1])
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertEqual(key.read_text(), "synthetic-key")
            else:
                return self.public_key + "\n"
        elif args[-2] == "Scripts/generate-sparkle-appcast.sh":
            self.assertEqual(args[0], "env")
            self.assertTrue(args[1].startswith("SPARKLE_ED_KEY_FILE="))
            Path("site/appcast.xml").write_bytes(self.feed)
        elif args[0].endswith("sign_update"):
            self.assertEqual(args[1], "--ed-key-file")
            self.assertTrue(Path(args[2]).is_file())
            if self.bad_signature:
                raise subprocess.CalledProcessError(1, args)
        elif args[:3] == ("gh", "release", "view"):
            return json.dumps(self.release)
        elif args[:3] == ("gh", "release", "download"):
            name = args[args.index("--pattern") + 1]
            destination = Path(args[-1], name)
            destination.write_bytes(b"changed" if self.bad_download else Path("dist", name).read_bytes())
        elif args[1] == "Scripts/deploy-public-site.sh":
            self.deployed = True
        elif args[0] == "git":
            return "synthetic-commit\n"
        return ""

    def assert_no_publication(self):
        self.assertFalse(self.deployed)
        self.assertFalse(any(call[:3] in (("gh", "release", "upload"), ("gh", "release", "edit"))
                             for call in self.calls))

    def test_full_release_preserves_history_and_verifies_before_publication(self):
        publisher.main()
        self.assertTrue(self.deployed)
        metadata = json.loads(Path("site/releases.json").read_text())
        self.assertEqual([r["tag"] for r in metadata["releases"]], ["v1.5.3", "v1.5.2"])
        self.assertEqual(metadata["releases"][0]["notes"], ["A new feature", "A fix"])
        self.assertEqual(metadata["releases"][1]["status"], "Previous release")
        self.assertIn("v1.5.3", Path("site/releases/index.html").read_text())
        verify = next(i for i, c in enumerate(self.calls) if c[0].endswith("sign_update"))
        upload = next(i for i, c in enumerate(self.calls) if c[:3] == ("gh", "release", "upload"))
        publish = next(i for i, c in enumerate(self.calls) if c[:3] == ("gh", "release", "edit"))
        deploy = next(i for i, c in enumerate(self.calls) if c[1] == "Scripts/deploy-public-site.sh")
        self.assertLess(verify, upload)
        self.assertLess(upload, publish)
        self.assertLess(publish, deploy)
        self.assertFalse(any("--clobber" in c for c in self.calls))

    def test_wrong_cloudflare_domain_stops_before_release_creation(self):
        self.project["result"]["domains"] = ["another.example"]
        with self.assertRaisesRegex(SystemExit, "domain mismatch"):
            publisher.main()
        self.assertEqual(self.calls, [])

    def test_wrong_sparkle_key_stops_before_release_creation(self):
        self.public_key = "different-public-key"
        with self.assertRaisesRegex(SystemExit, "does not match"):
            publisher.main()
        self.assertFalse(any(c[0] == "gh" for c in self.calls))
        self.assert_no_publication()

    def test_invalid_signature_stops_before_upload_or_deployment(self):
        self.bad_signature = True
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.main()
        self.assert_no_publication()

    def test_changed_historical_enclosure_stops_before_publication(self):
        self.feed = self.feed.replace(b"historical-signature", b"changed-signature")
        with self.assertRaisesRegex(SystemExit, "history"):
            publisher.main()
        self.assert_no_publication()

    def test_missing_historical_enclosure_stops_before_publication(self):
        self.feed = self.feed.replace(b"/v1.5.2/JustNow-v1.5.2-macos.zip", b"/removed.zip")
        with self.assertRaisesRegex(SystemExit, "history"):
            publisher.main()
        self.assert_no_publication()

    def test_feed_preserves_more_than_three_historical_downloads(self):
        older = b'''<item><enclosure url="https://example/older-1.zip" length="41"
sparkle:edSignature="older-1-signature" /></item>
<item><enclosure url="https://example/older-2.zip" length="52"
sparkle:edSignature="older-2-signature" /></item>
<item><enclosure url="https://example/older-3.zip" length="63"
sparkle:edSignature="older-3-signature" /></item>'''
        previous = OLD_FEED.replace(b"</channel>", older + b"</channel>")
        preserved = self.feed.replace(b"</channel>", older + b"</channel>")
        self.assertEqual(publisher.validate_feed("v1.5.3", self.archive, self.info, preserved, previous),
                         "synthetic-signature")
        with self.assertRaisesRegex(SystemExit, "history"):
            publisher.validate_feed("v1.5.3", self.archive, self.info,
                                    preserved.replace(b"older-3.zip", b"removed.zip"), previous)

    def test_credential_files_are_removed_even_if_keychain_cleanup_fails(self):
        workflow = (SCRIPTS.parent / ".github/workflows/release.yml").read_text()
        cleanup = workflow.split("      - name: Remove signing credentials\n", 1)[1]
        script = textwrap.dedent(cleanup.split("        run: |\n", 1)[1])
        for name in ("justnow-release.keychain-db", "signing.p12", "notary.p8"):
            Path(name).write_text("synthetic credential")
        result = REAL_RUN(["bash", "-c", "security() { return 17; }\n" + script],
                          env={**os.environ, "RUNNER_TEMP": str(Path.cwd())}, capture_output=True)
        self.assertEqual(result.returncode, 17)
        self.assertFalse(Path("signing.p12").exists())
        self.assertFalse(Path("notary.p8").exists())

    def test_lipo_verification_keeps_binary_out_of_architecture_arguments(self):
        workflow = (SCRIPTS.parent / ".github/workflows/release.yml").read_text()
        command = shlex.split(next(line.strip() for line in workflow.splitlines()
                                   if line.strip().startswith("lipo ")))
        verify = command.index("-verify_arch")
        self.assertEqual(command[verify + 1:], ["arm64", "x86_64"])
        self.assertEqual(command[1:verify],
                         ["build/Build/Products/Release/JustNow.app/Contents/MacOS/JustNow"])

    def test_changed_download_stops_before_release_publication(self):
        self.bad_download = True
        with self.assertRaisesRegex(SystemExit, "differs"):
            publisher.main()
        self.assertFalse(self.deployed)
        self.assertFalse(any(c[:3] == ("gh", "release", "edit") for c in self.calls))

    def test_identical_existing_assets_are_reused_without_upload(self):
        self.release["assets"] = [{"name": self.archive.name}, {"name": "JustNow-v1.5.3-macos.dmg"}]
        publisher.main()
        self.assertTrue(self.deployed)
        self.assertFalse(any(c[:3] == ("gh", "release", "upload") for c in self.calls))

    def test_feed_rejects_wrong_url_size_version_build_and_missing_signature(self):
        for old, new in ((b"yjsoon/justnow", b"someone/justnow"),
                         (str(self.archive.stat().st_size).encode(), b"1"),
                         (b">1.5.3<", b">1.5.4<"), (b">23<", b">24<"),
                         (b'sparkle:edSignature="synthetic-signature"', b"")):
            with self.subTest(corruption=old), self.assertRaises(SystemExit):
                publisher.validate_feed("v1.5.3", self.archive, self.info, self.feed.replace(old, new), OLD_FEED)

    def test_build_boundaries_reject_rollback_and_reused_build_for_new_tag(self):
        for build in ("21", "22"):
            with self.subTest(build=build), self.assertRaisesRegex(SystemExit, "roll back"):
                publisher.check_forward_release("v1.5.3", {**self.info, "CFBundleVersion": build},
                                                self.metadata, OLD_FEED)
        publisher.check_forward_release("v1.5.3", self.info, self.metadata, OLD_FEED)
        publisher.check_forward_release("v1.5.2", {**self.info, "CFBundleVersion": "22",
                                        "CFBundleShortVersionString": "1.5.2"}, self.metadata, OLD_FEED)

    def test_older_marketing_version_is_rejected_even_with_a_higher_build(self):
        with self.assertRaisesRegex(SystemExit, "roll back"):
            publisher.check_forward_release("v1.4.1", {**self.info, "CFBundleShortVersionString": "1.4.1"},
                                            self.metadata, OLD_FEED)
        # Version ordering is numeric, not lexical.
        latest = {**self.metadata, "releases": [{"tag": "v1.5.9", "version": "1.5.9"}]}
        publisher.check_forward_release("v1.5.10", {**self.info, "CFBundleShortVersionString": "1.5.10"},
                                        latest, OLD_FEED)

    def test_generator_supports_file_signing_and_preserves_local_account_mode(self):
        generator_spec = importlib.util.spec_from_file_location("generator", SCRIPTS / "generate-sparkle-appcast.py")
        generator = importlib.util.module_from_spec(generator_spec)
        generator_spec.loader.exec_module(generator)
        generator.RELEASES_PATH = Path("site/releases.json")
        generator.SITE_APPCAST_PATH = Path("site/appcast.xml")
        Path("site/releases.json").write_text(json.dumps({"releases": [{"tag": "v1.5.3", "notes": ["New"]}]}))

        for source, expected in ((["--ed-key-file", "/private/key"], "--ed-key-file"),
                                 (["--key-account", "sg.tk.JustNow"], "--account")):
            def generate(args, check):
                self.assertTrue(check)
                self.assertIn(expected, args)
                self.assertNotIn("--account" if expected == "--ed-key-file" else "--ed-key-file", args)
                self.assertIn("--maximum-versions", args)
                self.assertEqual(args[args.index("--maximum-versions") + 1], "0")
                Path(args[1], "appcast.xml").write_bytes(self.feed)

            argv = ["generator", "--tag", "v1.5.3", "--archive", str(self.archive),
                    "--generate-appcast-bin", "synthetic-tool", "--download-url-prefix", "https://example/",
                    "--site-url", "https://justnow.tk.sg", "--release-notes-url", "https://justnow.tk.sg/releases/",
                    *source]
            with self.subTest(source=source), patch("sys.argv", argv), \
                    patch.object(generator.subprocess, "run", side_effect=generate):
                generator.main()
                self.assertIn(b"synthetic-signature", Path("site/appcast.xml").read_bytes())


if __name__ == "__main__":
    unittest.main()
