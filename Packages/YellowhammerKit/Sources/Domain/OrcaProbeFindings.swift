/// A single informational observation. Unavailable evidence is never reported as a negative observation.
public struct ProbeObservation: Codable, Equatable, Sendable {
    public var finding: ProbeFinding
    public var detail: String?

    public init(_ finding: ProbeFinding = .notRun, detail: String? = nil) {
        self.finding = finding
        self.detail = detail
    }
}

/// Orca observations from a CLI Probe (OQ201). These never decide whether a Route is offered.
public struct OrcaProbeFindings: Codable, Equatable, Sendable {
    public var tabRecognition: ProbeObservation
    public var sessionHistory: ProbeObservation
    public var sessionName: ProbeObservation
    public var foreignTurnMarker: ProbeObservation
    public var tabCloseContainment: ProbeObservation
    public var hookTraffic: ProbeObservation

    public init(
        tabRecognition: ProbeObservation = .init(),
        sessionHistory: ProbeObservation = .init(),
        sessionName: ProbeObservation = .init(),
        foreignTurnMarker: ProbeObservation = .init(),
        tabCloseContainment: ProbeObservation = .init(),
        hookTraffic: ProbeObservation = .init()
    ) {
        self.tabRecognition = tabRecognition
        self.sessionHistory = sessionHistory
        self.sessionName = sessionName
        self.foreignTurnMarker = foreignTurnMarker
        self.tabCloseContainment = tabCloseContainment
        self.hookTraffic = hookTraffic
    }

    public var observations: [(String, ProbeObservation)] {
        [
            ("recognised in an Orca tab", tabRecognition),
            ("listed in Agent Session History", sessionHistory),
            ("session name shown in Orca", sessionName),
            ("foreign-turn marker found", foreignTurnMarker),
            ("Orca tab-close containment", tabCloseContainment),
            ("Orca localhost hook traffic", hookTraffic)
        ]
    }
}
