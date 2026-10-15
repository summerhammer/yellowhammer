import Domain
import Foundation

// `Package.swift`: every `.package(` call naming a sibling by `url:` or `path:`.

extension RepoDependencyScan {
    /// How a `.package(url:)` call pins its dependency.
    private enum Pin {
        case release, branch, commit, unknown
    }

    static func scanPackageSwift(_ context: Context, into sink: inout Sink) {
        guard let text = scanText(of: "Package.swift", in: context, into: &sink) else { return }
        for call in packageCalls(in: text) {
            let reference = call.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            func found(_ sibling: Sibling, _ via: RepoDependencyVia?) {
                sink.findings.append(Finding(
                    producer: sibling.name, via: via, file: "Package.swift", reference: reference
                ))
            }
            if let path = firstCapture(#"\bpath:\s*"([^"]+)""#, in: call) {
                if let sibling = context.sibling(path: path) { found(sibling, .mainline) }
                continue
            }
            guard let url = firstCapture(#"\burl:\s*"([^"]+)""#, in: call),
                  let sibling = context.sibling(url: url)
            else { continue }
            switch pin(of: call) {
            case .release: found(sibling, .tag)
            case .branch: found(sibling, .mainline)
            case .commit: found(sibling, nil)
            case .unknown: break
            }
        }
    }

    private static func pin(of call: String) -> Pin {
        if call.contains("revision:") || call.contains(".revision(") { return .commit }
        if call.contains("branch:") || call.contains(".branch(") { return .branch }
        let releaseMarkers = ["from:", "exact:", ".upToNextMajor(", ".upToNextMinor(", ".exact("]
        if releaseMarkers.contains(where: call.contains) { return .release }
        if call.range(of: #""[^"]*"\s*\.\.[.<]\s*"[^"]*""#, options: .regularExpression) != nil { return .release }
        return .unknown
    }

    /// The text of each `.package(...)` call, parentheses balanced outside string literals, comment lines dropped.
    static func packageCalls(in source: String) -> [String] {
        let text = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let characters = Array(text)
        let marker = Array(".package(")
        var calls: [String] = []
        var index = 0
        while index + marker.count <= characters.count {
            guard Array(characters[index..<index + marker.count]) == marker,
                  let end = closingParenthesis(in: characters, openingAt: index + marker.count - 1)
            else {
                index += 1
                continue
            }
            calls.append(String(characters[index...end]))
            index = end + 1
        }
        return calls
    }

    private static func closingParenthesis(in characters: [Character], openingAt start: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 1 } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
