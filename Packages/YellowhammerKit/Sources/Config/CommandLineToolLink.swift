import Darwin
import Foundation

/// One observed state of the Command Line Tool symlink (typically `/usr/local/bin/yh`).
public enum CommandLineToolLinkState: Equatable, Sendable {
    /// Nothing exists at the path (`lstat` returns ENOENT).
    case notInstalled
    /// A symlink whose canonical path equals the running executable's canonical path.
    case installed
    /// A symlink whose target does not exist.
    case dangling(target: String)
    /// A symlink that resolves to any other file, or a non-symlink file at the path (naming its path).
    case mismatched(target: String)
}

/// Errors raised by ``CommandLineToolLink`` operations.
public enum CommandLineToolLinkError: Error, CustomStringConvertible, Equatable {
    case parentDirectoryNotWritable(String)
    case refusedNonSymlink(String)
    case refusedIneligibleSymlink(path: String, target: String)
    case notInstalled(String)
    case verificationFailed(String)
    case systemError(Int32, String)

    public var description: String {
        switch self {
        case .parentDirectoryNotWritable(let dir):
            return "directory \(dir) does not exist or is not writable by the current user"
        case .refusedNonSymlink(let path):
            return "refusing to replace non-symlink file at \(path)"
        case .refusedIneligibleSymlink(let path, let target):
            return "refusing to remove symlink at \(path) pointing to \(target)"
        case .notInstalled(let path):
            return "nothing exists at \(path)"
        case .verificationFailed(let path):
            return "verification failed for symlink at \(path): mode is not 0755"
        case .systemError(let code, let msg):
            return "\(msg) (errno \(code))"
        }
    }
}

/// The link primitive in the Config module that inspects, creates, repoints, and removes a world-readable
/// Command Line Tool symlink (OQ124 ruling, 2026-10-05).
///
/// Default location is `/usr/local/bin/yh`. Injectable for testing and UI test overrides.
public struct CommandLineToolLink: Sendable {
    public static let defaultPath = "/usr/local/bin/yh"
    public static let defaultDirectory = "/usr/local/bin"

    /// The UI-test argument override name (`-YellowhammerCommandLineToolLink <path>`).
    public static let linkOverrideArgument = "YellowhammerCommandLineToolLink"

    /// The path override passed via argument domain, if any.
    public static var overrideLinkPath: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[linkOverrideArgument] as? String
    }

    /// Whether an argument-domain override is active.
    public static var isOverridden: Bool {
        overrideLinkPath != nil
    }

    public let linkPath: String

    public init(path: String = Self.defaultPath) {
        self.linkPath = path
    }

    public var parentDirectory: String {
        (linkPath as NSString).deletingLastPathComponent
    }

    /// Whether the parent directory exists and is writable by the current user (`access(…, W_OK)`).
    public var isParentDirectoryWritable: Bool {
        access(parentDirectory, W_OK) == 0
    }

    /// Whether the parent directory exists on disk.
    public var parentDirectoryExists: Bool {
        access(parentDirectory, F_OK) == 0
    }

    /// Whether a file exists at `linkPath` and is a symbolic link.
    public var isSymlink: Bool {
        var st = stat()
        return lstat(linkPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Inspects the link path relative to the running `yh` executable.
    public func inspect(runningExecutable: String) -> CommandLineToolLinkState {
        var st = stat()
        guard lstat(linkPath, &st) == 0 else {
            return .notInstalled
        }

        let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
        guard isSymlink else {
            // A non-symlink file at the path is reported as mismatched, naming the path.
            return .mismatched(target: linkPath)
        }

        let rawTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) ?? ""
        var targetSt = stat()
        // `stat` follows symlinks: non-zero means target does not exist.
        guard stat(linkPath, &targetSt) == 0 else {
            return .dangling(target: rawTarget)
        }

        let linkResolved = ExecutableFile.resolvedPath(linkPath)
        let runningResolved = ExecutableFile.resolvedPath(runningExecutable) ?? runningExecutable

        if let linkResolved, linkResolved == runningResolved {
            return .installed
        }
        return .mismatched(target: linkResolved ?? rawTarget)
    }

    /// Unprivileged install or repoint: creates a symlink under a temporary name in the same directory,
    /// renames it over `linkPath`, then `lchmod`s it to `0755` (`0o755`).
    ///
    /// Refuses to replace a non-symlink file.
    public func install(target: String) throws {
        guard isParentDirectoryWritable else {
            throw CommandLineToolLinkError.parentDirectoryNotWritable(parentDirectory)
        }

        var st = stat()
        if lstat(linkPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFLNK else {
                throw CommandLineToolLinkError.refusedNonSymlink(linkPath)
            }
        }

        let tempPath = "\(linkPath).tmp.\(ProcessInfo.processInfo.globallyUniqueString)"
        guard symlink(target, tempPath) == 0 else {
            throw CommandLineToolLinkError.systemError(errno, "could not create temporary symlink at \(tempPath)")
        }

        guard rename(tempPath, linkPath) == 0 else {
            let renameErrno = errno
            unlink(tempPath)
            throw CommandLineToolLinkError.systemError(renameErrno, "could not rename symlink over \(linkPath)")
        }

        guard lchmod(linkPath, 0o755) == 0 else {
            throw CommandLineToolLinkError.systemError(errno, "could not set symlink mode 0755 via lchmod")
        }

        var verifySt = stat()
        guard lstat(linkPath, &verifySt) == 0, (verifySt.st_mode & 0o777) == 0o755 else {
            throw CommandLineToolLinkError.verificationFailed(linkPath)
        }
    }

    /// Checks whether the existing file is eligible for uninstallation:
    /// must be a symlink whose raw destination path ends in `/Contents/MacOS/yh`.
    public func checkUninstallEligibility() throws {
        var st = stat()
        guard lstat(linkPath, &st) == 0 else {
            throw CommandLineToolLinkError.notInstalled(linkPath)
        }
        guard (st.st_mode & S_IFMT) == S_IFLNK else {
            throw CommandLineToolLinkError.refusedNonSymlink(linkPath)
        }
        let rawTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) ?? ""
        guard rawTarget.hasSuffix("/Contents/MacOS/yh") else {
            throw CommandLineToolLinkError.refusedIneligibleSymlink(path: linkPath, target: rawTarget)
        }
    }

    /// Unprivileged uninstall: removes the symlink after verifying eligibility and directory writability.
    public func uninstall() throws {
        try checkUninstallEligibility()
        guard isParentDirectoryWritable else {
            throw CommandLineToolLinkError.parentDirectoryNotWritable(parentDirectory)
        }
        guard unlink(linkPath) == 0 else {
            throw CommandLineToolLinkError.systemError(errno, "could not unlink \(linkPath)")
        }
    }

    /// One source for the privileged install shell command string:
    /// `/bin/mkdir -p -m 0755 <parent> && /bin/ln -sfh <target> <linkPath> && /bin/chmod -h 0755 <linkPath>`.
    public func privilegedInstallCommand(target: String) -> String {
        let parent = Self.shellQuote(parentDirectory)
        let link = Self.shellQuote(linkPath)
        let tgt = Self.shellQuote(target)
        if parentDirectory == Self.defaultDirectory && linkPath == Self.defaultPath {
            return "/bin/mkdir -p -m 0755 /usr/local/bin && /bin/ln -sfh \(tgt) /usr/local/bin/yh && /bin/chmod -h 0755 /usr/local/bin/yh"
        }
        return "/bin/mkdir -p -m 0755 \(parent) && /bin/ln -sfh \(tgt) \(link) && /bin/chmod -h 0755 \(link)"
    }

    /// One source for the privileged uninstall shell command string:
    /// `/bin/rm -f <linkPath>` (only after unprivileged eligibility check passed).
    public func privilegedUninstallCommand() -> String {
        if linkPath == Self.defaultPath {
            return "/bin/rm -f /usr/local/bin/yh"
        }
        return "/bin/rm -f \(Self.shellQuote(linkPath))"
    }

    /// POSIX single-quote escaping for shell commands: wraps in single quotes and escapes single quotes as `'\\''`.
    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal escaping: escapes `\` as `\\` and `"` as `\"`.
    public static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The absolute path to the `yh` binary currently running, with all symlinks resolved via `realpath(3)`
    /// in every branch (including `argv[0]`).
    ///
    /// Invoking `yh` through `/usr/local/bin/yh` yields the bundle's `Contents/MacOS/yh`.
    public static func runningExecutablePath(
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        argv0: String? = CommandLine.arguments.first,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        if let bundleURL = bundleExecutableURL {
            let bundlePath = bundleURL.path(percentEncoded: false)
            if let resolved = ExecutableFile.resolvedPath(bundlePath) {
                return resolved
            }
            return bundlePath
        }
        let rawArgv0 = argv0 ?? "yh"
        let absolute: String
        if rawArgv0.hasPrefix("/") {
            absolute = rawArgv0
        } else {
            absolute = URL(filePath: rawArgv0, relativeTo: URL(filePath: currentDirectory)).path(percentEncoded: false)
        }
        if let resolved = ExecutableFile.resolvedPath(absolute) {
            return resolved
        }
        return absolute
    }
}
