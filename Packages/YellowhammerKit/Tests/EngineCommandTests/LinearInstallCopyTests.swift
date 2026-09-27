@testable import EngineCommand
import Foundation
import Testing

// roadmap P17.6 slice (a) (spec: board-projection/install-the-linear-app "A non-admin Operator"): the
// non-admin copy is quoted verbatim in the story — asserted in full so a `\`-continuation edit cannot
// silently gain or lose a word or a space.

@Suite("LinearInstallCopy (P17.6/P17.9)")
struct LinearInstallCopyTests {
    @Test("The non-admin copy points at --remote (roadmap P17.9)")
    func nonAdminCopyPointsAtRemote() {
        #expect(LinearInstallCopy.nonAdmin == """
        Installing here needs a Linear workspace admin account. If you are not an admin, request approval \
        from an admin instead: yh setup --install-linear --remote
        """)
    }

    @Test("beforeRemoteApproval names each team when given, and falls back when empty")
    func beforeRemoteApprovalCopyNamesTeamsOrFallsBack() {
        #expect(LinearInstallCopy.beforeRemoteApproval(teams: []).contains("choose the teams your Projects use"))
        #expect(LinearInstallCopy.beforeRemoteApproval(teams: [engineeringTeam])
            .contains("choose ENG (Engineering)"))
    }

    @Test("approvalLink names the URL and rounds the validity window down to whole minutes, minimum 1")
    func approvalLinkCopyNamesURLAndMinutes() {
        let url = URL(string: "https://app.yellowhammer.dev/install/abc123")!
        #expect(LinearInstallCopy.approvalLink(url: url, expiresIn: .seconds(900))
            .contains("valid for 15 minutes"))
        #expect(LinearInstallCopy.approvalLink(url: url, expiresIn: .seconds(900)).contains(url.absoluteString))
        #expect(LinearInstallCopy.approvalLink(url: url, expiresIn: .seconds(90)).contains("valid for 1 minutes"))
        #expect(LinearInstallCopy.approvalLink(url: url, expiresIn: .seconds(30)).contains("valid for 1 minutes"))
    }

    @Test("The before-browser copy names each team when given, and falls back when empty")
    func beforeBrowserCopyNamesTeamsOrFallsBack() {
        #expect(LinearInstallCopy.beforeBrowser(teams: []).contains("choose the teams your Projects use"))
    }

    @Test("The ports-busy copy names each port and its holder, or just the port with no holder")
    func portsBusyCopyNamesPortsAndHolders() {
        let copy = LinearInstallCopy.portsBusy([
            (port: 44837, holder: PortHolder(pid: 123, command: "Fugu")),
            (port: 44838, holder: nil)
        ])
        #expect(copy.contains("44837 is held by Fugu (pid 123)"))
        #expect(copy.contains("44838 is busy"))
    }
}
