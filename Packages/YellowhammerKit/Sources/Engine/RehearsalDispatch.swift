import Domain
import Synchronization

/// Which Card a Card-scoped rehearsal fixture answers (P15.3): the Card's board issue id — carried on
/// ``AgentDispatchRequest/issueID``, which for a Card pass is the Journal's `card.issue_id` — and the pass.
public struct CardPass: Hashable, Sendable {
    public let issueID: String
    public let pass: RunPass

    public init(issueID: String, pass: RunPass) {
        self.issueID = issueID
        self.pass = pass
    }
}

/// A rehearsal Night's whole fixture script (P15.3): `byPass` answers every Card's given pass the same
/// way (`--result-fixture <pass>=<fixture>`), `byCard` answers one named Card's given pass
/// (`--result-fixture <pass>@<card issue id>=<fixture>`), which takes priority when both name the same
/// Card and pass. `ExpressibleByDictionaryLiteral` lets a plain `[.worker: .workerQuestion]` literal
/// stand in wherever only `byPass` is needed, as it did before this type existed.
public struct RehearsalScript: Equatable, Sendable {
    public let byPass: [RunPass: RehearsalResultFixture]
    public let byCard: [CardPass: RehearsalResultFixture]

    public init(byPass: [RunPass: RehearsalResultFixture] = [:], byCard: [CardPass: RehearsalResultFixture] = [:]) {
        self.byPass = byPass
        self.byCard = byCard
    }

    public var isEmpty: Bool { byPass.isEmpty && byCard.isEmpty }

    /// No fixtures scripted: every pass answers from ``RehearsalDispatch/defaultScript``. Spelled out as
    /// a name, not `RehearsalScript()`, because that zero-argument call is ambiguous with the
    /// `ExpressibleByDictionaryLiteral` initializer below.
    public static let empty = RehearsalScript(byPass: [:], byCard: [:])
}

extension RehearsalScript: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (RunPass, RehearsalResultFixture)...) {
        self.byPass = Dictionary(uniqueKeysWithValues: elements)
        self.byCard = [:]
    }
}

/// The Dispatch seam for a Rehearsal Night: it never spawns anything (a rehearsal Night never dispatches
/// an agent CLI), and answers each pass from the result files shipped with the engine. The default script
/// is a clean run — architect plans, worker completes, reviewer approves; the author Act's selection selects
/// one Feature and its breakdown drafts one Card — and a test drives a failure by
/// scripting another fixture for a pass, or one Card's pass alone through ``RehearsalScript/byCard``.
public final class RehearsalDispatch: AgentDispatch, Sendable {
    public static let defaultScript: [RunPass: RehearsalResultFixture] = [
        .architect: .architectPlanned,
        .worker: .workerCompleted,
        .reviewer: .reviewerApproved,
        .selection: .selectionSelected,
        .breakdown: .breakdownDrafted,
        .verifier: .verifierReported
    ]

    private let script: RehearsalScript
    private let requests = Mutex<[AgentDispatchRequest]>([])

    /// `script.byPass` overrides the default fixture for the passes it names; `script.byCard` overrides
    /// both for the one Card and pass it names.
    public init(script: RehearsalScript = RehearsalScript.empty) {
        self.script = RehearsalScript(
            byPass: Self.defaultScript.merging(script.byPass) { _, scripted in scripted },
            byCard: script.byCard
        )
    }

    /// Every request answered so far, in order.
    public var answered: [AgentDispatchRequest] { requests.withLock { $0 } }

    public func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        requests.withLock { $0.append(request) }
        let cardKey = CardPass(issueID: request.issueID, pass: request.pass)
        guard let fixture = script.byCard[cardKey] ?? script.byPass[request.pass] else {
            preconditionFailure("RehearsalDispatch has no fixture for pass \(request.pass)")
        }
        let outcome: RunOutcome
        if fixture == .verifierReported {
            outcome = Self.verifierOutcome(for: request)
        } else if fixture.pass == .selection {
            outcome = Self.selectionOutcome(fixture: fixture, for: request)
        } else {
            outcome = fixture.outcome()
        }
        return AgentDispatchReport(outcome: outcome, origin: .rehearsalFixture(fixture.rawValue))
    }

    /// The `verifier-reported` fixture cannot know the clause ids it will be asked about, so it is
    /// synthesized from the request: every clause its ``VerificationInstruction`` names is reported `met`
    /// under fixed rehearsal copy. It asserts nothing about any code — a rehearsal Night reads none.
    private static func verifierOutcome(for request: AgentDispatchRequest) -> RunOutcome {
        guard case .verification(let instruction) = request.instruction else {
            preconditionFailure("a verifier request carries a verification instruction")
        }
        let clauses = instruction.clauses.map {
            VerifiedClause(
                cid: $0.cid, issueID: $0.issueID, verdict: .met,
                whatWasChecked: "Fixture data: a rehearsal Night reads no code.",
                interpretation: "Fixture data: the clause as written."
            )
        }
        return .completed(.verifier(VerifierResult(outcome: .reported(clauses: clauses))))
    }

    /// A selection fixture's `selected` answer is adjusted to honour the request, the same way
    /// ``verifierOutcome(for:)`` synthesizes from it: the Operator's named Feature (Force authoring,
    /// `yh author --feature <name>`) overrides the fixture's own name — a real selector must honour it,
    /// else selection itself refuses with `namedFeatureIgnored` — and
    /// ``RehearsalResultFixture/selectionSelectedAdopting``'s empty `adopted_card_issue_ids` is
    /// synthesized from the request's adoption candidates (documented on that fixture's own case).
    /// Every other fixture, and every other outcome, is returned untouched.
    private static func selectionOutcome(
        fixture: RehearsalResultFixture, for request: AgentDispatchRequest
    ) -> RunOutcome {
        let outcome = fixture.outcome()
        guard case .authoring(let instruction) = request.instruction else {
            preconditionFailure("a selection request carries an authoring instruction")
        }
        guard case .completed(.selection(let result)) = outcome, case .selected(let selected) = result.outcome else {
            return outcome
        }
        let name = instruction.namedFeature ?? selected.name
        let adoptedCardIssueIDs = fixture == .selectionSelectedAdopting
            ? instruction.adoptionCandidates.map(\.issueID)
            : selected.adoptedCardIssueIDs
        let adjusted = SelectedFeature(
            name: name, reasoning: selected.reasoning, sequence: selected.sequence,
            repositories: selected.repositories, adoptedCardIssueIDs: adoptedCardIssueIDs
        )
        return .completed(.selection(SelectionResult(outcome: .selected(adjusted))))
    }
}
