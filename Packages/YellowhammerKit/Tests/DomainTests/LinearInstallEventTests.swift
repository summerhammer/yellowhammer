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
            .approvalLinkIssued(
                url: "https://app.yellowhammer.dev/install/abc123", expiresInSeconds: 900,
                text: "send this link to a workspace admin"
            ),
            .awaitingRemoteApproval,
            .installed(workspaceName: "Acme"),
            .failed(reason: .cancelled, text: "the Operator cancelled"),
            .failed(reason: .expired, text: "the link expired"),
            .failed(reason: .rejected, text: "the admin declined"),
            .failed(reason: .relayUnreachable, text: "the relay could not be reached"),
            .failed(reason: .relayRateLimited, text: "the relay is rate-limiting requests")
        ]
        for event in events {
            let line = try event.ndjsonLine()
            #expect(!line.contains("\n"))
            let decoded = try JSONDecoder().decode(LinearInstallEvent.self, from: Data(line.utf8))
            #expect(decoded == event)
        }
    }

    @Test("approvalLinkIssued and awaitingRemoteApproval encode to their exact spec JSON")
    func remoteApprovalEventsEncodeExactly() throws {
        let issued = LinearInstallEvent.approvalLinkIssued(
            url: "https://app.yellowhammer.dev/install/abc123", expiresInSeconds: 900, text: "send this link"
        )
        let issuedData = try JSONEncoder().encode(issued)
        let issuedDecoded = try JSONDecoder().decode([String: AnyDecodableForTest].self, from: issuedData)
        #expect(issuedDecoded["event"]?.stringValue == "approvalLinkIssued")
        #expect(issuedDecoded["url"]?.stringValue == "https://app.yellowhammer.dev/install/abc123")
        #expect(issuedDecoded["expiresIn"]?.intValue == 900)
        #expect(issuedDecoded["text"]?.stringValue == "send this link")

        let awaiting = try LinearInstallEvent.awaitingRemoteApproval.ndjsonLine()
        #expect(awaiting == #"{"event":"awaitingRemoteApproval"}"#)
    }

    @Test("An old decoder-shape line still decodes")
    func oldShapeStillDecodes() throws {
        let line = #"{"event":"awaitingApproval"}"#
        let decoded = try JSONDecoder().decode(LinearInstallEvent.self, from: Data(line.utf8))
        #expect(decoded == .awaitingApproval)
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
            .differentWorkspace: "\"differentWorkspace\"", .portsBusy: "\"portsBusy\"", .other: "\"other\"",
            .expired: "\"expired\"", .rejected: "\"rejected\"",
            .relayUnreachable: "\"relayUnreachable\"", .relayRateLimited: "\"relayRateLimited\""
        ]
        for (reason, json) in expected {
            let data = try JSONEncoder().encode(reason)
            #expect(String(data: data, encoding: .utf8) == json)
        }
    }
}

/// A minimal untyped JSON value, used only to assert `approvalLinkIssued`'s exact key set and values
/// without hand-writing a second Decodable shape for the whole event.
private struct AnyDecodableForTest: Decodable {
    let stringValue: String?
    let intValue: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            stringValue = value
            intValue = nil
        } else if let value = try? container.decode(Int.self) {
            stringValue = nil
            intValue = value
        } else {
            stringValue = nil
            intValue = nil
        }
    }
}
