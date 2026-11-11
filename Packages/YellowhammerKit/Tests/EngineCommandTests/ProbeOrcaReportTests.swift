import Domain
@testable import EngineCommand
import Foundation
import Ledger
import Testing

@Suite("Orca Probe report")
struct ProbeOrcaReportTests {
    @Test("Yes, no and unconfirmed observations are printed and never change the verdict")
    func reporting() {
        let result = ProbeRecording.probeResult(
            cli: "codex", probedAt: Date(), adapterVersion: "4", cliVersion: "1",
            unattendedDispatch: .passed, resultFileOnCleanExit: .passed, processContainment: .passed,
            sessionResumption: .passed, stateContainment: .passed, sessionNaming: .notRun,
            orca: .init(
                tabRecognition: .init(.passed), sessionHistory: .init(.notRun, detail: "search disabled"),
                sessionName: .init(.failed), foreignTurnMarker: .init(.passed)
            ), reason: nil
        )
        let lines = ProbeCommand.reportLines(result, drift: nil)
        #expect(lines.contains("recognised in an Orca tab: yes"))
        #expect(lines.contains("listed in Agent Session History: unconfirmed"))
        #expect(lines.contains("session name shown in Orca: no"))
        #expect(lines.contains("foreign-turn marker found: yes"))
        #expect(lines.contains("  search disabled"))
        #expect(lines.contains { $0.contains("known behaviour; routing is unchanged") })
        #expect(result.verdict == .passed)
        #expect(!ProbeCommand.everyFindingPassed(result))
    }
}
