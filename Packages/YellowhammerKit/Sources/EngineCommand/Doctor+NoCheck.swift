import Config
import Domain
import Foundation

extension Doctor {
    /// The test targets visible at a Repo's top level, named for the Operator: a `Tests`/`test`/`tests`
    /// directory, any `*Tests` directory, an `*.xctestplan`, or a `Package.swift` that declares a
    /// `testTarget`. One directory listing and one file read, both confined to the Repo's own path.
    static func testTargetEvidence(atPath path: String) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return [] }
        var evidence: [String] = []
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
            if isDirectory.boolValue, ["Tests", "test", "tests"].contains(name) || name.hasSuffix("Tests") {
                evidence.append("\(name)/")
            } else if name.hasSuffix(".xctestplan") {
                evidence.append(name)
            }
        }
        let manifest = (path as NSString).appendingPathComponent("Package.swift")
        if let text = try? String(contentsOfFile: manifest, encoding: .utf8), text.contains(".testTarget(") {
            evidence.append("Package.swift declares a testTarget")
        }
        return evidence
    }

    /// An informational finding when a working Repo declares `check = none` yet has test targets: the Feature's
    /// build and test clauses touching it will be reported as `not checked`. Never a warning, never a failure.
    func noCheckFinding(repo: RepoDeclaration, project: ProjectID) -> DoctorFinding? {
        guard repo.check == .none else { return nil }
        let expanded = Doctor.expandTilde(repo.path, homeDirectory: homeDirectory.path(percentEncoded: false))
        let evidence = Doctor.testTargetEvidence(atPath: expanded)
        guard !evidence.isEmpty else { return nil }
        let subject = "Project \(project.rawValue) repo \(repo.name)"
        return finding(
            .git, subject: subject, .info,
            "\(repo.name) declares `check = none`, but test targets exist (\(evidence.joined(separator: ", "))). "
                + "Build and test clauses in Features touching this Repo will be reported as `not checked`; "
                + "set its check in projects/\(project.rawValue).toml to automate them.",
            project: project
        )
    }
}
