import Config
import Domain
import Foundation

extension Doctor {
    /// Check 1: `Configuration.load(directory:)`. A machine-file error is a failure and stops every
    /// later check — every one of them needs configuration. Each invalid Project is a failure listing
    /// its file and errors; each valid Project is a pass. Routing warnings follow
    /// `Setup.reportRoutingWarnings` exactly: per Project when there are any, the machine's base
    /// Routing Table when there are none (routing/overview, OQ13, OQ154).
    func runConfigurationCheck(into findings: inout [DoctorFinding]) -> Configuration? {
        let configuration: Configuration
        do {
            configuration = try Configuration.load(directory: configurationDirectory)
        } catch {
            findings.append(finding(
                .configuration, subject: machineFileURL.path(percentEncoded: false), .failure,
                "\(machineFileURL.path(percentEncoded: false)) is invalid: \(error)"
            ))
            return nil
        }

        for invalid in configuration.invalidProjects {
            let errors = invalid.errors.map { "\($0)" }.joined(separator: "; ")
            findings.append(finding(
                .configuration, subject: invalid.file, .failure, "\(invalid.file): \(errors)",
                project: projectID(forInvalid: invalid)
            ))
        }
        for project in configuration.projects {
            findings.append(finding(
                .configuration, subject: project.id.rawValue, .pass,
                "Project \(project.id) is valid", // glossary:ignore GL001
                project: project.id
            ))
        }
        findings.append(contentsOf: routingWarnings(configuration: configuration))
        return configuration
    }

    /// `invalid.id` when known, else the id parsed from the file's last path component
    /// (`<id>.toml`), matching `Status.matchesFilter`'s rule — nil when neither is available.
    func projectID(forInvalid invalid: InvalidProject) -> ProjectID? {
        if let id = invalid.id {
            return id
        }
        let name = (invalid.file as NSString).lastPathComponent
        guard name.hasSuffix(".toml") else { return nil }
        return ProjectID(rawValue: String(name.dropLast(".toml".count)))
    }

    private func routingWarnings(configuration: Configuration) -> [DoctorFinding] {
        guard !configuration.projects.isEmpty else {
            return configuration.machine.routingTable.warnings.map {
                finding(.configuration, subject: "routing", .warning, "\($0)")
            }
        }
        var warnings: [DoctorFinding] = []
        for project in configuration.projects {
            for warning in configuration.routingTable(for: project.id)?.warnings ?? [] {
                warnings.append(finding(
                    .configuration, subject: project.id.rawValue, .warning,
                    "Project \(project.id): \(warning)", // glossary:ignore GL001
                    project: project.id
                ))
            }
        }
        return warnings
    }
}
