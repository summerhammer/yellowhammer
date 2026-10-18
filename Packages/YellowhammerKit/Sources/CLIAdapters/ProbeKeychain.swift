import Foundation
import Subprocess
import System

/// The throwaway Keychain item the state-containment dispatch tries to read (issue #557). Never one
/// of the Operator's `dev.yellowhammer` items: its service is ``service``, its account and secret are
/// a fresh nonce, and it is created with `-A`, so any application may read it without a prompt — a
/// leak shows up as a finding, never as a dialog nobody answers.
///
/// The two operations are closures so tests substitute them and never touch the real Keychain.
public struct ProbeKeychain: Sendable {
    /// The service every probe item is filed under.
    public static let service = "dev.yellowhammer.probe"

    /// Creates the item for `account`, with `account` as its secret. True iff it was created.
    public let create: @Sendable (_ account: String) async -> Bool
    /// Deletes the item for `account`. Called on every path after ``create`` was attempted.
    public let delete: @Sendable (_ account: String) async -> Void

    public init(
        create: @escaping @Sendable (_ account: String) async -> Bool,
        delete: @escaping @Sendable (_ account: String) async -> Void
    ) {
        self.create = create
        self.delete = delete
    }

    /// The login Keychain, through `/usr/bin/security`.
    public static let login = ProbeKeychain(
        create: { account in
            await security(["add-generic-password", "-s", service, "-a", account, "-w", account, "-A"])
        },
        delete: { account in
            _ = await security(["delete-generic-password", "-s", service, "-a", account])
        }
    )

    /// Runs `/usr/bin/security` in a detached task, so a cancelled probe still deletes its item
    /// instead of having the cleanup call cancelled with it. True iff it exited 0.
    private static func security(_ arguments: [String]) async -> Bool {
        await Task.detached {
            let result = try? await Subprocess.run(
                .path(FilePath("/usr/bin/security")),
                arguments: Arguments(arguments),
                output: .discarded,
                error: .discarded
            )
            return result?.terminationStatus == .exited(0)
        }.value
    }
}
