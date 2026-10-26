import CLIAdapters
import Domain
import Engine
import Foundation

/// The real Route Pre-flight seam (OQ126): resolves the CLI Adapter and executable a Route names the way
/// ``CLIAdapterDispatch`` does, then runs ``CLIRoutePreflight`` in a directory of its own under the
/// Project's runs directory, `<runID>/preflight/<uuid>`. A Route with no adapter or no executable fails its
/// pre-flight: it could not be dispatched either.
struct CLIAdapterRoutePreflight: RoutePreflighting {
    let projectID: ProjectID
    let runsDirectory: URL
    let declaredExecutables: [String: String]
    let path: String?
    let environment: [String: String]
    let preflight: CLIRoutePreflight

    init(
        projectID: ProjectID,
        runsDirectory: URL,
        declaredExecutables: [String: String] = [:],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preflight: CLIRoutePreflight = CLIRoutePreflight()
    ) {
        self.projectID = projectID
        self.runsDirectory = runsDirectory
        self.declaredExecutables = declaredExecutables
        self.path = path
        self.environment = environment
        self.preflight = preflight
    }

    var dispatchesAgentCLI: Bool { true }

    func preflight(
        _ route: Route, runID: RunID, nightID: Int64?, recordID: String
    ) async throws -> RoutePreflightVerdict {
        guard let adapter = CLIAdapterRegistry.adapter(named: route.cli) else {
            return .failed(reason: "no CLI Adapter for `\(route.cli)`")
        }
        guard let executable = ProbeExecutable.resolve(
            name: route.cli, declared: declaredExecutables[route.cli], path: path,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else {
            return .failed(reason: "no executable found for `\(route.cli)`")
        }
        let workDirectory = runsDirectory
            .appending(components: runID.rawValue, "preflight", UUID().uuidString, directoryHint: .isDirectory)
        if let reason = await preflight.run(
            adapter: adapter, route: route, executable: executable, environment: environment,
            workDirectory: workDirectory,
            projectID: projectID.rawValue,
            runID: runID.rawValue,
            nightID: nightID,
            recordID: recordID
        ) {
            return .failed(reason: reason)
        }
        return .passed()
    }
}
