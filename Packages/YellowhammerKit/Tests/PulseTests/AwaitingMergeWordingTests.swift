import Config
import Domain
import Foundation
import Pulse
import Testing

@Suite("Awaiting merge wording")
struct AwaitingMergeWordingTests {
    private func feature(merged: Bool) -> AwaitingMergeFeature {
        AwaitingMergeFeature(
            id: "F", landedTonight: false, repositories: [AwaitingMergeRepository(repo: "a", merged: merged)]
        )
    }

    @Test func countTextStatesTheLimitAsALimit() {
        let stack = UnmergedFeatureStack(features: [feature(merged: false)], unmergedFeaturesMax: 3)
        #expect(stack.countText == "1 awaiting merge \u{00B7} stack limit 3")
        #expect(UnmergedFeatureStack(features: [feature(merged: false)]).countText == "1 awaiting merge")
    }

    @Test func limitHelpCarriesTheBoundsExplanation() throws {
        let field = try #require(Bounds.fields.first { $0.key == "unmerged_features_max" })
        let help = UnmergedFeatureStack.empty.limitHelp
        #expect(help.contains(field.explanation))
        #expect(help.contains("unmerged_features_max"))
    }

    @Test func fullNoteOnlyWhenFull() {
        let one = [feature(merged: false)]
        #expect(UnmergedFeatureStack(features: one, unmergedFeaturesMax: 2).fullNote == nil)
        #expect(UnmergedFeatureStack(features: one, unmergedFeaturesMax: 1).fullNote != nil)
        #expect(UnmergedFeatureStack(features: one + one, unmergedFeaturesMax: 1).fullNote != nil)
        #expect(UnmergedFeatureStack(features: one).fullNote == nil)
    }

    @Test func mergedTextNamesFeatureBranches() {
        #expect(feature(merged: false).mergedText == "0 of 1 Feature Branches merged")
        #expect(feature(merged: true).mergedText == "1 of 1 Feature Branches merged")
    }

    @Test func mainlineWording() {
        #expect(AwaitingMergeRepository(repo: "a", merged: true).mainlineText == "in mainline")
        #expect(AwaitingMergeRepository(repo: "a", merged: false).mainlineText == "not in mainline")
        #expect(
            AwaitingMergeRepository(repo: "a", merged: true).mainlineHelp
                != AwaitingMergeRepository(repo: "a", merged: false).mainlineHelp
        )
    }

    @Test func legendsAreNonEmptyAndDistinct() {
        let rollUps = RollUpState.allCases.map(\.help)
        #expect(rollUps.allSatisfy { !$0.isEmpty })
        #expect(Set(rollUps).count == rollUps.count)
        let lanes = LaneState.allCases.map(\.help)
        #expect(lanes.allSatisfy { !$0.isEmpty })
        #expect(Set(lanes).count == lanes.count)
        #expect(FeatureInFlight.stateHelp("returned") != FeatureInFlight.stateHelp("selected"))
    }

    @Test func laneCardsText() {
        let lane = RepoLaneSnapshot(repo: "a", state: .running, cardsDone: 1, cardsTotal: 3, pullRequest: nil)
        #expect(lane.cardsText == "1/3 Cards")
        #expect(lane.cardsHelp == "1 of 3 Cards in this Repo Lane are done.")
    }

    @Test func stackFullSkipCountText() {
        let skip = StackFullSkip(features: ["A-1", "A-2"], unmergedFeaturesMax: 2, at: Date(), count: 1)
        #expect(skip.countText == "2 awaiting merge \u{00B7} stack limit 2")
    }
}
