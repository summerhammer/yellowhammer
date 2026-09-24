import Domain
import Foundation
import Journal
import Observation

/// The read-only Journal account behind a Card (P14.5; Decision Gates Ruling, G-6): one Project's
/// Cards, and for the one picked its Attempts, Rounds, routes and Check output.
///
/// The Journal is opened with ``Journal/JournalStore/openReadOnly(at:projectID:)`` — never the
/// engine's open, which would create or migrate it — and dropped at the end of every load, so no
/// connection outlives one read ("Nothing resident"). An Act may be writing the same Journal
/// meanwhile; each read is one short transaction and never blocks it for long.
@MainActor
@Observable
final class CardAccountModel {
    let project: ProjectID
    let directory: URL

    /// This Project's Cards, nil when the Journal could not be read.
    private(set) var cards: [CardRecord]?
    /// The picked Card's account, nil when no Card is picked or it could not be read.
    private(set) var account: CardAccount?
    /// Set when the Journal does not exist yet: no Act of this Project has run.
    private(set) var journalMissing = false
    /// The Journal's own words, when it exists but could not be read (e.g. a schema newer than this
    /// build knows: the app says so and reads nothing, rather than misreading it).
    private(set) var failure: String?

    /// The picked Card, by issue id.
    private(set) var selectedIssueID: String?

    init(project: ProjectID, directory: URL = ConfigurationDirectory.current) {
        self.project = project
        self.directory = directory
        load()
    }

    /// Picks a Card and reads its account.
    func select(_ issueID: String?) {
        guard issueID != selectedIssueID else { return }
        selectedIssueID = issueID
        load()
    }

    /// Re-reads the Card list and the picked Card's account from a fresh read-only open.
    func load() {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: directory, id: project)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: project)
            let cards = try journal.cards()
            if let selected = selectedIssueID, !cards.contains(where: { $0.issueID == selected }) {
                selectedIssueID = nil
            }
            self.cards = cards
            account = try selectedIssueID.flatMap(journal.cardAccount(issueID:))
            journalMissing = false
            failure = nil
        } catch JournalError.missing {
            clear()
            journalMissing = true
        } catch {
            clear()
            failure = "\(error)"
        }
    }

    private func clear() {
        cards = nil
        account = nil
        journalMissing = false
    }
}
