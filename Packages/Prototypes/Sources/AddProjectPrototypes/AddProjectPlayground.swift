#if DEBUG
import SwiftUI

// The Add Project prototyping harness. Debug builds only.
//
// - Hub4, `SplitHubWizard`, is the one prototype kept: a view that takes a `Binding<AddProjectDraft>`
//   and draws the whole sheet. The app's version of it is in `Yellowhammer/Features/AddProject`.
// - Colours and typography are fixed (`WizardTheme`, system text styles).
// - The "Playground" preview hosts Hub4 over a mock main window beside live controls.
// - Round three's variants, `AddProjectVariant.all`, solve six of Hub4's problems in different ways; the
//   Playground's Variant picker swaps between them, and each has a preview of its own.
//
// Hub4 reads only the draft and calls `addProjectAction` for every way out of the sheet. It never runs
// `yh` or touches the disk.

/// The sheet's size: the wizard is a sheet, so it is drawn at a fixed size.
private let sheetSize = CGSize(width: 900, height: 620)

/// The sheet over a dimmed mock of the main window, so the sheet is judged where it will appear.
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
    init(variant: String = "Hub4", scenario: AddProjectScenario = .repoConflict, step: WizardStep? = nil) {
        _variantName = State(initialValue: variant)
        _scenario = State(initialValue: scenario)
        var draft = scenario.draft
        if let step { draft.go(to: step, allowingAhead: true) }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let action = $lastAction
        HStack(spacing: 0) {
            AddProjectStage(size: sheetSize) { wizard }
                .environment(\.addProjectAction) { action.wrappedValue = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .preferredColorScheme(darkAppearance ? .dark : .light)

            Divider()
            controls.frame(width: 300)
        }
        .frame(minWidth: 1_340, minHeight: 760)
    }

    private var variant: AddProjectVariant? { AddProjectVariant.named(variantName) }

    /// Keyed by variant and scenario, so switching either starts the sheet afresh.
    @ViewBuilder private var wizard: some View {
        if let design = variant?.design {
            VariantHubWizard(draft: $draft, design: design).id("\(variantName)-\(scenario.rawValue)")
        } else {
            SplitHubWizard(draft: $draft).id("\(variantName)-\(scenario.rawValue)")
        }
    }

    private var controls: some View {
        Form {
            Section("Prototype") {
                Picker("Variant", selection: $variantName) {
                    ForEach(AddProjectVariant.all) { Text($0.name).tag($0.name) }
                }
                .onChange(of: variantName) { draft = scenario.draft }
                if let idea = variant?.idea {
                    Text(idea).font(.callout).foregroundStyle(.secondary)
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

#Preview("Playground") {
    AddProjectPlayground()
}

#Preview("Hub4") {
    AddProjectPlayground(scenario: .fresh)
}

#Preview("A · Continue") { AddProjectPlayground(variant: "A · Continue", scenario: .fresh) }
#Preview("B · Next card") { AddProjectPlayground(variant: "B · Next card", scenario: .fresh) }
#Preview("C · Back and Next") { AddProjectPlayground(variant: "C · Back and Next", scenario: .fresh) }
#Preview("D · Next needed") { AddProjectPlayground(variant: "D · Next needed", scenario: .fresh) }
#Preview("E · Quiet") { AddProjectPlayground(variant: "E · Quiet", scenario: .fresh) }
#Preview("F · Banner") { AddProjectPlayground(variant: "F · Banner", scenario: .fresh) }
#Preview("G · Guided") { AddProjectPlayground(variant: "G · Guided", scenario: .fresh) }

#Preview("Hub4 — Linear project") {
    @Previewable @State var draft: AddProjectDraft = {
        var draft = AddProjectDraft()
        draft.setName("Acme")
        return draft
    }()
    AddProjectStage(size: sheetSize) {
        SplitHubWizard(draft: $draft, opensOnLinear: true)
    }
    .frame(width: 1_040, height: 760)
}
#endif
