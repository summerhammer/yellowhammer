#if DEBUG
import Domain
import Pulse
import SwiftUI

// The Inspector renders one selection's detail read-only. Every selection is first turned into an
// `PulseInspectorModel` — facts, related items and the one way out to Linear or GitHub — and each
// style only lays that model out. Re-ready, answer and settle are never performed here: the primary
// button opens the Linear issue that carries the gesture.

enum PulseInspectorStyle: String, CaseIterable {
    /// A grouped `Form` of `LabeledContent`, like a Finder Get Info window.
    case form
    /// A tinted icon header, a facts grid and related lists, the way out pinned at the bottom.
    case header
    /// Dense key/value rows and link-style related items, for a narrow Inspector.
    case compact
    /// The header style's large header and pinned prominent way out around the form's grouped sections.
    case headerForm
}

/// One selection's detail, whatever it is.
struct PulseInspectorModel {
    struct Item: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        let systemImage: String
        let tint: Color
        let action: Action
    }

    struct Related: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    enum Action {
        case inspect(PulseSelection)
        case open(PulseDestination)
    }

    let kind: String
    let systemImage: String
    let tint: Color
    var identifier: String?
    let title: String
    var badges: [(text: String, color: Color)] = []
    var progress: (done: Int, total: Int)?
    var facts: [(label: String, value: String)] = []
    var related: [Related] = []
    var primary: (title: String, destination: PulseDestination)?
    var note: String?
}

struct PulseInspectorView: View {
    let context: PulseContext
    let selection: PulseSelection?
    let style: PulseInspectorStyle
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        if let model = selection.flatMap(model(for:)) {
            switch style {
            case .form: PulseFormInspector(model: model, actions: context.actions)
            case .header: PulseHeaderInspector(model: model, actions: context.actions)
            case .compact: PulseCompactInspector(model: model, actions: context.actions)
            case .headerForm: PulseHeaderFormInspector(model: model, actions: context.actions)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: "sidebar.trailing")
            } description: {
                Text("Select a Card, the Feature, an Attempt or a Repo to see its detail here.")
            }
        }
    }

    // MARK: Models

    private func model(for selection: PulseSelection) -> PulseInspectorModel? {
        let pulse = context.pulse
        switch selection {
        case let .card(id):
            return pulse.needsYou.cards.first { $0.id == id }.map(cardModel)
        case let .feature(id):
            return pulse.feature.flatMap { $0.id == id ? featureModel($0) : nil }
        case let .attempt(id):
            return pulse.now.attempts.first { $0.id == id }.map(attemptModel)
        case let .repo(repo):
            return context.project.repos.contains(repo) ? repoModel(repo) : nil
        }
    }

    private func cardModel(_ card: DecisionCard) -> PulseInspectorModel {
        let color = palette.color(for: card.state)
        let lane = context.project.laneState(for: card.repo)
        var badges = [(text: card.state.rawValue, color: color)]
        if let reason = card.blockReason { badges.append((reason.rawValue, palette.blocked)) }
        let siblings = context.pulse.needsYou.cards.filter { $0.repo == card.repo && $0.id != card.id }
        var related = [
            PulseInspectorModel.Related(title: "Repo", items: [repoItem(card.repo)])
        ]
        if !siblings.isEmpty {
            related.append(.init(title: "Also needs you in \(card.repo)", items: siblings.map(cardItem)))
        }
        return PulseInspectorModel(
            kind: "Card",
            systemImage: card.state == .blocked ? "exclamationmark.octagon.fill" : "questionmark.bubble.fill",
            tint: color,
            identifier: card.id,
            title: card.title,
            badges: badges,
            facts: [
                ("State", card.state.rawValue),
                ("Block Reason", card.blockReason?.rawValue ?? "—"),
                ("Repo", card.repo),
                ("Repo Lane", lane?.rawValue ?? "not in lane")
            ],
            related: related,
            primary: ("Open \(card.id) in Linear", .linearIssue(card.id)),
            note: card.state == .blocked
                ? "Re-ready happens in Linear, not here."
                : "Answer it in Linear, not here."
        )
    }

    private func featureModel(_ feature: FeatureInFlight) -> PulseInspectorModel {
        let progress = PulseFormat.cardProgress(feature)
        let pullRequests = feature.lanes.compactMap { lane in lane.pullRequest.map { (lane.repo, $0) } }
        var related = [
            PulseInspectorModel.Related(title: "Repo Lanes", items: feature.lanes.map { lane in
                PulseInspectorModel.Item(
                    id: lane.repo,
                    title: lane.repo,
                    subtitle: "\(lane.cardsDone)/\(lane.cardsTotal) Cards · \(lane.state.rawValue)",
                    systemImage: "shippingbox",
                    tint: palette.color(for: lane.state),
                    action: .inspect(.repo(lane.repo))
                )
            })
        ]
        if !pullRequests.isEmpty {
            related.append(.init(title: "Pull requests", items: pullRequests.map { repo, chip in
                pullRequestItem(repo: repo, chip: chip)
            }))
        }
        return PulseInspectorModel(
            kind: "Feature",
            systemImage: "flag.fill",
            tint: palette.color(for: feature.rollupState),
            identifier: feature.id,
            title: feature.title ?? feature.id,
            badges: [
                feature.state.map { ($0, Color.secondary) },
                feature.rollupState.map { ($0.rawValue, palette.color(for: $0)) }
            ].compactMap { $0 },
            progress: feature.lanes.isEmpty ? nil : progress,
            facts: [
                ("Linear state", feature.state ?? "—"),
                ("Roll-up", feature.rollupState?.rawValue ?? "—"),
                ("Repo Lanes", feature.lanes.isEmpty ? "none yet" : "\(feature.lanes.count)"),
                ("Cards done", feature.lanes.isEmpty ? "—" : "\(progress.done) of \(progress.total)"),
                ("Pull requests", pullRequests.isEmpty ? "none yet" : "\(pullRequests.count)")
            ],
            related: related,
            primary: ("Open \(feature.id) in Linear", .linearIssue(feature.id)),
            note: "Settle and merge happen in Linear and GitHub, not here."
        )
    }

    private func attemptModel(_ attempt: RunningAttempt) -> PulseInspectorModel {
        var facts: [(label: String, value: String)] = [("Repo", attempt.repo)]
        if let route = PulseFormat.routeParts(attempt.route) {
            facts += route
        } else {
            facts.append(("Route", attempt.route))
        }
        facts += [
            ("Round", "\(attempt.round)"),
            ("Started", PulseFormat.time(attempt.startedAt)),
            ("Elapsed", PulseFormat.elapsed(since: attempt.startedAt, asOf: context.asOf)),
            ("Status", attempt.status ?? "—")
        ]
        return PulseInspectorModel(
            kind: "Attempt",
            systemImage: "gearshape.2.fill",
            tint: palette.working,
            identifier: attempt.cardID,
            title: attempt.cardTitle,
            badges: [("running", palette.working), ("Round \(attempt.round)", .secondary)],
            facts: facts,
            related: [
                .init(title: "Card", items: [
                    .init(
                        id: attempt.cardID, title: attempt.cardID, subtitle: attempt.cardTitle,
                        systemImage: "arrow.up.forward.square", tint: .secondary,
                        action: .open(.linearIssue(attempt.cardID))
                    )
                ]),
                .init(title: "Repo", items: [repoItem(attempt.repo)])
            ],
            primary: ("Open \(attempt.cardID) in Linear", .linearIssue(attempt.cardID)),
            note: "One line of status, never agent output. "
                + "A review asking for changes starts a new Round, not a new Attempt."
        )
    }

    private func repoModel(_ repo: String) -> PulseInspectorModel {
        let lane = context.pulse.feature?.lanes.first { $0.repo == repo }
        let attempt = context.project.runningAttempt(for: repo)
        let cards = context.pulse.needsYou.cards.filter { $0.repo == repo }
        var related: [PulseInspectorModel.Related] = []
        if let attempt {
            related.append(.init(title: "Running Attempt", items: [
                .init(
                    id: attempt.id, title: "\(attempt.cardID) · Round \(attempt.round)", subtitle: attempt.status,
                    systemImage: "gearshape.2", tint: palette.working, action: .inspect(.attempt(attempt.id))
                )
            ]))
        }
        if !cards.isEmpty {
            related.append(.init(title: "Needs you", items: cards.map(cardItem)))
        }
        if let chip = lane?.pullRequest {
            related.append(.init(title: "Pull request", items: [pullRequestItem(repo: repo, chip: chip)]))
        }
        return PulseInspectorModel(
            kind: "Repo",
            systemImage: "shippingbox.fill",
            tint: lane.map { palette.color(for: $0.state) } ?? .secondary,
            title: repo,
            badges: [(lane?.state.rawValue ?? "not in lane", lane.map { palette.color(for: $0.state) } ?? .secondary)],
            progress: lane.map { ($0.cardsDone, $0.cardsTotal) },
            facts: [
                ("Repo Lane", lane?.state.rawValue ?? "not in lane"),
                ("Cards done", lane.map { "\($0.cardsDone) of \($0.cardsTotal)" } ?? "—"),
                (
                    "Pull request",
                    lane?.pullRequest.map { "#\($0.number)" + ($0.state.map { " \($0.rawValue)" } ?? "") } ?? "none yet"
                ),
                ("Attempt", attempt?.route ?? "none running"),
                ("Needs you", cards.isEmpty ? "nothing" : "\(cards.count)")
            ],
            related: related,
            primary: lane?.pullRequest.map { chip in
                ("Open #\(chip.number) on GitHub", .pullRequest(repo: repo, number: chip.number))
            }
        )
    }

    private func repoItem(_ repo: String) -> PulseInspectorModel.Item {
        let lane = context.project.laneState(for: repo)
        return .init(
            id: repo, title: repo, subtitle: lane?.rawValue ?? "not in lane", systemImage: "shippingbox",
            tint: lane.map { palette.color(for: $0) } ?? .secondary, action: .inspect(.repo(repo))
        )
    }

    private func cardItem(_ card: DecisionCard) -> PulseInspectorModel.Item {
        .init(
            id: card.id, title: "\(card.id)  \(card.title)",
            subtitle: card.blockReason?.rawValue ?? card.state.rawValue,
            systemImage: card.state == .blocked ? "exclamationmark.octagon" : "questionmark.bubble",
            tint: palette.color(for: card.state), action: .inspect(.card(card.id))
        )
    }

    private func pullRequestItem(repo: String, chip: PullRequestChip) -> PulseInspectorModel.Item {
        .init(
            id: "\(repo)#\(chip.number)", title: "\(repo) #\(chip.number)",
            subtitle: chip.state?.rawValue ?? "state unknown",
            systemImage: "arrow.triangle.pull", tint: palette.color(for: chip.state),
            action: .open(.pullRequest(repo: repo, number: chip.number))
        )
    }
}

extension PulseActions {
    @MainActor
    func perform(_ action: PulseInspectorModel.Action) {
        switch action {
        case let .inspect(selection): inspect(selection)
        case let .open(destination): open(destination)
        }
    }
}
#endif
