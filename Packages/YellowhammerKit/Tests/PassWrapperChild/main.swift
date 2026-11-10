import CLIAdapters
import Foundation

// Test-only child process for PassWrapper tests; no product.
// Usage:
//   PassWrapperChild <specPath>
//   PassWrapperChild pass-wrapper <specPath>
let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: PassWrapperChild [pass-wrapper] <specPath>\n".utf8))
    exit(2)
}

let specPath: String
if arguments.count >= 3 && arguments[1] == "pass-wrapper" {
    specPath = arguments[2]
} else {
    specPath = arguments[1]
}

do {
    let outcome = try PassWrapper.run(specPath: specPath)
    let exitCode = outcome.exitStatus ?? (128 + (outcome.signal ?? 0))
    exit(exitCode)
} catch {
    FileHandle.standardError.write(Data("PassWrapperChild error: \(error)\n".utf8))
    exit(1)
}
