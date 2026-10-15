import Config
import Domain
import Foundation
import Testing

/// Sibling Repos on disk: `app` references `contracts` by path in its `Package.swift`.
private final class DraftRepos: @unchecked Sendable {
    let root: URL

    init(contractsPackage: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yh-draft-deps-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in ["app", "contracts", "web"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true
            )
        }
        try #".package(path: "../contracts"),"#.write(
            to: root.appending(path: "app/Package.swift"), atomically: true, encoding: .utf8
        )
        if let contractsPackage {
            try contractsPackage.write(
                to: root.appending(path: "contracts/Package.swift"), atomically: true, encoding: .utf8
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func repo(_ name: String, role: String = "backend") -> AddProjectDraft.Repo {
        AddProjectDraft.Repo(
            path: root.appending(path: name).path(percentEncoded: false), name: name, role: role, check: "none"
        )
    }
}

@Suite("Add Project draft: Repo Dependencies")
struct AddProjectDraftDependenciesTests {
    @Test("A scan proposes the edge a Package.swift path: reference names, with its evidence")
    func scanProposes() throws {
        let repos = try DraftRepos()
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts")]

        draft.scanDependencies()

        let proposal = try #require(draft.dependencyProposals.first)
        #expect(draft.dependencyProposals.count == 1)
        #expect(proposal.consumer == "app")
        #expect(proposal.producer == "contracts")
        #expect(proposal.via == .mainline)
        #expect(proposal.evidence == #"Package.swift: .package(path: "../contracts")"#)
        #expect(proposal.decision == .pending)
        #expect(draft.dependencyScanned)
        #expect(draft.confirmedDependencies.isEmpty)
    }

    @Test("A confirmed proposal keeps its decision and an edited via through a re-scan")
    func rescanKeepsDecisions() throws {
        let repos = try DraftRepos()
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts")]
        draft.scanDependencies()
        draft.dependencyProposals[0].decision = .confirmed
        draft.dependencyProposals[0].via = .tag
        let id = draft.dependencyProposals[0].id

        draft.scanDependencies()

        #expect(draft.dependencyProposals.count == 1)
        #expect(draft.dependencyProposals[0].decision == .confirmed)
        #expect(draft.dependencyProposals[0].via == .tag)
        #expect(draft.dependencyProposals[0].id == id)
    }

    @Test("Removing the producer drops its proposal, and fewer than two Repos clears the scan")
    func removingTheProducer() throws {
        let repos = try DraftRepos()
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts"), repos.repo("web")]
        draft.scanDependencies()
        draft.dependencyProposals[0].decision = .confirmed
        #expect(draft.dependencyProposals.count == 1)

        draft.repos.removeAll { $0.name == "contracts" }
        // Before the next scan, an edge to a Repo that is gone is never written.
        #expect(draft.confirmedDependencies.isEmpty)
        draft.scanDependencies()
        #expect(draft.dependencyProposals.isEmpty)
        #expect(draft.dependencyScanned)

        draft.repos.removeAll { $0.name == "web" }
        draft.scanDependencies()
        #expect(draft.dependencyProposals.isEmpty)
        #expect(!draft.dependencyScanned)
    }

    @Test("The invocation carries the confirmed edges only, in order")
    func invocationCarriesConfirmedEdges() throws {
        let repos = try DraftRepos(contractsPackage: #".package(path: "../web"),"#)
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts"), repos.repo("web")]
        draft.scanDependencies()
        let producers = draft.dependencyProposals.map { "\($0.consumer)>\($0.producer)" }
        #expect(producers == ["app>contracts", "contracts>web"])

        draft.dependencyProposals[0].decision = .declined
        draft.dependencyProposals[1].decision = .confirmed
        draft.dependencyProposals[1].via = .tag
        #expect(draft.setupInvocation.project?.dependencies == [
            SetupInvocation.RepoDependency(consumer: "contracts", producer: "web", via: "tag")
        ])

        draft.dependencyProposals[0].decision = .confirmed
        #expect(draft.setupInvocation.project?.dependencies.map(\.consumer) == ["app", "contracts"])
    }

    @Test("A confirmed proposal with no via is a problem to resolve")
    func confirmedWithoutViaIsAProblem() throws {
        let repos = try DraftRepos()
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts")]
        draft.scanDependencies()
        draft.dependencyProposals[0].via = nil
        draft.dependencyProposals[0].decision = .confirmed

        #expect(draft.problems(in: .repos).contains("Choose mainline or tag for app \u{2192} contracts."))
        #expect(draft.confirmedDependencies.isEmpty)

        draft.dependencyProposals[0].decision = .pending
        #expect(!draft.problems(in: .repos).contains { $0.hasPrefix("Choose mainline or tag") })
    }

    @Test("Two confirmed edges forming a cycle are refused with the loader's reason")
    func cycleIsAProblem() throws {
        let repos = try DraftRepos(contractsPackage: #".package(path: "../app"),"#)
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts")]
        draft.scanDependencies()
        draft.dependencyProposals[0].decision = .confirmed
        #expect(!draft.problems(in: .repos).contains { $0.contains("cycle") })

        draft.dependencyProposals[1].decision = .confirmed
        #expect(draft.problems(in: .repos).contains { $0.contains("cycle") })
    }

    @Test("Fewer than two Repos propose nothing")
    func fewerThanTwoRepos() throws {
        let repos = try DraftRepos()
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app")]

        draft.scanDependencies()

        #expect(draft.dependencyProposals.isEmpty)
        #expect(!draft.dependencyScanned)
    }

    @Test("A role spec Repo is the specification Repo only when the Spec Source is chosen as a Repo")
    func specRepoNeedsTheRepoChoice() throws {
        let repos = try DraftRepos()
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts", role: "spec")]

        draft.specChoice = .path
        draft.scanDependencies()
        #expect(draft.dependencyProposals.filter { $0.producer == "contracts" }.count == 1)
        #expect(draft.dependencyProposals.allSatisfy { $0.evidence.hasPrefix("Package.swift") })

        draft.specChoice = .repo
        draft.scanDependencies()
        #expect(draft.dependencyProposals.filter { $0.producer == "contracts" }.count == 1)
    }

    @Test("The Repos summary counts the confirmed Repo Dependencies")
    func summaryNamesTheCount() throws {
        let repos = try DraftRepos(contractsPackage: #".package(path: "../web"),"#)
        var draft = AddProjectDraft()
        draft.repos = [repos.repo("app"), repos.repo("contracts"), repos.repo("web")]
        draft.scanDependencies()
        #expect(draft.summary(of: .repos) == "app, contracts, and web")

        draft.dependencyProposals[0].decision = .confirmed
        draft.dependencyProposals[0].via = .tag
        #expect(draft.summary(of: .repos) == "app, contracts, and web, 1 Repo Dependency")

        draft.dependencyProposals[1].decision = .confirmed
        #expect(draft.summary(of: .repos) == "app, contracts, and web, 2 Repo Dependencies")
    }
}
