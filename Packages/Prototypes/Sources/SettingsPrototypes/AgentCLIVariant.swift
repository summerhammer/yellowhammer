#if DEBUG
import SwiftUI

// The Agent CLIs pane, in four variants. Each closes the app's three gaps its own way: a Probe shows which
// stage it is in, how long it has run and roughly what is left, instead of only a spinner; removing a CLI
// is a trash button, as removing a Repo is; and the findings stop leaving most of the card's width empty.
// All of them edit the same `AgentCLIBench` and leave the rest of the Settings window as the app draws it.

/// One prototype of the pane.
struct AgentCLIVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line.
    let idea: String
    let make: (AgentCLIBench) -> AnyView

    var id: String { name }

    static let all: [AgentCLIVariant] = [
        AgentCLIVariant(
            name: "A · Checklist",
            idea: "Facts in one line, findings in a 2 \u{00D7} 2 grid; a Probe swaps them for its stage checklist"
        ) { AnyView(AgentCLIChecklistVariant(bench: $0)) },
        AgentCLIVariant(
            name: "B · Two columns",
            idea: "Facts left, probe targets with their meaning right; targets fill in live over a bar"
        ) { AnyView(AgentCLIColumnsVariant(bench: $0)) },
        AgentCLIVariant(
            name: "C · Sentences",
            idea: "Each CLI as a sentence and a row of marks; a Probe rewrites the sentence beside a filling ring"
        ) { AnyView(AgentCLISentencesVariant(bench: $0)) },
        AgentCLIVariant(
            name: "E · Activity panel",
            idea: "One compact card per CLI; the Probe gets its own panel: a staged bar, the stage, the output"
        ) { AnyView(AgentCLIActivityVariant(bench: $0)) }
    ]

    static func named(_ name: String) -> AgentCLIVariant? { all.first { $0.name == name } }
}
#endif
