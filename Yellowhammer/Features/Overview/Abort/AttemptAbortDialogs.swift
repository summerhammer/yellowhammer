import Domain
import Pulse
import SwiftUI

extension View {
    /// The confirmation, and the failure alert, of Abort Attempt. The window owns the one pair; the Sidebar
    /// and the Inspector only ask for it. Confirming aborts the pending Attempt of the Project it names.
    func attemptAbortDialogs(
        pending: Binding<PendingAttemptAbort?>, abort: AttemptAbortModel, afterAbort: @escaping () async -> Void
    ) -> some View {
        confirmationDialog(
            "Abort the Attempt on \(pending.wrappedValue?.attempt.cardID ?? "this Card")?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { request in
            Button("Abort Attempt", role: .destructive) {
                Task {
                    await abort.abort(request.id)
                    await afterAbort()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(
                "This aborts the running Attempt on \(request.attempt.cardID). The Card is Blocked with the Block " +
                    "Reason “operator abort” until you re-ready it in Linear: the Card is reclaimable, and no " +
                    "partial state was written as if it were complete. The Attempt does not count against the " +
                    "Card's Attempts and does not rule its route out. Nothing else is stopped."
            )
        }
        .alert(
            "The Attempt could not be aborted",
            isPresented: Binding(get: { abort.failure != nil }, set: { if !$0 { abort.failure = nil } })
        ) {
            Button("OK") { abort.failure = nil }
        } message: {
            Text(abort.failure ?? "")
        }
    }
}
