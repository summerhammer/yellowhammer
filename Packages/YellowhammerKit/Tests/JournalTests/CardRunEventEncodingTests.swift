import Domain
import Foundation
import Testing

@testable import Journal

// The Card run's event (roadmap P8.4) round-trips here, split out of EventEncodingTests.swift to keep
// that file under the length limit.

@Test("cardRunStep event round-trips for every step, with and without a detail")
func cardRunStepRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-cardrun-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    for (index, step) in CardRunStep.allCases.enumerated() {
        let detail: String? = index.isMultiple(of: 2) ? "detail \(step.rawValue)" : nil
        try journal.append(
            .cardRunStep(cardID: 7, issueID: "BACK-1", step: step, detail: detail),
            act: .build, runID: run, now: epoch
        )
    }
    let records = try journal.events(ofType: .cardRunStep)

    #expect(records.count == CardRunStep.allCases.count)
    for (index, step) in CardRunStep.allCases.enumerated() {
        let detail: String? = index.isMultiple(of: 2) ? "detail \(step.rawValue)" : nil
        #expect(records[index].event == .cardRunStep(cardID: 7, issueID: "BACK-1", step: step, detail: detail))
    }
}
