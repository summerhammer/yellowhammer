import CryptoKit
import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-board-updates-through-the-outbox: split out of OutboxTests.swift (SwiftLint's
// type_body_length) — OutboxClientID.make's determinism, its salting by the Journal (P15's fix for the
// rehearsal-reset replay bug: a reset Project's fresh Journal must never recompute the id of an issue an
// earlier Journal already created and that is now archived), and its v4 UUID shape.

@Suite("Outbox client ids")
struct OutboxClientIDTests {
    @Test("The same Project, salt and key always yield the same client id, and another Project never shares it")
    func deterministicClientIDs() throws {
        let alpha = try #require(ProjectID(rawValue: "alpha"))
        let beta = try #require(ProjectID(rawValue: "beta"))

        let first = OutboxClientID.make(projectID: alpha, salt: "salt-1", key: "card:1:main:1:create")
        #expect(first == OutboxClientID.make(projectID: alpha, salt: "salt-1", key: "card:1:main:1:create"))
        #expect(first != OutboxClientID.make(projectID: alpha, salt: "salt-1", key: "card:1:main:2:create"))
        #expect(first != OutboxClientID.make(projectID: beta, salt: "salt-1", key: "card:1:main:1:create"))
        #expect(UUID(uuidString: first.uuidString) == first)
    }

    @Test("A different salt on the same Project and key yields a different client id")
    func differentSaltYieldsDifferentClientID() throws {
        let alpha = try #require(ProjectID(rawValue: "alpha"))
        let key = "card:1:main:1:create"

        let saltedOne = OutboxClientID.make(projectID: alpha, salt: "journal-one", key: key)
        let saltedTwo = OutboxClientID.make(projectID: alpha, salt: "journal-two", key: key)
        #expect(saltedOne != saltedTwo)
    }

    @Test("An empty salt reproduces the legacy digest, byte for byte")
    func emptySaltReproducesLegacyDigest() throws {
        let alpha = try #require(ProjectID(rawValue: "alpha"))
        let key = "card:1:main:1:create"

        let digest = SHA256.hash(data: Data("yellowhammer-outbox|alpha|\(key)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let expected = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))

        #expect(OutboxClientID.make(projectID: alpha, salt: "", key: key) == expected)
    }

    @Test("A client id is shaped as a version-4 UUID with the RFC 4122 variant, the only form Linear accepts")
    func clientIDsAreVersion4() throws {
        let alpha = try #require(ProjectID(rawValue: "alpha"))
        for key in ["card:1:main:1:create", "night:2026-09-23:create", "comment:x:1:crash"] {
            for salt in ["", "some-salt"] {
                let bytes = OutboxClientID.make(projectID: alpha, salt: salt, key: key).uuid
                #expect(bytes.6 >> 4 == 4)
                #expect(bytes.8 >> 6 == 0b10)
            }
        }
    }

    @Test("Outbox.clientID(for:) yields different ids for the same Project and key in two fresh Journals")
    func clientIDDiffersAcrossFreshJournals() throws {
        // A real fresh open, not the seeded template: the template's file copy would give every seeded
        // Journal the same outbox_salt, which is exactly what this test must not assume.
        let firstFixture = try OutboxJournalFixture(project: "salt-a")
        let firstJournal = try JournalStore.open(
            configurationDirectory: firstFixture.directory, projectID: firstFixture.projectID
        )
        let secondFixture = try OutboxJournalFixture(project: "salt-b")
        let secondJournal = try JournalStore.open(
            configurationDirectory: secondFixture.directory, projectID: secondFixture.projectID
        )

        let key = "card:1:main:1:create"
        let firstOutbox = try outbox(firstJournal, board: FakeWritingBoard())
        let secondOutbox = try outbox(secondJournal, board: FakeWritingBoard())

        #expect(firstOutbox.clientID(for: key) != secondOutbox.clientID(for: key))
    }

    @Test("Outbox.clientID(for:) yields the same id on reopen of one Journal")
    func clientIDStableAcrossReopen() throws {
        let fixture = try OutboxJournalFixture(project: "salt-reopen")
        let key = "card:1:main:1:create"

        let firstOpen = try JournalStore.open(configurationDirectory: fixture.directory, projectID: fixture.projectID)
        let firstOutbox = try outbox(firstOpen, board: FakeWritingBoard())
        let firstID = firstOutbox.clientID(for: key)

        let reopened = try JournalStore.open(configurationDirectory: fixture.directory, projectID: fixture.projectID)
        let reopenedOutbox = try outbox(reopened, board: FakeWritingBoard(), runID: firstOutbox.runID)
        let secondID = reopenedOutbox.clientID(for: key)

        #expect(firstID == secondID)
    }
}
