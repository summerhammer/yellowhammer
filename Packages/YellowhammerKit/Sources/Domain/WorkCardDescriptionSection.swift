/// The sections a Work Card's description is measured in against the board's description budget. One
/// vocabulary for the budget check's reason line and the breakdown pass's prompt, so the two cannot name a
/// section differently.
public enum WorkCardDescriptionSection: CaseIterable, Sendable {
    case brief
    case transcriptionReferences
    case definitionOfDone
    case unitOfWork
    case restOfManagedBlock

    public var title: String {
        switch self {
        case .brief: "Architectural Brief"
        case .transcriptionReferences: "Transcription Block references"
        case .definitionOfDone: "Definition of Done"
        case .unitOfWork: "unit of work"
        case .restOfManagedBlock: "the rest of the Managed Block"
        }
    }
}
