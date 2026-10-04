import Foundation

/// Why an edit made through the app's form was not saved.
public enum ConfigurationEditError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file no longer holds the text the edit started from: edited directly in the meantime.
    case changedOnDisk(file: String)
    /// The loader refused the edit; its own errors, never empty.
    case refused([ConfigurationError])
    case unwritable(file: String, message: String)

    public var description: String {
        switch self {
        case .changedOnDisk(let file):
            return "\(file) changed on disk since it was opened; reopen it to see the change."
        case .refused(let errors):
            return errors.map(\.description).joined(separator: "\n")
        case .unwritable(let file, let message):
            return "\(file) could not be written: \(message)"
        }
    }
}

extension Configuration {
    /// Validates `text` — an edit of `file`, one of `directory`'s configuration files — against the
    /// loader before writing it, so the app never writes text the loader would refuse.
    ///
    /// In order:
    /// 1. `file` must still hold `originalText` (direct TOML editing stays supported; the app must
    ///    never clobber a hand edit it did not see) — otherwise ``ConfigurationEditError/changedOnDisk(file:)``.
    ///    A nil `originalText` means the edit started from no file at all: `file` must still not exist, and
    ///    is created, along with `directory`, only then.
    /// 2. `text` is loaded in place of `file`; a refusal is reported as
    ///    ``ConfigurationEditError/refused(_:)``.
    /// 3. Every Project newly invalid under `text` — the edited Project itself, or a sibling a
    ///    machine-file edit or a working-Repo clash invalidated — is also reported as `.refused`,
    ///    naming that Project's own file.
    /// Nothing is written unless every check passes.
    public static func save(
        _ text: String, to file: URL, in directory: URL, replacing originalText: String?
    ) throws(ConfigurationEditError) {
        let editedFile = file.path(percentEncoded: false)

        let currentText = try? String(contentsOf: file, encoding: .utf8)
        guard currentText == originalText else {
            throw ConfigurationEditError.changedOnDisk(file: editedFile)
        }

        // A Project already invalid before the edit is not this edit's fault; only newly invalid
        // Projects count as refused below. When the file's own original text does not even load
        // (e.g. it is a freshly broken machine file), treat the set of already-invalid Projects as
        // empty: everything after the edit is then judged against a clean slate.
        let before = originalText.flatMap { try? Configuration.load(directory: directory, reading: file, as: $0) }
        let alreadyInvalidFiles = Set((before?.invalidProjects ?? []).map(\.file))

        let after: Configuration
        do {
            after = try Configuration.load(directory: directory, reading: file, as: text)
        } catch {
            throw ConfigurationEditError.refused([error])
        }

        let offending = after.invalidProjects.filter { invalid in
            invalid.file == editedFile || !alreadyInvalidFiles.contains(invalid.file)
        }
        guard offending.isEmpty else {
            throw ConfigurationEditError.refused(offending.flatMap(\.errors))
        }

        do {
            if originalText == nil {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            }
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw ConfigurationEditError.unwritable(file: editedFile, message: error.localizedDescription)
        }
    }
}
