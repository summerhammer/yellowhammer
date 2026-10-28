import Domain
import Testing

@Suite struct ProjectInstructionsComparisonTests {
    private let text = "Prefer small commits.\n⟨not a placeholder⟩"

    @Test func everyProductionFamilyDiffersByTheOneAddedSectionBeforeBoundaries() throws {
        let shipped = PromptCatalog.entries
        let customized = PromptCatalog.entries(projectInstructions: text)
        for family in PromptFamily.allCases where family.acceptsProjectInstructions {
            let shippedEntry = try #require(shipped.first { $0.family == family })
            let customizedEntry = try #require(customized.first { $0.family == family })
            for (before, after) in zip(shippedEntry.variants, customizedEntry.variants) {
                let comparison = try #require(
                    ProjectInstructionsComparison(
                        shipped: before.template, customized: after.template, projectInstructions: text
                    )
                )
                #expect(comparison.isOnlyDifference)
                #expect(comparison.added == ProjectInstructionsSection.render(text))
                #expect(comparison.precedesHeading == "## Boundaries")
            }
        }
    }

    @Test func emptyTextOrAnUnrelatedTemplateYieldsNoComparison() {
        #expect(ProjectInstructionsComparison(shipped: "a", customized: "a", projectInstructions: "  \n") == nil)
        #expect(ProjectInstructionsComparison(shipped: "a", customized: "b", projectInstructions: text) == nil)
    }

    @Test func aDifferingRemainderIsNotReportedAsTheOnlyDifference() throws {
        let section = ProjectInstructionsSection.render(text)
        let comparison = try #require(
            ProjectInstructionsComparison(
                shipped: "one\n\n## Boundaries", customized: "ONE\n\n\(section)\n\n## Boundaries",
                projectInstructions: text
            )
        )
        #expect(!comparison.isOnlyDifference)
    }
}
