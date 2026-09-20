import Domain
import Foundation
import Testing

@testable import Engine

// roadmap P9.10 (spec: board-projection/maintain-the-managed-block, "A Transcription Block's interior
// is opaque"): a Transcription Block quoting either Managed Block delimiter in its transcribed content
// must never confuse `ManagedBlockFence.replace(in:rendered:)` / `.parts(of:)` into seeing a duplicate.

private let transcriptionOpen = "<!-- yh:transcription:start repo=r paths=p symbol=- commit=c hash=h -->"
private let transcriptionClose = "<!-- yh:transcription:end -->"

@Suite("ManagedBlockFence ignores delimiters quoted inside a Transcription Block")
struct ManagedBlockFenceTranscriptionTests {
    @Test("A Transcription Block quoting the start delimiter does not read as a duplicate start")
    func quotedStartDelimiterIsIgnored() throws {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            ### Architectural Brief

            \(transcriptionOpen)
            This transcribed content quotes \(ManagedBlockFence.start) as an example.
            \(transcriptionClose)
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        let replacement = try ManagedBlockFence.replace(in: description, rendered: "NEW BLOCK").get()
        let parts = try ManagedBlockFence.parts(of: replacement.description).get()
        #expect(parts.block == "NEW BLOCK")

        let originalParts = try ManagedBlockFence.parts(of: description).get()
        #expect(originalParts.block.contains(transcriptionOpen))
        #expect(originalParts.block.contains("quotes \(ManagedBlockFence.start)"))
    }

    @Test("A Transcription Block quoting the end delimiter does not read as a duplicate end")
    func quotedEndDelimiterIsIgnored() throws {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            ### Architectural Brief

            \(transcriptionOpen)
            This transcribed content quotes \(ManagedBlockFence.end) as an example.
            \(transcriptionClose)
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        let replacement = try ManagedBlockFence.replace(in: description, rendered: "NEW BLOCK").get()
        let parts = try ManagedBlockFence.parts(of: replacement.description).get()
        #expect(parts.block == "NEW BLOCK")
    }

    @Test("A Transcription Block quoting both delimiters at once round-trips")
    func quotedBothDelimitersRoundTrips() throws {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            ### Architectural Brief

            \(transcriptionOpen)
            Quotes both \(ManagedBlockFence.start) and \(ManagedBlockFence.end) in one transcription.
            \(transcriptionClose)
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        let replacement = try ManagedBlockFence.replace(in: description, rendered: "REPLACED").get()
        let roundTripped = try ManagedBlockFence.parts(of: replacement.description).get()
        #expect(roundTripped.block == "REPLACED")
        // Outside the delimiters is byte-identical to the original read.
        let originalParts = try ManagedBlockFence.parts(of: description).get()
        #expect(replacement.preservedProse == originalParts.preservedProse)
    }

    @Test("An unterminated Transcription Block start does not mask the real end delimiter")
    func unterminatedTranscriptionDoesNotMaskRealEnd() throws {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            \(transcriptionOpen)
            unterminated content, never closed
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        let replacement = try ManagedBlockFence.replace(in: description, rendered: "NEW").get()
        #expect(replacement.description.contains("NEW"))
        let parts = try ManagedBlockFence.parts(of: description).get()
        #expect(parts.block.contains(transcriptionOpen))
        #expect(parts.block.contains("unterminated content, never closed"))
    }

    @Test("Genuinely duplicated delimiters outside any Transcription Block still fail")
    func realDuplicatesStillFail() {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            block one
            \(ManagedBlockFence.start)
            block two
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        switch ManagedBlockFence.replace(in: description, rendered: "NEW") {
        case .success:
            Issue.record("expected startDuplicated")
        case .failure(let failure):
            #expect(failure == .startDuplicated)
        }
        switch ManagedBlockFence.parts(of: description) {
        case .success:
            Issue.record("expected startDuplicated")
        case .failure(let failure):
            #expect(failure == .startDuplicated)
        }
    }

    @Test("A description with no Transcription Block is byte-identical outside the delimiters")
    func plainDescriptionIsUnaffected() throws {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            old block
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        let replacement = try ManagedBlockFence.replace(in: description, rendered: "new block").get()
        let parts = try ManagedBlockFence.parts(of: description).get()
        #expect(parts.block == "old block")
        #expect(parts.preservedProseHash == replacement.preservedProseHash)
        #expect(parts.preservedProse == replacement.preservedProse)
    }
}
