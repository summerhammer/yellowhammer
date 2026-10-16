import Domain
import Foundation
import Testing

private func makeRoom() throws -> BreakdownDescriptionRoom {
    BreakdownDescriptionRoom(
        budget: try DescriptionBudget(
            configured: 10_000, limit: BoardDescriptionLimit(maximum: 250_000, unit: .utf16CodeUnits)
        ),
        rooms: [.init(repository: "mobile", room: 9_613), .init(repository: "backend", room: 9_612)],
        clauseOverhead: 32, referenceOverhead: 198, pathOverhead: 6
    )
}

private func instruction(
    _ pass: RunPass, hasRoom: Bool = true, earlierRejections: [String] = []
) throws -> AuthoringInstruction {
    AuthoringInstruction(
        pass: pass, route: try #require(Route(cli: "claude", model: "opus", effort: "high")),
        specificationSource: .specSource(SpecSource(path: "/spec")), specificationMainline: nil,
        repos: [
            Repo(name: "mobile", path: "/m", role: .mobile), Repo(name: "backend", path: "/b", role: .backend)
        ],
        mainlines: ResolvedMainlines(), namedFeature: nil, adoptionCandidates: [], selectedFeature: nil,
        resultFilePath: "/runs/result.json", descriptionRoom: hasRoom ? try makeRoom() : nil,
        earlierRejections: earlierRejections
    )
}

@Suite("Authoring instruction: the description budget and earlier rejections")
struct AuthoringInstructionBudgetTests {
    @Test("The breakdown's Description budget section names every section the check measures, by its title")
    func everySectionIsNamed() throws {
        let rendered = try instruction(.breakdown).render()
        for section in WorkCardDescriptionSection.allCases {
            #expect(rendered.contains("- \(section.title):"), "\(section.title)")
        }
        #expect(rendered.contains("description budget of 10000 UTF-16 code units"))
        #expect(rendered.contains("198 UTF-16 code units each, plus 6 per path it names"))
        #expect(rendered.contains("32 UTF-16 code units each plus its `text` and `citation`"))
    }

    @Test("Each repository's room renders in the order the repositories were given, in plain integers")
    func roomsKeepTheirOrder() throws {
        let rendered = try instruction(.breakdown).render()
        let mobile = try #require(rendered.range(of: "- mobile: 9613 UTF-16 code units"))
        let backend = try #require(rendered.range(of: "- backend: 9612 UTF-16 code units"))
        #expect(mobile.upperBound <= backend.lowerBound)
        #expect(!rendered.contains("9,613"))
        #expect(!rendered.contains("Linear"))
    }

    @Test("The section precedes the result contract, which points at it")
    func sectionPrecedesTheContract() throws {
        let rendered = try instruction(.breakdown).render()
        let section = try #require(rendered.range(of: "## Description budget"))
        let contract = try #require(rendered.range(of: "## Result contract"))
        #expect(section.upperBound <= contract.lowerBound)
        #expect(rendered.contains("as Description budget sets out"))
    }

    @Test("Without a room, or on the selection pass, nothing is said of the description budget")
    func absentWithoutARoomOrOnSelection() throws {
        for rendered in [try instruction(.breakdown, hasRoom: false).render(), try instruction(.selection).render()] {
            #expect(!rendered.contains("Description budget"))
            #expect(!rendered.contains("description budget"))
        }
    }

    @Test("Earlier rejections render verbatim before the result contract, on either pass")
    func earlierRejectionsAreVerbatim() throws {
        let rejections = [
            "`claude/opus/high`: Work Card \"One\" (backend) composes 12,001 UTF-16 code units",
            "`codex/gpt-5.4/high`: another reason"
        ]
        for pass in [RunPass.breakdown, .selection] {
            let rendered = try instruction(pass, earlierRejections: rejections).render()
            let heading = try #require(rendered.range(of: "## Rejected on an earlier Route"))
            let contract = try #require(rendered.range(of: "## Result contract"))
            #expect(heading.upperBound <= contract.lowerBound)
            for rejection in rejections {
                #expect(rendered.contains("- \(rejection)\n"))
            }
        }
    }

    @Test("With no earlier rejection there is no such section")
    func noRejectionsNoSection() throws {
        #expect(!(try instruction(.breakdown).render().contains("Rejected on an earlier Route")))
    }

    @Test("A result file path replacement keeps the room and the earlier rejections")
    func replacingThePathKeepsBoth() throws {
        let original = try instruction(.breakdown, earlierRejections: ["`a/b/c`: a reason"])
        let moved = original.withResultFilePath("/other.json")
        #expect(moved.descriptionRoom == (try makeRoom()))
        #expect(moved.earlierRejections == ["`a/b/c`: a reason"])
        let expected = original.render().replacingOccurrences(of: "/runs/result.json", with: "/other.json")
        #expect(moved.render() == expected)
    }
}
