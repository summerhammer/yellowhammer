import Foundation

// swiftlint:disable line_length

extension EngineStub {
    /// Registry report for the app. When `YH_STUB_CODE_HOSTING_REPORT_FILE` names an existing file, its
    /// content (one JSON line) is the answer, read afresh on every run, so a test in the UI test runner's
    /// container can change the report mid-test. Otherwise the fixture can leave the default connection absent
    /// until it is connected.
    static let printCodeHostingConnectionsCase = #"""
          print-code-hosting-connections)
            if [ -n "$YH_STUB_CODE_HOSTING_REPORT_FILE" ] && [ -f "$YH_STUB_CODE_HOSTING_REPORT_FILE" ]; then
              cat "$YH_STUB_CODE_HOSTING_REPORT_FILE"
              exit 0
            fi
            if [ -n "$YH_STUB_GITHUB_MISSING" ] && [ ! -f "$YH_STUB_GITHUB_STORED_MARKER" ]; then
              echo '{"connections":[]}'
            else
              echo '{"connections":[{"name":"github","type":"keychain","identity":"octocat","state":"ok","projects":[]}]}'
            fi
            exit 0
            ;;

        """#

    /// Per-Repo credential report, using the same contract as the real command.
    static let checkCodeHostingCredentialCase = #"""
          check-code-hosting-credential)
            repos=""
            previous=""
            for arg in "$@"; do
              if [ "$previous" = "--github-repo" ]; then
                repo_name=$(basename "$arg")
                entry='{"message":"Repo '"$repo_name"' (acme/'"$repo_name"'): the token can push.","name":"'"$repo_name"'","path":"'"$arg"'","slug":"acme/'"$repo_name"'","status":"ok"}'
                if [ -n "$repos" ]; then repos="$repos,$entry"; else repos="$entry"; fi
              fi
              previous="$arg"
            done
            if [ -n "$YH_STUB_GITHUB_MISSING" ] && [ ! -f "$YH_STUB_GITHUB_STORED_MARKER" ]; then
              echo '{"message":"No GitHub token is stored for keychain:github.","reference":"keychain:github","repos":[],"state":"missing"}'
            else
              echo '{"login":"octocat","message":"The token in keychain:github belongs to octocat.","reference":"keychain:github","repos":['"$repos"'],"state":"resolves"}'
            fi
            exit 0
            ;;

        """#

    /// `yh config connect-code-hosting <name> ...` and `replace-code-hosting-token <name> ...`: drains the
    /// token from stdin and logs argv only (never the token). When `YH_STUB_CODE_HOSTING_REFUSAL` is set it
    /// echoes that text and exits 1. When `YH_STUB_CODE_HOSTING_GATES` is set it then waits on the
    /// `code-hosting` gate (``waitForGate``), so a test can first write the entry `yh` would add to
    /// `config.toml`. Then it creates the fixture's stored-token marker and prints the success line for `$2`.
    static let connectCodeHostingCase = #"""
          connect-code-hosting|replace-code-hosting-token)
            read -r _
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_CODE_HOSTING_REFUSAL" ]; then
              echo "$YH_STUB_CODE_HOSTING_REFUSAL"
              exit 1
            fi
            if [ -n "$YH_STUB_CODE_HOSTING_GATES" ]; then wait_for_gate code-hosting; fi
            if [ -n "$YH_STUB_GITHUB_STORED_MARKER" ]; then touch "$YH_STUB_GITHUB_STORED_MARKER"; fi
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
