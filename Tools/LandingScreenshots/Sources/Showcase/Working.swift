import Domain
import Foundation

@testable import Journal

// `working/`: the same Night, still running, its build Act mid-flight. The first build run (22:16 to 23:27)
// finished ORB-213 and ORB-215 and ended. The live build run started 16 minutes before `now` and holds the
// Act Lease, last heartbeat 2 minutes before `now`, so it is held until `now + 8 minutes` and never released.
// Within it, in this order (so the attempt ids are fixed):
//
// - attempt 3: ORB-214, Attempt 1 on codex, ended in a hard failure 7 minutes before `now`;
// - attempt 4: ORB-216 in orbit-web on `codex/gpt-5.4/high`, started 14 minutes ago, Round 2 (the reviewer
//   asked for changes once);
// - attempt 5: ORB-214 in orbit-api, Attempt 2 on `claude/opus/high`, started 6 minutes ago, Round 1;
// - attempt 6: ORB-218 in orbit-ios on `agy/gemini-3-pro/high`, started 3 minutes ago, Round 1.
//
// (Attempts 1 and 2 are ORB-213's and ORB-215's, from the first run.) ORB-217 and ORB-219 are still Todo.

func seedWorking(_ journal: JournalStore, clock: ShowcaseClock) throws {
    let night = try seedAuthorRun(journal, clock: clock)
    try seedFirstBuildRun(journal, clock: clock, night: night)
    try seedLiveBuildRun(journal, clock: clock, night: night)
}

private func seedFirstBuildRun(_ journal: JournalStore, clock: ShowcaseClock, night: ShowcaseNight) throws {
    let run = try ShowcaseRun.begin(journal, act: .build, nightID: night.nightID, at: clock.night(22, 16))
    let sonnet = try Showcase.route("claude/sonnet/medium")
    var script = ShowcaseScript()
    script.at(clock.night(22, 17)) {
        try $0.record(.repoLaneStarted(repository: Showcase.apiRepo, cards: 2), at: clock.night(22, 17))
    }
    script.card(213, on: sonnet, from: clock.night(22, 18), to: clock.night(22, 52))
    script.card(215, on: sonnet, from: clock.night(22, 54), to: clock.night(23, 25))
    script.at(clock.night(23, 26)) {
        try $0.record(
            .repoLaneEnded(repository: Showcase.apiRepo, cardsRun: 2, failure: nil), at: clock.night(23, 26)
        )
    }
    try script.play(on: run)
    try run.finish(at: clock.night(23, 27))
}

private func seedLiveBuildRun(_ journal: JournalStore, clock: ShowcaseClock, night: ShowcaseNight) throws {
    let run = try ShowcaseRun.begin(journal, act: .build, nightID: night.nightID, at: clock.ago(16))
    let codex = try Showcase.route("codex/gpt-5.4/high")
    let opus = try Showcase.route("claude/opus/high")
    let agy = try Showcase.route("agy/gemini-3-pro/high")
    var script = ShowcaseScript()
    for (repo, cards) in [(Showcase.apiRepo, 1), (Showcase.webRepo, 1), (Showcase.iosRepo, 1)] {
        script.at(clock.ago(16) + 10) {
            try $0.record(.repoLaneStarted(repository: repo, cards: cards), at: clock.ago(16) + 10)
        }
    }
    script.at(clock.ago(15)) { try $0.startAttempt(214, on: codex, at: clock.ago(15)) }
    script.at(clock.ago(7)) { try $0.failOnUsageLimit(214, at: clock.ago(7)) }
    script.at(clock.ago(14)) { try $0.startAttempt(216, on: codex, at: clock.ago(14)) }
    script.at(clock.ago(11)) { try $0.workAndCheck(216, at: clock.ago(11)) }
    script.at(clock.ago(10)) {
        try $0.requestChanges(216, note: "Keep the list sorted by last use.", at: clock.ago(10))
    }
    script.at(clock.ago(9)) { try $0.step(216, .worker, "round 2 started", at: clock.ago(9)) }
    script.at(clock.ago(6)) { try $0.startAttempt(214, on: opus, at: clock.ago(6)) }
    script.at(clock.ago(3)) { try $0.startAttempt(218, on: agy, at: clock.ago(3)) }
    try script.play(on: run)
    // The run is alive: heartbeat two minutes ago, never released.
    try run.beat(clock.ago(2))
}
