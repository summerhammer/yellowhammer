import Domain
import Testing

// Unit tests for ``ProtectedPaths/match(declaredScope:protectedPaths:)`` (roadmap P8.3). Domain has no
// dedicated test target, so these live alongside the other Readiness Check tests, which already depend
// on Domain.

@Test("A declared path under a protected directory matches")
func declaredPathUnderProtectedDirectoryMatches() {
    let match = ProtectedPaths.match(
        declaredScope: ["Sources/Secrets/key.swift"], protectedPaths: ["Sources/Secrets/"]
    )
    #expect(match == ProtectedPaths.Match(declaredPath: "Sources/Secrets/key.swift", protectedPath: "Sources/Secrets/"))
}

@Test("A declared directory containing a protected path matches")
func declaredDirectoryContainingProtectedPathMatches() {
    let match = ProtectedPaths.match(declaredScope: ["Sources/"], protectedPaths: ["Sources/Secrets/"])
    #expect(match == ProtectedPaths.Match(declaredPath: "Sources/", protectedPath: "Sources/Secrets/"))
}

@Test("Matching is component-wise: a sibling name prefix does not match")
func componentWiseMatchingRejectsNamePrefix() {
    let match = ProtectedPaths.match(declaredScope: ["Secrets"], protectedPaths: ["SecretsExtra"])
    #expect(match == nil)
    let reverseMatch = ProtectedPaths.match(declaredScope: ["SecretsExtra"], protectedPaths: ["Secrets"])
    #expect(reverseMatch == nil)
}

@Test("Matching is case-sensitive")
func matchingIsCaseSensitive() {
    let match = ProtectedPaths.match(declaredScope: ["secrets/key"], protectedPaths: ["Secrets/"])
    #expect(match == nil)
}

@Test("Empty and blank entries never match")
func emptyAndBlankEntriesNeverMatch() {
    #expect(ProtectedPaths.match(declaredScope: [""], protectedPaths: ["Secrets/"]) == nil)
    #expect(ProtectedPaths.match(declaredScope: ["   "], protectedPaths: ["Secrets/"]) == nil)
    #expect(ProtectedPaths.match(declaredScope: ["Secrets/key"], protectedPaths: [""]) == nil)
}

@Test("Paths are normalised before matching: leading ./ and /, and trailing /, are stripped")
func pathsAreNormalisedBeforeMatching() {
    let match = ProtectedPaths.match(declaredScope: ["./Secrets/key"], protectedPaths: ["/Secrets/"])
    #expect(match == ProtectedPaths.Match(declaredPath: "./Secrets/key", protectedPath: "/Secrets/"))
}

@Test("No match returns nil when no declared path falls under any protected path")
func noMatchReturnsNilWhenScopesDisjoint() {
    let match = ProtectedPaths.match(declaredScope: ["Sources/App/"], protectedPaths: ["Secrets/"])
    #expect(match == nil)
}

@Test("The first match wins, in declared-scope order then protected-path order")
func firstMatchWinsInOrder() {
    let match = ProtectedPaths.match(
        declaredScope: ["Sources/App/", "Secrets/key.env", "Private/data"],
        protectedPaths: ["Private/", "Secrets/"]
    )
    #expect(match == ProtectedPaths.Match(declaredPath: "Secrets/key.env", protectedPath: "Secrets/"))
}
