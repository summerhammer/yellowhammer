@testable import Config
import Foundation
import Testing

@Suite("KeychainItemAccess")
struct KeychainItemAccessTests {
    private func hex(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    @Test("the partition ACL's hex-encoded plist decodes to its entries")
    func decodesPartitions() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Partitions</key><array>
        <string>teamid:A2SJL2N487</string><string>apple-tool:</string></array></dict></plist>
        """
        #expect(KeychainCredentialStore.partitions(fromDescription: hex(plist))
            == ["teamid:A2SJL2N487", "apple-tool:"])
        #expect(KeychainCredentialStore.partitions(fromDescription: "not hex").isEmpty)
    }

    @Test("only yh, Yellowhammer and the Yellowhammer team partition are trusted")
    func wideningReasons() {
        let clean = KeychainItemAccess(
            trustedApplicationPaths: ["/x/yh", "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer"],
            partitions: ["teamid:A2SJL2N487", "apple:"]
        )
        #expect(clean.wideningReasons.isEmpty)
        #expect(KeychainItemAccess(trustedApplicationPaths: ["/x/yh"], partitions: []).wideningReasons.isEmpty)
        let security = KeychainItemAccess(trustedApplicationPaths: ["/usr/bin/security"], partitions: [])
        #expect(security.wideningReasons.count == 1)
        let otherTeam = KeychainItemAccess(trustedApplicationPaths: [], partitions: ["teamid:OTHER"])
        #expect(otherTeam.wideningReasons.count == 1)
        #expect(KeychainItemAccess(trustedApplicationPaths: nil, partitions: []).wideningReasons.count == 1)
    }
}
