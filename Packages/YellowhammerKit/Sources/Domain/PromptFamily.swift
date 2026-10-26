import Foundation

/// The families of prompts Yellowhammer manages.
///
/// Production families drive the author, execute and verifier loops and accept Project instructions.
/// Diagnostic families drive local preflight and containment probes and never accept Project instructions.
public enum PromptFamily: String, CaseIterable, Codable, Sendable {
    case selection
    case breakdown
    case architect
    case worker
    case reviewer
    case verifier
    case unattendedProbe = "unattended-probe"
    case sessionResumptionProbe = "session-resumption-probe"
    case routePreflight = "route-preflight"
    case processContainmentProbe = "process-containment-probe"
    case stateContainmentProbe = "state-containment-probe"

    /// True for diagnostic/preflight dispatches that have no Project.
    public var isDiagnostic: Bool {
        switch self {
        case .unattendedProbe, .sessionResumptionProbe, .routePreflight, .processContainmentProbe,
             .stateContainmentProbe:
            true
        case .selection, .breakdown, .architect, .worker, .reviewer, .verifier:
            false
        }
    }

    /// True for the six production families that accept Project instructions.
    public var acceptsProjectInstructions: Bool {
        switch self {
        case .selection, .breakdown, .architect, .worker, .reviewer, .verifier:
            true
        case .unattendedProbe, .sessionResumptionProbe, .routePreflight, .processContainmentProbe,
             .stateContainmentProbe:
            false
        }
    }

    /// The default version of the prompt family's text.
    ///
    /// It must change whenever that family's shipped text changes.
    public var defaultVersion: Int {
        1
    }

    /// Initializes a production family from a production pass. `reviewer` covers both Lenses.
    public init?(pass: RunPass) {
        switch pass {
        case .selection: self = .selection
        case .breakdown: self = .breakdown
        case .architect: self = .architect
        case .worker: self = .worker
        case .reviewer: self = .reviewer
        case .verifier: self = .verifier
        }
    }
}

/// Whether a pass was dispatched in a brand-new session or resumed an earlier pass's session.
public enum DispatchSession: String, CaseIterable, Codable, Equatable, Sendable {
    case new
    case resumed
}

/// The Project instructions revision used for a dispatch, or absence.
public enum ProjectInstructionsUse: Codable, Equatable, Sendable {
    case absent
    case revision(String)
}

/// The launch status of a dispatched pass.
public enum DispatchLaunch: Codable, Equatable, Sendable {
    case pending
    case launched
    case notLaunched(cause: String)
}

/// The result of capturing a dispatch prompt record.
public enum DispatchPromptCapture: Equatable, Sendable {
    case recorded(id: String)
    case unavailable(cause: String)
}

/// The storage scope of a dispatch prompt record: scoped to a Project or machine-wide diagnostic.
public enum DispatchPromptScope: Hashable, Sendable {
    case project(ProjectID)
    case machine

    public var projectID: ProjectID? {
        switch self {
        case .project(let id): id
        case .machine: nil
        }
    }
}
