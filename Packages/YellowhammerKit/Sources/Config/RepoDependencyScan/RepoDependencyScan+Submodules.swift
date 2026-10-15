import Domain
import Foundation

// `.gitmodules`: each submodule naming a sibling by URL. A submodule is a commit pin unless it follows a branch.

extension RepoDependencyScan {
    static func scanSubmodules(_ context: Context, into sink: inout Sink) {
        guard let text = scanText(of: ".gitmodules", in: context, into: &sink) else { return }
        var section: String?
        var url: String?
        var branch: String?

        func flush() {
            defer { (url, branch) = (nil, nil) }
            guard let section, let url, let sibling = context.sibling(url: url) else { return }
            sink.findings.append(Finding(
                producer: sibling.name, via: branch == nil ? nil : .mainline, file: ".gitmodules",
                reference: "submodule \"\(section)\": url = \(url)" + (branch.map { ", branch = \($0)" } ?? "")
            ))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                section = submoduleName(inHeader: line)
            } else if let (key, value) = keyValue(line) {
                if key == "url" { url = value } else if key == "branch" { branch = value }
            }
        }
        flush()
    }

    private static func submoduleName(inHeader line: String) -> String? {
        guard line.hasPrefix("[submodule"), let open = line.firstIndex(of: "\""),
              let close = line.lastIndex(of: "\""), open < close
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}
