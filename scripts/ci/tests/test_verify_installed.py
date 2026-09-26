#!/usr/bin/env python3
"""
Unit tests for scripts/release/verify_installed.py.

Every external command (`launchctl`, `ps`, `open`, `mdfind`, `osascript`, `plutil`, `segedit`,
`sysctl`, `sw_vers`, `uname`, `env`, `orca`) goes through one injectable `run` callable, so
these tests never touch a real macOS system and run on ubuntu-latest.
"""

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import sys

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts" / "release"))

import verify_installed as vi  # noqa: E402

APP_VERSION = "1.2.3"
APP_BUILD = "42"
PROJECT = "proj"
PRODUCTION_CLIENT_ID = "client-abc"
ORCA_VERSION = "1.4.195"


class ScriptedRun:
    """A stand-in for the injectable `run` callable. Handlers are tried in registration order;
    the first whose predicate matches argv handles the call."""

    def __init__(self):
        self.handlers = []
        self.calls = []

    def on(self, predicate, response):
        self.handlers.append((predicate, response))

    def __call__(self, argv, env=None, timeout=None):
        self.calls.append(list(argv))
        for predicate, response in self.handlers:
            if predicate(argv):
                if callable(response):
                    return response(argv)
                return response
        raise AssertionError(f"unhandled command: {argv}")


def starts_with(*prefix):
    prefix = list(prefix)
    return lambda argv: list(argv[: len(prefix)]) == prefix


class FakeJournalLock:
    """A stand-in for the injectable `journal_lock` factory: records `("acquired", path)` /
    `("released", path)` into a shared list instead of actually shelling out to `sqlite3`."""

    def __init__(self, events, fail_message=None):
        self.events = events
        self.fail_message = fail_message

    def __call__(self, path):
        if self.fail_message is not None:
            raise vi.JournalLockError(self.fail_message)
        return _FakeJournalLockContext(self.events, path)


class _FakeJournalLockContext:
    def __init__(self, events, path):
        self.events = events
        self.path = str(path)

    def __enter__(self):
        self.events.append(("acquired", self.path))
        return self

    def __exit__(self, exc_type, exc, tb):
        self.events.append(("released", self.path))
        return False


def make_launchctl_print_handler(scripts, default="state = waiting\nruns = 0\nlast exit code = 0\n"):
    """`scripts` maps a label to a list of successive `launchctl print` outputs; the last one
    repeats once exhausted."""
    counters = {}

    def handler(argv):
        target = argv[2]
        label = target.split("/")[-1]
        script = scripts.get(label)
        if not script:
            return (0, default, "")
        index = min(counters.get(label, 0), len(script) - 1)
        counters[label] = counters.get(label, 0) + 1
        return (0, script[index], "")

    return handler


class VerifyInstalledTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        # Resolved up front so paths built here match the Verifier's own os.path.realpath calls
        # (macOS puts /tmp behind a /private symlink; Linux CI does not, but this is harmless there).
        self.root = Path(os.path.realpath(self.temp_dir.name))
        self.app_path = self.root / "Applications" / "Yellowhammer.app"
        self.home = self.root / "home"
        (self.home / "Library" / "LaunchAgents").mkdir(parents=True)
        self.evidence_directory = self.root / "evidence"

        self.yh_path = self.app_path / "Contents" / "MacOS" / "yh"

        # Sane defaults for every incidental command a happy-path run touches.
        self.run = ScriptedRun()
        self.run.on(starts_with("sysctl"), (0, "Mac16,1\n", ""))
        self.run.on(starts_with("sw_vers"), (0, "26.0\n", ""))
        self.run.on(starts_with("uname"), (0, "arm64\n", ""))
        self.run.on(starts_with("segedit"), (0, "", ""))
        self.run.on(self._plutil_predicate, self._plutil_response)
        self.run.on(starts_with("env", "-i", str(self.yh_path), "--help"), (0, "usage: yh\n", ""))
        self.run.on(starts_with("env", "-i", str(self.yh_path), "validate"), (0, "ok\n", ""))
        self.run.on(starts_with("mdfind"), (0, f"{self.app_path}\n", ""))
        self.run.on(starts_with("ps", "-axo"), (0, "", ""))

        self.prompts = ["y"]
        self.sleeps = []
        self.now = 0.0
        self.lock_events = []
        self.journal_lock = FakeJournalLock(self.lock_events)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _plutil_predicate(self, argv):
        return argv[0] == "plutil"

    def app_info_plist_path(self):
        return self.app_path / "Contents" / "Info.plist"

    def _plutil_response(self, argv):
        key = argv[2]
        path = argv[-1]
        if path == str(self.app_info_plist_path()):
            values = {"CFBundleShortVersionString": APP_VERSION, "CFBundleVersion": APP_BUILD}
        else:
            values = {
                "CFBundleShortVersionString": APP_VERSION,
                "CFBundleVersion": APP_BUILD,
                "CFBundleIdentifier": "dev.yellowhammer.engine",
            }
        return (0, values.get(key, ""), "")

    def prompt(self, _message):
        return self.prompts.pop(0)

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def make_verifier(self, act="build", act_timeout=5.0, journal_lock=None):
        return vi.Verifier(
            app=self.app_path,
            project=PROJECT,
            production_linear_client_id=PRODUCTION_CLIENT_ID,
            evidence_directory=self.evidence_directory,
            act=act,
            act_timeout=act_timeout,
            run=self.run,
            prompt=self.prompt,
            sleep=self.sleep,
            clock=lambda: self.now,
            home=self.home,
            uid=501,
            user="operator",
            min_orca_version=ORCA_VERSION,
            journal_lock=journal_lock if journal_lock is not None else self.journal_lock,
        )

    def write_journal_file(self):
        journal_dir = self.home / ".config" / "yellowhammer" / "journals"
        journal_dir.mkdir(parents=True, exist_ok=True)
        journal_path = journal_dir / f"{PROJECT}.db"
        journal_path.write_text("")
        return journal_path

    def write_plist(self, act, path=None, args_rest=None, path_env=None):
        label = f"dev.yellowhammer.{PROJECT}.{act}"
        plist = {
            "Label": label,
            "ProgramArguments": [str(path if path is not None else self.yh_path)]
            + (args_rest if args_rest is not None else [act, "--project", PROJECT]),
        }
        if path_env is not None:
            plist["EnvironmentVariables"] = {"PATH": path_env}
        target = self.home / "Library" / "LaunchAgents" / f"{label}.plist"
        with open(target, "wb") as handle:
            plistlib.dump(plist, handle)
        return target

    def write_all_plists(self, path_env="/usr/bin:/bin"):
        for act in vi.ACTS:
            self.write_plist(act, path_env=path_env if act == "build" else None)

    def write_config_toml(self, client_id=PRODUCTION_CLIENT_ID):
        config_dir = self.home / ".config" / "yellowhammer"
        config_dir.mkdir(parents=True)
        (config_dir / "config.toml").write_text(
            f'[general]\nsomething = "x"\n\n[linear]\nclient_id = "{client_id}"\n'
        )

    def setup_orca(self, bin_dir, version=ORCA_VERSION):
        bin_dir.mkdir(parents=True, exist_ok=True)
        orca_path = bin_dir / "orca"
        orca_path.write_text("#!/bin/sh\n")
        orca_path.chmod(0o755)
        self.run.on(starts_with(str(orca_path), "--version"), (0, f"orca {version}\n", ""))
        return orca_path

    # -- check 1: bare environment --

    def test_bare_environment_passes(self):
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        verifier.app_info = verifier._safe_app_info()
        verifier.yh_info = verifier._safe_yh_info()
        passed, reason = verifier.check_bare_environment([])
        self.assertTrue(passed, reason)

    def test_bare_environment_fails_on_help_exit_code(self):
        self.run.handlers.insert(
            0, (starts_with("env", "-i", str(self.yh_path), "--help"), (1, "", "boom"))
        )
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        verifier.app_info = verifier._safe_app_info()
        verifier.yh_info = verifier._safe_yh_info()
        passed, reason = verifier.check_bare_environment([])
        self.assertFalse(passed)
        self.assertIn("--help exited", reason)

    def test_bare_environment_fails_on_version_mismatch(self):
        def mismatched_plutil(argv):
            key = argv[2]
            path = argv[-1]
            if path == str(self.app_info_plist_path()):
                values = {"CFBundleShortVersionString": APP_VERSION, "CFBundleVersion": APP_BUILD}
            else:
                values = {
                    "CFBundleShortVersionString": "9.9.9",
                    "CFBundleVersion": "999",
                    "CFBundleIdentifier": "dev.yellowhammer.engine",
                }
            return (0, values.get(key, ""), "")

        self.run.handlers.insert(0, (self._plutil_predicate, mismatched_plutil))
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        verifier.app_info = verifier._safe_app_info()
        verifier.yh_info = verifier._safe_yh_info()
        passed, reason = verifier.check_bare_environment([])
        self.assertFalse(passed)
        self.assertIn("differs", reason)

    # -- check 2: headless notification --

    def _stub_open_notification(self, stderr_content=""):
        def handler(argv):
            stderr_path = Path(argv[argv.index("--stderr") + 1])
            stderr_path.write_text(stderr_content)
            return (0, "", "")

        self.run.on(starts_with("/usr/bin/open", "-n", "-g", "-W", "-b", "dev.yellowhammer"), handler)

    def test_notification_passes(self):
        self._stub_open_notification("")
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_notification([])
        self.assertTrue(passed, reason)

    def test_notification_fails_when_second_copy_found(self):
        other = str(self.root / "Volumes" / "Yellowhammer" / "Yellowhammer.app")
        self.run.handlers.insert(
            0, (starts_with("mdfind"), (0, f"{self.app_path}\n{other}\n", ""))
        )
        self._stub_open_notification("")
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_notification([])
        self.assertFalse(passed)
        self.assertIn("other dev.yellowhammer copies", reason)

    def test_notification_fails_on_not_authorized_stderr(self):
        self._stub_open_notification("Yellowhammer: notification not authorized\n")
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_notification([])
        self.assertFalse(passed)
        self.assertIn("permission was never granted", reason)

    def test_notification_fails_when_operator_declines(self):
        self._stub_open_notification("")
        self.prompts = ["n"]
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_notification([])
        self.assertFalse(passed)
        self.assertIn("did not confirm", reason)

    # -- check 3: launchd jobs --

    def default_loaded_program_output(self, program=None):
        program = program if program is not None else self.yh_path
        return f"state = waiting\nruns = 0\nlast exit code = 0\n\tprogram = {program}\n"

    def test_launchd_passes(self):
        self.write_all_plists()
        label = f"dev.yellowhammer.{PROJECT}.build"
        scripts = {
            label: [
                f"state = waiting\nruns = 5\nlast exit code = 0\n\tprogram = {self.yh_path}\n",
                "state = waiting\nruns = 5\nlast exit code = 0\n",
                "state = xpcproxy\n\tpid = 4242\nruns = 6\nlast exit code = (never exited)\n",
                "state = running\n\tpid = 4242\nruns = 6\n",
                "state = waiting\nruns = 6\nlast exit code = 0\n",
            ]
        }
        print_handler = make_launchctl_print_handler(scripts, default=self.default_loaded_program_output())
        last_print = {"out": ""}

        def recording_print_handler(argv):
            response = print_handler(argv)
            last_print["out"] = response[1]
            return response

        def ps_handler(_argv):
            # Under `xpcproxy` the pid is launchd's spawn trampoline, which has not exec'd yh yet.
            if "state = xpcproxy" in last_print["out"]:
                return (0, "/usr/libexec/xpcproxy\n", "")
            return (0, f"{self.yh_path}\n", "")

        self.run.on(starts_with("launchctl", "print"), recording_print_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))
        self.run.on(starts_with("ps", "-o", "comm="), ps_handler)
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_launchd([])
        self.assertTrue(passed, reason)

    def test_launchd_fails_when_loaded_program_is_different_yh(self):
        self.write_all_plists()
        other_yh = self.root / "somewhere-else" / "yh"
        label = f"dev.yellowhammer.{PROJECT}.build"
        scripts = {label: [self.default_loaded_program_output(program=other_yh)]}
        self.run.on(
            starts_with("launchctl", "print"),
            make_launchctl_print_handler(scripts, default=self.default_loaded_program_output()),
        )
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_launchd([])
        self.assertFalse(passed)
        self.assertIn("is loaded with program", reason)
        self.assertIn("not the installed yh", reason)

    def test_launchd_fails_when_plist_points_elsewhere(self):
        other_yh = self.root / "somewhere-else" / "yh"
        self.write_plist("author", path=other_yh)
        self.write_plist("build")
        self.write_plist("land")
        self.run.on(starts_with("launchctl", "print"), (0, "state = waiting\n", ""))
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_launchd([])
        self.assertFalse(passed)
        self.assertIn("not the installed yh", reason)

    def test_launchd_fails_on_nonzero_exit_code(self):
        self.write_all_plists()
        label = f"dev.yellowhammer.{PROJECT}.build"
        scripts = {
            label: [
                f"state = waiting\nruns = 5\nlast exit code = 0\n\tprogram = {self.yh_path}\n",
                "state = waiting\nruns = 5\nlast exit code = 0\n",
                "state = running\n\tpid = 4242\nruns = 5\n",
                "state = waiting\nruns = 6\nlast exit code = 1\n",
            ]
        }
        self.run.on(
            starts_with("launchctl", "print"),
            make_launchctl_print_handler(scripts, default=self.default_loaded_program_output()),
        )
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))
        self.run.on(starts_with("ps", "-o", "comm="), (0, f"{self.yh_path}\n", ""))
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_launchd([])
        self.assertFalse(passed)
        self.assertIn("last exit code", reason)

    # -- check 4: yh doctor --

    def test_doctor_passes(self):
        path_env = str(self.root / "path-bin")
        self.write_all_plists(path_env=path_env)
        self.write_config_toml()
        self.setup_orca(Path(path_env))
        self.run.on(
            starts_with("env", "-i"),
            (0, "[pass] probes: ok\n[pass] linear: Linear authorization succeeded\n", ""),
        )
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_doctor([])
        self.assertTrue(passed, reason)

    def test_doctor_fails_when_probe_line_missing(self):
        path_env = str(self.root / "path-bin")
        self.write_all_plists(path_env=path_env)
        self.write_config_toml()
        self.setup_orca(Path(path_env))
        self.run.on(
            starts_with("env", "-i"),
            (0, "[pass] linear: Linear authorization succeeded\n", ""),
        )
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_doctor([])
        self.assertFalse(passed)
        self.assertIn("probes:", reason)

    def test_doctor_fails_on_client_id_mismatch(self):
        path_env = str(self.root / "path-bin")
        self.write_all_plists(path_env=path_env)
        self.write_config_toml(client_id="wrong-client")
        self.setup_orca(Path(path_env))
        self.run.on(
            starts_with("env", "-i"),
            (0, "[pass] probes: ok\n[pass] linear: Linear authorization succeeded\n", ""),
        )
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_doctor([])
        self.assertFalse(passed)
        self.assertIn("client_id", reason)

    def test_doctor_fails_on_old_orca(self):
        path_env = str(self.root / "path-bin")
        self.write_all_plists(path_env=path_env)
        self.write_config_toml()
        self.setup_orca(Path(path_env), version="1.0.0")
        self.run.on(
            starts_with("env", "-i"),
            (0, "[pass] probes: ok\n[pass] linear: Linear authorization succeeded\n", ""),
        )
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_doctor([])
        self.assertFalse(passed)
        self.assertIn("older than", reason)

    # -- check 5: shell, not host --

    def test_shell_not_host_5a_fails_when_window_app_appears(self):
        self.write_all_plists()
        label = f"dev.yellowhammer.{PROJECT}.build"
        window_pids = {"present": False}

        def ps_axo_handler(_argv):
            if window_pids["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer --some-flag\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))
        self.run.on(
            starts_with("launchctl", "print"),
            make_launchctl_print_handler(
                {
                    label: [
                        "state = waiting\nruns = 0\nlast exit code = 0\n",
                        "state = waiting\nruns = 1\nlast exit code = 0\n",
                    ]
                }
            ),
        )

        def kickstart_handler(_argv):
            window_pids["present"] = True
            return (0, "", "")

        self.run.on(starts_with("launchctl", "kickstart"), kickstart_handler)
        verifier = self.make_verifier()
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("appeared during an unattended Act", reason)

    def test_shell_not_host_5b_inconclusive_after_three_tries(self):
        self.write_all_plists()
        label = f"dev.yellowhammer.{PROJECT}.build"
        window_pids = {"present": False}

        def ps_axo_handler(_argv):
            if window_pids["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        calls = {"n": 0}

        def launchctl_print_handler(_argv):
            calls["n"] += 1
            n = calls["n"]
            if n == 1:
                # 5a baseline.
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if n == 2:
                # 5a: finishes immediately (state not running, runs incremented).
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            # 5b (every attempt): a pid that does not exist on this machine, so os.kill(pid, 0)
            # always raises and the job is never observed "overlapping" the app's quit.
            return (0, "state = running\n\tpid = 999999999\nruns = 1\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_print_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        def open_handler(_argv):
            window_pids["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)

        def quit_handler(_argv):
            window_pids["present"] = False
            return (0, "", "")

        self.run.on(starts_with("osascript"), quit_handler)

        journal_path = self.write_journal_file()
        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("inconclusive", reason)
        # Every one of the three attempts acquired and released the lock — no leak.
        self.assertEqual(
            self.lock_events,
            [
                ("acquired", str(journal_path)), ("released", str(journal_path)),
                ("acquired", str(journal_path)), ("released", str(journal_path)),
                ("acquired", str(journal_path)), ("released", str(journal_path)),
            ],
        )

    def test_shell_not_host_full_pass(self):
        self.write_all_plists()
        label = f"dev.yellowhammer.{PROJECT}.build"
        window_pids = {"present": False}

        def ps_axo_handler(_argv):
            if window_pids["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        state = {"n": 0}

        def launchctl_handler(_argv):
            state["n"] += 1
            call = state["n"]
            if call == 1:
                # 5a baseline.
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                # 5a: first poll shows it already finished.
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 3:
                # 5b baseline.
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 4:
                # 5b: waiting for pid — job still running, using this test's own pid so
                # os.kill(pid, 0) succeeds (this process definitely exists).
                return (0, f"state = running\n\tpid = {os.getpid()}\nruns = 1\n", "")
            # 5b post-quit: finished cleanly.
            return (0, "state = waiting\nruns = 2\nlast exit code = 0\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        def open_handler(_argv):
            window_pids["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)

        def quit_handler(_argv):
            window_pids["present"] = False
            return (0, "", "")

        self.run.on(starts_with("osascript"), quit_handler)

        journal_path = self.write_journal_file()
        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertTrue(passed, reason)
        # Acquired before the kickstart-and-quit sequence, released after the app quit.
        self.assertEqual(
            self.lock_events, [("acquired", str(journal_path)), ("released", str(journal_path))]
        )

    def test_shell_not_host_5b_fails_when_osascript_lacks_automation_permission(self):
        self.write_all_plists()
        window_pids = {"present": False}

        def ps_axo_handler(_argv):
            if window_pids["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        state = {"n": 0}

        def launchctl_handler(_argv):
            state["n"] += 1
            call = state["n"]
            if call == 1:
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 3:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            return (0, f"state = running\n\tpid = {os.getpid()}\nruns = 1\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        def open_handler(_argv):
            window_pids["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)
        self.run.on(
            starts_with("osascript"),
            (1, "", "execution error: Not authorized to send Apple events (-1743)"),
        )

        journal_path = self.write_journal_file()
        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("Automation", reason)
        self.assertIn("-1743", reason)
        # The lock is released even though 5b failed mid-way — no leaked lock.
        self.assertEqual(
            self.lock_events, [("acquired", str(journal_path)), ("released", str(journal_path))]
        )

    def test_shell_not_host_5b_fails_when_journal_missing(self):
        # No self.write_journal_file() — checks 3/5a are supposed to have created it.
        self.write_all_plists()
        window_pids = {"present": False}

        def ps_axo_handler(_argv):
            if window_pids["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        kickstart_calls = {"n": 0}

        def kickstart_handler(_argv):
            kickstart_calls["n"] += 1
            return (0, "", "")

        state = {"n": 0}

        def launchctl_handler(_argv):
            state["n"] += 1
            call = state["n"]
            if call == 1:
                # 5a baseline.
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            # 5a: finishes immediately.
            return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), kickstart_handler)

        def open_handler(_argv):
            window_pids["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("does not exist", reason)
        # 5a's own kickstart is the only one — 5b never got as far as firing the Act.
        self.assertEqual(kickstart_calls["n"], 1)
        self.assertEqual(self.lock_events, [])

    def test_shell_not_host_5b_retries_when_app_does_not_quit_within_lock_budget(self):
        self.write_all_plists()
        window_pids = {"present": False}

        def ps_axo_handler(_argv):
            if window_pids["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        state = {"n": 0}

        def launchctl_handler(_argv):
            state["n"] += 1
            call = state["n"]
            if call == 1:
                # 5a baseline.
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                # 5a: finishes immediately.
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            # 5b (every attempt): job running throughout — the app never quits.
            return (0, f"state = running\n\tpid = {os.getpid()}\nruns = 1\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        def open_handler(_argv):
            window_pids["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)
        # osascript "succeeds" but the window app never actually quits.
        self.run.on(starts_with("osascript"), (0, "", ""))

        journal_path = self.write_journal_file()
        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("hold budget", reason)
        # Three attempts, each acquiring and releasing the lock — never leaked.
        self.assertEqual(
            self.lock_events,
            [
                ("acquired", str(journal_path)), ("released", str(journal_path)),
                ("acquired", str(journal_path)), ("released", str(journal_path)),
                ("acquired", str(journal_path)), ("released", str(journal_path)),
            ],
        )

    def test_journal_lock_real_sqlite3_implementation(self):
        if shutil.which("sqlite3") is None:
            self.skipTest("sqlite3 not on PATH")
        db_path = self.root / "journal-lock-test.db"
        subprocess.run(["sqlite3", str(db_path), "CREATE TABLE t (x INTEGER);"], check=True)

        with vi.default_journal_lock(db_path):
            result = subprocess.run(
                ["sqlite3", str(db_path), ".timeout 100", "INSERT INTO t VALUES (1);"],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("locked", (result.stderr or "").lower())

        result = subprocess.run(
            ["sqlite3", str(db_path), ".timeout 100", "INSERT INTO t VALUES (1);"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    # -- record: crashed check --

    def test_record_marks_crashed_check_as_fail(self):
        # No plists written at all -> check 3 fails cleanly (not a crash); force a genuine crash
        # in check 2 by making mdfind explode.
        def boom(_argv):
            raise RuntimeError("mdfind exploded")

        self.run.handlers.insert(0, (starts_with("mdfind"), boom))
        self._stub_open_notification("")
        verifier = self.make_verifier()
        code = verifier.record()
        self.assertEqual(code, 1)
        verdict = json.loads((self.evidence_directory / "verdict.json").read_text())
        check_2 = next(c for c in verdict["checks"] if c["id"] == 2)
        self.assertFalse(check_2["passed"])
        self.assertIn("mdfind exploded", check_2["reason"])

    def test_record_writes_five_logs_and_verdict(self):
        self.write_all_plists(path_env=str(self.root / "path-bin"))
        self.write_config_toml()
        self.setup_orca(self.root / "path-bin")
        self._stub_open_notification("")
        label = f"dev.yellowhammer.{PROJECT}.build"

        def launchctl_handler(argv):
            return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))
        self.run.on(starts_with("ps", "-o", "comm="), (0, f"{self.yh_path}\n", ""))
        self.run.on(
            starts_with("env", "-i", "HOME="),
            (0, "[pass] probes: ok\n[pass] linear: Linear authorization succeeded\n", ""),
        )

        verifier = self.make_verifier()
        verifier.record()
        for filename in vi.LOG_FILENAMES.values():
            self.assertTrue((self.evidence_directory / filename).is_file(), filename)
        self.assertTrue((self.evidence_directory / "verdict.json").is_file())
        verdict = json.loads((self.evidence_directory / "verdict.json").read_text())
        self.assertEqual(len(verdict["checks"]), 5)
        self.assertEqual(verdict["app"]["version"], APP_VERSION)
        self.assertEqual(verdict["yh"]["bundle_id"], "dev.yellowhammer.engine")


class CheckCommandTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.evidence_directory = Path(self.temp_dir.name) / "evidence"
        self.evidence_directory.mkdir()

    def tearDown(self):
        self.temp_dir.cleanup()

    def write_verdict(self, passed=True, checks=None, version=APP_VERSION):
        if checks is None:
            checks = [{"id": i, "name": f"check {i}", "passed": True, "reason": ""} for i in range(1, 6)]
        verdict = {
            "recorded_at": "2026-01-01T00:00:00Z",
            "host": {"model": "Mac16,1", "macos": "26.0", "arch": "arm64"},
            "app": {"path": "/Applications/Yellowhammer.app", "version": version, "build": "42"},
            "yh": {"path": "yh", "version": version, "build": "42", "bundle_id": "dev.yellowhammer.engine"},
            "project": PROJECT,
            "checks": checks,
            "passed": passed,
        }
        (self.evidence_directory / "verdict.json").write_text(json.dumps(verdict))

    def run_check(self, args):
        return vi.main(["check", "--evidence-directory", str(self.evidence_directory)] + args)

    def test_check_fails_when_verdict_missing(self):
        self.assertEqual(self.run_check([]), 1)

    def test_check_fails_when_a_check_failed(self):
        checks = [{"id": i, "name": f"check {i}", "passed": i != 3, "reason": "x"} for i in range(1, 6)]
        self.write_verdict(passed=False, checks=checks)
        self.assertEqual(self.run_check([]), 1)

    def test_check_fails_on_version_mismatch(self):
        self.write_verdict(passed=True, version="0.0.1")
        self.assertEqual(self.run_check(["--version", "1.2.3"]), 1)

    def test_check_passes_when_all_green(self):
        self.write_verdict(passed=True)
        self.assertEqual(self.run_check(["--version", APP_VERSION]), 0)


if __name__ == "__main__":
    unittest.main()
