import Foundation

/// The Definition of Done checklist line format (roadmap P9.5; spec: feature-authoring/
/// author-citable-definitions-of-done, first story): `- [ ] <!-- yh:clause:<cid> --> <text> (<citation>)`.
/// Shared by ``CardManagedBlock``'s renderer and the authoring transaction's initial descriptions
/// (``AuthoringPlanner``), so the format string exists in exactly one place.
enum DefinitionOfDoneClauseLine {
    static func render(cid: String, text: String, citation: String) -> String {
        "- [ ] <!-- yh:clause:\(cid) --> \(text) (\(citation))"
    }
}
