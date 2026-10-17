import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// Every failure event reads in the Night's account with its reason as detail, never the bare event name, and
// a failure is a problem for the playhead's "from problem to problem" step
// (app/land-on-the-sidebar-and-pulse#failure-line). A halt and a usage limit are decisions and deferrals, not
// failures, so they are worded and not marked.

private let moment = Date(timeIntervalSince1970: 1_790_000_000)

private func failureEntry(
    _ event: JournalEvent, cardNames: [Int64: String] = [:]
) -> NightAccount.Entry {
    let record = JournalEventRecord(
        id: 7, event: event, act: .land, runID: nil, nightID: 1, occurredAt: moment
    )
    return NightAccount.Entry(record: record, cardNames: cardNames)
}

private func failureRoute() throws -> Route {
    try #require(Route(cli: "claude", model: "opus", effort: "high"))
}

private func step(
    _ step: LandStep, _ repository: String?, _ outcome: LandStepOutcome, _ detail: String?
) -> NightAccount.Entry {
    failureEntry(.landStep(step: step, repository: repository, outcome: outcome, detail: detail))
}

@Suite("The Night's account words every failure event")
struct NightAccountFailureWordingTests {
    @Test("Board writes rolled back name the reason and the group")
    func rolledBack() {
        let words = failureEntry(.outboxGroupRolledBack(groupID: "grp-1", reason: "Linear refused the second create"))
        #expect(words.headline == "Board writes rolled back")
        #expect(words.detail == "Linear refused the second create (group grp-1)")
        #expect(words.isProblem)
    }

    @Test("A broken Managed Block names what the engine did")
    func delimiterBroken() {
        let words = failureEntry(.managedBlockDelimiterBroken(issueID: "11111111-2222-3333-4444-555555555555"))
        #expect(words.headline == "A Managed Block's delimiters were broken")
        #expect(words.detail?.contains("was not rewritten this Night") == true)
        #expect(words.detail?.contains("11111111") == false)
        #expect(words.isProblem)
    }

    @Test("A lost Worktree names the Repo, its path, the lost commit and the Done Cards lost")
    func worktreeLost() {
        let words = failureEntry(
            .worktreeLost(
                featureID: 1, repository: "seshes-backend", worktreeID: "wt", path: "/work/wt", pinnedCommit: nil,
                lostCommit: "abc1234", lostDoneCardIDs: [1, 2]
            )
        )
        #expect(words.headline == "seshes-backend: Worktree lost")
        #expect(words.detail == "/work/wt; lost commit abc1234; 2 Done Cards lost")
        #expect(words.isProblem)
    }

    @Test("A lost Worktree with nothing lost names only its path")
    func worktreeLostNothingLost() {
        let words = failureEntry(
            .worktreeLost(
                featureID: 1, repository: "seshes-backend", worktreeID: "wt", path: "/work/wt", pinnedCommit: "abc"
            )
        )
        #expect(words.detail == "/work/wt")
    }

    @Test("A failed reconciliation names the Repo and the reason")
    func reconciliationFailed() {
        let words = failureEntry(
            .worktreeReconciliationFailed(
                featureID: 1, repository: "seshes-backend", path: "/work/wt", reason: "git reset refused"
            )
        )
        #expect(words.headline == "seshes-backend: Worktree reconciliation failed")
        #expect(words.detail == "/work/wt: git reset refused")
        #expect(words.isProblem)
    }

    @Test("A mainline conflict names the first paths and counts the rest")
    func mainlineConflict() {
        let few = failureEntry(
            .mainlineConflictDetected(featureIssueID: "F", repository: "api", paths: ["a.swift", "b.swift"])
        )
        #expect(few.headline == "api: conflicts with mainline")
        #expect(few.detail == "a.swift, b.swift")
        let many = failureEntry(
            .mainlineConflictDetected(featureIssueID: "F", repository: "api", paths: ["a", "b", "c", "d", "e"])
        )
        #expect(many.detail == "a, b, c and 2 more")
        #expect(many.isProblem)
    }

    @Test("A failed readiness check names the Card and every failure")
    func readinessFailed() {
        let words = failureEntry(
            .readinessCheckFailed(cardID: 4, issueID: "uuid", failures: ["no Definition of Done", "no repository"]),
            cardNames: [4: "ALPHA-4"]
        )
        #expect(words.headline == "ALPHA-4: readiness check failed")
        #expect(words.detail?.hasPrefix("no Definition of Done; no repository") == true)
        #expect(words.isProblem)
    }

    @Test("Waiting on You with no record behind it names the Card, or says a Card")
    func waitingOnYouUnbacked() {
        let named = failureEntry(
            .waitingOnYouUnbacked(issueID: "uuid", cardID: 4, reason: "no waiting reason recorded"),
            cardNames: [4: "ALPHA-4"]
        )
        #expect(named.headline == "ALPHA-4: in Waiting on You with no record behind it")
        #expect(named.detail == "no waiting reason recorded. Not dispatched.")
        #expect(named.isProblem)
        let unknown = failureEntry(.waitingOnYouUnbacked(issueID: "uuid", cardID: nil, reason: "unknown object"))
        #expect(unknown.headline == "A Card: in Waiting on You with no record behind it")
    }

    @Test("A failed land step reads as the step and its outcome, a completed one is not a problem")
    func landStep() {
        let failed = step(.push, "seshes-backend", .failed, "not pushed")
        #expect(failed.headline == "seshes-backend: push failed")
        #expect(failed.detail == "not pushed")
        #expect(failed.isProblem)
        let verification = step(.verification, nil, .failed, "boom")
        #expect(verification.headline == "Verification failed")
        #expect(verification.isProblem)
        let completed = step(.push, "seshes-backend", .completed, nil)
        #expect(completed.headline == "seshes-backend: push completed")
        #expect(!completed.isProblem)
        #expect(!step(.push, "a", .skipped, "x").isProblem)
        #expect(!step(.openPullRequest, "a", .notWired, nil).isProblem)
    }

    @Test("An Authoring Halt is worded with its cause and is not a problem")
    func authoringHalted() {
        let words = failureEntry(
            .featureAuthoringHalted(name: "Sync", reasonKind: "contract-outside-project", detail: "elsewhere")
        )
        #expect(words.headline == "Authoring the Feature “Sync” halted")
        #expect(words.detail == "it names a repository outside this Project: elsewhere")
        #expect(!words.isProblem)
        let unknown = failureEntry(.featureAuthoringHalted(name: "Sync", reasonKind: "something-new", detail: nil))
        #expect(unknown.detail == "something-new")
        let seam = failureEntry(
            .featureAuthoringHalted(name: "Sync", reasonKind: "no-backward-compatible-seam", detail: "model text")
        )
        #expect(seam.detail == "no backward-compatible seam was found")
    }

    @Test("A usage limit is worded with when the Route is backed off to and is not a problem")
    func usageLimited() throws {
        let words = failureEntry(
            .routeUsageLimited(route: "claude/opus/high", cli: "claude", until: moment, resetHint: "resets at 5pm")
        )
        #expect(words.headline == "claude usage limit on claude/opus/high")
        #expect(words.detail?.hasPrefix("Backing off until") == true)
        #expect(words.detail?.hasSuffix("the CLI reports: resets at 5pm") == true)
        #expect(!words.isProblem)
    }

    @Test("An Attempt that hard-failed is a problem; one that succeeded is not")
    func attempts() throws {
        let hard = failureEntry(
            .attemptEnded(
                cardID: 4, issueID: "uuid", attemptID: 1, route: try failureRoute(),
                outcome: AttemptOutcome.hardFailure.rawValue, routeExcluded: true
            ),
            cardNames: [4: "ALPHA-4"]
        )
        #expect(hard.isProblem)
        let success = failureEntry(
            .attemptEnded(
                cardID: 4, issueID: "uuid", attemptID: 2, route: try failureRoute(),
                outcome: AttemptOutcome.success.rawValue, routeExcluded: false
            ),
            cardNames: [4: "ALPHA-4"]
        )
        #expect(!success.isProblem)
    }

    @Test("None of the worded events reads as its bare event name")
    func noneIsBare() throws {
        let events: [JournalEvent] = [
            .outboxGroupRolledBack(groupID: "g", reason: "r"),
            .managedBlockDelimiterBroken(issueID: "i"),
            .worktreeLost(featureID: 1, repository: "r", worktreeID: "w", path: "/p", pinnedCommit: nil),
            .worktreeReconciliationFailed(featureID: 1, repository: "r", path: "/p", reason: "x"),
            .mainlineConflictDetected(featureIssueID: "F", repository: "r", paths: []),
            .readinessCheckFailed(cardID: 1, issueID: "i", failures: ["f"]),
            .waitingOnYouUnbacked(issueID: "i", cardID: nil, reason: "x"),
            .featureAuthoringHalted(name: "n", reasonKind: "k", detail: nil),
            .landStep(step: .push, repository: nil, outcome: .failed, detail: nil),
            .routeUsageLimited(route: "r", cli: "c", until: moment, resetHint: nil)
        ]
        for event in events {
            #expect(failureEntry(event).headline != NightAccount.plainName(of: event.type), "\(event.type)")
        }
    }

    @Test("The seven problem types that were already marked still are")
    func existingProblemTypes() throws {
        let nightStart = try #require(NightStart(rawValue: "2026-10-11"))
        let events: [JournalEvent] = [
            .linearAuthorizationHalted, .linearUnreachableHalted,
            .mainlineFetchFailed(repository: "r", reason: "x"), .absentNightDetected(nightStart: nightStart),
            .notificationDeliveryFailed(notification: "closed", reason: "x"),
            .boardWriteFailed(clientID: UUID(), operation: "o", issueID: nil, reason: "x"),
            .rateBudgetExhausted(degradation: "d", installation: nil)
        ]
        for event in events {
            #expect(failureEntry(event).isProblem, "\(event.type)")
        }
    }

    @Test("A failed land step and a hard-failed Attempt are problem times in the timeline")
    func problemTimesInTheTimeline() throws {
        let failedStep = failureEntry(.landStep(step: .push, repository: "a", outcome: .failed, detail: "x"))
        let hardAttempt = failureEntry(
            .attemptEnded(
                cardID: 4, issueID: "u", attemptID: 1, route: try failureRoute(),
                outcome: AttemptOutcome.hardFailure.rawValue, routeExcluded: false
            )
        )
        var later = hardAttempt
        later.occurredAt = moment.addingTimeInterval(60)
        let run = NightAccount.ActRun(
            id: "r", act: "land", startedAt: moment, outcome: .ended, entries: [failedStep, later]
        )
        let account = NightAccount(
            id: 1, nightStart: "2026-10-11", mode: .real, state: .done, openedAt: moment,
            completedAt: moment.addingTimeInterval(120), closeReason: nil, nightCard: nil, runs: [run]
        )

        #expect(NightTimeline(account: account).problemTimes == [moment, moment.addingTimeInterval(60)])
    }
}
