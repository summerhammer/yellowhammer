import Domain
@testable import Engine
import Journal
import Testing

// The roll-up Managed Block (roadmap P12.3; spec: board-projection/maintain-the-managed-block, second
// story): pure rendering from a ``FeatureRollUp``, no Journal access.

@Suite("Feature Roll-up block (P12.3)")
struct FeatureRollUpBlockTests {
    private func member(
        _ issueID: String, repo: String, order: Int, state: CardState,
        waitingReason: WaitingReason? = nil, blockReason: String? = nil,
        markers: Set<FeatureMemberMarker> = [], adoptedFrom: String? = nil
    ) -> RollUpMember {
        RollUpMember(issueID: issueID, repository: repo, authoredOrder: order, state: state,
                     waitingReason: waitingReason, blockReason: blockReason, markers: markers,
                     adoptedFromFeatureIssueID: adoptedFrom)
    }

    private func noMerge() -> MergedFraction { MergedFraction(mergedCount: 0, totalCount: 0) }

    @Test("Zero-Card block is just the sentence line")
    func zeroCardBlockIsJustTheSentence() {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(rendered == "**authoring · no Cards yet · in authoring**")
    }

    @Test("Lanes are ordered by worst live-Card severity, ties by repository name")
    func laneOrderingBySeverity() {
        let rollUp = FeatureRollUp(
            members: [
                member("D-1", repo: "docs", order: 0, state: .done),
                member("A-1", repo: "api", order: 0, state: .waitingOnYou),
                member("W-1", repo: "web", order: 0, state: .blocked)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        let apiIndex = rendered.range(of: "#### `api`")!.lowerBound
        let webIndex = rendered.range(of: "#### `web`")!.lowerBound
        let docsIndex = rendered.range(of: "#### `docs`")!.lowerBound
        #expect(apiIndex < webIndex)
        #expect(webIndex < docsIndex)
    }

    @Test("Within a lane, live Cards are ordered by severity, ties by authoredOrder")
    func inLaneOrdering() {
        let rollUp = FeatureRollUp(
            members: [
                member("B-2", repo: "backend", order: 1, state: .done),
                member("B-1", repo: "backend", order: 0, state: .inProgress),
                member("B-3", repo: "backend", order: 2, state: .blocked)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        let blockedIndex = rendered.range(of: "`B-3`")!.lowerBound
        let inProgressIndex = rendered.range(of: "`B-1`")!.lowerBound
        let doneIndex = rendered.range(of: "`B-2`")!.lowerBound
        #expect(blockedIndex < inProgressIndex)
        #expect(inProgressIndex < doneIndex)
    }

    @Test("Lane status is running while a Todo/In Progress Card remains and lanes are not pushed")
    func laneStatusRunning() {
        let rollUp = FeatureRollUp(
            members: [member("A", repo: "backend", order: 0, state: .inProgress)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(rendered.contains("#### `backend` — running"))
    }

    @Test("Lane status is finished when no live Todo/In Progress Card remains and lanes are not pushed")
    func laneStatusFinished() {
        let rollUp = FeatureRollUp(
            members: [member("A", repo: "backend", order: 0, state: .blocked)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(rendered.contains("#### `backend` — finished"))
    }

    @Test("Lane status is pushed when the Cycle has landed")
    func laneStatusPushed() {
        let rollUp = FeatureRollUp(
            members: [member("A", repo: "backend", order: 0, state: .done)],
            lanesPushed: true, verificationPassed: true,
            mergedFraction: MergedFraction(mergedCount: 1, totalCount: 1), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(rendered.contains("#### `backend` — pushed"))
    }

    @Test("Adopted and banked-answer markers render on the Card line")
    func adoptedAndBankedMarkers() {
        let rollUp = FeatureRollUp(
            members: [
                member(
                    "A", repo: "backend", order: 0, state: .waitingOnYou, waitingReason: .question,
                    markers: [.bankedAnswer], adoptedFrom: "FEAT-9"
                )
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(
            rendered.contains(
                "- `A` — Waiting on You (question) · adopted from `FEAT-9` · banked answer waiting"
            )
        )
    }

    @Test("Blocked Card with a block reason renders the reason suffix")
    func blockedReasonSuffix() {
        let rollUp = FeatureRollUp(
            members: [member("A", repo: "backend", order: 0, state: .blocked, blockReason: "blocked by check")],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(rendered.contains("- `A` — Blocked (blocked by check)"))
    }

    @Test("Cancelled Cards render in a trailing group, sorted by repository then authoredOrder")
    func cancelledGroupAtTheBottom() {
        let rollUp = FeatureRollUp(
            members: [
                member("A", repo: "backend", order: 0, state: .done),
                member("W-2", repo: "web", order: 1, state: .cancelled),
                member("W-1", repo: "web", order: 0, state: .cancelled),
                member("B-1", repo: "backend", order: 1, state: .cancelled)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()

        #expect(rendered.contains("#### Cancelled"))
        let cancelledHeadingIndex = rendered.range(of: "#### Cancelled")!.lowerBound
        let backendLaneIndex = rendered.range(of: "#### `backend`")!.lowerBound
        #expect(backendLaneIndex < cancelledHeadingIndex)

        let expectedTail = [
            "#### Cancelled",
            "- `B-1` [`backend`] — Cancelled",
            "- `W-1` [`web`] — Cancelled",
            "- `W-2` [`web`] — Cancelled"
        ].joined(separator: "\n")
        #expect(rendered.hasSuffix(expectedTail))
    }

    @Test("A lane with only Cancelled Cards gets no lane group")
    func laneWithOnlyCancelledGetsNoGroup() {
        let rollUp = FeatureRollUp(
            members: [
                member("A", repo: "backend", order: 0, state: .done),
                member("W-1", repo: "web", order: 0, state: .cancelled)
            ],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(), issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        #expect(!rendered.contains("#### `web`"))
        #expect(rendered.contains("- `W-1` [`web`] — Cancelled"))
    }

    @Test("Conflicts render on the header line, beside the bold sentence")
    func conflictsOnHeaderLine() {
        let rollUp = FeatureRollUp(
            members: [member("A", repo: "backend", order: 0, state: .done)],
            lanesPushed: false, verificationPassed: false, mergedFraction: noMerge(),
            conflictingRepositories: ["api", "web"], issueStanding: .authoring
        )
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        let firstLine = rendered.components(separatedBy: "\n").first!
        #expect(firstLine == "**\(rollUp.sentence)** [conflict: api] [conflict: web]")
    }
}
