@testable import CLIAdapters
import Foundation
import Synchronization

/// Stands in for the login Keychain in ``CLIProbe`` tests, so no test ever creates a real item: it
/// records every create and delete, and refuses the create when told to.
final class StubProbeKeychain: Sendable {
    enum Call: Equatable, Sendable {
        case create(String)
        case delete(String)
    }

    private let recorded = Mutex<[Call]>([])
    private let createSucceeds: Bool

    init(createSucceeds: Bool = true) {
        self.createSucceeds = createSucceeds
    }

    var calls: [Call] { recorded.withLock { $0 } }

    var keychain: ProbeKeychain {
        ProbeKeychain(
            create: { [self] account in
                recorded.withLock { $0.append(.create(account)) }
                return createSucceeds
            },
            delete: { [self] account in
                recorded.withLock { $0.append(.delete(account)) }
            }
        )
    }
}
