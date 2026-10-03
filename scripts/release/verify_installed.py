#!/usr/bin/env python3
"""
Installed-product verification (P16.6): runs the five checks the roadmap names against a
notarized release installed from the DMG into /Applications on a clean Apple Silicon Mac,
after the Operator has run `yh setup --install-jobs` for one dedicated verification Project.

  record --app PATH --project ID --evidence-directory DIR
         [--act build] [--act-timeout 600]
    Runs all five checks (never stops at the first failure — each is independent, and a
    crashed check is recorded FAIL with the exception text), writes one log file per check
    into the evidence directory (`1-bare-environment.log` .. `5-shell-not-host.log`) and
    `verdict.json`, prints a `PASS [n] <name>` / `FAIL [n] <name>: <reason>` summary line per
    check, and exits 0 only if all five pass.

  check --evidence-directory DIR [--version X.Y.Z]
    Exits 0 only if `verdict.json` exists, every check passed, and (when `--version` is given)
    the verdict's installed app marketing version matches it. Otherwise prints why and exits 1.

The five checks:
  1. Bare environment      — `env -i yh --help` and `env -i yh validate` both exit 0, and yh's
                              embedded version/build match the app's.
  2. Headless notification — the installed bundle identity is the only `dev.yellowhammer` copy
                              Spotlight knows about, the engine's own headless notification
                              invocation succeeds silently, and the Operator confirms the
                              notification appeared.
  3. launchd jobs           — the three generated LaunchAgents point at the installed yh, are
                              loaded, and the selected Act's job actually fires it.
  4. yh doctor              — probes pass, Orca ADE meets the minimum version, and the
                              Linear App Installation's authorization succeeds.
  5. Shell, not host        — an Act fires and finishes whether or not the app was ever opened,
                              and quitting the app mid-Act does not kill it.

Python stdlib only (macOS system python3 is 3.9 — no `tomllib`). All external commands are
issued through one injectable runner so tests can stub `launchctl`/`ps`/`open`/`mdfind`/
`osascript`/`plutil`/`segedit`/`sysctl`/`sw_vers`/`uname`/`env` without touching the real
system; the whole test suite therefore runs on ubuntu-latest.
"""

import argparse
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = SCRIPT_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent

ACTS = ("author", "build", "land")

LOG_FILENAMES = {
    1: "1-bare-environment.log",
    2: "2-notification.log",
    3: "3-launchd.log",
    4: "4-doctor.log",
    5: "5-shell-not-host.log",
}

TOTAL_CHECKS = 5

# The Act on the verification Project is idle and finishes in well under a second, so check 5b
# polls `launchctl print` fast to catch its pid before it exits.
PID_POLL_SECONDS = 0.05

# How long check 5b waits for the window app to quit while the Act is paused (SIGSTOP'd). A
# paused Act could in rare cases be holding the Journal's write lock, and the app cannot quit
# while the Journal is write-locked (measured on the Mac mini) — so if the app has not quit in
# this long, resume the Act and retry rather than wait indefinitely.
PAUSE_QUIT_TIMEOUT_SECONDS = 10.0


def utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_run(argv, env=None, timeout=None):
    """The default runner: an ordinary subprocess call. Tests inject a stub with this same
    signature instead."""
    result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    return result.returncode, result.stdout, result.stderr


def load_min_orca_version(repo_root=REPO_ROOT):
    """Reads MIN_ORCA_VERSION from check-prerequisites.sh rather than duplicating the constant."""
    text = (repo_root / "scripts" / "check-prerequisites.sh").read_text()
    match = re.search(r'MIN_ORCA_VERSION="([\d.]+)"', text)
    if not match:
        raise RuntimeError("could not find MIN_ORCA_VERSION in scripts/check-prerequisites.sh")
    return match.group(1)


def version_tuple(version):
    return tuple(int(part) for part in re.findall(r"\d+", version))


def parse_version_output(text):
    match = re.search(r"(\d+\.\d+\.\d+)", text or "")
    return match.group(1) if match else None


# MARK: - Verifier


class Verifier:
    def __init__(
        self,
        app,
        project,
        evidence_directory,
        act="build",
        act_timeout=600.0,
        run=None,
        prompt=None,
        sleep=None,
        home=None,
        uid=None,
        user=None,
        min_orca_version=None,
        clock=None,
        signal=None,
    ):
        self.app_path = Path(os.path.realpath(str(app)))
        self.project = project
        self.evidence_directory = Path(evidence_directory)
        self.act = act
        self.act_timeout = act_timeout

        self.run = run or default_run
        self.prompt = prompt or input
        self.sleep = sleep or (lambda seconds: __import__("time").sleep(seconds))
        self.home = Path(home) if home is not None else Path(os.path.expanduser("~"))
        self.uid = uid if uid is not None else os.getuid()
        self.user = user or os.environ.get("USER", "")
        self.min_orca_version = min_orca_version or load_min_orca_version()
        self.clock = clock or time.monotonic
        # `signal` here is the constructor parameter (a fake in tests), not the `signal` module —
        # the module is still used unshadowed everywhere else (e.g. `signal.SIGSTOP`).
        self.signal = signal or os.kill

        self.yh_path = self.app_path / "Contents" / "MacOS" / "yh"
        self.yh_realpath = os.path.realpath(str(self.yh_path))
        self.window_app_path = str(self.app_path / "Contents" / "MacOS" / "Yellowhammer")
        self.app_info_plist = self.app_path / "Contents" / "Info.plist"

        self.app_info = {}
        self.yh_info = {}

    # -- small run helpers --

    def _run_single(self, argv, timeout=None):
        code, out, err = self.run(argv, timeout=timeout)
        if code != 0:
            raise RuntimeError(f"{' '.join(argv)} failed (exit {code}): {err.strip()}")
        return out.strip()

    def _plutil_extract(self, plist_path, key):
        code, out, err = self.run(["plutil", "-extract", key, "raw", str(plist_path)])
        if code != 0:
            raise RuntimeError(f"plutil -extract {key} failed for {plist_path}: {err.strip()}")
        return out.strip()

    def _label(self, act=None):
        return f"dev.yellowhammer.{self.project}.{act or self.act}"

    def _launchctl_print(self, label):
        return self.run(["launchctl", "print", f"gui/{self.uid}/{label}"])

    def _kickstart(self, label):
        code, _out, _err = self.run(["launchctl", "kickstart", f"gui/{self.uid}/{label}"])
        return code

    @staticmethod
    def _parse_launchctl(output):
        runs = re.search(r"^\s*runs\s*=\s*(\d+)", output or "", re.MULTILINE)
        pid = re.search(r"^\s*pid\s*=\s*(\d+)", output or "", re.MULTILINE)
        exit_code = re.search(r"^\s*last exit code\s*=\s*(-?\d+)", output or "", re.MULTILINE)
        state = re.search(r"^\s*state\s*=\s*(.+?)\s*$", output or "", re.MULTILINE)
        program = re.search(r"^\s*program\s*=\s*(\S+)", output or "", re.MULTILINE)
        return {
            "runs": int(runs.group(1)) if runs else None,
            "pid": int(pid.group(1)) if pid else None,
            "last_exit_code": int(exit_code.group(1)) if exit_code else None,
            "state": state.group(1) if state else None,
            "program": program.group(1) if program else None,
        }

    @staticmethod
    def _summarize(parsed):
        return (
            f"pid={parsed.get('pid')} state={parsed.get('state')} "
            f"runs={parsed.get('runs')} last_exit_code={parsed.get('last_exit_code')}"
        )

    def _window_app_pid(self):
        code, out, err = self.run(["ps", "-axo", "pid=,args="])
        if code != 0:
            raise RuntimeError(f"ps -axo pid=,args= failed: {err.strip()}")
        for line in (out or "").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split(None, 1)
            if len(parts) != 2:
                continue
            pid_text, args = parts
            if args.startswith(self.window_app_path) and "--post-notification" not in args:
                try:
                    return int(pid_text)
                except ValueError:
                    continue
        return None

    # -- app / yh / host info --

    def _safe_app_info(self):
        try:
            version = self._plutil_extract(self.app_info_plist, "CFBundleShortVersionString")
            build = self._plutil_extract(self.app_info_plist, "CFBundleVersion")
            return {"path": str(self.app_path), "version": version, "build": build}
        except Exception as error:  # noqa: BLE001 - surfaced via check 1's reason instead
            return {"path": str(self.app_path), "version": None, "build": None, "error": str(error)}

    def _safe_yh_info(self):
        try:
            tmp_path = self.evidence_directory / "yh-embedded-info.plist"
            code, _out, err = self.run(
                ["segedit", str(self.yh_path), "-extract", "__TEXT", "__info_plist", str(tmp_path)]
            )
            if code != 0:
                raise RuntimeError(f"segedit failed: {err.strip()}")
            version = self._plutil_extract(tmp_path, "CFBundleShortVersionString")
            build = self._plutil_extract(tmp_path, "CFBundleVersion")
            bundle_id = self._plutil_extract(tmp_path, "CFBundleIdentifier")
            return {"path": str(self.yh_path), "version": version, "build": build, "bundle_id": bundle_id}
        except Exception as error:  # noqa: BLE001 - surfaced via check 1's reason instead
            return {
                "path": str(self.yh_path), "version": None, "build": None, "bundle_id": None,
                "error": str(error),
            }

    def _safe_host_info(self):
        try:
            model = self._run_single(["sysctl", "-n", "hw.model"])
            macos = self._run_single(["sw_vers", "-productVersion"])
            arch = self._run_single(["uname", "-m"])
            return {"model": model, "macos": macos, "arch": arch}
        except Exception as error:  # noqa: BLE001 - host info is informational only
            return {"model": None, "macos": None, "arch": None, "error": str(error)}

    # -- check 1: bare environment --

    def check_bare_environment(self, log):
        if self.app_info.get("error"):
            return False, f"could not read the app's version: {self.app_info['error']}"
        if self.yh_info.get("error"):
            return False, f"could not read yh's embedded version: {self.yh_info['error']}"

        code, out, err = self.run(["env", "-i", str(self.yh_path), "--help"])
        log.append(f"$ env -i {self.yh_path} --help\n{out}\n{err}")
        if code != 0:
            return False, f"env -i yh --help exited {code}"

        code, out, err = self.run(["env", "-i", str(self.yh_path), "validate"])
        log.append(f"$ env -i {self.yh_path} validate\n{out}\n{err}")
        if code != 0:
            return False, f"env -i yh validate exited {code}"

        if self.yh_info["version"] != self.app_info["version"] or self.yh_info["build"] != self.app_info["build"]:
            return False, (
                f"yh version/build ({self.yh_info['version']}/{self.yh_info['build']}) differs from "
                f"the app's ({self.app_info['version']}/{self.app_info['build']})"
            )
        return True, ""

    # -- check 2: headless notification --

    def check_notification(self, log):
        code, out, err = self.run(["mdfind", "kMDItemCFBundleIdentifier == 'dev.yellowhammer'"])
        log.append(f"$ mdfind kMDItemCFBundleIdentifier == 'dev.yellowhammer'\n{out}\n{err}")
        if code != 0:
            return False, f"mdfind exited {code}"

        found = [os.path.realpath(path) for path in (out or "").splitlines() if path.strip()]
        app_real = os.path.realpath(str(self.app_path))
        others = sorted(set(path for path in found if path != app_real))
        if others:
            return False, (
                f"mdfind found other dev.yellowhammer copies: {others}; LaunchServices might open one of "
                "them instead of the installed app — eject the DMG or delete the other copies"
            )
        if app_real not in found:
            return False, f"mdfind did not list the installed app at {app_real}"

        stderr_path = self.evidence_directory / "notification-stderr.txt"
        argv = [
            "/usr/bin/open", "-n", "-g", "-W", "-b", "dev.yellowhammer",
            "--stderr", str(stderr_path), "--args", "--post-notification",
            "--project", self.project, "--event", "closed",
        ]
        code, out, err = self.run(argv, timeout=30)
        log.append(f"$ {' '.join(argv)}\n{out}\n{err}")
        if code != 0:
            return False, f"open exited {code}"

        stderr_content = stderr_path.read_text() if stderr_path.is_file() else ""
        if stderr_content.strip():
            if "not authorized" in stderr_content:
                return False, (
                    "notification permission was never granted at setup "
                    f"(stderr: {stderr_content.strip()})"
                )
            return False, f"the app wrote to stderr: {stderr_content.strip()}"

        answer = self.prompt(
            f"Did a Yellowhammer notification for Project {self.project} appear in Notification Center? [y/N] "
        )
        if (answer or "").strip().lower() != "y":
            return False, "the Operator did not confirm the notification appeared"
        return True, ""

    # -- check 3: launchd jobs --

    @staticmethod
    def _finished(parsed, before_runs):
        """True once the fired run has exited: `runs` passed the baseline and launchd holds no
        pid. A state other than `running` is not enough — launchd reports `xpcproxy` (and other
        transitional states) with a pid while the process is still starting."""
        return (parsed.get("runs") or 0) > before_runs and parsed.get("pid") is None and parsed.get("state") != "running"

    def _kickstart_and_wait(self, label, log, tag, on_poll=None):
        """Kickstarts `label` and polls `launchctl print` every 0.5s until it reports finished
        (state not `running` and `runs` incremented past the baseline) or `--act-timeout`
        elapses. Logs the baseline, one compact line per poll whose (pid, state, runs) differ
        from the previous poll, and the full output only once — when the wait ends, whichever
        way. `on_poll(parsed, elapsed)`, if given, runs every poll before the finished check; if
        it returns `(False, reason)` the wait aborts immediately with `reason`."""
        before_code, before_out, _before_err = self._launchctl_print(label)
        log.append(f"$ launchctl print gui/{self.uid}/{label} ({tag} baseline)\n{before_out}")
        if before_code != 0:
            return False, f"{label} not loaded before firing (exit {before_code})"
        before_runs = self._parse_launchctl(before_out).get("runs") or 0

        kickstart_code = self._kickstart(label)
        if kickstart_code != 0:
            return False, f"launchctl kickstart gui/{self.uid}/{label} exited {kickstart_code}"

        last_summary = None
        last_out = ""
        elapsed = 0.0
        while elapsed <= self.act_timeout:
            code, out, _err = self._launchctl_print(label)
            last_out = out
            if code != 0:
                log.append(f"$ launchctl print gui/{self.uid}/{label} ({tag} final, t={elapsed})\n{out}")
                return False, f"launchctl print gui/{self.uid}/{label} exited {code}"
            parsed = self._parse_launchctl(out)

            if on_poll is not None:
                hook_ok, hook_reason = on_poll(parsed, elapsed)
                if not hook_ok:
                    log.append(f"$ launchctl print gui/{self.uid}/{label} ({tag} final, t={elapsed})\n{out}")
                    return False, hook_reason

            summary = (parsed.get("pid"), parsed.get("state"), parsed.get("runs"))
            if summary != last_summary:
                log.append(f"launchctl print gui/{self.uid}/{label} ({tag} t={elapsed}): {self._summarize(parsed)}")
                last_summary = summary

            if self._finished(parsed, before_runs):
                log.append(f"$ launchctl print gui/{self.uid}/{label} ({tag} final, t={elapsed})\n{out}")
                if parsed.get("last_exit_code") != 0:
                    return False, f"{label} last exit code {parsed.get('last_exit_code')}"
                return True, ""
            self.sleep(0.5)
            elapsed += 0.5
        log.append(f"$ launchctl print gui/{self.uid}/{label} ({tag} final, timeout, t={elapsed})\n{last_out}")
        return False, f"{label} did not finish within {self.act_timeout}s ({tag})"

    def _fire_act_and_wait(self, label, log):
        sampled = {"comm": None}

        def on_poll(parsed, _elapsed):
            # Only once `running`: under `xpcproxy` the pid is launchd's spawn trampoline, not yet yh.
            if parsed.get("state") == "running" and parsed.get("pid") is not None and sampled["comm"] is None:
                _pcode, pout, _perr = self.run(["ps", "-o", "comm=", "-p", str(parsed["pid"])])
                sampled["comm"] = pout.strip()
            return True, ""

        ok, reason = self._kickstart_and_wait(label, log, "fire", on_poll=on_poll)
        if not ok:
            return False, reason

        if sampled["comm"]:
            if os.path.realpath(sampled["comm"]) != self.yh_realpath:
                return False, f"{label} ran {sampled['comm']}, not the installed yh"
        else:
            log.append(
                "process exited before ps could sample it; relying on launchd's loaded program path"
            )
        return True, ""

    def check_launchd(self, log):
        for act in ACTS:
            label = self._label(act)
            plist_path = self.home / "Library" / "LaunchAgents" / f"{label}.plist"
            if not plist_path.is_file():
                return False, f"missing LaunchAgent plist for {act}: {plist_path}"
            try:
                with open(plist_path, "rb") as handle:
                    plist = plistlib.load(handle)
            except Exception as error:  # noqa: BLE001
                return False, f"could not read {plist_path}: {error}"

            program_arguments = plist.get("ProgramArguments") or []
            if not program_arguments:
                return False, f"{label} plist has no ProgramArguments"
            if os.path.realpath(program_arguments[0]) != self.yh_realpath:
                return False, f"{label} ProgramArguments[0] is {program_arguments[0]!r}, not the installed yh"
            expected_rest = [act, "--project", self.project]
            if list(program_arguments[1:]) != expected_rest:
                return False, (
                    f"{label} ProgramArguments[1:] is {program_arguments[1:]!r}, expected {expected_rest!r}"
                )

            code, out, _err = self._launchctl_print(label)
            log.append(f"$ launchctl print gui/{self.uid}/{label}\n{out}")
            if code != 0:
                return False, f"{label} is not loaded (launchctl print exited {code})"
            loaded_program = self._parse_launchctl(out).get("program")
            if not loaded_program:
                return False, f"{label} launchctl print has no top-level 'program =' line"
            if os.path.realpath(loaded_program) != self.yh_realpath:
                return False, f"{label} is loaded with program {loaded_program!r}, not the installed yh"

        fire_label = self._label()
        ok, reason = self._fire_act_and_wait(fire_label, log)
        if not ok:
            return False, reason

        act_log_path = self.home / "Library" / "Logs" / "Yellowhammer" / f"{self.project}.{self.act}.log"
        if act_log_path.is_file():
            try:
                lines = act_log_path.read_text(errors="replace").splitlines()
                log.append("--- act log tail ---")
                log.extend(lines[-200:])
            except Exception:  # noqa: BLE001 - the log tail is best-effort evidence
                pass
        return True, ""

    # -- check 4: yh doctor --

    def check_doctor(self, log):
        label = self._label()
        plist_path = self.home / "Library" / "LaunchAgents" / f"{label}.plist"
        if not plist_path.is_file():
            return False, f"missing LaunchAgent plist: {plist_path}"
        try:
            with open(plist_path, "rb") as handle:
                plist = plistlib.load(handle)
        except Exception as error:  # noqa: BLE001
            return False, f"could not read {plist_path}: {error}"

        path_value = (plist.get("EnvironmentVariables") or {}).get("PATH")
        if not path_value:
            return False, f"{label} plist has no EnvironmentVariables.PATH"

        argv = [
            "env", "-i", f"HOME={self.home}", f"USER={self.user}", f"PATH={path_value}",
            str(self.yh_path), "doctor", "--probe", "--project", self.project,
        ]
        code, out, err = self.run(argv, timeout=300)
        log.append(f"$ {' '.join(argv)}\n{out}\n{err}")
        if code != 0:
            return False, f"yh doctor --probe exited {code}"

        lines = (out or "").splitlines()
        if not any(line.startswith("[pass] probes:") for line in lines):
            return False, "no '[pass] probes:' line in yh doctor output"
        if not any(
            line.startswith("[pass] linear:") and "Linear authorization succeeded" in line for line in lines
        ):
            return False, "no '[pass] linear: ... Linear authorization succeeded' line in yh doctor output"

        orca_path = shutil.which("orca", path=path_value)
        if not orca_path:
            return False, "orca not found on the LaunchAgent's PATH"
        code, out, err = self.run([orca_path, "--version"])
        log.append(f"$ {orca_path} --version\n{out}\n{err}")
        if code != 0:
            return False, f"orca --version exited {code}"
        orca_version = parse_version_output(out)
        if orca_version is None:
            return False, f"could not parse orca --version output: {out!r}"
        if version_tuple(orca_version) < version_tuple(self.min_orca_version):
            return False, f"orca {orca_version} is older than the minimum {self.min_orca_version}"

        config_path = self.home / ".config" / "yellowhammer" / "config.toml"
        if not config_path.is_file():
            return False, f"missing config: {config_path}"
        return True, ""

    # -- check 5: shell, not host --

    def _check_5a(self, log):
        if self._window_app_pid() is not None:
            return False, "the window app is already running; quit it before this check"
        label = self._label()

        def on_poll(_parsed, _elapsed):
            if self._window_app_pid() is not None:
                return False, "the window app appeared during an unattended Act"
            return True, ""

        return self._kickstart_and_wait(label, log, "5a", on_poll=on_poll)

    def _wait_post_resume(self, label, log, before_runs, tag):
        """After the Act is resumed (or was never paused), waits for it to finish and checks its
        exit code. Returns `(status, reason)` with `status` `"pass"` or `"fail"` (never
        `"retry"` — an Act that ran to completion is decisive either way)."""
        last_summary = None
        elapsed = 0.0
        while elapsed <= self.act_timeout:
            code, out, _err = self._launchctl_print(label)
            parsed = self._parse_launchctl(out)
            summary = (parsed.get("pid"), parsed.get("state"), parsed.get("runs"))
            if summary != last_summary:
                log.append(
                    f"launchctl print gui/{self.uid}/{label} ({tag} t={elapsed}): "
                    f"{self._summarize(parsed)}"
                )
                last_summary = summary
            if self._finished(parsed, before_runs):
                log.append(f"$ launchctl print gui/{self.uid}/{label} ({tag} final, t={elapsed})\n{out}")
                if parsed.get("last_exit_code") != 0:
                    return "fail", f"{label} last exit code {parsed.get('last_exit_code')}"
                return "pass", ""
            self.sleep(0.5)
            elapsed += 0.5
        return "fail", f"{label} did not finish within {self.act_timeout}s ({tag})"

    def _process_state(self, pid):
        """`ps` STAT for `pid` (`T` stopped, `Z` zombie, ...), or None when there is no such process."""
        code, out, _err = self.run(["ps", "-o", "stat=", "-p", str(pid)])
        state = (out or "").strip()
        return state if code == 0 and state else None

    def _run_5b_once(self, label, log):
        # A previous attempt may have left the app still quitting; `open -a` on an app that is
        # shutting down fails with LaunchServices error -600.
        elapsed = 0.0
        while self._window_app_pid() is not None:
            if elapsed >= 20.0:
                return "fail", "the window app from an earlier attempt never quit within 20s"
            self.sleep(0.5)
            elapsed += 0.5

        code, out, err = self.run(["open", "-a", str(self.app_path)])
        log.append(f"$ open -a {self.app_path}\n{out}\n{err}")
        if code != 0:
            return "fail", f"open -a {self.app_path} exited {code}"

        elapsed = 0.0
        while self._window_app_pid() is None:
            if elapsed >= 20.0:
                return "fail", "the window app never appeared within 20s"
            self.sleep(0.5)
            elapsed += 0.5

        before_code, before_out, _before_err = self._launchctl_print(label)
        log.append(f"$ launchctl print gui/{self.uid}/{label} (5b baseline)\n{before_out}")
        if before_code != 0:
            return "fail", f"{label} not loaded before firing (exit {before_code})"
        before_runs = self._parse_launchctl(before_out).get("runs") or 0

        kickstart_code = self._kickstart(label)
        if kickstart_code != 0:
            return "fail", f"launchctl kickstart gui/{self.uid}/{label} exited {kickstart_code}"

        # Poll fast for a *running* pid — the Act lives well under a second. `xpcproxy` reports a
        # pid too, but that pid is launchd's spawn trampoline, not yet yh (see `_fire_act_and_wait`).
        job_pid = None
        last_summary = None
        elapsed = 0.0
        while elapsed <= self.act_timeout:
            code, out, _err = self._launchctl_print(label)
            if code != 0:
                return "fail", f"launchctl print gui/{self.uid}/{label} exited {code}"
            parsed = self._parse_launchctl(out)
            summary = (parsed.get("pid"), parsed.get("state"), parsed.get("runs"))
            if summary != last_summary:
                log.append(
                    f"launchctl print gui/{self.uid}/{label} (5b waiting for running pid, t={elapsed}): "
                    f"{self._summarize(parsed)}"
                )
                last_summary = summary
            if self._finished(parsed, before_runs):
                log.append(f"$ launchctl print gui/{self.uid}/{label} (5b final, t={elapsed})\n{out}")
                return "retry", "the Act finished before it could be paused; inconclusive"
            if parsed.get("state") == "running" and parsed.get("pid") is not None:
                job_pid = parsed["pid"]
                log.append(f"$ launchctl print gui/{self.uid}/{label} (5b running pid found, t={elapsed})\n{out}")
                break
            self.sleep(PID_POLL_SECONDS)
            elapsed += PID_POLL_SECONDS
        if job_pid is None:
            return "fail", (
                f"{label} never reported a running pid or finished within {self.act_timeout}s"
            )

        # Pause the Act immediately, and always resume it before returning — a paused process
        # left behind would wedge every later attempt (and the real Project's schedule).
        try:
            self.signal(job_pid, signal.SIGSTOP)
        except ProcessLookupError:
            return "retry", "the Act exited before it could be paused; inconclusive"
        log.append(f"paused Act pid {job_pid}")
        paused_at = self.clock()

        try:
            # A job that exited just before SIGSTOP is a zombie until launchd reaps it, and both
            # SIGSTOP and kill(pid, 0) succeed on a zombie: require the Act to be really stopped.
            state = None
            for _ in range(20):
                state = self._process_state(job_pid)
                if state is None or state.startswith(("T", "Z")):
                    break
                self.sleep(PID_POLL_SECONDS)
            log.append(f"ps state of Act pid {job_pid} after SIGSTOP: {state}")
            if state is None or not state.startswith("T"):
                return "retry", "the Act exited before it could be paused; inconclusive"

            code, out, err = self.run(["osascript", "-e", 'tell application id "dev.yellowhammer" to quit'])
            log.append(f"$ osascript -e 'tell application id \"dev.yellowhammer\" to quit'\n{out}\n{err}")
            if code != 0:
                return "fail", (
                    f"osascript exited {code} trying to quit the app; the calling app (e.g. "
                    "Terminal) probably lacks Automation permission to control Yellowhammer — "
                    "grant it in System Settings → Privacy & Security → Automation "
                    f"(stderr: {err.strip()})"
                )

            quit_elapsed = 0.0
            while self._window_app_pid() is not None:
                if quit_elapsed >= PAUSE_QUIT_TIMEOUT_SECONDS:
                    return "retry", (
                        "the window app did not quit within "
                        f"{PAUSE_QUIT_TIMEOUT_SECONDS}s while the Act was paused"
                    )
                self.sleep(0.5)
                quit_elapsed += 0.5

            # The app is gone. The paused Act's pid must still be alive — a SIGSTOP'd process
            # cannot exit on its own, so if it's gone, quitting the app killed it: exactly the
            # defect this check exists to catch, and not a retryable inconclusive.
            state = self._process_state(job_pid)
            log.append(f"ps state of Act pid {job_pid} after the app quit: {state}")
            if state is None or not state.startswith("T"):
                return "fail", (
                    f"the Act (pid {job_pid}) was gone after the window app quit, while paused — "
                    f"quitting the app killed it (ps state {state})"
                )
        finally:
            try:
                self.signal(job_pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
            log.append(f"resumed Act pid {job_pid} (paused {self.clock() - paused_at:.1f}s)")

        return self._wait_post_resume(label, log, before_runs, "5b post-quit")

    def _check_5b(self, log):
        label = self._label()
        last_reason = "the Act finished before it could be paused; inconclusive"
        for _attempt in range(3):
            status, reason = self._run_5b_once(label, log)
            if status == "pass":
                return True, ""
            if status == "fail":
                return False, reason
            last_reason = reason
        return False, last_reason

    def check_shell_not_host(self, log):
        ok, reason = self._check_5a(log)
        if not ok:
            return False, f"5a (never opened): {reason}"
        ok, reason = self._check_5b(log)
        if not ok:
            return False, f"5b (quit mid-Act): {reason}"
        return True, ""

    # -- record --

    def record(self):
        self.evidence_directory.mkdir(parents=True, exist_ok=True)
        self.app_info = self._safe_app_info()
        self.yh_info = self._safe_yh_info()
        host_info = self._safe_host_info()

        checks_spec = [
            (1, "bare environment", self.check_bare_environment),
            (2, "headless notification", self.check_notification),
            (3, "launchd jobs", self.check_launchd),
            (4, "yh doctor", self.check_doctor),
            (5, "shell, not host", self.check_shell_not_host),
        ]
        results = []
        for check_id, name, check_fn in checks_spec:
            log_lines = []
            try:
                passed, reason = check_fn(log_lines)
            except Exception as error:  # noqa: BLE001 - a crashed check is recorded FAIL, not raised
                passed = False
                reason = f"{type(error).__name__}: {error}"
                log_lines.append(traceback.format_exc())
            log_text = "\n".join(log_lines)
            (self.evidence_directory / LOG_FILENAMES[check_id]).write_text(
                log_text + ("\n" if log_text else "")
            )
            results.append({"id": check_id, "name": name, "passed": bool(passed), "reason": reason or ""})
            status = "PASS" if passed else "FAIL"
            suffix = "" if passed else f": {reason}"
            print(f"{status} [{check_id}] {name}{suffix}")

        passed_all = all(result["passed"] for result in results)
        verdict = {
            "recorded_at": utc_now_iso(),
            "host": host_info,
            "app": {
                "path": str(self.app_path),
                "version": self.app_info.get("version"),
                "build": self.app_info.get("build"),
            },
            "yh": {
                "path": str(self.yh_path),
                "version": self.yh_info.get("version"),
                "build": self.yh_info.get("build"),
                "bundle_id": self.yh_info.get("bundle_id"),
            },
            "project": self.project,
            "checks": results,
            "passed": passed_all,
        }
        (self.evidence_directory / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
        return 0 if passed_all else 1


# MARK: - CLI


def record_command(args):
    verifier = Verifier(
        app=args.app,
        project=args.project,
        evidence_directory=args.evidence_directory,
        act=args.act,
        act_timeout=args.act_timeout,
    )
    return verifier.record()


def check_command(args):
    evidence_directory = args.evidence_directory.expanduser().resolve()
    verdict_path = evidence_directory / "verdict.json"
    if not verdict_path.is_file():
        print(f"verify_installed: no verdict.json in {evidence_directory}", file=sys.stderr)
        return 1

    try:
        verdict = json.loads(verdict_path.read_text())
    except json.JSONDecodeError as error:
        print(f"verify_installed: could not parse {verdict_path}: {error}", file=sys.stderr)
        return 1

    problems = []
    if not verdict.get("passed"):
        problems.append("verdict.json reports passed: false")

    checks = verdict.get("checks") or []
    failing = [check.get("id") for check in checks if not check.get("passed")]
    if len(checks) != TOTAL_CHECKS or failing:
        problems.append(f"not all {TOTAL_CHECKS} checks passed (ran {len(checks)}, failing {failing})")

    if args.version:
        app_version = (verdict.get("app") or {}).get("version")
        if app_version != args.version:
            problems.append(f"installed app version {app_version!r} does not match expected {args.version!r}")

    if problems:
        for problem in problems:
            print(f"verify_installed: {problem}", file=sys.stderr)
        return 1

    print(f"verify_installed: installed-product verification green for Project {verdict.get('project')!r}")
    return 0


def parse_arguments(argv):
    parser = argparse.ArgumentParser(prog="verify_installed.py", description=__doc__.split("\n\n")[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    record_parser = subparsers.add_parser("record", help="run the five checks and write evidence")
    record_parser.add_argument("--app", required=True, type=Path, help="the installed Yellowhammer.app")
    record_parser.add_argument("--project", required=True, help="the dedicated verification Project's id")
    record_parser.add_argument(
        "--evidence-directory", required=True, type=Path,
        help="where the per-check logs and verdict.json are written",
    )
    record_parser.add_argument(
        "--act", default="build", choices=ACTS, help="which Act's LaunchAgent to fire (default: build)"
    )
    record_parser.add_argument(
        "--act-timeout", type=float, default=600.0, help="seconds any single fired Act may take"
    )

    check_parser = subparsers.add_parser("check", help="exit 0 only if the evidence is a clean green")
    check_parser.add_argument(
        "--evidence-directory", required=True, type=Path, help="the directory `record` wrote to"
    )
    check_parser.add_argument(
        "--version", default=None, help="the marketing version the installed app must report"
    )

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv if argv is not None else sys.argv[1:])
    if args.command == "record":
        return record_command(args)
    return check_command(args)


if __name__ == "__main__":
    sys.exit(main())
