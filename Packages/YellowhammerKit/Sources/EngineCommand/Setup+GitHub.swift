import Config
import Domain
import Foundation

/// Where the GitHub step gets a token it does not find in the Keychain.
enum GitHubCapture: Equatable {
    /// Offer the GitHub CLI's token, else ask with hidden input.
    case interactive
    /// One line from standard input (`--token-stdin`).
    case standardInput
    /// `gh auth token` (`--from-gh`).
    case githubCLI
    /// Never capture: a missing or rejected token is an error (`--init`).
    case never
}

extension Setup {
    /// The GitHub step's credential half: reuses a stored token that GitHub accepts, otherwise captures one,
    /// authenticates it BEFORE storing, and stores it. Returns the GitHub user's login. The token is never
    /// printed, logged, put in an error or passed as a process argument; a rejected token is never stored.
    ///
    /// A stored token that resolves is reused without asking (`replace` forces a capture). A missing or
    /// rejected one is captured per `capture`; with `.never` it is an error carrying the report's message.
    func ensureGitHubCredential(
        reference: CredentialReference, capture: GitHubCapture, replace: Bool
    ) async throws -> String {
        if !replace {
            let report = await gitHub.report(
                reference: reference, secret: credentials.gitHubSecret(for: reference), repos: []
            )
            switch report.state {
            case .resolves:
                let login = report.login ?? ""
                output("GitHub credential \(reference.rawValue) is in the Keychain (GitHub user \(login))")
                return login
            case .unreadable, .unreachable:
                throw SetupError(report.message, gitHub: true)
            case .missing, .rejected:
                guard capture != .never else { throw SetupError(report.message, gitHub: true) }
                if report.state == .rejected {
                    output(report.message)
                    if capture == .interactive,
                       !(try confirm("Replace the stored GitHub token? [Y/n] ", defaultYes: true)) {
                        throw SetupError("setup was cancelled")
                    }
                }
            }
        }
        return try await captureGitHubToken(reference: reference, capture: capture)
    }

    /// The GitHub step's Repo half: checks the token can push to every Repo in `repos` (pass working Repos
    /// only — a `spec` role Repo is read-only). Throws one SetupError listing every failing Repo and the
    /// permission it lacks.
    func validateGitHubRepos(reference: CredentialReference, repos: [(name: String, path: String)]) async throws {
        guard !repos.isEmpty else { return }
        let report = await gitHub.report(
            reference: reference, secret: credentials.gitHubSecret(for: reference), repos: repos
        )
        guard report.state == .resolves else { throw SetupError(report.message, gitHub: true) }
        let failing = report.repos.filter { $0.status != .ok && $0.status != .okUnverified }
        guard failing.isEmpty else {
            throw SetupError(
                "GitHub credential \(reference.rawValue) cannot publish every Repo:\n"
                    + failing.map { "  " + $0.message }.joined(separator: "\n"),
                gitHub: true
            )
        }
        for repo in report.repos { output(repo.message) }
    }

    /// Before a Project file is written (and before any Linear write): the token of the Code Hosting
    /// Connection the Project selects must resolve and push to the declaration's working Repos.
    func validateGitHub(
        for declaration: ProjectDeclaration, machine: MachineConfiguration, connection: String
    ) async throws {
        guard !options.skipGitHubCheck else {
            output(
                "warning: the GitHub check was skipped (--skip-github-check): `land` cannot push or open pull "
                    + "requests for Project \(declaration.id.rawValue) until "
                    + "`yh setup --install-github --code-hosting-connection \(connection)` passes for its Repos; "
                    + "`yh doctor` reports it."
            )
            return
        }
        let reference = try codeHostingReference(of: connection, machine: machine)
        _ = try await ensureGitHubCredential(
            reference: reference, capture: isInteractive ? .interactive : .never, replace: false
        )
        let repos = declaration.repos.filter { $0.role != .spec }.map { gitHubRepo(name: $0.name, path: $0.path) }
        try await validateGitHubRepos(reference: reference, repos: repos)
    }

    /// The Keychain reference behind the Code Hosting Connection called `name`, through the one resolver; a
    /// refusal becomes a SetupError carrying its description.
    func codeHostingReference(of name: String, machine: MachineConfiguration) throws -> CredentialReference {
        do {
            return try machine.codeHostingCredential(connectionNamed: name).reference
        } catch {
            throw SetupError(error.description)
        }
    }

    /// Lets the Operator replace the selected connection's token after the interactive loop's GitHub failure.
    func offerGitHubReplacement(machine: MachineConfiguration, connection: String) async throws {
        guard try confirm("Replace the GitHub token and check again? [y/N] ", defaultYes: false) else { return }
        let reference = try codeHostingReference(of: connection, machine: machine)
        _ = try await ensureGitHubCredential(reference: reference, capture: .interactive, replace: true)
    }

    // MARK: Standalone modes

    /// `--install-github [--code-hosting-connection N]`: only the GitHub step, for the connection N (default
    /// `github`). A broken `config.toml` is refused before anything is captured and is never overwritten.
    /// A rejected token is never stored; N joins the registry only once its token is accepted. A stored
    /// token whose Repo validation then fails stays stored and the run fails naming each Repo.
    func installGitHub() async throws {
        let name = options.codeHostingConnection ?? CodeHostingConnection.defaultName
        let existing = try loadMachineFileForGitHubInstall()
        let entry = existing?.codeHostingConnection(named: name)
        let reference: CredentialReference
        switch entry?.kind {
        case .githubCLI:
            throw SetupError(CodeHostingRefusal.githubCLINotSupported(connection: name).description)
        case .keychainToken(let stored):
            reference = stored
        case nil:
            guard LinearInstallation.isValidLocalName(name) else {
                throw SetupError(Self.invalidConnectionNameMessage(name))
            }
            reference = CodeHostingConnection.defaultCredentialReference(for: name)
        }
        let capture: GitHubCapture = switch options.gitHubTokenSource {
        case .prompt: .interactive
        case .standardInput: .standardInput
        case .githubCLI: .githubCLI
        }
        _ = try await ensureGitHubCredential(
            reference: reference, capture: capture, replace: options.replaceGitHubToken
        )
        if entry == nil {
            try addCodeHostingConnection(CodeHostingConnection(name: name, kind: .keychainToken(reference)))
        }
        try await validateGitHubRepos(reference: reference, repos: standaloneGitHubRepos(connection: name))
        output("Code Hosting Connection \(name) is ready.")
    }

    /// The machine file when there is one; nil when there is none. A `config.toml` that does not load is an
    /// error, so the run never overwrites it.
    private func loadMachineFileForGitHubInstall() throws -> MachineConfiguration? {
        let path = machineFileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try MachineConfiguration.load(contentsOf: machineFileURL)
        } catch {
            throw SetupError("\(path) is invalid: \(error); fix or remove it, then run setup again")
        }
    }

    /// `--print-github [--code-hosting-connection N]`: never prompts, writes nothing, prints one line for the
    /// app to decode. An invalid report is still exit 0. A connection that is not in the registry, or is a
    /// `gh` CLI connection, reports `missing` whatever the Keychain holds.
    func printGitHub() async {
        let name = options.codeHostingConnection ?? CodeHostingConnection.defaultName
        let repos = options.gitHubRepoPaths.map { gitHubRepo(name: Self.repoName(ofPath: $0), path: $0) }
        let fallback = CodeHostingConnection.defaultCredentialReference(for: name)
        let machine = FileManager.default.fileExists(atPath: machineFileURL.path(percentEncoded: false))
            ? try? MachineConfiguration.load(contentsOf: machineFileURL) : nil
        guard let machine, machine.codeHostingConnection(named: name) != nil else {
            output(GitHubCredentialReport(
                reference: fallback.rawValue, state: .missing,
                message: "No Code Hosting Connection named \(name) is connected. Connect it with "
                    + "`yh setup --install-github --code-hosting-connection \(name)`."
            ).encodeLine())
            return
        }
        let credential: CodeHostingCredential
        do {
            credential = try machine.codeHostingCredential(connectionNamed: name)
        } catch {
            output(GitHubCredentialReport(
                reference: fallback.rawValue, state: .missing, message: error.description
            ).encodeLine())
            return
        }
        let report = await gitHub.report(
            reference: credential.reference, secret: credentials.gitHubSecret(for: credential.reference),
            repos: repos
        )
        output(report.encodeLine())
    }

    /// `--github-repo` paths, else the working Repos of every configured Project that selects `connection`.
    private func standaloneGitHubRepos(connection: String) -> [(name: String, path: String)] {
        if !options.gitHubRepoPaths.isEmpty {
            return options.gitHubRepoPaths.map { gitHubRepo(name: Self.repoName(ofPath: $0), path: $0) }
        }
        guard let configuration = try? Configuration.load(directory: configurationDirectory) else { return [] }
        return configuration.projects
            .filter { $0.codeHostingConnectionName == connection }
            .flatMap { project in
                project.repos.filter { $0.role != .spec }.map { gitHubRepo(name: $0.name, path: $0.path) }
            }
    }

    private static func repoName(ofPath path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func gitHubRepo(name: String, path: String) -> (name: String, path: String) {
        (name, Doctor.expandTilde(path, homeDirectory: homeDirectory.path(percentEncoded: false)))
    }

    // MARK: Capture

    private enum Authentication {
        case authenticated(login: String)
        case rejected
        case failed(String)
    }

    private func authenticate(_ token: String, reference: CredentialReference) async -> Authentication {
        let report = await gitHub.report(reference: reference, secret: .present(token), repos: [])
        switch report.state {
        case .resolves: return .authenticated(login: report.login ?? "")
        case .rejected: return .rejected
        case .missing, .unreadable, .unreachable: return .failed(report.message)
        }
    }

    private func captureGitHubToken(reference: CredentialReference, capture: GitHubCapture) async throws -> String {
        let token: String
        switch capture {
        case .never:
            throw SetupError("no GitHub token is available for \(reference.rawValue)", gitHub: true)
        case .standardInput:
            let line = console.ask("")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { throw SetupError("no GitHub token was read from standard input") }
            token = line
        case .githubCLI:
            switch await importGitHubToken() {
            case .token(let imported): token = imported
            case .unavailable(let reason):
                throw SetupError("could not import a token from the GitHub CLI: \(reason)")
            }
        case .interactive:
            return try await captureInteractively(reference: reference)
        }
        switch await authenticate(token, reference: reference) {
        case .authenticated(let login):
            try storeGitHubToken(token, reference: reference, login: login)
            return login
        case .rejected:
            throw SetupError(Self.rejectedMessage, gitHub: true)
        case .failed(let message):
            throw SetupError(message, gitHub: true)
        }
    }

    private static let rejectedMessage =
        "GitHub rejected that token: it is wrong, revoked or expired. It was not stored."

    /// Offers the GitHub CLI's token once, then asks with hidden input until GitHub accepts one. EOF cancels.
    private func captureInteractively(reference: CredentialReference) async throws -> String {
        var offerImport = true
        while true {
            var candidate: String?
            if offerImport, case .token(let imported) = await importGitHubToken(),
               try confirm("Use the token from the GitHub CLI (gh)? [Y/n] ", defaultYes: true) {
                candidate = imported
            }
            offerImport = false
            if candidate == nil {
                guard let line = console.askSecret("GitHub token (input hidden): ") else {
                    throw SetupError("setup was cancelled")
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                candidate = trimmed
            }
            guard let token = candidate else { continue }
            switch await authenticate(token, reference: reference) {
            case .authenticated(let login):
                try storeGitHubToken(token, reference: reference, login: login)
                return login
            case .rejected:
                output(Self.rejectedMessage)
            case .failed(let message):
                throw SetupError(message, gitHub: true)
            }
        }
    }

    private func storeGitHubToken(_ token: String, reference: CredentialReference, login: String) throws {
        do {
            try credentials.store(token, for: reference)
        } catch {
            throw SetupError("could not store the GitHub token for \(reference.rawValue) in the Keychain: \(error)")
        }
        let account = GitHubCredentialValidation.account(of: reference)
        output(
            "stored the GitHub token of \(login) in the Keychain (service \(KeychainCredentialStore.service), "
                + "account \(account)) as \(reference.rawValue)"
        )
        output(
            "Yellowhammer's yh reads it from launchd; if a different yh build reads it first, macOS may ask "
                + "once — choose Always Allow."
        )
    }

    /// A yes/no answer; an empty one takes the default and EOF cancels setup.
    private func confirm(_ prompt: String, defaultYes: Bool) throws -> Bool {
        guard let line = console.ask(prompt) else { throw SetupError("setup was cancelled") }
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": return defaultYes
        case "y", "yes": return true
        default: return false
        }
    }
}
