import Domain
import Testing

struct DescriptionBudgetTests {
    private let limit = BoardDescriptionLimit(maximum: 250_000, unit: .utf16CodeUnits)

    @Test("UTF-16 code units: an emoji counts 2, a precomposed é counts 1, a decomposed é counts 2")
    func utf16Measuring() {
        #expect(DescriptionLengthUnit.utf16CodeUnits.length(of: "🦜") == 2)
        #expect(DescriptionLengthUnit.utf16CodeUnits.length(of: "\u{00E9}") == 1)
        #expect(DescriptionLengthUnit.utf16CodeUnits.length(of: "e\u{0301}") == 2)
        #expect(DescriptionLengthUnit.utf16CodeUnits.length(of: "") == 0)
    }

    @Test("Characters: an emoji and a decomposed é each count 1")
    func characterMeasuring() {
        #expect(DescriptionLengthUnit.characters.length(of: "🦜") == 1)
        #expect(DescriptionLengthUnit.characters.length(of: "e\u{0301}") == 1)
    }

    @Test("The ceiling is 90% of the limit, rounded down")
    func ceiling() {
        #expect(limit.budgetCeiling == 225_000)
        #expect(BoardDescriptionLimit(maximum: 7, unit: .characters).budgetCeiling == 6)
        #expect(BoardDescriptionLimit(maximum: 10, unit: .characters).budgetCeiling == 9)
    }

    @Test("An unset budget is the default of 10,000")
    func unsetIsDefault() throws {
        #expect(DescriptionBudget.defaultValue == 10_000)
        let budget = try DescriptionBudget(configured: nil, limit: limit)
        #expect(budget.value == 10_000)
        #expect(budget.limit == limit)
    }

    @Test("The default is capped at the ceiling of a board whose ceiling is below it")
    func defaultIsCapped() throws {
        let small = BoardDescriptionLimit(maximum: 1_000, unit: .characters)
        #expect(try DescriptionBudget(configured: nil, limit: small).value == 900)
    }

    @Test("1 and the ceiling are accepted")
    func boundsAccepted() throws {
        #expect(try DescriptionBudget(configured: 1, limit: limit).value == 1)
        #expect(try DescriptionBudget(configured: 225_000, limit: limit).value == 225_000)
    }

    @Test("0, a negative value and one above the ceiling are refused")
    func boundsRefused() {
        #expect(throws: DescriptionBudget.Refusal.belowOne(0)) {
            try DescriptionBudget(configured: 0, limit: limit)
        }
        #expect(throws: DescriptionBudget.Refusal.belowOne(-5)) {
            try DescriptionBudget(configured: -5, limit: limit)
        }
        #expect(throws: DescriptionBudget.Refusal.aboveCeiling(225_001, ceiling: 225_000)) {
            try DescriptionBudget(configured: 225_001, limit: limit)
        }
    }

    @Test("A description fits at the budget and not one unit past it, measured in the limit's unit")
    func fitting() throws {
        let budget = try DescriptionBudget(configured: 4, limit: limit)
        #expect(budget.measure("🦜🦜") == 4)
        #expect(budget.fits("🦜🦜"))
        #expect(!budget.fits("🦜🦜a"))
    }
}
