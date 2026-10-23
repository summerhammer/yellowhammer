import Domain
import Foundation
import Testing

@testable import Journal

// spec ruling OQ182 (2026-10-22), item 5: `adoptionOrigins` reads the recorded `CardAdopted` events for
// one Feature, giving the same-repository hold (`RepoLane`) each adopted Card's previous Feature Issue
// id, so an adopted Card's sequence is kept apart from a newly authored one's. No column, no migration:
// these events already record the adoption.

private struct AdoptionOriginsFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-adoption-origins-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private func appendCardAdopted(
    _ journal: JournalStore, cardID: Int64, issueID: String, from previousFeatureIssueID: String,
    into newFeatureIssueID: String, previousAuthoredOrder: Int? = nil
) throws {
    try journal.append(.cardAdopted(
        cardID: cardID, issueID: issueID, previousFeatureIssueID: previousFeatureIssueID,
        newFeatureIssueID: newFeatureIssueID, priorBlockReason: nil, coldStartNote: "cold",
        previousAuthoredOrder: previousAuthoredOrder
    ))
}

@Test("""
Every Card adopted into one Feature is mapped to its previous Feature Issue id; a Card adopted into \
another Feature is excluded
""")
func mapsEveryAdoptedCardToItsOriginForThisFeatureOnly() throws {
    let fixture = try AdoptionOriginsFixture()
    let journal = try fixture.open()

    try appendCardAdopted(journal, cardID: 1, issueID: "BACK-1", from: "FEAT-OLD-1", into: "FEAT-NEW")
    try appendCardAdopted(journal, cardID: 2, issueID: "BACK-2", from: "FEAT-OLD-2", into: "FEAT-NEW")
    // Adopted into a different Feature: excluded from FEAT-NEW's origins.
    try appendCardAdopted(journal, cardID: 3, issueID: "BACK-3", from: "FEAT-OLD-3", into: "FEAT-OTHER")

    let origins = try journal.adoptionOrigins(featureIssueID: "FEAT-NEW")
    #expect(origins == [1: "FEAT-OLD-1", 2: "FEAT-OLD-2"])
}

@Test("A Card adopted more than once reads as its latest recorded origin")
func latestAdoptionEventWins() throws {
    let fixture = try AdoptionOriginsFixture()
    let journal = try fixture.open()

    try appendCardAdopted(journal, cardID: 1, issueID: "BACK-1", from: "FEAT-OLD-1", into: "FEAT-NEW")
    try appendCardAdopted(journal, cardID: 1, issueID: "BACK-1", from: "FEAT-OLD-2", into: "FEAT-NEW")

    let origins = try journal.adoptionOrigins(featureIssueID: "FEAT-NEW")
    #expect(origins == [1: "FEAT-OLD-2"])
}

@Test("A Feature with no recorded CardAdopted events reads as no origins")
func noEventsReadsAsEmpty() throws {
    let fixture = try AdoptionOriginsFixture()
    let journal = try fixture.open()

    #expect(try journal.adoptionOrigins(featureIssueID: "FEAT-NEW").isEmpty)
}
