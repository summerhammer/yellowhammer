import Domain
import Foundation

/// The result files shipped with the engine for rehearsal Nights. A rehearsal Night never spawns a
/// CLI (spec: three environments only — Development, Rehearsal, Production); its result files come
/// from these fixtures instead, so both the happy paths and the dual-key completion failure modes
/// (an empty or truncated file) are exercisable without a live CLI.
public enum RehearsalResultFixture: String, CaseIterable, Sendable {
    case architectPlanned = "architect-planned.json"
    case architectFailed = "architect-failed.json"
    /// The file's `commit` (`a1b2c3d4...`) is a placeholder, not a real SHA: ``RehearsalDispatch``
    /// answers it with the request's Worktree's actual HEAD instead (P15.3), so a rehearsal Night never
    /// records a commit that does not exist as a Worktree's last known-good.
    case workerCompleted = "worker-completed.json"
    case workerQuestion = "worker-question.json"
    case workerFailed = "worker-failed.json"
    /// The file's `judged_commit` is a placeholder, answered with the request's Worktree's actual HEAD
    /// instead, like ``workerCompleted``'s `commit` (P15.3).
    case reviewerApproved = "reviewer-approved.json"
    /// The file's `judged_commit` is a placeholder, answered with the request's Worktree's actual HEAD
    /// instead, like ``workerCompleted``'s `commit` (P15.3).
    case reviewerChangesRequested = "reviewer-changes-requested.json"
    /// Zero bytes: the Codex SIGTERM failure mode. Must fail ``ResultFile`` validation.
    case workerEmpty = "worker-empty.json"
    /// Truncated JSON. Must fail ``ResultFile`` validation.
    case workerMalformed = "worker-malformed.json"
    /// The author Act's selection answers (roadmap P9.11). A rehearsal Night fixtures the selection and
    /// breakdown dispatches by this same rule. The selected Feature names the repository
    /// `fixture-backend`, which must be one of the Project's working repositories or ``FeatureSelection``
    /// halts it as `contract-outside-project`: a test using it configures a Project with that repo name.
    case selectionSelected = "selection-selected.json"
    case selectionNoSelectableFeature = "selection-no-selectable-feature.json"
    case selectionFailed = "selection-failed.json"
    /// One Card in `fixture-backend` under Kind `impl.fixture`, citing `fixture-epic/fixture-story`; it
    /// pairs with ``selectionSelected``.
    case breakdownDrafted = "breakdown-drafted.json"
    /// Like ``selectionSelected``, but names two repositories — `fixture-backend` and `fixture-web` —
    /// so a rehearsal Night can exercise a Card carrying a Contract that crosses repositories. Pairs
    /// with ``breakdownDraftedWithContract``.
    case selectionSelectedWithContract = "selection-selected-with-contract.json"
    /// Two Cards, both Kind `impl.fixture`, citing `fixture-epic/fixture-story`: one in `fixture-backend`
    /// with no contracts, and one in `fixture-web` whose single contract cites
    /// `contracts/fixture-api.json` from `fixture-backend`'s mainline — a rehearsal Night's Transcription
    /// Block exercise. Pairs with ``selectionSelectedWithContract``.
    case breakdownDraftedWithContract = "breakdown-drafted-with-contract.json"
    /// Selects `fixture-backend` and `fixture-web`, like ``selectionSelectedWithContract``, but the file's
    /// `adopted_card_issue_ids` is always `[]`: ``RehearsalDispatch`` synthesizes it from the request's
    /// ``AuthoringInstruction/adoptionCandidates`` (P15.3), so a rehearsal Night can exercise adoption
    /// without knowing a live Card's issue id in advance. Pairs with ``breakdownDraftedWithContract``.
    case selectionSelectedAdopting = "selection-selected-adopting.json"
    /// Like ``selectionSelectedWithContract``, but names three repositories — `fixture-backend`,
    /// `fixture-web` and `fixture-mobile` — for a rehearsal Night exercising a three-repository Feature.
    /// No adoptions. Pairs with ``breakdownDraftedThreeRepos``.
    case selectionSelectedThreeRepos = "selection-selected-three-repos.json"
    /// Five Cards across three repositories, citing two Feature-level Definition of Done clauses:
    /// `fixture-backend` × 3 (no contracts), `fixture-web` × 1 (one contract, citing
    /// `contracts/fixture-api.json` from `fixture-backend`'s mainline, like
    /// ``breakdownDraftedWithContract``'s web Card), `fixture-mobile` × 1 (no contracts). Each Card's
    /// authored order within its repository is the file's order. Pairs with ``selectionSelectedThreeRepos``.
    case breakdownDraftedThreeRepos = "breakdown-drafted-three-repos.json"
    /// The land Act's verifier answers (roadmap P10.5). The file's single clause is a placeholder:
    /// the fixture cannot know the Feature's clause ids in advance, so ``RehearsalDispatch`` answers a
    /// `verifierReported` request by reporting every clause the request names as `met`.
    case verifierReported = "verifier-reported.json"
    case verifierFailed = "verifier-failed.json"

    public var pass: RunPass {
        switch self {
        case .architectPlanned, .architectFailed:
            .architect
        case .workerCompleted, .workerQuestion, .workerFailed, .workerEmpty, .workerMalformed:
            .worker
        case .reviewerApproved, .reviewerChangesRequested:
            .reviewer
        case .selectionSelected, .selectionNoSelectableFeature, .selectionFailed, .selectionSelectedWithContract,
             .selectionSelectedAdopting, .selectionSelectedThreeRepos:
            .selection
        case .breakdownDrafted, .breakdownDraftedWithContract, .breakdownDraftedThreeRepos:
            .breakdown
        case .verifierReported, .verifierFailed:
            .verifier
        }
    }

    /// This fixture's exact bytes, embedded in the binary (``contents``, in
    /// `RehearsalResultFixtures+Contents.swift`) — never read from a resource bundle: a command-line
    /// tool carries none at run time, so `yh` itself could never have read one from disk.
    public func data() -> Data {
        Data(contents.utf8)
    }

    /// Decodes this fixture against ``ResultFile``, as the engine would decode a live result file.
    public func decode() throws -> DispatchResult {
        try ResultFile.decode(data(), expecting: pass)
    }

    /// What a rehearsal run of this fixture yields. A rehearsal Night never spawns a CLI: the
    /// fixture stands in for the result file of a run that exited 0, and the same dual-key
    /// contract applies, so `workerEmpty` and `workerMalformed` are Crashed-Unknown exactly as a
    /// live run would be.
    public func outcome() -> RunOutcome {
        RunOutcome.classify(end: .exited(status: 0), resultFile: data(), pass: pass)
    }
}
