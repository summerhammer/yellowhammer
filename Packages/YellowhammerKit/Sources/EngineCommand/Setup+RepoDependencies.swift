import Config
import Domain
import Foundation

// Proposing Repo Dependencies at setup (app/propose-repository-dependencies-at-setup): the Repos are scanned for
// what they already say about each other, and the Operator decides. Interactive setup asks about each proposal;
// `--init` only prints them, since a declared edge is `--consumes`'s to write.

extension Setup {
    /// What a scan of the declared Repos found. A Spec Source's path is not a Repo and is not scanned.
    func scanRepoDependencies(_ declaration: ProjectDeclaration) -> RepoDependencyScanResult {
        RepoDependencyScan.scan(repos: declaration.repos.map {
            ScannedRepo(name: $0.name, path: $0.path, role: $0.role.rawValue)
        })
    }

    /// The proposals not already declared on their consumer, in the scan's order.
    private func undeclaredProposals(
        _ result: RepoDependencyScanResult, in repos: [RepoDeclaration]
    ) -> [RepoDependencyProposal] {
        result.proposals.filter { proposal in
            !(repos.first { $0.name == proposal.consumer }?.consumes.contains { $0.producer == proposal.producer }
                ?? false)
        }
    }

    private func proposalLine(_ proposal: RepoDependencyProposal) -> String {
        let evidence = proposal.evidenceFile.isEmpty
            ? proposal.evidenceReference : "\(proposal.evidenceFile): \(proposal.evidenceReference)"
        let via = proposal.via?.rawValue ?? "?"
        let note = proposal.via == nil ? " (commit pin: choose mainline or tag)" : ""
        return "Proposed: \(proposal.consumer) consumes \(proposal.producer) via \(via) — \(evidence)\(note)"
    }

    private func printSkippedFiles(_ result: RepoDependencyScanResult) {
        for skipped in result.skippedFiles {
            output("Skipped \(skipped.file): \(skipped.reason)")
        }
    }

    private func printNothingFound() {
        output(
            "No Repo Dependencies found among this Project's Repos; "
                + "declare any by hand with consumes = [...] in the Project file."
        )
    }

    /// `--init`: prints the proposals and the files the scan skipped; writes none.
    func printRepoDependencyProposals(for declaration: ProjectDeclaration) {
        let result = scanRepoDependencies(declaration)
        printSkippedFiles(result)
        let proposals = undeclaredProposals(result, in: declaration.repos)
        guard !proposals.isEmpty else {
            if result.foundNothing { printNothingFound() }
            return
        }
        output("Proposed Repo Dependencies (not written; pass --consumes consumer,producer,via to declare one):")
        for proposal in proposals {
            output(proposalLine(proposal))
        }
    }

    /// Interactive setup: asks about each proposal and returns the declaration with the accepted edges on their
    /// consumers. An edge the loader would refuse, given the ones accepted so far, is refused with the loader's
    /// reason and asked about again; declining records nothing.
    func declaringProposedRepoDependencies(_ declaration: ProjectDeclaration) -> ProjectDeclaration {
        let result = scanRepoDependencies(declaration)
        printSkippedFiles(result)
        var repos = declaration.repos
        let proposals = undeclaredProposals(result, in: repos)
        guard !proposals.isEmpty else {
            if result.foundNothing { printNothingFound() }
            return declaration
        }
        for proposal in proposals {
            output(proposalLine(proposal))
            guard let accepted = askAcceptance(of: proposal, repos: repos) else { continue }
            repos = accepted
        }
        return ProjectDeclaration(
            id: declaration.id, name: declaration.name, linearProject: declaration.linearProject,
            specSource: declaration.specSource, repos: repos, schedule: declaration.schedule
        )
    }

    /// The Repos with the proposal's edge added when the Operator confirms it and the loader would take it;
    /// nil when declined. A refusal is printed and the same proposal asked again.
    private func askAcceptance(of proposal: RepoDependencyProposal, repos: [RepoDeclaration]) -> [RepoDeclaration]? {
        while true {
            guard let via = askVia(for: proposal) else { return nil }
            var edited = repos
            guard let index = edited.firstIndex(where: { $0.name == proposal.consumer }) else { return nil }
            edited[index].consumes.append(RepoDependency(producer: proposal.producer, via: via))
            guard let refusal = ProjectConfiguration.repoDependencyRefusal(repos: edited) else { return edited }
            output("Refused: \(refusal)")
        }
    }

    /// `y` confirms the guessed via (invalid when there is none), `m` mainline, `t` tag; anything else, and
    /// EOF, declines.
    private func askVia(for proposal: RepoDependencyProposal) -> RepoDependencyVia? {
        let subject = "Declare \(proposal.consumer) consumes \(proposal.producer) via"
        while true {
            let prompt = proposal.via.map { "\(subject) \($0.rawValue)? [y/N/m/t] " } ?? "\(subject) ? [m/t/N] "
            guard let line = console.ask(prompt) else { return nil }
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "y", "yes":
                if let via = proposal.via { return via }
            case "m":
                return .mainline
            case "t":
                return .tag
            default:
                return nil
            }
        }
    }
}
