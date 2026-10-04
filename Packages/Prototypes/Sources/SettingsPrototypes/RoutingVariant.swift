#if DEBUG
import SwiftUI

// The Base Routing Table pane. After two rounds of review one layout is left — H · Sections, the pane
// split into Cards, Author and Verification — in two variants that differ only in how a Card's Kind is
// chosen: I's pop-up or J's path of chips. Both edit the same `[RoutingRule]` and leave the rest of the
// Settings window — sidebar, heading, save footer — as the app draws it. A Route is picked rather than
// typed (the CLI from those declared, the effort from what its adapter accepts), and "Any" is a word
// rather than a blank.

/// One prototype of the pane.
struct RoutingVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line.
    let idea: String
    let make: (Binding<[RoutingRule]>) -> AnyView

    var id: String { name }

    static let all: [RoutingVariant] = [
        RoutingVariant(name: "H + I · Kind pop-up", idea: "Cards, Author and Verification; a Kind from a pop-up") {
            AnyView(RoutingSectionsVariant(rules: $0, kindStyle: .popUp))
        },
        RoutingVariant(name: "H + J · Kind path", idea: "Cards, Author and Verification; a Kind as a path of chips") {
            AnyView(RoutingSectionsVariant(rules: $0, kindStyle: .path))
        }
    ]

    static func named(_ name: String) -> RoutingVariant? { all.first { $0.name == name } }
}
#endif
