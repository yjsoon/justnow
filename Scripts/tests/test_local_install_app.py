"""Safety checks for installed apps whose signing identity cannot be read."""

from pathlib import Path
import subprocess
import tempfile
import unittest


class LocalInstallSignatureTests(unittest.TestCase):
    def test_inspection_failure_requires_explicit_identified_migration(self):
        source = (Path(__file__).resolve().parents[1] / "local-install-app.sh").read_text()
        cases = [
            ("unreadable", False, "sg.tk.JustNow", 1, False),
            ("adhoc", False, "sg.tk.JustNow", 71, True),
            ("unreadable", True, "sg.tk.JustNow", 71, True),
            ("unreadable", True, "other.app", 1, False),
            ("unreadable", True, "", 1, False),
        ]
        for signature, override, bundle_id, expected_exit, expected_build in cases:
            with self.subTest(signature=signature, override=override, bundle_id=bundle_id):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    install = root / "JustNow.app"
                    install.mkdir()
                    marker = root / "build-attempted"
                    bin_dir = root / "bin"
                    bin_dir.mkdir()
                    commands = {
                        "codesign": 'if [ "$TEST_SIGNATURE" = adhoc ]; then echo Signature=adhoc; else echo "signature inspection failed" >&2; exit 1; fi',
                        "security": "exit 0",
                        "xcodebuild": f'touch "{marker}"; exit 71',
                        "PlistBuddy": 'printf "%s\\n" "$TEST_BUNDLE_ID"',
                    }
                    for name in ("pkill", "trash", "cp", "open"):
                        commands[name] = 'echo "UNEXPECTED MUTATION" >&2; exit 81'
                    for name, body in commands.items():
                        executable = bin_dir / name
                        executable.write_text("#!/bin/bash\n" + body + "\n")
                        executable.chmod(0o700)
                    # Keep the public script intact except for redirecting its absolute
                    # install/PlistBuddy paths into disposable fixtures on Linux/macOS.
                    script = root / "install.sh"
                    script.write_text(source.replace(
                        'INSTALL_PATH="/Applications/${SCHEME}.app"', f'INSTALL_PATH="{install}"'
                    ).replace("/usr/libexec/PlistBuddy", str(bin_dir / "PlistBuddy")))
                    env = {
                        "PATH": f"{bin_dir}:/usr/bin:/bin",
                        "HOME": str(root),
                        "RELEASE_ENV_FILE": str(root / "absent.env"),
                        "TEST_SIGNATURE": signature,
                        "TEST_BUNDLE_ID": bundle_id,
                    }
                    args = ["bash", str(script)] + (["--allow-signing-change"] if override else [])
                    result = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected_exit, result.stderr)
                    self.assertEqual(marker.exists(), expected_build, result.stderr)
                    self.assertNotIn("UNEXPECTED MUTATION", result.stderr)
                    if signature == "unreadable" and override and expected_build:
                        self.assertIn("installed signature could not be inspected", result.stderr)


if __name__ == "__main__":
    unittest.main()
