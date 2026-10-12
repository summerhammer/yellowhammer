import Domain
import Foundation
import Journal

extension NightAccount {
    /// Reads one Night's account from its own Project's Journal.
    ///
    /// The Journal is found by `project` alone, opened read-only and closed before this returns, so no
    /// connection outlives the read ("Nothing resident") and nothing of a sibling Project's can appear in
    /// it (R20; ADR-002). The read never creates or migrates a Journal, and an Act writing the same Journal
    /// meanwhile is never blocked for longer than one of its reads. Unlike ``CardDetail/read(issueID:project:configurationDirectory:)``
    /// it is several reads, not one transaction: the Night, its events and each named Card are read in turn.
    ///
    /// It may wait for the Journal's busy timeout while an Act holds the write lock, so call it off the
    /// main actor.
    public static func read(nightID: Int64, project: ProjectID, configurationDirectory: URL) -> NightAccountRead {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: project)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: project)
            guard let account = try read(from: journal, nightID: nightID) else { return .noSuchNight }
            return .account(account)
        } catch JournalError.missing {
            return .journalMissing
        } catch {
            return .journalFailure("\(error)")
        }
    }

    /// Fills one Night's account from `journal`. Nil when the Journal records no Night with `nightID`.
    ///
    /// Like ``PulseSnapshot/read(from:status:asOf:)``, the read is HANDED a store and never opens one, so
    /// every value comes from this one store. It only reads.
    public static func read(from journal: JournalStore, nightID: Int64) throws -> NightAccount? {
        guard let night = try journal.night(id: nightID) else { return nil }
        let records = try journal.events(nightID: nightID)
        let cardNames = try cardNames(for: records, in: journal)
        return NightAccount(
            id: night.id,
            nightStart: night.nightStart.rawValue,
            mode: night.mode,
            state: night.state == .opened ? .running : .done,
            openedAt: night.openedAt,
            completedAt: night.completedAt,
            closeReason: night.closeReason.map(NightAccount.words(closeReason:)),
            nightCard: LinearIssueLink.link(
                key: night.nightCardIssueIDForDisplay ?? night.nightCardIssueKey,
                url: night.nightCardIssueURL
            ),
            runs: ActRun.runs(from: records, cardNames: cardNames)
        )
    }

    /// The display identifier of every Card the entries name, each read once. A Card the Journal no longer
    /// knows is left out and read as `Card <id>`; any other Journal failure is not swallowed.
    private static func cardNames(
        for records: [JournalEventRecord], in journal: JournalStore
    ) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        for id in Set(records.compactMap { NightAccount.cardID(of: $0.event) }) {
            do {
                let card = try journal.card(id: id)
                names[id] = card.issueIDForDisplay ?? card.issueKey
            } catch JournalError.cardUnknown {
                continue
            }
        }
        return names
    }
}

extension NightAccount.ActRun {
    /// The `id` of the run that gathers the events carrying no run id.
    static let unstampedID = "unstamped"

    /// Groups `records`, already in append order, by run id. A run is placed by its first event, and its
    /// entries stay in append order.
    static func runs(from records: [JournalEventRecord], cardNames: [Int64: String]) -> [NightAccount.ActRun] {
        var order: [String] = []
        var groups: [String: [JournalEventRecord]] = [:]
        for record in records {
            let key = record.runID?.rawValue ?? unstampedID
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }
        return order.compactMap { key in
            groups[key].map { run(id: key, records: $0, cardNames: cardNames) }
        }
    }

    private static func run(
        id: String, records: [JournalEventRecord], cardNames: [Int64: String]
    ) -> NightAccount.ActRun {
        NightAccount.ActRun(
            id: id,
            act: id == unstampedID ? nil : records.lazy.compactMap(\.act).first?.rawValue,
            startedAt: records.first?.occurredAt ?? Date(timeIntervalSince1970: 0),
            outcome: outcome(of: records),
            entries: records.map { NightAccount.Entry(record: $0, cardNames: cardNames) }
        )
    }

    /// The outcome the run's first closing event gives; `.notEnded` when it has none.
    private static func outcome(of records: [JournalEventRecord]) -> NightAccount.RunOutcome {
        for record in records {
            switch record.event {
            case .actEnded: return .ended
            case .actIdle(let reason): return .idle(reason: NightAccount.words(idleReason: reason))
            case .actIncomplete(let reason): return .incomplete(reason: reason)
            case .actStoodDown: return .stoodDown
            default: continue
            }
        }
        return .notEnded
    }
}
