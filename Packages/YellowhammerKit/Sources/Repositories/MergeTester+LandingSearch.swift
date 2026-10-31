import Foundation

// Which mainline commits the content test's landing search merges the tip into (feature-authoring/
// select-the-next-feature, #merge-test, #stacked-content-test). Split out of MergeTester+ContentTest.swift for the
// file and type length limits.
//
// A commit whose diff from its first parent touches none of the paths the tip changes against the merge base
// absorbs the tip exactly when its first parent does: outside those paths the tip equals the base, so the merge
// takes the commit's side. The search therefore merges into the commits that touch the tip's paths, and finds the
// same oldest commit as a search of every commit, with three conditions. The first commit's first parent is the
// search's start, which is known not to absorb the tip or is itself tested. In the plain content test the fork point
// is the only merge base, so it is each commit's merge base with the tip. And no rename is possible: `git
// merge-tree` detects renames, which can carry the tip's change to a path the tip never named, so the search keeps
// every commit whenever mainline deleted a path the tip changes, mainline emptied a directory holding one of them,
// or the tip emptied a directory mainline added to. Any read that fails also keeps every commit, so a failed read
// never reads as "no landing".

/// The paths one `git diff --name-status --no-renames` touches, and of them those it adds and deletes.
struct PathChanges: Equatable, Sendable {
    var touched: Set<String> = []
    var added: Set<String> = []
    var deleted: Set<String> = []

    /// Records one `--name-status` entry.
    mutating func record(status: Character, path: String) {
        touched.insert(path)
        switch status {
        case "A": added.insert(path)
        case "D": deleted.insert(path)
        default: break
        }
    }
}

/// One commit of mainline's first-parent chain, with the paths its diff from its first parent touches.
struct FirstParentCommit: Equatable, Sendable {
    let commit: String
    let tree: String
    let firstParent: String?
    var changes = PathChanges()
}

/// The changes on both sides of a landing search, against its merge base, and whether a rename is possible.
struct LandingSearchScope: Equatable, Sendable {
    /// The paths the tip changes against the merge base.
    let tipPaths: Set<String>
    let tipDeleted: Set<String>
    /// Every path any of mainline's commits from the merge base to the end of the search adds, or deletes.
    let mainlineAdded: Set<String>
    let mainlineDeleted: Set<String>

    /// Directories holding a tip path, from which mainline deleted something: mainline may have emptied them.
    var mainlineEmptiedCandidates: Set<String> {
        let held = Set(tipPaths.flatMap(Self.directories(of:)))
        return Set(mainlineDeleted.flatMap(Self.directories(of:))).intersection(held)
    }

    /// Directories the tip deleted from, to which mainline added something: the tip may have emptied them.
    var tipEmptiedCandidates: Set<String> {
        let held = Set(mainlineAdded.flatMap(Self.directories(of:)))
        return Set(tipDeleted.flatMap(Self.directories(of:))).intersection(held)
    }

    /// Whether the tip's paths alone decide the search: no rename can carry the tip's change to another path.
    /// `baseFiles`, every file of the merge base, is read only when a directory may have been emptied; nil is
    /// unreadable, and then a rename is assumed.
    func limitsToTipPaths(baseFiles: () async -> [String]?) async -> Bool {
        guard tipPaths.isDisjoint(with: mainlineDeleted) else { return false }
        let mainlineCandidates = mainlineEmptiedCandidates
        let tipCandidates = tipEmptiedCandidates
        guard !mainlineCandidates.isEmpty || !tipCandidates.isEmpty else { return true }
        guard let files = await baseFiles() else { return false }
        return !Self.anyEmptied(mainlineCandidates, of: files, by: mainlineDeleted)
            && !Self.anyEmptied(tipCandidates, of: files, by: tipDeleted)
    }

    /// Whether `deleted` holds every file of `files` under one of `candidates` that has any.
    private static func anyEmptied(_ candidates: Set<String>, of files: [String], by deleted: Set<String>) -> Bool {
        guard !candidates.isEmpty else { return false }
        var held: [String: Int] = [:]
        var gone: [String: Int] = [:]
        for file in files {
            for directory in directories(of: file) where candidates.contains(directory) {
                held[directory, default: 0] += 1
                if deleted.contains(file) { gone[directory, default: 0] += 1 }
            }
        }
        return held.contains { directory, count in gone[directory] == count }
    }

    /// The directories above `path`, the repository's root excluded: `a/b/c` is in `a` and `a/b`.
    static func directories(of path: String) -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        return components.indices.map { components[...$0].joined(separator: "/") }
    }
}

extension MergeTester {
    /// The commits a landing search after `start` merges the tip into, oldest first, each with its tree: mainline's
    /// first-parent chain from `start` (excluded) to `mainline`, limited to the commits that touch the paths
    /// `tip` changes against `base` when that cannot change the search's result. `start` is where the search
    /// begins; `base` must be every merge's base, the fork point when it is the only merge base, or `--merge-base`.
    func landingCandidates(
        after start: String, upTo mainline: String, tip: String, base: String, in path: String
    ) async -> [(commit: String, tree: String)] {
        guard let history = await firstParentHistory(after: start, upTo: mainline, in: path) else {
            return await firstParentChain(after: start, upTo: mainline, in: path)
        }
        let chain = history.map { (commit: $0.commit, tree: $0.tree) }
        guard history.first?.firstParent == start,
              let tipPaths = await limitingPaths(of: history, start: start, tip: tip, base: base, in: path)
        else { return chain }
        return history.filter { !$0.changes.touched.isDisjoint(with: tipPaths) }
            .map { (commit: $0.commit, tree: $0.tree) }
    }

    /// The paths `tip` changes against `base`, when the search may be limited to them; nil when it may not, or a
    /// read failed.
    private func limitingPaths(
        of history: [FirstParentCommit], start: String, tip: String, base: String, in path: String
    ) async -> Set<String>? {
        // The tip has a net change whenever the search runs, so no changes here is a read that failed.
        guard let tipChanges = await changes(from: base, to: tip, in: path), !tipChanges.touched.isEmpty
        else { return nil }
        var mainlineAdded = Set(history.flatMap(\.changes.added))
        var mainlineDeleted = Set(history.flatMap(\.changes.deleted))
        if start != base {
            guard let startChanges = await changes(from: base, to: start, in: path) else { return nil }
            mainlineAdded.formUnion(startChanges.added)
            mainlineDeleted.formUnion(startChanges.deleted)
        }
        let scope = LandingSearchScope(
            tipPaths: tipChanges.touched, tipDeleted: tipChanges.deleted,
            mainlineAdded: mainlineAdded, mainlineDeleted: mainlineDeleted
        )
        let limits = await scope.limitsToTipPaths { await self.files(of: base, in: path) }
        return limits ? tipChanges.touched : nil
    }

    /// Mainline's first-parent chain after `start`, oldest first, each commit with its tree, its first parent, and
    /// the paths its diff from its first parent touches, read in one `git log`. Nil when git cannot read it, and
    /// for an empty chain, which the caller reads again.
    func firstParentHistory(
        after start: String, upTo mainline: String, in path: String
    ) async -> [FirstParentCommit]? {
        let result = await git.run([
            "-C", path, "log", "--first-parent", "--reverse", "--diff-merges=first-parent", "--no-renames",
            "--no-color", "--no-show-signature", "--ignore-submodules=none", "--no-ext-diff", "--name-status", "-z",
            "--format=%x01%H %T %P", "\(start)..\(mainline)"
        ])
        guard result.isSuccess else { return nil }
        var history: [FirstParentCommit] = []
        var status: Character?
        for field in Self.nulFields(result.stdout) {
            if let pending = status {
                history[history.count - 1].changes.record(status: pending, path: field)
                status = nil
                continue
            }
            let token = field.drop { $0 == "\n" }
            if token.first == "\u{1}" {
                let header = token.dropFirst().split(separator: " ").map(String.init)
                guard header.count >= 2 else { return nil }
                history.append(
                    FirstParentCommit(commit: header[0], tree: header[1], firstParent: header.dropFirst(2).first)
                )
            } else if let letter = token.first {
                guard !history.isEmpty else { return nil }
                status = letter
            }
        }
        return history.isEmpty || status != nil ? nil : history
    }

    /// `git diff --name-status` between two commits; empty when `--exit-code` says they have the same tree. Nil
    /// when git cannot read it, or prints no entries for trees that differ.
    private func changes(from base: String, to commit: String, in path: String) async -> PathChanges? {
        let result = await git.run([
            "-C", path, "diff", "--name-status", "--no-renames", "--no-color", "--ignore-submodules=none",
            "--no-ext-diff", "--exit-code", "-z", base, commit
        ])
        switch result.exitCode {
        case 0: return PathChanges()
        case 1: break
        default: return nil
        }
        var changes = PathChanges()
        let fields = Self.nulFields(result.stdout).filter { !$0.isEmpty }
        guard !fields.isEmpty, fields.count.isMultiple(of: 2) else { return nil }
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard let letter = fields[index].first else { return nil }
            changes.record(status: letter, path: fields[index + 1])
        }
        return changes
    }

    /// Every file of `commit`'s tree. Nil when git cannot read it, or reads none.
    private func files(of commit: String, in path: String) async -> [String]? {
        let result = await git.run(["-C", path, "ls-tree", "-r", "--name-only", "--full-tree", "-z", commit])
        guard result.isSuccess else { return nil }
        let files = Self.nulFields(result.stdout).filter { !$0.isEmpty }
        return files.isEmpty ? nil : files
    }

    /// `-z` output split at each NUL, the final empty field dropped. Split by scalar, not by Character, so a path
    /// that starts with a combining mark stays its own field.
    private static func nulFields(_ output: String) -> [String] {
        var fields = output.unicodeScalars.split(separator: "\0", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        if fields.last?.isEmpty == true { fields.removeLast() }
        return fields
    }
}
