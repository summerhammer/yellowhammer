import Domain

/// `consumes` on a `[[repos]]` entry: the Repo Dependencies a consumer Repo declares on its producers.
///
/// The shape of each edge (table, `repo`, `via`, no repeated or self producer) is checked while the
/// consumer is decoded; whether a producer is a Repo of the Project, and whether the edges form a cycle,
/// are checked once every Repo is known, so a forward reference to a later Repo works.
extension ProjectConfigurationDecoder {
    func repoDependencies(
        in table: TOMLTable, path: String, consumer: String
    ) throws(ConfigurationError) -> [RepoDependency] {
        guard let value = table["consumes"] else { return [] }
        let key = "\(path).consumes"
        guard case .array(let elements) = value.content else {
            throw decoding.error(line: value.line, key: key, .typeMismatch(expected: "array", found: value.typeName))
        }
        var dependencies: [RepoDependency] = []
        var firstLines: [String: Int] = [:]
        for (index, element) in elements.enumerated() {
            let edgeKey = "\(key)[\(index)]"
            let edge = try decoding.table(element, key: edgeKey)
            try decoding.rejectUnknownKeys(in: edge, path: edgeKey, allowed: ["repo", "via"])
            let producer = try decoding.requiredString("repo", in: edge, path: edgeKey)
            let via = try repoDependencyVia(in: edge, path: edgeKey)
            let line = edge["repo"]?.line ?? edge.line
            guard producer != consumer else {
                throw decoding.error(line: line, key: "\(edgeKey).repo", .selfRepoDependency)
            }
            if let firstLine = firstLines[producer] {
                let reason = ConfigurationError.Reason.duplicateRepoDependency(producer: producer, firstLine: firstLine)
                throw decoding.error(line: line, key: "\(edgeKey).repo", reason)
            }
            firstLines[producer] = line
            dependencies.append(RepoDependency(producer: producer, via: via))
        }
        return dependencies
    }

    private func repoDependencyVia(in edge: TOMLTable, path: String) throws(ConfigurationError) -> RepoDependencyVia {
        // `via` has no default: silence is never read as `mainline`.
        let string = try decoding.requiredString("via", in: edge, path: path)
        guard let via = RepoDependencyVia(rawValue: string) else {
            let line = edge["via"]?.line ?? edge.line
            throw decoding.error(line: line, key: "\(path).via", .invalidRepoDependencyVia(string))
        }
        return via
    }

    /// Run after every Repo decoded: each producer names a Repo of the Project, and no cycle exists.
    /// `elements` are the `[[repos]]` tables, parallel to `repos`, for the lines of the edges.
    func requireResolvableAcyclicRepoDependencies(
        _ repos: [RepoDeclaration], elements: [TOMLValue]
    ) throws(ConfigurationError) {
        let indexByName = Dictionary(uniqueKeysWithValues: repos.enumerated().map { ($1.name, $0) })
        for (consumerIndex, repo) in repos.enumerated() {
            for (edgeIndex, dependency) in repo.consumes.enumerated()
            where indexByName[dependency.producer] == nil {
                throw decoding.error(
                    line: edgeLine(elements, consumerIndex, edgeIndex),
                    key: "repos[\(consumerIndex)].consumes[\(edgeIndex)].repo",
                    .unknownRepoDependencyProducer(dependency.producer)
                )
            }
        }
        let graph = repos.map { repo in repo.consumes.compactMap { indexByName[$0.producer] } }
        guard let cycle = firstCycle(in: graph) else { return }
        // `cycle` repeats its first Repo at the end; its first edge is the one reported.
        let consumerIndex = cycle[0]
        let edgeIndex = graph[consumerIndex].firstIndex(of: cycle[1]) ?? 0
        throw decoding.error(
            line: edgeLine(elements, consumerIndex, edgeIndex),
            key: "repos[\(consumerIndex)].consumes[\(edgeIndex)].repo",
            .repoDependencyCycle(path: cycle.map { repos[$0].name })
        )
    }

    private func edgeLine(_ elements: [TOMLValue], _ consumerIndex: Int, _ edgeIndex: Int) -> Int {
        guard case .table(let table) = elements[consumerIndex].content,
              case .array(let edges)? = table["consumes"]?.content,
              case .table(let edge) = edges[edgeIndex].content
        else { return elements[consumerIndex].line }
        return edge["repo"]?.line ?? edge.line
    }

    /// A cycle over `graph` (consumer index → producer indexes), as the Repo indexes in order with the first
    /// repeated at the end, or nil. Searched depth-first from each Repo in file order; the cycle found is
    /// rotated to start at the first Repo on it in file order.
    private func firstCycle(in graph: [[Int]]) -> [Int]? {
        enum Mark { case onPath, done }
        var marks: [Int: Mark] = [:]
        var stack: [Int] = []

        func visit(_ node: Int) -> [Int]? {
            marks[node] = .onPath
            stack.append(node)
            for next in graph[node] {
                switch marks[next] {
                case .onPath?:
                    let loop = Array(stack[stack.firstIndex(of: next)!...])
                    let start = loop.firstIndex(of: loop.min()!)!
                    let rotated = Array(loop[start...] + loop[..<start])
                    return rotated + [rotated[0]]
                case .done?:
                    continue
                case nil:
                    if let cycle = visit(next) { return cycle }
                }
            }
            stack.removeLast()
            marks[node] = .done
            return nil
        }

        for node in graph.indices where marks[node] == nil {
            if let cycle = visit(node) { return cycle }
        }
        return nil
    }
}
