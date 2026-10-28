import Domain
import SwiftUI

/// Shows a production prompt's shipped template composed with the Operator's draft (*Preview*), or beside
/// the shipped one (*Compare*). Both are the catalog's real renderers; nothing here is sent to an agent.
struct ProjectInstructionsPreviewSheet: View {
    enum Mode {
        case preview
        case compare
    }

    let text: String
    let mode: Mode
    @State private var family = PromptFamily.selection
    @State private var variantName = ""
    @Environment(\.dismiss) private var dismiss

    private var shippedEntries: [PromptCatalogEntry] {
        PromptCatalog.entries.filter(\.family.acceptsProjectInstructions)
    }

    private var customizedEntries: [PromptCatalogEntry] {
        PromptCatalog.entries(projectInstructions: text).filter(\.family.acceptsProjectInstructions)
    }

    private var shipped: PromptCatalogEntry? { shippedEntries.first { $0.family == family } }
    private var customized: PromptCatalogEntry? { customizedEntries.first { $0.family == family } }

    private var variantIndex: Int {
        customized?.variants.firstIndex { $0.name == variantName } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            pickers
            if let shipped, let customized, customized.variants.indices.contains(variantIndex) {
                let after = customized.variants[variantIndex]
                let before = shipped.variants[variantIndex]
                let comparison = ProjectInstructionsComparison(
                    shipped: before.template, customized: after.template, projectInstructions: text
                )
                switch mode {
                case .preview: preview(after, comparison)
                case .compare: compare(before, after, comparison)
                }
            }
        }
        .padding(20)
        .frame(minWidth: mode == .compare ? 900 : 640, minHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(sheetIdentifier)
    }

    private var sheetIdentifier: String {
        let kind = mode == .preview ? "preview" : "compare"
        return "settings-project-instructions-\(kind)-sheet" // glossary:ignore GL001
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(mode == .preview ? "Preview" : "Compare").font(.title2.weight(.semibold))
            PromptTemplateBadge()
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings-project-instructions-sheet-done") // glossary:ignore GL001
        }
    }

    private var pickers: some View {
        HStack(spacing: 12) {
            Picker("Prompt", selection: $family) {
                ForEach(shippedEntries) { Text($0.title).tag($0.family) }
            }
            .fixedSize()
            .accessibilityIdentifier("settings-project-instructions-family") // glossary:ignore GL001
            if let variants = customized?.variants, variants.count > 1 {
                Picker("Variant", selection: $variantName) {
                    ForEach(variants) { Text($0.name).tag($0.name) }
                }
                .fixedSize()
                .accessibilityIdentifier("settings-project-instructions-variant") // glossary:ignore GL001
            }
            Spacer()
        }
        .onChange(of: family) { variantName = customized?.variants.first?.name ?? "" }
        .onAppear { variantName = customized?.variants.first?.name ?? "" }
    }

    // MARK: Preview

    private func preview(
        _ variant: PromptTemplateVariant, _ comparison: ProjectInstructionsComparison?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Yellowhammer\u{2019}s sections are locked. Your text is the one Project instructions section. "
                    + "Placeholders such as \u{27E8}work card title\u{27E9} are filled in at dispatch; "
                    + "this is not text sent to an agent."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !variant.placeholders.isEmpty {
                Text("Placeholders: " + variant.placeholders.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let comparison {
                        segment("Locked \u{2014} Yellowhammer", comparison.before, operators: false)
                        segment("Your Project instructions", comparison.added, operators: true)
                        segment("Locked \u{2014} Yellowhammer", comparison.after, operators: false)
                    } else {
                        segment(
                            "Locked \u{2014} Yellowhammer (no Project instructions: the shipped prompt)",
                            variant.template, operators: false
                        )
                    }
                }
            }
            .accessibilityIdentifier("settings-project-instructions-preview-text") // glossary:ignore GL001
        }
    }

    // MARK: Compare

    private func compare(
        _ shipped: PromptTemplateVariant, _ customized: PromptTemplateVariant,
        _ comparison: ProjectInstructionsComparison?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary(comparison))
                .font(.callout)
                .foregroundStyle(
                    comparison?.isOnlyDifference == false ? AnyShapeStyle(.error) : AnyShapeStyle(.secondary)
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-project-instructions-compare-summary") // glossary:ignore GL001
            HStack(alignment: .top, spacing: 12) {
                column("Shipped template") {
                    segment(nil, shipped.template, operators: false)
                }
                column("With Project instructions") {
                    if let comparison {
                        segment(nil, comparison.before, operators: false)
                        segment("Added", comparison.added, operators: true)
                        segment(nil, comparison.after, operators: false)
                    } else {
                        segment(nil, customized.template, operators: false)
                    }
                }
            }
        }
    }

    private func summary(_ comparison: ProjectInstructionsComparison?) -> String {
        guard let comparison else {
            return "No difference: with no Project instructions the prompt is the shipped one."
        }
        let position = comparison.precedesHeading.map { "immediately before \u{201C}\($0)\u{201D}" } ?? "at the end"
        guard comparison.isOnlyDifference else {
            return "The prompts differ by more than the Project instructions section. This is unexpected."
        }
        return "The only difference is one added Project instructions section, placed \(position). "
            + "The contract is unchanged, not forked."
    }

    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 8) { content() } }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// One run of a prompt. Yellowhammer's text is plain; the Operator's is tinted and labelled as theirs,
    /// and is the only text never treated as a template.
    private func segment(_ caption: String?, _ text: String, operators: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                Text(caption).font(.caption.weight(.semibold)).foregroundStyle(operators ? .primary : .secondary)
            }
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    operators ? AnyShapeStyle(.accent.opacity(0.12)) : AnyShapeStyle(.surface),
                    in: .rect(cornerRadius: 8)
                )
        }
    }
}
