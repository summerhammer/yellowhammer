import Domain
import Foundation
import Testing

@testable import Engine

// routing/resolve-a-route-for-a-card, G-17 as amended by the Override Ruling (OQ126): the Override is
// one mutually exclusive label group, `Override`, whose children are whole Routes as `cli/model/effort`
// — provisioned from the merged Routing Table's Routes — and a Card's Override is read off its labels
// by name.

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

/// The group as setup provisions it from `table`, plus an Operator-added off-table Route.
private let provisioned: [BoardLabel] = [
    label("g-override", "Override", isGroup: true),
    label("o-sonnet", "claude/sonnet/medium", parent: "g-override"),
    label("o-codex", "codex/gpt-5.4/medium", parent: "g-override"),
    label("o-agy", "agy/gemini-3-pro/high", parent: "g-override"),
    // Another group's child, and a plain label, with names that could be mistaken for a pin.
    label("g-status", "Status", isGroup: true),
    label("status-route", "claude/opus/high", parent: "g-status"),
    label("plain-codex", "codex")
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
    @Test("The labels are every distinct Route across primaries and fallbacks, as cli/model/effort, sorted")
    func labelsAreDistinctRoutesSorted() {
        let values = OverrideLabelValues(table: table)
        #expect(values.labels == [
            "claude/opus/high", "claude/sonnet/medium", "codex/gpt-5.4/high", "codex/gpt-5.4/medium",
            "gemini/flash/low"
        ])
        #expect(values.refusals.isEmpty)
        #expect(values.entries["gemini/flash/low"] == "(kind `impl`, any Repo Role)")
    }

    @Test("A two-part entry route is labelled with the effort it inherits: a label is never two-part")
    func labelsAreAlwaysThreePart() {
        // The decoder fills an omitted effort from the default, so the table holds three parts.
        let inherited = RoutingTable(entries: [RoutingEntry(route: route("claude", "opus", "medium"))])
        let values = OverrideLabelValues(table: inherited)
        #expect(values.labels == ["claude/opus/medium"])
    }

    @Test("Two Routes rendering to the same text, ignoring case, are both refused, naming their entries")
    func collidingRoutesAreRefused() {
        let colliding = RoutingTable(entries: [
            RoutingEntry(route: route("claude", "opus", "high")),
            RoutingEntry(kind: Kind("impl")!, route: route("claude", "Opus", "high"))
        ])
        let values = OverrideLabelValues(table: colliding)
        #expect(values.labels.isEmpty)
        #expect(values.refusals.keys.sorted() == ["claude/Opus/high", "claude/opus/high"])
        #expect(values.refusals["claude/opus/high"]?.contains("(kind `impl`, any Repo Role)") == true)
    }

    @Test("The group's children resolve by id; a label outside the group is not a child")
    func groupResolvesItsChildren() {
        let labels = OverrideLabels(labels: provisioned)
        #expect(labels.children == [
            "claude/sonnet/medium": BoardObjectID(rawValue: "o-sonnet"),
            "codex/gpt-5.4/medium": BoardObjectID(rawValue: "o-codex"),
            "agy/gemini-3-pro/high": BoardObjectID(rawValue: "o-agy")
        ])
    }

    @Test("A Card's pin is read off its labels by name, case-insensitively, spelled as the group's child is")
    func pinIsReadByName() {
        let labels = OverrideLabels(labels: provisioned)
        #expect(labels.override(on: object(labels: ["Card", "CODEX/GPT-5.4/Medium"])) ==
            Override(label: "codex/gpt-5.4/medium"))
        #expect(labels.override(on: object(labels: ["agy/gemini-3-pro/high"])) ==
            Override(label: "agy/gemini-3-pro/high"))
        #expect(labels.override(on: object(labels: ["Card"])) == nil)
    }

    @Test("A label that is not a child of the Override group pins nothing")
    func foreignLabelsPinNothing() {
        let labels = OverrideLabels(labels: provisioned)
        #expect(labels.override(on: object(labels: ["claude/opus/high", "codex", "Status"])) == nil)
    }

    @Test("A team without the group reads every Card as having no Override, the old per-axis groups included")
    func missingGroupMeansNoOverride() {
        let labels = OverrideLabels(labels: [
            label("g-cli", "Override CLI", isGroup: true), label("cli-codex", "codex", parent: "g-cli")
        ])
        #expect(labels.children.isEmpty)
        #expect(labels.override(on: object(labels: ["codex"])) == nil)
    }
}
