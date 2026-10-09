import Config
import Domain
import SwiftUI

struct WizardCodeHostingStep: View {
    @Binding var draft: AddProjectDraft
    let connections: CodeHostingConnectionsModel
    let check: CodeHostingCheckModel
    @State private var isConnecting = false

    private var checkID: String {
        ([draft.codeHostingConnectionName ?? ""] + draft.workingRepoPaths).joined(separator: "\n")
    }

    var body: some View {
        WizardColumn {
            WizardBlock(title: "Code Hosting Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Connection", selection: $draft.codeHostingConnectionName) {
                        Text("Choose a connection").tag(String?.none)
                        ForEach(connections.connections) { connection in
                            Text("\(connection.name) · \(connection.typeLabel) · "
                                + connections.label(for: connection))
                                .tag(Optional(connection.name))
                        }
                    }
                    .accessibilityIdentifier("setup-code-hosting-picker")
                    Button("Connect another…") { isConnecting.toggle() }
                        .accessibilityIdentifier("setup-code-hosting-connect-another")
                    if check.isChecking { ProgressView("Checking…") }
                    if let report = check.report {
                        Text(report.message).textSelection(.enabled)
                            .accessibilityIdentifier("setup-code-hosting-report")
                        ForEach(report.repos, id: \.path) { repo in
                            Text(repo.message).textSelection(.enabled)
                        }
                    }
                    if !check.failure.isEmpty { Text(check.failure.joined(separator: "\n")).textSelection(.enabled) }
                    Button("Check again") { Task { await runCheck() } }
                        .accessibilityIdentifier("setup-code-hosting-check-again")
                }
                .padding(12)
            }
            if let failure = connections.loadFailure {
                WizardProblemBox(problems: [failure])
            }
            if let failure = connections.reportFailure {
                WizardProblemBox(problems: failure)
            }
            if draft.revealsProblems(in: .github), !draft.problems(in: .github).isEmpty {
                WizardProblemBox(problems: draft.problems(in: .github))
            }
            if isConnecting || connections.connections.isEmpty { CodeHostingConnectBlock(model: connections) }
        }
        .onAppear { connections.requestRefresh() }
        .task(id: checkID) { await runCheck() }
    }

    private func runCheck() async {
        draft.gitHubReport = nil
        await check.check(
            connection: draft.codeHostingConnectionName,
            repoPaths: draft.workingRepoPaths.map(AddProjectContext.normalizedPath)
        )
    }
}
