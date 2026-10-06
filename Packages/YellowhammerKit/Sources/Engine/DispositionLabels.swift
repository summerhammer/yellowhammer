import Domain
import Foundation

/// Label management for Card disposition: card type and block reason.
public struct DispositionLabels: Equatable, Sendable {
    public var cardType: [CardType: BoardObjectID]
    public var blockReason: [BlockReason: BoardObjectID]

    public init(cardType: [CardType: BoardObjectID], blockReason: [BlockReason: BoardObjectID]) {
        self.cardType = cardType
        self.blockReason = blockReason
    }

    /// Resolves from the labels a team exposes: the child of the group named
    /// BoardProvisioner.cardTypeGroup / blockReasonGroup, matched case-insensitively.
    /// Throws DispositionLabelsError.missing(group:label:) naming the first missing one.
    public init(labels: [BoardLabel]) throws {
        var cardTypeMap: [CardType: BoardObjectID] = [:]
        var blockReasonMap: [BlockReason: BoardObjectID] = [:]

        // Find group label IDs
        let cardTypeGroupID = labels.first { label in
            label.name.lowercased() == BoardProvisioner.cardTypeGroup.lowercased() && label.isGroup
        }?.id

        let blockReasonGroupID = labels.first { label in
            label.name.lowercased() == BoardProvisioner.blockReasonGroup.lowercased() && label.isGroup
        }?.id

        // Process card type children
        if let groupID = cardTypeGroupID {
            for type in CardType.allCases {
                let lowerChild = type.rawValue.lowercased()
                let predicate = { (label: BoardLabel) in
                    label.name.lowercased() == lowerChild && label.parent == groupID
                }
                if let label = labels.first(where: predicate) {
                    cardTypeMap[type] = label.id
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

        // Verify we have all card type children
        for type in CardType.allCases where cardTypeMap[type] == nil {
            throw DispositionLabelsError.missing(group: BoardProvisioner.cardTypeGroup, label: type.rawValue)
        }

        // Verify we have all block reasons
        for reason in BlockReason.allCases where blockReasonMap[reason] == nil {
            throw DispositionLabelsError.missing(group: BoardProvisioner.blockReasonGroup, label: reason.rawValue)
        }

        self.cardType = cardTypeMap
        self.blockReason = blockReasonMap
    }

    /// The change that puts exactly the right labels on an issue: adds `cardType`'s child label and
    /// removes the other card-type children; adds the one Block Reason label when `state` is Blocked
    /// with a known reason, and removes every other Block Reason label (the Block Reason group is only
    /// ever non-empty on a Blocked issue).
    public func change(cardType: CardType, state: CardState, blockReason: BlockReason?) -> BoardIssueChange {
        var change = BoardIssueChange()

        // Card type: add the named child, remove the others.
        if let id = self.cardType[cardType] {
            change.addLabels.append(id)
        }
        for type in CardType.allCases where type != cardType {
            if let id = self.cardType[type] {
                change.removeLabels.append(id)
            }
        }

        // Block Reason: add the one if the issue is Blocked with a known reason, remove every other.
        let effectiveReason = state == .blocked ? blockReason : nil
        if let effectiveReason, let reasonID = self.blockReason[effectiveReason] {
            change.addLabels.append(reasonID)
        }
        for reason in BlockReason.allCases {
            if reason != effectiveReason, let reasonID = self.blockReason[reason] {
                change.removeLabels.append(reasonID)
            }
        }

        return change
    }

    /// `change(cardType:state:blockReason:)` for a Work Card.
    public func change(for state: CardState, blockReason: BlockReason?) -> BoardIssueChange {
        change(cardType: .workCard, state: state, blockReason: blockReason)
    }
}

public enum DispositionLabelsError: Error, Equatable, CustomStringConvertible {
    case missing(group: String, label: String)

    public var description: String {
        switch self {
        case .missing(let group, let label):
            "The label \(label) in group \(group) is missing from the board; run `yh setup` to provision it"
        }
    }
}
