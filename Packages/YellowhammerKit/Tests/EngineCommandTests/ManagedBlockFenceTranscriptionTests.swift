import Domain
import Foundation
import Testing

@testable import Engine

// roadmap P9.10 (spec: board-projection/maintain-the-managed-block, "A Transcription Block's interior
// is opaque"): a Transcription Block quoting either Managed Block delimiter in its transcribed content
// must never confuse `ManagedBlockFence.replace(in:rendered:)` / `.parts(of:)` into seeing a duplicate.

private let transcriptionOpen = "<!-- yh:transcription:start repo=r paths=p symbol=- commit=c -->"
private let transcriptionClose = "<!-- yh:transcription:end -->"

@Suite("ManagedBlockFence ignores delimiters quoted inside a Transcription Block")
struct ManagedBlockFenceTranscriptionTests {
    @Test("A Transcription Block quoting the start delimiter does not read as a duplicate start")
    func quotedStartDelimiterIsIgnored() throws {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            ### Architectural Brief
            <!-- yh:brief-prose:start id=0 -->
            Prose.
            <!-- yh:brief-prose:end id=0 -->

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
            <!-- yh:brief-prose:start id=0 -->
            Prose.
            <!-- yh:brief-prose:end id=0 -->

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
            <!-- yh:brief-prose:start id=0 -->
            Prose.
            <!-- yh:brief-prose:end id=0 -->

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

    @Test("An unterminated Transcription Block start does not mask the real end delimiter: it is unpaired")
    func unterminatedTranscriptionDoesNotMaskRealEnd() {
        let description = """
            Prefix prose.
            \(ManagedBlockFence.start)
            \(transcriptionOpen)
            unterminated content, never closed
            \(ManagedBlockFence.end)
            Suffix prose.
            """

        // The real end is still found (not `.endMissing`); the lone start is what is refused.
        let unpaired = Result<Bool, ManagedBlockFence.Failure>.failure(.transcriptionDelimiterUnpaired)
        #expect(ManagedBlockFence.replace(in: description, rendered: "NEW").map { _ in true } == unpaired)
        #expect(ManagedBlockFence.parts(of: description).map { _ in true } == unpaired)
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

// spec: feature-authoring/author-an-architectural-brief#edited-reference — a Transcription Block with one
// delimiter left behind is a broken delimiter, refused exactly like a broken `yh:managed` fence.

private let blockLine = "Contract: `r` · `p` · commit `c`"

private func card(_ managed: String) -> String {
    "Prefix prose.\n\(ManagedBlockFence.start)\n\(managed)\n\(ManagedBlockFence.end)\nSuffix prose."
}

@Suite("ManagedBlockFence refuses an unpaired Transcription Block delimiter")
struct ManagedBlockFenceUnpairedTests {
    private func failures(_ description: String) -> [ManagedBlockFence.Failure?] {
        let replaced: ManagedBlockFence.Failure?
        if case .failure(let failure) = ManagedBlockFence.replace(in: description, rendered: "NEW") {
            replaced = failure
        } else {
            replaced = nil
        }
        let parted: ManagedBlockFence.Failure?
        if case .failure(let failure) = ManagedBlockFence.parts(of: description) {
            parted = failure
        } else {
            parted = nil
        }
        return [replaced, parted]
    }

    @Test("A start deleted (the line and the end left behind) fails")
    func startDeleted() {
        let description = card("Prose\n\(blockLine)\n\(transcriptionClose)\n### Definition of Done")
        #expect(failures(description) == [.transcriptionDelimiterUnpaired, .transcriptionDelimiterUnpaired])
    }

    @Test("An end deleted (the start and the line left behind) fails")
    func endDeleted() {
        let description = card("Prose\n\(transcriptionOpen)\n\(blockLine)\n### Definition of Done")
        #expect(failures(description) == [.transcriptionDelimiterUnpaired, .transcriptionDelimiterUnpaired])
    }

    @Test("A second end with no start before it fails")
    func strayEnd() {
        let description = card("\(transcriptionOpen)\n\(blockLine)\n\(transcriptionClose)\n\(transcriptionClose)")
        #expect(failures(description) == [.transcriptionDelimiterUnpaired, .transcriptionDelimiterUnpaired])
    }

    @Test("A well-formed card, several blocks, and a card with none all pass")
    func wellFormed() {
        let one = "\(transcriptionOpen)\n\(blockLine)\n\(transcriptionClose)"
        #expect(failures(card(one)) == [nil, nil])
        #expect(failures(card("\(one)\n\(one)")) == [nil, nil])
        let brief = "### Architectural Brief\n<!-- yh:brief-prose:start id=0 -->\nProse\n"
            + "<!-- yh:brief-prose:end id=0 -->"
        #expect(failures(card(brief)) == [nil, nil])
        #expect(failures(card("  \(transcriptionOpen)\n  \(blockLine)\n  \(transcriptionClose)")) == [nil, nil])
    }

    @Test("A start nested inside a block is interior, as in the masking reader")
    func nestedStartIsInterior() {
        let nested = "\(transcriptionOpen)\n\(transcriptionOpen)\n\(transcriptionClose)"
        #expect(failures(card(nested)) == [nil, nil])
    }

    @Test("A delimiter quoted inside the delimited Brief prose is prose, never counted")
    func delimiterQuotedInProseIsIgnored() {
        let prose = "### Architectural Brief\n<!-- yh:brief-prose:start id=0 -->\nQuoted: \(transcriptionClose)\n"
            + "<!-- yh:brief-prose:end id=0 -->"
        #expect(failures(card(prose)) == [nil, nil])
    }

    @Test("A start deleted after a delimited Brief prose still fails")
    func startDeletedAfterDelimitedProse() {
        let prose = "### Architectural Brief\n<!-- yh:brief-prose:start id=0 -->\nProse\n"
            + "<!-- yh:brief-prose:end id=0 -->"
        let description = card("\(prose)\n\(blockLine)\n\(transcriptionClose)\n### Definition of Done")
        #expect(failures(description) == [.transcriptionDelimiterUnpaired, .transcriptionDelimiterUnpaired])
    }

    @Test("Text outside the Managed Block is never checked")
    func outsideIsIgnored() {
        let description = "\(transcriptionClose)\n\(ManagedBlockFence.start)\nprose\n\(ManagedBlockFence.end)\n"
            + "\(transcriptionOpen)\nstray"
        #expect(failures(description) == [nil, nil])
    }
}
