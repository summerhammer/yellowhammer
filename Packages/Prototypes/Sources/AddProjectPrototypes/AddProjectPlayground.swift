#if DEBUG
import SwiftUI

// The Add Project prototyping harness. Debug builds only.
//
// - `AddProjectVariant.all` lists every prototype: a view that takes a `Binding<AddProjectDraft>` and
//   draws the whole sheet. Only names in `AddProjectVariant.shown` are offered by the Playground and
//   Gallery; a `#Preview` can still open any variant by name.
// - Colours and typography are fixed (`WizardTheme`, system text styles); variants differ in layout
//   and components only.
// - The "Playground" preview hosts one variant over a mock main window beside live controls.
// - The "Gallery" preview shows one variant at a time: pick it from the menu or step with ← and →.
//
// A variant reads only the draft and calls `addProjectAction` for every way out of the sheet. It never
// runs `yh` or touches the disk.

/// One prototype of the Add Project sheet.
struct AddProjectVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line.
    let idea: String
    /// The sheet's size: the wizard is a sheet, so it is drawn at a fixed size.
    let size: CGSize
    let make: (Binding<AddProjectDraft>) -> AnyView

    var id: String { name }

    init<Content: View>(
        _ name: String,
        idea: String,
        size: CGSize = CGSize(width: 760, height: 540),
        @ViewBuilder make: @escaping (Binding<AddProjectDraft>) -> Content
    ) {
        self.name = name
        self.idea = idea
        self.size = size
        self.make = { AnyView(make($0)) }
    }
}

/// The sheet over a dimmed mock of the main window, so a variant is judged where it will appear.
struct AddProjectStage<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            mockWindow
            Color.black.opacity(0.12)
            content
                .frame(width: size.width, height: size.height)
                .background(.windowBackground)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .padding(.top, 38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The landing screen's outline only: the Sidebar with its "+" and an empty Pulse.
    private var mockWindow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Label("Beta Service", systemImage: "circle.fill").foregroundStyle(WizardTheme.active)
                Label("Docs Site", systemImage: "circle").foregroundStyle(WizardTheme.neutral)
                Spacer()
                Image(systemName: "plus").foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .padding(14)
            .frame(width: 200, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(WizardTheme.surface)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Yellowhammer").font(.headline)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12).fill(WizardTheme.surface).frame(height: 120)
                }
                Spacer()
            }
            .padding(14)
        }
        .background(.windowBackground)
    }
}

// MARK: - Playground

struct AddProjectPlayground: View {
    @State private var variantName: String
    @State private var scenario: AddProjectScenario
    @State private var draft: AddProjectDraft
    @State private var lastAction: String?
    @State private var darkAppearance = false

    /// `step` opens the scenario on another step, so a preview can show one step's content.
    init(variant: String? = nil, scenario: AddProjectScenario = .repoConflict, step: WizardStep? = nil) {
        _variantName = State(initialValue: variant ?? AddProjectVariant.inPlay.first?.name ?? "")
        _scenario = State(initialValue: scenario)
        var draft = scenario.draft
        if let step { draft.go(to: step, allowingAhead: true) }
        _draft = State(initialValue: draft)
    }

    private var variant: AddProjectVariant? {
        AddProjectVariant.all.first { $0.name == variantName } ?? AddProjectVariant.inPlay.first
    }

    private var pickable: [AddProjectVariant] {
        let shown = AddProjectVariant.inPlay
        guard let variant, !shown.contains(where: { $0.name == variant.name }) else { return shown }
        return shown + [variant]
    }

    var body: some View {
        let action = $lastAction
        HStack(spacing: 0) {
            Group {
                if let variant {
                    AddProjectStage(size: variant.size) { variant.make($draft) }
                } else {
                    Text("No variant in AddProjectVariant.shown")
                }
            }
            .environment(\.addProjectAction) { action.wrappedValue = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(darkAppearance ? .dark : .light)

            Divider()
            controls.frame(width: 300)
        }
        .frame(minWidth: 1_340, minHeight: 760)
    }

    private var controls: some View {
        Form {
            Section("Prototype") {
                Picker("Variant", selection: $variantName) {
                    ForEach(pickable) { Text($0.name).tag($0.name) }
                }
                if let variant {
                    Text(variant.idea).font(.callout).foregroundStyle(.secondary)
                }
                Picker("Scenario", selection: $scenario) {
                    ForEach(AddProjectScenario.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: scenario) { _, newValue in draft = newValue.draft }
                Button("Reset Scenario") { draft = scenario.draft }
                Toggle("Dark appearance", isOn: $darkAppearance)
            }
            Section("Draft") {
                Picker("Step", selection: stepBinding) {
                    ForEach(WizardStep.allCases) { Text("\($0.number). \($0.shortTitle)").tag($0) }
                }
                Toggle("Run fails", isOn: $draft.runFails)
                LabeledContent("Complete steps", value: "\(WizardStep.allCases.count(where: draft.isComplete)) of 5")
            }
            Section("Last way out") {
                Text(lastAction ?? "None yet — press Cancel or Done")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var stepBinding: Binding<WizardStep> {
        Binding { draft.step } set: { draft.go(to: $0, allowingAhead: true); draft.run = .notStarted }
    }
}

// MARK: - Gallery

struct AddProjectGallery: View {
    @State private var scenario: AddProjectScenario = .repoConflict
    @State private var index = 0

    private var variants: [AddProjectVariant] { AddProjectVariant.inPlay }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if variants.indices.contains(index) {
                AddProjectGalleryTile(variant: variants[index], scenario: scenario)
                    .id("\(variants[index].id)/\(scenario.id)")
            }
        }
        .frame(minWidth: 1_140, minHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Variant", selection: $index) {
                ForEach(variants.indices, id: \.self) { Text(variants[$0].name).tag($0) }
            }
            .fixedSize()
            ControlGroup {
                Button("Previous", systemImage: "chevron.left") { index -= 1 }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index <= 0)
                Button("Next", systemImage: "chevron.right") { index += 1 }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= variants.count - 1)
            }
            .fixedSize()
            Text("\(index + 1) of \(variants.count)").monospacedDigit().foregroundStyle(.secondary)
            if variants.indices.contains(index) {
                Text(variants[index].idea).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Scenario", selection: $scenario) {
                ForEach(AddProjectScenario.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
    }
}

/// One variant with its own draft, so it can be clicked through independently.
private struct AddProjectGalleryTile: View {
    let variant: AddProjectVariant
    @State private var draft: AddProjectDraft

    init(variant: AddProjectVariant, scenario: AddProjectScenario) {
        self.variant = variant
        _draft = State(initialValue: scenario.draft)
    }

    var body: some View {
        AddProjectStage(size: variant.size) { variant.make($draft) }
    }
}

#Preview("Playground") {
    AddProjectPlayground()
}

#Preview("Gallery") {
    AddProjectGallery()
}
#endif
