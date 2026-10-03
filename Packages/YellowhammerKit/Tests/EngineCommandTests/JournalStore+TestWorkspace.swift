import Domain
import Foundation

@testable import Journal

extension BoardObjectID {
    /// The Linear workspace of the fixture App Installation in the tests' machine files.
    static let fixtureWorkspace = BoardObjectID(rawValue: "workspace-1")
}

extension JournalStore {
    /// The creating opens with the fixture workspace, so a test that does not care which workspace its
    /// Journal records keeps the short form.
    static func open(configurationDirectory: URL, projectID: ProjectID) throws -> JournalStore {
        try open(
            configurationDirectory: configurationDirectory, projectID: projectID,
            linearWorkspace: .fixtureWorkspace
        )
    }

    static func open(homeDirectory: URL, projectID: ProjectID) throws -> JournalStore {
        try open(homeDirectory: homeDirectory, projectID: projectID, linearWorkspace: .fixtureWorkspace)
    }

    static func open(at fileURL: URL, projectID: ProjectID) throws -> JournalStore {
        try open(at: fileURL, projectID: projectID, linearWorkspace: .fixtureWorkspace)
    }
}
