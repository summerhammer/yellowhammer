import Foundation

/// The stub `yh` shell script the Setup wizard and Settings UI tests exec, shared so both test classes
/// drive the same `--print-choices`, `--init`, `--check`, `--install-linear`, `--print-github` and
/// `--install-github` answers.
enum EngineStub {
    /// A `sh` script, read (never exec'd) by `/bin/sh`. `--print-choices` answers with a canned
    /// ``SetupChoices`` JSON line and nothing else, so the wizard's "last non-empty line" decode still
    /// works. `--init` first drains the stdin secret line, then echoes every argument as `argv: <arg>`
    /// and prints "Setup complete." Its only files are the `/tmp` markers, argv log and Project files the
    /// tests name.
    static func write(in directory: URL) throws -> URL {
        let script = "#!/bin/sh\nall_args=\"$*\"\n" + waitForGate + "shift\ncase \"$1\" in\n"
            + printChoicesCase + initCase + checkCase + installLinearCase + printGitHubCase + installGitHubCase
            + operatorCase
            + removeInstallationCase + projectRemoveCase
            + "  *)\n    exit 1\n    ;;\nesac\n"
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }

    /// `wait_for_gate <name>`: when `YH_STUB_GATE_DIR` is set, waits (at most 30 s) until the file
    /// `$YH_STUB_GATE_DIR/<name>` exists. The gate directory is in the UI test runner's container, which the
    /// stub can read but not write: so a stub run that `yh` would end by editing `config.toml` (a connect,
    /// an Operator save) waits there while the test makes that edit itself, then opens the gate.
    static let waitForGate = """
    wait_for_gate() {
      [ -n "$YH_STUB_GATE_DIR" ] || return 1
      gate_waits=0
      while [ ! -e "$YH_STUB_GATE_DIR/$1" ] && [ "$gate_waits" -lt 300 ]; do
        sleep 0.1
        gate_waits=$((gate_waits + 1))
      done
      return 0
    }

    """

    /// When `YH_STUB_ARGV_LOG` names a file, the full argument vector (`setup --print-choices ...`, so a
    /// test can see `--board-connection <name>`) is appended to it as one line before the answer.
    static let printChoicesCase = """
          --print-choices)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            check=""
            prev=""
            for arg in "$@"; do
              if [ "$prev" = "--linear-project" ]; then
                case "$arg" in
                proj-not-found)
                  check=',"linearProjectCheck":{"id":"proj-not-found","status":"notFound","teamNames":[]}'
                  ;;
                proj-no-access)
                  check=',"linearProjectCheck":{"id":"proj-no-access","status":"noTeamAccess","teamNames":["Payments"]}'
                  ;;
                *)
                  check=',"linearProjectCheck":{"id":"'"$arg"'","name":"Billing Revamp",'\
        '"status":"found","teamNames":["Payments"]}'
                  ;;
                esac
              fi
              prev="$arg"
            done
            echo '{"operatorCandidates":[{"id":"user-op","name":"operator","displayName":"Operator Person"}],\
        "configuredOperator":null,"teams":[{"id":"team-1","key":"ENG","name":"Engineering"}],\
        "linearProjects":[{"id":"proj-listed","name":"Acme Mobile","teamNames":["Engineering"]}],\
        "cliAdapters":["claude","codex"]'"$check"'}'
            exit 0
            ;;

        """

    /// When `YH_STUB_PROJECTS_DIR` names a directory, `--init` also writes a minimal Project file there,
    /// named by `--project`'s value (its `installation` is the value after `--board-connection`, else `acme`), as the real `yh setup --init` writes `projects/<id>.toml`. The tests
    /// point the configuration's `projects` folder at that `/tmp` directory with a symlink, because the
    /// stub cannot write into the UI test runner's container.
    static let initCase = """
          --init)
            read -r _
            project_id=""
            init_installation="acme"
            init_code_hosting=""
            previous=""
            for arg in "$@"; do
              echo "argv: $arg"
              if [ "$previous" = "--project" ]; then project_id="$arg"; fi
              if [ "$previous" = "--board-connection" ]; then init_installation="$arg"; fi
              if [ "$previous" = "--code-hosting-connection" ]; then init_code_hosting="$arg"; fi
              previous="$arg"
            done
            if [ -n "$YH_STUB_PROJECTS_DIR" ] && [ -n "$project_id" ]; then
              mkdir -p "$YH_STUB_PROJECTS_DIR"
              project_file="$YH_STUB_PROJECTS_DIR/$project_id.toml"
              echo 'id = "'"$project_id"'"' > "$project_file"
              echo 'name = "'"$project_id"'"' >> "$project_file"
              echo 'spec_source = "/tmp/acme-spec"' >> "$project_file"
              echo '[board.linear]' >> "$project_file"
              echo 'connection = "'"$init_installation"'"' >> "$project_file"
              echo 'project = "proj-1"' >> "$project_file"
              echo '[code_hosting]' >> "$project_file"
              echo 'connection = "'"$init_code_hosting"'"' >> "$project_file"
              echo '[[repos]]' >> "$project_file"
              echo 'name = "backend"' >> "$project_file"
              echo 'path = "/tmp/acme-backend"' >> "$project_file"
              echo 'role = "backend"' >> "$project_file"
              echo 'check = "none"' >> "$project_file"
            fi
            echo "Setup complete."
            exit 0
            ;;

        """

    /// `yh doctor --check linear --json`: "installed" once the install marker exists or when
    /// `YH_STUB_LINEAR_INSTALLED` is set, else "not installed". When `YH_STUB_LINEAR_INSTALLED_ONCE` is set,
    /// the first check also reports "installed" and touches `YH_STUB_CHECKED_MARKER`, so later checks see a
    /// revoked installation until an install touches the install marker. The Add Project sheet and the
    /// Settings General pane run this on appearing. When `YH_STUB_DOCTOR_ROWS` is set (non-empty), its value
    /// is echoed verbatim as the single output line, before any other logic, so a test can supply
    /// per-installation rows carrying `installation`, `workspaceName` and `projects`.
    static let checkCase = """
          --check)
            if [ -n "$YH_STUB_DOCTOR_ROWS" ]; then
              echo "$YH_STUB_DOCTOR_ROWS"
              exit 0
            fi
            installed=""
            if [ -f "$YH_STUB_INSTALLED_MARKER" ] || [ -n "$YH_STUB_LINEAR_INSTALLED" ]; then installed="1"; fi
            if [ -n "$YH_STUB_LINEAR_INSTALLED_ONCE" ] && [ ! -f "$YH_STUB_CHECKED_MARKER" ]; then
              touch "$YH_STUB_CHECKED_MARKER"
              installed="1"
            fi
            if [ -n "$installed" ]; then
              echo '[{"check":"linear","subject":"authorization","severity":"pass","message":"ok"}]'
            else
              echo '[{"check":"linear","subject":"connection","severity":"failure","message":"no pair"}]'
            fi
            exit 0
            ;;

        """

    /// `yh setup --install-linear --events json`: when `YH_STUB_ARGV_LOG` names a file, first appends the
    /// full argument vector (`setup --install-linear ...`) to it as one line, so a test can assert on what
    /// the app ran. Branches on `--remote` (roadmap P17.9). The `installed` event carries `installation`:
    /// the value after `--board-connection` when passed, else `YH_STUB_CONNECT_NAME` when set, else `acme`
    /// locally and `scratch` remotely. Just before `installed`, the attempt waits on the `install` gate
    /// (``waitForGate``), so a test can first write the entry `yh` would add to `config.toml`. Without
    /// `--remote`, the first attempt reports every port busy when `YH_STUB_PORTS_BUSY_FIRST` is set (a Retry
    /// test); every later attempt installs. With it, the attempt fails with `relayUnreachable` when
    /// `YH_STUB_RELAY_UNREACHABLE` is set; otherwise it issues an approval link, waits, then installs.
    static let installLinearCase = """
          --install-linear)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            is_remote=""
            install_name=""
            install_prev=""
            for arg in "$@"; do
              if [ "$arg" = "--remote" ]; then is_remote="1"; fi
              if [ "$install_prev" = "--board-connection" ]; then install_name="$arg"; fi
              install_prev="$arg"
            done
            [ -n "$install_name" ] || install_name="$YH_STUB_CONNECT_NAME"
            if [ -n "$is_remote" ]; then
        \(remoteInstallBody)    fi
        \(localInstallBody)    ;;

        """

    /// Not a raw string: each `\\` here is one `\` in the emitted `.sh` file. The approval link's event
    /// is built with `printf '%s\n'`, which prints its argument verbatim (unlike `echo`, whose escape
    /// handling differs between shells), so `text` carries the two-character JSON escape `\n`. The
    /// gate (or, without one, the `sleep`) keeps the waiting phase on screen long enough for the test to
    /// read the link.
    static let remoteInstallBody = """
              echo '{"event":"adminStatement","text":"An admin must approve."}'
              if [ -n "$YH_STUB_RELAY_UNREACHABLE" ]; then
                echo '{"event":"failed","reason":"relayUnreachable","text":"could not reach the relay"}'
                exit 1
              fi
              link='https://app.yellowhammer.dev/install/test-session'
              text='Send this link to a Linear workspace admin. It is valid for 15 minutes:\\n'"$link"
              head='{"event":"approvalLinkIssued","url":"'"$link"'","expiresIn":900'
              printf '%s\\n' "$head"',"text":"'"$text"'"}'
              echo '{"event":"awaitingRemoteApproval"}'
              wait_for_gate install || sleep 4
              [ -n "$install_name" ] || install_name="scratch"
              echo '{"event":"installed","workspaceName":"scratch","installation":"'"$install_name"'"}'
              touch "$YH_STUB_INSTALLED_MARKER"
              exit 0

        """

    static let localInstallBody = """
            count_file="$YH_STUB_ATTEMPTS_MARKER"
            count=0
            [ -f "$count_file" ] && count=$(cat "$count_file")
            count=$((count + 1))
            echo "$count" > "$count_file"
            echo '{"event":"adminStatement","text":"An admin must approve."}'
            if [ "$count" -eq 1 ] && [ -n "$YH_STUB_PORTS_BUSY_FIRST" ]; then
              echo '{"event":"portsBusy","ports":[{"port":44837,"pid":123,"command":"Fugu"}],"text":"all busy"}'
              echo '{"event":"failed","reason":"portsBusy","text":"all busy"}'
              exit 1
            fi
            echo '{"event":"browserOpened","url":"https://linear.app/oauth/authorize"}'
            echo '{"event":"awaitingApproval"}'
            wait_for_gate install
            [ -n "$install_name" ] || install_name="acme"
            echo '{"event":"installed","workspaceName":"Acme","installation":"'"$install_name"'"}'
            touch "$YH_STUB_INSTALLED_MARKER"
            exit 0

        """

    /// `yh config operator [--board-connection <name>] <user-id>`: appends the full argument vector to
    /// `YH_STUB_ARGV_LOG` when set, waits on the `operator` gate (``waitForGate``) so a test can first write
    /// the identity to `config.toml`, then prints the real command's success lines and exits 0. When
    /// `YH_STUB_OPERATOR_REFUSAL` is set it echoes that text and exits 1 instead.
    static let operatorCase = """
          operator)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_OPERATOR_REFUSAL" ]; then
              echo "$YH_STUB_OPERATOR_REFUSAL"
              exit 1
            fi
            operator_installation=""
            operator_id=""
            operator_prev=""
            for arg in "$@"; do
              if [ "$operator_prev" = "--board-connection" ]; then operator_installation="$arg"; fi
              operator_id="$arg"
              operator_prev="$arg"
            done
            wait_for_gate operator
            echo "Board Connection $operator_installation: Operator identity is now $operator_id"
            echo "The change applies from the next Act; it does not reassign issues already in Waiting on You."
            exit 0
            ;;

        """

    /// `yh config remove-board-connection <name>`: appends the full argument vector to `YH_STUB_ARGV_LOG` when
    /// set. `YH_STUB_INSTALLATION_USERS` holds space-separated `name=project` pairs; when a pair's name
    /// equals the argument, prints the real refusal (Projects joined with ", ") and exits 1. Otherwise prints
    /// the real two success lines and exits 0.
    static let removeInstallationCase = """
          remove-board-connection)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            removal_users=""
            for pair in $YH_STUB_INSTALLATION_USERS; do
              if [ "${pair%%=*}" = "$2" ]; then
                removal_users="${removal_users:+$removal_users, }${pair#*=}"
              fi
            done
            if [ -n "$removal_users" ]; then
              removal_name="Board Connection \\"$2\\" was not removed: Project $removal_users"
              removal_name="$removal_name uses Board Connection \\"$2\\"; remove it first:"
              echo "$removal_name yh project remove $removal_users"
              exit 1
            fi
            echo "Board Connection $2 removed: its entry in config.toml and its Keychain items."
            echo "Yellowhammer stays installed in that Linear workspace until a workspace admin removes it" \\
              "in Linear's settings."
            exit 0
            ;;

        """

    /// `yh project remove <id> --yes` (the leading `shift` has already dropped `project`, so the case is
    /// `remove` and the id is `$2`): appends the full argument vector to `YH_STUB_ARGV_LOG` when set. When
    /// `YH_STUB_PROJECT_REMOVE_REFUSE` is set, prints the real refusal for a held Act Lease and exits 1.
    /// Otherwise prints a progress line, waits on the `project-removed` gate (``waitForGate``) so the test
    /// can first delete `projects/<id>.toml`, as the real `yh` does, then prints the real summary line and
    /// exits 0.
    static let projectRemoveCase = """
          remove)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_PROJECT_REMOVE_REFUSE" ]; then
              echo "refused: build run run-1 holds $2's Act lease until 2026-10-05 12:00:00 +0000"
              exit 1
            fi
            echo "unloading the LaunchAgents of Project $2"
            wait_for_gate project-removed
            echo "Project $2 removed. Its Journal was kept."
            exit 0
            ;;

        """
}
