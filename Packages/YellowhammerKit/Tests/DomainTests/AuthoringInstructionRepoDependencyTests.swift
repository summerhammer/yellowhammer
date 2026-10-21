import Domain
import Testing

private func instruction(
    _ pass: RunPass, consumes: [RepoDependency], held: [HeldConsumer] = []
) throws -> String {
    AuthoringInstruction(
        pass: pass, route: try #require(Route(cli: "claude", model: "opus", effort: "high")),
        specificationSource: .specSource(SpecSource(path: "/spec")), specificationMainline: nil,
        repos: [
            Repo(name: "backend", path: "/b", role: .backend, consumes: consumes),
            Repo(name: "contracts", path: "/c", role: .backend)
        ],
        mainlines: ResolvedMainlines(), namedFeature: nil, adoptionCandidates: [], heldConsumers: held,
        selectedFeature: nil
    ).render()
}

private let invariant = "Every Work Card in a Feature must be completable and verifiable against the repositories as "
    + "they exist at authoring time: nothing a Work Card needs may be work another Work Card in the same Feature "
    + "has yet to do."

@Suite("Authoring instruction: Repo Dependencies")
struct AuthoringInstructionRepoDependencyTests {
    @Test("The selection pass states the invariant and the sequence rule, and lists each edge")
    func selectionPass() throws {
        let rendered = try instruction(.selection, consumes: [RepoDependency(producer: "contracts", via: .tag)])
        #expect(rendered.contains("## Authoring invariant"))
        #expect(rendered.contains(invariant))
        #expect(rendered.contains("A Feature never touches both ends of a declared Repo Dependency."))
        #expect(rendered.contains("select the upstream layer (the producer Repo) as its own Feature first"))
        #expect(rendered.contains("name the rest in `followed_by`"))
        #expect(rendered.contains("## Repo Dependencies\n\n- backend consumes contracts via tag"))
        #expect(!rendered.contains("None declared."))
        #expect(!rendered.contains("## Held by the release gate tonight"))
        let repositories = try #require(rendered.range(of: "## Repositories"))
        let section = try #require(rendered.range(of: "## Authoring invariant"))
        #expect(repositories.lowerBound < section.lowerBound)
    }

    @Test("The selection pass says None declared. when there are no edges")
    func noneDeclared() throws {
        let rendered = try instruction(.selection, consumes: [])
        #expect(rendered.contains("## Repo Dependencies\n\nNone declared."))
    }

    @Test("A held consumer is named, and only when the release gate holds one")
    func heldConsumers() throws {
        let held = [HeldConsumer(
            consumer: "backend", producer: "contracts", producerFeature: "FEAT-7", hold: .awaitingRelease
        )]
        let rendered = try instruction(.selection, consumes: [], held: held)
        #expect(rendered.contains("## Held by the release gate tonight"))
        #expect(rendered.contains(
            "- backend: it reads contracts by tag, and no release of contracts contains Feature FEAT-7 yet. "
                + "Do not select a Feature that touches backend tonight."
        ))
    }

    @Test("The breakdown pass has the invariant and the two breakdown sentences, and no edges or held consumers")
    func breakdownPass() throws {
        let held = [HeldConsumer(
            consumer: "backend", producer: "contracts", producerFeature: "FEAT-7", hold: .awaitingRelease
        )]
        let rendered = try instruction(
            .breakdown, consumes: [RepoDependency(producer: "contracts", via: .tag)], held: held
        )
        #expect(rendered.contains("## Authoring invariant"))
        #expect(rendered.contains(invariant))
        #expect(rendered.contains("Every repository a Work Card reads from goes in its `contracts`."))
        #expect(rendered.contains(
            "Bumping a version pin or updating a lockfile in a consumer repository is that consumer "
                + "Work Card's own work."
        ))
        #expect(!rendered.contains("## Repo Dependencies"))
        #expect(!rendered.contains("## Held by the release gate tonight"))
        #expect(!rendered.contains("A Feature never touches both ends"))
    }

    @Test("A consumer held awaiting a merge renders the awaiting-merge bullet")
    func awaitingMergeConsumer() throws {
        let held = [HeldConsumer(
            consumer: "backend", producer: "contracts", producerFeature: "FEAT-7", hold: .awaitingMerge
        )]
        let rendered = try instruction(.selection, consumes: [], held: held)
        #expect(rendered.contains(
            "- backend: it consumes contracts, and Feature FEAT-7 is implemented in contracts but awaits its "
                + "Observed Merge there. Do not select a Feature that touches backend tonight."
        ))
        #expect(!rendered.contains("by tag"))
    }
}
