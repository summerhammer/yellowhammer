import Domain
import Foundation

/// The dialect of ``ResultSchema`` each CLI's structured-output enforcement accepts. The Domain
/// schema stays the contract — ``ResultFile`` validates every result file against it after the run —
/// so a derived dialect may only loosen what the CLI is shown, never what completes an Attempt.
///
/// The derivation exists because both CLIs refused the Domain document as-is (spec
/// `routing/add-an-agent-cli` — adapters own structured output conventions, CLIs drift in them):
/// `claude` rejects the draft 2020-12 `$schema` identifier and any top-level `oneOf`, and `codex`
/// forwards the schema to strict structured outputs, which permit no `oneOf`/`if`/`then`/`else` and
/// require every property.
enum CLIOutputSchema {
    /// A flat, strict-structured-outputs rendering of ``ResultSchema``: conditional keywords dropped, every
    /// property required, a property the Domain schema leaves optional made nullable, `const` spelled
    /// as a one-value `enum`, and string length bounds dropped.
    static func strict(for pass: RunPass) -> String {
        let schema = domainSchema(for: pass)
        let required = Set(schema["required"] as? [String] ?? [])
        let properties = schema["properties"] as? [String: Any] ?? [:]

        var strictProperties: [String: Any] = [:]
        for (name, value) in properties {
            guard let property = value as? [String: Any] else { continue }
            strictProperties[name] = strictProperty(property, nullable: !required.contains(name))
        }
        let strictSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": strictProperties.keys.sorted(),
            "properties": strictProperties
        ]
        return serialized(strictSchema)
    }

    /// Removes top-level `null` members a CLI writes for properties it had to declare
    /// nullable, so the result file reads as the Domain schema expects: an absent optional field.
    static func removingNullMembers(from data: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        object = object.filter { !($0.value is NSNull) }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Private

    private static func strictProperty(_ property: [String: Any], nullable: Bool) -> [String: Any] {
        var strict = property
        strict.removeValue(forKey: "minLength")
        strict.removeValue(forKey: "maxLength")
        if let constant = strict.removeValue(forKey: "const") {
            strict["enum"] = [constant]
        }
        if strict["type"] == nil {
            strict["type"] = jsonType(of: (strict["enum"] as? [Any])?.first)
        }
        if nullable, let type = strict["type"] as? String {
            strict["type"] = [type, "null"]
            if var values = strict["enum"] as? [Any] {
                values.append(NSNull())
                strict["enum"] = values
            }
        }
        return strict
    }

    private static func jsonType(of value: Any?) -> String {
        switch value {
        case is String: "string"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): "boolean"
        case let number as NSNumber where CFNumberIsFloatType(number): "number"
        case is NSNumber: "integer"
        default: "string"
        }
    }

    private static func domainSchema(for pass: RunPass) -> [String: Any] {
        // ResultSchema's documents are literals covered by Domain tests; failing to parse one is a
        // programmer error, not a runtime condition.
        guard let schema = (try? JSONSerialization.jsonObject(with: ResultSchema.schemaData(for: pass)))
            as? [String: Any]
        else {
            preconditionFailure("ResultSchema.jsonSchema(for: \(pass)) is not a JSON object")
        }
        return schema
    }

    private static func serialized(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(bytes: data, encoding: .utf8)
        else {
            preconditionFailure("derived result schema is not serializable")
        }
        return text
    }
}
