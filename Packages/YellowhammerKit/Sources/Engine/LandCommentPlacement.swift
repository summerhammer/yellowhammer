import Domain
import Foundation
import Journal

/// Where the land Act comments on a repository's lane: the Feature Card and each Work Card of the lane that is Done
/// and still on the board, where a refused push is reported. The one place that decides which Cards receive a land
/// comment; the "not published" report and the remote tip failure both post through it.
struct LandCommentPlacement {
    let cycleID: Int64
    let repository: String
    let issues: [String]

    init(cycleID: Int64, repository: String, featureIssueID: String, laneCards: [CardRecord]) {
        self.cycleID = cycleID
        self.repository = repository
        issues = [featureIssueID]
            + laneCards.filter { $0.state == .done && !$0.isRemovedFromBoard }.map(\.issueID)
    }

    /// Posts `body` on each Card, under `land:<cycle>:<repository>:<keySuffix>:<issue>`. One key per Cycle,
    /// repository and suffix: a later firing posts nothing again.
    func post(_ body: String, keySuffix: String, outbox: Outbox?) async {
        guard let outbox else { return }
        let prefix = "land:\(cycleID):\(repository):\(keySuffix)"
        for issue in issues {
            let write = OutboxWrite(
                key: "\(prefix):\(issue)", write: .createComment(issue: BoardObjectID(rawValue: issue), body: body)
            )
            _ = try? await outbox.post(write)
        }
    }
}
