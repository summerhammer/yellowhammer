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
import signal
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
ORCA_VERSION = "1.4.195"

_UNSET = object()


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


class FakeSignal:
    """A stand-in for the injectable `signal` callable (`os.kill`'s signature): records every
    call as `("signal", pid, sig)` into a shared events list — the same list other fakes (like
    the osascript quit handler) append `("quit",)` markers to, so cross-action ordering (e.g.
    "SIGCONT comes after the quit") can be asserted from one sequence. Raises
    `ProcessLookupError` for any signal listed in `raise_on`. `state(pid)` answers the fake
    `ps -o stat=`: `T` once SIGSTOP'd, `S` otherwise, and no process when SIGSTOP raised or when
    `gone_after_quit` and the app has been quit."""

    def __init__(self, events, raise_on=None, gone_after_quit=False):
        self.events = events
        self.raise_on = set(raise_on or ())
        self.gone_after_quit = gone_after_quit

    def __call__(self, pid, sig):
        self.events.append(("signal", pid, sig))
        if sig in self.raise_on:
            raise ProcessLookupError(f"no such process: {pid}")

    def state(self, _pid):
        if signal.SIGSTOP in self.raise_on:
            return None
        if self.gone_after_quit and ("quit",) in self.events:
            return None
        sent = [event[2] for event in self.events if event[0] == "signal" and event[2] != 0]
        return "T" if sent and sent[-1] == signal.SIGSTOP else "S"


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
        self.events = []
        self.signal = FakeSignal(self.events)
        self.active_signal = self.signal

        def ps_stat_handler(argv):
            state = self.active_signal.state(int(argv[-1]))
            return (0, f"{state}\n", "") if state else (1, "", "")

        self.run.on(starts_with("ps", "-o", "stat="), ps_stat_handler)

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

    def make_verifier(self, act="build", act_timeout=5.0, signal_fn=None):
        return vi.Verifier(
            app=self.app_path,
            project=PROJECT,
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
            signal=self._activate(signal_fn),
        )

    def _activate(self, signal_fn):
        self.active_signal = signal_fn if signal_fn is not None else self.signal
        return self.active_signal

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

    def install_manual_window_app_fake(self):
        """Wires `ps -axo`, `open -a` and `osascript` (quit) to a shared `present` flag the test
        controls explicitly: `open` sets it, the osascript handler clears it and records a
        `("quit",)` marker into `self.events` so ordering against signal calls is assertable."""
        state = {"present": False}

        def ps_axo_handler(_argv):
            if state["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        def open_handler(_argv):
            state["present"] = True
            return (0, "", "")

        def quit_handler(_argv):
            state["present"] = False
            self.events.append(("quit",))
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))
        self.run.on(starts_with("open", "-a"), open_handler)
        self.run.on(starts_with("osascript"), quit_handler)
        return state

    def install_ephemeral_window_app_fake(self):
        """For tests where 5b never reaches the osascript quit: `open` marks the app present,
        the *next* `ps -axo` poll reports it present exactly once and then clears it — so the
        next attempt's "wait for the previous app to exit" loop proceeds immediately without a
        real quit ever happening."""
        state = {"present": False, "unread": False}

        def ps_axo_handler(_argv):
            if state["present"] and state["unread"]:
                state["unread"] = False
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            state["present"] = False
            return (0, "", "")

        def open_handler(_argv):
            state["present"] = True
            state["unread"] = True
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))
        self.run.on(starts_with("open", "-a"), open_handler)
        return state

    def signal_calls(self, sig=_UNSET):
        """The `(pid, sig)` pairs recorded for signal events, in call order. Defaults to only
        SIGSTOP/SIGCONT (skipping the liveness check's signal-0 calls and the `("quit",)`
        markers `self.events` also carries); pass an explicit `sig` (including `0`) to filter to
        just that one."""
        wanted = (signal.SIGSTOP, signal.SIGCONT) if sig is _UNSET else (sig,)
        return [
            (event[1], event[2])
            for event in self.events
            if event[0] == "signal" and event[2] in wanted
        ]

    def write_config_toml(self):
        config_dir = self.home / ".config" / "yellowhammer"
        config_dir.mkdir(parents=True)
        (config_dir / "config.toml").write_text(
            '[general]\nsomething = "x"\n\n[linear]\ncredential = "keychain:linear"\n'
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

    def launchctl_handler_per_attempt(self, second_call_response):
        """Builds a `launchctl print` handler for 5b tests: calls 1–2 are 5a's baseline and
        immediate-finish; from call 3 on, each attempt gets two calls — a baseline (`waiting`,
        `runs = 1 + attempt`) and `second_call_response(runs)` for whatever the test wants that
        attempt's poll to show."""
        counters = {"n": 0}

        def handler(_argv):
            counters["n"] += 1
            call = counters["n"]
            if call == 1:
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            idx = call - 3
            attempt, step = divmod(idx, 2)
            base_runs = 1 + attempt
            if step == 0:
                return (0, f"state = waiting\nruns = {base_runs}\nlast exit code = 0\n", "")
            return (0, second_call_response(base_runs), "")

        return handler

    def test_shell_not_host_full_pass(self):
        self.write_all_plists()
        self.install_manual_window_app_fake()

        counters = {"n": 0}

        def launchctl_handler(_argv):
            counters["n"] += 1
            call = counters["n"]
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
                # 5b: waiting for a running pid — found on the first poll.
                return (0, "state = running\n\tpid = 4242\nruns = 1\n", "")
            # 5b post-resume: finished cleanly.
            return (0, "state = waiting\nruns = 2\nlast exit code = 0\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertTrue(passed, reason)
        # kickstart -> SIGSTOP -> osascript quit -> app gone -> SIGCONT -> finished exit 0.
        self.assertEqual(self.signal_calls(), [(4242, signal.SIGSTOP), (4242, signal.SIGCONT)])
        quit_index = self.events.index(("quit",))
        sigcont_index = next(
            i for i, e in enumerate(self.events) if e == ("signal", 4242, signal.SIGCONT)
        )
        self.assertLess(quit_index, sigcont_index)

    def test_shell_not_host_5b_retries_when_act_finishes_before_pause(self):
        self.write_all_plists()
        self.install_ephemeral_window_app_fake()

        def second_call_response(base_runs):
            # The Act finished (runs incremented, no pid, not running) before ever being seen
            # in the `running` state — inconclusive, not a defect.
            return f"state = waiting\nruns = {base_runs + 1}\nlast exit code = 0\n"

        self.run.on(
            starts_with("launchctl", "print"),
            self.launchctl_handler_per_attempt(second_call_response),
        )
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("finished before it could be paused", reason)
        self.assertIn("inconclusive", reason)
        # Never got far enough to send a signal.
        self.assertEqual(self.events, [])

    def test_shell_not_host_5b_retries_when_sigstop_raises(self):
        self.write_all_plists()
        self.install_ephemeral_window_app_fake()

        def second_call_response(base_runs):
            return f"state = running\n\tpid = 4242\nruns = {base_runs}\n"

        self.run.on(
            starts_with("launchctl", "print"),
            self.launchctl_handler_per_attempt(second_call_response),
        )
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        signal_fn = FakeSignal(self.events, raise_on={signal.SIGSTOP})
        verifier = self.make_verifier(act_timeout=2.0, signal_fn=signal_fn)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("exited before it could be paused", reason)
        self.assertIn("inconclusive", reason)
        # Every attempt tried to pause the pid it found, and never got as far as resuming.
        self.assertEqual(self.signal_calls(signal.SIGSTOP), [(4242, signal.SIGSTOP)] * 3)
        self.assertEqual(self.signal_calls(signal.SIGCONT), [])

    def test_shell_not_host_5b_retries_when_the_paused_pid_is_a_zombie(self):
        # The Act exited just before SIGSTOP: SIGSTOP and kill(pid, 0) both succeed on the zombie,
        # so only `ps` can tell it was never really paused. That must never count as an overlap.
        self.write_all_plists()
        self.install_ephemeral_window_app_fake()

        def second_call_response(base_runs):
            return f"state = running\n\tpid = 4242\nruns = {base_runs}\n"

        self.run.on(
            starts_with("launchctl", "print"),
            self.launchctl_handler_per_attempt(second_call_response),
        )
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        signal_fn = FakeSignal(self.events)
        signal_fn.state = lambda _pid: "Z"
        verifier = self.make_verifier(act_timeout=2.0, signal_fn=signal_fn)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("inconclusive", reason)
        # No attempt quit the app on the strength of a zombie, and every pause was undone.
        self.assertNotIn(("quit",), self.events)
        self.assertEqual(len(self.signal_calls(signal.SIGCONT)), 3)

    def test_shell_not_host_5b_fails_when_osascript_lacks_automation_permission(self):
        self.write_all_plists()
        self.install_manual_window_app_fake()

        counters = {"n": 0}

        def launchctl_handler(_argv):
            counters["n"] += 1
            call = counters["n"]
            if call == 1:
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 3:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            return (0, "state = running\n\tpid = 4242\nruns = 1\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))
        self.run.handlers.insert(
            0,
            (
                starts_with("osascript"),
                (1, "", "execution error: Not authorized to send Apple events (-1743)"),
            ),
        )

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("Automation", reason)
        self.assertIn("-1743", reason)
        # SIGCONT is still sent even though osascript failed mid-way — no leaked pause.
        self.assertEqual(self.signal_calls(), [(4242, signal.SIGSTOP), (4242, signal.SIGCONT)])

    def test_shell_not_host_5b_retries_when_app_does_not_quit_within_pause_timeout(self):
        self.write_all_plists()
        # The app quits, but slowly: it lingers well past the 10s pause-quit timeout after
        # osascript returns, then clears during the *next* attempt's own initial wait.
        state = {"present": False, "linger": None}
        opened_while_running = []

        def ps_axo_handler(_argv):
            if state["linger"] is not None:
                out = (
                    (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
                    if state["present"] else (0, "", "")
                )
                state["linger"] -= 1
                if state["linger"] <= 0:
                    state["present"] = False
                    state["linger"] = None
                return out
            if state["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        def open_handler(_argv):
            # LaunchServices fails with -600 when the app is still quitting.
            if state["present"]:
                opened_while_running.append(True)
                return (1, "", "_LSOpenURLsWithCompletionHandler() failed ... with error -600.\n")
            state["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)

        def quit_handler(_argv):
            # 25 polls (12.5s of fake sleeps) outlasts the 10s/20-poll pause-quit timeout, but
            # clears well before the next attempt's own 20s wait would time out.
            state["linger"] = 25
            self.events.append(("quit",))
            return (0, "", "")

        self.run.on(starts_with("osascript"), quit_handler)

        def second_call_response(base_runs):
            return f"state = running\n\tpid = 4242\nruns = {base_runs}\n"

        self.run.on(
            starts_with("launchctl", "print"),
            self.launchctl_handler_per_attempt(second_call_response),
        )
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn(f"{vi.PAUSE_QUIT_TIMEOUT_SECONDS}s", reason)
        self.assertIn("paused", reason)
        # Every attempt paused, quit, and resumed — never left the Act stopped.
        self.assertEqual(self.signal_calls(signal.SIGSTOP), [(4242, signal.SIGSTOP)] * 3)
        self.assertEqual(self.signal_calls(signal.SIGCONT), [(4242, signal.SIGCONT)] * 3)
        # Never opened the app again while a previous attempt's was still quitting.
        self.assertEqual(opened_while_running, [])

    def test_shell_not_host_5b_waits_for_earlier_attempt_app_before_opening(self):
        # Exercises `_run_5b_once` directly (not through `check_shell_not_host`, which runs 5a
        # first and 5a itself refuses to start with the window app already present) — this is
        # specifically 5b's own "wait for an earlier attempt's app to quit" step at the top of
        # `_run_5b_once`.
        self.write_all_plists()
        label = f"dev.yellowhammer.{PROJECT}.build"
        # Simulate a leftover window app from an earlier attempt still quitting when this attempt
        # begins: present for the first 6 `ps` polls, then gone.
        state = {"present": True, "linger": 6}
        opened_while_running = []

        def ps_axo_handler(_argv):
            if state["linger"] is not None:
                out = (
                    (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
                    if state["present"] else (0, "", "")
                )
                state["linger"] -= 1
                if state["linger"] <= 0:
                    state["present"] = False
                    state["linger"] = None
                return out
            if state["present"]:
                return (0, f"4321 {self.app_path}/Contents/MacOS/Yellowhammer\n", "")
            return (0, "", "")

        self.run.handlers.insert(0, (starts_with("ps", "-axo"), ps_axo_handler))

        def open_handler(_argv):
            if state["present"]:
                opened_while_running.append(True)
                return (1, "", "_LSOpenURLsWithCompletionHandler() failed ... with error -600.\n")
            state["present"] = True
            return (0, "", "")

        self.run.on(starts_with("open", "-a"), open_handler)

        def quit_handler(_argv):
            state["present"] = False
            self.events.append(("quit",))
            return (0, "", "")

        self.run.on(starts_with("osascript"), quit_handler)

        counters = {"n": 0}

        def launchctl_handler(_argv):
            counters["n"] += 1
            call = counters["n"]
            if call == 1:
                # 5b baseline.
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = running\n\tpid = 4242\nruns = 1\n", "")
            return (0, "state = waiting\nruns = 2\nlast exit code = 0\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        status, reason = verifier._run_5b_once(label, [])
        self.assertEqual(status, "pass", reason)
        self.assertEqual(opened_while_running, [])

    def test_shell_not_host_5b_fails_when_act_gone_after_quit(self):
        self.write_all_plists()
        self.install_manual_window_app_fake()

        counters = {"n": 0}

        def launchctl_handler(_argv):
            counters["n"] += 1
            call = counters["n"]
            if call == 1:
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 3:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            return (0, "state = running\n\tpid = 4242\nruns = 1\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        # The liveness check (signal 0) raises: quitting the app killed the paused Act.
        signal_fn = FakeSignal(self.events, gone_after_quit=True)
        verifier = self.make_verifier(act_timeout=2.0, signal_fn=signal_fn)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("gone after the window app quit", reason)
        self.assertIn("5b (quit mid-Act)", reason)
        # Not a retry: this is exactly the defect the check exists to catch.
        self.assertNotIn("inconclusive", reason)
        # SIGCONT was still attempted even though the pid was already gone (and swallowed).
        self.assertEqual(self.signal_calls(signal.SIGSTOP), [(4242, signal.SIGSTOP)])
        self.assertEqual(self.signal_calls(signal.SIGCONT), [(4242, signal.SIGCONT)])

    def test_shell_not_host_5b_xpcproxy_pid_is_not_paused(self):
        self.write_all_plists()
        self.install_manual_window_app_fake()

        counters = {"n": 0}

        def launchctl_handler(_argv):
            counters["n"] += 1
            call = counters["n"]
            if call == 1:
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 3:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 4:
                # xpcproxy reports a pid too — launchd's spawn trampoline, not yet yh.
                return (0, "state = xpcproxy\n\tpid = 999\nruns = 1\n", "")
            if call == 5:
                return (0, "state = running\n\tpid = 4242\nruns = 1\n", "")
            return (0, "state = waiting\nruns = 2\nlast exit code = 0\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertTrue(passed, reason)
        self.assertEqual(self.signal_calls(signal.SIGSTOP), [(4242, signal.SIGSTOP)])
        self.assertEqual(self.signal_calls(signal.SIGCONT), [(4242, signal.SIGCONT)])

    def test_shell_not_host_5b_fails_on_nonzero_exit_after_resume(self):
        self.write_all_plists()
        self.install_manual_window_app_fake()

        counters = {"n": 0}

        def launchctl_handler(_argv):
            counters["n"] += 1
            call = counters["n"]
            if call == 1:
                return (0, "state = waiting\nruns = 0\nlast exit code = 0\n", "")
            if call == 2:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 3:
                return (0, "state = waiting\nruns = 1\nlast exit code = 0\n", "")
            if call == 4:
                return (0, "state = running\n\tpid = 4242\nruns = 1\n", "")
            return (0, "state = waiting\nruns = 2\nlast exit code = 1\n", "")

        self.run.on(starts_with("launchctl", "print"), launchctl_handler)
        self.run.on(starts_with("launchctl", "kickstart"), (0, "", ""))

        verifier = self.make_verifier(act_timeout=2.0)
        verifier.evidence_directory.mkdir(parents=True)
        passed, reason = verifier.check_shell_not_host([])
        self.assertFalse(passed)
        self.assertIn("last exit code", reason)
        self.assertEqual(self.signal_calls(signal.SIGSTOP), [(4242, signal.SIGSTOP)])
        self.assertEqual(self.signal_calls(signal.SIGCONT), [(4242, signal.SIGCONT)])

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
