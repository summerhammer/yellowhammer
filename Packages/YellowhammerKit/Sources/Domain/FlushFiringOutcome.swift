/// How a flush firing — one of the three land firings after `night_end` (Transient Board Failure Ruling
/// 2026-10-09 item 6) — ended. A flush firing does no Night work, so this is all it has to report.
public enum FlushFiringOutcome: String, CaseIterable, Sendable {
    /// No Night is recorded for the window: the Mac slept through it, or it never started. Nothing is
    /// opened, so the absence of a Night Card stays the "never started" signal.
    case noNight = "no_night"
    /// The Night was still open — its closing land died, halted or stood down on the Lease — and this
    /// firing closed it the way the closing land would have.
    case closedNight = "closed_night"
    /// The Night was already closed; the Project's pending Outbox entries were delivered.
    case delivered
    /// The Night was already closed and entries were pending, but none could be delivered — the board was
    /// still unreachable or rate-limited. They stay pending, not failed.
    case stillPending = "still_pending"
    /// The Night was already closed and nothing was pending.
    case nothingPending = "nothing_pending"
    /// The firing failed on an already-closed Night. Recorded here rather than as `ActIncomplete`, which
    /// would read as the Night having halted after its Night Summary was written.
    case failed
}
