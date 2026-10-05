import Domain
import Foundation
import Journal

// Test-only child for JournalTests' cross-process open race. Usage:
//   JournalOpenChild <configurationDirectory> <projectID> <linearWorkspace>
// Opens the Journal through the engine's public open and prints the applied migrations.
let arguments = CommandLine.arguments
guard arguments.count == 4, let projectID = ProjectID(rawValue: arguments[2]) else {
    FileHandle.standardError.write(Data("usage: JournalOpenChild <configDir> <projectID> <workspace>\n".utf8))
    exit(2)
}

do {
    let store = try JournalStore.open(
        configurationDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
        projectID: projectID,
        linearWorkspace: BoardObjectID(rawValue: arguments[3])
    )
    print(try store.appliedMigrations().joined(separator: ","))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
