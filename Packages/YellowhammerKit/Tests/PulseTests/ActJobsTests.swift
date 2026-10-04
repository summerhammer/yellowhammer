import Domain
import Testing

@testable import Pulse

private let listing = """
    PID\tStatus\tLabel
    -\t0\tdev.yellowhammer.alpha.land
    4242\t0\tdev.yellowhammer.alpha.build
    78156\t0\tapplication.dev.yellowhammer.621872183.621888131.A24CCF6C-5446-4230-BF80-3873F18598F5
    308\t0\tcom.apple.something
    this line is malformed
    -\t-9\tdev.yellowhammer.beta.author
    """

@Test("A Project is alive when one of its Act jobs has a PID; a dead job or another Project's does not count")
func parsesAliveJobsPerProject() throws {
    let jobs = ActJobs.parse(launchctlList: listing)

    #expect(jobs.isAlive(projectID: try #require(ProjectID(rawValue: "alpha"))))
    #expect(!jobs.isAlive(projectID: try #require(ProjectID(rawValue: "beta"))))
    #expect(!jobs.isAlive(projectID: try #require(ProjectID(rawValue: "gamma"))))
}

@Test("Labels match exactly: a longer label that contains a Project's id never counts")
func matchesLabelsExactly() throws {
    let jobs = ActJobs.parse(launchctlList: listing)

    #expect(!jobs.isAlive(projectID: try #require(ProjectID(rawValue: "621872183"))))
    #expect(!jobs.isAlive(projectID: try #require(ProjectID(rawValue: "621888131"))))
}

@Test("Empty output and header-only output have no job alive")
func emptyOutput() {
    #expect(ActJobs.parse(launchctlList: "") == .none)
    #expect(ActJobs.parse(launchctlList: "PID\tStatus\tLabel\n") == .none)
}
