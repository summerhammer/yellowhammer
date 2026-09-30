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
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
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
                    ForEach(flags) { HealthFlagRow(flag: $0) }
                }
                Button("Open Settings") { openDestination(.settings) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("pulse-health-settings")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Health", systemImage: "stethoscope")
        }
        .accessibilityIdentifier("pulse-health")
    }
}

/// One flag: its kind, and `yh doctor`'s message for it.
private struct HealthFlagRow: View {
    let flag: HealthFlag

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.kind.displayName)
                Text(flag.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        // Combining children drops the selectable detail from the label, so both are spelled out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flag.kind.displayName): \(flag.detail)")
        .accessibilityIdentifier("health-flag")
    }
}

// MARK: For display

private extension HealthFlagKind {
    /// `Stale Operator identity`: the glossary's words, capitalised as a row title.
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
