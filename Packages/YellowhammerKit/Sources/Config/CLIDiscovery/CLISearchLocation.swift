import Foundation

/// A directory worth probing for an agent CLI beyond the `PATH`: relative to the Operator's home directory,
/// absolute, or the `bin` directory inside each version a version manager has installed.
public enum CLISearchLocation: Equatable, Sendable {
    /// A directory relative to the home directory, such as `.local/bin`.
    case home(String)
    /// An absolute directory, such as `/opt/homebrew/bin`.
    case absolute(String)
    /// `<suffix>` inside every subdirectory of `<parent>` (relative to home), newest version first.
    case versions(parent: String, suffix: String)

    /// The directories this location stands for, in probe order. Reads the file system for ``versions``; a
    /// missing parent yields nothing. The directories are not checked to exist.
    public func directories(homeDirectory: String) -> [String] {
        switch self {
        case .home(let relative):
            return [ExecutableSearchPath.normalized("\(homeDirectory)/\(relative)")]
        case .absolute(let path):
            return [ExecutableSearchPath.normalized(path)]
        case .versions(let parent, let suffix):
            let parentPath = ExecutableSearchPath.normalized("\(homeDirectory)/\(parent)")
            let files = FileManager.default
            let names = (try? files.contentsOfDirectory(atPath: parentPath)) ?? []
            return names
                .filter { name in
                    var isDirectory: ObjCBool = false
                    return files.fileExists(atPath: "\(parentPath)/\(name)", isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
                .sorted(by: Self.isNewer)
                .map { ExecutableSearchPath.normalized("\(parentPath)/\($0)/\(suffix)") }
        }
    }

    /// Whether version directory name `lhs` sorts before `rhs`, newest first: a leading `v` is ignored and
    /// dot-separated numeric components compare as numbers; names that are not versions follow, lexically.
    static func isNewer(_ lhs: String, _ rhs: String) -> Bool {
        let left = components(of: lhs)
        let right = components(of: rhs)
        switch (left, right) {
        case (let left?, let right?):
            for index in 0..<max(left.count, right.count) {
                let lhsPart = index < left.count ? left[index] : 0
                let rhsPart = index < right.count ? right[index] : 0
                if lhsPart != rhsPart { return lhsPart > rhsPart }
            }
            return lhs < rhs
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs < rhs
        }
    }

    private static func components(of name: String) -> [Int]? {
        let stripped = name.hasPrefix("v") ? String(name.dropFirst()) : name
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
