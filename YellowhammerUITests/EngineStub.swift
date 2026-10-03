import Foundation

/// The stub `yh` shell script the Setup wizard and Settings UI tests exec, shared so both test classes
/// drive the same `--print-choices`, `--init`, `--check` and `--install-linear` answers.
enum EngineStub {
    /// A `sh` script, read (never exec'd) by `/bin/sh`. `--print-choices` answers with a canned
    /// ``SetupChoices`` JSON line and nothing else, so the wizard's "last non-empty line" decode still
    /// works. `--init` first drains the stdin secret line, then echoes every argument as `argv: <arg>`
    /// and prints "Setup complete." Its only files are the `/tmp` markers, argv log and Project files the
    /// tests name.
    static func write(in directory: URL) throws -> URL {
        let script = "#!/bin/sh\nall_args=\"$*\"\nshift\ncase \"$1\" in\n"
            + printChoicesCase + initCase + checkCase + installLinearCase
            + "  *)\n    exit 1\n    ;;\nesac\n"
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }

    static let printChoicesCase = """
          --print-choices)
            echo '{"operatorCandidates":[{"id":"user-op","name":"operator","displayName":"Operator Person"}],\
        "configuredOperator":null,"teams":[{"id":"team-1","key":"ENG","name":"Engineering"}],\
        "linearProjects":[{"id":"proj-listed","name":"Acme Mobile","teamNames":["Engineering"]}],\
        "cliAdapters":["claude","codex"]}'
            exit 0
            ;;

        """

    /// When `YH_STUB_PROJECTS_DIR` names a directory, `--init` also writes a minimal Project file there,
    /// named by `--project`'s value, as the real `yh setup --init` writes `projects/<id>.toml`. The tests
    /// point the configuration's `projects` folder at that `/tmp` directory with a symlink, because the
    /// stub cannot write into the UI test runner's container.
    static let initCase = """
          --init)
            read -r _
            project_id=""
            previous=""
            for arg in "$@"; do
              echo "argv: $arg"
              if [ "$previous" = "--project" ]; then project_id="$arg"; fi
              previous="$arg"
            done
            if [ -n "$YH_STUB_PROJECTS_DIR" ] && [ -n "$project_id" ]; then
              mkdir -p "$YH_STUB_PROJECTS_DIR"
              project_file="$YH_STUB_PROJECTS_DIR/$project_id.toml"
              echo 'id = "'"$project_id"'"' > "$project_file"
              echo 'name = "'"$project_id"'"' >> "$project_file"
              echo 'linear_project = "proj-1"' >> "$project_file"
              echo 'spec_source = "/tmp/acme-spec"' >> "$project_file"
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
    /// Settings General pane run this on appearing.
    static let checkCase = """
          --check)
            installed=""
            if [ -f "$YH_STUB_INSTALLED_MARKER" ] || [ -n "$YH_STUB_LINEAR_INSTALLED" ]; then installed="1"; fi
            if [ -n "$YH_STUB_LINEAR_INSTALLED_ONCE" ] && [ ! -f "$YH_STUB_CHECKED_MARKER" ]; then
              touch "$YH_STUB_CHECKED_MARKER"
              installed="1"
            fi
            if [ -n "$installed" ]; then
              echo '[{"check":"linear","subject":"authorization","severity":"pass","message":"ok"}]'
            else
              echo '[{"check":"linear","subject":"installation","severity":"failure","message":"no pair"}]'
            fi
            exit 0
            ;;

        """

    /// `yh setup --install-linear --events json`: when `YH_STUB_ARGV_LOG` names a file, first appends the
    /// full argument vector (`setup --install-linear ...`) to it as one line, so a test can assert on what
    /// the app ran. Branches on `--remote` (roadmap P17.9). Without it,
    /// the first attempt reports every port busy when `YH_STUB_PORTS_BUSY_FIRST` is set (a Retry test);
    /// every later attempt installs. With it, the attempt fails with `relayUnreachable` when
    /// `YH_STUB_RELAY_UNREACHABLE` is set; otherwise it issues an approval link, waits, then installs.
    static let installLinearCase = """
          --install-linear)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            is_remote=""
            for arg in "$@"; do
              if [ "$arg" = "--remote" ]; then is_remote="1"; fi
            done
            if [ -n "$is_remote" ]; then
        \(remoteInstallBody)    fi
        \(localInstallBody)    ;;

        """

    /// Not a raw string: each `\\` here is one `\` in the emitted `.sh` file. The approval link's event
    /// is built with `printf '%s\n'`, which prints its argument verbatim (unlike `echo`, whose escape
    /// handling differs between shells), so `text` carries the two-character JSON escape `\n`. The
    /// `sleep` keeps the waiting phase on screen long enough for the test to read the link.
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
              sleep 4
              echo '{"event":"installed","workspaceName":"scratch"}'
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
            echo '{"event":"installed","workspaceName":"Acme"}'
            touch "$YH_STUB_INSTALLED_MARKER"
            exit 0

        """
}
