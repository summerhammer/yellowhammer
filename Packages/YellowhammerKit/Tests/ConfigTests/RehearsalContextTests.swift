import Config
import Domain
import Foundation
import Testing

/// Whether Rehearsal is available for a Project, decided from its configuration alone (OQ149).
@Suite("Rehearsal context")
struct RehearsalContextTests {
    private let directory: URL
    private let realJournal: URL
    private let projectID: ProjectID

    init() throws {
        directory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "rehearsal-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "alpha"))
        realJournal = directory.appending(components: "journals", "alpha.db", directoryHint: .notDirectory)
    }

    private func project(rehearsalProject: String?, journal: String?, linearProject: String = "ALP")
        -> ProjectConfiguration {
        ProjectConfiguration(
            id: projectID,
            name: "Alpha",
            linearInstallationName: "acme",
            linearProject: linearProject,
            codeHostingConnectionName: "github",
            repos: [RepoDeclaration(name: "backend", path: "~/backend", role: .backend, check: .none)],
            rehearsalLinearProject: rehearsalProject,
            rehearsalJournal: journal
        )
    }

    private func unavailable(_ configuration: ProjectConfiguration) -> RehearsalUnavailable? {
        do {
            _ = try configuration.rehearsalContext(realJournal: realJournal)
            return nil
        } catch {
            return error
        }
    }

    private func rehearsalPath(_ name: String) -> String {
        directory.appending(components: "rehearsal", name, directoryHint: .notDirectory).path(percentEncoded: false)
    }

    @Test("Both defined and distinct yield the context")
    func available() throws {
        let path = rehearsalPath("alpha.db")
        let context = try project(rehearsalProject: "ALP-REHEARSAL", journal: path)
            .rehearsalContext(realJournal: realJournal)
        #expect(context.linearProject == "ALP-REHEARSAL")
        #expect(context.journal == URL(filePath: path, directoryHint: .notDirectory).standardizedFileURL)
    }

    @Test("A tilde in the journal path expands to the home directory")
    func tildeExpands() throws {
        let context = try project(rehearsalProject: "ALP-REHEARSAL", journal: "~/x/rehearsal.db")
            .rehearsalContext(realJournal: realJournal)
        let expected = (("~/x/rehearsal.db") as NSString).expandingTildeInPath
        #expect(context.journal.path(percentEncoded: false) == expected)
        #expect(context.journal.path(percentEncoded: false).hasPrefix("/"))
        #expect(!context.journal.path(percentEncoded: false).contains("~"))
    }

    @Test("A journal in a rehearsal directory of its own is accepted")
    func ownDirectoryAccepted() throws {
        let path = rehearsalPath("\(projectID.rawValue).db")
        #expect(unavailable(project(rehearsalProject: "ALP-R", journal: path)) == nil)
    }

    @Test("A missing rehearsal_project is the only reason when the journal is fine")
    func linearProjectMissing() {
        let error = unavailable(project(rehearsalProject: nil, journal: rehearsalPath("a.db")))
        #expect(error?.reasons == [.linearProjectNotDefined])
    }

    @Test("A missing journal is the only reason when the Linear project is fine")
    func journalMissing() {
        let error = unavailable(project(rehearsalProject: "ALP-R", journal: nil))
        #expect(error?.reasons == [.journalNotDefined])
    }

    @Test("Both missing give both reasons, Linear project first, in the description")
    func bothMissing() throws {
        let error = try #require(unavailable(project(rehearsalProject: nil, journal: nil)))
        #expect(error.reasons == [.linearProjectNotDefined, .journalNotDefined])
        #expect(error.projectID == projectID)
        #expect(error.description.hasPrefix("Rehearsal is not available for Project alpha: "))
        #expect(error.description.contains("`[board.linear] rehearsal_project`"))
        #expect(error.description.contains("`[rehearsal] journal`"))
    }

    @Test("A rehearsal_project equal to the Project's own does not count, whitespace aside")
    func linearProjectIsTheRealOne() {
        let exact = unavailable(project(rehearsalProject: "ALP", journal: rehearsalPath("a.db")))
        #expect(exact?.reasons == [.linearProjectIsTheRealOne])
        let padded = unavailable(project(rehearsalProject: "  ALP \n", journal: rehearsalPath("a.db")))
        #expect(padded?.reasons == [.linearProjectIsTheRealOne])
    }

    @Test("A relative journal path does not count")
    func relativeJournal() {
        let error = unavailable(project(rehearsalProject: "ALP-R", journal: "rehearsal.db"))
        #expect(error?.reasons == [.journalNotAbsolute("rehearsal.db")])
    }

    @Test("The real Journal under a non-standard spelling does not count")
    func realJournalSpelledOddly() {
        let spelled = directory.path(percentEncoded: false) + "/journals/../journals/alpha.db"
        let error = unavailable(project(rehearsalProject: "ALP-R", journal: spelled))
        #expect(error?.reasons == [.journalIsTheRealOne])
    }

    @Test("A journal beside the real Journals, such as a sibling's, does not count")
    func journalAmongRealJournals() throws {
        let sibling = directory.appending(components: "journals", "sibling.db", directoryHint: .notDirectory)
        let error = try #require(
            unavailable(project(rehearsalProject: "ALP-R", journal: sibling.path(percentEncoded: false)))
        )
        #expect(error.reasons.count == 1)
        guard case .journalAmongRealJournals = error.reasons[0] else {
            Issue.record("expected journalAmongRealJournals, got \(error.reasons)")
            return
        }
    }
}
