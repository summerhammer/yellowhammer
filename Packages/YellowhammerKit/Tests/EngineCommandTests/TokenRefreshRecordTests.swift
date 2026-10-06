import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// Every Board Connection token-pair refresh an Act's board attempted is appended to the Journal, once,
// before the Act's closing event: `.actEnded` on success, `.actIncomplete` on failure.

@Suite("Token refresh records reach the Journal")
struct TokenRefreshRecordTests {
    private static let attempted = Date(timeIntervalSince1970: 1_800_000_000)

    private static let label = AppInstallationLabel(name: "acme", workspace: BoardObjectID(rawValue: "workspace-1"))

    private static func refreshed() -> AppInstallationTokenRefresh {
        AppInstallationTokenRefresh(
            installation: label, attemptedAt: attempted, trigger: .nearExpiry,
            previousExpiresAt: attempted.addingTimeInterval(60),
            outcome: .refreshed(expiresAt: attempted.addingTimeInterval(7200))
        )
    }

    private static func refused() -> AppInstallationTokenRefresh {
        AppInstallationTokenRefresh(
            installation: label, attemptedAt: attempted, trigger: .accessTokenRejected,
            previousExpiresAt: attempted.addingTimeInterval(60),
            outcome: .refused(.init(
                status: 401, code: "invalid_client", description: "Client authentication failed", message: "refused"
            ))
        )
    }

    private static func record(_ refresh: AppInstallationTokenRefresh, into log: AppInstallationTokenRefreshLog) {
        log.record(
            attemptedAt: refresh.attemptedAt, trigger: refresh.trigger,
            previousExpiresAt: refresh.previousExpiresAt, outcome: refresh.outcome
        )
    }

    @Test("A refresh record made through an Act's board lands in the Journal with that board's installation")
    func recordCarriesTheActBoardsInstallation() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let log = AppInstallationTokenRefreshLog(installation: Self.label)
        Self.record(Self.refreshed(), into: log)
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning,
            tokenRefreshes: log, installation: Self.label
        )

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        )
        try await invocation.run()

        let record = try #require(try journal.events(ofType: .appInstallationTokenRefresh).first)
        guard case .appInstallationTokenRefresh(let refresh) = record.event else {
            Issue.record("Event is not appInstallationTokenRefresh")
            return
        }
        #expect(refresh.installation == board.installation)
        #expect(record.event.payload?["installation"] == "acme")
        #expect(record.event.payload?["workspace"] == "workspace-1")
    }

    @Test("A successful Act appends its `refreshed` record before `.actEnded`, once")
    func successfulActRecordsBeforeActEnded() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let log = AppInstallationTokenRefreshLog(installation: Self.label)
        Self.record(Self.refreshed(), into: log)
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning,
            tokenRefreshes: log
        )

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        )
        try await invocation.run()

        let records = try journal.events()
        let types = records.map(\.type)
        let refreshIndex = try #require(types.firstIndex(of: .appInstallationTokenRefresh))
        let endedIndex = try #require(types.firstIndex(of: .actEnded))
        #expect(refreshIndex < endedIndex)
        #expect(types.filter { $0 == .appInstallationTokenRefresh }.count == 1)
        #expect(records[refreshIndex].event == .appInstallationTokenRefresh(Self.refreshed()))
        #expect(records[refreshIndex].nightID != nil)
        #expect(log.drain().isEmpty)
    }

    @Test("A failing Act appends its `refused` record before `.actIncomplete`")
    func failingActRecordsBeforeActIncomplete() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let log = AppInstallationTokenRefreshLog(installation: Self.label)
        Self.record(Self.refused(), into: log)
        let reading = FakeReadingBoard([])
        await reading.script(identity: .failure(.notAuthenticated("sign-in expired")))
        let board = ActBoard(
            reading: reading, writing: boards.writing, provisioning: boards.provisioning, tokenRefreshes: log
        )

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        )
        await #expect(throws: (any Error).self) { try await invocation.run() }

        let types = try journal.events().map(\.type)
        let refreshIndex = try #require(types.firstIndex(of: .appInstallationTokenRefresh))
        let incompleteIndex = try #require(types.firstIndex(of: .actIncomplete))
        #expect(refreshIndex < incompleteIndex)
        #expect(types.filter { $0 == .appInstallationTokenRefresh }.count == 1)
        #expect(types.contains(.linearAuthorizationHalted))
    }
}
