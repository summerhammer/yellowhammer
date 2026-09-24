import Foundation

// swiftlint:disable indentation_width line_length

/// The exact bytes of every bundled rehearsal result fixture, embedded in the binary (P15.3 live
/// rehearsal fix): a command-line tool carries no resource bundle at run time — only a test target's
/// `Bundle.module` is ever populated by SwiftPM — so `yh` itself could never have read these from disk;
/// only `swift test`, which runs from the build directory, ever could. Byte-exact with the files these
/// were generated from: `workerEmpty` is zero bytes, `workerMalformed` keeps its truncation (no closing
/// brace, no trailing newline). The literals are left-aligned at column 0, deliberately: Swift strips
/// each line's leading whitespace up to the closing delimiter's own indentation, and column 0 is the
/// only indentation that reproduces every line, including JSON's own un-indented `{`/`}`, byte-exact.
extension RehearsalResultFixture {
    var contents: String {
        switch self {
        case .architectPlanned:
#"""
{
  "schema": "yellowhammer.result.architect",
  "version": 1,
  "outcome": "planned",
  "plan": "Add a `RunPass`-tagged result envelope and decode it against the forced JSON schema.",
  "affected_paths": [
    "Sources/Domain/DispatchResult.swift",
    "Sources/Domain/ResultFile.swift"
  ]
}

"""#
        case .architectFailed:
#"""
{
  "schema": "yellowhammer.result.architect",
  "version": 1,
  "outcome": "failed",
  "reason": "The Architectural Brief cites a repository that is not configured on this Project."
}

"""#
        case .workerCompleted:
#"""
{
  "schema": "yellowhammer.result.worker",
  "version": 1,
  "outcome": "completed",
  "commit": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
  "summary": "Implemented the result schema decoder and its rehearsal fixtures."
}

"""#
        case .workerQuestion:
#"""
{
  "schema": "yellowhammer.result.worker",
  "version": 1,
  "outcome": "question",
  "question": "The DoD asks for a 40-hex commit, but the Worktree has no commits yet. Should I create an empty commit first?"
}

"""#
        case .workerFailed:
#"""
{
  "schema": "yellowhammer.result.worker",
  "version": 1,
  "outcome": "failed",
  "reason": "The Check command failed three times in a row and no further edit made it pass."
}

"""#
        case .reviewerApproved:
#"""
{
  "schema": "yellowhammer.result.reviewer",
  "version": 1,
  "verdict": "approved",
  "judged_commit": "b2c3d4e5f60718293a4b5c6d7e8f90123456789a",
  "summary": "The diff satisfies every Definition of Done clause and the Check is green."
}

"""#
        case .reviewerChangesRequested:
#"""
{
  "schema": "yellowhammer.result.reviewer",
  "version": 1,
  "verdict": "changes_requested",
  "judged_commit": "c3d4e5f60718293a4b5c6d7e8f90123456789abc",
  "summary": "Close, but the worker skipped one clause and left a stray debug print.",
  "requested_changes": [
    "Satisfy DoD clause D-3: the Worktree reconciliation must record a WIP ref on interruption.",
    "Remove the `print(\"here\")` left in WorktreeReconciler.swift."
  ]
}

"""#
        case .workerEmpty:
            ""
        case .workerMalformed:
            #"{"schema": "yellowhammer.result.worker", "version": 1, "outcome": "comple"#
        case .selectionSelected:
#"""
{
  "schema": "yellowhammer.result.selection",
  "version": 1,
  "outcome": "selected",
  "name": "Fixture Feature: rehearsal selection",
  "reasoning": "Fixture data: a rehearsal Night's selection answer, not a judgement about any specification.",
  "repositories": ["fixture-backend"],
  "adopted_card_issue_ids": []
}

"""#
        case .selectionNoSelectableFeature:
#"""
{
  "schema": "yellowhammer.result.selection",
  "version": 1,
  "outcome": "no_selectable_feature"
}

"""#
        case .selectionFailed:
#"""
{
  "schema": "yellowhammer.result.selection",
  "version": 1,
  "outcome": "failed",
  "reason": "Fixture data: the selection pass could not read the specification."
}

"""#
        case .breakdownDrafted:
#"""
{
  "schema": "yellowhammer.result.breakdown",
  "version": 1,
  "outcome": "drafted",
  "definition_of_done": [
    { "text": "Fixture data: the fixture Feature is observable end to end.", "citation": "fixture-epic/fixture-story" }
  ],
  "cards": [
    {
      "repository": "fixture-backend",
      "kind": "impl.fixture",
      "title": "Fixture Card: rehearsal breakdown",
      "unit_of_work": "Fixture data: one unit of work in the fixture repository.",
      "brief": "Fixture data: approach prose for the fixture Card.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture Card's behaviour is covered.", "citation": "fixture-epic/fixture-story" }
      ],
      "contracts": []
    }
  ]
}

"""#
        case .selectionSelectedWithContract:
#"""
{
  "schema": "yellowhammer.result.selection",
  "version": 1,
  "outcome": "selected",
  "name": "Fixture Feature: rehearsal selection with contract",
  "reasoning": "Fixture data: a rehearsal Night's selection answer, not a judgement about any specification.",
  "repositories": ["fixture-backend", "fixture-web"],
  "adopted_card_issue_ids": []
}

"""#
        case .breakdownDraftedWithContract:
#"""
{
  "schema": "yellowhammer.result.breakdown",
  "version": 1,
  "outcome": "drafted",
  "definition_of_done": [
    { "text": "Fixture data: the fixture Feature is observable end to end.", "citation": "fixture-epic/fixture-story" }
  ],
  "cards": [
    {
      "repository": "fixture-backend",
      "kind": "impl.fixture",
      "title": "Fixture Card: rehearsal breakdown (backend)",
      "unit_of_work": "Fixture data: one unit of work in the fixture backend repository.",
      "brief": "Fixture data: approach prose for the fixture backend Card.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture backend Card's behaviour is covered.", "citation": "fixture-epic/fixture-story" }
      ],
      "contracts": []
    },
    {
      "repository": "fixture-web",
      "kind": "impl.fixture",
      "title": "Fixture Card: rehearsal breakdown (web)",
      "unit_of_work": "Fixture data: one unit of work in the fixture web repository.",
      "brief": "Fixture data: approach prose for the fixture web Card.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture web Card's behaviour is covered.", "citation": "fixture-epic/fixture-story" }
      ],
      "contracts": [
        { "repository": "fixture-backend", "paths": ["contracts/fixture-api.json"] }
      ]
    }
  ]
}

"""#
        case .selectionSelectedAdopting:
#"""
{
  "schema": "yellowhammer.result.selection",
  "version": 1,
  "outcome": "selected",
  "name": "Fixture Feature: rehearsal adoption",
  "reasoning": "Fixture data: a rehearsal Night's selection answer, not a judgement about any specification.",
  "repositories": ["fixture-backend", "fixture-web"],
  "adopted_card_issue_ids": []
}

"""#
        case .selectionSelectedThreeRepos:
#"""
{
  "schema": "yellowhammer.result.selection",
  "version": 1,
  "outcome": "selected",
  "name": "Fixture Feature: rehearsal selection across three repositories",
  "reasoning": "Fixture data: a rehearsal Night's selection answer, not a judgement about any specification.",
  "repositories": ["fixture-backend", "fixture-web", "fixture-mobile"],
  "adopted_card_issue_ids": []
}

"""#
        case .breakdownDraftedThreeRepos:
#"""
{
  "schema": "yellowhammer.result.breakdown",
  "version": 1,
  "outcome": "drafted",
  "definition_of_done": [
    { "text": "Fixture data: the fixture Feature is observable end to end.", "citation": "fixture-epic/fixture-story" },
    { "text": "Fixture data: the fixture Feature's second behaviour is observable end to end.", "citation": "fixture-epic/fixture-story-2" }
  ],
  "cards": [
    {
      "repository": "fixture-backend",
      "kind": "impl.fixture",
      "title": "Fixture Card: backend 1 of 3",
      "unit_of_work": "Fixture data: one unit of work in the fixture backend repository.",
      "brief": "Fixture data: approach prose for the fixture backend Card 1 of 3.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture backend Card 1 of 3's behaviour is covered.", "citation": "fixture-epic/fixture-story" }
      ],
      "contracts": []
    },
    {
      "repository": "fixture-backend",
      "kind": "impl.fixture",
      "title": "Fixture Card: backend 2 of 3",
      "unit_of_work": "Fixture data: one unit of work in the fixture backend repository.",
      "brief": "Fixture data: approach prose for the fixture backend Card 2 of 3.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture backend Card 2 of 3's behaviour is covered.", "citation": "fixture-epic/fixture-story-2" }
      ],
      "contracts": []
    },
    {
      "repository": "fixture-backend",
      "kind": "impl.fixture",
      "title": "Fixture Card: backend 3 of 3",
      "unit_of_work": "Fixture data: one unit of work in the fixture backend repository.",
      "brief": "Fixture data: approach prose for the fixture backend Card 3 of 3.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture backend Card 3 of 3's behaviour is covered.", "citation": "fixture-epic/fixture-story" }
      ],
      "contracts": []
    },
    {
      "repository": "fixture-web",
      "kind": "impl.fixture",
      "title": "Fixture Card: rehearsal breakdown (web)",
      "unit_of_work": "Fixture data: one unit of work in the fixture web repository.",
      "brief": "Fixture data: approach prose for the fixture web Card.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture web Card's behaviour is covered.", "citation": "fixture-epic/fixture-story-2" }
      ],
      "contracts": [
        { "repository": "fixture-backend", "paths": ["contracts/fixture-api.json"] }
      ]
    },
    {
      "repository": "fixture-mobile",
      "kind": "impl.fixture",
      "title": "Fixture Card: rehearsal breakdown (mobile)",
      "unit_of_work": "Fixture data: one unit of work in the fixture mobile repository.",
      "brief": "Fixture data: approach prose for the fixture mobile Card.",
      "definition_of_done": [
        { "text": "Fixture data: the fixture mobile Card's behaviour is covered.", "citation": "fixture-epic/fixture-story" }
      ],
      "contracts": []
    }
  ]
}

"""#
        case .verifierReported:
#"""
{
  "schema": "yellowhammer.result.verifier",
  "version": 1,
  "outcome": "reported",
  "clauses": [
    {
      "issue_id": "FIXTURE-1",
      "cid": "c1",
      "verdict": "met",
      "what_was_checked": "Fixture data: a rehearsal Night reads no code.",
      "interpretation": "Fixture data: the clause as written."
    }
  ]
}

"""#
        case .verifierFailed:
#"""
{
  "schema": "yellowhammer.result.verifier",
  "version": 1,
  "outcome": "failed",
  "reason": "Fixture data: the verifier pass could not read the finished code."
}

"""#
        }
    }
}
// swiftlint:enable indentation_width line_length
