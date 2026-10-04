import Testing

@testable import Domain

@Test("An Act's LaunchAgent label is dev.yellowhammer.<project>.<act>")
func launchdLabelFormat() throws {
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    #expect(Act.build.launchdLabel(projectID: projectID) == "dev.yellowhammer.alpha.build")
    #expect(Act.author.launchdLabel(projectID: projectID) == "dev.yellowhammer.alpha.author")
    #expect(Act.land.launchdLabel(projectID: projectID) == "dev.yellowhammer.alpha.land")
}
