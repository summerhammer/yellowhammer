// The author Act's two pass schemas (roadmap P9.11). Flat at the top level, and every nested object
// requires all of its properties with no length bounds, so ``CLIOutputSchema`` can hand them to a CLI's
// strict structured outputs unchanged.

extension ResultSchema {
    static let selectionSchema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "required": ["schema", "version", "outcome"],
          "properties": {
            "schema": { "const": "yellowhammer.result.selection" },
            "version": { "const": 1 },
            "outcome": { "enum": ["selected", "no_selectable_feature", "halted", "failed"] },
            "name": { "type": "string", "minLength": 1 },
            "reasoning": { "type": "string", "minLength": 1 },
            "sequence": {
              "type": "object",
              "additionalProperties": false,
              "required": ["preceded_by", "followed_by", "seam"],
              "properties": {
                "preceded_by": { "type": "string" },
                "followed_by": { "type": "string" },
                "seam": { "type": "string" }
              }
            },
            "repositories": { "type": "array", "items": { "type": "string" } },
            "adopted_card_issue_ids": { "type": "array", "items": { "type": "string" } },
            "feature": { "type": "string", "minLength": 1 },
            "halt_cause": {
              "enum": ["no-backward-compatible-seam", "repositories-undetermined", "contract-outside-project"]
            },
            "halt_seam": { "type": "string", "minLength": 1 },
            "halt_repository": { "type": "string", "minLength": 1 },
            "reason": { "type": "string", "minLength": 1 }
          },
          "oneOf": [
            {
              "properties": { "outcome": { "const": "selected" } },
              "required": ["name", "reasoning", "repositories"]
            },
            {
              "properties": { "outcome": { "const": "no_selectable_feature" } }
            },
            {
              "properties": { "outcome": { "const": "halted" } },
              "required": ["feature", "halt_cause"]
            },
            {
              "properties": { "outcome": { "const": "failed" } },
              "required": ["reason"]
            }
          ]
        }
        """

    static let breakdownSchema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "required": ["schema", "version", "outcome"],
          "properties": {
            "schema": { "const": "yellowhammer.result.breakdown" },
            "version": { "const": 1 },
            "outcome": { "enum": ["drafted", "failed"] },
            "definition_of_done": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["text", "citation"],
                "properties": {
                  "text": { "type": "string" },
                  "citation": { "type": "string" }
                }
              }
            },
            "cards": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": [
                  "repository", "kind", "title", "unit_of_work", "brief", "definition_of_done", "contracts"
                ],
                "properties": {
                  "repository": { "type": "string" },
                  "kind": { "type": "string" },
                  "title": { "type": "string" },
                  "unit_of_work": { "type": "string" },
                  "brief": { "type": "string" },
                  "definition_of_done": {
                    "type": "array",
                    "items": {
                      "type": "object",
                      "additionalProperties": false,
                      "required": ["text", "citation"],
                      "properties": {
                        "text": { "type": "string" },
                        "citation": { "type": "string" }
                      }
                    }
                  },
                  "contracts": {
                    "type": "array",
                    "items": {
                      "type": "object",
                      "additionalProperties": false,
                      "required": ["repository", "paths", "symbol"],
                      "properties": {
                        "repository": { "type": "string" },
                        "paths": { "type": "array", "items": { "type": "string" } },
                        "symbol": { "type": ["string", "null"] }
                      }
                    }
                  }
                }
              }
            },
            "reason": { "type": "string", "minLength": 1 }
          },
          "oneOf": [
            {
              "properties": { "outcome": { "const": "drafted" } },
              "required": ["definition_of_done", "cards"]
            },
            {
              "properties": { "outcome": { "const": "failed" } },
              "required": ["reason"]
            }
          ]
        }
        """
}
