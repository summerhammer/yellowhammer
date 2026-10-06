import Config
import Domain

/// What the probe found for one Board Connection, naming WHICH case it hit. Only `.refused` is a
/// permanent refusal; everything else that is not `.authorized` is "cannot judge now" and must never
/// unlock `yh config remove-board-connection --orphan-projects`.
enum InstallationAuthorization: Equatable, Sendable {
    case authorized
    case refused(Refusal)
    case unreachable(Reason)

    enum Refusal: Equatable, Sendable {
        /// The Keychain item is absent (`errSecItemNotFound`): no live call was made.
        case keychainAbsent
        /// Linear answered `notAuthenticated`: revoked, or its sign-in expired.
        case linearRefused
    }

    enum Reason: Equatable, Sendable {
        /// The Keychain item may exist but could not be read (locked Keychain, …): no live call was made.
        case keychainUnreadable(String)
        case linearUnreachable
        /// Linear answered something other than success or a clear refusal (rate limit, forbidden, …).
        case unconfirmed(String)
    }

    /// The state `yh doctor --json` reports.
    var state: InstallationAuthorizationState {
        switch self {
        case .authorized: .authorized
        case .refused: .refused
        case .unreachable: .unreachable
        }
    }
}

/// The one place that decides whether a Board Connection's authorization is usable, shared by `yh doctor`
/// and `yh config remove-board-connection --orphan-projects`.
struct InstallationAuthorizationProbe {
    let credentials: any SetupCredentialStore
    let bindProvisioning: (LinearInstallation, String) -> any BoardProvisioning

    struct Result {
        let authorization: InstallationAuthorization
        /// The workspace members the live call returned; empty unless `.authorized`.
        let members: [BoardMember]
        /// Whether the board was asked at all (false when the Keychain item decided the answer).
        let askedLinear: Bool
    }

    func check(_ installation: LinearInstallation) async -> Result {
        switch credentials.presence(of: installation.credential) {
        case .absent:
            return Result(authorization: .refused(.keychainAbsent), members: [], askedLinear: false)
        case .unreadable(let detail):
            return Result(
                authorization: .unreachable(.keychainUnreadable(detail)), members: [], askedLinear: false
            )
        case .present:
            break
        }
        do {
            let members = try await bindProvisioning(installation, "").workspaceMembers()
            return Result(authorization: .authorized, members: members, askedLinear: true)
        } catch .notAuthenticated {
            return Result(authorization: .refused(.linearRefused), members: [], askedLinear: true)
        } catch .unreachable {
            return Result(authorization: .unreachable(.linearUnreachable), members: [], askedLinear: true)
        } catch {
            return Result(authorization: .unreachable(.unconfirmed("\(error)")), members: [], askedLinear: true)
        }
    }
}
