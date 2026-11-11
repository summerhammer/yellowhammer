import Darwin
import EngineCommand

if CommandLine.arguments.dropFirst().first == "--_pass-wrapper" {
    exit(RootCommand.executePassWrapper(Array(CommandLine.arguments.dropFirst(2))))
}

await RootCommand.execute()
