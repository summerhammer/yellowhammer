#if DEBUG
import Domain
import Pulse
import SwiftUI

/// One combination of the interchangeable styles. A variant in `PulseVariant.all` is a name, an idea
/// and one of these.
struct PulseDesign {
    var sections: PulseSectionStyle
    var sidebar: PulseSidebarRows = .sourceList
    /// The Sidebar floats over the Pulse as a Liquid Glass panel instead of being a split-view column.
    var floatingGlassSidebar = false
    var toolbar: PulseToolbarStyle = .minimal
    var inspector: PulseInspectorStyle = .form
    /// What the Inspector shows when the variant first appears, so its detail can be judged filled.
    var opens: PulseOpening = .firstDecisionCard
}

/// The Inspector's first selection. Each falls back along the Pulse, so the Inspector is filled
/// whenever the Project has anything to inspect.
enum PulseOpening {
    case nothing
    case firstDecisionCard
    case feature
    case attempt
    case repo

    func selection(in project: ProjectSnapshot) -> PulseSelection? {
        let pulse = project.pulse
        let card = pulse.needsYou.cards.first.map { PulseSelection.card($0.id) }
        let feature = pulse.feature.map { PulseSelection.feature($0.id) }
        let attempt = pulse.now.attempts.first.map { PulseSelection.attempt($0.id) }
        let repo = (pulse.feature?.lanes.first?.repo ?? project.repos.first).map(PulseSelection.repo)
        return switch self {
        case .nothing: nil
        case .firstDecisionCard: card ?? feature ?? attempt ?? repo
        case .feature: feature ?? card ?? repo
        case .attempt: attempt ?? card ?? feature ?? repo
        case .repo: repo
        }
    }
}

/// A landing screen assembled from a `PulseDesign`.
struct PulseComposedVariant: View {
    let snapshot: LandingSnapshot
    @Binding var selection: ProjectID?
    let design: PulseDesign

    @State private var inspected: PulseSelection?
    @State private var inspectorShown = true
    @State private var glassSidebarShown = true
    @State private var query = ""
    @State private var didOpen = false
    @Environment(\.openPulseDestination) private var openDestination
    @Environment(\.pulsePrototypeAction) private var prototypeAction
    @Environment(\.pulsePalette) private var palette

    private static let glassSidebarWidth: CGFloat = 260

    var body: some View {
        Group {
            if design.floatingGlassSidebar { glassLayout } else { splitLayout }
        }
        .tint(palette.accent)
        .onAppear {
            guard !didOpen, let project else { return }
            didOpen = true
            inspected = design.opens.selection(in: project)
        }
        .onChange(of: selection) {
            guard let project, !Self.resolves(inspected, in: project) else { return }
            inspected = design.opens.selection(in: project)
        }
    }

    // MARK: Layouts

    private var splitLayout: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .inspector(isPresented: $inspectorShown) { inspectorPane }
    }

    /// The Pulse runs full width under a floating glass Sidebar. The scroll content is inset by the
    /// panel's width through the safe area, so backgrounds (the hero banner) extend under the glass
    /// while text stays clear of it.
    private var glassLayout: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                detail
                    .safeAreaPadding(.leading, glassSidebarShown ? Self.glassSidebarWidth + 16 : 0)
                if glassSidebarShown {
                    sidebar
                        .scrollContentBackground(.hidden)
                        .frame(width: Self.glassSidebarWidth)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .padding(8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.smooth) { glassSidebarShown.toggle() }
                    } label: {
                        Label("Sidebar", systemImage: "sidebar.leading")
                    }
                    .help(glassSidebarShown ? "Hide the Sidebar" : "Show the Sidebar")
                }
            }
        }
        .inspector(isPresented: $inspectorShown) { inspectorPane }
    }

    private var sidebar: some View {
        PulseSidebarList(snapshot: snapshot, selection: $selection, rows: design.sidebar, actions: actions)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let project {
                PulseSectionsView(
                    context: PulseContext(project: project, asOf: snapshot.asOf, actions: actions),
                    style: design.sections
                )
                .navigationTitle(project.name)
            } else {
                ContentUnavailableView("Select a Project", systemImage: "sidebar.left")
            }
        }
        .pulseToolbar(design.toolbar, toolbarModel)
        .modifier(PulseSearchable(isOn: design.toolbar == .search, query: $query))
        .toolbar(removing: design.toolbar == .titled ? nil : .title)
    }

    private var inspectorPane: some View {
        Group {
            if let project {
                PulseInspectorView(
                    context: PulseContext(project: project, asOf: snapshot.asOf, actions: actions),
                    selection: inspected,
                    style: design.inspector
                )
            } else {
                ContentUnavailableView("No Project", systemImage: "sidebar.trailing")
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }

    // MARK: State

    /// The selected Project, narrowed by the search field when the toolbar has one.
    private var project: ProjectSnapshot? {
        guard var project = snapshot.project(selection) else { return nil }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard design.toolbar == .search, !query.isEmpty else { return project }
        let matches = { (fields: [String]) in fields.contains { $0.localizedStandardContains(query) } }
        project.pulse.needsYou.cards = project.pulse.needsYou.cards.filter { matches([$0.id, $0.title, $0.repo]) }
        project.pulse.now.attempts = project.pulse.now.attempts.filter {
            matches([$0.cardID, $0.cardTitle, $0.repo, $0.route])
        }
        return project
    }

    /// The closures capture only the bindings and the destination handler they need, never the
    /// whole view.
    private var actions: PulseActions {
        let inspected = $inspected
        let inspectorShown = $inspectorShown
        let openDestination = openDestination
        return PulseActions(
            inspected: self.inspected,
            inspect: { selection in
                inspected.wrappedValue = selection
                withAnimation { inspectorShown.wrappedValue = true }
                openDestination(.inspector(selection))
            },
            open: { openDestination($0) }
        )
    }

    private var toolbarModel: PulseToolbarModel {
        PulseToolbarModel(
            project: project,
            asOf: snapshot.asOf,
            inspectorShown: $inspectorShown,
            actions: actions,
            prototypeAction: prototypeAction,
            palette: palette
        )
    }

    private static func resolves(_ selection: PulseSelection?, in project: ProjectSnapshot) -> Bool {
        switch selection {
        case nil: false
        case let .card(id): project.pulse.needsYou.cards.contains { $0.id == id }
        case let .feature(id): project.pulse.feature?.id == id
        case let .attempt(id): project.pulse.now.attempts.contains { $0.id == id }
        case let .repo(repo): project.repos.contains(repo)
        }
    }
}

/// Adds the toolbar filter field only for the search toolbar, so other variants carry none.
private struct PulseSearchable: ViewModifier {
    let isOn: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if isOn {
            content.searchable(text: $query, placement: .toolbar, prompt: "Filter Cards and Attempts")
        } else {
            content
        }
    }
}

#Preview("Dashboard") {
    PulsePlayground(variant: "Dashboard")
}

#Preview("Hero Banner") {
    PulsePlayground(variant: "Hero Banner")
}

#Preview("Glass over Hero") {
    PulsePlayground(variant: "Glass over Hero", scenario: .nightRunning)
}

#Preview("Mail List") {
    PulsePlayground(variant: "Mail List", scenario: .nightRunning)
}

#endif
