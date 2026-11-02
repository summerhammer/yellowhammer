import Config
import Domain
import Foundation
import Journal

// The words the Pulse puts on counts and badges, and the tooltips that explain them. They live here, not in the
// app's views, so a unit test can hold them.

extension UnmergedFeatureStack {
    /// `1 awaiting merge · stack limit 3`, or `1 awaiting merge` while the Bound was not read. The limit is a
    /// ceiling, never a total.
    public var countText: String {
        guard let unmergedFeaturesMax else { return "\(count) awaiting merge" }
        return "\(count) awaiting merge \u{00B7} stack limit \(unmergedFeaturesMax)"
    }

    /// What the stack limit is and where it is set, from the Bound's own explanation.
    public var limitHelp: String {
        let key = "unmerged_features_max"
        let explanation = Bounds.fields.first { $0.key == key }?.explanation ?? ""
        return "Stack limit: `\(key)` in the Project's configuration. \(explanation)"
    }

    /// Non-nil only when the stack is full.
    public var fullNote: String? {
        isFull ? "Stack full: the author Act authors nothing until a merge is observed." : nil
    }
}

extension AwaitingMergeFeature {
    /// `0 of 1 Feature Branches merged`: the engine's standing-line wording.
    public var mergedText: String { "\(mergedCount) of \(pushedCount) Feature Branches merged" }

    public var mergedHelp: String {
        "How many of the Feature Branches this Feature pushed have an Observed Merge into mainline."
    }

    public static let landedTonightHelp =
        "This Feature's Cycle landed during the Night the Pulse shows. A Night runs across midnight, "
        + "so this includes a landing after 00:00."
}

extension AwaitingMergeRepository {
    public var mainlineText: String { merged ? "in mainline" : "not in mainline" }

    public var mainlineHelp: String {
        merged
            ? "An Observed Merge is recorded: this Feature Branch is in mainline."
            : "No merge of this Feature Branch into mainline has been observed yet. "
                + "Merging its pull request by any method releases it."
    }
}

extension StackFullSkip {
    /// `2 awaiting merge · stack limit 2`.
    public var countText: String {
        "\(features.count) awaiting merge \u{00B7} stack limit \(unmergedFeaturesMax)"
    }
}

extension RollUpState {
    /// The tooltip for the Roll-up word. It is the Feature's derived word, not a Card state.
    public var help: String {
        switch self {
        case .authoring:
            "Roll-up: the Feature's Cards are being authored."
        case .running:
            "Roll-up: lanes are still running, and no Card waits on you or is Blocked."
        case .waiting:
            "Roll-up: a Card waits on you while lanes run, or every Card is done but Verification has not passed."
        case .blocked:
            "Roll-up: lanes are still running and a Card is Blocked."
        case .partial:
            "Roll-up: every lane finished and pushed with a Card still Blocked or Waiting on You. "
                + "It never means anything was merged."
        case .verified:
            "Roll-up: every Card is done and Verification passed."
        }
    }
}

extension FeatureInFlight {
    /// The tooltip for the Journal's own Feature state.
    public static func stateHelp(_ state: String) -> String {
        if state == FeatureRecord.returnedState {
            return "returned: Verification found unmet or unchecked clauses and handed the Feature back to you. "
                + "The Roll-up beside it says what its Cards read."
        }
        return "The Feature's state as the Journal records it."
    }
}

extension LaneState {
    public var help: String {
        switch self {
        case .idle: "Lane state: no Card of this Repo Lane is running."
        case .running: "Lane state: a Card of this Repo Lane is running."
        case .blocked: "Lane state: a Card of this Repo Lane is Blocked."
        case .waitingOnYou: "Lane state: a Card of this Repo Lane waits on you."
        case .landed: "Lane state: this Repo Lane landed and was pushed."
        }
    }
}

extension RepoLaneSnapshot {
    /// `1/3 Cards`.
    public var cardsText: String { "\(cardsDone)/\(cardsTotal) Cards" }

    public var cardsHelp: String { "\(cardsDone) of \(cardsTotal) Cards in this Repo Lane are done." }
}
