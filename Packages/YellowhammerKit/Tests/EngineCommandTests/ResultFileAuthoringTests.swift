import Domain
@testable import Engine
import Foundation
import Testing

// roadmap P9.11: the selection and breakdown result-file contracts, decoded with the same strictness and
// `ResultFileError` style as the Card passes. Only that a file decodes to the domain type it maps onto is
// asserted — never the quality of a selection or breakdown.

private func decode(_ json: String, _ pass: RunPass) throws(ResultFileError) -> DispatchResult {
    try ResultFile.decode(Data(json.utf8), expecting: pass)
}

private func selection(_ body: String) -> String {
    #"{"schema": "yellowhammer.result.selection", "version": 1, \#(body)}"#
}

private func breakdown(_ body: String) -> String {
    #"{"schema": "yellowhammer.result.breakdown", "version": 1, \#(body)}"#
}

private func invalid(_ json: String, _ pass: RunPass, field: String) {
    do {
        _ = try decode(json, pass)
        Issue.record("expected `\(field)` to be refused")
    } catch {
        guard case .invalid(let found, _) = error else {
            Issue.record("expected invalid(field: \(field)), got \(error)")
            return
        }
        #expect(found == field)
    }
}

@Suite("Selection result file (P9.11)")
struct SelectionResultFileTests {
    @Test("selected maps onto SelectedFeature, sequence and adoption included")
    func selected() throws {
        let result = try decode(selection("""
            "outcome": "selected", "name": "F", "reasoning": "R", "repositories": ["a", "b"],
            "sequence": {"preceded_by": "P", "followed_by": "N", "seam": "S"},
            "adopted_card_issue_ids": ["X-1"]
            """), .selection)

        guard case .selection(let decoded) = result else {
            Issue.record("expected a selection result")
            return
        }
        #expect(decoded.outcome == .selected(SelectedFeature(
            name: try #require(FeatureName(rawValue: "F")), reasoning: "R",
            sequence: FeatureSequence(precededBy: "P", followedBy: "N", seam: "S"),
            repositories: ["a", "b"], adoptedCardIssueIDs: ["X-1"]
        )))
        #expect(decoded.featureSelectionOutcome != nil)
        #expect(result.pass == .selection)
    }

    @Test("no_selectable_feature and failed decode")
    func noSelectableAndFailed() throws {
        let none = try decode(selection(#""outcome": "no_selectable_feature""#), .selection)
        #expect(none == .selection(SelectionResult(outcome: .noSelectableFeature)))
        #expect(none.authoringFailureReason == nil)

        let failed = try decode(selection(#""outcome": "failed", "reason": "why""#), .selection)
        #expect(failed == .selection(SelectionResult(outcome: .failed(reason: "why"))))
        #expect(failed.authoringFailureReason == "why")
    }

    @Test("halted covers every cause a selector may return")
    func halted() throws {
        let feature = try #require(FeatureName(rawValue: "F"))
        let cases: [(String, AuthoringHaltCause)] = [
            (#""halt_cause": "no-backward-compatible-seam", "halt_seam": "the wire""#,
             .noBackwardCompatibleSeam(seam: "the wire")),
            (#""halt_cause": "repositories-undetermined""#, .repositoriesUndetermined),
            (#""halt_cause": "contract-outside-project", "halt_repository": "web""#,
             .contractOutsideProject(repository: "web"))
        ]
        for (body, cause) in cases {
            let result = try decode(selection(#""outcome": "halted", "feature": "F", \#(body)"#), .selection)
            #expect(result == .selection(SelectionResult(outcome: .halted(feature: feature, cause: cause))))
        }
    }

    @Test("A missing or empty required field is refused, naming it")
    func refusesBrokenFields() {
        invalid(selection(#""outcome": "selected", "reasoning": "R", "repositories": []"#), .selection, field: "name")
        invalid(selection(#""outcome": "selected", "name": "F", "reasoning": "R""#), .selection, field: "repositories")
        invalid(selection(#""outcome": "failed", "reason": " ""#), .selection, field: "reason")
        invalid(selection(#""outcome": "halted", "feature": "F", "halt_cause": "no-backward-compatible-seam""#),
                .selection, field: "halt_seam")
        invalid(selection(#""outcome": "halted", "feature": "F", "halt_cause": "contract-unreadable""#),
                .selection, field: "halt_cause")
        invalid(selection(#""outcome": "mystery""#), .selection, field: "outcome")
        invalid(
            selection(#""outcome": "selected", "name": "F", "reasoning": "R", "repositories": [], "#
                + #""sequence": {"seam": "S"}"#),
            .selection, field: "sequence.preceded_by"
        )
    }

    @Test("A file declaring another pass's schema is a pass mismatch")
    func wrongSchema() {
        do {
            _ = try decode(breakdown(#""outcome": "failed", "reason": "r""#), .selection)
            Issue.record("expected a pass mismatch")
        } catch {
            #expect(error == .passMismatch(expected: .selection, found: .breakdown))
        }
    }
}

@Suite("Breakdown result file (P9.11)")
struct BreakdownResultFileTests {
    @Test("drafted maps every field onto FeatureBreakdown, Card drafts and contracts included")
    func drafted() throws {
        let result = try decode(breakdown("""
            "outcome": "drafted",
            "definition_of_done": [{"text": "T", "citation": "e/s"}],
            "cards": [{
              "repository": "a", "kind": "impl.x", "title": "C", "unit_of_work": "U", "brief": "B",
              "definition_of_done": [{"text": "CT", "citation": "e/s2"}],
              "contracts": [
                {"repository": "b", "paths": ["p"], "symbol": null},
                {"repository": "c", "paths": [], "symbol": "S"}
              ]
            }]
            """), .breakdown)

        let expected = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "T", citation: "e/s")],
            cards: [CardDraft(
                repository: "a", kind: try #require(Kind("impl.x")), title: "C", unitOfWork: "U", brief: "B",
                definitionOfDone: [DefinitionOfDoneClauseDraft(text: "CT", citation: "e/s2")],
                contracts: [
                    ContractDraft(repository: "b", paths: ["p"], symbol: nil),
                    ContractDraft(repository: "c", paths: [], symbol: "S")
                ]
            )]
        )
        #expect(result == .breakdown(BreakdownResult(outcome: .drafted(expected))))
        #expect(result.pass == .breakdown)
    }

    @Test("failed decodes, and reads as an authoring failure")
    func failed() throws {
        let result = try decode(breakdown(#""outcome": "failed", "reason": "no plan""#), .breakdown)
        #expect(result == .breakdown(BreakdownResult(outcome: .failed(reason: "no plan"))))
        #expect(result.authoringFailureReason == "no plan")
    }

    @Test("A missing or malformed field is refused, naming its path")
    func refusesBrokenFields() {
        invalid(breakdown(#""outcome": "drafted", "definition_of_done": []"#), .breakdown, field: "cards")
        invalid(breakdown(#""outcome": "drafted", "cards": "none""#), .breakdown, field: "cards")
        invalid(breakdown(#""outcome": "failed""#), .breakdown, field: "reason")
        invalid(
            breakdown(#""outcome": "drafted", "definition_of_done": [{"text": "T"}], "cards": []"#),
            .breakdown, field: "definition_of_done[0].citation"
        )
        let card = #""repository": "a", "title": "C", "brief": "B""#
        invalid(
            breakdown(#""outcome": "drafted", "cards": [{\#(card), "kind": "impl..x", "unit_of_work": "U"}]"#),
            .breakdown, field: "cards[0].kind"
        )
        invalid(
            breakdown(#""outcome": "drafted", "cards": [{\#(card), "kind": "impl"}]"#),
            .breakdown, field: "cards[0].unit_of_work"
        )
    }

    @Test("A file declaring another pass's schema is a pass mismatch, and an unknown version is refused")
    func wrongSchemaAndVersion() {
        do {
            _ = try decode(selection(#""outcome": "no_selectable_feature""#), .breakdown)
            Issue.record("expected a pass mismatch")
        } catch {
            #expect(error == .passMismatch(expected: .breakdown, found: .selection))
        }
        do {
            _ = try decode(
                #"{"schema": "yellowhammer.result.breakdown", "version": 2, "outcome": "failed"}"#, .breakdown
            )
            Issue.record("expected an unsupported version")
        } catch {
            #expect(error == .unsupportedVersion(2))
        }
    }
}

@Suite("Authoring rehearsal fixtures (P9.11)")
struct AuthoringFixtureTests {
    @Test("Every shipped authoring fixture decodes, and each pass has a default fixture")
    func fixturesDecode() throws {
        for fixture in RehearsalResultFixture.allCases where fixture.pass.isAuthoring {
            #expect(try fixture.decode().pass == fixture.pass)
        }
        #expect(RehearsalDispatch.defaultScript[.selection] == .selectionSelected)
        #expect(RehearsalDispatch.defaultScript[.breakdown] == .breakdownDrafted)
    }

    @Test("The fixtures answer as a completed run, and the failed one reads as an authoring failure")
    func fixtureOutcomes() throws {
        guard case .completed(let none) = RehearsalResultFixture.selectionNoSelectableFeature.outcome() else {
            Issue.record("expected a completed outcome")
            return
        }
        #expect(none == .selection(SelectionResult(outcome: .noSelectableFeature)))
        #expect(try RehearsalResultFixture.selectionFailed.decode().authoringFailureReason != nil)
    }

    @Test("Every pass has a JSON schema declaring its own schema id, and the authoring instruction names it")
    func schemasAndInstruction() throws {
        for pass in RunPass.allCases {
            #expect(ResultSchema.jsonSchema(for: pass).contains(pass.schemaIdentifier))
        }
        let instruction = AuthoringInstruction(
            pass: .breakdown, route: Route(cli: "claude", model: "opus", effort: "high")!,
            specificationSource: .specSource(SpecSource(path: "/spec")), specificationMainline: nil,
            repos: [Repo(name: "backend", path: "/b", role: .backend)], mainlines: ResolvedMainlines(),
            namedFeature: nil, adoptionCandidates: [], selectedFeature: nil, resultFilePath: "/runs/result.json"
        )
        let rendered = instruction.render()
        #expect(rendered == instruction.render())
        #expect(rendered.contains("/runs/result.json"))
        #expect(rendered.contains("yellowhammer.result.breakdown"))
        #expect(rendered.hasSuffix("\n"))
        #expect(instruction.withResultFilePath("/other.json").render().contains("/other.json"))
    }
}
