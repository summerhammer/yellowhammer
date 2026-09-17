import Foundation

/// The JSON Schema (draft 2020-12) documents handed to the CLI adapters to force each pass's result
/// file into the shape ``ResultFile`` decodes. Yellowhammer owns the contract; the CLI is only ever
/// shown the schema for the one pass it is running.
public enum ResultSchema {
    public static func jsonSchema(for pass: RunPass) -> String {
        switch pass {
        case .architect: architectSchema
        case .worker: workerSchema
        case .reviewer: reviewerSchema
        }
    }

    public static func schemaData(for pass: RunPass) -> Data {
        // The schema documents are authored as UTF-8 Swift string literals; this can only fail if one
        // of them is edited to contain non-UTF-8 content, which is a programmer error caught by tests.
        guard let data = jsonSchema(for: pass).data(using: .utf8) else {
            preconditionFailure("ResultSchema.jsonSchema(for: \(pass)) is not valid UTF-8")
        }
        return data
    }

    private static let architectSchema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "required": ["schema", "version", "outcome"],
          "properties": {
            "schema": { "const": "yellowhammer.result.architect" },
            "version": { "const": 1 },
            "outcome": { "enum": ["planned", "failed"] },
            "plan": { "type": "string", "minLength": 1 },
            "affected_paths": { "type": "array", "items": { "type": "string" } },
            "reason": { "type": "string", "minLength": 1 }
          },
          "oneOf": [
            {
              "properties": { "outcome": { "const": "planned" } },
              "required": ["plan"]
            },
            {
              "properties": { "outcome": { "const": "failed" } },
              "required": ["reason"]
            }
          ]
        }
        """

    private static let workerSchema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "required": ["schema", "version", "outcome"],
          "properties": {
            "schema": { "const": "yellowhammer.result.worker" },
            "version": { "const": 1 },
            "outcome": { "enum": ["completed", "question", "failed"] },
            "commit": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
            "summary": { "type": "string", "minLength": 1 },
            "question": { "type": "string", "minLength": 1 },
            "reason": { "type": "string", "minLength": 1 }
          },
          "oneOf": [
            {
              "properties": { "outcome": { "const": "completed" } },
              "required": ["commit", "summary"]
            },
            {
              "properties": { "outcome": { "const": "question" } },
              "required": ["question"]
            },
            {
              "properties": { "outcome": { "const": "failed" } },
              "required": ["reason"]
            }
          ]
        }
        """

    private static let reviewerSchema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "required": ["schema", "version", "verdict", "judged_commit", "summary"],
          "properties": {
            "schema": { "const": "yellowhammer.result.reviewer" },
            "version": { "const": 1 },
            "verdict": { "enum": ["approved", "changes_requested"] },
            "judged_commit": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
            "summary": { "type": "string", "minLength": 1 },
            "requested_changes": { "type": "array", "items": { "type": "string" } }
          },
          "if": {
            "properties": { "verdict": { "const": "changes_requested" } }
          },
          "then": {
            "properties": { "requested_changes": { "type": "array", "minItems": 1 } },
            "required": ["requested_changes"]
          },
          "else": {
            "properties": { "requested_changes": { "type": "array", "maxItems": 0 } }
          }
        }
        """
}
