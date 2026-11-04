import Domain
@testable import Engine
import Foundation
import Testing

// Pin Failure item 2 and OQ196 item 2 (spec: landing/open-one-pull-request-per-repository, `#pin-failure`,
// `#uncommitted-snapshot`): what the decision reads for a gone or non-git Worktree directory before it touches the
// main clone. The lead judgements are tested here directly: no recorded commit pins nothing, and a main clone that
// cannot be read fails the branch step, which keeps the Worktree held at land and at cancellation.

private let decisionBranch = FeatureBranch(rawValue: "yh-decision-feature")

private func scratchDirectory(_ name: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appending(component: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path(percentEncoded: false)
}

private func gonePath() -> String {
    FileManager.default.temporaryDirectory
        .appending(component: "decision-gone-\(UUID().uuidString)").path(percentEncoded: false)
}

@Suite("Unpublished pin decision: gone and non-git Worktree directories read the main clone")
struct UnpublishedPinDecisionTests {
    // landing/stories/open-one-pull-request-per-repository.md#pin-failure
    @Test("Lead judgement: a gone directory with no recorded commit pins nothing, even with no main clone")
    func goneWithoutRecordedCommitIsNotNeeded() async {
        let decision = await UnpublishedPinDecision.evaluate(
            worktreePath: gonePath(), mainClonePath: nil, recordedCommit: nil,
            branch: decisionBranch, reporting: ("repo", false)
        )
        guard case .gone(.notNeeded) = decision else {
            Issue.record("expected .gone(.notNeeded), got \(decision)")
            return
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#pin-failure
    @Test("Lead judgement: a gone directory with no configured main clone fails the branch step")
    func goneWithoutMainCloneFails() async {
        let decision = await UnpublishedPinDecision.evaluate(
            worktreePath: gonePath(), mainClonePath: nil, recordedCommit: "abc1234",
            branch: decisionBranch, reporting: ("repo", false)
        )
        guard case .gone(.failed) = decision else {
            Issue.record("expected .gone(.failed), got \(decision)")
            return
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#pin-failure
    @Test("Lead judgement: a gone directory whose main clone is no git repository fails the branch step")
    func goneWithUnreadableMainCloneFails() async throws {
        let decision = await UnpublishedPinDecision.evaluate(
            worktreePath: gonePath(), mainClonePath: try scratchDirectory("decision-not-a-clone"),
            recordedCommit: "abc1234",
            branch: decisionBranch, reporting: ("repo", false)
        )
        guard case .gone(.failed) = decision else {
            Issue.record("expected .gone(.failed), got \(decision)")
            return
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#uncommitted-snapshot
    @Test("A non-git directory whose main clone is no git repository reads as not a git work tree, failed")
    func notGitWithUnreadableMainCloneFails() async throws {
        let decision = await UnpublishedPinDecision.evaluate(
            worktreePath: try scratchDirectory("decision-not-git"),
            mainClonePath: try scratchDirectory("decision-not-a-clone"),
            recordedCommit: "abc1234",
            branch: decisionBranch, reporting: ("repo", false)
        )
        guard case .notGitWorktree(.failed) = decision else {
            Issue.record("expected .notGitWorktree(.failed), got \(decision)")
            return
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#uncommitted-snapshot
    @Test("A non-git directory with no recorded commit pins nothing, and still reads as not a git work tree")
    func notGitWithoutRecordedCommitIsNotNeeded() async throws {
        let decision = await UnpublishedPinDecision.evaluate(
            worktreePath: try scratchDirectory("decision-not-git"), mainClonePath: nil, recordedCommit: nil,
            branch: decisionBranch, reporting: ("repo", false)
        )
        guard case .notGitWorktree(.notNeeded) = decision else {
            Issue.record("expected .notGitWorktree(.notNeeded), got \(decision)")
            return
        }
    }
}
