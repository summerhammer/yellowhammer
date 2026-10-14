@testable import Engine
import Testing

@Suite("Feature authoring prose preserves unrelated description text")
struct FeatureAuthoringProseTests {
    @Test("Retry replaces the owned prose once, preserving human text and the primary Managed Block")
    func retryReplacesOnlyOwnedProse() throws {
        let primary = ManagedBlockFence.initialDescription(rendered: "Roll-up stays here.")
        let original = "Human prefix.\n\n" + primary + "\nHuman suffix."
        let first = try #require(FeatureAuthoringProse.replace(in: original, prose: "Old authoring."))
        let retried = try #require(FeatureAuthoringProse.replace(
            in: first + "\nHuman later suffix.", prose: "New authoring."
        ))
        #expect(retried.hasPrefix(original))
        #expect(retried.hasSuffix("\nHuman later suffix."))
        #expect(retried.components(separatedBy: FeatureAuthoringProse.start).count == 2)
        #expect(retried.contains("New authoring."))
        #expect(!retried.contains("Old authoring."))
        #expect(try ManagedBlockFence.parts(of: retried).get().block == "Roll-up stays here.")
        #expect(FeatureAuthoringProse.replace(in: retried, prose: "New authoring.") == retried)
    }

    @Test("Malformed or duplicate authoring delimiters are refused", arguments: [
        FeatureAuthoringProse.start,
        FeatureAuthoringProse.end,
        FeatureAuthoringProse.end + FeatureAuthoringProse.start,
        FeatureAuthoringProse.start + FeatureAuthoringProse.start + FeatureAuthoringProse.end,
        FeatureAuthoringProse.start + FeatureAuthoringProse.end + FeatureAuthoringProse.end
    ])
    func malformedIsRefused(region: String) {
        let description = ManagedBlockFence.initialDescription(rendered: "Roll-up") + region
        #expect(FeatureAuthoringProse.replace(in: description, prose: "New authoring.") == nil)
    }
}
