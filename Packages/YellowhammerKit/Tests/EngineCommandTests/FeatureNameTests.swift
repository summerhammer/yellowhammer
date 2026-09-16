import Domain
import Testing

// P4.1: FeatureName and ActTrigger domain types

@Test("FeatureName accepts ordinary text")
func featureNameAcceptsOrdinaryText() {
    let name = FeatureName(rawValue: "Ship the Journal")
    #expect(name != nil)
    #expect(name?.rawValue == "Ship the Journal")
}

@Test("FeatureName trims leading and trailing whitespace and newlines")
func featureNameTrims() {
    let name = FeatureName(rawValue: "  \n  Spaced  \t\n  ")
    #expect(name != nil)
    #expect(name?.rawValue == "Spaced")
}

@Test("FeatureName rejects empty string", arguments: ["", "   ", "\n", "\t "])
func featureNameRejectsEmpty(_ input: String) {
    let name = FeatureName(rawValue: input)
    #expect(name == nil)
}

@Test("FeatureName description equals rawValue")
func featureNameDescription() {
    let name = FeatureName(rawValue: "Test Feature")
    #expect(name?.description == name?.rawValue)
    #expect(name?.description == "Test Feature")
}

@Test("Equal FeatureNames hash equal")
func featureNameHashable() {
    let name1 = FeatureName(rawValue: "Feature")
    let name2 = FeatureName(rawValue: "Feature")
    #expect(name1 == name2)
    #expect(Set([name1, name2]).count == 1)
}

@Test("ActTrigger.isForced returns true for .forced and .forcedForFeature")
func actTriggerIsForced() throws {
    #expect(ActTrigger.scheduled.isForced == false)
    #expect(ActTrigger.forced.isForced == true)
    let feature = try #require(FeatureName(rawValue: "test"))
    #expect(ActTrigger.forcedForFeature(feature).isForced == true)
}

@Test("ActTrigger.namedFeature returns nil for .scheduled and .forced")
func actTriggerNamedFeatureNil() {
    #expect(ActTrigger.scheduled.namedFeature == nil)
    #expect(ActTrigger.forced.namedFeature == nil)
}

@Test("ActTrigger.namedFeature returns the name for .forcedForFeature")
func actTriggerNamedFeature() throws {
    let feature = try #require(FeatureName(rawValue: "Test Feature"))
    let trigger = ActTrigger.forcedForFeature(feature)
    #expect(trigger.namedFeature == feature)
    #expect(trigger.namedFeature?.rawValue == "Test Feature")
}
