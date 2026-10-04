import Config
import SwiftUI

// Round two's building blocks. A step is a column of blocks rather than a grouped Form, so option
// cards and radio lists can sit outside a boxed group, and every variant draws a step the same way.

/// A titled group: an optional header, its rows in a softly filled box, and an optional footer.
struct WizardBlock<Content: View>: View {
    var title: String?
    var footer: String?
    var boxed = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            if boxed {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.surface, in: .rect(cornerRadius: 10))
            } else {
                content
            }
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
    /// The Button's accessibility identifier, so a UI test can click the card; empty for none.
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.accent) : AnyShapeStyle(.neutral))
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
                isSelected ? AnyShapeStyle(.accent.opacity(0.07)) : AnyShapeStyle(.surface),
                in: .rect(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(.accent.opacity(0.6)) : AnyShapeStyle(.clear),
                        lineWidth: 1.5
                    )
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
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
    /// The Button's accessibility identifier; empty for none.
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.accent) : AnyShapeStyle(.neutral))
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
            .background(isSelected ? AnyShapeStyle(.accent.opacity(0.07)) : AnyShapeStyle(.clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A row that adds something to a list: an action, not a choice.
struct AddRow: View {
    let title: String
    /// The Button's accessibility identifier; empty for none.
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .foregroundStyle(.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyle.Configuration) -> some View {
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
        .background(.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project id \(id)\(locked ? ", permanent" : "")")
        .accessibilityValue(id)
    }
}

struct PermanentBadge: View {
    var body: some View {
        Text("Permanent")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.attention)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.attention.opacity(0.14), in: .capsule)
    }
}

/// Everything the id names on disk and in `launchd`, so "permanent" has a concrete meaning.
struct IdNamesList: View {
    let id: String
    var configurationDirectory: URL = ConfigurationDirectory.current
    // LaunchAgent label and log formats mirror Status+Project.launchAgentLabel and ScheduledJob.logPath in EngineCommand.

    var body: some View {
        let id = id.isEmpty ? "<id>" : id
        VStack(alignment: .leading, spacing: 0) {
            row(
                "Project file",
                configurationDirectory
                    .appending(components: "projects", "\(id).toml")
                    .path(percentEncoded: false)
            )
            Divider().padding(.leading, 12)
            row(
                "Journal",
                configurationDirectory
                    .appending(components: "journals", "\(id).db")
                    .path(percentEncoded: false)
            )
            Divider().padding(.leading, 12)
            row("LaunchAgents", "dev.yellowhammer.\(id).{author,build,land}")
            Divider().padding(.leading, 12)
            row("Logs", "~/Library/Logs/Yellowhammer/\(id).<act>.log")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        let displayValue = (value as NSString).abbreviatingWithTildeInPath
        return HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(displayValue).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
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
            .foregroundStyle(.info)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Problem list

/// What a step still needs, as a titled block after its content. Every step reports its problems this way,
/// and only once the Operator has left the step (``AddProjectDraft/revealsProblems(in:)``), so a page never
/// opens on an error.
struct WizardProblemBox: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To finish this step").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            WizardProblemList(problems: problems)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surface, in: .rect(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-step-problems")
    }
}

/// A step's problems in `error`, at most `limit` of them.
struct WizardProblemList: View {
    let problems: [String]
    var limit = Int.max

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems.prefix(limit), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.error)
            }
        }
    }
}
