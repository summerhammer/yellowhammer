import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Security
import Testing

/// Against the real scratch Linear workspace — the done-condition a stub cannot prove. Opt-in only:
///
///     YH_LINEAR_SCRATCH_TESTS=1 YH_LINEAR_INSTALLATION=<local name> YH_LINEAR_PROJECT_ID=… \
///         swift test --package-path Packages/YellowhammerKit --filter NightCardScratchTests
///
/// Uses the token pair of the Board Connection named `YH_LINEAR_INSTALLATION`, already stored in the Keychain
/// item `linear-<name>` (P17.3/P17.4), via `BoardBinding` — no client id or secret of its own.
@Suite(
    "Open and close the Night Card (live)",
    .enabled(if: ProcessInfo.processInfo.environment["YH_LINEAR_SCRATCH_TESTS"] == "1")
)
struct NightCardScratchTests {
    @Test("A rehearsal Night opens and completes exactly one Night Card; a second run opens no second")
    func nightCardOpensAndCompletesOnce() async throws {
        guard let (board, projectID) = try Self.liveBoard() else {
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-night-card-scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)

        // A unique Night derived from today's date, so re-running this scratch test on a later day
        // does not collide with an earlier one's card (a same-day re-run is idempotent by design:
        // the create's client id is deterministic, so Linear reports it already applied).
        let nightStart = try #require(Self.todayAsNightStart())

        try await EngineInvocation(
            act: .land, mode: .rehearsal, nightStart: nightStart, journal: journal,
            trigger: .forced, closesNight: true, board: board, work: { _ in }
        ).run()

        try await EngineInvocation(
            act: .land, mode: .rehearsal, nightStart: nightStart, journal: journal,
            trigger: .forced, closesNight: false, board: board, work: { _ in }
        ).run()

        let events = try journal.events()
        #expect(events.filter { $0.type == .nightCardOpened }.count == 1)
        #expect(events.filter { $0.type == .nightCardCompleted }.count == 1)
    }

    /// The live scratch Board Port, from the same environment variables and Keychain item as
    /// `BoardProvisionerScratchTests`; nil (printing why) when the scratch environment is not set up.
    private static func liveBoard() throws -> (board: ActBoard, projectID: ProjectID)? {
        let environment = ProcessInfo.processInfo.environment
        guard let linearProjectID = environment["YH_LINEAR_PROJECT_ID"], !linearProjectID.isEmpty else {
            print("NightCardScratchTests skipped: YH_LINEAR_PROJECT_ID is not set")
            return nil
        }
        guard let installation = environment["YH_LINEAR_INSTALLATION"], !installation.isEmpty else {
            print("NightCardScratchTests skipped: YH_LINEAR_INSTALLATION is not set")
            return nil
        }
        guard keychainSecret(account: "linear-\(installation)") != nil else {
            print("NightCardScratchTests skipped: no Keychain item for service dev.yellowhammer, "
                + "account linear-\(installation)")
            return nil
        }

        let machine = try MachineConfiguration.parse("""
            [board.linear.connections."\(installation)"]
            credential = "keychain:linear-\(installation)"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """, file: "config.toml")

        let project = try ProjectConfiguration.parse("""
            id = "yellowhammer"
            name = "Yellowhammer"
            board = { linear = { connection = "\(installation)", project = "\(linearProjectID)" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/yellowhammer-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/yellowhammer-backend"
            role = "backend"
            check = "swift test"
            """, file: "yellowhammer.toml")

        return (try BoardBinding.actBoard(machine: machine, project: project), project.id)
    }

    /// Today's calendar date, UTC, as a Night's identity.
    private static func todayAsNightStart() -> NightStart? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        return NightStart(year: today.year ?? 0, month: today.month ?? 0, day: today.day ?? 0)
    }

    private static func keychainSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.yellowhammer",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
