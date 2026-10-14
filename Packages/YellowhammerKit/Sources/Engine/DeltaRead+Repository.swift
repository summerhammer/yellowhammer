import Foundation

// The repository line parser for the Card's Managed Block (roadmap P5.6; issue #446) — split out to
// keep DeltaRead.swift under the file-length limit.

extension DeltaRead {
    /// The repository a rendered Managed Block names on its `Repository:` line — the line the Card's
    /// block renders (roadmap P5.6) as `**Repository:** `name``. Bold and backticks are optional, so
    /// an Operator who retyped the line is still read. Nil when the block has no such line. Ignores
    /// lines inside Architectural Brief prose, Transcription Blocks and code blocks (issues #446, #490).
    static func repository(inBlock block: String) -> String? {
        let normalized = block.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let masked = ArchitecturalBriefProseRegion.structureMasks(lines)

        var inCodeFence: (character: Character, count: Int)?

        for (index, line) in lines.enumerated() {
            if masked.contains(index) {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let currentFence = inCodeFence {
                let fenceCount = trimmed.prefix(while: { $0 == currentFence.character }).count
                if fenceCount >= currentFence.count {
                    let remainder = trimmed.dropFirst(fenceCount).trimmingCharacters(in: .whitespaces)
                    if remainder.isEmpty {
                        inCodeFence = nil
                    }
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                inCodeFence = ("`", trimmed.prefix(while: { $0 == "`" }).count)
                continue
            }
            if trimmed.hasPrefix("~~~") {
                inCodeFence = ("~", trimmed.prefix(while: { $0 == "~" }).count)
                continue
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                continue
            }

            guard let name = repositoryName(onLine: trimmed) else { continue }
            return name
        }
        return nil
    }

    /// Extracts the repository name from a candidate line, or nil if the line is not a valid
    /// `Repository:` declaration.
    private static func repositoryName(onLine trimmed: String) -> String? {
        var text = Substring(trimmed)
        if text.hasPrefix("- ") || text.hasPrefix("* ") {
            text = text.dropFirst(2).drop(while: { $0.isWhitespace })
        }
        text = text.drop(while: { $0 == "*" || $0 == "_" })
        guard text.lowercased().hasPrefix("repository") else { return nil }
        text = text.dropFirst("repository".count)
        text = text.drop(while: { $0 == "*" || $0 == "_" || $0.isWhitespace })
        guard text.first == ":" else { return nil }
        text = text.dropFirst()
        text = text.drop(while: { $0 == "*" || $0 == "_" || $0.isWhitespace })

        let isBackticked = text.first == "`"
        if isBackticked {
            text = text.dropFirst()
        }

        let name = text.prefix(while: { !$0.isWhitespace && $0 != "`" && $0 != "*" && $0 != "_" })
        guard !name.isEmpty else { return nil }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return nil
        }

        var remainder = text.dropFirst(name.count)
        if isBackticked {
            guard remainder.first == "`" else { return nil }
            remainder = remainder.dropFirst()
        }
        remainder = remainder.drop(while: { $0 == "*" || $0 == "_" || $0.isWhitespace })
        guard remainder.isEmpty else { return nil }

        return String(name)
    }
}
