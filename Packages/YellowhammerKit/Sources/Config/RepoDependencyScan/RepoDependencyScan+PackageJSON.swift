import Domain
import Foundation

// `package.json`: the dependencies naming a sibling by path, by git URL, or (a registry range) by package name.

extension RepoDependencyScan {
    private static let dependencySections = [
        "dependencies", "devDependencies", "peerDependencies", "optionalDependencies"
    ]

    static func scanPackageJSON(_ context: Context, into sink: inout Sink) {
        guard let text = scanText(of: "package.json", in: context, into: &sink) else { return }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            sink.skipped.append(SkippedFile(
                file: context.consumer.name + "/package.json", reason: "is not a valid JSON object"
            ))
            return
        }
        for section in dependencySections {
            guard let entries = object[section] as? [String: Any] else { continue }
            for key in entries.keys.sorted() {
                guard let value = entries[key] as? String,
                      let finding = finding(key: key, value: value, in: context)
                else { continue }
                sink.findings.append(finding)
            }
        }
    }

    private static func finding(key: String, value: String, in context: Context) -> Finding? {
        let reference = "\"\(key)\": \"\(value)\""
        func found(_ sibling: Sibling, _ via: RepoDependencyVia?) -> Finding {
            Finding(producer: sibling.name, via: via, file: "package.json", reference: reference)
        }
        if let path = localPath(value) {
            return context.sibling(path: path).map { found($0, .mainline) }
        }
        let parts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let location = String(parts[0])
        if let url = remoteURL(location) {
            let ref = parts.count > 1 ? String(parts[1]) : nil
            return context.sibling(url: url).map { found($0, via(ofReference: ref)) }
        }
        // A registry range names the package, not where it lives: it matches a sibling by that package's name.
        return context.sibling(packageName: key).map { found($0, .tag) }
    }

    private static func localPath(_ value: String) -> String? {
        for prefix in ["file:", "link:"] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return ["./", "../", "/", "~"].contains(where: value.hasPrefix) ? value : nil
    }

    private static func remoteURL(_ location: String) -> String? {
        let schemes = ["git+ssh://", "git+https://", "git+http://", "git://", "https://", "http://", "ssh://"]
        if schemes.contains(where: location.hasPrefix) { return location }
        return githubShorthandURL(location)
    }

    /// A version tag pins a release; a full commit hash pins nothing movable; any other ref is a branch.
    private static func via(ofReference ref: String?) -> RepoDependencyVia? {
        guard let ref, !ref.isEmpty else { return .mainline }
        if ref.hasPrefix("semver:") { return .tag }
        if ref.range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) != nil { return .tag }
        if ref.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil { return nil }
        return .mainline
    }
}
