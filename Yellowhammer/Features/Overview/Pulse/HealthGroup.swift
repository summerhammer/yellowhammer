import Pulse
import SwiftUI

/// The Pulse's Health group: the `yh doctor` flags (stale Operator identity, App Installation revoked,
/// probe failures), each with `yh doctor`'s own message. Opens the Settings window, where the Operator
/// acts on a flag; the group itself fixes nothing.
///
/// `health` is nil until `yh doctor` has been read, and whenever it cannot be. The group states that
/// rather than claiming there are no flags.
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
                    Button { openDestination(flag.destination) } label: { HealthFlagRow(flag: flag) }
                        .buttonStyle(.plain)
                        .help(flag.destination == .linearWorkspaces
                            ? "Open Settings → Boards" : "Open the Project's Settings")
                        // On the Button, which is the accessibility element the row's label becomes.
                        .accessibilityIdentifier("health-flag")
                }
            }
            Button("Open Settings") { openDestination(.settings) }
                .buttonStyle(.link)
                .accessibilityIdentifier("pulse-health-settings")
        }
        .accessibilityIdentifier("pulse-health")
    }
}

/// One flag: its kind, and `yh doctor`'s message for it.
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
            }
            Spacer(minLength: 8)
        }
        .contentShape(.rect)
        // Combining children drops the selectable detail from the label, so both are spelled out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flag.kind.displayName): \(flag.detail)")
    }
}

// MARK: For display

private extension HealthFlagKind {
    /// `Stale Operator identity`: the glossary's words, capitalised as a row title.
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
