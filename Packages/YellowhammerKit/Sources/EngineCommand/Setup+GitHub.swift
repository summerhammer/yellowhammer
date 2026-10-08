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
        reference: CredentialReference, capture: GitHubCapture, replace: Bool, connectionName: String? = nil
    ) async throws -> String {
        if !replace {
            let report = await gitHub.report(
                reference: reference, secret: credentials.gitHubSecret(for: reference), repos: [],
                connectionName: connectionName
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
    func validateGitHubRepos(
        reference: CredentialReference, repos: [(name: String, path: String)], connectionName: String? = nil
    ) async throws {
        guard !repos.isEmpty else { return }
        let report = await gitHub.report(
            reference: reference, secret: credentials.gitHubSecret(for: reference), repos: repos,
            connectionName: connectionName
        )
        guard report.state == .resolves else { throw SetupError(report.message, gitHub: true) }
        try requirePublishable(report, credential: "GitHub credential \(reference.rawValue)")
    }

    /// Throws one SetupError listing every Repo `report` found the credential cannot publish; otherwise prints
    /// each Repo's verdict.
    private func requirePublishable(_ report: GitHubCredentialReport, credential: String) throws {
        let failing = report.repos.filter { $0.status != .ok && $0.status != .okUnverified }
        guard failing.isEmpty else {
            throw SetupError(
                "\(credential) cannot publish every Repo:\n"
                    + failing.map { "  " + $0.message }.joined(separator: "\n"),
                gitHub: true
            )
        }
        for repo in report.repos { output(repo.message) }
    }

    /// Before a Project file is written (and before any Linear write): the Code Hosting Connection the Project
    /// selects must resolve and push to the declaration's working Repos. A Keychain token is reused or
    /// captured; the GitHub CLI holds no token, so it is only asked who it is and what it can push to.
    func validateGitHub(
        for declaration: ProjectDeclaration, machine: MachineConfiguration, connection: String
    ) async throws {
        guard !options.skipGitHubCheck else {
            output(
                "warning: the GitHub check was skipped (--skip-github-check): `land` cannot push or open pull "
                    + "requests for Project \(declaration.id.rawValue) until "
                    + "`yh config check-code-hosting-credential --connection \(connection)` passes for its Repos; "
                    + "`yh doctor` reports it."
            )
            return
        }
        let repos = declaration.repos.filter { $0.role != .spec }.map { gitHubRepo(name: $0.name, path: $0.path) }
        switch try codeHostingCredential(of: connection, machine: machine) {
        case .keychainToken(_, let reference):
            _ = try await ensureGitHubCredential(
                reference: reference, capture: isInteractive ? .interactive : .never, replace: false,
                connectionName: connection
            )
            try await validateGitHubRepos(reference: reference, repos: repos, connectionName: connection)
        case .githubCLI(_, let executable):
            let report = await gitHub.reportGitHubCLI(executable: executable, repos: repos, connectionName: connection)
            guard report.state == .resolves else { throw SetupError(report.message, gitHub: true) }
            output(report.message)
            try requirePublishable(report, credential: "The gh CLI")
        }
    }

    /// What the Code Hosting Connection called `name` gives, through the one resolver; a refusal becomes a
    /// SetupError carrying its description.
    func codeHostingCredential(of name: String, machine: MachineConfiguration) throws -> CodeHostingCredential {
        do {
            return try machine.codeHostingCredential(connectionNamed: name)
        } catch {
            throw SetupError(error.description)
        }
    }

    /// Lets the Operator replace the selected connection's token after the interactive loop's GitHub failure.
    func offerGitHubReplacement(machine: MachineConfiguration, connection: String) async throws {
        switch try codeHostingCredential(of: connection, machine: machine) {
        case .githubCLI:
            // Yellowhammer never changes gh's login, so there is nothing to replace here.
            output(
                "Code Hosting Connection \(connection) uses the gh CLI, which holds the GitHub token; "
                    + "Yellowhammer holds none. Run `gh auth login` or `gh auth switch` yourself, then check again."
            )
        case .keychainToken(_, let reference):
            guard try confirm("Replace the GitHub token and check again? [y/N] ", defaultYes: false) else { return }
            _ = try await ensureGitHubCredential(reference: reference, capture: .interactive, replace: true)
        }
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
