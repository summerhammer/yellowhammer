import Foundation

/// A fresh directory tree standing in for a Mac: a home, bin directories, and fixture executables.
struct CLIDiscoveryFixture {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yh-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so realpath comparisons are exact.
        root = realpath(base.path, nil).map { String(cString: $0) } ?? base.path
    }

    var home: String { "\(root)/home" }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func directory(_ path: String) throws -> String {
        let full = path.hasPrefix("/") ? path : "\(root)/\(path)"
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    /// A `#!/bin/sh` script (or other `contents`) at `path` under the root, mode `mode`.
    @discardableResult
    func file(_ path: String, contents: String = "#!/bin/sh\nexit 0\n", mode: Int = 0o755) throws -> String {
        let full = path.hasPrefix("/") ? path : "\(root)/\(path)"
        try directory((full as NSString).deletingLastPathComponent)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: full))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: full)
        return full
    }

    /// Bytes that are not a `#!` script.
    @discardableResult
    func binary(_ path: String) throws -> String {
        try file(path, contents: "\u{7F}ELF-not-a-script\n")
    }

    func symlink(_ path: String, to target: String) throws {
        let full = "\(root)/\(path)"
        try directory((full as NSString).deletingLastPathComponent)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: target)
    }
}
