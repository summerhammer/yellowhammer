import Foundation

// swiftlint:disable line_length

extension EngineStub {
    /// Registry report for the app. When `YH_STUB_CODE_HOSTING_REPORT_FILE` names an existing file, its
    /// content (one JSON line) is the answer, read afresh on every run, so a test in the UI test runner's
    /// container can change the report mid-test. Otherwise it returns the default connection.
    static let printCodeHostingConnectionsCase = #"""
          print-code-hosting-connections)
            if [ -n "$YH_STUB_CODE_HOSTING_REPORT_FILE" ] && [ -f "$YH_STUB_CODE_HOSTING_REPORT_FILE" ]; then
              cat "$YH_STUB_CODE_HOSTING_REPORT_FILE"
              exit 0
            fi
            echo '{"connections":[{"name":"github","type":"keychain","identity":"octocat","state":"ok","projects":[]}],"githubCLI":{"available":true,"login":"octocat"}}'
            exit 0
            ;;

        """#

    /// The current selected-connection check, with a configurable refusal for one working Repo.
    static let checkCodeHostingCredentialCase = #"""
          check-code-hosting-credential)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            repos=""
            refused_repo="$YH_STUB_CODE_HOSTING_REFUSED_REPO"
            if [ -n "$YH_STUB_CODE_HOSTING_REFUSED_REPO_FILE" ]; then
              refused_repo=""
              if [ -f "$YH_STUB_CODE_HOSTING_REFUSED_REPO_FILE" ]; then
                refused_repo=$(cat "$YH_STUB_CODE_HOSTING_REFUSED_REPO_FILE")
              fi
            fi
            connection="github"
            previous=""
            for arg in "$@"; do
              if [ "$previous" = "--connection" ]; then connection="$arg"; fi
              if [ "$previous" = "--github-repo" ]; then
                repo_name=$(basename "$arg")
                status="ok"
                message="the token can push."
                if [ "$arg" = "$refused_repo" ]; then
                  status="noPushPermission"
                  message="GitHub refused push permission."
                fi
                entry='{"message":"Repo '"$repo_name"' (acme/'"$repo_name"'): '"$message"'","name":"'"$repo_name"'","path":"'"$arg"'","slug":"acme/'"$repo_name"'","status":"'"$status"'"}'
                if [ -n "$repos" ]; then repos="$repos,$entry"; else repos="$entry"; fi
              fi
              previous="$arg"
            done
            echo '{"login":"octocat","message":"Code Hosting Connection '"$connection"' belongs to octocat.","reference":"keychain:'"$connection"'","repos":['"$repos"'],"state":"resolves"}'
            exit 0
            ;;

        """#

    /// `yh config connect-code-hosting <name> ...` and `replace-code-hosting-token <name> ...`: drains the
    /// token from stdin and logs argv only (never the token). When `YH_STUB_CODE_HOSTING_REFUSAL` is set it
    /// echoes that text and exits 1. When `YH_STUB_CODE_HOSTING_GATES` is set it then waits on the
    /// `code-hosting` gate (``waitForGate``), so a test can first write the entry `yh` would add to
    /// `config.toml`. Then it prints the success line for `$2`.
    static let connectCodeHostingCase = #"""
          connect-code-hosting|replace-code-hosting-token)
            read -r _
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_CODE_HOSTING_REFUSAL" ]; then
              echo "$YH_STUB_CODE_HOSTING_REFUSAL"
              exit 1
            fi
            if [ -n "$YH_STUB_CODE_HOSTING_GATES" ]; then wait_for_gate code-hosting; fi
            echo "Code Hosting Connection $2 is ready as GitHub user octocat."
            exit 0
            ;;

        """#

    /// `yh config remove-code-hosting-connection <name>` (the leading `shift` has dropped `config`): logs argv
    /// when `YH_STUB_ARGV_LOG` is set. When `YH_STUB_CODE_HOSTING_REMOVE_REFUSE` is set it echoes that text and
    /// exits 1. When `YH_STUB_CODE_HOSTING_GATES` is set it waits on the `code-hosting-removed` gate
    /// (``waitForGate``), so a test can first remove the entry from `config.toml`. Then it prints the success
    /// line and exits 0.
    static let removeCodeHostingConnectionCase = #"""
          remove-code-hosting-connection)
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_CODE_HOSTING_REMOVE_REFUSE" ]; then
              echo "$YH_STUB_CODE_HOSTING_REMOVE_REFUSE"
              exit 1
            fi
            if [ -n "$YH_STUB_CODE_HOSTING_GATES" ]; then wait_for_gate code-hosting-removed; fi
            echo "Code Hosting Connection $2 removed."
            exit 0
            ;;

        """#

    static let printCodeHostingCases = printCodeHostingConnectionsCase + checkCodeHostingCredentialCase
        + connectCodeHostingCase + removeCodeHostingConnectionCase
}

// swiftlint:enable line_length
