#if DEBUG
import SwiftUI

// Hub, refined after round two. Hub2 keeps Hub's layout and swaps in the picked components — the id
// as a Permanent token confirmed when the Project is added, the Linear project as one list, the spec
// source as option cards, Bounds as sentences. Hub3 is Hub2 with the first step split in two, so the
// name and id, and the Linear project, each get a step of their own. Hub4 is Hub3 with the Linear
// project drawn as Hub draws it: two option cards over the matching list.

/// The components Hub2 and Hub3 share.
let hubComponents = WizardComponents(
    identity: .lockedToken, linear: .unifiedList, spec: .optionCards, bounds: .sentences
)

/// Hub4's: Hub3's, with the Linear project as option cards.
let hub4Components = WizardComponents(
    identity: .lockedToken, linear: .choiceCards, spec: .optionCards, bounds: .sentences
)

extension View {
    /// Asks before adding, because adding is the moment the id becomes permanent.
    func addProjectConfirmation(isPresented: Binding<Bool>, draft: Binding<AddProjectDraft>) -> some View {
        let value = draft.wrappedValue
        return alert(
            "Add \u{201c}\(value.displayName)\u{201d} with the id \u{201c}\(value.projectID)\u{201d}?",
            isPresented: isPresented
        ) {
            Button("Add Project") { draft.wrappedValue.runSetup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The id names the Project file, its Journal and its three LaunchAgents. "
                + "It can\u{2019}t be changed after the Project is added.")
        }
    }
}

// MARK: - Hub2

struct Hub2Wizard: View {
    @Binding var draft: AddProjectDraft
    @State private var confirmsAdding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HubSidebarHeader(ready: draft.readyCount, total: WizardStep.allCases.count)
                    WizardStepSidebar(draft: $draft)
                }
                .frame(width: 240)
                .background(WizardTheme.surface)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if draft.run == .notStarted {
                        StepHeading(step: draft.step).padding([.horizontal, .top], 20)
                        WizardStepBody(step: draft.step, draft: $draft, components: hubComponents)
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            WizardHubFooter(draft: $draft) { confirmsAdding = true }
        }
        .addProjectConfirmation(isPresented: $confirmsAdding, draft: $draft)
    }
}

private struct HubSidebarHeader: View {
    let ready: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add Project").font(.title3.weight(.semibold))
            Text("\(ready) of \(total) ready")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Hub3

/// Hub3's six steps: the wizard's five, with the first split into the name and id, and the Linear
/// project. Both halves are still `WizardStep.project` in the draft.
private enum HubPage: CaseIterable, Identifiable {
    case identity
    case linear
    case repos
    case specSource
    case bounds
    case jobs

    var id: Self { self }

    var step: WizardStep {
        switch self {
        case .identity, .linear: .project
        case .repos: .repos
        case .specSource: .specSource
        case .bounds: .bounds
        case .jobs: .jobs
        }
    }

    static func first(showing step: WizardStep) -> Self {
        allCases.first { $0.step == step } ?? .identity
    }

    var title: String {
        switch self {
        case .identity: "Project"
        case .linear: "Linear project" // glossary:ignore GL001
        default: step.shortTitle
        }
    }

    var heading: String {
        switch self {
        case .identity: "Project"
        case .linear: "Linear project" // glossary:ignore GL001
        default: step.title
        }
    }

    var explanation: String {
        switch self {
        case .identity: "Name the Project. Its id is made from the name and is permanent."
        case .linear: "Where this Project\u{2019}s Features come from."
        default: step.explanation
        }
    }
}

private extension AddProjectDraft {
    func problems(in page: HubPage) -> [String] {
        switch page {
        case .identity: identityProblems
        case .linear: linearProblems
        default: problems(in: page.step)
        }
    }

    func summary(of page: HubPage) -> String {
        switch page {
        case .identity: identitySummary
        // On its own row the summary starts the line, so it is capitalised.
        case .linear: linearSummary.prefix(1).uppercased() + linearSummary.dropFirst()
        default: summary(of: page.step)
        }
    }

    func isComplete(_ page: HubPage) -> Bool { problems(in: page).isEmpty }
}

/// Hub3 and Hub4: the split first step, with the components a variant picks.
struct SplitHubWizard: View {
    @Binding var draft: AddProjectDraft
    let components: WizardComponents
    @State private var page: HubPage
    @State private var visitedLinear = false
    @State private var confirmsAdding = false

    /// `opensOnLinear` lets a preview start on the Linear project step, which the draft alone cannot
    /// name: both halves of the first step are `WizardStep.project`.
    init(draft: Binding<AddProjectDraft>, components: WizardComponents, opensOnLinear: Bool = false) {
        _draft = draft
        self.components = components
        let first = HubPage.first(showing: draft.wrappedValue.step)
        _page = State(initialValue: opensOnLinear && first == .identity ? .linear : first)
        _visitedLinear = State(initialValue: opensOnLinear)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HubSidebarHeader(
                        ready: HubPage.allCases.count(where: draft.isComplete), total: HubPage.allCases.count
                    )
                    sidebar
                }
                .frame(width: 240)
                .background(WizardTheme.surface)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if draft.run == .notStarted {
                        heading.padding([.horizontal, .top], 20)
                        content
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            WizardHubFooter(draft: $draft, stillNeeded: stillNeeded) { confirmsAdding = true }
        }
        .addProjectConfirmation(isPresented: $confirmsAdding, draft: $draft)
        // The Playground's step picker moves the draft; follow it.
        .onChange(of: draft.step) { _, step in
            if page.step != step { page = HubPage.first(showing: step) }
        }
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(HubPage.allCases) { page in
                WizardSidebarRow(
                    title: page.title,
                    summary: draft.summary(of: page),
                    status: status(of: page),
                    problemCount: draft.problems(in: page).count
                )
                .tag(page)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .disabled(draft.run != .notStarted)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.heading).font(.title2.weight(.semibold))
            Text(page.explanation).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .identity:
            WizardColumn { IdentityBlock(draft: $draft, style: components.identity) }
        case .linear:
            WizardColumn { LinearBlock(draft: $draft, style: components.linear, showsTitle: false) }
        default:
            WizardStepBody(step: page.step, draft: $draft, components: components)
        }
    }

    /// Done when complete; a problem once visited; untouched otherwise.
    private func status(of page: HubPage) -> WizardStepStatus {
        if draft.isComplete(page) { return .done }
        let visited = switch page {
        case .identity: true
        case .linear: visitedLinear || draft.reached > .project
        default: draft.visited.contains(page.step)
        }
        return visited ? .problem : .upcoming
    }

    private var stillNeeded: String? {
        let missing = HubPage.allCases.filter { !draft.isComplete($0) }
        guard !missing.isEmpty else { return nil }
        return "Still needed: " + missing.map(\.title).formatted(.list(type: .and))
    }

    private var selection: Binding<HubPage?> {
        Binding {
            page
        } set: { newPage in
            guard let newPage else { return }
            if newPage == .linear { visitedLinear = true }
            page = newPage
            draft.go(to: newPage.step, allowingAhead: true)
        }
    }
}
#endif
