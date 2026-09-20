import Foundation

// The author Act's two passes (roadmap P9.11), split out of ResultFile.swift to keep it under the file
// length limit. Every key maps 1:1 onto an existing domain type; nothing here is a new concept.

extension ResultFile {
    static func decodeSelection(_ object: [String: Any]) throws(ResultFileError) -> SelectionResult {
        let outcomeRaw = try string(object, "outcome")
        switch outcomeRaw {
        case "selected":
            return SelectionResult(outcome: .selected(try selectedFeature(object)))
        case "no_selectable_feature":
            return SelectionResult(outcome: .noSelectableFeature)
        case "halted":
            let name = try featureName(object, "feature")
            return SelectionResult(outcome: .halted(feature: name, cause: try haltCause(object)))
        case "failed":
            return SelectionResult(outcome: .failed(reason: try nonEmptyString(object, "reason")))
        default:
            throw .invalid(field: "outcome", reason: "unknown outcome `\(outcomeRaw)`")
        }
    }

    static func decodeBreakdown(_ object: [String: Any]) throws(ResultFileError) -> BreakdownResult {
        let outcomeRaw = try string(object, "outcome")
        switch outcomeRaw {
        case "drafted":
            let clauses = try clauseDrafts(object, "definition_of_done", field: "definition_of_done")
            let cards = try objectArray(object, "cards", field: "cards")
            let drafts = try cards.enumerated().map { index, card throws(ResultFileError) in
                try cardDraft(card, path: "cards[\(index)]")
            }
            let breakdown = FeatureBreakdown(definitionOfDone: clauses ?? [], cards: drafts)
            return BreakdownResult(outcome: .drafted(breakdown))
        case "failed":
            return BreakdownResult(outcome: .failed(reason: try nonEmptyString(object, "reason")))
        default:
            throw .invalid(field: "outcome", reason: "unknown outcome `\(outcomeRaw)`")
        }
    }

    // MARK: - Selection

    private static func selectedFeature(_ object: [String: Any]) throws(ResultFileError) -> SelectedFeature {
        let name = try featureName(object, "name")
        let reasoning = try nonEmptyString(object, "reasoning")
        var sequence: FeatureSequence?
        if let raw = object["sequence"], !(raw is NSNull) {
            guard let table = raw as? [String: Any] else {
                throw .invalid(field: "sequence", reason: "must be an object")
            }
            sequence = FeatureSequence(
                precededBy: try nonEmptyString(table, "preceded_by", path: "sequence"),
                followedBy: try nonEmptyString(table, "followed_by", path: "sequence"),
                seam: try nonEmptyString(table, "seam", path: "sequence")
            )
        }
        guard let repositories = try stringArray(object, "repositories") else {
            throw .invalid(field: "repositories", reason: "missing or not an array of strings")
        }
        return SelectedFeature(
            name: name, reasoning: reasoning, sequence: sequence, repositories: repositories,
            adoptedCardIssueIDs: try stringArray(object, "adopted_card_issue_ids") ?? []
        )
    }

    /// A selector may return the three causes it can itself find; an unreadable contract is found later,
    /// by the transcription, and is never a selection result.
    private static func haltCause(_ object: [String: Any]) throws(ResultFileError) -> AuthoringHaltCause {
        let kind = try string(object, "halt_cause")
        switch kind {
        case "no-backward-compatible-seam":
            return .noBackwardCompatibleSeam(seam: try nonEmptyString(object, "halt_seam"))
        case "repositories-undetermined":
            return .repositoriesUndetermined
        case "contract-outside-project":
            return .contractOutsideProject(repository: try nonEmptyString(object, "halt_repository"))
        default:
            throw .invalid(field: "halt_cause", reason: "unknown halt cause `\(kind)`")
        }
    }

    private static func featureName(_ object: [String: Any], _ key: String) throws(ResultFileError) -> FeatureName {
        guard let name = FeatureName(rawValue: try nonEmptyString(object, key)) else {
            throw .invalid(field: key, reason: "must not be empty")
        }
        return name
    }

    // MARK: - Breakdown

    private static func cardDraft(_ card: [String: Any], path: String) throws(ResultFileError) -> CardDraft {
        // Title, brief and repository are read as they are: an empty one is a rejected breakdown the
        // engine's own validation reports, not a malformed result file.
        let kindRaw = try string(card, "kind", path: path)
        guard let kind = Kind(kindRaw) else {
            throw .invalid(field: "\(path).kind", reason: "`\(kindRaw)` is not a Kind")
        }
        let contracts = try objectArray(card, "contracts", field: "\(path).contracts", optional: true).enumerated()
            .map { index, contract throws(ResultFileError) in
                try contractDraft(contract, path: "\(path).contracts[\(index)]")
            }
        return CardDraft(
            repository: try string(card, "repository", path: path),
            kind: kind,
            title: try string(card, "title", path: path),
            unitOfWork: try string(card, "unit_of_work", path: path),
            brief: try string(card, "brief", path: path),
            definitionOfDone: try clauseDrafts(card, "definition_of_done", field: "\(path).definition_of_done") ?? [],
            contracts: contracts
        )
    }

    private static func contractDraft(
        _ contract: [String: Any], path: String
    ) throws(ResultFileError) -> ContractDraft {
        guard let paths = try stringArray(contract, "paths", path: path) else {
            throw .invalid(field: "\(path).paths", reason: "missing or not an array of strings")
        }
        var symbol: String?
        if let raw = contract["symbol"], !(raw is NSNull) {
            symbol = try nonEmptyString(contract, "symbol", path: path)
        }
        return ContractDraft(
            repository: try nonEmptyString(contract, "repository", path: path), paths: paths, symbol: symbol
        )
    }

    private static func clauseDrafts(
        _ object: [String: Any], _ key: String, field: String
    ) throws(ResultFileError) -> [DefinitionOfDoneClauseDraft]? {
        guard object[key] != nil else { return nil }
        let items = try objectArray(object, key, field: field)
        return try items.enumerated().map { index, item throws(ResultFileError) in
            let itemPath = "\(field)[\(index)]"
            return DefinitionOfDoneClauseDraft(
                text: try nonEmptyString(item, "text", path: itemPath),
                citation: SpecCitation(try nonEmptyString(item, "citation", path: itemPath))
            )
        }
    }

    // MARK: - Nested-field helpers

    /// `key` as an array of objects; `field` is the full path named in an error.
    private static func objectArray(
        _ object: [String: Any], _ key: String, field: String, optional: Bool = false
    ) throws(ResultFileError) -> [[String: Any]] {
        guard let raw = object[key] else {
            if optional { return [] }
            throw .invalid(field: field, reason: "missing or not an array of objects")
        }
        guard let array = raw as? [[String: Any]] else {
            throw .invalid(field: field, reason: "must be an array of objects")
        }
        return array
    }

    private static func string(
        _ object: [String: Any], _ key: String, path: String
    ) throws(ResultFileError) -> String {
        guard let value = object[key] as? String else {
            throw .invalid(field: "\(path).\(key)", reason: "missing or not a string")
        }
        return value
    }

    private static func nonEmptyString(
        _ object: [String: Any], _ key: String, path: String
    ) throws(ResultFileError) -> String {
        let value = try string(object, key, path: path)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalid(field: "\(path).\(key)", reason: "must not be empty")
        }
        return value
    }

    private static func stringArray(
        _ object: [String: Any], _ key: String, path: String
    ) throws(ResultFileError) -> [String]? {
        guard let raw = object[key] else { return nil }
        guard let array = raw as? [String] else {
            throw .invalid(field: "\(path).\(key)", reason: "must be an array of strings")
        }
        return array
    }
}
