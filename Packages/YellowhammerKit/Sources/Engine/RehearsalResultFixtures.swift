import Domain
import Foundation

/// The result files shipped with the engine for rehearsal Nights. A rehearsal Night never spawns a
/// CLI (spec: three environments only — Development, Rehearsal, Production); its result files come
/// from these fixtures instead, so both the happy paths and the dual-key completion failure modes
/// (an empty or truncated file) are exercisable without a live CLI.
public enum RehearsalResultFixture: String, CaseIterable, Sendable {
    case architectPlanned = "architect-planned.json"
    case architectFailed = "architect-failed.json"
    case workerCompleted = "worker-completed.json"
    case workerQuestion = "worker-question.json"
    case workerFailed = "worker-failed.json"
    case reviewerApproved = "reviewer-approved.json"
    case reviewerChangesRequested = "reviewer-changes-requested.json"
    /// Zero bytes: the Codex SIGTERM failure mode. Must fail ``ResultFile`` validation.
    case workerEmpty = "worker-empty.json"
    /// Truncated JSON. Must fail ``ResultFile`` validation.
    case workerMalformed = "worker-malformed.json"

    public var pass: RunPass {
        switch self {
        case .architectPlanned, .architectFailed:
            .architect
        case .workerCompleted, .workerQuestion, .workerFailed, .workerEmpty, .workerMalformed:
            .worker
        case .reviewerApproved, .reviewerChangesRequested:
            .reviewer
        }
    }

    /// The fixture's location in the `Engine` module's resource bundle.
    public var url: URL {
        let fileName = (rawValue as NSString).deletingPathExtension
        let fileExtension = (rawValue as NSString).pathExtension
        guard
            let url = Bundle.module.url(
                forResource: fileName,
                withExtension: fileExtension,
                subdirectory: "Fixtures/RehearsalResults"
            )
        else {
            preconditionFailure("RehearsalResultFixture(\(rawValue)) is missing from the Engine resource bundle")
        }
        return url
    }

    public func data() throws -> Data {
        try Data(contentsOf: url)
    }

    /// Decodes this fixture against ``ResultFile``, as the engine would decode a live result file.
    public func decode() throws -> DispatchResult {
        try ResultFile.decode(try data(), expecting: pass)
    }

    /// What a rehearsal run of this fixture yields. A rehearsal Night never spawns a CLI: the
    /// fixture stands in for the result file of a run that exited 0, and the same dual-key
    /// contract applies, so `workerEmpty` and `workerMalformed` are Crashed-Unknown exactly as a
    /// live run would be.
    public func outcome() -> RunOutcome {
        RunOutcome.classify(end: .exited(status: 0), resultFileAt: url, pass: pass)
    }
}
