import ArgumentParser
import Config
import Domain
import Engine
import Foundation
import Repositories

extension ActCommand {
    /// This Act's own work. Split out of `makeInvocation` to keep that function within its length limit.
    func work(
        mode: NightMode, configuration: Configuration, project: ProjectConfiguration, configurationDirectory: URL,
        narrativeScrub: @escaping @Sendable () -> NarrativeScrub
    ) throws -> EngineInvocation.ActWork {
        switch Self.act {
        case .land:
            // The Repo Lane merge test (P10.3) is pure local git and records conflicts without gating
            // landing. Push (P10.2), Verification (P10.5), open pull request (P10.4), returning the
            // Feature (P10.6) and archiving the Cycle (P10.7) are all wired, and run in that order so
            // the pull request body carries the clause report.
            return LandAct(
                mergeTest: FeatureBranchLaneMergeTest(),
                push: LandBinding.push(configuration: configuration, project: project),
                openPullRequest: LandBinding.pullRequest(
                    configuration: configuration, project: project, scrub: narrativeScrub
                ),
                verification: try LandBinding.verification(
                    mode: mode, configuration: configuration, project: project,
                    configurationDirectory: configurationDirectory, resultFixtures: resultFixtures
                ),
                returnFeature: FeatureReturn(),
                archiveCycle: CycleArchive()
            ).work
        case .author:
            // Selection and breakdown are agent CLI dispatches routed through the ordinary Routing Table
            // under the reserved authoring Kind (P9.11); `AuthoringBinding` wires both, and a Rehearsal
            // Night answers them from the shipped result fixtures. The closure seam (P10.8) is wired to
            // the real `FeatureMergeClosure`: a fully-merged predecessor or in-flight landed Feature is
            // closed unverified, not just observed. The settle seam (P10.9) is wired to the real
            // `FeatureSettleGesture`, applied to whatever Feature the merge closure left in flight.
            return AuthorAct(
                predecessorGate: PredecessorAncestryGate(closure: FeatureMergeClosure()),
                authoring: try AuthoringBinding.authoring(
                    mode: mode, configuration: configuration, project: project,
                    configurationDirectory: configurationDirectory, resultFixtures: resultFixtures
                ),
                settle: FeatureSettleGesture(),
                unansweredNightsMax: project.bounds.unansweredNightsMax
            ).work
        case .build:
            let cardRunner = try CardRunBinding.cardRunner(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory, resultFixtures: resultFixtures
            )
            return BuildAct(
                cardRunner: cardRunner,
                readiness: ReadinessCheck(provenance: ProvenanceDiffTester(), citations: MainlineReader()),
                // Bound in both modes (P8.10): a rehearsal Night writes no result files, so this simply
                // finds none, and the lease-reclaim sweep falls to the event log and Crashed-Unknown.
                resultReader: RunDirectoryResultReader(
                    runsDirectory: CLIAdapterDispatch.runsDirectory(
                        configurationDirectory: configurationDirectory, projectID: project.id
                    )
                ),
                wipCommitMessage: project.wipCommit,
                unansweredNightsMax: project.bounds.unansweredNightsMax
            ).work
        }
    }
}
