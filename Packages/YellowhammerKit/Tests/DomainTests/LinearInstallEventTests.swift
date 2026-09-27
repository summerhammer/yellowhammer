@testable import Domain
import Foundation
import Testing

// roadmap P17.6 slice (b): the app decodes `yh setup --install-linear --events json`'s NDJSON without
// linking Engine, so this type's Codable round trip is the contract.

@Suite("LinearInstallEvent (P17.6)")
struct LinearInstallEventTests {
    @Test("Every case round-trips through its NDJSON line")
    func everyCaseRoundTrips() throws {
        let events: [LinearInstallEvent] = [
            .adminStatement(text: "an admin must approve"),
            .portsBusy(
                ports: [
                    .init(port: 44837, pid: 123, command: "SomeApp"),
                    .init(port: 44838, pid: nil, command: nil)
                ],
                text: "all three ports are busy"
            ),
            .browserOpened(url: "https://linear.app/oauth/authorize?client_id=x"),
            .awaitingApproval,
            .installed(workspaceName: "Acme"),
            .failed(reason: .cancelled, text: "the Operator cancelled")
        ]
        for event in events {
            let line = try event.ndjsonLine()
            #expect(!line.contains("\n"))
            let decoded = try JSONDecoder().decode(LinearInstallEvent.self, from: Data(line.utf8))
            #expect(decoded == event)
        }
    }

    @Test("An unknown event name fails to decode")
    func unknownEventFailsToDecode() {
        let json = #"{"event":"somethingElse"}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(LinearInstallEvent.self, from: Data(json.utf8))
        }
    }

    @Test("Every FailureReason encodes to its exact spec string")
    func failureReasonsEncodeExactly() throws {
        let expected: [LinearInstallEvent.FailureReason: String] = [
            .cancelled: "\"cancelled\"", .notCompleted: "\"notCompleted\"",
            .differentWorkspace: "\"differentWorkspace\"", .portsBusy: "\"portsBusy\"", .other: "\"other\""
        ]
        for (reason, json) in expected {
            let data = try JSONEncoder().encode(reason)
            #expect(String(data: data, encoding: .utf8) == json)
        }
    }
}
