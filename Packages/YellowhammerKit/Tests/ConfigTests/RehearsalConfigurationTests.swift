import Config
import Domain
import Foundation
import Testing

/// `[board.linear] rehearsal_project` and `[rehearsal] journal`: decoding, and surviving a draft round trip.
@Suite("Rehearsal configuration")
struct RehearsalConfigurationTests {
    private static let head = """
        id = "alpha"
        name = "Alpha"
        spec_source = "~/spec"

        """

    private static let repos = """

        [[repos]]
        name = "backend"
        path = "~/backend"
        role = "backend"
        check = "none"
        """

    private static func text(boardExtra: String = "", rehearsal: String = "") -> String {
        head
            + "\n[board.linear]\nconnection = \"acme\"\nproject = \"ALP\"\n" + boardExtra
            + repos + "\n" + rehearsal + "\n"
    }

    private static func parse(boardExtra: String = "", rehearsal: String = "") throws(ConfigurationError)
        -> ProjectConfiguration {
        try ProjectConfiguration.parse(text(boardExtra: boardExtra, rehearsal: rehearsal), file: "alpha.toml")
    }

    private static func refusal(boardExtra: String = "", rehearsal: String = "") -> ConfigurationError? {
        do {
            _ = try parse(boardExtra: boardExtra, rehearsal: rehearsal)
            return nil
        } catch {
            return error
        }
    }

    private static let both = (
        board: "rehearsal_project = \"ALP-REHEARSAL\"\n",
        rehearsal: "[rehearsal]\njournal = \"~/x/rehearsal.db\"\n"
    )

    @Test("Both keys present are held as written")
    func bothKeysDecode() throws {
        let project = try Self.parse(boardExtra: Self.both.board, rehearsal: Self.both.rehearsal)
        #expect(project.rehearsalLinearProject == "ALP-REHEARSAL")
        #expect(project.rehearsalJournal == "~/x/rehearsal.db")
    }

    @Test("Both keys absent are nil")
    func keysAbsent() throws {
        let project = try Self.parse()
        #expect(project.rehearsalLinearProject == nil)
        #expect(project.rehearsalJournal == nil)
    }

    @Test("An unknown key inside [rehearsal] is refused, naming it")
    func unknownRehearsalKey() {
        let error = Self.refusal(rehearsal: "[rehearsal]\njournal = \"/x/r.db\"\nunknown_key = 1\n")
        #expect(error?.reason == .unknownKey)
        #expect(error?.key == "rehearsal.unknown_key")
    }

    @Test("An empty [rehearsal] journal is refused as an empty string")
    func emptyJournalRefused() {
        let error = Self.refusal(rehearsal: "[rehearsal]\njournal = \"\"\n")
        #expect(error?.reason == .emptyString)
        #expect(error?.key == "rehearsal.journal")
    }

    @Test("An empty rehearsal_project is refused as an empty string")
    func emptyRehearsalProjectRefused() {
        let error = Self.refusal(boardExtra: "rehearsal_project = \"\"\n")
        #expect(error?.reason == .emptyString)
        #expect(error?.key == "board.linear.rehearsal_project")
    }

    @Test("A draft round trip keeps both keys")
    func draftRoundTrip() throws {
        let original = try Self.parse(boardExtra: Self.both.board, rehearsal: Self.both.rehearsal)
        let rendered = ProjectFileDraft(original).renderedTOML
        let reparsed = try ProjectConfiguration.parse(rendered, file: "alpha.toml")
        #expect(reparsed == original)
        #expect(reparsed.rehearsalLinearProject == "ALP-REHEARSAL")
        #expect(reparsed.rehearsalJournal == "~/x/rehearsal.db")
    }

    @Test("A draft of a file without them renders neither")
    func draftWithoutKeysRendersNone() throws {
        let original = try Self.parse()
        let rendered = ProjectFileDraft(original).renderedTOML
        #expect(!rendered.contains("rehearsal_project"))
        #expect(!rendered.contains("[rehearsal]"))
        #expect(try ProjectConfiguration.parse(rendered, file: "alpha.toml") == original)
    }

    @Test("Editing a Bound in the draft keeps both keys")
    func editingABoundKeepsBothKeys() throws {
        let original = try Self.parse(boardExtra: Self.both.board, rehearsal: Self.both.rehearsal)
        var draft = ProjectFileDraft(original)
        draft.bounds.reviewRoundsMax = "5"
        let reparsed = try ProjectConfiguration.parse(draft.renderedTOML, file: "alpha.toml")
        #expect(reparsed.bounds.reviewRoundsMax == 5)
        #expect(reparsed.rehearsalLinearProject == "ALP-REHEARSAL")
        #expect(reparsed.rehearsalJournal == "~/x/rehearsal.db")
    }
}
