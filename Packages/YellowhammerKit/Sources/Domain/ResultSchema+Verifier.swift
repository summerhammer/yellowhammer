// The verifier pass's schema (roadmap P10.5). Flat at the top level, and every nested object requires
// all of its properties with no length bounds, so ``CLIOutputSchema`` can hand it to a CLI's strict
// structured outputs unchanged. The verdict enum omits `unresolved`: only the engine decides that.

extension ResultSchema {
    static let verifierSchema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "required": ["schema", "version", "outcome"],
          "properties": {
            "schema": { "const": "yellowhammer.result.verifier" },
            "version": { "const": 1 },
            "outcome": { "enum": ["reported", "failed"] },
            "clauses": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["issue_id", "cid", "verdict", "what_was_checked", "interpretation"],
                "properties": {
                  "issue_id": { "type": "string" },
                  "cid": { "type": "string" },
                  "verdict": { "enum": ["met", "unmet"] },
                  "what_was_checked": { "type": "string" },
                  "interpretation": { "type": "string" }
                }
              }
            },
            "reason": { "type": "string", "minLength": 1 }
          },
          "oneOf": [
            {
              "properties": { "outcome": { "const": "reported" } },
              "required": ["clauses"]
            },
            {
              "properties": { "outcome": { "const": "failed" } },
              "required": ["reason"]
            }
          ]
        }
        """
}
