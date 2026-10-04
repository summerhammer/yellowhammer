import SwiftUI

// The Settings window's panes are drawn the way the Add Project sheet draws a step: a heading, then a
// scrolling column of the wizard's blocks (`WizardBlock`, `WizardBlockRow`), cards for the items a pane
// edits, and, for a pane that saves, a footer bar under a divider.

/// A Settings pane: its heading, its column of blocks and, when it saves, its footer. A pane whose heading
/// is drawn by its container (a Project's two tabs) passes no title.
struct SettingsPane<Content: View, Footer: View>: View {
    var title: String?
    var explanation = ""
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                PaneHeading(title: title, explanation: explanation)
                    .padding([.horizontal, .top], 20)
            }
            WizardColumn { content }
            if Footer.self != EmptyView.self {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension SettingsPane where Footer == EmptyView {
    init(title: String? = nil, explanation: String = "", @ViewBuilder content: () -> Content) {
        self.init(title: title, explanation: explanation, content: content) { EmptyView() }
    }
}

/// The footer of a pane that writes a file: why the last save was refused, what saving does to the file,
/// then Revert and Save. Its identifiers are `<prefix>-save-failure`, `<prefix>-revert` and `<prefix>-save`.
struct SettingsSaveFooter: View {
    var note: String?
    let failure: String?
    let isDirty: Bool
    let identifierPrefix: String
    let onRevert: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure {
                SettingsFailureText(text: failure, identifier: "\(identifierPrefix)-save-failure")
            }
            HStack(spacing: 12) {
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Revert", action: onRevert)
                    .disabled(!isDirty)
                    .accessibilityIdentifier("\(identifierPrefix)-revert")
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(!isDirty)
                    .accessibilityIdentifier("\(identifierPrefix)-save")
            }
        }
        .padding(16)
    }
}

/// A card for one item a pane edits — a Repo, a Routing Entry, a Linear workspace — like the Add Project
/// sheet's Repo cards. A card with a problem is tinted `error`; a highlighted one — the Routing Entry that
/// answers "Test a Card" — is drawn in `accent`.
struct SettingsCard<Content: View>: View {
    var hasProblem = false
    var isHighlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(tint.opacity(isHighlighted ? 0.6 : 0.22), lineWidth: isHighlighted ? 1.5 : 1)
            )
    }

    private var tint: AnyShapeStyle {
        if hasProblem { return AnyShapeStyle(.error) }
        return isHighlighted ? AnyShapeStyle(.accent) : AnyShapeStyle(.neutral)
    }
}

/// What went wrong, in the words of whatever refused it, in `error`. The identifier is on the text, so a
/// UI test reads the message itself.
struct SettingsFailureText: View {
    let text: String
    var identifier = ""
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(text)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .font(.callout)
        .foregroundStyle(.error)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pane that has nothing to show: why, centred.
struct SettingsUnavailable: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A read-only value in a boxed block's row: selectable, never a field.
struct SettingsValueText: View {
    let value: String
    var monospaced = false

    var body: some View {
        Text(value)
            .font(monospaced ? .body.monospaced() : .body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}
