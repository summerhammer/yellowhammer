import Domain
import Foundation

// Generator scripts and configuration: a bounded sweep of the consumer's root and its first two directory levels
// for a line that names a sibling's path.

extension RepoDependencyScan {
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "node_modules", "DerivedData", "Pods", "vendor", ".swiftpm"
    ]
    private static let generatorExtensions: Set<String> = [
        "yaml", "yml", "toml", "json", "sh", "mk", "rb", "py", "swift"
    ]
    /// Handled by their own readers, or lock files that only repeat what those say.
    private static let handledElsewhere: Set<String> = ["package.json", "Package.swift", "package-lock.json"]
    private static let maximumLineLength = 160

    static func scanGenerators(_ context: Context, into sink: inout Sink) {
        for file in generatorFiles(under: context.root, relativeTo: "", depth: 0) {
            guard let text = scanText(of: file, in: context, into: &sink) else { continue }
            sink.findings += hits(in: text, file: file, context: context)
        }
    }

    /// Files relative to the root, in a stable order: this directory's files, then its subdirectories'.
    private static func generatorFiles(under directory: String, relativeTo prefix: String, depth: Int) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        var files: [String] = []
        var subdirectories: [String] = []
        for name in names.sorted() {
            let type = (try? manager.attributesOfItem(atPath: directory + "/" + name))?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if !skippedDirectories.contains(name) { subdirectories.append(name) }
            } else if type == .typeRegular, isGeneratorFile(name) {
                files.append(prefix + name)
            }
        }
        guard depth < 2 else { return files }
        return files + subdirectories.flatMap {
            generatorFiles(under: directory + "/" + $0, relativeTo: prefix + $0 + "/", depth: depth + 1)
        }
    }

    private static func isGeneratorFile(_ name: String) -> Bool {
        guard !handledElsewhere.contains(name) else { return false }
        return name == "Makefile" || generatorExtensions.contains((name as NSString).pathExtension)
    }

    /// The first line naming each sibling, as `<file>:<line number>` and the trimmed line.
    private static func hits(in text: String, file: String, context: Context) -> [Finding] {
        var found: [Finding] = []
        var named: Set<String> = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for sibling in context.siblings where !named.contains(sibling.name) && names(sibling, in: String(line)) {
                named.insert(sibling.name)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                found.append(Finding(
                    producer: sibling.name, via: .mainline, file: "\(file):\(offset + 1)",
                    reference: String(trimmed.prefix(maximumLineLength))
                ))
            }
        }
        return found
    }

    /// Whether `line` holds the sibling's absolute path, its `~` form, or `../<its last path component>`, as a
    /// whole path component: `/a/contracts` is not found in `/a/contracts-extra`.
    private static func names(_ sibling: Sibling, in line: String) -> Bool {
        let home = NSHomeDirectory()
        var absolute = [sibling.path]
        if sibling.path.hasPrefix(home + "/") { absolute.append("~" + sibling.path.dropFirst(home.count)) }
        let relative = "../" + (sibling.path as NSString).lastPathComponent
        return absolute.contains { contains(line, $0, checkingStart: true) }
            || contains(line, relative, checkingStart: false)
    }

    private static func contains(_ line: String, _ needle: String, checkingStart: Bool) -> Bool {
        var searchRange = line.startIndex..<line.endIndex
        while let found = line.range(of: needle, range: searchRange) {
            let startsClean = !checkingStart || found.lowerBound == line.startIndex
                || !isPathCharacter(line[line.index(before: found.lowerBound)])
            let endsClean = found.upperBound == line.endIndex || !isPathCharacter(line[found.upperBound], atEnd: true)
            if startsClean && endsClean { return true }
            searchRange = found.upperBound..<line.endIndex
        }
        return false
    }

    private static func isPathCharacter(_ character: Character, atEnd: Bool = false) -> Bool {
        if character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." {
            return true
        }
        return !atEnd && (character == "/" || character == "~")
    }
}
