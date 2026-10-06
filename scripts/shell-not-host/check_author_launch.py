#!/usr/bin/env python3
"""Drive the real Author toolbar outside XCUITest and prove its detached launch survives app quit.

Uses a scratch configuration and a held shell stub, never the real engine or a Journal. This checks
the app's exact selected-Project argument vector, responsiveness and process independence only.
The terminal needs Accessibility permission to click the actual toolbar through System Events.
"""

import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from check_shell_not_host import (
    CLICK_SCRIPT, Harness, SetupFailed, launch_app, list_processes, pid_alive, quit_app, window_apps,
)

AUTHOR_CLICK_SCRIPT = CLICK_SCRIPT.replace(
    'if (wanted.startsWith("tab:")) {',
    'if (wanted.startsWith("text:")) {\n'
    '          if (e.role() === "AXStaticText" && e.value() === wanted.slice(5)) return e;\n'
    '        } else if (wanted.startsWith("tab:")) {',
)


STUB = r'''#!/bin/sh
set -eu
directory="$(dirname "$0")"
case "${1:-}" in
  doctor) printf '%s\n' '[]'; exit 0 ;;
  author) ;;
  *) exit 1 ;;
esac
printf '%s\n' "$@" >> "$directory/author.calls"
if ! mkdir "$directory/held" 2>/dev/null; then
  echo 'author stood down: another Act is running'
  exit 1
fi
trap 'rmdir "$directory/held"' EXIT
printf '%s\n' "$@" > "$directory/author.argv"
echo "$$" > "$directory/author.pid"
echo 'author stdout'
echo 'author stderr' >&2
while [ ! -f "$directory/release" ]; do sleep 0.1; done
echo 'author completed after app quit'
touch "$directory/completed"
'''

SELECT_SCRIPT = CLICK_SCRIPT.split("function run(argv)")[0] + '''
function run(argv) {
  const proc = Application("System Events").processes.whose({unixId: parseInt(argv[0])})[0];
  proc.frontmost = true;
  for (let i = 0; i < 120; i++) {
    try {
      const heading = find(proc, "pulse-heading");
      if (heading && heading.value() === "Bravo") return "Bravo selected";
      // Static text has no AXPress. Select its enclosing List row. AX references can be invalidated
      // by the first snapshot arriving, so reacquire them on every attempt.
      let row = find(proc, "sidebar-bravo");
      for (let depth = 0; row && depth < 5 && row.role() !== "AXRow"; depth++) {
        row = row.attributes.byName("AXParent").value();
      }
      if (row && row.role() === "AXRow") row.attributes.byName("AXSelected").value = true;
    } catch (error) {}
    delay(0.25);
  }
  throw new Error("Pulse did not scope to Bravo");
}
'''


def wait_for(path, timeout=30):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > deadline:
            raise SetupFailed(f"timed out waiting for {path}")
        time.sleep(0.1)


def click(pid, *identifiers):
    result = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", AUTHOR_CLICK_SCRIPT, str(pid), *identifiers],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SetupFailed("could not drive the toolbar: " + result.stderr.strip())


def select_bravo(pid):
    result = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", SELECT_SCRIPT, str(pid)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SetupFailed("could not select Bravo: " + result.stderr.strip())


def prepare(directory):
    configuration = directory / "config"
    projects = configuration / "projects"
    projects.mkdir(parents=True)
    (configuration / "config.toml").write_text('''
[board.linear.connections.acme]
credential = "keychain:linear"
workspace = "workspace-1"
yellowhammer_identity = "app-user-1"
[github]
credential = "keychain:github"
[cli.claude]
[[routing]]
route = "claude/sonnet"
''')
    for project in ("alpha", "bravo"):
        (projects / f"{project}.toml").write_text(f'''
id = "{project}"
name = "{project.title()}"
spec_source = "~/dev/spec"
[board.linear]
connection = "acme"
project = "{project.upper()}"
[[repos]]
name = "{project}"
path = "~/dev/{project}"
role = "backend"
check = "swift test"
''')
    stub = directory / "stub-author.sh"
    stub.write_text(STUB)
    return configuration, stub


def check(app, directory):
    if window_apps(list_processes()):
        raise SetupFailed("quit Yellowhammer before running this check")
    configuration, stub = prepare(directory)
    harness = Harness(app, configuration, stub, directory, 30)
    app_pid = launch_app(harness)
    try:
        # Bravo is not the default first Project: the action must follow the selected window scope.
        select_bravo(app_pid)
        click(app_pid, "toolbar-start-author")
        wait_for(directory / "author.pid")
        actual = (directory / "author.argv").read_text().splitlines()
        if actual != ["author", "--project", "bravo"]:
            raise SetupFailed(f"unexpected Author arguments: {actual!r}")
        child_pid = int((directory / "author.pid").read_text())
        # This click must succeed while Author is still held: the launch did not wait for completion.
        click(app_pid, "toolbar-reread")
        click(app_pid, "toolbar-start-author")
        deadline = time.monotonic() + 30
        while "author stood down" not in (directory / "bravo.author.log").read_text():
            if time.monotonic() > deadline:
                raise SetupFailed("the overlapping Author launch did not reach the stub")
            time.sleep(0.1)
        expected_calls = ["author", "--project", "bravo"] * 2
        if (directory / "author.calls").read_text().splitlines() != expected_calls:
            raise SetupFailed("overlapping Author launch had unexpected arguments")
        if (directory / "completed").exists():
            raise SetupFailed("the stub completed before the app was quit")
        quit_app(harness, app_pid)
        app_pid = None
        if not pid_alive(child_pid):
            raise SetupFailed("Author did not survive quitting the app")
        (directory / "release").touch()
        wait_for(directory / "completed")
        output = (directory / "bravo.author.log").read_text()
        for marker in ("author stdout", "author stderr", "author completed after app quit"):
            if marker not in output:
                raise SetupFailed(f"missing log output: {marker}")

        # A log that cannot be opened must fail synchronously and never start a third Author.
        log = directory / "bravo.author.log"
        log.rename(directory / "bravo.author.success.log")
        log.mkdir()
        app_pid = launch_app(harness)
        select_bravo(app_pid)
        click(app_pid, "toolbar-start-author", "wait:text:Author could not be launched", "action-button-1")
        if (directory / "author.calls").read_text().splitlines() != expected_calls:
            raise SetupFailed("Author started even though its log could not be opened")
        if list(configuration.glob("journals/*.db")):
            raise SetupFailed("the app wrote a Journal during the stub-backed Author launch")
    finally:
        (directory / "release").touch()
        if app_pid is not None and pid_alive(app_pid):
            quit_app(harness, app_pid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    arguments = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="yh-author-launch-"))
    print(f"Author launch evidence: {directory}", flush=True)
    try:
        app = arguments.app.resolve()
        if not (app / "Contents" / "MacOS" / "Yellowhammer").is_file():
            raise SetupFailed(f"not a built Yellowhammer.app: {app}")
        check(app, directory)
    except (SetupFailed, OSError, subprocess.CalledProcessError) as error:
        print(f"Author launch FAILED: {error}", file=sys.stderr)
        return 1
    print("PASSED: selected argv, overlapping launch, responsive app, quit survival, logs, launch error")
    return 0


if __name__ == "__main__":
    sys.exit(main())
