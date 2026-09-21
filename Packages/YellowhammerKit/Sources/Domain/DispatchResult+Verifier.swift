/// How one Definition of Done clause fared in Verification (roadmap P10.5; spec:
/// verification/verify-a-feature-clause-by-clause). `met` and `unmet` are judgements — the verifier's,
/// or the engine's for a clause whose Card did not complete. `unresolved` is only ever the engine's: the
/// clause's Spec Citation no longer resolves, which is work for the Specification Author, not unfinished
/// code. The verifier is never asked to say it.
public enum ClauseVerdict: String, CaseIterable, Equatable, Sendable {
    case met
    case unmet
    case unresolved
}

/// One clause the verifier judged. Clause ids are unique only within their issue, so the identity is the
/// `(issueID, cid)` pair.
public struct VerifiedClause: Equatable, Sendable {
    public let cid: String
    public let issueID: String
    /// Only ``ClauseVerdict/met`` or ``ClauseVerdict/unmet``.
    public let verdict: ClauseVerdict
    /// What the verifier looked at in the finished code, non-empty.
    public let whatWasChecked: String
    /// The reading of the clause the verdict was reached under, non-empty.
    public let interpretation: String

    public init(cid: String, issueID: String, verdict: ClauseVerdict, whatWasChecked: String, interpretation: String) {
        self.cid = cid
        self.issueID = issueID
        self.verdict = verdict
        self.whatWasChecked = whatWasChecked
        self.interpretation = interpretation
    }
}

/// What the verifier pass decided: a verdict for each clause it was given, or that it could not judge.
public enum VerifierOutcome: Equatable, Sendable {
    case reported(clauses: [VerifiedClause])
    case failed(reason: String)
}

/// The verifier pass's result-file contents (everything after the envelope's `schema`/`version`).
public struct VerifierResult: Equatable, Sendable {
    public let outcome: VerifierOutcome

    public init(outcome: VerifierOutcome) {
        self.outcome = outcome
    }
}

extension DispatchResult {
    /// The reason a verifier pass reported `failed` — a capability failure of its Route; nil otherwise.
    public var verifierFailureReason: String? {
        if case .verifier(let result) = self, case .failed(let reason) = result.outcome { reason } else { nil }
    }
}
