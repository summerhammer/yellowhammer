import Domain
import Foundation
import Testing

@testable import Journal

@Test("tagFetchFailed event round-trips under its own type, apart from mainlineFetchFailed")
func tagFetchFailedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )

    try journal.append(
        .tagFetchFailed(repository: "contracts", reason: "would clobber existing tag"), act: .author, runID: RunID()
    )
    try journal.append(.mainlineFetchFailed(repository: "contracts", reason: "offline"), act: .author, runID: RunID())

    let tagRecords = try journal.events(ofType: .tagFetchFailed)
    #expect(tagRecords.count == 1)
    #expect(tagRecords[0].type.rawValue == "TagFetchFailed")
    #expect(tagRecords[0].event == .tagFetchFailed(repository: "contracts", reason: "would clobber existing tag"))
    #expect(try journal.events(ofType: .mainlineFetchFailed).count == 1)
}
