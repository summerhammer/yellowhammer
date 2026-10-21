import Domain
import Foundation

/// A minimal text edit of a Project file: adds Board Mapping entries and leaves every other byte alone.
public enum BoardMappingFileEdit {
    /// `text` with `entries` added under `[board.linear.mapping]`: right after the header when the file has
    /// one, else as a new table at the end of the file. Existing lines, comments and key order are kept; an
    /// entry is never overwritten (the caller adds only roles the file does not map). The result is validated
    /// by the loader when saved (``Configuration/save(_:to:in:replacing:)``).
    public static func adding(_ entries: [(role: BoardMappingRole, id: BoardObjectID)], to text: String) -> String {
        let lines = entries.map { "\($0.role.rawValue) = \"\($0.id.rawValue)\"" }
        var existing = text.components(separatedBy: "\n")
        if let header = existing.firstIndex(where: { isMappingHeader($0) }) {
            existing.insert(contentsOf: lines, at: header + 1)
            return existing.joined(separator: "\n")
        }
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + (["[board.linear.mapping]"] + lines).joined(separator: "\n") + "\n"
    }

    private static func isMappingHeader(_ line: String) -> Bool {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return code.trimmingCharacters(in: .whitespaces) == "[board.linear.mapping]"
    }
}
