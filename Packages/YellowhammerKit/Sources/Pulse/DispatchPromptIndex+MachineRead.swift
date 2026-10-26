import Config
import Domain
import Foundation

/// One store entry resolved to the run it belongs to. `cli` is nil for a deleted entry whose
/// tombstone predates naming its Route.
private struct MachineEntryItem {
    let runID: String
    let cli: String?
    let item: DispatchPromptItem
}

/// A run being assembled from its entries: the earliest dispatch is the run's time.
private struct MachineRunDraft {
    var cli: String?
    var time: Date
    var items: [DispatchPromptItem] = []

    init(first entry: MachineEntryItem) {
        time = entry.item.time
    }

    mutating func add(_ entry: MachineEntryItem) {
        time = min(time, entry.item.time)
        cli = cli ?? entry.cli
        items.append(entry.item)
    }

    /// A run made only of deleted items falls back to the CLI filter, then to an empty name.
    func run(id: String, filterCLI: String?) -> DispatchPromptIndex.MachineRun {
        let sorted = items.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.id < $1.id
        }
        return DispatchPromptIndex.MachineRun(
            runID: id, cli: cli ?? filterCLI ?? "", time: time, items: sorted
        )
    }
}

extension DispatchPromptIndex {
    /// Reads and groups machine-scope diagnostic prompt records by run id, newest run first,
    /// optionally filtered by the Route's CLI.
    ///
    /// A deleted record whose tombstone names its run stays in that run as a `.deleted` item, so a
    /// Probe Result opening its own run still shows what was removed.
    public static func machine(
        store: DispatchPromptStore,
        cli: String? = nil,
        asOf: Date = Date()
    ) -> [MachineRun] {
        let filterCLI = cli.flatMap { $0.isEmpty ? nil : $0 }
        var drafts: [String: MachineRunDraft] = [:]
        var runOrder: [String] = []

        for entry in store.entries(in: .machine) {
            guard let found = machineItem(for: entry, store: store, filterCLI: filterCLI, asOf: asOf) else {
                continue
            }
            if drafts[found.runID] == nil {
                runOrder.append(found.runID)
                drafts[found.runID] = MachineRunDraft(first: found)
            }
            drafts[found.runID]?.add(found)
        }

        var result = runOrder.compactMap { id in drafts[id]?.run(id: id, filterCLI: filterCLI) }
        // Newest run first
        result.sort { $0.time > $1.time }
        return result
    }

    private static func machineItem(
        for entry: DispatchPromptEntry,
        store: DispatchPromptStore,
        filterCLI: String?,
        asOf: Date
    ) -> MachineEntryItem? {
        let record: DispatchPromptRecord?
        switch entry.lookup {
        case .available(let rec):
            record = rec
        case .expired:
            record = decodeMachineRecord(id: entry.id, store: store)
        case .deleted(let deletedAt):
            return deletedMachineItem(id: entry.id, deletedAt: deletedAt, store: store, filterCLI: filterCLI)
        case .missing, .unreadable:
            record = nil
        }
        guard let record else { return nil }

        let recordCLI = extractCLI(from: record.route)
        if let filterCLI, recordCLI != filterCLI { return nil }

        let isExpired = record.isExpired(at: asOf)
        let state: EntryState = isExpired ? .expired(dispatchedAt: record.dispatchedAt) : .recorded(record)
        let item = DispatchPromptItem(
            id: record.id,
            recordID: record.id,
            pass: record.pass,
            round: record.provenance.round,
            routeTry: record.provenance.routeTry,
            route: record.route,
            time: record.dispatchedAt,
            session: record.session,
            state: state,
            family: record.provenance.family,
            projectID: nil,
            defaultVersion: record.defaultVersion,
            projectInstructions: record.projectInstructions,
            launch: record.launch,
            nightID: nil,
            featureIssueID: nil,
            workCardIssueID: nil,
            cardID: nil,
            attemptID: nil,
            instruction: isExpired ? nil : record.instruction,
            outputSchema: isExpired ? nil : record.outputSchema
        )
        return MachineEntryItem(runID: record.provenance.runID ?? record.id, cli: recordCLI, item: item)
    }

    /// A deleted record has no pass or text left; its tombstone keeps only the run, the family and
    /// the Route. A tombstone without a run cannot be placed in one, so it is not listed, and one
    /// without a Route is not listed under a CLI filter.
    private static func deletedMachineItem(
        id: String,
        deletedAt: Date,
        store: DispatchPromptStore,
        filterCLI: String?
    ) -> MachineEntryItem? {
        guard let tombstone = decodeMachineTombstone(id: id, store: store),
              let runID = tombstone.runID else { return nil }
        let tombstoneCLI = tombstone.route.map(extractCLI(from:))
        if let filterCLI, tombstoneCLI != filterCLI { return nil }
        let item = DispatchPromptItem(
            id: id,
            recordID: id,
            pass: .architect,
            round: nil,
            routeTry: nil,
            route: tombstone.route ?? "",
            time: tombstone.dispatchedAt,
            session: .new,
            state: .deleted(deletedAt: deletedAt),
            family: tombstone.family,
            projectID: nil,
            defaultVersion: nil,
            projectInstructions: nil,
            launch: nil,
            nightID: nil,
            featureIssueID: nil,
            workCardIssueID: nil,
            cardID: nil,
            attemptID: nil,
            instruction: nil,
            outputSchema: nil
        )
        return MachineEntryItem(runID: runID, cli: tombstoneCLI, item: item)
    }

    private static func extractCLI(from route: String) -> String {
        route.split(separator: "/").first.map(String.init) ?? route
    }

    private static func decodeMachineRecord(id: String, store: DispatchPromptStore) -> DispatchPromptRecord? {
        let fileURL = store.directory(for: .machine)
            .appending(components: "\(id).json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? DispatchPromptRecord.makeJSONDecoder()
            .decode(DispatchPromptRecord.self, from: data)
    }

    private static func decodeMachineTombstone(id: String, store: DispatchPromptStore) -> DispatchPromptTombstone? {
        let fileURL = store.directory(for: .machine)
            .appending(components: "\(id).deleted.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? DispatchPromptRecord.makeJSONDecoder()
            .decode(DispatchPromptTombstone.self, from: data)
    }
}
