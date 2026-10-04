#if DEBUG
import SwiftUI

// Round three of the Add Project sheet: Hub4 with six of its problems solved in different ways. Each
// problem is one axis of `HubDesign`, and each variant picks one answer per axis, so a variant is a
// combination rather than a fork of the sheet. `VariantHubWizard` draws any design; Hub4 itself,
// `SplitHubWizard`, stays untouched as the baseline.
//
// 1. `OptionalStepMark` — Bounds and Schedule are not ticked before the Operator has looked at them.
// 2. `AdvanceStyle` — one button moves to the next step once the current one is complete.
// 3. `ProblemPlacement` — every page reports its problems the same way, revealed by the same rule.
// 4. `repoSymbol` — a Repo no longer wears the folder the Overview uses for a whole Project.
// 5. `ProjectContext` — the Project being added stays named on every page.
// 6. `BoardLayout` — the first choice is a board, Linear or (later) Jira, then existing or new.

/// How the optional pages, Bounds and Schedule, are marked in the step list.
enum OptionalStepMark {
    /// Hub4: ticked as soon as complete, so the defaults are ticked from the start.
    case tick
    /// An "Optional" tag until changed; ticked once the Operator changes something.
    case optionalTag
    /// Ticked only once the Operator has opened the page.
    case tickOnceReviewed
    /// The optional pages in a sidebar section of their own, never ticked.
    case optionalSection
    /// "Default" or "Changed" where the tick would be.
    case defaultOrChanged
}

/// How the Operator moves on from a complete page.
enum AdvanceStyle {
    /// Hub4: only the sidebar.
    case sidebarOnly
    /// The footer's default button is "Continue to <next>" until every page is ready.
    case footerContinue
    /// A "Next: <page>" card at the end of a complete page.
    case inlineNext
    /// Back and Next in the footer; Next becomes Add Project on the last page.
    case backAndNext
    /// One button to the next page that still needs something, skipping pages already ready.
    case nextNeeded
}

/// Where a page's problems are drawn. Every page uses the same placement, and every page reveals its
/// problems by the same rule: once the Operator has left it.
enum ProblemPlacement {
    /// A boxed "To finish this page" list after the page's content.
    case belowContent
    /// A banner under the page heading.
    case banner
    /// A caption beside the part that is wrong: the empty Repo list, a Repo card, the board list.
    case nearField
}

/// Where the sheet keeps the Project being added in view.
enum ProjectContext {
    case none
    /// The sidebar header names the Project and its id instead of "Add Project".
    case sidebarHeader
    /// A title bar across the sheet: "Add Project — Acme".
    case titleBar
    /// A breadcrumb over each page heading: "Acme › Repos".
    case breadcrumb
    /// A chip beside Cancel in the footer.
    case footerChip
}

/// How the board page offers its four choices: Linear or Jira, an existing project or a new one.
enum BoardLayout {
    /// The four choices as a two-by-two grid of option cards, Jira's marked Coming later.
    case fourCards
    /// A board switch (Linear, Jira) over Hub4's existing-or-new cards.
    case vendorSwitch
    /// A card per board, then existing-or-new as a segmented control.
    case vendorCards
    /// One boxed list per board, each with its existing and new options.
    case groupedList
}

struct HubDesign {
    var optionalMark: OptionalStepMark
    var advance: AdvanceStyle
    var problems: ProblemPlacement
    /// The SF Symbol on a Repo card, or nil for none.
    var repoSymbol: String?
    var context: ProjectContext
    var board: BoardLayout
}

/// One prototype of the sheet. A nil design is Hub4 itself.
struct AddProjectVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line.
    let idea: String
    let design: HubDesign?

    var id: String { name }

    static let all: [AddProjectVariant] = [
        AddProjectVariant(name: "Hub4", idea: "The baseline: the chosen layout as it is today", design: nil),
        AddProjectVariant(
            name: "A · Continue",
            idea: "Footer Continue; Optional tags; problems below the page; Project in the sidebar header",
            design: HubDesign(
                optionalMark: .optionalTag, advance: .footerContinue, problems: .belowContent,
                repoSymbol: "shippingbox", context: .sidebarHeader, board: .fourCards
            )
        ),
        AddProjectVariant(
            name: "B · Next card",
            idea: "A Next card ends each page; optional section; banners; breadcrumb",
            design: HubDesign(
                optionalMark: .optionalSection, advance: .inlineNext, problems: .banner,
                repoSymbol: "arrow.triangle.branch", context: .breadcrumb, board: .vendorSwitch
            )
        ),
        AddProjectVariant(
            name: "C · Back and Next",
            idea: "Classic Back/Next footer; tick once reviewed; problems beside the field; title bar",
            design: HubDesign(
                optionalMark: .tickOnceReviewed, advance: .backAndNext, problems: .nearField,
                repoSymbol: "chevron.left.forwardslash.chevron.right", context: .titleBar, board: .groupedList
            )
        ),
        AddProjectVariant(
            name: "D · Next needed",
            idea: "One button to whatever still needs you; Default/Changed marks; footer chip",
            design: HubDesign(
                optionalMark: .defaultOrChanged, advance: .nextNeeded, problems: .belowContent,
                repoSymbol: "cube", context: .footerChip, board: .vendorCards
            )
        ),
        AddProjectVariant(
            name: "E · Quiet",
            idea: "Optional section; footer Continue; problems beside the field; no Repo icon",
            design: HubDesign(
                optionalMark: .optionalSection, advance: .footerContinue, problems: .nearField,
                repoSymbol: nil, context: .sidebarHeader, board: .vendorCards
            )
        ),
        AddProjectVariant(
            name: "F · Banner",
            idea: "Back/Next; Optional tags; banners; title bar; four board cards",
            design: HubDesign(
                optionalMark: .optionalTag, advance: .backAndNext, problems: .banner,
                repoSymbol: "point.3.connected.trianglepath.dotted", context: .titleBar, board: .fourCards
            )
        ),
        AddProjectVariant(
            name: "G · Guided",
            idea: "Next card; tick once reviewed; problems below; breadcrumb; board lists",
            design: HubDesign(
                optionalMark: .tickOnceReviewed, advance: .inlineNext, problems: .belowContent,
                repoSymbol: "externaldrive", context: .breadcrumb, board: .groupedList
            )
        )
    ]

    static func named(_ name: String) -> AddProjectVariant? { all.first { $0.name == name } }
}
#endif
