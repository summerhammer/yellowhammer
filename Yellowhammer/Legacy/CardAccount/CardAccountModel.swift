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
/// meanwhile; each read is one short transaction and never blocks it for long. Reads run off the
/// main actor, so a write-locked Journal (SQLite's busy wait) can never stall the window or quit.
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

    /// False until the first read lands, so the first read is not shown as an unreadable Journal.
    private(set) var hasLoaded = false

    /// Counts loads. A blocked read cannot be cancelled, so a result is applied only if no later
    /// load has started since.
    private var generation = 0

    /// What one read found. Plain values, so it can cross from the read back to the main actor.
    nonisolated enum Snapshot: Sendable {
        case loaded(cards: [CardRecord], account: CardAccount?)
        case missing
        case failed(String)
    }

    init(project: ProjectID, directory: URL = ConfigurationDirectory.current) {
        self.project = project
        self.directory = directory
    }

    /// Picks a Card and reads its account.
    func select(_ issueID: String?) {
        guard issueID != selectedIssueID else { return }
        selectedIssueID = issueID
        Task { await load() }
    }

    /// Re-reads the Card list and the picked Card's account from a fresh read-only open. The read
    /// runs detached: a nonisolated async method would stay on the main actor here.
    func load() async {
        generation += 1
        let current = generation
        let selected = selectedIssueID
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: directory, id: project)
        let project = project
        let snapshot = await Task.detached {
            Self.read(fileURL: fileURL, project: project, selected: selected)
        }.value
        // Superseded by a later load, or the pick changed while reading: that load applies instead.
        guard current == generation, selected == selectedIssueID else { return }
        hasLoaded = true
        switch snapshot {
        case let .loaded(cards, account):
            if let selected, !cards.contains(where: { $0.issueID == selected }) {
                selectedIssueID = nil
            }
            self.cards = cards
            self.account = account
            journalMissing = false
            failure = nil
        case .missing:
            clear()
            journalMissing = true
        case let .failed(message):
            clear()
            failure = message
        }
    }

    /// The whole read, on plain values. May block for as long as another process holds a write lock.
    private nonisolated static func read(fileURL: URL, project: ProjectID, selected: String?) -> Snapshot {
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: project)
            let cards = try journal.cards()
            guard let selected, cards.contains(where: { $0.issueID == selected }) else {
                return .loaded(cards: cards, account: nil)
            }
            return .loaded(cards: cards, account: try journal.cardAccount(issueID: selected))
        } catch JournalError.missing {
            return .missing
        } catch {
            return .failed("\(error)")
        }
    }

    private func clear() {
        cards = nil
        account = nil
        journalMissing = false
        failure = nil
    }
}
