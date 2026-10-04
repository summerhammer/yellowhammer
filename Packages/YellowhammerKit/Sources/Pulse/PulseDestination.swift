import Foundation

// MARK: - Selection and ways out

/// What the Inspector shows. Selecting one of these opens its detail beside the Pulse, never as a
/// pushed screen.
public enum PulseSelection: Hashable, Sendable {
    case card(String)
    case feature(String)
    case attempt(String)
    case repo(String)
}

/// Where a Pulse element leads. None of these is a triage gesture: each opens something, and the
/// gesture itself stays in Linear or GitHub.
///
/// `nightCard`, `linearIssue` and `pullRequest` carry the URL the Journal recorded and open it in the
/// default browser, or the vendor's app, through `openURL`. The app composes no URL of its own.
public enum PulseDestination: Hashable, Sendable {
    case inspector(PulseSelection)
    case nightCard(URL)
    case settings
    /// The Settings window's Boards pane, where an App Installation or Operator identity flag is fixed: its
    /// Linear section lists the workspaces.
    case linearWorkspaces
    case pullRequest(URL)
    case linearIssue(URL)
}
