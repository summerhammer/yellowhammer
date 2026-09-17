import Domain
import Foundation
import Ledger

/// Maps a CLI Probe's findings into a Ledger ``ProbeResult``. Takes the individual findings and
/// strings rather than `CLIAdapters.ProbeReport` itself, so this stays testable from
/// `EngineCommandTests` without that module importing `CLIAdapters` (MB2).
enum ProbeRecording {
    // swiftlint:disable:next function_parameter_count
    static func probeResult(
        cli: String,
        probedAt: Date,
        adapterVersion: String,
        cliVersion: String,
        unattendedDispatch: ProbeFinding,
        resultFileOnCleanExit: ProbeFinding,
        processContainment: ProbeFinding,
        sessionResumption: ProbeFinding,
        reason: String?
    ) -> ProbeResult {
        ProbeResult(
            cli: cli,
            probedAt: probedAt,
            adapterVersion: adapterVersion,
            cliVersion: cliVersion,
            findingResultFileOnCleanExit: resultFileOnCleanExit,
            findingUnattendedDispatch: unattendedDispatch,
            findingProcessContainment: processContainment,
            findingSessionResumption: sessionResumption,
            reason: reason
        )
    }
}
