import Domain
import SwiftUI

/// The GitHub credential: whether a token is stored and accepted, what it can push to, and where to put a
/// new one. The Setup wizard's GitHub step draws it, driven by ``GitHubCredentialModel``. The wording of every
/// failure is `yh`'s own (``GitHubCredentialReport/message``); the app adds only the labels around it. The
/// token is typed into a secure field, handed to `yh` over standard input, and the field is emptied the moment
/// the run starts.
struct GitHubCredentialView: View {
    let model: GitHubCredentialModel
    /// The working Repo paths the token is checked against.
    var repoPaths: [String] = []
    @State private var token = ""
    @State private var isReplacing = false

    var body: some View {
        WizardBlock(title: "GitHub token", footer: Self.footer) {
            VStack(alignment: .leading, spacing: 0) {
                stateRow
                ForEach(repos, id: \.name) { repo in
                    Divider()
                    repoRow(repo)
                }
                if showsCapture {
                    Divider()
                    captureRow
                }
                if let failure = model.storeFailure {
                    Divider()
                    failureRow(failure)
                }
            }
        }
    }

    static let footer = "The token is stored in the login Keychain (service dev.yellowhammer) and never in a "
        + "file. It needs push access and pull request write on every working Repo; for a classic token, the "
        + "repo scope."

    // MARK: State

    private var report: GitHubCredentialReport? {
        if case .checked(let report) = model.state { return report }
        return nil
    }

    private var repos: [GitHubCredentialReport.Repo] {
        report?.repos ?? []
    }

    private var stateTitle: String {
        switch model.state {
        case .checking: "Checking\u{2026}"
        case .failed: "Could not check"
        case .checked(let report):
            switch report.state {
            case .resolves: "Stored \u{2014} GitHub user \(report.login ?? "")"
            case .missing: "Missing"
            case .rejected: "Rejected"
            case .unreadable: "Could not be read"
            case .unreachable: "Could not reach GitHub"
            }
        }
    }

    private var stateDetail: String? {
        switch model.state {
        case .checking: nil
        case .failed(let lines): lines.joined(separator: "\n")
        case .checked(let report): report.message
        }
    }

    private var stateSymbol: (name: String, isGood: Bool) {
        switch model.state {
        case .checking: ("ellipsis.circle", false)
        case .failed: ("exclamationmark.triangle.fill", false)
        case .checked(let report):
            report.state == .resolves ? ("checkmark.circle.fill", true) : ("exclamationmark.triangle.fill", false)
        }
    }

    private var stateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: stateSymbol.name)
                .foregroundStyle(stateSymbol.isGood ? AnyShapeStyle(.accent) : AnyShapeStyle(.warning))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle).accessibilityIdentifier("github-credential-state")
                if let stateDetail {
                    Text(stateDetail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if canReplace {
                Button("Replace token\u{2026}") { isReplacing = true }
                    .accessibilityIdentifier("github-replace-token")
            }
            Button("Check again") { Task { await model.check(repoPaths: repoPaths) } }
                .disabled(model.isStoring)
                .accessibilityIdentifier("github-check-again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func repoRow(_ repo: GitHubCredentialReport.Repo) -> some View {
        let isGood = repo.status == .ok || repo.status == .okUnverified
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(isGood ? AnyShapeStyle(.accent) : AnyShapeStyle(.warning))
                .accessibilityHidden(true)
            Text(repo.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("github-repo-\(repo.name)")
    }

    // MARK: Capture

    /// A stored token that works needs no field until the Operator asks to replace it.
    private var isUsable: Bool {
        report?.isValid ?? false
    }

    private var canReplace: Bool { isUsable && !isReplacing }

    private var showsCapture: Bool {
        switch model.state {
        case .checking: false
        case .failed: true
        case .checked: isReplacing || !isUsable
        }
    }

    private var captureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("GitHub token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("github-token-field")
                    .onSubmit(store)
                Button("Store", action: store)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || model.isStoring)
                    .accessibilityIdentifier("github-token-store")
            }
            HStack(spacing: 8) {
                Button("Use the GitHub CLI\u{2019}s token") {
                    Task {
                        await model.importFromGitHubCLI(repoPaths: repoPaths)
                        if model.storeFailure == nil { isReplacing = false }
                    }
                }
                .disabled(model.isStoring)
                .accessibilityIdentifier("github-import-gh")
                if model.isStoring { ProgressView().controlSize(.small) }
            }
        }
        .padding(12)
    }

    /// Hands the token to `yh` and empties the field before the run starts: the app keeps no copy.
    private func store() {
        let value = token
        token = ""
        Task {
            await model.store(token: value, repoPaths: repoPaths)
            if model.storeFailure == nil { isReplacing = false }
        }
    }

    private func failureRow(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index]).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("github-store-failure")
    }
}
