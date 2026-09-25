#!/usr/bin/env python3
"""
Unit tests for scripts/release/appcast.sh.

Runs the script via subprocess against a stub `sign_update` (via SIGN_UPDATE_PATH), so no
real EdDSA key or Sparkle binary is needed. Bash, python3 and coreutils only, so this also
runs on ubuntu-latest (see .github/workflows/release-scripts.yml).
"""

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent.parent / "release" / "appcast.sh"

FAKE_SIGN_UPDATE = r"""#!/usr/bin/env bash
set -euo pipefail
echo "sign_update $*" >> "$INVOCATIONS_FILE"

# Consume the key from stdin so a real invocation's contract (key never as a CLI arg) is
# exercised, and record whether stdin was actually the key text.
key="$(cat)"
echo "$key" > "$STDIN_CAPTURE_FILE"

if [ -n "${FAKE_SIGN_UPDATE_EXIT:-}" ]; then
	exit "$FAKE_SIGN_UPDATE_EXIT"
fi

echo "${FAKE_SIGNATURE:-fake-signature==}"
"""


def _write_fake(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class TestAppcast(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self.fake_sign_update = self.fake_bin / "sign_update"
        _write_fake(self.fake_sign_update, FAKE_SIGN_UPDATE)

        self.zip_path = self.root / "Yellowhammer-1.2.3-42.zip"
        self.zip_path.write_bytes(b"fake zip contents")

        self.out_dir = self.root / "out"
        self.invocations_file = self.root / "invocations.log"
        self.invocations_file.write_text("")
        self.stdin_capture_file = self.root / "stdin.txt"

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_appcast(self, extra_env=None, args=None, key="fake-private-key"):
        env = dict(os.environ)
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        env["INVOCATIONS_FILE"] = str(self.invocations_file)
        env["STDIN_CAPTURE_FILE"] = str(self.stdin_capture_file)
        env["SIGN_UPDATE_PATH"] = str(self.fake_sign_update)
        if key is not None:
            env["SPARKLE_ED_PRIVATE_KEY"] = key
        else:
            env.pop("SPARKLE_ED_PRIVATE_KEY", None)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            args
            or [
                str(SCRIPT_PATH),
                str(self.zip_path),
                "1.2.3",
                "42",
                "v1.2.3",
                str(self.out_dir),
            ],
            capture_output=True,
            text=True,
            env=env,
        )

    def test_writes_appcast_with_enclosure_and_signature(self):
        result = self.run_appcast()
        self.assertEqual(result.returncode, 0, result.stderr)

        appcast_path = self.out_dir / "appcast.xml"
        self.assertTrue(appcast_path.exists())
        xml = appcast_path.read_text()

        self.assertIn("<sparkle:version>42</sparkle:version>", xml)
        self.assertIn("<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>", xml)
        self.assertIn("<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>", xml)
        self.assertIn(
            'url="https://github.com/summerhammer/yellowhammer/releases/download/v1.2.3/'
            'Yellowhammer-1.2.3-42.zip"',
            xml,
        )
        self.assertIn('length="17"', xml)
        self.assertIn('sparkle:edSignature="fake-signature=="', xml)

    def test_key_is_piped_on_stdin_not_a_cli_argument(self):
        result = self.run_appcast(key="super-secret-key")
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertEqual(self.stdin_capture_file.read_text().strip(), "super-secret-key")

        invocation = self.invocations_file.read_text()
        self.assertNotIn("super-secret-key", invocation)
        self.assertNotIn("super-secret-key", result.stdout)
        self.assertNotIn("super-secret-key", result.stderr)

    def test_missing_private_key_fails(self):
        result = self.run_appcast(key=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY", result.stdout)

    def test_missing_zip_fails(self):
        result = self.run_appcast(
            args=[
                str(SCRIPT_PATH),
                str(self.root / "does-not-exist.zip"),
                "1.2.3",
                "42",
                "v1.2.3",
                str(self.out_dir),
            ]
        )
        self.assertNotEqual(result.returncode, 0)

    def test_sign_update_failure_fails_and_writes_no_appcast(self):
        result = self.run_appcast(extra_env={"FAKE_SIGN_UPDATE_EXIT": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.out_dir / "appcast.xml").exists())

    def test_missing_sign_update_binary_fails(self):
        result = self.run_appcast(extra_env={"SIGN_UPDATE_PATH": str(self.root / "no-such-tool")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sign_update", result.stdout)

    def test_usage_requires_five_arguments(self):
        result = self.run_appcast(args=[str(SCRIPT_PATH), str(self.zip_path)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage", result.stdout)


if __name__ == "__main__":
    unittest.main()
