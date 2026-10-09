import Pulse
import SwiftUI

/// The Pulse's Health group: recorded Act failures, undelivered Board writes and `yh doctor` findings. Runtime failures show
/// their reason, count and last occurrence; doctor findings open Settings, where the Operator acts.
/// Nil states that doctor was not read when there are no recorded failures to show.
struct HealthGroup: View {
    let health: [HealthFlag]?
    let deliverNow: () -> Void
    let canDeliverNow: Bool
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        PulseCard(group: .health, summary: PulseGroup.summary(of: health)) {
            switch health {
            case nil:
                Label("yh doctor not read", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("health-unread")
            case let flags? where flags.isEmpty:
                Label("No health flags", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("health-absence")
            case let flags?:
                ForEach(flags) { flag in
                    if flag.kind == .actFailure {
                        HealthFlagRow(flag: flag)
                    } else if flag.kind == .undeliveredBoardWrites {
                        VStack(alignment: .leading, spacing: 6) {
                            HealthFlagRow(flag: flag)
                            Button("Deliver now", action: deliverNow)
                                .buttonStyle(.link)
                                .disabled(!canDeliverNow)
                                .accessibilityIdentifier("pulse-deliver-now")
                        }
                    } else {
                        Button { openDestination(flag.destination) } label: { HealthFlagRow(flag: flag) }
                            .buttonStyle(.plain)
                            .help(help(for: flag.destination))
                    }
                }
            }
            Button("Open Settings") { openDestination(settingsDestination) }
                .buttonStyle(.link)
                .accessibilityIdentifier("pulse-health-settings")
        }
        .accessibilityIdentifier("pulse-health")
    }

    /// A single repair destination is the useful way out; mixed findings need the Project's Settings.
    private var settingsDestination: PulseDestination {
        let destinations = Set((health ?? []).map(\.destination))
        guard destinations.count == 1, let destination = destinations.first else { return .settings }
        return destination
    }

    private func help(for destination: PulseDestination) -> String {
        switch destination {
        case .linearWorkspaces:
            "Open Settings → Boards"
        case .codeHosting:
            "Open Settings → Code Hosting"
        default:
            "Open the Project's Settings"
        }
    }
}

/// One flag: its recorded detail, plus occurrence metadata for a Journal failure.
private struct HealthFlagRow: View {
    let flag: HealthFlag

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // `warning` is too light for a thin glyph on a light canvas, so the icon is the filled
            // triangle and the kind is always spelled out beside it.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.kind.displayName)
                Text(flag.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if flag.kind == .undeliveredBoardWrites {
                    Text(outboxSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = flag.lastError {
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if let recoveredAt = flag.recoveredAt {
                    let recoveredTime = recoveredAt.formatted(date: .omitted, time: .shortened)
                    Text("\(occurrenceLabel) · recovered \(recoveredTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let last = flag.lastOccurredAt {
                    Text("\(occurrenceLabel) · last \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .contentShape(.rect)
        // Combining children drops the selectable detail from the label, so both are spelled out.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("health-flag")
        .accessibilityLabel(accessibilityDescription)
    }

    private var occurrenceLabel: String {
        "\(flag.occurrenceCount) failure\(flag.occurrenceCount == 1 ? "" : "s")"
    }

    private var outboxSummary: String {
        let pending = flag.pendingWriteCount
        let failed = flag.failedWriteCount
        let pendingText = "\(pending) pending write\(pending == 1 ? "" : "s")"
        let failedText = "\(failed) failed write\(failed == 1 ? "" : "s")"
        let counts = [pending > 0 ? pendingText : nil, failed > 0 ? failedText : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let since = flag.oldestUndeliveredAt.map {
            "since \($0.formatted(date: .abbreviated, time: .shortened))"
        }
        return [counts, since].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        let detail = "\(flag.kind.displayName): \(flag.detail)"
        if flag.kind == .undeliveredBoardWrites {
            let error = flag.lastError.map { ". Last error: \($0)" } ?? ""
            return "\(detail). \(outboxSummary)\(error)"
        }
        if let recoveredAt = flag.recoveredAt {
            let time = recoveredAt.formatted(date: .omitted, time: .shortened)
            return "\(detail). \(occurrenceLabel), recovered \(time)"
        }
        guard let last = flag.lastOccurredAt else { return detail }
        return "\(detail). \(occurrenceLabel), last \(last.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: For display

private extension HealthFlagKind {
    /// `Stale Operator identity`: the glossary's words, capitalised as a row title.
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
