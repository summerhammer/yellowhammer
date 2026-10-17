import CLIAdapters
import Foundation
import Testing

// #555: the `securityd` lines captured live on 2026-10-18 (macOS 27) while `/usr/bin/security` read a
// throwaway item that trusts no application. Trimmed to the fields that matter; the messages are verbatim.

/// The default-level `kcacl` message: what `UnifiedLogPromptSource`'s predicate streams.
private let defaultLevelMessage = "displaying keychain prompt for /usr/bin/security(7365); ACL: "
    + "<AclValidationContext(action:24)SUBJECT[<ThresholdAclSubject(1 of 1)[<KeychainPromptAclSubject(flags: 0x0, "
    + "desc:dev.yellowhammer.probe)>]>]OBJECT[<ObjectAcl[ENTRY()[<AclEntry[tag:]AUTH[35]SUBJECT[<ThresholdAclSubject"
    + "(1 of 2)[AnyAclSubject][<KeychainPromptAclSubject(flags: 0x0, desc:dev.yellowhammer.probe)>]>]>] "
    + "ENTRY(___PARTITION___)[<AclEntry[tag:___PARTITION___]AUTH[65538]SUBJECT[<PartitionAclSubject({\n"
    + "    Partitions =     (\n        \"apple-tool:\"\n    );\n})>]>] ]>]>"

/// Default level, subsystem `com.apple.securityd`, category `kcacl`.
private let defaultLevelFixture = logLine(
    messageType: "Default", subsystem: "com.apple.securityd", category: "kcacl", eventMessage: defaultLevelMessage
)

/// Info level, no subsystem: only seen with `--info`, and it names no item.
private let infoLevelFixture = logLine(
    messageType: "Info", subsystem: "", category: "",
    eventMessage: "displaying keychain prompt for /usr/bin/security(7365)"
)

/// One `log stream --style ndjson` line, as `securityd` (pid 404) wrote it.
private func logLine(
    messageType: String, subsystem: String, category: String, eventMessage: String,
    processImagePath: String = "/usr/sbin/securityd"
) -> String {
    let object: [String: Any] = [
        "messageType": messageType, "subsystem": subsystem, "category": category,
        "processImagePath": processImagePath, "processID": 404, "eventMessage": eventMessage,
        "timestamp": "2026-10-18 00:46:44.646378+0300"
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(bytes: data, encoding: .utf8) ?? ""
}

private func parse(_ line: String) -> PromptEvent? {
    PromptLogLine.parse(Data(line.utf8))
}

@Suite("Permission prompt log lines")
struct PromptLogLineTests {
    @Test("The default-level securityd line names the client, its pid and the item")
    func defaultLevelLine() throws {
        let event = try #require(parse(Self.fixture(defaultLevelFixture)))
        #expect(event.kind == .keychain)
        #expect(event.clientPID == 7365)
        #expect(event.detail == "Keychain prompt for /usr/bin/security (pid 7365), item dev.yellowhammer.probe")
    }

    @Test("The info-level securityd line names the client and its pid")
    func infoLevelLine() throws {
        let event = try #require(parse(Self.fixture(infoLevelFixture)))
        #expect(event.clientPID == 7365)
        #expect(event.detail == "Keychain prompt for /usr/bin/security (pid 7365)")
    }

    @Test("A client path with spaces and parentheses keeps its pid")
    func pathWithParentheses() throws {
        let line = logLine(
            messageType: "Info", subsystem: "", category: "",
            eventMessage: "displaying keychain prompt for /Applications/My Tool (2).app/Contents/MacOS/My Tool(812)"
        )
        let event = try #require(parse(line))
        #expect(event.clientPID == 812)
        #expect(event.detail == "Keychain prompt for /Applications/My Tool (2).app/Contents/MacOS/My Tool (pid 812)")
    }

    @Test("log's plain-text header, other securityd lines and other processes are not prompts")
    func nonPromptLines() {
        #expect(parse(#"Filtering the log data using "process == "securityd""#) == nil)
        #expect(parse("") == nil)
        let query = logLine(
            messageType: "Default", subsystem: "com.apple.securityd", category: "kcacl",
            eventMessage: "Keychain query for process 7365 (UID 501)"
        )
        #expect(parse(query) == nil)
        let otherProcess = logLine(
            messageType: "Info", subsystem: "", category: "",
            eventMessage: "displaying keychain prompt for /usr/bin/security(7365)", processImagePath: "/usr/bin/log"
        )
        #expect(parse(otherProcess) == nil)
        let noPID = logLine(
            messageType: "Info", subsystem: "", category: "",
            eventMessage: "displaying keychain prompt for /usr/bin/security"
        )
        #expect(parse(noPID) == nil)
    }

    private static func fixture(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
