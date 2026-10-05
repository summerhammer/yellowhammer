# Shell-not-host verification (P14.9)

The app is a shell around the Acts, never their host: a Night must run correctly with the app
never opened, and with it quit mid-Shift (`../yellowhammer-spec/docs/tech/system-overview.md` →
Yellowhammer app). `check_shell_not_host.py` checks that with two rehearsal Nights:

| Night | How it runs | What must hold |
| --- | --- | --- |
| **never-opened** (Project A) | `Yellowhammer.app/Contents/MacOS/yh rehearse --project A`, run directly, the way a LaunchAgent fires an Act | The window app is not running at any point (the app's headless `--post-notification` launches do not count) |
| **quit-mid-act** (Project B) | The app is launched, Recalibrate → Run a Rehearsal Night is clicked, and the app is quit while an Act holds Project B's Act lease | The `yh rehearse` process outlives the app |

Both Nights must then finish their land Act, and their Journals and Night Cards must be
equivalent. The Night Card is compared as the Engine wrote it: each `night` row and every Outbox
write to its `night_card_issue_id`. The whole Journal is compared table by table. Values that
necessarily differ between two Projects are normalised first: the Project id, name and Linear
project, Repo and Spec Source paths, timestamps, and generated identifiers (UUIDs, issue keys,
commit SHAs, URLs), which become `<kind-N>` in order of first appearance.

## Live run

It needs a built app and two **fresh** rehearsal Projects in `~/.config/yellowhammer` — each with
its own scratch Linear project and throwaway Repos (Rehearsal environment, P15.1–P15.2), seeded
identically, with no Journal yet and no LaunchAgents installed. It drives the app through System
Events, so the terminal running it needs Accessibility permission.

```sh
xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -derivedDataPath .build/app build
python3 scripts/shell-not-host/check_shell_not_host.py \
    --app .build/app/Build/Products/Debug/Yellowhammer.app \
    --never-opened shell-a --quit-mid-act shell-b
```

Logs, Journal snapshots and both normalised dumps are left in the work directory it prints
(`--work-directory` to choose one). On a difference it prints a unified diff and exits 1; exit 2
means the check could not be set up.

## Harness self-test

`--engine-stub scripts/shell-not-host/stub-yh.sh` swaps `yh` for a shell stub (the app's
`-YellowhammerEngineStub` seam) that writes a minimal Journal with a held Act lease per Act. It
needs a scratch configuration directory holding `config.toml` and the two Projects' files, and no
Linear. It proves the harness and the app's detached launch, never the Engine.

```sh
python3 scripts/shell-not-host/check_shell_not_host.py \
    --app .build/app/Build/Products/Debug/Yellowhammer.app \
    --never-opened alpha --quit-mid-act bravo \
    --configuration-directory /tmp/yh-shell-config \
    --engine-stub scripts/shell-not-host/stub-yh.sh
```

Unit tests: `python3 -m unittest discover -s scripts/shell-not-host/tests -v`.

This is not a UI test on purpose: under `xcodebuild test`, `testmanagerd` reaps a process the app
spawns detached within about a second, whether or not the app quits (see `RecalibrateUITests`).

## On-demand Author launch (#317)

The selected Project's **Start Author** toolbar button launches `yh author --project <id>` and
returns immediately. The CLI owns lease contention: if another Act holds the lease, Author stands
down normally. The app retains only synchronous launch errors; it tracks no running or completed
state. Output appends to `~/Library/Logs/Yellowhammer/<id>.author.log`, the scheduled Author log.

`check_author_launch.py` drives that real toolbar through System Events, using a scratch configuration
with two Projects and a held shell stub. It selects the second Project, checks the exact argv, clicks
Re-read and Author again while the child is held (the stub stands down), quits the app, then releases
the child and checks its completion and merged stdout/stderr log. It also makes the log unwritable and
checks that the app shows its launch failure without starting another child. It needs Accessibility
permission and the app quit before starting. Actual lease behavior remains covered by
`SingleWriterTests.overlappingActStandsDown`; the stub checks only that the app permits another launch.

```sh
python3 scripts/shell-not-host/check_author_launch.py \
    --app build/DerivedData/Build/Products/Debug/Yellowhammer.app
```

The script leaves its scratch directory and evidence paths in its output. It proves the app's
detachment and scope, without invoking the real Author or asserting model-authored engine work.
