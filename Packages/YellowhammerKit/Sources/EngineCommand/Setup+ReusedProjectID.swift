import Config
import Domain
import Foundation
import Journal

extension Setup {
    /// A Project id re-added after `yh project remove` keeps its Journal. That Journal records the Linear
    /// workspace it was built against, so a different workspace is refused here, before the Project file
    /// or a Linear project exists; the same workspace is reopened by the next Act as it is. A Journal that
    /// cannot be read is refused too: its workspace cannot be verified, and every Act would refuse it.
    /// Setup opens it read-only and never creates or writes a Journal.
    func refuseReusedProjectID(_ id: ProjectID, installation: LinearInstallation) throws {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: id)
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let journal: JournalStore
        do {
            journal = try JournalStore.openReadOnly(at: fileURL, projectID: id)
        } catch {
            throw SetupError(
                "Project \(id.rawValue): the kept Journal at \(path) cannot be used: \(error). "
                    + Self.reusedProjectIDWaysOut
            )
        }
        guard journal.linearWorkspace == installation.workspace else {
            throw SetupError(
                "Project \(id.rawValue): the kept Journal at \(path) was built against Linear workspace "
                    + "\(journal.linearWorkspace.rawValue), but Board Connection \"\(installation.name)\" is in "
                    + "Linear workspace \(installation.workspace.rawValue). " + Self.reusedProjectIDWaysOut
            )
        }
        output("the kept Journal at \(path) is for Linear workspace \(installation.workspace.rawValue); it is reopened")
    }

    private static let reusedProjectIDWaysOut =
        "Choose a new Project id, or archive the old Journal (move it out of journals/) first."
}
