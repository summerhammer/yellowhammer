import Foundation

// swiftlint:disable line_length

extension EngineStub {
    /// Registry report for the app. The fixture can leave the default connection absent until it is connected.
    static let printCodeHostingConnectionsCase = #"""
          print-code-hosting-connections)
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

    /// Drains the token from stdin, logs argv only, and creates the fixture's stored-token marker.
    static let connectCodeHostingCase = #"""
          connect-code-hosting|replace-code-hosting-token)
            read -r _
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_GITHUB_STORED_MARKER" ]; then touch "$YH_STUB_GITHUB_STORED_MARKER"; fi
            echo "Code Hosting Connection github is ready as GitHub user octocat."
            exit 0
            ;;

        """#

    static let printCodeHostingCases = printCodeHostingConnectionsCase + checkCodeHostingCredentialCase + connectCodeHostingCase
}

// swiftlint:enable line_length
