@testable import EngineCommand
import Foundation
import Testing

// roadmap P17.6 slice (a): port selection (first free of the three wins) and the lsof holder lookup's
// `-Fpc` parsing, both with injected seams so no real socket or `lsof` process is needed here.

private final class FakeCallbackListening: CallbackListening, Sendable {
    let port: Int
    let redirectURI: URL
    init(port: Int) {
        self.port = port
        redirectURI = URL(string: "http://127.0.0.1:\(port)/callback")!
    }
    func waitForCallback(timeout: Duration) async throws -> LoopbackCallbackServer.CallbackResult {
        LoopbackCallbackServer.CallbackResult(code: nil, state: nil, error: nil, errorDescription: nil)
    }
    func close() {}
}

private struct FakeHolderLookup: PortHolderLookup {
    let holders: [Int: PortHolder]
    func holder(port: Int) async -> PortHolder? { holders[port] }
}

@Suite("Loopback port selection (P17.6)")
struct LinearInstallPortsTests {
    @Test("The first free port of the three is chosen")
    func firstFreeChosen() async throws {
        let selected = try await LoopbackPortSelection.select(
            ports: [1, 2, 3],
            binder: { port in
                if port == 1 { throw LoopbackCallbackServer.BindError.busy(port: port) }
                return FakeCallbackListening(port: port)
            },
            holderLookup: FakeHolderLookup(holders: [:])
        )
        #expect(selected.redirectURI.absoluteString.contains(":2/"))
    }

    @Test("All three busy reports PortsBusyError with each port's holder")
    func allBusyReportsHolders() async throws {
        let holder = PortHolder(pid: 999, command: "SomeApp")
        do {
            _ = try await LoopbackPortSelection.select(
                ports: [1, 2, 3],
                binder: { port in throw LoopbackCallbackServer.BindError.busy(port: port) },
                holderLookup: FakeHolderLookup(holders: [2: holder])
            )
            Issue.record("expected PortsBusyError")
        } catch let error as PortsBusyError {
            #expect(error.ports.map { $0.port } == [1, 2, 3])
            #expect(error.ports[1].holder == holder)
            #expect(error.ports[0].holder == nil)
        }
    }

    @Test("lsof -Fpc output parses into pid and command")
    func parsesLsofOutput() {
        let output = "p12345\ncSomeApp\n"
        let holder = LSOFPortHolderLookup.parse(output)
        #expect(holder == PortHolder(pid: 12345, command: "SomeApp"))
    }

    @Test("Unparseable lsof output reports no holder")
    func unparseableLsofOutputReportsNoHolder() {
        #expect(LSOFPortHolderLookup.parse("") == nil)
        #expect(LSOFPortHolderLookup.parse("garbage\n") == nil)
    }
}
