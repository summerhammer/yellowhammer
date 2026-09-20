import Domain
import Journal

extension LandAct {
    /// The Feature-scoped steps, run only when no lane faulted: Verification, then — depending on its
    /// verdict — return the Feature or archive the Cycle, never both. A nil Verification seam records
    /// all three steps `.notWired` and calls neither return nor archive. Returns a fault description
    /// when a wired seam throws, nil otherwise.
    func runFeatureSteps(feature: FeatureRecord, cycleID: Int64, context: ActContext) async -> String? {
        let featureContext = LandActFeatureContext(act: context, feature: feature, cycleID: cycleID)

        guard let verification else {
            record(.notWired(), step: .verification, repository: nil, context: context)
            record(.notWired(), step: .returnFeature, repository: nil, context: context)
            record(.notWired(), step: .archiveCycle, repository: nil, context: context)
            return nil
        }

        let verdict: VerificationVerdict
        do {
            verdict = try await verification.verify(featureContext)
        } catch {
            let description = String(describing: error)
            record(.faulted(description), step: .verification, repository: nil, context: context)
            return description
        }
        record(.completed(), step: .verification, repository: nil, context: context)

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
