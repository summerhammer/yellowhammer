import Config
import Foundation

private enum InstallAction: Equatable { case install, present, differs }

extension Setup {
    /// `--config <path>`: adopts a prepared configuration directory before step 1. Refuses — nothing
    /// written — when the prepared directory does not validate, or when any destination file already
    /// differs from its prepared counterpart. Byte-identical files are reported `present`; missing ones
    /// `installed`. A source that already equals `configurationDirectory` is a no-op: every file
    /// compares identical to itself.
    func installPreparedConfiguration(from source: URL) throws {
        let prepared: Configuration
        do {
            prepared = try Configuration.load(directory: source)
        } catch {
            throw SetupError("\(source.path(percentEncoded: false)) is invalid: \(error)")
        }
        guard prepared.invalidProjects.isEmpty else {
            throw SetupError(invalidPreparedConfigurationMessage(prepared, source: source))
        }

        let plan = try planInstall(from: source)
        let differing = plan.filter { $0.action == .differs }
        guard differing.isEmpty else {
            let names = differing.map { $0.destination.path(percentEncoded: false) }.joined(separator: ", ")
            throw SetupError(
                "setup never overwrites configuration; these files already differ from " // glossary:ignore GL001
                    + "\(source.path(percentEncoded: false)): \(names)"
            )
        }
        for entry in plan {
            switch entry.action {
            case .install:
                try installFile(entry)
            case .present:
                output("present \(entry.destination.path(percentEncoded: false))")
            case .differs:
                break // already refused above
            }
        }
    }

    private func invalidPreparedConfigurationMessage(_ prepared: Configuration, source: URL) -> String {
        let details = prepared.invalidProjects.map { invalid in
            "\(invalid.file):\n" + invalid.errors.map { "  \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n")
        return "\(source.path(percentEncoded: false)) has invalid Projects:\n\(details)" // glossary:ignore GL001
    }

    private struct InstallEntry {
        let source: URL
        let destination: URL
        let action: InstallAction
    }

    private func planInstall(from source: URL) throws -> [InstallEntry] {
        var entries: [InstallEntry] = [
            try planFile(
                source: source.appending(component: "config.toml", directoryHint: .notDirectory),
                destination: machineFileURL
            )
        ]
        let sourceProjects = source.appending(component: "projects", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: sourceProjects.path(percentEncoded: false)
        )) ?? []
        for name in names.sorted() where name.hasSuffix(".toml") {
            entries.append(try planFile(
                source: sourceProjects.appending(component: name, directoryHint: .notDirectory),
                destination: configurationDirectory.appending(
                    components: "projects", name, directoryHint: .notDirectory
                )
            ))
        }
        return entries
    }

    private func planFile(source: URL, destination: URL) throws -> InstallEntry {
        let destinationPath = destination.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: destinationPath) else {
            return InstallEntry(source: source, destination: destination, action: .install)
        }
        let sourceData: Data
        let destinationData: Data
        do {
            sourceData = try Data(contentsOf: source)
            destinationData = try Data(contentsOf: destination)
        } catch {
            throw SetupError("could not compare \(destinationPath): \(error)")
        }
        let isMachineFile = destination == machineFileURL
        let identical = sourceData == destinationData
            || (isMachineFile && differsOnlyByOperator(source: sourceData, destination: destinationData))
        return InstallEntry(source: source, destination: destination, action: identical ? .present : .differs)
    }

    /// Setup itself writes `[linear].operator` into the installed machine file (step 3), so a prepared
    /// `config.toml` without it must still compare `present` on the next identical run: the destination
    /// counts as unchanged when it is exactly the prepared text with that one line set.
    private func differsOnlyByOperator(source: Data, destination: Data) -> Bool {
        guard let sourceText = String(data: source, encoding: .utf8),
              let destinationText = String(data: destination, encoding: .utf8),
              let installed = try? MachineConfiguration.parse(
                  destinationText, file: machineFileURL.path(percentEncoded: false)
              ),
              let operatorIdentity = installed.operatorIdentity
        else { return false }
        return MachineConfiguration.settingOperator(operatorIdentity, inFileText: sourceText) == destinationText
    }

    private func installFile(_ entry: InstallEntry) throws {
        let destinationPath = entry.destination.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: entry.destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: entry.source, to: entry.destination)
        } catch {
            throw SetupError("could not install \(destinationPath): \(error)")
        }
        output("installed \(destinationPath)")
    }
}
