import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Indeterminate predecessor reporting (#732)")
struct PredecessorIndeterminateReportingTests {
    @Test("Night Card names each cause and only names missing tips for tip-unreadable repositories")
    func nightCardPerCause() throws {
        let line = try #require(NightCardMaintenance.authoringLine(for: .authoringPredecessorIndeterminate(
            featureIssueID: "FEAT-1", repositories: ["backend": .landingCommitUnreadable, "mobile": .tipUnreadable]
        )))
        #expect(line == "Authoring was skipped: the pushed tip of Feature `FEAT-1` in the unmerged Feature stack "
            + "could not be found in mobile. Feature `FEAT-1` is merged into mainline in backend, but its landing "
            + "commit could not be read. The Observed Merge is recorded on a later author Act when the read "
            + "succeeds. A quiet Night, not a failure.")
        let tip = try #require(NightCardMaintenance.authoringLine(for: .authoringPredecessorIndeterminate(
            featureIssueID: "FEAT-1", repositories: ["backend": .tipUnreadable]
        )))
        #expect(tip == "Authoring was skipped: the pushed tip of Feature `FEAT-1` in the unmerged Feature stack "
            + "could not be found in backend. A quiet Night, not a failure.")
        let landing = try #require(NightCardMaintenance.authoringLine(for: .authoringPredecessorIndeterminate(
            featureIssueID: "FEAT-1", repositories: ["backend": .landingCommitUnreadable]
        )))
        #expect(landing.contains("merged into mainline in backend, but its landing commit could not be read"))
        #expect(!landing.contains("could not be found"))
    }

    @Test("Journal preserves all three partitions, causes, and does not consider an indeterminate pass fully merged")
    func observationPartitions() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, runID) = try makeGateContext(journal, repositories: nil)
        let event = JournalEvent.predecessorAncestryObserved(
            featureIssueID: "FEAT-1", mergedRepositories: ["api"], unmergedRepositories: ["web"],
            indeterminateRepositories: ["backend": .landingCommitUnreadable, "mobile": .tipUnreadable]
        )
        try journal.append(event, act: .author, runID: runID, nightID: context.night.id)
        #expect(try journal.events(ofType: .predecessorAncestryObserved).last?.event == event)
        let observation = try #require(try FeatureMainlineObservationReader.latestAncestryObservation(
            featureIssueID: "FEAT-1", journal: journal
        ))
        #expect(observation.merged == ["api"])
        #expect(observation.unmerged == ["web"])
        #expect(observation.indeterminate == ["backend": .landingCommitUnreadable, "mobile": .tipUnreadable])
        try journal.append(.predecessorAncestryObserved(
            featureIssueID: "FEAT-2", mergedRepositories: ["api"], unmergedRepositories: [],
            indeterminateRepositories: ["backend": .landingCommitUnreadable]
        ), act: .author, runID: runID, nightID: context.night.id)
        #expect(try !journal.predecessorAncestryPreviouslyFullyMerged(featureIssueID: "FEAT-2"))
    }
}
