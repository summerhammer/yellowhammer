import Foundation
import Journal

extension Outbox {
    /// Delivers every pending entry in accepted order, including entries a killed run left behind (see
    /// `deliverPendingExclusively`). Only one delivery runs at a time per Outbox: the build Act's Repo
    /// Lanes post concurrently, and two overlapping deliveries would read the same pending entry and
    /// deliver it twice.
    public func deliverPending() async throws -> OutboxDeliveryReport {
        await deliveryGate.acquire()
        do {
            let report = try await deliverPendingExclusively()
            await deliveryGate.release()
            return report
        } catch {
            await deliveryGate.release()
            throw error
        }
    }
}

/// A FIFO async mutex. An actor alone would not do: its methods interleave at every `await`, so the
/// exclusion has to be held across the delivery, not within one call.
actor OutboxDeliveryGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isHeld = true
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
