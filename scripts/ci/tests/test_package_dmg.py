#!/usr/bin/env python3
"""
Unit tests for scripts/release/package-dmg.sh.

Runs the script via subprocess against fake `hdiutil`, `codesign`, `xcrun` and `spctl`
on PATH (the real `shasum` is used — it is available on ubuntu-latest coreutils images
too), so no real disk image is ever built or notarized. Bash, python3 and coreutils
only, so this also runs on ubuntu-latest (see .github/workflows/release-scripts.yml).
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent.parent / "release" / "package-dmg.sh"

FAKE_HDIUTIL = r"""#!/usr/bin/env bash
set -euo pipefail
echo "hdiutil $*" >> "$INVOCATIONS_FILE"
if [ "$1" = "create" ]; then
	out="${*: -1}"
	: > "$out"
fi
exit "${FAKE_HDIUTIL_EXIT:-0}"
"""

FAKE_CODESIGN = r"""#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$INVOCATIONS_FILE"
exit "${FAKE_CODESIGN_EXIT:-0}"
"""

FAKE_SPCTL = r"""#!/usr/bin/env bash
set -euo pipefail
echo "spctl $*" >> "$INVOCATIONS_FILE"
echo "${FAKE_SPCTL_OUTPUT:-accepted
source=Notarized Developer ID}" >&2
exit "${FAKE_SPCTL_EXIT:-0}"
"""

FAKE_XCRUN = r"""#!/usr/bin/env bash
set -euo pipefail
echo "xcrun $*" >> "$INVOCATIONS_FILE"

case "$1 $2" in
	"notarytool submit")
		if [ -n "${FAKE_EXPECT_KEY_AUTH:-}" ]; then
			echo "$*" | grep -q -- '--key ' || { echo "fake xcrun: expected --key auth, got: $*" >&2; exit 1; }
			if echo "$*" | grep -q -- '--keychain-profile'; then
				echo "fake xcrun: unexpected --keychain-profile in CI auth mode: $*" >&2
				exit 1
			fi
		fi
		if [ -n "${FAKE_SUBMIT_JSON:-}" ]; then
			printf '%s' "$FAKE_SUBMIT_JSON"
		else
			printf '{"id": "%s", "status": "%s"}' "${FAKE_SUBMIT_ID:-sub-1}" "${FAKE_SUBMIT_STATUS:-Accepted}"
		fi
		exit "${FAKE_SUBMIT_EXIT:-0}"
		;;
	"notarytool log")
		outfile="${*: -1}"
		if [ -n "${FAKE_LOG_CONTENT:-}" ]; then
			printf '%s' "$FAKE_LOG_CONTENT" > "$outfile"
		else
			printf '{"status": "%s", "issues": []}' "${FAKE_SUBMIT_STATUS:-Accepted}" > "$outfile"
		fi
		exit "${FAKE_LOG_EXIT:-0}"
		;;
	"stapler staple")
		exit "${FAKE_STAPLE_EXIT:-0}"
		;;
	"stapler validate")
		exit "${FAKE_STAPLE_VALIDATE_EXIT:-0}"
		;;
	*)
		echo "fake xcrun: unhandled args: $*" >&2
		exit 1
		;;
esac
"""


def _write_fake(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class TestPackageDmg(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        _write_fake(self.fake_bin / "hdiutil", FAKE_HDIUTIL)
        _write_fake(self.fake_bin / "codesign", FAKE_CODESIGN)
        _write_fake(self.fake_bin / "spctl", FAKE_SPCTL)
        _write_fake(self.fake_bin / "xcrun", FAKE_XCRUN)

        real_shasum = shutil.which("shasum")
        if real_shasum:
            (self.fake_bin / "shasum").symlink_to(real_shasum)

        self.app_path = self.root / "Yellowhammer.app"
        self.app_path.mkdir()
        (self.app_path / "marker").write_text("app")

        self.out_dir = self.root / "out"
        self.invocations_file = self.root / "invocations.log"
        self.invocations_file.write_text("")

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_package(self, args=None, extra_env=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        env["INVOCATIONS_FILE"] = str(self.invocations_file)
        if extra_env:
            env.update(extra_env)
        argv = [str(SCRIPT_PATH), str(self.app_path), str(self.out_dir), "Yellowhammer-1.0.0"]
        if args:
            argv.extend(args)
        return subprocess.run(argv, capture_output=True, text=True, env=env)

    def invocations(self):
        return self.invocations_file.read_text().splitlines()

    def test_accepted_notarization_produces_dmg_and_checksums(self):
        result = self.run_package(extra_env={"FAKE_SUBMIT_STATUS": "Accepted"})
        self.assertEqual(result.returncode, 0, result.stderr)

        dmg_path = self.out_dir / "Yellowhammer-1.0.0.dmg"
        self.assertTrue(dmg_path.exists())

        log_path = self.out_dir / "dmg-notarization-log.json"
        self.assertTrue(log_path.exists())

        sums_path = self.out_dir / "SHA256SUMS"
        self.assertTrue(sums_path.exists())
        sums_content = sums_path.read_text()
        self.assertIn("Yellowhammer-1.0.0.dmg", sums_content)
        # bare file name (no directory component) so `shasum -c` works from the out dir
        for line in sums_content.splitlines():
            fields = line.split(maxsplit=1)
            self.assertEqual(len(fields), 2)
            self.assertNotIn("/", fields[1].strip())

        staple_calls = [line for line in self.invocations() if "stapler staple" in line]
        self.assertEqual(len(staple_calls), 1)

        if shutil.which("shasum"):
            verify = subprocess.run(
                ["shasum", "-a", "256", "-c", "SHA256SUMS"],
                cwd=self.out_dir,
                capture_output=True,
                text=True,
            )
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_includes_extra_file_in_checksums(self):
        self.out_dir.mkdir(parents=True, exist_ok=True)
        extra_path = self.out_dir / "Yellowhammer-1.0.0.zip"
        extra_path.write_text("zip contents")

        result = self.run_package(
            args=[str(extra_path)],
            extra_env={"FAKE_SUBMIT_STATUS": "Accepted"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        sums_content = (self.out_dir / "SHA256SUMS").read_text()
        self.assertIn("Yellowhammer-1.0.0.dmg", sums_content)
        self.assertIn("Yellowhammer-1.0.0.zip", sums_content)

    def test_invalid_notarization_fails_and_skips_staple(self):
        result = self.run_package(extra_env={"FAKE_SUBMIT_STATUS": "Invalid"})
        self.assertNotEqual(result.returncode, 0)

        staple_calls = [line for line in self.invocations() if "stapler staple" in line]
        self.assertEqual(len(staple_calls), 0)

        sums_path = self.out_dir / "SHA256SUMS"
        self.assertFalse(sums_path.exists())

    def test_spctl_without_notarized_source_fails(self):
        result = self.run_package(
            extra_env={
                "FAKE_SUBMIT_STATUS": "Accepted",
                "FAKE_SPCTL_OUTPUT": "accepted\nsource=Developer ID",
            }
        )
        self.assertNotEqual(result.returncode, 0)

    def test_stapler_validate_failure_fails(self):
        result = self.run_package(
            extra_env={
                "FAKE_SUBMIT_STATUS": "Accepted",
                "FAKE_STAPLE_VALIDATE_EXIT": "1",
            }
        )
        self.assertNotEqual(result.returncode, 0)

    def test_stapler_staple_failure_fails(self):
        result = self.run_package(
            extra_env={
                "FAKE_SUBMIT_STATUS": "Accepted",
                "FAKE_STAPLE_EXIT": "1",
            }
        )
        self.assertNotEqual(result.returncode, 0)

        sums_path = self.out_dir / "SHA256SUMS"
        self.assertFalse(sums_path.exists())

    def test_ci_auth_mode_uses_key_not_keychain_profile(self):
        api_key_path = self.root / "AuthKey_TEST.p8"
        api_key_path.write_text("fake-key")

        result = self.run_package(
            extra_env={
                "FAKE_SUBMIT_STATUS": "Accepted",
                "FAKE_EXPECT_KEY_AUTH": "1",
                "NOTARY_API_KEY_PATH": str(api_key_path),
                "NOTARY_API_KEY_ID": "KEYID",
                "NOTARY_API_ISSUER_ID": "ISSUERID",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        submit_calls = [line for line in self.invocations() if "notarytool submit" in line]
        self.assertTrue(any("--key " in line for line in submit_calls))
        self.assertFalse(any("--keychain-profile" in line for line in submit_calls))

    def test_signing_identity_and_keychain_env_passed_to_codesign(self):
        result = self.run_package(
            extra_env={
                "FAKE_SUBMIT_STATUS": "Accepted",
                "SIGNING_IDENTITY": "Developer ID Application: Test (TEAMID)",
                "KEYCHAIN_PATH": "/tmp/fake.keychain-db",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        codesign_calls = [line for line in self.invocations() if line.startswith("codesign ")]
        self.assertTrue(codesign_calls)
        self.assertTrue(any("Developer ID Application: Test (TEAMID)" in line for line in codesign_calls))
        self.assertTrue(any("/tmp/fake.keychain-db" in line for line in codesign_calls))


if __name__ == "__main__":
    unittest.main()
