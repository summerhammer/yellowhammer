import Foundation
import Showcase

// showcase-journals <output-dir> [--now <epoch>] | --self-test
//
// Writes the stub-data configuration directories `<output-dir>/morning` and `<output-dir>/working` for the
// landing page's screenshots, then reads them back and checks every fact the screenshots rely on.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("showcase-journals: \(message)\n".utf8))
    exit(1)
}

let usage = "usage: showcase-journals <output-dir> [--now <epoch>] | --self-test"
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--self-test"] {
        try Showcase.selfTestDaylightSaving()
        print("self-test passed: a clock change leaves the Night at 22:00 to 06:00 local time")
    } else {
        var now = Date()
        var output: String?
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if argument == "--now" {
                guard let text = remaining.popFirst(), let seconds = Int(text) else {
                    fail("--now needs epoch seconds")
                }
                now = Date(timeIntervalSince1970: TimeInterval(seconds))
            } else if output == nil, !argument.hasPrefix("--") {
                output = argument
            } else {
                fail("unexpected argument \(argument)\n\(usage)")
            }
        }
        guard let output else { fail(usage) }
        let directory = URL(filePath: output, directoryHint: .isDirectory)
        try Showcase.write(to: directory, now: now)
        try Showcase.verify(directory: directory, now: now)
        let morning = directory.appending(component: "morning").path
        let working = directory.appending(component: "working").path
        print("wrote and verified:\n  \(morning)\n  \(working)")
    }
} catch {
    fail("\(error)")
}
