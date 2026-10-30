import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), item 3: the pull request body's report shows the commit Verification judged, per
// repository, in short form; a record written before this rule shows "judged commit not recorded" and is never
// filled in from the Feature Branch record (`landed_commit`). These go through the real-git land world, so the
// body is the one the real pull request seam renders, and no remote read can reach a GitHub URL. Spec at
// yellowhammer-spec f33bccf. Red cases are known issues until their behaviour lands.

/// The body of the pull request opened for `repository`.
private func body(_ world: OQ191LandWorld, _ repository: String) async throws -> String {
    try #require(await world.publication.calls.last { $0.repository == repository }?.body)
}

/// Records a Verification of every clause through today's API, which names no judged commit: a record from
/// before this rule.
private func recordVerificationBeforeTheRule(_ world: OQ191LandWorld) throws {
    let clauses = world.repositories.map { repository in
        let issue = repository.name == "backend" ? "BACK-1" : "MOB-1"
        return ClauseVerificationRecord(
            issueID: issue, cid: "c1", level: "card", text: "Clause c1 of \(issue).", locationID: "resolvable/story",
            citationProvenance: "machine-found", verdict: .met, whatWasChecked: "read the code",
            interpretation: "as written", judgedBy: .agent
        )
    }
    try #require(try world.env.journal.recordFeatureVerification(NewFeatureVerification(
        featureID: world.feature.id, cycleID: world.cycleID, route: routeOther.description,
        nightID: world.env.context.night.id, runID: world.env.runID, clauses: clauses
    )))
}

@Suite("OQ191 pull request body: the judged commit per repository", .tags(.oq191))
struct OQ191PullRequestBodyTests {
    // landing/stories/open-one-pull-request-per-repository.md#judged-commit-in-body
    @Test(
        "item 3: the body shows each repository with the short commit Verification judged",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func bodyShowsTheJudgedCommitPerRepository() async throws {
        let world = try await OQ191LandWorld.make()
        let firing = await world.fire()
        try #require(firing.error == nil)
        let lines = try await body(world, "backend").split(separator: "\n")

        withKnownIssue("OQ191 item 3: the pull request body shows no judged commit") {
            for repository in world.repositories {
                #expect(lines.contains { $0.contains(repository.name) && $0.contains(oq191Short(repository.tip)) })
            }
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#judged-commit-in-body
    @Test(
        "item 3: for a record written before this rule, the body shows judged commit not recorded",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func bodyShowsJudgedCommitNotRecorded() async throws {
        let world = try await OQ191LandWorld.make()
        try recordVerificationBeforeTheRule(world)
        let firing = await world.fire()
        try #require(firing.error == nil)
        try #require(firing.dispatch.requests.isEmpty)
        let text = try await body(world, "backend")

        withKnownIssue("OQ191 item 3: the pull request body shows no judged commit") {
            #expect(text.contains("judged commit not recorded"))
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#judged-commit-in-body
    @Test(
        "item 3: characterization: for a record written before this rule, the body never shows landed_commit",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func bodyIsNeverFilledFromLandedCommit() async throws {
        let world = try await OQ191LandWorld.make()
        try recordVerificationBeforeTheRule(world)
        let firing = await world.fire()
        try #require(firing.error == nil)
        let backend = world["backend"]
        let landed = try world.env.journal.landedCommit(featureID: world.feature.id, repository: "backend")
        try #require(landed == backend.tip)

        #expect(try await !body(world, "backend").contains(oq191Short(backend.tip)))
    }
}
