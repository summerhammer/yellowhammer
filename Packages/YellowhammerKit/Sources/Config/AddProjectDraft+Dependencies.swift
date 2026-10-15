import Domain
import Foundation

// MARK: - Repo Dependencies

/// A Repo Dependency the scan proposed while the Operator declares the Project's Repos
/// (app/propose-repository-dependencies-at-setup). Nothing is written until the Operator confirms it; the
/// Operator may also set its `via` before confirming, which a commit pin requires.
public struct DependencyProposal: Identifiable, Equatable, Sendable {
    public enum Decision: Sendable {
        case pending
        case confirmed
        case declined
    }

    public var id = UUID()
    public var consumer: String
    public var producer: String
    /// The scan's guess, editable; nil for a commit pin, where the Operator must choose.
    public var via: RepoDependencyVia?
    /// The file and the reference that produced the proposal, as one line, or the reference alone.
    public let evidence: String
    public var decision: Decision = .pending

    public init(consumer: String, producer: String, via: RepoDependencyVia?, evidence: String) {
        self.consumer = consumer
        self.producer = producer
        self.via = via
        self.evidence = evidence
    }
}

extension AddProjectDraft {
    /// The Repos the scan can read: those with a name and a path. A Repo of role `spec` is the specification
    /// Repo only when the Spec Source is chosen as a Repo.
    private var scannableRepos: [ScannedRepo] {
        repos.compactMap { repo in
            let name = repo.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = repo.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !path.isEmpty else { return nil }
            let role = repo.role.trimmingCharacters(in: .whitespacesAndNewlines)
            return ScannedRepo(name: name, path: path, role: role == "spec" && specChoice != .repo ? "" : role)
        }
    }

    /// Scans the declared Repos for what they say about each other, replacing ``dependencyProposals``. A
    /// proposal already listed keeps the Operator's `via` edit and decision; one no longer proposed is dropped.
    /// With fewer than two Repos to scan there is nothing to propose.
    public mutating func scanDependencies() {
        let scanned = scannableRepos
        guard scanned.count >= 2 else {
            dependencyProposals = []
            dependencyScanSkipped = []
            dependencyScanned = false
            return
        }
        let result = RepoDependencyScan.scan(repos: scanned)
        dependencyProposals = result.proposals.map { proposal in
            let evidence = proposal.evidenceFile.isEmpty
                ? proposal.evidenceReference : "\(proposal.evidenceFile): \(proposal.evidenceReference)"
            var fresh = DependencyProposal(
                consumer: proposal.consumer, producer: proposal.producer, via: proposal.via, evidence: evidence
            )
            if let known = dependencyProposals.first(where: {
                $0.consumer == fresh.consumer && $0.producer == fresh.producer
            }) {
                fresh.id = known.id
                fresh.via = known.via
                fresh.decision = known.decision
            }
            return fresh
        }
        dependencyScanSkipped = result.skippedFiles.map { "\($0.file): \($0.reason)" }
        dependencyScanned = true
    }

    /// The confirmed proposals that have a `via`, in order: what `yh setup --init` is asked to declare.
    public var confirmedDependencies: [SetupInvocation.RepoDependency] {
        confirmedProposals.compactMap { proposal in
            proposal.via.map {
                SetupInvocation.RepoDependency(
                    consumer: proposal.consumer, producer: proposal.producer, via: $0.rawValue
                )
            }
        }
    }

    /// The confirmed proposals whose two Repos are still declared: removing a Repo leaves its proposals behind
    /// until the next scan, and an edge to a Repo that is gone must never be written.
    private var confirmedProposals: [DependencyProposal] {
        let names = Set(scannableRepos.map(\.name))
        return dependencyProposals.filter {
            $0.decision == .confirmed && names.contains($0.consumer) && names.contains($0.producer)
        }
    }

    var confirmedDependencyCount: Int { confirmedProposals.count }

    /// Problems with the confirmed edges: one without a `via`, and the loader's own refusal of the set.
    var dependencyProblems: [String] {
        let confirmed = confirmedProposals
        var problems = confirmed.filter { $0.via == nil }.map {
            "Choose mainline or tag for \($0.consumer) \u{2192} \($0.producer)."
        }
        let edges = confirmed.filter { $0.via != nil }
        guard !edges.isEmpty else { return problems }
        let declarations = scannableRepos.map { repo in
            RepoDeclaration(
                name: repo.name, path: repo.path, role: RepoRole(rawValue: repo.role.isEmpty ? "backend" : repo.role),
                check: .none,
                consumes: edges.filter { $0.consumer == repo.name }.compactMap { edge in
                    edge.via.map { RepoDependency(producer: edge.producer, via: $0) }
                }
            )
        }
        if let refusal = ProjectConfiguration.repoDependencyRefusal(repos: declarations) {
            problems.append(refusal + ".")
        }
        return problems
    }
}
