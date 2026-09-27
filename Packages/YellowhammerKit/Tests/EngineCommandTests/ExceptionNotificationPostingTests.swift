import ArgumentParser
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// morning-report/notify-the-operator-of-exceptions (P12.5), Decision Gates Ruling G-10: the Night
// Card records `opened`, `halted` and `closed`; only `halted` and `closed` post a local notification,
// and only after the event is recorded on the Night Card first. Posting is strictly fire-and-forget:
// a failure to dispatch is caught, recorded as `notificationDeliveryFailed`, and never fails the Act.

private let notificationProjectID = ProjectID(rawValue: "fixture")!
private let sampleNotification = ExceptionNotification(project: notificationProjectID, event: .closed)

/// A test failure with a plain, controllable description — `runUnderLease` records
/// `String(describing:)`, so this is what ends up in the Journal and the notification reason.
private struct SampleWorkFailure: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// Records every notification a fake `ExceptionNotifier` was asked to post.
private final class NotificationRecorder: Sendable {
    private let storage = Mutex<[ExceptionNotification]>([])

    func record(_ notification: ExceptionNotification) {
        storage.withLock { $0.append(notification) }
    }

    var notifications: [ExceptionNotification] { storage.withLock { $0 } }
}

@Suite("Exception notification from Acts")
struct ExceptionNotificationPostingTests {
    @Test("A closing Act posts .closed only once the Night Card's completion is already on the board")
    func closingActPostsClosedAfterCompletion() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let writing = boards.writing
        let provisioning = boards.provisioning
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)
        let recorder = NotificationRecorder()

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            notifier: ExceptionNotifier { notification in
                // Writing-first ordering: the board already shows the completed state by the time the
                // local notification is posted.
                let scope = try await NightCardScope.resolve(using: provisioning)
                let issue = try #require(await writing.liveIssues.first)
                #expect(issue.workflowState == scope.completedState)
                recorder.record(notification)
            },
            work: { _ in }
        )
        try await invocation.run()

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        #expect(notification.project == fixture.projectID)
        guard case .closed = notification.event else {
            Issue.record("expected .closed, got \(notification.event)")
            return
        }
    }

    @Test("A non-closing Act never posts a local notification")
    func nonClosingActNeverNotifies() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let recorder = NotificationRecorder()

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in }
        )
        try await invocation.run()

        // The first Act opens the Night Card; `opened` posts nothing (G-10), and this Act never closes.
        #expect(recorder.notifications.isEmpty)
    }

    @Test("A failing Act records a halted comment on the Night Card first, then posts .halted, and rethrows")
    func failingActHaltsAndNotifies() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: boards.provisioning)
        let recorder = NotificationRecorder()
        let failure = SampleWorkFailure(description: "boom\nsecond line")

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { notification in
                let comments = await writing.comments
                #expect(comments.contains { $0.body.contains("Night halted") && $0.body.contains("boom") })
                recorder.record(notification)
            },
            work: { _ in throw failure }
        )

        do {
            try await invocation.run()
            Issue.record("expected the work error to be rethrown")
        } catch let error as SampleWorkFailure {
            #expect(error == failure)
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        guard case .halted(let reason) = notification.event else {
            Issue.record("expected .halted, got \(notification.event)")
            return
        }
        #expect(reason.contains("boom"))
        #expect(!reason.contains("\n"))
    }

    @Test("A closing Act with no headless app records a delivery failure but never fails the Night")
    func closingActWithMissingAppRecordsFailure() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let notifier = ExceptionNotifier.headlessApp(bundleIdentifier: "dev.yellowhammer.missing-\(UUID())")

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, notifier: notifier,
            work: { _ in }
        )
        try await invocation.run()

        let closedFailures = try closedDeliveryFailureReasons(journal: journal)
        #expect(closedFailures.count == 1)
        #expect(closedFailures.first?.isEmpty == false)
    }

    @Test("A closing Act whose app denies notifications records the app's own reason")
    func closingActWithDeniedNotificationsRecordsReason() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let scratch = try ScratchDirectory()
        let scriptPath = try scratch.writeOpenFixture(
            exitCode: 0, stderrMessage: "Yellowhammer: notifications are not authorized"
        )
        let notifier = ExceptionNotifier.headlessApp(openPath: scriptPath)

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, notifier: notifier,
            work: { _ in }
        )
        try await invocation.run()

        let closedFailures = try closedDeliveryFailureReasons(journal: journal)
        #expect(closedFailures.count == 1)
        #expect(closedFailures.first?.contains("notifications are not authorized") == true)
    }

    @Test("A failing notifier on the halted path never replaces the original error, and posts once")
    func haltedNotifierFailureDoesNotReplaceOriginalError() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let calls = Mutex(0)
        let failure = SampleWorkFailure(description: "boom")

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { _ in
                calls.withLock { $0 += 1 }
                throw SampleWorkFailure(description: "the notifier exploded")
            },
            work: { _ in throw failure }
        )

        do {
            try await invocation.run()
            Issue.record("expected the work error to be rethrown")
        } catch let error as SampleWorkFailure {
            #expect(error == failure)
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(calls.withLock { $0 } == 1)
        let events = try journal.events(ofType: .notificationDeliveryFailed)
        let haltedFailures = events.filter {
            guard case .notificationDeliveryFailed(let notification, _) = $0.event else { return false }
            return notification == "halted"
        }
        #expect(haltedFailures.count == 1)
    }

    @Test("A halted Act with no Night Card posts .haltedUnrecorded (OQ71)")
    func haltedActWithNoNightCardPostsUnrecorded() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let recorder = NotificationRecorder()
        // Fails the Night Card's own creation, so no Night Card ever opens for this run.
        await boards.writing.refuseNext(.unreachable("board unreachable"))

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in }
        )

        await #expect(throws: (any Error).self) { try await invocation.run() }

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        #expect(notification.project == fixture.projectID)
        guard case .haltedUnrecorded = notification.event else {
            Issue.record("expected .haltedUnrecorded, got \(notification.event)")
            return
        }
        // Nothing beyond `.actIncomplete` is recorded for this halt: no delivery failure now that the
        // notification itself posts.
        let deliveryFailures = try journal.events(ofType: .notificationDeliveryFailed)
        #expect(deliveryFailures.isEmpty)
    }

    @Test("A halted comment write that is aborted or permanently failed also posts .haltedUnrecorded (OQ71)")
    func haltedCommentAbortedOrFailedPostsUnrecorded() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let recorder = NotificationRecorder()
        let failure = SampleWorkFailure(description: "boom")
        let commentBody = "**Night halted:** the `build` Act did not complete: boom"
        // A permanent refusal on the halted comment's own body fails that specific write.
        await boards.writing.script(.refuse(.notAuthenticated("no token")), for: commentBody)

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in throw failure }
        )

        do {
            try await invocation.run()
            Issue.record("expected the work error to be rethrown")
        } catch let error as SampleWorkFailure {
            #expect(error == failure)
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        guard case .haltedUnrecorded = notification.event else {
            Issue.record("expected .haltedUnrecorded, got \(notification.event)")
            return
        }
    }

    @Test("A halted comment write left pending/deferred still posts the ordinary .halted(reason:)")
    func haltedCommentDeferredStillPostsOrdinaryHalted() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let recorder = NotificationRecorder()
        let failure = SampleWorkFailure(description: "boom")
        let commentBody = "**Night halted:** the `build` Act did not complete: boom"
        // A transient refusal on the comment leaves the write pending (deferred) — still "on the Night
        // Card first" per the ordinary rule.
        await boards.writing.script(.refuse(.unreachable("board unreachable")), for: commentBody)

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            notifier: ExceptionNotifier { recorder.record($0) },
            work: { _ in throw failure }
        )

        do {
            try await invocation.run()
            Issue.record("expected the work error to be rethrown")
        } catch let error as SampleWorkFailure {
            #expect(error == failure)
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(recorder.notifications.count == 1)
        let notification = try #require(recorder.notifications.first)
        guard case .halted(let reason) = notification.event else {
            Issue.record("expected .halted, got \(notification.event)")
            return
        }
        #expect(reason.contains("boom"))
    }

    @Test("makeInvocation passes the given notifier through to the invocation")
    func makeInvocationPassesNotifierThrough() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "yellowhammer")
        let parsed = try RootCommand.parseAsRoot(["land", "--project", "yellowhammer", "--force"])
        let command = try #require(parsed as? any ActCommand)
        let recorder = NotificationRecorder()

        let invocation = try command.makeInvocation(
            configurationDirectory: directory.url, now: Date(), bindBoard: nil, bindWorkspace: nil,
            notifier: ExceptionNotifier { recorder.record($0) }
        )
        try await invocation.notifier.post(sampleNotification)

        #expect(recorder.notifications == [sampleNotification])
    }

    private func closedDeliveryFailureReasons(journal: JournalStore) throws -> [String] {
        try journal.events(ofType: .notificationDeliveryFailed).compactMap {
            guard case .notificationDeliveryFailed(let notification, let reason) = $0.event, notification == "closed"
            else { return nil }
            return reason
        }
    }
}

@Suite("ExceptionNotifier.headlessApp interprets open's outcome")
struct HeadlessAppNotifierTests {
    @Test("The launched app's own stderr file names a failure to post")
    func appStderrIsAPostFailure() async throws {
        let scratch = try ScratchDirectory()
        let scriptPath = try scratch.writeOpenFixture(
            exitCode: 0, stderrMessage: "Yellowhammer: notifications are not authorized"
        )
        let notifier = ExceptionNotifier.headlessApp(openPath: scriptPath)

        do {
            try await notifier.post(sampleNotification)
            Issue.record("expected a throw")
        } catch let error as HeadlessPostError {
            guard case .postFailed(let reason) = error else {
                Issue.record("expected .postFailed, got \(error)")
                return
            }
            #expect(reason.contains("notifications are not authorized"))
        }
    }

    @Test("A clean app stderr file posts successfully")
    func cleanAppStderrSucceeds() async throws {
        let scratch = try ScratchDirectory()
        let scriptPath = try scratch.writeOpenFixture(exitCode: 0, stderrMessage: nil)
        let notifier = ExceptionNotifier.headlessApp(openPath: scriptPath)

        try await notifier.post(sampleNotification)
    }

    @Test("open exiting non-zero is a launch failure, not a post failure")
    func openNonZeroIsLaunchFailure() async throws {
        let scratch = try ScratchDirectory()
        let scriptPath = try scratch.writeOpenFixture(exitCode: 1, stderrMessage: nil)
        let notifier = ExceptionNotifier.headlessApp(openPath: scriptPath)

        do {
            try await notifier.post(sampleNotification)
            Issue.record("expected a throw")
        } catch let error as HeadlessPostError {
            guard case .launchFailed = error else {
                Issue.record("expected .launchFailed, got \(error)")
                return
            }
        }
    }

    @Test("The launched script receives -n, -W, -b, the bundle id, and --args followed by the notification's own")
    func scriptReceivesExpectedArguments() async throws {
        let scratch = try ScratchDirectory()
        let argsFile = scratch.directory.appending(component: "args.txt")
        let scriptPath = try scratch.writeOpenFixture(exitCode: 0, stderrMessage: nil, argsDumpPath: argsFile.path)
        let bundleIdentifier = "dev.yellowhammer.test-\(UUID())"
        let notifier = ExceptionNotifier.headlessApp(bundleIdentifier: bundleIdentifier, openPath: scriptPath)

        try await notifier.post(sampleNotification)

        let arguments = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(arguments.contains("-n"))
        #expect(arguments.contains("-W"))
        let bIndex = try #require(arguments.firstIndex(of: "-b"))
        #expect(arguments[bIndex + 1] == bundleIdentifier)
        let argsIndex = try #require(arguments.firstIndex(of: "--args"))
        #expect(Array(arguments[(argsIndex + 1)...]) == sampleNotification.arguments)
    }
}

/// A throwaway directory for the shell scripts that stand in for `/usr/bin/open` in these tests.
private struct ScratchDirectory: ~Copyable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-open-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an executable `/bin/sh` script that mimics enough of `open`'s contract for
    /// ``ExceptionNotifier/headlessApp(bundleIdentifier:openPath:timeout:)`` to be tested against:
    /// it finds the path after `--stderr` and writes `stderrMessage` to it (nothing, if `nil`), and
    /// optionally dumps its own arguments, one per line, to `argsDumpPath`.
    func writeOpenFixture(exitCode: Int32, stderrMessage: String?, argsDumpPath: String? = nil) throws -> String {
        let scriptURL = directory.appending(component: "open-\(UUID().uuidString).sh")
        var lines = ["#!/bin/sh"]
        if let argsDumpPath {
            lines.append("printf '%s\\n' \"$@\" > \(Self.quoted(argsDumpPath))")
        }
        lines.append(contentsOf: [
            "while [ \"$#\" -gt 0 ]; do",
            "  case \"$1\" in",
            "    --stderr) shift; STDERR_FILE=\"$1\" ;;",
            "  esac",
            "  shift",
            "done"
        ])
        if let stderrMessage {
            lines.append("printf '%s' \(Self.quoted(stderrMessage)) > \"$STDERR_FILE\"")
        }
        lines.append("exit \(exitCode)")
        try (lines.joined(separator: "\n") + "\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }

    private static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
