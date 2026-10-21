import Domain
import Foundation

/// Label management for Card disposition. The `Card Type` group is required. Block Reason is a Journal
/// cause shown in the Card's Managed Block, never a label (Board Simplification Ruling 2026-10-20).
public struct DispositionLabels: Equatable, Sendable {
    public var cardType: [CardType: BoardObjectID]

    public init(cardType: [CardType: BoardObjectID]) {
        self.cardType = cardType
    }

    /// Resolves from the labels a team exposes: the child of the group named
    /// BoardProvisioner.cardTypeGroup, matched case-insensitively.
    /// Throws DispositionLabelsError.missing(group:label:) naming the first missing Card Type child.
    ///
    /// `known` holds the Card Type ids a Board Mapping or the persisted footprint names; they win over the
    /// group lookup.
    public init(labels: [BoardLabel], known: [CardType: BoardObjectID] = [:]) throws {
        var cardTypeMap: [CardType: BoardObjectID] = known

        let cardTypeGroupID = labels.first { label in
            label.name.lowercased() == BoardProvisioner.cardTypeGroup.lowercased() && label.isGroup
        }?.id

        if let groupID = cardTypeGroupID {
            for type in CardType.allCases where cardTypeMap[type] == nil {
                let lowerChild = type.rawValue.lowercased()
                let predicate = { (label: BoardLabel) in
                    label.name.lowercased() == lowerChild && label.parent == groupID
                }
                if let label = labels.first(where: predicate) {
                    cardTypeMap[type] = label.id
                }
            }
        }

        for type in CardType.allCases where cardTypeMap[type] == nil {
            throw DispositionLabelsError.missing(group: BoardProvisioner.cardTypeGroup, label: type.rawValue)
        }

        self.cardType = cardTypeMap
    }

    /// The change that puts exactly the right labels on an issue: adds `cardType`'s child label and
    /// removes the other card-type children.
    public func change(cardType: CardType) -> BoardIssueChange {
        var change = BoardIssueChange()

        if let id = self.cardType[cardType] {
            change.addLabels.append(id)
        }
        for type in CardType.allCases where type != cardType {
            if let id = self.cardType[type] {
                change.removeLabels.append(id)
            }
        }

        return change
    }

    /// ``change(cardType:)`` for a Work Card.
    public func workCardChange() -> BoardIssueChange {
        change(cardType: .workCard)
    }
}

public enum DispositionLabelsError: Error, Equatable, CustomStringConvertible {
    case missing(group: String, label: String)

    public var description: String {
        switch self {
        case .missing(let group, let label):
            "The label \(label) in group \(group) is missing from the board; "
                + "run `yh doctor --fix --check linear` to provision it"
        }
    }
}
