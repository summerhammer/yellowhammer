/// What the selection pass decided (roadmap P9.11; spec: feature-authoring/select-the-next-feature):
/// the existing ``FeatureSelectionOutcome`` cases, plus `failed` — the pass could not judge at all,
/// which is a failure of the Route, not a finding about the specification.
public enum SelectionResultOutcome: Equatable, Sendable {
    case selected(SelectedFeature)
    case noSelectableFeature
    /// Only the causes a selector itself finds: no backward-compatible seam, undetermined repositories,
    /// a repository outside the Project. An unreadable contract is found later, by the transcription.
    case halted(feature: FeatureName, cause: AuthoringHaltCause)
    case failed(reason: String)
}

/// The selection pass's result-file contents (everything after the envelope's `schema`/`version`).
public struct SelectionResult: Equatable, Sendable {
    public let outcome: SelectionResultOutcome

    public init(outcome: SelectionResultOutcome) {
        self.outcome = outcome
    }

    /// The finding for ``FeatureSelecting``; nil when the pass failed.
    public var featureSelectionOutcome: FeatureSelectionOutcome? {
        switch outcome {
        case .selected(let feature): .selected(feature)
        case .noSelectableFeature: .noSelectableFeature
        case .halted(let feature, let cause): .halted(feature: feature, cause: cause)
        case .failed: nil
        }
    }
}

/// What the breakdown pass decided (roadmap P9.11): the full ``FeatureBreakdown``, or that it could not
/// produce one.
public enum BreakdownResultOutcome: Equatable, Sendable {
    case drafted(FeatureBreakdown)
    case failed(reason: String)
}

/// The breakdown pass's result-file contents (everything after the envelope's `schema`/`version`).
public struct BreakdownResult: Equatable, Sendable {
    public let outcome: BreakdownResultOutcome

    public init(outcome: BreakdownResultOutcome) {
        self.outcome = outcome
    }
}

extension DispatchResult {
    /// The reason an authoring pass reported `failed`, which is a capability failure of its Route (the
    /// engine tries the entry's next fallback); nil for a completed authoring pass and for every Card pass.
    public var authoringFailureReason: String? {
        switch self {
        case .selection(let result):
            if case .failed(let reason) = result.outcome { reason } else { nil }
        case .breakdown(let result):
            if case .failed(let reason) = result.outcome { reason } else { nil }
        case .architect, .worker, .reviewer, .verifier:
            nil
        }
    }
}
