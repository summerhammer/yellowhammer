import Domain
import Foundation

/// Label management for Card disposition: object type and block reason.
public struct DispositionLabels: Equatable, Sendable {
    public var objectType: [String: BoardObjectID]  // child name → id
    public var blockReason: [BlockReason: BoardObjectID]

    public init(objectType: [String: BoardObjectID], blockReason: [BlockReason: BoardObjectID]) {
        self.objectType = objectType
        self.blockReason = blockReason
    }

    /// Resolves from the labels a team exposes: the child of the group named
    /// BoardProvisioner.objectTypeGroup / blockReasonGroup, matched case-insensitively.
    /// Throws DispositionLabelsError.missing(group:label:) naming the first missing one.
    public init(labels: [BoardLabel]) throws {
        var objectTypeMap: [String: BoardObjectID] = [:]
        var blockReasonMap: [BlockReason: BoardObjectID] = [:]

        // Find group label IDs
        let objectTypeGroupID = labels.first { label in
            label.name.lowercased() == BoardProvisioner.objectTypeGroup.lowercased() && label.isGroup
        }?.id

        let blockReasonGroupID = labels.first { label in
            label.name.lowercased() == BoardProvisioner.blockReasonGroup.lowercased() && label.isGroup
        }?.id

        // Process object type children
        if let groupID = objectTypeGroupID {
            for child in BoardProvisioner.objectTypeChildren {
                let lowerChild = child.lowercased()
                let predicate = { (label: BoardLabel) in
                    label.name.lowercased() == lowerChild && label.parent == groupID
                }
                if let label = labels.first(where: predicate) {
                    objectTypeMap[child] = label.id
                }
            }
        }

        // Process block reason children
        if let groupID = blockReasonGroupID {
            for reason in BlockReason.allCases {
                let lowerValue = reason.rawValue.lowercased()
                let predicate = { (label: BoardLabel) in
                    label.name.lowercased() == lowerValue && label.parent == groupID
                }
                if let label = labels.first(where: predicate) {
                    blockReasonMap[reason] = label.id
                }
            }
        }

        // Verify we have all object type children
        for child in BoardProvisioner.objectTypeChildren where objectTypeMap[child] == nil {
            throw DispositionLabelsError.missing(group: BoardProvisioner.objectTypeGroup, label: child)
        }

        // Verify we have all block reasons
        for reason in BlockReason.allCases where blockReasonMap[reason] == nil {
            throw DispositionLabelsError.missing(group: BoardProvisioner.blockReasonGroup, label: reason.rawValue)
        }

        self.objectType = objectTypeMap
        self.blockReason = blockReasonMap
    }

    /// The change that puts exactly the right labels on a Card: adds "Card" and removes the other
    /// object-type children; adds the one Block Reason label when the Card is Blocked with a known
    /// reason, and removes every other Block Reason label.
    public func change(for state: CardState, blockReason: BlockReason?) -> BoardIssueChange {
        var change = BoardIssueChange()

        // Object type: add "Card", remove others
        if let cardID = objectType["Card"] {
            change.addLabels.append(cardID)
        }
        for child in BoardProvisioner.objectTypeChildren where child != "Card" {
            if let id = objectType[child] {
                change.removeLabels.append(id)
            }
        }

        // Block Reason: add the one if present, remove others
        if let knownReason = blockReason, let reasonID = self.blockReason[knownReason] {
            change.addLabels.append(reasonID)
        }
        for reason in BlockReason.allCases {
            if reason != blockReason, let reasonID = self.blockReason[reason] {
                change.removeLabels.append(reasonID)
            }
        }

        return change
    }
}

public enum DispositionLabelsError: Error, Equatable, CustomStringConvertible {
    case missing(group: String, label: String)

    public var description: String {
        switch self {
        case .missing(let group, let label):
            "The label \(label) in group \(group) is missing from the board"
        }
    }
}
