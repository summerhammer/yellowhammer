import Foundation

/// The stub `yh`'s GitHub answers, split from `EngineStub` to keep both under SwiftLint's length limits.
extension EngineStub {
    /// `yh setup --print-github`: one `GitHubCredentialReport` line. It resolves for user `octocat`, reporting
    /// every `--github-repo` path `ok`, unless `YH_STUB_GITHUB_MISSING` is set and the file
    /// `YH_STUB_GITHUB_STORED_MARKER` names does not exist yet (`--install-github` creates it): then the
    /// token is `missing`.
    static let printGitHubCase = """
          --print-github)
            repos=""
            github_prev=""
            for arg in "$@"; do
              if [ "$github_prev" = "--github-repo" ]; then
                repo_name=$(basename "$arg")
                entry='{"message":"Repo '"$repo_name"' (acme/'"$repo_name"'): the token can push.",'\
        '"name":"'"$repo_name"'","path":"'"$arg"'","slug":"acme/'"$repo_name"'","status":"ok"}'
                if [ -n "$repos" ]; then repos="$repos,$entry"; else repos="$entry"; fi
              fi
              github_prev="$arg"
            done
            if [ -n "$YH_STUB_GITHUB_MISSING" ] && [ ! -f "$YH_STUB_GITHUB_STORED_MARKER" ]; then
              echo '{"message":"No GitHub token is stored for keychain:github.",\
        "reference":"keychain:github","repos":[],"state":"missing"}'
            else
              echo '{"login":"octocat","message":"The token in keychain:github belongs to octocat.",\
        "reference":"keychain:github","repos":['"$repos"'],"state":"resolves"}'
            fi
            exit 0
            ;;

        """

    /// `yh setup --install-github`: drains the one stdin line (the token), appends the full argument vector to
    /// `YH_STUB_ARGV_LOG` when set (the token is never in it: it arrives only on stdin), creates
    /// `YH_STUB_GITHUB_STORED_MARKER` when set, and exits 0.
    static let installGitHubCase = """
          --install-github)
            read -r _
            if [ -n "$YH_STUB_ARGV_LOG" ]; then echo "$all_args" >> "$YH_STUB_ARGV_LOG"; fi
            if [ -n "$YH_STUB_GITHUB_STORED_MARKER" ]; then touch "$YH_STUB_GITHUB_STORED_MARKER"; fi
            echo "GitHub credential keychain:github is ready."
            exit 0
            ;;

        """
}
