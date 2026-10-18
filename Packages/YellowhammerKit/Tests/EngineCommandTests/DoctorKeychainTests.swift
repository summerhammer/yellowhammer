import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: widened Keychain items")
struct DoctorKeychainTests {
    private static let yh = "/Applications/Yellowhammer.app/Contents/MacOS/yh"
    private static let trusted = KeychainItemAccess(
        trustedApplicationPaths: [yh, "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer"],
        partitions: ["teamid:A2SJL2N487", "apple:"]
    )

    private func findings(_ reports: [String: KeychainAccessReport]) async throws -> [DoctorFinding] {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        return await makeDoctor(
            directory: directory, checks: [.configuration, .keychain],
            keychainAccess: FakeKeychainAccess(reports: reports)
        ).run().filter { $0.check == .keychain }
    }

    @Test("an item trusting only yh and Yellowhammer passes, for each Board and Code Hosting item")
    func passes() async throws {
        let result = try await findings([
            "keychain:linear": .read(Self.trusted), "keychain:github": .read(Self.trusted)
        ])
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.severity == .pass })
        #expect(result.contains { $0.message.contains("Board Connection acme") })
        #expect(result.contains { $0.message.contains("Code Hosting Connection github") })
    }

    @Test("a security entry and an apple-tool partition fail, naming the item, the widening and the fix")
    func widened() async throws {
        let widened = KeychainItemAccess(
            trustedApplicationPaths: [Self.yh, "/usr/bin/security"],
            partitions: ["teamid:A2SJL2N487", "apple-tool:"]
        )
        let result = try await findings(["keychain:linear": .read(widened)])
        let failure = try #require(result.first { $0.severity == .failure })
        #expect(failure.installation?.name == "acme")
        #expect(failure.message.contains("dev.yellowhammer / linear"))
        #expect(failure.message.contains("/usr/bin/security"))
        #expect(failure.message.contains("apple-tool:"))
        #expect(failure.message.contains("delete the item in Keychain Access"))
        #expect(failure.message.contains("yh setup --install-linear"))
        #expect(!failure.message.contains("test-secret"))
    }

    @Test("an item any application may read fails; a widened Code Hosting token names its replace command")
    func anyApplication() async throws {
        let open = KeychainItemAccess(trustedApplicationPaths: nil, partitions: [])
        let result = try await findings(["keychain:github": .read(open)])
        let failure = try #require(result.first)
        #expect(failure.severity == .failure)
        #expect(failure.message.contains("any application"))
        #expect(failure.message.contains("yh config replace-code-hosting-token github"))
    }

    @Test("an absent item is left to the Linear and GitHub checks; an unreadable one warns")
    func absentAndUnreadable() async throws {
        #expect(try await findings([:]).isEmpty)
        let result = try await findings(["keychain:linear": .unreadable("locked")])
        #expect(result.map(\.severity) == [.warning])
    }

    @Test("the check is part of the full run and accepted by --check")
    func fullRun() throws {
        #expect(DoctorCheck.allCases.contains(.keychain))
        #expect(try DoctorCommand.parse(["--check", "keychain"]).validate() == ())
    }
}
