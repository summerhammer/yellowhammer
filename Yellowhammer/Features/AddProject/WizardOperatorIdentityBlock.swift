import Config
import Domain
import SwiftUI

/// The Board step's Operator identity, asked for while the selected Linear workspace has none: what the
/// Operator identity is and how Yellowhammer uses it, then a picker over the workspace's members. Picking
/// one writes it through `yh config operator` at once; it is machine configuration, so it stays if the
/// sheet is cancelled. Settings keeps its own ``OperatorIdentityRow``.
struct WizardOperatorIdentityBlock: View {
    @Bindable var model: OperatorIdentityModel
    /// The workspace's label, as the workspace list names it.
    let workspaceLabel: String

    var body: some View {
        WizardBlock(
            title: "Operator identity", // glossary:ignore GL001
            footer: "Chosen once for \(workspaceLabel), for every Project in it. Change it later in Settings; "
                + "issues already waiting on you keep their assignee."
        ) {
            OperatorIdentityExplanation()
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "You in Linear", detail: "A member of \(workspaceLabel), not a bot.") {
                chooser
            }
            if !model.fetchFailure.isEmpty || model.failure != nil {
                Divider().padding(.leading, 12)
                problem.padding(12)
            }
        }
        // The fetch starts by itself after a connect; a workspace connected earlier fetches here.
        .task {
            if model.candidates.isEmpty, !model.isFetching, model.fetchFailure.isEmpty {
                await model.fetchCandidates()
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        if model.isFetching || model.isSaving {
            ProgressView().controlSize(.small)
        } else if !model.candidates.isEmpty {
            Picker("Operator identity", selection: selection) { // glossary:ignore GL001
                Text("Choose\u{2026}").tag(String?.none)
                ForEach(model.candidates, id: \.id) { candidate in
                    Text("\(candidate.displayName) (\(candidate.name))").tag(Optional(candidate.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("setup-linear-operator-picker-\(model.installation)")
        } else {
            Button("Try Again") { Task { await model.fetchCandidates() } }
                .accessibilityIdentifier("setup-linear-operator-choose-\(model.installation)")
        }
    }

    /// Picking a member saves it: there is nothing else to confirm.
    private var selection: Binding<String?> {
        Binding {
            model.selection
        } set: { newValue in
            model.selection = newValue
            guard newValue != nil else { return }
            Task { await model.save() }
        }
    }

    /// Why the members could not be read, or why the save was refused, in `yh`'s own words.
    @ViewBuilder private var problem: some View {
        if !model.fetchFailure.isEmpty {
            failureText(
                OperatorIdentityModel.fetchFailureSummary, details: model.fetchFailure.joined(separator: "\n"),
                identifier: "setup-linear-operator-fetch-failure-\(model.installation)"
            )
        } else if let failure = model.failure {
            failureText(
                "Yellowhammer could not save the Operator identity.", // glossary:ignore GL001
                details: failure, identifier: "setup-linear-operator-failure-\(model.installation)"
            )
        }
    }

    private func failureText(_ summary: String, details: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(summary, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.error)
            Text(details)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the Operator identity is, why Yellowhammer needs it, and how it is used.
private struct OperatorIdentityExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You are the Operator: the person Yellowhammer works for. It writes to Linear as its own "
                + "app, so it needs to know which Linear user is you.")
                .fixedSize(horizontal: false, vertical: true)
            point(
                "person.crop.circle.badge.exclamationmark",
                "When a Card or Feature needs your decision, Yellowhammer moves it to Waiting on You and "
                    + "assigns it to you, so it shows up in your Linear inbox."
            )
            point(
                "hand.raised",
                "It assigns only as the issue enters Waiting on You. If you reassign it by hand, that stands."
            )
            point(
                "person.slash",
                "If that user leaves the workspace, the issue still moves to Waiting on You, just unassigned."
            )
        }
        .font(.callout)
        .padding(12)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
