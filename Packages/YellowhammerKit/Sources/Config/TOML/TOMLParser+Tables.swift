extension TOMLParser {
    // MARK: - Key/value pairs

    mutating func parseKeyValue(into table: TOMLTableBuilder) throws(ConfigurationError) {
        let keyLine = line
        context = table.path
        let keys = try parseKey()
        let path = keys.reduce(table.path) { TOMLKey.path($0, $1) }
        context = path
        skipWhitespace()
        guard peek == "=" else {
            throw syntax("expected '=' after key, found \(Self.describe(peek))")
        }
        index += 1
        skipWhitespace()
        let value = try parseValue()
        context = path
        try insert(value, at: keys, into: table, line: keyLine)
    }

    private func insert(
        _ value: TOMLValue, at keys: [String], into table: TOMLTableBuilder, line: Int
    ) throws(ConfigurationError) {
        var table = table
        for key in keys.dropLast() {
            let path = TOMLKey.path(table.path, key)
            switch table[key] {
            case nil:
                let child = TOMLTableBuilder(origin: .dotted, line: line, path: path)
                table.insert(.table(child), for: key)
                table = child
            case .table(let child) where child.origin == .dotted:
                table = child
            case .table(let child):
                throw error(.tableRedefined(firstLine: child.line), key: path)
            case .value(let existing):
                throw error(.duplicateKey(firstLine: existing.line), key: path)
            case .arrayOfTables(let existing):
                throw error(.duplicateKey(firstLine: existing.line), key: path)
            }
        }
        let last = keys[keys.count - 1]
        if let existing = table[last] {
            throw error(.duplicateKey(firstLine: existing.line), key: TOMLKey.path(table.path, last))
        }
        table.insert(.value(value), for: last)
    }

    // MARK: - Headers

    mutating func parseHeader() throws(ConfigurationError) {
        let headerLine = line
        index += 1
        let isArray = peek == "["
        if isArray {
            index += 1
        }
        context = nil
        let keys = try parseKey()
        guard peek == "]", !isArray || peek(1) == "]" else {
            throw syntax("expected '\(isArray ? "]]" : "]")' to close the header, found \(Self.describe(peek))")
        }
        index += isArray ? 2 : 1
        let parent = try superTable(for: keys.dropLast(), line: headerLine)
        let last = keys[keys.count - 1]
        let path = TOMLKey.path(parent.path, last)
        context = path
        current = isArray
            ? try appendArrayTable(last, path: path, in: parent, line: headerLine)
            : try defineTable(last, path: path, in: parent, line: headerLine)
    }

    private mutating func superTable(
        for keys: ArraySlice<String>, line: Int
    ) throws(ConfigurationError) -> TOMLTableBuilder {
        var table = root
        for key in keys {
            let path = TOMLKey.path(table.path, key)
            switch table[key] {
            case nil:
                let child = TOMLTableBuilder(origin: .implicit, line: line, path: path)
                table.insert(.table(child), for: key)
                table = child
            case .table(let child):
                table = child
            case .arrayOfTables(let array):
                table = array.elements[array.elements.count - 1]
            case .value(let existing):
                throw error(.duplicateKey(firstLine: existing.line), key: path, line: line)
            }
        }
        return table
    }

    private func defineTable(
        _ key: String, path: String, in parent: TOMLTableBuilder, line: Int
    ) throws(ConfigurationError) -> TOMLTableBuilder {
        switch parent[key] {
        case nil:
            let table = TOMLTableBuilder(origin: .header, line: line, path: path)
            parent.insert(.table(table), for: key)
            return table
        case .table(let table) where table.origin == .implicit:
            table.origin = .header
            table.line = line
            return table
        case .table(let table):
            throw error(.tableRedefined(firstLine: table.line), line: line)
        case .arrayOfTables(let array):
            throw error(.tableRedefined(firstLine: array.line), line: line)
        case .value(let value):
            throw error(.duplicateKey(firstLine: value.line), line: line)
        }
    }

    private func appendArrayTable(
        _ key: String, path: String, in parent: TOMLTableBuilder, line: Int
    ) throws(ConfigurationError) -> TOMLTableBuilder {
        switch parent[key] {
        case nil:
            let array = TOMLArrayOfTablesBuilder(line: line, path: path)
            parent.insert(.arrayOfTables(array), for: key)
            return array.append(line: line)
        case .arrayOfTables(let array):
            return array.append(line: line)
        case .table(let table):
            throw error(.tableRedefined(firstLine: table.line), line: line)
        case .value(let value):
            throw error(.duplicateKey(firstLine: value.line), line: line)
        }
    }
}
