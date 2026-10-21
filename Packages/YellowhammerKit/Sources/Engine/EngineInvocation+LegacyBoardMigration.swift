import Domain
import Journal

extension EngineInvocation {
    /// Runs the legacy Board migration (roadmap P22.9) once the Night Card is live and before the trigger and
    /// any dependent work. It never halts the Act for a board that cannot answer: the migration is deferred
    /// to the next Act, with an event saying so. A lost Lease or a refused identity still stops the Act.
    func migrateLegacyBoard(outbox: Outbox?) async throws {
        guard let board, let outbox else { return }
        do {
            try await LegacyBoardMigration(board: board, outbox: outbox).run()
        } catch let error as BoardError {
            if case .notAuthenticated = error { throw error }
            deferLegacyMigration(String(describing: error))
        } catch let error as BoardStateScopeError {
            deferLegacyMigration(String(describing: error))
        } catch let error as NightCardScopeError {
            deferLegacyMigration(String(describing: error))
        }
    }

    private func deferLegacyMigration(_ reason: String) {
        _ = try? journal.append(
            .legacyBoardObserved(kind: "migration-deferred", issueID: LegacyBoardConversion.projectKey, detail: reason),
            act: act, runID: runID
        )
    }
}
