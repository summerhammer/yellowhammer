@testable import EngineCommand
import Testing

// roadmap P17.6 slice (a) (spec: board-projection/install-the-linear-app "A non-admin Operator"): the
// non-admin copy is quoted verbatim in the story — asserted in full so a `\`-continuation edit cannot
// silently gain or lose a word or a space.

@Suite("LinearInstallCopy (P17.6)")
struct LinearInstallCopyTests {
    @Test("The non-admin copy matches the story verbatim")
    func nonAdminCopyIsVerbatim() {
        #expect(LinearInstallCopy.nonAdmin == """
        Installing Yellowhammer in your Linear workspace needs a workspace admin. Ask an admin to sign in \
        when the browser opens on this Mac, then approve the install. Afterwards Yellowhammer acts as its \
        own app user; the admin's account is not used again.
        """)
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
