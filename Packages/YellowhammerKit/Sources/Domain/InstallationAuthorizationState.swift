/// Whether one App Installation's authorization is usable, as `yh doctor --json` reports it in a row's
/// `authorization` field. The app gates "Remove anyway…" on `.refused`, so the CLI's gate
/// (`yh config remove-installation --orphan-projects`) and the app can never disagree.
public enum InstallationAuthorizationState: String, Codable, Equatable, Sendable {
    /// Linear accepted the installation's token pair.
    case authorized
    /// Permanently refused: no token pair in the Keychain, or Linear refused it.
    case refused
    /// Could not be judged now (Keychain unreadable, Linear unreachable, an unconfirmed answer); retry.
    case unreachable
}

extension DoctorFindingRow {
    /// The authorization state `rows` report for `installation`: the `authorization` row's, else the
    /// token-pair `installation` row's; nil when no row carries one.
    public static func authorizationState(
        in rows: [DoctorFindingRow], installation: String
    ) -> InstallationAuthorizationState? {
        let own = rows.filter { $0.installation == installation }
        let row = own.first { $0.subject == "authorization" && $0.authorization != nil }
            ?? own.first { $0.subject == "installation" && $0.authorization != nil }
        return row?.authorization.flatMap(InstallationAuthorizationState.init(rawValue:))
    }
}
