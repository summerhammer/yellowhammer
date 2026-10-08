import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

@Suite("Setup: --board-connection, remote approval")
struct SetupInstallationRemoteTests {
    @Test("Remote install approved elsewhere: failed(differentWorkspace), nothing stored")
    func remoteReconnectApprovedElsewhereIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.main]
            credential = "keychain:linear-main"
            workspace = "workspace-old"
            yellowhammer_identity = "app-user-old"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let transport = RelayRoutingTransport([
            .relaySession: [relaySessionReply()],
            .relayStatus("s1"): [relayApprovedReply],
            .linearToken: [linearTokenReply()],
            .linearGraphQL: [linearGraphQLReply(workspaceID: "workspace-new", workspaceName: "Other")]
        ])
        let events = Mutex<[LinearInstallEvent]>([])
        let requested = Mutex(0)
        let (store, _) = freshLinearInstallationStore()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, installLinear: true, events: "json", remote: true, installation: "main"
            ),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: remoteSeams(transport: transport, clock: RemoteInstallClock()),
            linearInstallationStore: { _ in
                requested.withLock { $0 += 1 }
                return store
            },
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(requested.withLock { $0 } == 0)
        #expect(try store.tokenStore.read() == nil)
        #expect(try Data(contentsOf: file) == before)
        guard case .failed(let reason, _)? = events.withLock({ $0 }).last else {
            Issue.record("expected .failed last")
            return
        }
        #expect(reason == .differentWorkspace)
    }
}
