import Foundation

@testable import Ledger

struct LedgerFixture: ~Copyable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-ledger-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> LedgerStore {
        try LedgerStore.open(configurationDirectory: directory)
    }
}
