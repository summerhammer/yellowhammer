import Testing

@testable import Domain

@Test("An Act's log is <home>/Library/Logs/Yellowhammer/<project>.<act>.log")
func logPathFormat() throws {
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    #expect(
        Act.land.logPath(projectID: projectID, homeDirectory: "~") == "~/Library/Logs/Yellowhammer/alpha.land.log"
    )
    #expect(
        Act.build.logPath(projectID: projectID, homeDirectory: "/Users/max")
            == "/Users/max/Library/Logs/Yellowhammer/alpha.build.log"
    )
}
