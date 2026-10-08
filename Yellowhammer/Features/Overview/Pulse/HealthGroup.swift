import Pulse
import SwiftUI

/// The Pulse's Health group: recorded Act failures and `yh doctor` findings. Runtime failures show
/// their reason, count and last occurrence; doctor findings open Settings, where the Operator acts.
/// Nil states that doctor was not read when there are no recorded failures to show.
struct HealthGroup: View {
    let health: [HealthFlag]?
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
                        HealthFlagRow(flag: flag).accessibilityIdentifier("health-flag")
                    } else {
                        Button { openDestination(flag.destination) } label: { HealthFlagRow(flag: flag) }
                            .buttonStyle(.plain)
                            .help(help(for: flag.destination))
                            .accessibilityIdentifier("health-flag")
                    }
                }
            }
            Button("Open Settings") { openDestination(.settings) }
                .buttonStyle(.link)
                .accessibilityIdentifier("pulse-health-settings")
        }
        .accessibilityIdentifier("pulse-health")
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
                if let last = flag.lastOccurredAt {
                    Text("\(occurrenceLabel) · last \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .contentShape(.rect)
        // Combining children drops the selectable detail from the label, so both are spelled out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var occurrenceLabel: String {
        "\(flag.occurrenceCount) failure\(flag.occurrenceCount == 1 ? "" : "s")"
    }

    private var accessibilityDescription: String {
        let detail = "\(flag.kind.displayName): \(flag.detail)"
        guard let last = flag.lastOccurredAt else { return detail }
        return "\(detail). \(occurrenceLabel), last \(last.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: For display

private extension HealthFlagKind {
    /// `Stale Operator identity`: the glossary's words, capitalised as a row title.
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
