import ArgumentParser
import Config
import Foundation
import Journal
import Subprocess
import System

/// The read-only capability handshake for another installed engine. Older copies without this command
/// cannot be proved safe when a Journal exists; doctor leaves their jobs untouched in that case.
struct JournalSchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "journal-schema", shouldDisplay: false)

    func run() throws {
        let metadata = ScheduledExecutable.Metadata(schema: JournalStore.migrationIdentifiers.last ?? "unknown")
        print(String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "{}")
    }
}

enum ScheduledExecutable {
    enum State { case missing, mismatched, running }
    struct Metadata: Codable, Sendable { let schema: String }
    struct Refusal: Error, CustomStringConvertible { let description: String }

    static func resolved(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    static func installedPath(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let path = (plist["ProgramArguments"] as? [Any])?.first as? String,
              !path.isEmpty else { return nil }
        return path
    }

    static func inspect(_ path: String?, running: String, fileExists: (String) -> Bool) -> State {
        guard let path, path.hasPrefix("/"), fileExists(path) else { return .missing }
        return resolved(path) == resolved(running) ? .running : .mismatched
    }

    static func description(_ path: String) -> String {
        let executable = URL(filePath: resolved(path))
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let infoURL = bundle.appending(components: "Contents", "Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
        }
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "\(path) (version \(version))"
    }

    static func validateLocation(_ path: String, homeDirectory: URL, output: (String) -> Void) throws {
        if path.split(separator: "/").contains("AppTranslocation") {
            throw Refusal(description: "translocated bundle; move Yellowhammer.app to /Applications "
                + "or ~/Applications in the Finder and open it again")
        }
        let userApplications = homeDirectory.appending(component: "Applications").path(percentEncoded: false) + "/"
        if !path.hasPrefix("/Applications/"), !path.hasPrefix(userApplications) {
            output("Warning: scheduled jobs name \(path) outside /Applications or ~/Applications; "
                + "moving or renaming the app stops this Project's Nights until jobs are regenerated.")
        }
    }

    static func validateSchema(_ candidate: String?, journal: String) throws {
        let prefix = "journal-schema-"
        let current = candidate.flatMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
        let applied = journal.hasPrefix(prefix) ? Int(journal.dropFirst(prefix.count)) : nil
        let legacy = journal.wholeMatch(of: /v\d+-.*/) != nil
        guard let current, current > 0, legacy || (applied.map { $0 > 0 && current >= $0 } == true) else {
            throw Refusal(description: "engine schema \(candidate ?? "unknown") "
                + "cannot schedule Journal schema \(journal); "
                + "use an engine at least as new as the Journal")
        }
    }

    /// Bounded subprocess query: a copied executable never gets to hang doctor or flood its output.
    static func schema(_ path: String) async -> String? {
        await querySchema(path, timeout: 5)
    }

    static func querySchema(_ path: String, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: Metadata?.self) { group in
            group.addTask { await metadata(path) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first.flatMap { $0 }?.schema
        }
    }

    private static func metadata(_ path: String) async -> Metadata? {
        var options = PlatformOptions()
        options.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .milliseconds(50))]
        do {
            let result = try await Subprocess.run(
                .path(FilePath(path)), arguments: ["journal-schema"], platformOptions: options,
                input: .none, output: .bytes(limit: 4096), error: .bytes(limit: 4096)
            )
            guard result.terminationStatus == .exited(0) else { return nil }
            return try? JSONDecoder().decode(Metadata.self, from: Data(result.standardOutput))
        } catch {
            return nil
        }
    }
}
