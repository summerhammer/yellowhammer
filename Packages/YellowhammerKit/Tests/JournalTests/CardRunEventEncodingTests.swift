import Domain
import Foundation
import Testing

@testable import Journal

// The Card run's event (roadmap P8.4) round-trips here, split out of EventEncodingTests.swift to keep
// that file under the length limit.

@Test("cardRunStep event round-trips for every step, with and without a detail")
func cardRunStepRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-cardrun-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    for (index, step) in CardRunStep.allCases.enumerated() {
        let detail: String? = index.isMultiple(of: 2) ? "detail \(step.rawValue)" : nil
        try journal.append(
            .cardRunStep(cardID: 7, issueID: "BACK-1", step: step, detail: detail),
            act: .build, runID: run, now: epoch
        )
    }
    let records = try journal.events(ofType: .cardRunStep)

    #expect(records.count == CardRunStep.allCases.count)
    for (index, step) in CardRunStep.allCases.enumerated() {
        let detail: String? = index.isMultiple(of: 2) ? "detail \(step.rawValue)" : nil
        #expect(records[index].event == .cardRunStep(cardID: 7, issueID: "BACK-1", step: step, detail: detail))
    }
}

@Test("checkRan event round-trips for every result, with and without a status and output")
func checkRanRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-checkran-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let events: [JournalEvent] = [
        .checkRan(CheckRanPayload(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .passed, exitStatus: 0, output: "ok\n",
            judgedCommit: "b763aff", command: "swift test --filter \"Check Tests\""
        )),
        .checkRan(CheckRanPayload(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .failed, exitStatus: 127, output: "line\n\"quoted\"\n",
            judgedCommit: nil, command: "pnpm --filter relay test"
        )),
        .checkRan(CheckRanPayload(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .declaredNone, exitStatus: nil, output: nil,
            judgedCommit: "fddeef4"
        ))
    ]

    for event in events {
        try journal.append(event, act: .build, runID: run, now: epoch)
    }
    let records = try journal.events(ofType: .checkRan)

    #expect(records.map(\.event) == events)
    #expect(Set(events.compactMap { event -> CheckRunResult? in
        if case .checkRan(let payload) = event { payload.result } else { nil }
    }) == Set(CheckRunResult.allCases))
}

@Test("checkRan event round-trips its sibling Worktree HEADs and each lockfile identity (OQ198 item 3)")
func checkRanRoundTripsSiblingsAndLockfile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-checkran-siblings-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let sha = "b763aff0b763aff0b763aff0b763aff0b763aff0"
    let siblings = [
        CheckSiblingState(repository: "web", before: .commit(sha), after: .commit("fddeef4")),
        CheckSiblingState(repository: "mobile", before: .noHeldWorktree, after: .noHeldWorktree),
        CheckSiblingState(repository: "api", before: .unreadable(reason: "x"), after: .commit(sha))
    ]
    let lockfiles: [LockfileIdentity] = [
        .unknown, .absent(path: "pnpm-lock.yaml"), .blob(path: "Package.resolved", objectID: "e69de29")
    ]
    let events: [JournalEvent] = lockfiles.map { lockfile in
        .checkRan(CheckRanPayload(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .passed, exitStatus: 0, output: nil,
            judgedCommit: sha, command: "make test", siblings: siblings, lockfile: lockfile
        ))
    }
    for event in events {
        try journal.append(event, act: .build, runID: RunID(), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    #expect(try journal.events(ofType: .checkRan).map(\.event) == events)
}

@Test("A legacy checkRan payload decodes without inventing its command or judged commit")
func checkRanWithoutJudgedCommitDecodes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-checkran-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                nil, nil, nil, JournalEventType.checkRan.rawValue,
                JournalStore.timestamp(Date(timeIntervalSince1970: 1_800_000_000)),
                "{\"card_id\": \"7\", \"issue_id\": \"BACK-1\", \"attempt_id\": \"3\", \"result\": \"passed\", "
                    + "\"exit_status\": \"0\"}"
            ]
        )
    }

    let records = try journal.events(ofType: .checkRan)
    #expect(records.first.flatMap(CheckRunRecord.init)?.command == nil)

    #expect(records.map(\.event) == [
        .checkRan(CheckRanPayload(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .passed, exitStatus: 0, output: nil,
            judgedCommit: nil
        ))
    ])
    if case .checkRan(let payload)? = records.first?.event {
        #expect(payload.siblings.isEmpty)
        #expect(payload.lockfile == .unknown)
    }
}

@Test("failureCauseRecorded event round-trips")
func failureCauseRecordedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-failurecause-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let event = JournalEvent.failureCauseRecorded(
        cardID: 7, issueID: "BACK-1", cause: "hard failure (exit status 2)", causeHash: "abc123",
        recurrenceCount: 2
    )

    try journal.append(event, act: .build, runID: RunID(), now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(try journal.events(ofType: .failureCauseRecorded).map(\.event) == [event])
}

@Test("leftoverProcessRecorded event round-trips for every disposition, with and without a cwd")
func leftoverProcessRecordedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-leftover-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let events: [JournalEvent] = [
        .leftoverProcessRecorded(
            cardID: 7, issueID: "BACK-1", attemptID: 3, pass: .worker, pid: 4242, commandName: "node",
            disposition: .sweptByRunningSnapshot, cwd: nil
        ),
        .leftoverProcessRecorded(
            cardID: 7, issueID: "BACK-1", attemptID: 3, pass: .worker, pid: 4343, commandName: "python3",
            disposition: .sweptByWorktreeFence, cwd: nil
        ),
        .leftoverProcessRecorded(
            cardID: 7, issueID: "BACK-1", attemptID: 3, pass: .worker, pid: 4444, commandName: "sleep",
            disposition: .leftRunningUnattributed, cwd: "/tmp/yh-wt-backend"
        )
    ]

    for event in events {
        try journal.append(event, act: .build, runID: run, now: epoch)
    }
    let records = try journal.events(ofType: .leftoverProcessRecorded)

    #expect(records.map(\.event) == events)
    #expect(Set(events.compactMap { event -> LeftoverProcessDisposition? in
        if case .leftoverProcessRecorded(_, _, _, _, _, _, let disposition, _) = event { disposition } else { nil }
    }) == Set(LeftoverProcessDisposition.allCases))
}

@Test("agentSessionHadForeignTurns event round-trips through encoding and decoding")
func agentSessionHadForeignTurnsRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-foreignturns-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let event = JournalEvent.agentSessionHadForeignTurns(
        cardID: 42, issueID: "ENG-101", attemptID: 2, round: 1, cli: "claude"
    )

    try journal.append(event, act: .build, runID: RunID(), now: Date(timeIntervalSince1970: 1_800_000_000))

    let records = try journal.events(ofType: .agentSessionHadForeignTurns)
    #expect(records.map(\.event) == [event])

    // Verify payload keys do not name who wrote the turns (c2)
    let payload = try #require(records.first?.event.payload)
    #expect(payload["card_id"] == "42")
    #expect(payload["issue_id"] == "ENG-101")
    #expect(payload["attempt_id"] == "2")
    #expect(payload["round"] == "1")
    #expect(payload["cli"] == "claude")
    #expect(payload["operator"] == nil)
    #expect(payload["orca"] == nil)
    #expect(payload["author"] == nil)
    #expect(payload["who"] == nil)
}

@Test("agentPassNotShownInOrca event round-trips through encoding and decoding")
func agentPassNotShownInOrcaRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-notshowninorca-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let event = JournalEvent.agentPassNotShownInOrca(
        cardID: 42, issueID: "ENG-101", attemptID: 2, pass: .worker, cli: "claude",
        reason: "Orca was unreachable, ran unseen"
    )

    try journal.append(event, act: .build, runID: RunID(), now: Date(timeIntervalSince1970: 1_800_000_000))

    let records = try journal.events(ofType: .agentPassNotShownInOrca)
    #expect(records.map(\.event) == [event])

    let payload = try #require(records.first?.event.payload)
    #expect(payload["card_id"] == "42")
    #expect(payload["issue_id"] == "ENG-101")
    #expect(payload["attempt_id"] == "2")
    #expect(payload["pass"] == "worker")
    #expect(payload["cli"] == "claude")
    #expect(payload["reason"] == "Orca was unreachable, ran unseen")
}
