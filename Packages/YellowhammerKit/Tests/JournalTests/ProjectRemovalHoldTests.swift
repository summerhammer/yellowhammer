import Darwin
import Foundation
@testable import Journal
import Testing

@Suite("Project removal hold release")
struct ProjectRemovalHoldTests {
    /// A child spawned by any thread of the process copies every descriptor, and the kernel closes the
    /// `O_CLOEXEC` ones only once it activates the child's image. `dup` models that inherited copy: an
    /// Act claiming right after removal released must not find the Journal still held through it.
    @Test("A released exclusive hold admits a shared hold at once, even while a copy of its descriptor is open")
    func releaseUnlocksDespiteInheritedCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "yh-hold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appending(component: "alpha.db")
        let exclusive = try ProjectRemovalHold.exclusive(for: journalURL, wait: .zero)
        let inherited = dup(exclusive.lockedDescriptor)
        try #require(inherited >= 0)
        defer { Darwin.close(inherited) }

        exclusive.release()

        let shared = try ProjectRemovalHold.shared(for: journalURL)
        shared.release()
    }
}
