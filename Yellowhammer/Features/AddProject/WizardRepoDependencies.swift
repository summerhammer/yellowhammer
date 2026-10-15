import Config
import Domain
import SwiftUI

// MARK: - Repo Dependencies

/// The Repo Dependencies the scan proposes among the declared Repos: each names its evidence, and the Operator
/// confirms, edits or declines it. Nothing is written for a proposal left pending or declined.
struct RepoDependenciesBlock: View {
    @Binding var draft: AddProjectDraft

    /// What the scan depends on: changing any of it scans again.
    private var scanInputs: [String] {
        draft.repos.map { $0.path + "\u{1F}" + $0.name + "\u{1F}" + $0.role }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repo Dependencies").font(.headline)
            Text(
                "Which of these Repos reads which. A Feature never touches both ends of a declared dependency, "
                    + "and a consumer that reads by tag waits for a release."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if draft.dependencyScanned && draft.dependencyProposals.isEmpty {
                Text("No Repo Dependencies found among these Repos.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-dependency-none")
            }
            ForEach(draft.dependencyProposals) { proposal in
                DependencyRow(proposal: $draft.dependencyProposal(proposal.id))
            }
            if !draft.dependencyScanSkipped.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skipped:").foregroundStyle(.secondary)
                    ForEach(draft.dependencyScanSkipped, id: \.self) { line in
                        Text(line).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
        .onAppear { draft.scanDependencies() }
        .onChange(of: scanInputs) { draft.scanDependencies() }
        .onChange(of: draft.specChoice) { draft.scanDependencies() }
    }
}

private struct DependencyRow: View {
    @Binding var proposal: DependencyProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(proposal.consumer) consumes \(proposal.producer)").font(.headline)
                Spacer()
                decisionControls
            }
            Text(proposal.evidence)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Text("Read by").foregroundStyle(.secondary)
                Picker("Read by", selection: $proposal.via) {
                    Text("Choose\u{2026}").tag(RepoDependencyVia?.none)
                    ForEach(RepoDependencyVia.allCases, id: \.self) { via in
                        Text(via.rawValue).tag(RepoDependencyVia?.some(via))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("setup-dependency-via")
            }
        }
        .padding(14)
        .background(tint.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.22)))
        .opacity(proposal.decision == .declined ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-dependency-row")
    }

    @ViewBuilder
    private var decisionControls: some View {
        switch proposal.decision {
        case .pending:
            HStack {
                Button("Confirm") { proposal.decision = .confirmed }
                    .accessibilityIdentifier("setup-dependency-confirm")
                Button("Decline") { proposal.decision = .declined }
                    .accessibilityIdentifier("setup-dependency-decline")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .confirmed:
            HStack {
                Label("Confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.success)
                Button("Undo") { proposal.decision = .pending }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("setup-dependency-undo")
            }
        case .declined:
            Button("Undo") { proposal.decision = .pending }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("setup-dependency-undo")
        }
    }

    private var tint: AnyShapeStyle {
        proposal.decision == .confirmed ? AnyShapeStyle(.success) : AnyShapeStyle(.neutral)
    }
}

extension Binding where Value == AddProjectDraft {
    /// A binding to one proposal by id, safe against a re-scan dropping it mid-render.
    fileprivate func dependencyProposal(_ id: DependencyProposal.ID) -> Binding<DependencyProposal> {
        Binding<DependencyProposal> {
            wrappedValue.dependencyProposals.first { $0.id == id }
                ?? DependencyProposal(consumer: "", producer: "", via: nil, evidence: "")
        } set: { newValue in
            guard let index = wrappedValue.dependencyProposals.firstIndex(where: { $0.id == id }) else { return }
            wrappedValue.dependencyProposals[index] = newValue
        }
    }
}
