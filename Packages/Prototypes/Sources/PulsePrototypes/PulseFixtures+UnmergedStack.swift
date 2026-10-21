#if DEBUG
import Domain
import Pulse
import Foundation

// Fixtures for the Unmerged Feature Stack U: landed Features still awaiting merge, the Bound, and a Night that
// authored nothing because U was full. Invented values, like the rest of the fixtures.

extension PulseFixtures {
    /// The Project's `unmerged_features_max` Bound in every stack scenario.
    static let unmergedFeaturesMax = 3

    /// One pushed repository of a Feature in U; its pull request number is derived from `number`.
    static func awaitingRepository(
        _ repo: String, merged: Bool, number: Int, stackedOn: String? = nil
    ) -> AwaitingMergeRepository {
        AwaitingMergeRepository(
            repo: repo,
            merged: merged,
            branch: "yh/\(repo)/feature-\(number)",
            pullRequest: pullRequest(repo: repo, number: number, state: merged ? .merged : .open),
            stackedOn: stackedOn
        )
    }

    static func awaitingFeature(
        _ identifier: String, landedTonight: Bool, repositories: [AwaitingMergeRepository]
    ) -> AwaitingMergeFeature {
        AwaitingMergeFeature(
            id: identifier, issueIDForDisplay: identifier, link: issueLink(identifier),
            landedTonight: landedTonight, repositories: repositories
        )
    }

    /// YH-118 landed last Night with 1 of 2 repositories merged.
    static let landedLastNight = awaitingFeature("YH-118", landedTonight: false, repositories: [
        awaitingRepository("yellowhammer", merged: true, number: 201),
        awaitingRepository("yellowhammer-site", merged: false, number: 74)
    ])

    /// YH-120 landed tonight, stacked on YH-118 in `yellowhammer`.
    static let landedTonightStacked = awaitingFeature("YH-120", landedTonight: true, repositories: [
        awaitingRepository("yellowhammer", merged: false, number: 214, stackedOn: "YH-118"),
        awaitingRepository("yellowhammer-site", merged: false, number: 88)
    ])

    /// Landed mid-Night with the in-flight slot free: U = 2 of 3.
    static func landedMidNightPulse(from pulse: PulseSnapshot) -> PulseSnapshot {
        var pulse = pulse
        pulse.feature = nil
        pulse.unmergedFeatures = UnmergedFeatureStack(
            features: [landedLastNight, landedTonightStacked], unmergedFeaturesMax: unmergedFeaturesMax
        )
        pulse.night = night(.done, verdict: "Feature YH-120 landed — awaiting merge")
        return pulse
    }

    /// Nothing in flight and U at its Bound: authoring waits, and the Night says so without failing.
    static func stackFullPulse(from pulse: PulseSnapshot) -> PulseSnapshot {
        var pulse = pulse
        pulse.feature = nil
        let oldest = awaitingFeature("YH-116", landedTonight: false, repositories: [
            awaitingRepository("yellowhammer", merged: false, number: 190)
        ])
        pulse.unmergedFeatures = UnmergedFeatureStack(
            features: [oldest, landedLastNight, landedTonightStacked], unmergedFeaturesMax: unmergedFeaturesMax
        )
        var tonight = night(.done, verdict: "did not advance — idle")
        tonight.stackFullSkip = StackFullSkip(
            features: ["YH-116", "YH-118", "YH-120"], unmergedFeaturesMax: unmergedFeaturesMax,
            at: time(3, 0), count: 4
        )
        pulse.night = tonight
        return pulse
    }

    /// The running Feature built over the stack: its base in `yellowhammer` is YH-118's landed tip.
    static func inFlightOverStackPulse() -> PulseSnapshot {
        var pulse = runningPulse
        pulse.feature = feature(rollup: .running)
        pulse.feature?.stackedOn = ["yellowhammer": "YH-118"]
        pulse.unmergedFeatures = UnmergedFeatureStack(
            features: [landedLastNight], unmergedFeaturesMax: unmergedFeaturesMax
        )
        return pulse
    }
}
#endif
