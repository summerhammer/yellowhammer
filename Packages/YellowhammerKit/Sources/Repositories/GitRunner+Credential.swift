import Foundation

extension GitRunner {
    /// A runner for git commands that talk to GitHub (push, fetch): this runner's environment plus a
    /// disabled terminal prompt and askpass, and, when a credential is given, config injected purely
    /// through the environment (`GIT_CONFIG_COUNT`/`_KEY_n`/`_VALUE_n`) so no credential appears in
    /// `ps`/process arguments. When the command targets `httpsURL`, the Operator's `insteadOf` rewrites
    /// are neutralized for that exact URL.
    public func authenticated(with credential: PushCredential?, httpsURL: String? = nil) -> GitRunner {
        var environment = self.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // An empty GIT_ASKPASS disables every askpass fallback (SSH_ASKPASS and core.askPass included),
        // so git can never ask another program for a credential beyond the one supplied here.
        environment["GIT_ASKPASS"] = ""

        if let credential {
            var configs = Self.configs(for: credential)
            if let httpsURL {
                configs += Self.urlRewriteOverrides(for: httpsURL)
            }
            environment["GIT_CONFIG_COUNT"] = "\(configs.count)"
            for (index, config) in configs.enumerated() {
                environment["GIT_CONFIG_KEY_\(index)"] = config.key
                environment["GIT_CONFIG_VALUE_\(index)"] = config.value
            }
        }

        return GitRunner(executablePath: executablePath, environment: environment)
    }

    /// The explicit HTTPS URL a credentialed command should target instead of `origin`: a connection's
    /// credential is git HTTP config, which git never applies over SSH, so an SSH GitHub `origin` would
    /// otherwise authenticate with the Operator's SSH key. Nil without a credential, or for an `origin`
    /// that is not on GitHub.
    func httpsURL(for credential: PushCredential?, in path: String) async -> String? {
        guard credential != nil else { return nil }
        return await GitHubRepositorySlugResolver(git: self).resolve(path: path)?.httpsURL
    }

    /// Config pairs that map `url` onto itself for fetch and push. Git applies the longest matching
    /// `insteadOf` prefix, so this beats an Operator's `url."git@github.com:".insteadOf = https://github.com/`
    /// and keeps the command on HTTPS.
    static func urlRewriteOverrides(for url: String) -> [(key: String, value: String)] {
        [
            (key: "url.\(url).insteadOf", value: url),
            (key: "url.\(url).pushInsteadOf", value: url)
        ]
    }

    /// The git config pairs for a credential. Both reset the inherited `credential.helper` list first.
    private static func configs(for credential: PushCredential) -> [(key: String, value: String)] {
        switch credential {
        case .token(let token):
            let basicCredential = Data("x-access-token:\(token.value)".utf8).base64EncodedString()
            return [
                (key: "credential.helper", value: ""),
                (key: "http.extraHeader", value: "Authorization: Basic \(basicCredential)")
            ]
        case .githubCLI(let executable):
            // A shell-run helper (leading `!`): the path is single-quoted, with `'` written as `'\''`.
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return [
                (key: "credential.helper", value: ""),
                (key: "credential.helper", value: "!\(quoted) auth git-credential")
            ]
        }
    }
}
