#if DEBUG
import SwiftUI

// Hub4's building blocks. A step is a column of blocks rather than a grouped Form, so option cards
// and radio lists can sit outside a boxed group.

/// A titled group: an optional header, its rows in a softly filled box, and an optional footer.
struct WizardBlock<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row in a boxed block: a label on the left, its control on the right.
struct WizardBlockRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A step's column of blocks, scrollable, at a readable width.
struct WizardColumn<Content: View>: View {
    var maxWidth: CGFloat = .infinity
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A choice drawn as a card, so every option and what it implies are visible before choosing.
struct OptionCard: View {
    let title: String
    let detail: String
    var points: [String] = []
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? WizardTheme.accent : WizardTheme.neutral)
                    Text(title).font(.headline)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(points, id: \.self) { point in
                    Label(point, systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(BulletLabelStyle())
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                isSelected ? WizardTheme.accent.opacity(0.07) : WizardTheme.surface, in: .rect(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? WizardTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Two or three option cards side by side, at equal heights.
struct OptionCards<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A selectable row in a boxed list: one radio, a title, an optional subtitle and trailing note.
struct RadioRow: View {
    let title: String
    var subtitle: String?
    var note: String?
    var monospaced = false
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? WizardTheme.accent : WizardTheme.neutral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(monospaced ? .body.monospaced() : .body)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? WizardTheme.accent.opacity(0.07) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row that adds something to a list: an action, not a choice.
struct AddRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .foregroundStyle(WizardTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.caption2.weight(.bold))
            configuration.title
        }
    }
}

// MARK: - The Project id

/// The id as a locked token: monospaced, with a padlock, so it reads as a fixed value, not a field.
struct IdToken: View {
    let id: String
    var locked = true

    var body: some View {
        HStack(spacing: 5) {
            if locked {
                Image(systemName: "lock.fill").font(.caption)
            }
            Text(id.isEmpty ? "—" : id).font(.body.monospaced())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(WizardTheme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project id \(id)\(locked ? ", permanent" : "")")
    }
}

struct PermanentBadge: View {
    var body: some View {
        Text("Permanent")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WizardTheme.attention)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(WizardTheme.attention.opacity(0.14), in: .capsule)
    }
}

/// Everything the id names on disk and in `launchd`, so "permanent" has a concrete meaning.
struct IdNamesList: View {
    let id: String

    var body: some View {
        let id = id.isEmpty ? "<id>" : id
        VStack(alignment: .leading, spacing: 0) {
            row("Project file", "~/.config/yellowhammer/projects/\(id).toml")
            Divider().padding(.leading, 12)
            row("Journal", "~/.config/yellowhammer/journals/\(id).db")
            Divider().padding(.leading, 12)
            row("LaunchAgents", "dev.yellowhammer.\(id).{author,build,land}")
            Divider().padding(.leading, 12)
            row("Logs", "~/Library/Logs/Yellowhammer/\(id).<act>.log")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// A note in the `info` colour: something true and worth knowing, not a problem.
struct WizardNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.callout)
            .foregroundStyle(WizardTheme.info)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Hub parts

/// One hub row: no icon, a title and the step's summary, and a trailing mark only where there is
/// something to say — a tick when done, a count of problems once visited.
struct WizardSidebarRow: View {
    let title: String
    let summary: String
    let status: WizardStepStatus
    let problemCount: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch status {
            case .done:
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(WizardTheme.success)
                    .accessibilityLabel("Done")
            case .problem:
                Text("\(problemCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(WizardTheme.onColor)
                    .padding(.horizontal, 6)
                    .background(WizardTheme.error, in: .capsule)
                    .accessibilityLabel("\(problemCount) problems")
            case .upcoming:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
    }
}

/// Progress as words: how many steps are ready, and which are still needed.
struct WizardReadiness: View {
    /// "Still needed: …", or nil when nothing is.
    let stillNeeded: String?

    var body: some View {
        if let stillNeeded {
            Text(stillNeeded).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Label("Ready to add", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(WizardTheme.success)
        }
    }
}

/// The hub's footer: Cancel; what is still needed; Add Project — or Done and Close after the run.
struct WizardHubFooter: View {
    @Binding var draft: AddProjectDraft
    /// "Still needed: …", or nil when every page is ready.
    let stillNeeded: String?
    let addProject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if draft.run == .notStarted {
                WizardCancelButton(caption: false)
                Spacer()
                WizardReadiness(stillNeeded: stillNeeded)
                Button("Add Project", action: addProject)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
            } else {
                Spacer()
                WizardNavigationButtons(draft: $draft)
            }
        }
        .padding(16)
    }
}
#endif
