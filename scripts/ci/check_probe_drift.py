#!/usr/bin/env python3
"""
Scheduled probe drift check (P7.5; spec R11, routing/add-an-agent-cli).

Re-runs agent CLI Probes, records results in the machine-wide Ledger, and checks for
regressions (drift) in:
  - argv (unattended dispatch)
  - output format (result file on clean exit)
  - session handling (session resumption)
  - process containment

Fails loudly (exit code 1) on any detected drift or probe failure before a release ships, and
always when a probe did not run at all (no `yh`, an uninstalled CLI, a timeout): a probe that
never ran is not a green.

`yh` is the `Engine` target of `Yellowhammer.xcodeproj`, not a Swift package product, so the
script runs the one embedded in a built app (`DEFAULT_ENGINE_BIN`) unless `--engine-bin` names
another.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Tuple

# Where `xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -derivedDataPath .build/app
# build` puts `yh`, relative to the repository root.
DEFAULT_ENGINE_BIN = ".build/app/Build/Products/Debug/Yellowhammer.app/Contents/MacOS/yh"

# One `yh probe <cli>` makes several real dispatches, each allowed 300 s by `CLIProbe`, so the
# per-CLI cap is far above that.
DEFAULT_TIMEOUT_SECONDS = 1800


class ProbeResultInfo(NamedTuple):
    cli: str
    cli_version: str
    adapter_version: str
    unattended_dispatch: str
    result_file: str
    process_containment: str
    session_resumption: str
    verdict: str
    reason: Optional[str]
    drift_message: Optional[str]
    regressions: List[str]
    eligibility: Optional[str]
    exit_code: int
    raw_output: str
    # `yh probe` prints a `verdict:` line only after a probe has run. Without one, the probe never
    # ran (no `yh`, an uninstalled CLI, a timeout) and nothing was checked.
    completed: bool


def parse_probe_output(output: str, exit_code: int = 0) -> ProbeResultInfo:
    """Parse stdout/stderr output from `yh probe <cli>` into structured ProbeResultInfo."""
    cli = ""
    cli_version = "unknown"
    adapter_version = "unknown"
    unattended_dispatch = "not_run"
    result_file = "not_run"
    process_containment = "not_run"
    session_resumption = "not_run"
    verdict = "failed" if exit_code != 0 else "unknown"
    reason = None
    drift_message = None
    regressions: List[str] = []
    eligibility = None
    completed = False

    for line in output.splitlines():
        trimmed = line.strip()
        if trimmed.startswith("cli:"):
            cli = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("cli version:"):
            cli_version = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("adapter version:"):
            adapter_version = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("unattended dispatch:"):
            unattended_dispatch = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("result file on clean exit:"):
            result_file = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("process containment:"):
            process_containment = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("session resumption:"):
            session_resumption = trimmed.split(":", 1)[1].strip()
        elif trimmed.startswith("verdict:"):
            verdict = trimmed.split(":", 1)[1].strip()
            completed = True
        elif trimmed.startswith("reason:"):
            reason = trimmed.split(":", 1)[1].strip()
        elif "drift since the previous probe" in trimmed:
            drift_message = trimmed
            match = re.search(r"drift since the previous probe [^:]+:\s*(.+)$", trimmed)
            if match:
                targets_str = match.group(1).strip()
                regressions = [t.strip() for t in targets_str.split(",") if t.strip()]
            else:
                regressions = ["unspecified regression"]
        elif "offered as a route target" in trimmed:
            eligibility = "offered"
        elif "excluded from routing:" in trimmed:
            eligibility = trimmed

    return ProbeResultInfo(
        cli=cli,
        cli_version=cli_version,
        adapter_version=adapter_version,
        unattended_dispatch=unattended_dispatch,
        result_file=result_file,
        process_containment=process_containment,
        session_resumption=session_resumption,
        verdict=verdict,
        reason=reason,
        drift_message=drift_message,
        regressions=regressions,
        eligibility=eligibility,
        exit_code=exit_code,
        raw_output=output,
        completed=completed,
    )


def run_probe_command(
    cli_name: str,
    engine_bin: Optional[str] = None,
    repo_root: Optional[Path] = None,
    extra_env: Optional[Dict[str, str]] = None,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
) -> Tuple[int, str]:
    """Execute `yh probe <cli>` and return (exit_code, combined_output)."""
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    if not engine_bin:
        engine_bin = str((repo_root or Path.cwd()) / DEFAULT_ENGINE_BIN)
        if not os.path.isfile(engine_bin):
            return 1, (
                f"Error: no `yh` at {engine_bin}. Build the app first, from the repository root:\n"
                "  xcodebuild -scheme Yellowhammer -derivedDataPath .build/app build\n"
                "or pass --engine-bin."
            )
    cmd = [engine_bin, "probe", cli_name]

    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as e:
        output = e.stdout if isinstance(e.stdout, str) else (e.stdout.decode() if e.stdout else "")
        return 1, f"Error: probe timed out after {timeout}s\n{output}"
    except Exception as e:
        return 1, f"Error executing probe: {e}"


def format_status_badge(status: str) -> str:
    """Format status with markdown indicators."""
    if status == "passed":
        return "PASS"
    elif status == "failed":
        return "FAIL"
    elif status == "not_run":
        return "NOT RUN"
    return status.upper()


def generate_markdown_summary(results: List[ProbeResultInfo]) -> str:
    """Generate markdown report for $GITHUB_STEP_SUMMARY."""
    lines = [
        "## Agent CLI Probe Drift Report",
        "",
        "| CLI | CLI Version | Adapter | Dispatch | Result File | Containment | Resumption | Verdict | Drift |",
        "| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |",
    ]

    for r in results:
        if not r.completed:
            lines.append(
                f"| `{r.cli or 'unknown'}` | | | | | | | **DID NOT RUN** | — |"
            )
            continue
        drift_str = "None"
        if r.drift_message:
            drift_str = f"**DRIFT:** {', '.join(r.regressions)}"

        lines.append(
            f"| `{r.cli or 'unknown'}` | `{r.cli_version}` | `{r.adapter_version}` | "
            f"{format_status_badge(r.unattended_dispatch)} | "
            f"{format_status_badge(r.result_file)} | "
            f"{format_status_badge(r.process_containment)} | "
            f"{format_status_badge(r.session_resumption)} | "
            f"**{format_status_badge(r.verdict)}** | "
            f"{drift_str} |"
        )

    lines.append("")
    has_drift = any(r.drift_message is not None for r in results)
    has_failure = any(r.completed and r.verdict == "failed" for r in results)
    not_run = [r.cli for r in results if not r.completed]

    if not_run:
        lines.append("> [!CAUTION]")
        lines.append(
            "> **Probe Did Not Run:** "
            + ", ".join(f"`{cli}`" for cli in not_run)
            + ". Nothing was checked for these CLIs; see the job log."
        )
        lines.append("")

    if has_drift:
        lines.append("> [!WARNING]")
        lines.append("> **Probe Drift Detected:** One or more agent CLIs regressed since the last recorded probe.")
    elif has_failure:
        lines.append("> [!NOTE]")
        lines.append("> **Probe Finding Failure:** One or more agent CLIs failed probe criteria, but no regression (drift) was detected.")
    elif not not_run:
        lines.append("> [!TIP]")
        lines.append("> **All Probes Healthy:** No probe regressions or failures detected.")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check for agent CLI probe drift (P7.5).")
    parser.add_argument(
        "--repo-root",
        type=str,
        default=os.getcwd(),
        help="Repository root directory",
    )
    parser.add_argument(
        "--clis",
        type=str,
        default="claude,codex",
        help="Comma-separated list of CLIs to probe (default: claude,codex)",
    )
    parser.add_argument(
        "--engine-bin",
        type=str,
        default=None,
        help=f"Path to the `yh` engine executable (default: <repo-root>/{DEFAULT_ENGINE_BIN})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"Seconds one `yh probe <cli>` may run before it counts as not run (default: {DEFAULT_TIMEOUT_SECONDS})",
    )
    parser.add_argument(
        "--summary-file",
        type=str,
        default=None,
        help="Path to write GitHub Actions step summary markdown",
    )
    parser.add_argument(
        "--fail-on-drift",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Exit with non-zero code on detected drift (default: on)",
    )
    parser.add_argument(
        "--fail-on-error",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Exit with non-zero code on a failed probe verdict even without drift (default: on)",
    )

    args = parser.parse_args()
    repo_root = Path(args.repo_root)
    cli_list = [c.strip() for c in args.clis.split(",") if c.strip()]
    if not cli_list:
        print("::error::No CLIs to probe: --clis is empty.", file=sys.stderr)
        return 1

    print(f"Checking probe drift for CLIs: {', '.join(cli_list)}")
    results: List[ProbeResultInfo] = []
    any_drift = False
    any_error = False
    any_not_run = False

    for cli in cli_list:
        print(f"\n--- Running probe for `{cli}` ---")
        exit_code, output = run_probe_command(
            cli_name=cli,
            engine_bin=args.engine_bin,
            repo_root=repo_root,
            timeout=args.timeout,
        )
        print(output)

        info = parse_probe_output(output, exit_code=exit_code)
        if not info.cli:
            info = info._replace(cli=cli)
        results.append(info)

        if not info.completed:
            any_not_run = True
            print(
                f"::error title=Probe Did Not Run [{cli}]::`yh probe {cli}` exited {exit_code} "
                "without a verdict; nothing was checked.",
                file=sys.stderr,
            )
        elif info.drift_message:
            any_drift = True
            regressions_text = ", ".join(info.regressions)
            print(
                f"::error title=Probe Drift Detected [{cli}]::CLI `{cli}` regressed on: {regressions_text}",
                file=sys.stderr,
            )
        elif info.verdict == "failed":
            any_error = True

    # Generate summary if requested
    if args.summary_file:
        summary_md = generate_markdown_summary(results)
        try:
            with open(args.summary_file, "a", encoding="utf-8") as f:
                f.write(summary_md + "\n")
        except Exception as e:
            print(f"Warning: could not write summary file {args.summary_file}: {e}", file=sys.stderr)

    if any_not_run:
        print("\n::error::Probe drift check failed: one or more probes did not run.", file=sys.stderr)
        return 1

    if any_drift and args.fail_on_drift:
        print("\n::error::Probe drift check failed: one or more CLIs regressed.", file=sys.stderr)
        return 1

    if any_error and args.fail_on_error:
        print("\n::error::Probe check failed: one or more CLIs failed.", file=sys.stderr)
        return 1

    print("\n✓ Probe drift check completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
