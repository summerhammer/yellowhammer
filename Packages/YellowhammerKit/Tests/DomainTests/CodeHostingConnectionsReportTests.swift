import Domain
import Foundation
import Testing

struct CodeHostingConnectionsReportTests {
    @Test("A line without githubCLI, as an older yh prints it, decodes with no offer")
    func lineWithoutOfferDecodes() throws {
        let report = try #require(CodeHostingConnectionsReport.decodeLastLine(["{\"connections\":[]}"]))

        #expect(report.connections.isEmpty)
        #expect(report.gitHubCLI == nil)
    }

    @Test("The gh CLI offer round-trips under the githubCLI key")
    func offerRoundTrips() throws {
        let offered = CodeHostingConnectionsReport(
            connections: [], gitHubCLI: .init(available: true, login: "octocat")
        )
        let refused = CodeHostingConnectionsReport(
            connections: [], gitHubCLI: .init(available: false, reason: "gh is not logged in")
        )

        #expect(offered.encodeLine().contains("\"githubCLI\":{"))
        #expect(!offered.encodeLine().contains("gitHubCLI"))
        #expect(CodeHostingConnectionsReport.decodeLastLine([offered.encodeLine()]) == offered)
        #expect(CodeHostingConnectionsReport.decodeLastLine([refused.encodeLine()]) == refused)
        #expect(CodeHostingConnectionsReport.decodeLastLine([refused.encodeLine()])?.gitHubCLI?.login == nil)
    }
}
