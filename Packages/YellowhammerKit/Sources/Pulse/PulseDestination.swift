import Foundation

// MARK: - Selection and ways out

/// What the Inspector shows. Selecting one of these opens its detail beside the Pulse, never as a
/// pushed screen.
public enum PulseSelection: Hashable, Sendable {
    case card(String)
    case feature(String)
    case attempt(String)
    case repo(String)
    /// A Night's account, by the Night's row id in its own Project's Journal (OQ158 ruling item 14). Unlike
    /// the others it also takes the main area: the Night's Journal events, along a playhead, replace the Pulse
    /// until the selection is cleared, and the Inspector carries the Night's facts and its way out to the
    /// Night Card.
    case night(Int64)
}

/// Where a Pulse element leads. None of these is a triage gesture: each opens something, and the
/// gesture itself stays in Linear or GitHub.
///
/// `nightCard`, `linearIssue` and `pullRequest` carry the URL the Journal recorded and open it in the
/// default browser, or the vendor's app, through `openURL`. Authoring decisions without a recorded
/// URL may use Linear's canonical issue URL from a validated recorded UUID.
public enum PulseDestination: Hashable, Sendable {
    case inspector(PulseSelection)
    /// A Night's account, by the Night's row id, opened with its playhead at `at`: where a Failure Notice starts.
    /// `.inspector(.night(id))` opens the same account on its first problem.
    case nightAccount(Int64, at: Date)
    case nightCard(URL)
    case settings
    /// The Settings window's Boards pane, where a Board Connection or Operator identity flag is fixed: its
    /// Linear section lists the workspaces.
    case linearWorkspaces
    /// The Settings window's Code Hosting section, where a refused Code Hosting Connection is fixed.
    case codeHosting
    case pullRequest(URL)
    case linearIssue(URL)
}
