#if DEBUG
import SwiftUI

// Hub4's layout drawn from a `HubDesign`. The pages, blocks and draft are Hub4's; what changes is how
// optional pages are marked, how the Operator moves on, where problems show, the Repo symbol, where the
// Project stays named, and the board page.

struct VariantHubWizard: View {
    @Binding var draft: AddProjectDraft
    let design: HubDesign
    @State private var page: VariantPage
    /// Pages the Operator has opened.
    @State private var opened: Set<VariantPage>
    /// Pages the Operator has left: problems show on these only, in the sidebar and on the page alike.
    @State private var revealed: Set<VariantPage>
    @State private var confirmsAdding = false

    init(draft: Binding<AddProjectDraft>, design: HubDesign) {
        _draft = draft
        self.design = design
        let value = draft.wrappedValue
        let first = VariantPage.first(showing: value.step)
        _page = State(initialValue: first)
        _opened = State(initialValue: Set(VariantPage.allCases.filter {
            $0 == first || (value.visited.contains($0.step) && $0.step < value.reached)
        }))
        _revealed = State(initialValue: Set(VariantPage.allCases.filter { $0 != first && $0.step < value.reached }))
    }

    var body: some View {
        VStack(spacing: 0) {
            if design.context == .titleBar {
                ProjectTitleBar(draft: draft)
                Divider()
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VariantSidebarHeader(draft: draft, design: design)
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
            footer
        }
        .environment(\.wizardBlocksShowProblems, false)
        .addProjectConfirmation(isPresented: $confirmsAdding, draft: $draft)
        // The Playground's step picker moves the draft; follow it.
        .onChange(of: draft.step) { _, step in
            if page.step != step { open(VariantPage.first(showing: step)) }
        }
    }

    // MARK: Navigation

    private func open(_ target: VariantPage) {
        if target != page { revealed.insert(page) }
        opened.insert(target)
        page = target
        draft.go(to: target.step, allowingAhead: true)
    }

    private var selection: Binding<VariantPage?> {
        Binding { page } set: { if let newPage = $0 { open(newPage) } }
    }

    /// The next page that still needs something, after this one and then from the top.
    private var nextNeeded: VariantPage? {
        let pages = VariantPage.allCases
        guard let index = pages.firstIndex(of: page) else { return nil }
        return (pages[(index + 1)...] + pages[..<index]).first { !draft.isPageComplete($0) }
    }

    private var stillNeeded: String? {
        let missing = VariantPage.allCases.filter { !draft.isPageComplete($0) }
        guard !missing.isEmpty else { return nil }
        return "Still needed: " + missing.map(\.title).formatted(.list(type: .and))
    }

    private func revealedProblems(in page: VariantPage) -> [String] {
        revealed.contains(page) ? draft.problems(onPage: page) : []
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            if design.optionalMark == .optionalSection {
                Section("Required") { rows(VariantPage.allCases.filter { !$0.isOptional }) }
                Section("Optional \u{2014} defaults work") { rows(VariantPage.allCases.filter(\.isOptional)) }
            } else {
                rows(VariantPage.allCases)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .disabled(draft.run != .notStarted)
    }

    private func rows(_ pages: [VariantPage]) -> some View {
        ForEach(pages) { page in
            VariantSidebarRow(
                title: page.title,
                summary: draft.summary(ofPage: page),
                mark: draft.sidebarMark(for: page, design: design, opened: opened, revealed: revealed)
            )
                .tag(page)
        }
    }

    // MARK: Context

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            if design.context == .breadcrumb {
                Text("\(draft.contextTitle)  \u{203a}  \(page.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(page.heading).font(.title2.weight(.semibold))
                if page.isOptional, design.optionalMark != .tick {
                    Text("Optional").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(WizardTheme.surface, in: .capsule)
                }
            }
            Text(page.explanation).foregroundStyle(.secondary)
            if design.problems == .banner {
                let problems = revealedProblems(in: page)
                if !problems.isEmpty { ProblemBanner(problems: problems).padding(.top, 6) }
            }
        }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .identity:
            WizardColumn { IdentityBlock(draft: $draft); pageEnd }
        case .board:
            WizardColumn { VariantBoardBlock(draft: $draft, layout: design.board); pageEnd }
        case .repos:
            WizardColumn { repos; pageEnd }
        case .specSource:
            WizardColumn { SpecBlock(draft: $draft); pageEnd }
        case .bounds:
            WizardColumn { BoundsBlock(draft: $draft); pageEnd }
        case .jobs:
            Form {
                JobsSections(draft: $draft)
                Section { pageEnd }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private var repos: some View {
        let revealed = revealed.contains(.repos)
        if draft.repos.isEmpty {
            EmptyRepoList(showsProblem: revealed && design.problems == .nearField) { draft.addRepo() }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(draft.repos) { repo in
                    VStack(alignment: .leading, spacing: 4) {
                        RepoCard(draft: $draft, repo: $draft.repo(repo.id), symbol: design.repoSymbol)
                        let missing = draft.missingFields(of: repo)
                        if design.problems == .nearField, revealed, !missing.isEmpty {
                            FieldProblem(text: "Needs a \(missing.formatted(.list(type: .and))).")
                        }
                    }
                }
                Button("Add Repo\u{2026}", systemImage: "plus") { draft.addRepo() }
            }
        }
    }

    /// The end of every page: its problems, under the below-content and beside-the-field placements,
    /// then the Next card.
    @ViewBuilder private var pageEnd: some View {
        let problems = revealedProblems(in: page)
        switch design.problems {
        case .belowContent where !problems.isEmpty:
            ProblemBox(problems: problems)
        case .nearField where !problems.isEmpty:
            // The Repo page draws its own beside each card and the empty list.
            if page != .repos {
                VStack(alignment: .leading, spacing: 4) { ForEach(problems, id: \.self) { FieldProblem(text: $0) } }
            }
        default:
            EmptyView()
        }
        if design.advance == .inlineNext, let next = page.next, draft.isPageComplete(page) {
            NextCard(page: next, isDefault: !draft.isComplete) { open(next) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if draft.run == .notStarted {
                WizardCancelButton(caption: false)
                if design.context == .footerChip { ProjectChip(draft: draft) }
                Spacer()
                WizardReadiness(stillNeeded: stillNeeded)
                footerButtons
            } else {
                Spacer()
                WizardNavigationButtons(draft: $draft)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var footerButtons: some View {
        switch design.advance {
        case .sidebarOnly:
            addButton(isDefault: true)
        case .inlineNext:
            // The Next card is the way on; Add Project takes Return only once nothing is left.
            addButton(isDefault: draft.isComplete)
        case .footerContinue:
            if let next = page.next, !draft.isComplete {
                Button("Continue to \(next.title)") { open(next) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isPageComplete(page))
            } else {
                addButton(isDefault: true)
            }
        case .backAndNext:
            if let previous = page.previous {
                Button("Back") { open(previous) }
            }
            if let next = page.next {
                Button("Next") { open(next) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isPageComplete(page))
            } else {
                addButton(isDefault: true)
            }
        case .nextNeeded:
            if let target = nextNeeded, target != page {
                // Leaving an incomplete page is allowed; leaving reveals what it still needs.
                Button("Next: \(target.title)") { open(target) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                addButton(isDefault: true)
            }
        }
    }

    private func addButton(isDefault: Bool) -> some View {
        Button("Add Project") { confirmsAdding = true }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(isDefault ? .defaultAction : nil)
            .disabled(!draft.isComplete)
    }
}
#endif
