import Config
import Darwin
import Domain
import Foundation
import Testing

@Suite("DispatchPromptStore extended ACLs")
struct DispatchPromptStoreACLTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(components: "yh-prompt-store-acl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func addACL(_ rule: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", rule, url.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func hasACL(_ url: URL) -> Bool {
        guard let acl = acl_get_link_np(url.path(percentEncoded: false), ACL_TYPE_EXTENDED) else {
            return false
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }

    private func allEntries(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []) + [root]
    }

    @Test("Capture strips ACL entries from existing directories and from the new record")
    func captureStripsACLsFromDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DispatchPromptStore(rootDirectory: root)
        let first = makeStoreTestRecord(id: "rec-acl-1")
        #expect(store.capture(first) == .recorded(id: "rec-acl-1"))

        let scopeDir = store.directory(for: first.provenance.scope)
        try addACL("everyone allow read,list,search", to: root)
        try addACL("everyone allow read,list,search", to: scopeDir)
        #expect(hasACL(root))
        #expect(hasACL(scopeDir))

        let second = makeStoreTestRecord(id: "rec-acl-2")
        #expect(store.capture(second) == .recorded(id: "rec-acl-2"))
        #expect(!hasACL(root))
        #expect(!hasACL(scopeDir))
        #expect(!hasACL(scopeDir.appending(components: "rec-acl-2.json", directoryHint: .notDirectory)))
    }

    @Test("An inheritable ACL on the root never reaches subdirectories or record files")
    func inheritableACLIsNotInherited() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        Darwin.chmod(root.path(percentEncoded: false), 0o700)
        try addACL("everyone allow read,list,search,file_inherit,directory_inherit", to: root)

        let store = DispatchPromptStore(rootDirectory: root)
        let record = makeStoreTestRecord(id: "rec-inherit")
        #expect(store.capture(record) == .recorded(id: "rec-inherit"))

        for url in allEntries(under: root) {
            #expect(!hasACL(url), "unexpected ACL on \(url.path(percentEncoded: false))")
        }
    }

    @Test("A record file with an ACL entry is unreadable")
    func readRefusesACLOnRecordFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DispatchPromptStore(rootDirectory: root)
        let record = makeStoreTestRecord(id: "rec-read-acl")
        #expect(store.capture(record) == .recorded(id: "rec-read-acl"))

        let recordURL = store.directory(for: record.provenance.scope)
            .appending(components: "rec-read-acl.json", directoryHint: .notDirectory)
        try addACL("everyone allow read", to: recordURL)

        guard case .unreadable = store.lookup(id: "rec-read-acl", scope: record.provenance.scope) else {
            Issue.record("expected .unreadable")
            return
        }
        #expect(hasACL(recordURL))
    }
}
