import Domain
import Foundation

@testable import Journal

// `morning/`: the Night is done. The author Act authored the Cycle at 22:00; one long build Act run (22:16 to
// 03:12) ran the three Repo Lanes side by side, with one problem: ORB-214's Attempt 1, on codex, hit a usage
// limit at 01:40 and ended in a hard failure, and its Attempt 2 ran on a different Route and was approved.
// Build firings after that found nothing left to build; the land Act (05:30 to 05:42) verified all 18 clauses
// and opened one pull request per Repo; the land firing at 06:00 closed the Night.
//
// The Cycle is deliberately left unarchived: the Pulse shows a Feature only while its Cycle is open, and the
// screenshots show the Feature's three lanes with their pull requests.

func seedMorning(_ journal: JournalStore, clock: ShowcaseClock) throws {
    let night = try seedAuthorRun(journal, clock: clock)
    try seedLongBuildRun(journal, clock: clock, night: night)
    try seedIdleBuildFirings(journal, clock: clock, night: night)
    try seedLandRun(journal, clock: clock, night: night)
    try closeNight(journal, clock: clock, night: night)
}

private func seedLongBuildRun(_ journal: JournalStore, clock: ShowcaseClock, night: ShowcaseNight) throws {
    let run = try ShowcaseRun.begin(journal, act: .build, nightID: night.nightID, at: clock.night(22, 16))
    let sonnet = try Showcase.route("claude/sonnet/medium")
    let codex = try Showcase.route("codex/gpt-5.4/high")
    let opus = try Showcase.route("claude/opus/high")
    let agy = try Showcase.route("agy/gemini-3-pro/high")
    var script = ShowcaseScript()
    for (repo, cards) in [(Showcase.apiRepo, 3), (Showcase.webRepo, 2), (Showcase.iosRepo, 2)] {
        script.at(clock.night(22, 17)) {
            try $0.record(.repoLaneStarted(repository: repo, cards: cards), at: clock.night(22, 17))
        }
    }
    // orbit-api: 213, then 214 (two Attempts), then 215.
    script.card(213, on: sonnet, from: clock.night(22, 18), to: clock.night(24, 5))
    script.at(clock.night(24, 10)) { try $0.startAttempt(214, on: codex, at: clock.night(24, 10)) }
    script.at(clock.night(25, 40)) { try $0.failOnUsageLimit(214, at: clock.night(25, 40)) }
    script.card(214, on: opus, from: clock.night(25, 41), to: clock.night(26, 35))
    script.card(215, on: sonnet, from: clock.night(26, 36), to: clock.night(27, 8))
    // orbit-web: 216, then 217 (one Round asking for changes).
    script.card(216, on: codex, from: clock.night(22, 20), to: clock.night(23, 40))
    script.at(clock.night(24, 40)) { try $0.startAttempt(217, on: codex, at: clock.night(24, 40)) }
    script.at(clock.night(24, 55)) {
        try $0.requestChanges(217, note: "Cover the empty-name case.", at: clock.night(24, 55))
    }
    script.at(clock.night(25, 29)) { try $0.approve(217, at: clock.night(25, 29)) }
    // orbit-ios: 218, then 219.
    script.card(218, on: agy, from: clock.night(22, 25), to: clock.night(24, 30))
    script.card(219, on: agy, from: clock.night(24, 35), to: clock.night(26, 20))
    let laneEnds = [
        (repo: Showcase.webRepo, end: clock.night(25, 31)),
        (repo: Showcase.iosRepo, end: clock.night(26, 22)),
        (repo: Showcase.apiRepo, end: clock.night(27, 9))
    ]
    for lane in laneEnds {
        let cards = Showcase.cards.count { $0.repo == lane.repo }
        script.at(lane.end) {
            try $0.record(.repoLaneEnded(repository: lane.repo, cardsRun: cards, failure: nil), at: lane.end)
        }
    }
    try script.play(on: run)
    try run.finish(at: clock.night(27, 12))
}

/// Build firings between the long run and the land Act: each finds nothing left to build, and ends at once.
private func seedIdleBuildFirings(_ journal: JournalStore, clock: ShowcaseClock, night: ShowcaseNight) throws {
    let beforeLand = [(27, 30), (27, 45), (28, 0), (28, 15), (28, 30), (28, 45), (29, 0), (29, 15)]
    let firings = beforeLand.map { (clock.night($0.0, $0.1), ActIdleReason.cycleHasNoUnfinishedCards) }
        + [(clock.night(29, 45), ActIdleReason.cycleAlreadyLanded)]
    for (start, reason) in firings {
        let run = try ShowcaseRun.begin(journal, act: .build, nightID: night.nightID, at: start)
        try run.record(.actIdle(reason: reason), at: start + 2)
        _ = try journal.releaseActLease(runID: run.runID)
    }
}

/// 05:30 to 05:42: each Repo Lane's merge test, push, pull request and Worktree release, then Verification.
private func seedLandRun(_ journal: JournalStore, clock: ShowcaseClock, night: ShowcaseNight) throws {
    let run = try ShowcaseRun.begin(journal, act: .land, nightID: night.nightID, at: clock.night(29, 30))
    let lanes = [(Showcase.apiRepo, 418), (Showcase.iosRepo, 97), (Showcase.webRepo, 233)]
    for (index, lane) in lanes.enumerated() {
        let start = clock.night(29, 31 + index * 3)
        try landLane(run, repo: lane.0, pullRequest: lane.1, featureID: night.featureID, at: start)
    }
    try run.beat(clock.night(29, 40))
    try journal.markCycleLanded(cycleID: night.cycleID, runID: run.runID, now: clock.night(29, 40))
    try run.record(.cycleLanded(cycleID: night.cycleID), at: clock.night(29, 40))
    try verifyFeature(run, night: night, at: clock.night(29, 41))
    try run.finish(at: clock.night(29, 42))
}

private func landLane(_ run: ShowcaseRun, repo: String, pullRequest: Int, featureID: Int64, at start: Date) throws {
    let url = "https://github.com/orbit-hq/\(repo)/pull/\(pullRequest)"
    try run.journal.recordFeatureBranch(
        featureID: featureID, repository: repo, branch: FeatureBranch(rawValue: Showcase.featureBranch)
    )
    try run.record(.landStep(step: .mergeTest, repository: repo, outcome: .completed, detail: nil), at: start)
    try run.record(
        .landStep(step: .push, repository: repo, outcome: .completed, detail: Showcase.featureBranch),
        at: start + 20
    )
    try run.journal.recordLandedCommit(
        featureID: featureID, repository: repo, commit: "5eed\(pullRequest)", runID: run.runID, now: start + 20
    )
    try run.beat(start + 40)
    try run.journal.recordPullRequest(
        featureID: featureID, repository: repo, url: url, nightID: run.nightID, runID: run.runID, now: start + 40
    )
    try run.record(
        .landStep(step: .openPullRequest, repository: repo, outcome: .completed, detail: url), at: start + 40
    )
    try run.record(
        .landStep(step: .releaseWorktree, repository: repo, outcome: .completed, detail: nil), at: start + 60
    )
}

/// The verifier judged all 18 clauses of the Feature met.
private func verifyFeature(_ run: ShowcaseRun, night: ShowcaseNight, at time: Date) throws {
    let clauses = (1...18).map { index in
        ClauseVerificationRecord(
            issueID: Showcase.issueID(212), cid: "C\(index)", level: "feature",
            text: "Saved searches behave as specified (clause \(index)).", locationID: "saved-searches/\(index)",
            citationProvenance: "machine-found", verdict: .met, whatWasChecked: "The merged change and its tests.",
            interpretation: "The behaviour is present and covered.", judgedBy: .agent
        )
    }
    try run.journal.recordFeatureVerification(
        NewFeatureVerification(
            featureID: night.featureID, cycleID: night.cycleID, route: "claude/opus/high",
            nightID: night.nightID, runID: run.runID, clauses: clauses
        ),
        now: time
    )
    try run.record(.landStep(step: .verification, repository: nil, outcome: .completed, detail: nil), at: time)
    try run.record(.featureVerified(cycleID: night.cycleID, met: 18, unmet: 0, unresolved: 0), at: time + 1)
}

/// The land firing at `night_end`, 06:00: nothing left to land, so it closes the Night.
private func closeNight(_ journal: JournalStore, clock: ShowcaseClock, night: ShowcaseNight) throws {
    let run = try ShowcaseRun.begin(journal, act: .land, nightID: night.nightID, at: clock.night(29, 59, 50))
    try run.record(.actIdle(reason: .cycleAlreadyLanded), at: clock.night(29, 59, 52))
    try run.beat(clock.night(30, 0))
    try journal.closeNight(
        id: night.nightID, reason: .nightEnd, act: .land, runID: run.runID, now: clock.night(30, 0)
    )
    try run.finish(at: clock.night(30, 0, 1))
}
