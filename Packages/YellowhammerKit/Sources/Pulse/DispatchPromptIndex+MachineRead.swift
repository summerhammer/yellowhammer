import Config
import Domain
import Foundation

extension DispatchPromptIndex {
    /// Reads and groups machine-scope diagnostic prompt records by run id, newest run first,
    /// optionally filtered by the Route's CLI.
    public static func machine(
        store: DispatchPromptStore,
        cli: String? = nil,
        asOf: Date = Date()
    ) -> [MachineRun] {
        let entries = store.entries(in: .machine)

        var runsByID: [String: (cli: String, time: Date, items: [DispatchPromptItem])] = [:]
        var runOrder: [String] = []

        for entry in entries {
            let record: DispatchPromptRecord?
            let lookup = entry.lookup

            switch lookup {
            case .available(let rec):
                record = rec
            case .expired:
                record = decodeMachineRecord(id: entry.id, store: store)
            case .deleted, .missing, .unreadable:
                record = nil
            }

            guard let record else { continue }

            let recordCLI = extractCLI(from: record.route)
            if let cli, !cli.isEmpty, recordCLI != cli {
                continue
            }

            let runID = record.provenance.runID ?? record.id
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

            if runsByID[runID] == nil {
                runOrder.append(runID)
                runsByID[runID] = (cli: recordCLI, time: record.dispatchedAt, items: [])
            } else {
                if record.dispatchedAt < runsByID[runID]!.time {
                    runsByID[runID]!.time = record.dispatchedAt
                }
            }
            runsByID[runID]?.items.append(item)
        }

        var result: [MachineRun] = []
        for runID in runOrder {
            guard let run = runsByID[runID] else { continue }
            let sortedItems = run.items.sorted {
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.id < $1.id
            }
            result.append(
                MachineRun(
                    runID: runID,
                    cli: run.cli,
                    time: run.time,
                    items: sortedItems
                )
            )
        }

        // Newest run first
        result.sort { $0.time > $1.time }
        return result
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
}
