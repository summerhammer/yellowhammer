#if DEBUG
import SwiftUI

// Hub4, the layout chosen for the app's Add Project sheet and kept here as its reference; the app's
// version is in `Yellowhammer/Features/AddProject`. A step list beside the step, a footer that says
// what is still needed, and six pages: the first step split in two, so the name and id, and the Linear
// project, each get a page of their own. The id is a Permanent token confirmed when the Project is
// added, the Linear project is two option cards over the matching list, the spec source is option
// cards, and Bounds are sentences.

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

// MARK: - Hub4

/// Hub4's six pages: the wizard's five steps, with the first split into the name and id, and the Linear
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

/// Hub4: the step list, the page, and the footer.
struct SplitHubWizard: View {
    @Binding var draft: AddProjectDraft
    @State private var page: HubPage
    @State private var visitedLinear = false
    @State private var confirmsAdding = false

    /// `opensOnLinear` lets a preview start on the Linear project step, which the draft alone cannot
    /// name: both halves of the first step are `WizardStep.project`.
    init(draft: Binding<AddProjectDraft>, opensOnLinear: Bool = false) {
        _draft = draft
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
            WizardColumn { IdentityBlock(draft: $draft) }
        case .linear:
            WizardColumn { LinearBlock(draft: $draft) }
        case .repos:
            RepoStepView(draft: $draft)
        case .specSource:
            WizardColumn { SpecBlock(draft: $draft) }
        case .bounds:
            WizardColumn { BoundsBlock(draft: $draft) }
        case .jobs:
            Form { JobsSections(draft: $draft) }.formStyle(.grouped)
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
