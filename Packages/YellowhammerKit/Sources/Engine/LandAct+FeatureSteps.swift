import Domain
import Journal

/// What running Verification came to, before any pull request is opened (P10.5).
enum LandVerificationOutcome {
    /// No Verification seam is wired: the three Feature steps are recorded `.notWired` after the lanes.
    case notWired
    /// A lane faulted before Verification could run; it ran nothing and recorded nothing.
    case didNotRun
    /// The seam threw: an engine fault, recorded and returned.
    case faulted(String)
    case verdict(VerificationVerdict)

    /// Why the pull requests must not be opened; nil when they may be (Verification completed, or none
    /// is wired).
    var gate: String? {
        switch self {
        case .notWired, .verdict: nil
        case .didNotRun, .faulted: "Verification did not complete"
        }
    }
}

extension LandAct {
    /// Runs Verification (P10.5) once every lane's first phase is done and none faulted, so its report
    /// exists before any pull request body is written.
    func runVerification(
        feature: FeatureRecord, cycleID: Int64, firstPhaseFailed: Bool, context: ActContext
    ) async -> LandVerificationOutcome {
        guard let verification else { return .notWired }
        guard !firstPhaseFailed else { return .didNotRun }
        do {
            let verdict = try await verification.verify(
                LandActFeatureContext(act: context, feature: feature, cycleID: cycleID)
            )
            record(.completed(), step: .verification, repository: nil, context: context)
            return .verdict(verdict)
        } catch {
            let description = String(describing: error)
            record(.faulted(description), step: .verification, repository: nil, context: context)
            return .faulted(description)
        }
    }

    /// The Feature-scoped steps after the lanes and their pull requests, run only when nothing faulted:
    /// by Verification's verdict, return the Feature or archive the Cycle, never both. A nil Verification
    /// seam records all three steps `.notWired` and calls neither return nor archive. Returns a fault
    /// description when a wired seam throws, nil otherwise.
    func runFeatureSteps(
        verification outcome: LandVerificationOutcome, feature: FeatureRecord, cycleID: Int64, context: ActContext
    ) async -> String? {
        let featureContext = LandActFeatureContext(act: context, feature: feature, cycleID: cycleID)

        let verdict: VerificationVerdict
        switch outcome {
        case .notWired:
            record(.notWired(), step: .verification, repository: nil, context: context)
            record(.notWired(), step: .returnFeature, repository: nil, context: context)
            record(.notWired(), step: .archiveCycle, repository: nil, context: context)
            return nil
        case .didNotRun, .faulted:
            return nil
        case .verdict(let judged):
            verdict = judged
        }

        if verdict.allClausesMet {
            record(.skipped("all clauses met"), step: .returnFeature, repository: nil, context: context)
            return await runArchiveCycle(featureContext, context: context)
        }
        record(.skipped("clauses unmet"), step: .archiveCycle, repository: nil, context: context)
        return await runReturnFeature(featureContext, verdict: verdict, context: context)
    }

    private func runArchiveCycle(_ featureContext: LandActFeatureContext, context: ActContext) async -> String? {
        guard let archiveCycle else {
            record(.notWired(), step: .archiveCycle, repository: nil, context: context)
            return nil
        }
        do {
            try await archiveCycle.archive(featureContext)
            record(.completed(), step: .archiveCycle, repository: nil, context: context)
            return nil
        } catch {
            let description = String(describing: error)
            record(.faulted(description), step: .archiveCycle, repository: nil, context: context)
            return description
        }
    }

    private func runReturnFeature(
        _ featureContext: LandActFeatureContext, verdict: VerificationVerdict, context: ActContext
    ) async -> String? {
        guard let returnFeature else {
            record(.notWired(), step: .returnFeature, repository: nil, context: context)
            return nil
        }
        do {
            try await returnFeature.returnFeature(featureContext, verdict: verdict)
            record(.completed(), step: .returnFeature, repository: nil, context: context)
            return nil
        } catch {
            let description = String(describing: error)
            record(.faulted(description), step: .returnFeature, repository: nil, context: context)
            return description
        }
    }
}
