#!/usr/bin/env python3
"""
Unit tests for scripts/release/notarize.sh (and, transitively,
scripts/release/verify-notarized.sh).

Runs the script via subprocess against a fake `xcrun`, `ditto`, `codesign` and `spctl`
on PATH, so no real notarization ever happens. Bash, python3 and coreutils only, so this
also runs on ubuntu-latest (see .github/workflows/release-scripts.yml).
"""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent.parent / "release" / "notarize.sh"

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

FAKE_DITTO = r"""#!/usr/bin/env bash
set -euo pipefail
echo "ditto $*" >> "$INVOCATIONS_FILE"
dest="${*: -1}"
: > "$dest"
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


def _write_fake(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class TestNotarize(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        _write_fake(self.fake_bin / "xcrun", FAKE_XCRUN)
        _write_fake(self.fake_bin / "ditto", FAKE_DITTO)
        _write_fake(self.fake_bin / "codesign", FAKE_CODESIGN)
        _write_fake(self.fake_bin / "spctl", FAKE_SPCTL)

        self.app_path = self.root / "Yellowhammer.app"
        self.app_path.mkdir()

        self.out_dir = self.root / "out"
        self.invocations_file = self.root / "invocations.log"
        self.invocations_file.write_text("")

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_notarize(self, extra_env=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        env["INVOCATIONS_FILE"] = str(self.invocations_file)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(SCRIPT_PATH), str(self.app_path), str(self.out_dir)],
            capture_output=True,
            text=True,
            env=env,
        )

    def invocations(self):
        return self.invocations_file.read_text().splitlines()

    def test_accepted_notarization_passes_and_produces_final_zip(self):
        result = self.run_notarize({"FAKE_SUBMIT_STATUS": "Accepted"})
        self.assertEqual(result.returncode, 0, result.stderr)

        log_path = self.out_dir / "notarization-log.json"
        self.assertTrue(log_path.exists())

        final_zip = self.out_dir / "Yellowhammer.zip"
        self.assertTrue(final_zip.exists())

        staple_calls = [line for line in self.invocations() if "stapler staple" in line]
        self.assertEqual(len(staple_calls), 1)

    def test_invalid_notarization_fails_writes_log_skips_staple_and_zip(self):
        result = self.run_notarize({"FAKE_SUBMIT_STATUS": "Invalid"})
        self.assertNotEqual(result.returncode, 0)

        log_path = self.out_dir / "notarization-log.json"
        self.assertTrue(log_path.exists())

        final_zip = self.out_dir / "Yellowhammer.zip"
        self.assertFalse(final_zip.exists())

        staple_calls = [line for line in self.invocations() if "stapler staple" in line]
        self.assertEqual(len(staple_calls), 0)

    def test_submit_json_without_id_fails(self):
        result = self.run_notarize({"FAKE_SUBMIT_JSON": '{"status": "Accepted"}'})
        self.assertNotEqual(result.returncode, 0)

    def test_spctl_without_notarized_source_fails(self):
        result = self.run_notarize(
            {
                "FAKE_SUBMIT_STATUS": "Accepted",
                "FAKE_SPCTL_OUTPUT": "accepted\nsource=Developer ID",
            }
        )
        self.assertNotEqual(result.returncode, 0)

    def test_stapler_validate_failure_fails(self):
        result = self.run_notarize(
            {
                "FAKE_SUBMIT_STATUS": "Accepted",
                "FAKE_STAPLE_VALIDATE_EXIT": "1",
            }
        )
        self.assertNotEqual(result.returncode, 0)

    def test_ci_auth_mode_uses_key_not_keychain_profile(self):
        api_key_path = self.root / "AuthKey_TEST.p8"
        api_key_path.write_text("fake-key")

        result = self.run_notarize(
            {
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


if __name__ == "__main__":
    unittest.main()
