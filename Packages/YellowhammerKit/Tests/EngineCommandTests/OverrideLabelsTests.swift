import Domain
import Foundation
import Testing

@testable import Engine

// routing/resolve-a-route-for-a-card, Decision Gates Ruling G-17: the Override is three mutually
// exclusive label groups whose children are the merged Routing Table's values, and a Card's Override
// is read off its labels by name.

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private let table = RoutingTable(entries: [
    RoutingEntry(route: route("claude", "sonnet", "medium"), fallbacks: [route("codex", "gpt-5.4", "medium")]),
    RoutingEntry(
        kind: Kind("impl")!, route: route("claude", "opus", "high"), fallbacks: [route("gemini", "flash", "low")]
    ),
    RoutingEntry(kind: Kind("review")!, route: route("codex", "gpt-5.4", "high"))
])

private func label(_ id: String, _ name: String, isGroup: Bool = false, parent: String? = nil) -> BoardLabel {
    BoardLabel(
        id: BoardObjectID(rawValue: id), name: name, isGroup: isGroup,
        parent: parent.map(BoardObjectID.init(rawValue:)), team: BoardObjectID(rawValue: "team-1")
    )
}

/// The three groups as setup provisions them from `table`.
private let provisioned: [BoardLabel] = [
    label("g-cli", "Override CLI", isGroup: true),
    label("cli-claude", "claude", parent: "g-cli"),
    label("cli-codex", "codex", parent: "g-cli"),
    label("cli-gemini", "gemini", parent: "g-cli"),
    label("g-model", "Override Model", isGroup: true),
    label("model-sonnet", "sonnet", parent: "g-model"),
    label("model-opus", "opus", parent: "g-model"),
    label("g-effort", "Override Effort", isGroup: true),
    label("effort-high", "high", parent: "g-effort"),
    label("effort-medium", "medium", parent: "g-effort"),
    // Another group's child with a name that could be mistaken for a pin.
    label("g-status", "Status", isGroup: true),
    label("status-high", "high priority", parent: "g-status"),
    label("plain-codex", "codex-tips")
]

private func object(labels: [String]) -> BoardObject {
    BoardObject(
        id: BoardObjectID(rawValue: "issue-1"), key: "ENG-1", title: "A Card", description: nil,
        workflowState: BoardWorkflowState(id: BoardObjectID(rawValue: "state-1"), name: "Todo"),
        labels: labels, parent: nil, url: "https://linear.app/x/ENG-1", createdAt: Date(), updatedAt: Date()
    )
}

@Suite("Override labels")
struct OverrideLabelsTests {
    @Test("The values are every distinct cli, model and effort across routes and fallbacks, sorted")
    func valuesAreDistinctAndSorted() {
        let values = OverrideLabelValues(table: table)
        #expect(values.clis == ["claude", "codex", "gemini"])
        #expect(values.models == ["flash", "gpt-5.4", "opus", "sonnet"])
        #expect(values.efforts == ["high", "low", "medium"])
    }

    @Test("Each group's children resolve by id; a label outside the groups is not a child")
    func groupsResolveTheirChildren() {
        let labels = OverrideLabels(labels: provisioned)
        #expect(labels.cli == [
            "claude": BoardObjectID(rawValue: "cli-claude"),
            "codex": BoardObjectID(rawValue: "cli-codex"),
            "gemini": BoardObjectID(rawValue: "cli-gemini")
        ])
        #expect(labels.model.keys.sorted() == ["opus", "sonnet"])
        #expect(labels.effort.keys.sorted() == ["high", "medium"])
    }

    @Test("A Card's pins are read off its labels by name, case-insensitively, spelled as the group's child is")
    func pinsAreReadByName() {
        let labels = OverrideLabels(labels: provisioned)
        let pinned = labels.override(on: object(labels: ["Card", "Codex", "HIGH"]))
        #expect(pinned == Override(cli: "codex", effort: "high"))
        #expect(labels.override(on: object(labels: ["opus"])) == Override(model: "opus"))
        #expect(labels.override(on: object(labels: ["Card"])) == .none)
    }

    @Test("A label that is not a child of an Override group pins nothing")
    func foreignLabelsPinNothing() {
        let labels = OverrideLabels(labels: provisioned)
        #expect(labels.override(on: object(labels: ["high priority", "codex-tips", "Status"])) == .none)
    }

    @Test("A team without the groups reads every Card as having no Override")
    func missingGroupsMeanNoOverride() {
        let labels = OverrideLabels(labels: [
            label("g-object", "Object Type", isGroup: true), label("card", "Card", parent: "g-object")
        ])
        #expect(labels.cli.isEmpty && labels.model.isEmpty && labels.effort.isEmpty)
        #expect(labels.override(on: object(labels: ["Card", "codex", "high"])) == .none)
    }
}
