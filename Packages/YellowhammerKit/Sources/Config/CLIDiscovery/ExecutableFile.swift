import Darwin
import Foundation

/// Questions about one file on disk that decide whether it can be an agent CLI: whether it can be run, where
/// it really lives, and whether it is a script or a binary. Reads the file system only; it never runs the file.
public enum ExecutableFile {
    /// The interpreter a `#!` script names.
    public struct Interpreter: Equatable, Sendable {
        /// The interpreter as written: `/bin/sh`, or `/usr/bin/env` for an env-interpreted script.
        public let path: String
        /// The program that runs the script: the interpreter's file name, or for `env` the program it looks up
        /// on `PATH` (`node` in `#!/usr/bin/env node`).
        public let program: String
        /// Whether the script is run through `env`, so it finds `program` only on the `PATH` it is started with.
        public let viaEnv: Bool

        public init(path: String, program: String, viaEnv: Bool) {
            self.path = path
            self.program = program
            self.viaEnv = viaEnv
        }
    }

    /// Whether `path` names a regular file the process may execute. `stat` follows symlinks; a directory with
    /// the execute bit set is not runnable.
    public static func isRunnable(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// `path` with every symlink resolved (`realpath(3)`); nil when it cannot be resolved.
    public static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The interpreter named by the file's `#!` line, from at most its first 256 bytes; nil for a binary, an
    /// unreadable file, or a `#!` line naming nothing.
    public static func interpreter(atPath path: String) -> Interpreter? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), data.starts(with: Data("#!".utf8)) else { return nil }
        // Only the first line is decoded: 256 bytes can end inside a multi-byte character further on.
        let lineBytes = data.dropFirst(2).prefix { $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "\r") }
        guard let line = String(bytes: lineBytes, encoding: .utf8) else { return nil }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let interpreter = words.first else { return nil }
        let name = (interpreter as NSString).lastPathComponent
        if name == "env" {
            // `env [-flags] [NAME=value ...] program`: the program is the first word that is neither.
            let program = words.dropFirst().first { !$0.hasPrefix("-") && !$0.contains("=") }
            guard let program else { return nil }
            return Interpreter(path: interpreter, program: program, viaEnv: true)
        }
        return Interpreter(path: interpreter, program: name, viaEnv: false)
    }
}
