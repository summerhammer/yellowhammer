import Domain
@testable import Engine
import Foundation
import Testing

// roadmap P10.5: the verifier pass's result-file contract, its instruction and its rehearsal answer.
// Only that a file decodes, validates and renders is asserted — never the quality of a verdict.

private func verifier(_ body: String) -> String {
    #"{"schema": "yellowhammer.result.verifier", "version": 1, \#(body)}"#
}

private func decode(_ json: String) throws(ResultFileError) -> DispatchResult {
    try ResultFile.decode(Data(json.utf8), expecting: .verifier)
}

private func clauseJSON(
    issue: String = "BACK-1", cid: String = "c1", verdict: String = "met", what: String = "the handler",
    interpretation: String = "as written"
) -> String {
    #"{"issue_id": "\#(issue)", "cid": "\#(cid)", "verdict": "\#(verdict)", "what_was_checked": "\#(what)", "#
        + #""interpretation": "\#(interpretation)"}"#
}

private func expectInvalid(_ json: String, field: String) {
    do {
        _ = try decode(json)
        Issue.record("expected `\(field)` to be refused")
    } catch {
        guard case .invalid(let found, _) = error else {
            Issue.record("expected invalid(field: \(field)), got \(error)")
            return
        }
        #expect(found == field)
    }
}

@Suite("Verifier result file (P10.5)")
struct VerifierResultFileTests {
    @Test("reported maps each clause onto VerifiedClause, keyed by issue and cid")
    func reported() throws {
        let result = try decode(verifier(
            #""outcome": "reported", "clauses": [\#(clauseJSON()), \#(clauseJSON(issue: "MOB-1", verdict: "unmet"))]"#
        ))
        guard case .verifier(let decoded) = result, case .reported(let clauses, _) = decoded.outcome else {
            Issue.record("expected a reported verifier result")
            return
        }
        #expect(clauses.map(\.issueID) == ["BACK-1", "MOB-1"])
        #expect(clauses.map(\.verdict) == [.met, .unmet])
        #expect(clauses[0] == VerifiedClause(
            cid: "c1", issueID: "BACK-1", verdict: .met, whatWasChecked: "the handler", interpretation: "as written"
        ))
        #expect(result.pass == .verifier)
    }

    @Test("failed carries its reason, and is a capability failure of the Route")
    func failed() throws {
        let result = try decode(verifier(#""outcome": "failed", "reason": "cannot read the code""#))
        #expect(result.verifierFailureReason == "cannot read the code")
        #expect(DispatchResult.verifier(VerifierResult(outcome: .reported(clauses: []))).verifierFailureReason == nil)
    }

    @Test("The same cid under two issues is two clauses; the same pair twice is refused")
    func clauseIDsAreOnlyUniquePerIssue() throws {
        let both = #""outcome": "reported", "clauses": [\#(clauseJSON(issue: "A-1")), \#(clauseJSON(issue: "B-1"))]"#
        _ = try decode(verifier(both))
        expectInvalid(
            verifier(#""outcome": "reported", "clauses": [\#(clauseJSON()), \#(clauseJSON())]"#), field: "clauses[1]"
        )
    }

    @Test("The agent never says unresolved: only the engine does")
    func unresolvedIsRefused() {
        expectInvalid(
            verifier(#""outcome": "reported", "clauses": [\#(clauseJSON(verdict: "unresolved"))]"#),
            field: "clauses[0].verdict"
        )
        expectInvalid(
            verifier(#""outcome": "reported", "clauses": [\#(clauseJSON(verdict: "passed"))]"#),
            field: "clauses[0].verdict"
        )
    }

    @Test("Empty strings, a missing or empty clause list, and an unknown outcome are refused")
    func malformed() {
        expectInvalid(
            verifier(#""outcome": "reported", "clauses": [\#(clauseJSON(what: " "))]"#),
            field: "clauses[0].what_was_checked"
        )
        expectInvalid(
            verifier(#""outcome": "reported", "clauses": [\#(clauseJSON(interpretation: ""))]"#),
            field: "clauses[0].interpretation"
        )
        expectInvalid(verifier(#""outcome": "reported""#), field: "clauses")
        expectInvalid(verifier(#""outcome": "reported", "clauses": []"#), field: "clauses")
        expectInvalid(verifier(#""outcome": "failed""#), field: "reason")
        expectInvalid(verifier(#""outcome": "approved""#), field: "outcome")
    }

    @Test("A verifier file decoded as another pass is a pass mismatch")
    func passMismatch() {
        #expect(throws: ResultFileError.passMismatch(expected: .worker, found: .verifier)) {
            try ResultFile.decode(Data(verifier(#""outcome": "failed", "reason": "r""#).utf8), expecting: .worker)
        }
    }

    @Test("The verifier is read-only and not an authoring pass; its schema forbids unresolved")
    func passAndSchema() throws {
        #expect(RunPass.verifier.isAuthoring == false)
        #expect(RunPass.verifier.schemaIdentifier == "yellowhammer.result.verifier")
        let schema = ResultSchema.jsonSchema(for: .verifier)
        #expect(schema.contains("\"enum\": [\"met\", \"unmet\", \"not checked\"]"))
        #expect(!schema.contains("unresolved"))
    }

    @Test("reported accepts not checked and records missing capability in what_was_checked")
    func reportedNotChecked() throws {
        let result = try decode(verifier(
            #""outcome": "reported", "clauses": [\#(clauseJSON(verdict: "not checked", what: "network access"))]"#
        ))
        guard case .verifier(let decoded) = result, case .reported(let clauses, _) = decoded.outcome else {
            Issue.record("expected a reported verifier result")
            return
        }
        #expect(clauses[0].verdict == .notChecked)
        #expect(clauses[0].whatWasChecked == "network access")
    }

    // MARK: - Dropped clauses (OQ157)

    private static func droppedJSON(
        issue: String = "FEAT-1", cid: String = "c1", reason: String = "asserts landing's own output"
    ) -> String {
        #"{"issue_id": "\#(issue)", "cid": "\#(cid)", "reason": "\#(reason)"}"#
    }

    @Test("reported decodes results with only dropped clauses")
    func reportedOnlyDropped() throws {
        let json = #""outcome": "reported", "dropped": [\#(Self.droppedJSON())]"#
        let result = try decode(verifier(json))
        guard case .verifier(let decoded) = result, case .reported(let clauses, let dropped) = decoded.outcome else {
            Issue.record("expected reported result")
            return
        }
        #expect(clauses.isEmpty)
        #expect(dropped == [
            DroppedVerificationClause(cid: "c1", issueID: "FEAT-1", reason: "asserts landing's own output")
        ])
    }

    @Test("reported decodes results with both clauses and dropped")
    func reportedBothLists() throws {
        let json = #""outcome": "reported", "clauses": [\#(clauseJSON(issue: "BACK-1", cid: "c1"))], "#
            + #""dropped": [\#(Self.droppedJSON(issue: "FEAT-1", cid: "c2"))]"#
        let result = try decode(verifier(json))
        guard case .verifier(let decoded) = result, case .reported(let clauses, let dropped) = decoded.outcome else {
            Issue.record("expected reported result")
            return
        }
        #expect(clauses.count == 1)
        #expect(clauses[0].cid == "c1")
        #expect(dropped.count == 1)
        #expect(dropped[0].cid == "c2")
    }

    @Test("A clause appearing twice across both lists is refused")
    func duplicateAcrossListsRefused() {
        let json = #""outcome": "reported", "clauses": [\#(clauseJSON(issue: "BACK-1", cid: "c1"))], "#
            + #""dropped": [\#(Self.droppedJSON(issue: "BACK-1", cid: "c1"))]"#
        expectInvalid(verifier(json), field: "dropped[0]")
    }

    @Test("A clause appearing twice within dropped is refused")
    func duplicateWithinDroppedRefused() {
        let json = #""outcome": "reported", "dropped": ["#
            + #"\#(Self.droppedJSON(issue: "BACK-1", cid: "c1")), \#(Self.droppedJSON(issue: "BACK-1", cid: "c1"))]"#
        expectInvalid(verifier(json), field: "dropped[1]")
    }

    @Test("An invalid reason in dropped is refused")
    func invalidDroppedReasonRefused() {
        let json = #""outcome": "reported", "dropped": [\#(Self.droppedJSON(issue: "BACK-1", reason: "bad"))]"#
        expectInvalid(verifier(json), field: "dropped[0].reason")
    }
}

@Suite("Verification instruction and rehearsal answer (P10.5)")
struct VerificationInstructionTests {
    private let instruction = VerificationInstruction(
        route: Route(cli: "codex", model: "gpt-5.4", effort: "high")!,
        featureTitle: "FEAT-1 (Feature Branch yh-proj-feat)",
        clauses: [
            VerificationClause(issueID: "FEAT-1", cid: "c1", text: "The whole thing works.", location: "epic/story"),
            VerificationClause(issueID: "BACK-1", cid: "c2", text: "Returns 404.", location: "epic/other#dod-2")
        ],
        specificationSource: .specSource(SpecSource(path: "/repos/spec")),
        repositories: [
            VerificationRepository(name: "backend", directory: "/wt/backend", featureBranch: "yh-proj-feat")
        ]
    )

    @Test("It renders each clause with its citation, the specification path, each repository and the result file")
    func rendering() {
        let text = instruction.render()
        #expect(text.contains("FEAT-1 c1: The whole thing works."))
        #expect(text.contains("BACK-1 c2: Returns 404."))
        #expect(text.contains("Spec Citation: epic/story"))
        #expect(text.contains("Spec Citation: epic/other#dod-2"))
        #expect(text.contains("Specification path: /repos/spec"))
        #expect(text.contains("Finished code: /wt/backend"))
        #expect(text.contains("Feature Branch: yh-proj-feat"))
        #expect(!text.contains("result.json"))
        #expect(text.contains("final structured response"))
        #expect(text.contains("CLI Adapter persists it"))
        #expect(text.contains("do not create or edit a result file with tools"))
        #expect(!text.contains("Write the result file"))
        #expect(text.contains("\"schema\": \"yellowhammer.result.verifier\""))
        #expect(text.contains("read-only"))
        #expect(text.contains("never an aggregate verdict"))
        #expect(text.contains("Report `met`, `unmet` or `not checked` for each clause"))
        #expect(text.contains("Report `not checked` when you could not perform the check"))
        #expect(text.contains("naming in `what_was_checked` the capability that was missing"))
        #expect(text.contains("network access, a writable directory, or a tool"))
        #expect(text.contains(
            "You read the specification source and the finished code in the repositories you are given"
        ))
        #expect(text.contains("may run commands that change nothing"))
        #expect(text.contains("whether you have either depends on your Route"))
        #expect(text.contains("`verdict` (`met`, `unmet` or `not checked`)"))
        #expect(text.contains("guaranteed neither network access nor a writable directory"))
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        #expect(text == instruction.render())
    }

    @Test("It renders a clause with and without the Author-supplied flag (OQ157)")
    func renderingAuthorSuppliedFlag() {
        let flagInstruction = VerificationInstruction(
            route: Route(cli: "codex", model: "gpt-5.4", effort: "high")!,
            featureTitle: "FEAT-1",
            clauses: [
                VerificationClause(
                    issueID: "FEAT-1", cid: "c1", text: "Human inserted.",
                    location: "epic/story", isAuthorSupplied: true
                ),
                VerificationClause(
                    issueID: "FEAT-1", cid: "c2", text: "Machine found.",
                    location: "epic/story", isAuthorSupplied: false
                )
            ],
            specificationSource: .specSource(SpecSource(path: "/repos/spec")),
            repositories: [
                VerificationRepository(name: "backend", directory: "/wt/backend", featureBranch: "yh-feat")
            ]
        )
        let rendered = flagInstruction.render()
        #expect(rendered.contains("FEAT-1 c1: Human inserted.\n  Spec Citation: epic/story\n  Author-supplied: yes"))
        #expect(rendered.contains("FEAT-1 c2: Machine found.\n  Spec Citation: epic/story\n\n## Repositories"))
        #expect(!rendered.contains("FEAT-1 c2: Machine found.\n  Spec Citation: epic/story\n  Author-supplied: yes"))
        #expect(rendered.contains(
            "Before judging Author-supplied clauses (marked `Author-supplied: yes` below), screen them"
        ))
        #expect(rendered.contains(
            "the push, the pull request, the merge, the Cycle archive, or Yellowhammer's own board writes"
        ))
        #expect(rendered.contains("The test is who performs the action and when, not keywords"))
        #expect(rendered.contains("when it is unclear whether the test applies, judge the clause normally"))
        #expect(rendered.contains("Never screen machine-found clauses, because authoring already applied the test"))
    }

    @Test("It travels as an AgentInstruction that names no result file path")
    func agentInstruction() {
        let wrapped = AgentInstruction.verification(instruction)
        #expect(wrapped.render() == instruction.render())
        #expect(!wrapped.render().contains("result.json"))
        #expect(wrapped.render().contains(PassBoundaries.statement))
        #expect(wrapped.cardInstruction == nil)
    }

    @Test("A rehearsal answers verifier-reported by reporting exactly the requested clauses, from a fixture")
    func rehearsalSynthesizesFromTheRequest() async throws {
        let dispatch = RehearsalDispatch()
        let request = AgentDispatchRequest(
            runID: RunID(), issueID: "verification", attemptID: 1, route: instruction.route, pass: .verifier,
            instruction: .verification(instruction), worktreePath: "/repos/spec"
        )

        let report = try await dispatch.dispatch(request)

        #expect(report.origin == .rehearsalFixture("verifier-reported.json"))
        guard case .completed(.verifier(let result)) = report.outcome,
            case .reported(let clauses, _) = result.outcome
        else {
            Issue.record("expected a reported verifier result")
            return
        }
        #expect(clauses.map { "\($0.issueID) \($0.cid)" } == ["FEAT-1 c1", "BACK-1 c2"])
        #expect(clauses.allSatisfy { $0.verdict == .met })
    }

    @Test("Both verifier fixtures decode against the verifier schema; the failed one is a failed result")
    func fixturesDecode() throws {
        _ = try RehearsalResultFixture.verifierReported.decode()
        let failed = try RehearsalResultFixture.verifierFailed.decode()
        #expect(failed.verifierFailureReason != nil)
        #expect(RehearsalResultFixture.verifierFailed.outcome() == .completed(failed))
    }
}
