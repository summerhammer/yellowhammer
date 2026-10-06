#if DEBUG
import SwiftUI

// The Settings window around a variant, drawn the way the app draws it today (`SettingsWindow`,
// `SettingsPane`, `SettingsSaveFooter`): the sidebar with the pane's section selected, the pane's heading,
// the variant, and — for a pane that saves — the save footer. Only the variant differs between prototypes.

/// The Settings window's size in the app's screenshot.
let settingsWindowSize = CGSize(width: 1_000, height: 700)

/// The panes the prototypes draw, with the heading the app gives each.
enum StageSection: String, CaseIterable, Identifiable {
    case agentCLIs = "Agent CLIs"
    case baseRoutingTable = "Base Routing Table"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .agentCLIs:
            "The agent CLIs this Mac can dispatch to. A Probe checks that one works as its CLI Adapter "
                + "expects; one Probe run serves every Project."
        case .baseRoutingTable:
            "Who works on each Card: the agent CLI, model and effort for each Kind and Repo Role, with "
                + "fallbacks in order. Every Project on this Mac reads this table; a Project\u{2019}s own "
                + "entry for the same Kind and Repo Role replaces the one here."
        }
    }

    /// Whether the pane saves through a footer. Declaring or removing an agent CLI writes at once.
    var saves: Bool { self == .baseRoutingTable }
}

struct SettingsStage<Content: View>: View {
    var section = StageSection.baseRoutingTable
    var isDirty = false
    var onRevert: () -> Void = {}
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                heading.padding([.horizontal, .top], 20).padding(.bottom, 12)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if section.saves {
                    Divider()
                    footer
                }
            }
        }
        .frame(width: settingsWindowSize.width, height: settingsWindowSize.height)
        .background(.windowBackground)
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.rawValue).font(.title2.weight(.semibold))
            Text(section.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(
                "Saving rewrites ~/.config/yellowhammer/config.toml; comments and layout in it are not kept. "
                    + "Editing the file directly stays supported."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            Spacer(minLength: 12)
            Button("Revert", action: onRevert).disabled(!isDirty)
            Button("Save") {}
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
        }
        .padding(16)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("This Mac")
            sidebarRow("General", "Orca ADE")
            sidebarRow("Boards", "Board connections")
            sidebarRow("Agent CLIs", "Declared CLIs and their Probes", selected: section == .agentCLIs)
            sidebarRow("Base Routing Table", "Routes every Project shares", selected: section == .baseRoutingTable)
            sidebarRow("Refused Files", "None")
            sectionTitle("Projects").padding(.top, 14)
            sidebarRow("Yellowhammer", nil)
            Spacer()
            Label("Add Project\u{2026}", systemImage: "plus").foregroundStyle(.secondary).padding(8)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.surface)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 8)
    }

    private func sidebarRow(_ title: String, _ subtitle: String?, selected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).fontWeight(.medium)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.primary.opacity(0.09) : .clear, in: .rect(cornerRadius: 8))
    }
}

/// A variant's scrolling column, at the pane's padding.
struct SettingsColumn<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }
}

/// A titled group: an optional header, its content in a softly filled box, and an optional footer — the
/// app's `WizardBlock`.
struct SettingsBlock<Content: View>: View {
    var title: String?
    var footer: String?
    var boxed = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(boxed ? SettingsTheme.surface : .clear, in: .rect(cornerRadius: 10))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A card for one item the pane edits — the app's `SettingsCard`. A highlighted card is drawn in the accent.
struct RoutingCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted ? SettingsTheme.accent.opacity(0.07) : Color.primary.opacity(0.035),
                in: .rect(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(highlighted ? SettingsTheme.accent.opacity(0.6) : Color.primary.opacity(0.1),
                                  lineWidth: highlighted ? 1.5 : 1)
            )
    }
}

/// What to show while the table has no entry: what that means, and the one way forward.
struct RoutingEmptyState: View {
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Routing Entries", systemImage: "arrow.triangle.branch")
        } description: {
            Text("No Card can be dispatched until an entry routes it. Start with one for Any Kind and Any Repo Role.")
        } actions: {
            Button("Add a Catch-All Entry", action: add).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}
#endif
