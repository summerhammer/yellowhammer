#if DEBUG
import SwiftUI

extension AddProjectVariant {
    /// The variants the Playground and Gallery offer: Hub4, the one chosen to build. Every other variant
    /// stays in `all`, reachable by name from a `#Preview`, so a shelved idea can come back without being
    /// rewritten.
    static let shown: Set<String> = ["Hub4"]

    /// The shown variants, in catalog order.
    static var inPlay: [AddProjectVariant] { all.filter { shown.contains($0.name) } }

    static let all: [AddProjectVariant] = roundTwo + roundOne

    /// From the round-one feedback. Each also tries one answer to each of the four open questions:
    /// the permanent id, the Linear project, the specification source, and what a Bound means.
    static let roundTwo: [AddProjectVariant] = [
        AddProjectVariant(
            "Hub",
            idea: "Checklist without icons or a bar; id as a Permanent token; option cards; explained Bounds",
            size: CGSize(width: 900, height: 620)
        ) { HubWizard(draft: $0) },
        AddProjectVariant(
            "Hub2",
            idea: "Hub with the picks: Permanent id confirmed on Add, one Linear list, spec cards, Bounds as sentences",
            size: CGSize(width: 900, height: 620)
        ) { Hub2Wizard(draft: $0) },
        AddProjectVariant(
            "Hub3",
            idea: "Hub2 with the first step split: the name and id, and the Linear project, each a step",
            size: CGSize(width: 900, height: 620)
        ) { SplitHubWizard(draft: $0, components: hubComponents) },
        AddProjectVariant(
            "Hub4",
            idea: "Hub3 with the Linear project as in Hub: existing-or-new cards over the matching list",
            size: CGSize(width: 900, height: 620)
        ) { SplitHubWizard(draft: $0, components: hub4Components) },
        AddProjectVariant(
            "Focused Hub",
            idea: "Hub list beside the Focus layout; id confirmed in a dialog; one list per choice; "
                + "Bounds as sentences",
            size: CGSize(width: 940, height: 640)
        ) { FocusedHubWizard(draft: $0) },
        AddProjectVariant(
            "Focus Pages",
            idea: "Focus kept whole, navigable from a step menu and status dots; the name leads, the id follows",
            size: CGSize(width: 700, height: 640)
        ) { FocusPagesWizard(draft: $0) },
        AddProjectVariant(
            "Name First",
            idea: "A focused page locks the id in before the hub opens; the hub carries it in its header",
            size: CGSize(width: 880, height: 620)
        ) { NameFirstWizard(draft: $0) },
        AddProjectVariant(
            "Overview and Edit",
            idea: "Opens on the whole Project at a glance; each row opens its step as a focused page",
            size: CGSize(width: 680, height: 640)
        ) { OverviewEditWizard(draft: $0) }
    ]

    static let roundOne: [AddProjectVariant] = [
        AddProjectVariant(
            "Wireframe",
            idea: "The wireframe as drawn: numbered step list, path + role chip + Check pill rows, Back and Continue"
        ) { WireframeWizard(draft: $0) },
        AddProjectVariant(
            "Assistant",
            idea: "Installer-style tinted pane with step status; title and a sentence per step; Repos as a table"
        ) { AssistantWizard(draft: $0) },
        AddProjectVariant(
            "Top Stepper",
            idea: "A numbered stepper bar across the top, ticked as steps complete; Repos as tinted cards"
        ) { StepperWizard(draft: $0) },
        AddProjectVariant(
            "Focus",
            idea: "One question per page, like Setup Assistant: large title, narrow column, page dots",
            size: CGSize(width: 680, height: 600)
        ) { FocusWizard(draft: $0) },
        AddProjectVariant(
            "Accordion",
            idea: "Every step on one sheet; folded steps show their summary and Edit; the open one fills the rest",
            size: CGSize(width: 760, height: 600)
        ) { AccordionWizard(draft: $0) },
        AddProjectVariant(
            "Live Preview",
            idea: "Tabs in any order beside the Project file it will write, with what still blocks it",
            size: CGSize(width: 1_000, height: 580)
        ) { LivePreviewWizard(draft: $0) },
        AddProjectVariant(
            "Checklist",
            idea: "A hub of five tasks with tiles, status and summaries; Add Project lights up when all are ready",
            size: CGSize(width: 860, height: 560)
        ) { ChecklistWizard(draft: $0) }
    ]
}

#Preview("Hub") {
    AddProjectPlayground(variant: "Hub")
}

#Preview("Hub2") {
    AddProjectPlayground(variant: "Hub2", scenario: .readyToRun, step: .bounds)
}

#Preview("Hub3") {
    AddProjectPlayground(variant: "Hub3", scenario: .readyToRun, step: .project)
}

#Preview("Hub3 — Fresh") {
    AddProjectPlayground(variant: "Hub3", scenario: .fresh)
}

#Preview("Hub4") {
    AddProjectPlayground(variant: "Hub4", scenario: .fresh)
}

#Preview("Hub4 — Linear project") {
    @Previewable @State var draft: AddProjectDraft = {
        var draft = AddProjectDraft()
        draft.setName("Acme")
        return draft
    }()
    AddProjectStage(size: CGSize(width: 900, height: 620)) {
        SplitHubWizard(draft: $draft, components: hub4Components, opensOnLinear: true)
    }
    .frame(width: 1_040, height: 760)
}

#Preview("Focused Hub") {
    AddProjectPlayground(variant: "Focused Hub", scenario: .fresh)
}

#Preview("Focus Pages") {
    AddProjectPlayground(variant: "Focus Pages", scenario: .fresh)
}

#Preview("Name First") {
    AddProjectPlayground(variant: "Name First", scenario: .reusedID)
}

#Preview("Overview and Edit") {
    AddProjectPlayground(variant: "Overview and Edit", scenario: .specClash)
}

#Preview("Hub — Spec Source") {
    AddProjectPlayground(variant: "Hub", scenario: .specClash)
}

#Preview("Hub — Bounds") {
    AddProjectPlayground(variant: "Hub", scenario: .readyToRun, step: .bounds)
}

#Preview("Focused Hub — Spec Source") {
    AddProjectPlayground(variant: "Focused Hub", scenario: .specClash)
}

#Preview("Focused Hub — Bounds") {
    AddProjectPlayground(variant: "Focused Hub", scenario: .readyToRun, step: .bounds)
}

#Preview("Hub — Project") {
    AddProjectPlayground(variant: "Hub", scenario: .readyToRun, step: .project)
}

// Round one, shelved.

#Preview("Wireframe") {
    AddProjectPlayground(variant: "Wireframe")
}

#Preview("Assistant") {
    AddProjectPlayground(variant: "Assistant")
}

#Preview("Top Stepper") {
    AddProjectPlayground(variant: "Top Stepper")
}

#Preview("Focus") {
    AddProjectPlayground(variant: "Focus", scenario: .fresh)
}

#Preview("Accordion") {
    AddProjectPlayground(variant: "Accordion", scenario: .specClash)
}

#Preview("Live Preview") {
    AddProjectPlayground(variant: "Live Preview")
}

#Preview("Checklist") {
    AddProjectPlayground(variant: "Checklist")
}
#endif
