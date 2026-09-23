import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// loop-state/claim-and-heartbeat-a-run-lease: the Journal is single-writer and leases are Project-scoped
// by construction. shift-scheduling/fire-an-act-on-schedule: an Act firing while another Act of the same
// Project runs does not corrupt state. The Act-scoped lease is one row per Journal, one level above the
// per-Card lease, with the same 60-second heartbeat and 10-minute TTL (G-15).

/// A throwaway configuration directory holding one Project's Journal. Removed on deinit.
private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Each call is a new connection to the same file: what a second engine process would hold.
    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test("The act_lease table arrives in migration v2, after the shipped v1")
func actLeaseMigrationIsSecond() throws {
    #expect(
        JournalStore.migrationIdentifiers == [
            "v1-initial-schema", "v2-act-lease", "v3-night-close-reason", "v4-outbox-delivery",
            "v5-delta-read", "v6-night-verdict", "v7-card-state-version", "v8-worktree-pushed-commit",
            "v9-worktree-reconciliation", "v10-attempt-route-provenance", "v11-feature-branch",
            "v12-readiness-check", "v13-card-scope", "v14-attempt-preserved-ref", "v15-refusal", "v16-cycle-landed",
            "v17-authoring-halt", "v18-predecessor-gate", "v19-pull-request",
            "v20-feature-verification", "v21-feature-closure", "v22-night-triaged", "v23-card-question"
        ]
    )
}

@Test("A Journal created at v1 gains act_lease when the engine opens it")
func v1JournalMigratesForwardToActLease() throws {
    let fixture = try JournalFixture()
    let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let v1 = try DatabaseQueue(path: fileURL.path)
    try JournalMigrations.migrator.migrate(v1, upTo: "v1-initial-schema")
    #expect(try v1.read { try $0.tableExists("act_lease") } == false)

    let journal = try fixture.open()

    #expect(try journal.appliedMigrations() == [
        "v1-initial-schema", "v2-act-lease", "v3-night-close-reason", "v4-outbox-delivery",
        "v5-delta-read", "v6-night-verdict", "v7-card-state-version", "v8-worktree-pushed-commit",
        "v9-worktree-reconciliation", "v10-attempt-route-provenance", "v11-feature-branch",
        "v12-readiness-check", "v13-card-scope", "v14-attempt-preserved-ref", "v15-refusal", "v16-cycle-landed",
            "v17-authoring-halt", "v18-predecessor-gate", "v19-pull-request",
            "v20-feature-verification", "v21-feature-closure", "v22-night-triaged", "v23-card-question"
    ])
    #expect(try journal.tableNames().contains("act_lease"))
}

@Test("A fresh Journal has no Act lease, and the first run claims it")
func firstClaimSucceeds() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    #expect(try journal.currentActLease() == nil)

    let claim = try journal.claimActLease(act: .build, runID: run, mode: .rehearsal, now: epoch)

    let expected = ActLease(
        act: .build, runID: run, mode: .rehearsal,
        claimedAt: epoch, heartbeatAt: epoch, expiresAt: epoch.addingTimeInterval(600)
    )
    #expect(claim == .claimed(expected))
    #expect(try journal.currentActLease() == expected)
}

@Test("A second run of the same Project is told who holds the Project and claims nothing")
func overlappingRunIsHeldOff() throws {
    let fixture = try JournalFixture()
    let first = try fixture.open()
    let second = try fixture.open()
    let firstRun = RunID()
    let secondRun = RunID()
    let claim = try first.claimActLease(act: .build, runID: firstRun, mode: .real, now: epoch)
    guard case .claimed(let holder) = claim else {
        Issue.record("The first run did not claim the Project")
        return
    }

    let lastMoment = epoch.addingTimeInterval(599)
    let overlap = try second.claimActLease(act: .land, runID: secondRun, mode: .real, now: lastMoment)

    #expect(overlap == .held(holder))
    #expect(try second.currentActLease() == holder)
    #expect(try second.releaseActLease(runID: secondRun) == false)
    #expect(try second.currentActLease() == holder)
}

@Test("An unexpired lease is not taken over by a different Act of the same Project", arguments: Act.allCases)
func anyActStandsDownWhileHeld(_ act: Act) throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let holder = RunID()
    _ = try journal.claimActLease(act: .author, runID: holder, mode: .real, now: epoch)

    let claim = try journal.claimActLease(act: act, runID: RunID(), mode: .real, now: epoch.addingTimeInterval(60))

    guard case .held(let lease) = claim else {
        Issue.record("The \(act.rawValue) Act claimed a held Project")
        return
    }
    #expect(lease.runID == holder)
    #expect(lease.act == .author)
}

@Test("A lease with no heartbeat for the TTL is dead and the next run takes it over")
func expiredLeaseIsReclaimed() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let dead = RunID()
    let next = RunID()
    _ = try journal.claimActLease(act: .build, runID: dead, mode: .real, now: epoch)

    let atExpiry = epoch.addingTimeInterval(600)
    let claim = try journal.claimActLease(act: .build, runID: next, mode: .real, now: atExpiry)

    guard case .claimed(let lease) = claim else {
        Issue.record("The expired lease was not reclaimed")
        return
    }
    #expect(lease.runID == next)
    #expect(lease.claimedAt == atExpiry)
    #expect(lease.expiresAt == atExpiry.addingTimeInterval(600))
}

@Test("A heartbeat pushes the expiry out by the TTL and keeps the claim time")
func heartbeatExtendsExpiry() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let beat = epoch.addingTimeInterval(60)
    let refreshed = try journal.heartbeatActLease(runID: run, now: beat)

    #expect(refreshed.claimedAt == epoch)
    #expect(refreshed.heartbeatAt == beat)
    #expect(refreshed.expiresAt == beat.addingTimeInterval(600))
    #expect(try journal.currentActLease() == refreshed)
    // Still held at the original expiry, because it was heartbeated.
    let other = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch.addingTimeInterval(601))
    #expect(other == .held(refreshed))
}

@Test("A run that slept past its TTL and lost the Project learns so on its next heartbeat")
func heartbeatAfterLossThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let sleeper = RunID()
    let taker = RunID()
    _ = try journal.claimActLease(act: .build, runID: sleeper, mode: .real, now: epoch)
    guard case .claimed(let takerLease) = try journal.claimActLease(
        act: .build, runID: taker, mode: .real, now: epoch.addingTimeInterval(700)
    ) else {
        Issue.record("The expired lease was not reclaimed")
        return
    }

    #expect(throws: JournalError.actLeaseLost(runID: sleeper, holder: takerLease)) {
        try journal.heartbeatActLease(runID: sleeper, now: epoch.addingTimeInterval(701))
    }
    // The sleeper's heartbeat changed nothing.
    #expect(try journal.currentActLease() == takerLease)
}

@Test("A run whose lease expired with nobody taking it must claim again, not heartbeat")
func heartbeatOnOwnExpiredLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    guard case .claimed(let lease) = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch) else {
        Issue.record("The first run did not claim the Project")
        return
    }

    #expect(throws: JournalError.actLeaseLost(runID: run, holder: lease)) {
        try journal.heartbeatActLease(runID: run, now: epoch.addingTimeInterval(600))
    }
}

@Test("Releasing frees the Project for the next run; releasing twice is a no-op")
func releaseFreesTheProject() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    #expect(try journal.releaseActLease(runID: run) == true)
    #expect(try journal.currentActLease() == nil)
    #expect(try journal.releaseActLease(runID: run) == false)
    #expect(throws: JournalError.actLeaseLost(runID: run, holder: nil)) {
        try journal.heartbeatActLease(runID: run, now: epoch.addingTimeInterval(1))
    }

    let next = try journal.claimActLease(act: .land, runID: RunID(), mode: .real, now: epoch.addingTimeInterval(1))
    guard case .claimed = next else {
        Issue.record("The released Project was not claimable")
        return
    }
}

@Test("The run that holds the Project may claim again and keeps its original claim time")
func reclaimByHolderIsIdempotent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let again = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch.addingTimeInterval(30))

    let expected = ActLease(
        act: .build, runID: run, mode: .real,
        claimedAt: epoch, heartbeatAt: epoch.addingTimeInterval(30), expiresAt: epoch.addingTimeInterval(630)
    )
    #expect(again == .claimed(expected))
}

@Test("The lease records the Night's mode", arguments: NightMode.allCases)
func leaseCarriesMode(_ mode: NightMode) throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try journal.claimActLease(act: .build, runID: RunID(), mode: mode, now: epoch)

    #expect(try journal.currentActLease()?.mode == mode)
    let stored = try journal.read { try String.fetchOne($0, sql: "SELECT mode FROM act_lease WHERE id = 1") }
    #expect(stored == mode.rawValue)
}

@Test("The TTL and heartbeat are policy, merely true today")
func policyIsConfigurable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let policy = LeasePolicy(heartbeatInterval: 1, timeToLive: 5)
    #expect(LeasePolicy.ruled == LeasePolicy(heartbeatInterval: 60, timeToLive: 600))

    guard case .claimed(let lease) = try journal.claimActLease(
        act: .build, runID: run, mode: .real, policy: policy, now: epoch
    ) else {
        Issue.record("The first run did not claim the Project")
        return
    }
    #expect(lease.expiresAt == epoch.addingTimeInterval(5))
    let refreshed = try journal.heartbeatActLease(runID: run, policy: policy, now: epoch.addingTimeInterval(3))
    #expect(refreshed.expiresAt == epoch.addingTimeInterval(8))
}

@Test("LeasePolicy.heartbeatDuration converts to Duration without truncation")
func heartbeatDurationPrecision() {
    let short = LeasePolicy(heartbeatInterval: 0.25, timeToLive: 5)
    #expect(short.heartbeatDuration == .milliseconds(250))

    let ruled = LeasePolicy.ruled
    #expect(ruled.heartbeatDuration == .seconds(60))
}

@Test("The schema itself refuses a second Act lease row")
func schemaRefusesSecondRow() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)

    #expect(throws: DatabaseError.self) {
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO act_lease (id, act, run_id, mode, claimed_at, heartbeat_at, expires_at)
                VALUES (2, 'land', 'other', 'real', 't', 't', 't')
                """
            )
        }
    }
}

@Test("Two connections racing for the lease: exactly one claims it, with no SQLITE_BUSY")
func racingClaimsSerialise() async throws {
    let fixture = try JournalFixture()
    let stores = try (0..<8).map { _ in try fixture.open() }

    let claims = try await withThrowingTaskGroup(of: ActLeaseClaim.self) { group in
        for store in stores {
            group.addTask {
                try store.claimActLease(act: .build, runID: RunID(), mode: .real)
            }
        }
        return try await group.reduce(into: [ActLeaseClaim]()) { $0.append($1) }
    }

    let claimed = claims.compactMap { claim -> ActLease? in
        if case .claimed(let lease) = claim { return lease }
        return nil
    }
    #expect(claimed.count == 1)
    let holders = Set(claims.map { claim -> RunID in
        switch claim {
        case .claimed(let lease), .held(let lease): lease.runID
        }
    })
    #expect(holders == Set(claimed.map(\.runID)))
}

@Test("Two overlapping writers of the same Journal serialise on SQLite's lock and corrupt nothing")
func overlappingWritersDoNotCorrupt() async throws {
    let fixture = try JournalFixture()
    let first = try fixture.open()
    let second = try fixture.open()
    let perWriter = 200

    try await withThrowingTaskGroup(of: Void.self) { group in
        for (store, label) in [(first, "first"), (second, "second")] {
            group.addTask {
                for index in 0..<perWriter {
                    try store.write { db in
                        try db.execute(
                            sql: "INSERT INTO event (type, occurred_at) VALUES (?, ?)",
                            arguments: ["\(label)-\(index)", JournalStore.timestamp(Date())]
                        )
                    }
                }
            }
        }
        try await group.waitForAll()
    }

    let verifier = try fixture.open()
    let count = try verifier.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
    #expect(count == 2 * perWriter)
    let integrity = try verifier.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
    #expect(integrity == "ok")
    let distinct = try verifier.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT type) FROM event") }
    #expect(distinct == 2 * perWriter)
}

@Test("The engine addresses a Journal by Project id only, and the path cannot leave the journals directory")
func journalPathIsAFunctionOfTheProjectID() throws {
    let fixture = try JournalFixture(project: "alpha")
    let sibling = try #require(ProjectID(rawValue: "beta"))

    let journal = try fixture.open()

    let journals = fixture.directory.appending(component: "journals", directoryHint: .isDirectory)
    #expect(journal.fileURL == journals.appending(component: "alpha.db", directoryHint: .notDirectory))
    #expect(journal.projectID == fixture.projectID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: journals.path) == ["alpha.db"])
    let siblingURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: sibling)
    #expect(siblingURL.lastPathComponent == "beta.db")
    // Anything that could name a path outside `journals/` is not a ProjectID at all.
    #expect(ProjectID(rawValue: "../beta") == nil)
    #expect(ProjectID(rawValue: "beta/../../ledger") == nil)
}
