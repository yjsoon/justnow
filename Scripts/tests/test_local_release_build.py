"""Exercise alias-icon staging without building, signing, or invoking Finder."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


class ApplicationsAliasTests(unittest.TestCase):
    def test_icon_staging_is_private_and_cleaned_on_success_and_failure(self):
        source = (Path(__file__).resolve().parents[1] / "local-release-build.sh").read_text()
        function = source.split("create_applications_alias()", 1)[1].split("\nwhile [[", 1)[0]
        for fail_sips in (False, True):
            with self.subTest(fail_sips=fail_sips), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scratch = root / "tmp"
                scratch.mkdir()
                tools = root / "bin"
                tools.mkdir()
                icon = root / "source.icns"
                icon.write_text("synthetic icon")
                victim = root / "victim"
                victim.write_text("untouched")
                alias_dir = root / "staging"
                alias_dir.mkdir()
                commands = {
                    # Model a rival observing the old reserved basename and
                    # planting the unreserved suffix before cp opens it.
                    "mktemp": '/usr/bin/mktemp "$@" > "$ROOT/reserved"; '
                    'p=$(cat "$ROOT/reserved"); '
                    'if [ -f "$p" ]; then ln -s "$ROOT/victim" "$p.icns"; fi; '
                    'printf "%s\\n" "$p"',
                    "osascript": 'cat >/dev/null; touch "$2/Applications"',
                    "sips": 'printf "%s\\n" "$2" > "$ROOT/icon-path"; '
                    'if [ "$FAIL_SIPS" = true ]; then exit 42; fi',
                    "DeRez": 'cat "$3"',
                    "Rez": 'cat "$2" > "$4"',
                    "SetFile": "exit 0",
                }
                for name, body in commands.items():
                    tool = tools / name
                    tool.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
                    tool.chmod(0o700)
                result = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\ncreate_applications_alias()" + function
                     + '\ncreate_applications_alias "$ROOT/staging"'],
                    env={**os.environ, "PATH": f"{tools}:/usr/bin:/bin", "ROOT": str(root),
                         "TMPDIR": str(scratch), "APPLICATIONS_ALIAS_ICON": str(icon),
                         "FAIL_SIPS": str(fail_sips).lower()},
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 42 if fail_sips else 0, result.stderr)
                self.assertEqual(victim.read_text(), "untouched", "copy followed an attacker symlink")
                self.assertEqual(list(scratch.iterdir()), [], "temporary icon files leaked")
                if not fail_sips:
                    self.assertEqual((alias_dir / "Applications").read_text(), "synthetic icon")


if __name__ == "__main__":
    unittest.main()
