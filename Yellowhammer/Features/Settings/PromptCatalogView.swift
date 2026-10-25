import Domain
import SwiftUI

/// A boxed settings block displaying prompt catalog entries.
struct PromptCatalogBlock: View {
    let title: String
    let entries: [PromptCatalogEntry]
    @State private var selectedEntry: PromptCatalogEntry?

    init(
        title: String = "Prompts",
        entries: [PromptCatalogEntry] = PromptCatalog.entries
    ) {
        self.title = title
        self.entries = entries
    }

    var body: some View {
        WizardBlock(
            title: title,
            footer: "Shipped defaults Yellowhammer uses to dispatch agent CLIs. Tap a prompt to inspect its template."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, 12)
                    }
                    row(for: entry)
                }
            }
        }
        .sheet(item: $selectedEntry) { entry in
            PromptTemplateSheet(entry: entry)
        }
    }

    private func row(for entry: PromptCatalogEntry) -> some View {
        Button {
            selectedEntry = entry
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(entry.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Default version \(entry.defaultVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        entry.acceptsProjectInstructions
                            ? "Accepts Project instructions"
                            : "Locked: no Project instructions"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-prompts-\(entry.family.rawValue)") // glossary:ignore GL001
    }
}

/// A read-only sheet displaying a prompt family's shipped default template and its placeholders.
struct PromptTemplateSheet: View {
    let entry: PromptCatalogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                Text(entry.title)
                    .font(.title2.weight(.semibold))
                PromptTemplateBadge()
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text(
                "Placeholders such as \u{27E8}work card title\u{27E9} are filled in at dispatch. "
                    + "This is not text sent to an agent."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(entry.variants) { variant in
                        VStack(alignment: .leading, spacing: 10) {
                            if entry.variants.count > 1 {
                                Text(variant.name)
                                    .font(.headline)
                            }
                            if !variant.placeholders.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Placeholders")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(variant.placeholders.joined(separator: ", "))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            ScrollView(.vertical) {
                                Text(variant.template)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(minHeight: 220, maxHeight: 400)
                            .background(.surface, in: .rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                            .accessibilityIdentifier("settings-prompt-template") // glossary:ignore GL001
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .accessibilityElement(children: .contain)
    }
}

/// A badge labeling a template as a template with marked placeholders.
struct PromptTemplateBadge: View {
    var body: some View {
        Text("Template")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.14), in: .capsule)
    }
}
