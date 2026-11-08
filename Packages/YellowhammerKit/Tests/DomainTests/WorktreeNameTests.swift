import Domain
import Foundation
import Testing

@Suite("WorktreeName")
struct WorktreeNameTests {
    @Test("A long Feature title produces a real filesystem component with headroom")
    func longFeatureTitleCreatesDirectory() throws {
        let title = String(repeating: "Know-How-Many-Scans-I-Have-Left-", count: 12)
        let name = WorktreeName(project: "carscalm", feature: title)
        #expect(name.rawValue.utf8.count <= 200)
        let root = FileManager.default.temporaryDirectory.appending(component: "yh-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(component: name.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Truncated names retain the identity of the full title and Project")
    func truncatedInputsRemainDistinct() {
        let prefix = String(repeating: "long-title-", count: 30)
        let first = WorktreeName(project: "carscalm", feature: prefix + "first")
        let second = WorktreeName(project: "carscalm", feature: prefix + "second")
        #expect(first != second)
        #expect(first == WorktreeName(project: "carscalm", feature: prefix + "first"))
        let longProject = WorktreeName(project: String(repeating: "Project-", count: 50), feature: "quota")
        #expect(longProject.rawValue.utf8.count <= 200)
        #expect(!longProject.rawValue.contains("/"))
    }

    @Test("Feature issue identity separates same-title Cycles and sanitization collisions")
    func featureIdentitySeparatesNames() {
        let first = WorktreeName(project: "carscalm", feature: "quota", featureIssueID: "feature-1")
        let second = WorktreeName(project: "carscalm", feature: "quota", featureIssueID: "feature-2")
        #expect(first != second)
        #expect(first == WorktreeName(project: "carscalm", feature: "quota", featureIssueID: "feature-1"))
        #expect(
            WorktreeName(project: "proj", feature: "auth/tokens", featureIssueID: "same") !=
                WorktreeName(project: "proj", feature: "auth tokens", featureIssueID: "same")
        )
        #expect(
            WorktreeName(project: "a-b", feature: "c", featureIssueID: "same") !=
                WorktreeName(project: "a", feature: "b-c", featureIssueID: "same")
        )
    }

    @Test("Unicode names stay ASCII and different input survives sanitization")
    func unicodeNames() {
        let first = WorktreeName(project: "proj", feature: String(repeating: "配額😀", count: 100), featureIssueID: "id")
        let second = WorktreeName(project: "proj", feature: String(repeating: "配額🚗", count: 100), featureIssueID: "id")
        #expect(first.rawValue.utf8.count <= 200)
        #expect(first.rawValue.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(first != second)
    }

    @Test("Raw loading and legacy short requests retain their spelling")
    func preservesExistingNames() {
        let raw = "yh-" + String(repeating: "legacy-", count: 50)
        #expect(WorktreeName(rawValue: raw).rawValue == raw)
        let short = WorktreeName(project: "yellowhammer", feature: "bound unanswered nights")
        #expect(short.rawValue == "yh-yellowhammer-bound-unanswered-nights")
        #expect(short.bounded(featureIssueID: "anything") == short)
        let legacy = WorktreeName(rawValue: raw).bounded(featureIssueID: "feature-1")
        #expect(legacy.rawValue.utf8.count == 200)
        #expect(legacy != WorktreeName(rawValue: raw).bounded(featureIssueID: "feature-2"))
    }

    @Test("A truncation that ends on a hyphen never joins the digest with a double hyphen")
    func truncationOnHyphenHasNoDoubleHyphen() {
        // Slide the hyphen across the cut point so one of the titles ends the cut stem on it.
        for padding in 160...185 {
            let feature = String(repeating: "x", count: padding) + "-tail-words-" + String(repeating: "y", count: 40)
            for name in [
                WorktreeName(project: "p", feature: feature),
                WorktreeName(project: "p", feature: feature, featureIssueID: "feature-1"),
                WorktreeName(rawValue: "yh-p-" + feature).bounded(featureIssueID: "feature-1")
            ] {
                #expect(!name.rawValue.contains("--"), "\(name.rawValue)")
                #expect(name.rawValue.utf8.count <= 200)
            }
        }
    }

    @Test("The byte budget bounds the full name at its exact boundary")
    func exactBudgetBoundary() {
        let atBudget = WorktreeName(project: "p", feature: String(repeating: "x", count: 195))
        let overBudget = WorktreeName(project: "p", feature: String(repeating: "x", count: 196))
        #expect(atBudget.rawValue == "yh-p-" + String(repeating: "x", count: 195))
        #expect(atBudget.rawValue.utf8.count == 200)
        #expect(overBudget.rawValue.utf8.count == 200)
        #expect(atBudget != overBudget)
    }
}
