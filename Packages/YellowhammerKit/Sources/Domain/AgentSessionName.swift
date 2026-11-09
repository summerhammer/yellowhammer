import Foundation

/// Composes the name string for an agent CLI session run by Yellowhammer (AC named-session).
///
/// Templates:
/// - Work Card pass (architect, worker, reviewer):
///   `YH · <project> · <card> · <repo> · <pass> · Round <m> · Attempt <n>`
/// - Selection or breakdown pass:
///   `YH · <project> · <pass>`
/// - Verifier pass:
///   `YH · <project> · <feature> · verifier`
public enum AgentSessionName: Sendable, Equatable {
    public static let prefix = "YH"
    public static let separator = " · "

    // swiftlint:disable:next function_parameter_count
    public static func card(
        project: String,
        card: String,
        repo: String,
        pass: RunPass,
        round: Int,
        attempt: Int
    ) -> String {
        [
            prefix,
            project,
            card,
            repo,
            pass.rawValue,
            "Round \(round)",
            "Attempt \(attempt)"
        ].joined(separator: separator)
    }

    public static func authoring(
        project: String,
        pass: RunPass
    ) -> String {
        [
            prefix,
            project,
            pass.rawValue
        ].joined(separator: separator)
    }

    public static func selection(project: String) -> String {
        authoring(project: project, pass: .selection)
    }

    public static func breakdown(project: String) -> String {
        authoring(project: project, pass: .breakdown)
    }

    public static func verifier(
        project: String,
        feature: String
    ) -> String {
        [
            prefix,
            project,
            feature,
            RunPass.verifier.rawValue
        ].joined(separator: separator)
    }
}
