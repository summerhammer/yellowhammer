import CLIAdapters
import Foundation
import Testing

@Suite("Pass wrapper launcher command")
struct PassWrapperLauncherTests {
    @Test("every argument survives a POSIX shell word for word, quotes and spaces included")
    func quotesEveryArgument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let echoArguments = directory.appendingPathComponent("it's echo")
        try "#!/bin/sh\nfor a; do printf '%s\\n' \"$a\"; done\n"
            .write(to: echoArguments, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: echoArguments.path)
        let scratch = URL(fileURLWithPath: "/private/var/it's a dir")
        let command = PassWrapper.launcherCommand(
            yhExecutable: echoArguments.path, cliExecutable: "/bin/c li", cliArguments: ["-p", "a 'b' $HOME `x`"],
            identityFile: scratch.appendingPathComponent("identity"),
            endingFile: scratch.appendingPathComponent("ending"),
            signalFile: scratch.appendingPathComponent("signals"),
            stdoutFile: scratch.appendingPathComponent("stdout"),
            workingDirectory: URL(fileURLWithPath: "/tmp/w t")
        )
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let output = try #require(String(bytes: data, encoding: .utf8))

        #expect(output.split(separator: "\n").map(String.init) == [
            "--_pass-wrapper", "/bin/c li", "/private/var/it's a dir/identity", "/private/var/it's a dir/ending",
            "/private/var/it's a dir/signals", "/private/var/it's a dir/stdout", "/tmp/w t", "-p", "a 'b' $HOME `x`"
        ])
    }
}
