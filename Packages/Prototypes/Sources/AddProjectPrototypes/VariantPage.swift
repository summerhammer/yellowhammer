#if DEBUG
import Foundation

/// The six pages, as in Hub4, with the Linear project page renamed to Board.
enum VariantPage: CaseIterable, Identifiable {
    case identity
    case board
    case repos
    case specSource
    case bounds
    case jobs

    var id: Self { self }

    var step: WizardStep {
        switch self {
        case .identity, .board: .project
        case .repos: .repos
        case .specSource: .specSource
        case .bounds: .bounds
        case .jobs: .jobs
        }
    }

    /// Bounds and Schedule: their defaults work, so the Operator may never open them.
    var isOptional: Bool { self == .bounds || self == .jobs }

    static func first(showing step: WizardStep) -> Self {
        allCases.first { $0.step == step } ?? .identity
    }

    var next: Self? {
        let pages = Self.allCases
        guard let index = pages.firstIndex(of: self), index + 1 < pages.count else { return nil }
        return pages[index + 1]
    }

    var previous: Self? {
        let pages = Self.allCases
        guard let index = pages.firstIndex(of: self), index > 0 else { return nil }
        return pages[index - 1]
    }

    var title: String {
        switch self {
        case .identity: "Project"
        case .board: "Board"
        default: step.shortTitle
        }
    }

    var heading: String {
        switch self {
        case .identity: "Project"
        case .board: "Board"
        default: step.title
        }
    }

    var explanation: String {
        switch self {
        case .identity: "Name the Project. Its id is made from the name and is permanent."
        case .board:
            "Where this Project\u{2019}s Features are planned, and in which Linear workspace."
        default: step.explanation
        }
    }
}

extension AddProjectDraft {
    func problems(onPage page: VariantPage) -> [String] {
        switch page {
        case .identity: identityProblems
        case .board: boardProblems
        default: problems(in: page.step)
        }
    }

    func isPageComplete(_ page: VariantPage) -> Bool { problems(onPage: page).isEmpty }

    func summary(ofPage page: VariantPage) -> String {
        switch page {
        case .identity: identitySummary
        case .board: boardSummary
        default: summary(of: page.step)
        }
    }

    /// Whether the Operator moved an optional page off its defaults.
    func isChanged(_ page: VariantPage) -> Bool {
        let defaults = AddProjectDraft()
        return switch page {
        case .bounds: bounds != defaults.bounds
        case .jobs:
            jobs != defaults.jobs || nightStart != defaults.nightStart || nightEnd != defaults.nightEnd
                || buildEveryMinutes != defaults.buildEveryMinutes
        default: false
        }
    }

    /// "Acme", or a placeholder before the Project is named.
    var contextTitle: String { displayName.isEmpty ? "Untitled Project" : displayName }

    /// The sidebar's trailing mark: problems once revealed; a tick for a complete required page; and
    /// for an optional page, whatever the design puts in place of Hub4's tick.
    func sidebarMark(
        for page: VariantPage, design: HubDesign, opened: Set<VariantPage>, revealed: Set<VariantPage>
    ) -> VariantSidebarRow.Mark {
        let problems = problems(onPage: page)
        if !problems.isEmpty { return revealed.contains(page) ? .problems(problems.count) : .none }
        guard page.isOptional else { return .done }
        switch design.optionalMark {
        case .tick: return .done
        case .optionalTag: return isChanged(page) ? .done : .tag("Optional")
        case .tickOnceReviewed: return opened.contains(page) ? .done : .none
        case .optionalSection: return isChanged(page) ? .tag("Changed") : .none
        case .defaultOrChanged: return .tag(isChanged(page) ? "Changed" : "Default")
        }
    }
}
#endif
