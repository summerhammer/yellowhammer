import Foundation

/// A parsed TOML value and the 1-based line it starts on. A table's line is its header's line,
/// or the line of the key that first created it.
struct TOMLValue: Equatable {
    enum Content: Equatable {
        case string(String)
        case integer(Int64)
        case float(Double)
        case boolean(Bool)
        /// Validated, kept as written.
        case dateTime(String)
        case array([TOMLValue])
        case table(TOMLTable)
    }

    let content: Content
    let line: Int

    var typeName: String {
        switch content {
        case .string: "string"
        case .integer: "integer"
        case .float: "float"
        case .boolean: "boolean"
        case .dateTime: "date-time"
        case .array: "array"
        case .table: "table"
        }
    }
}

struct TOMLTable: Equatable {
    struct Entry: Equatable {
        let key: String
        let value: TOMLValue
    }

    /// In file order.
    let entries: [Entry]
    let line: Int

    subscript(key: String) -> TOMLValue? {
        entries.first { $0.key == key }?.value
    }
}

enum TOMLKey {
    /// Joins a display path and a key, quoting the key when it is not bare.
    static func path(_ parent: String?, _ key: String) -> String {
        let segment = isBare(key) ? key : quoted(key)
        guard let parent else { return segment }
        return "\(parent).\(segment)"
    }

    static func isBare(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy(isBareScalar)
    }

    static func isBareScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
        default: false
        }
    }

    private static func quoted(_ key: String) -> String {
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// A table under construction, tracking how it was defined so the define-once rules can be enforced.
final class TOMLTableBuilder {
    enum Origin {
        /// Created as a super-table of a header, and may still be defined by its own header once.
        case implicit
        case header
        case dotted
        case inline
    }

    enum Node {
        case value(TOMLValue)
        case table(TOMLTableBuilder)
        case arrayOfTables(TOMLArrayOfTablesBuilder)
    }

    var origin: Origin
    var line: Int
    let path: String?
    private(set) var keys: [String] = []
    private var nodes: [String: Node] = [:]

    init(origin: Origin, line: Int, path: String?) {
        self.origin = origin
        self.line = line
        self.path = path
    }

    subscript(key: String) -> Node? {
        nodes[key]
    }

    func insert(_ node: Node, for key: String) {
        if nodes[key] == nil {
            keys.append(key)
        }
        nodes[key] = node
    }

    func freeze() -> TOMLTable {
        let entries = keys.compactMap { key -> TOMLTable.Entry? in
            guard let node = nodes[key] else { return nil }
            return TOMLTable.Entry(key: key, value: node.freeze())
        }
        return TOMLTable(entries: entries, line: line)
    }
}

extension TOMLTableBuilder.Node {
    var line: Int {
        switch self {
        case .value(let value): value.line
        case .table(let table): table.line
        case .arrayOfTables(let array): array.line
        }
    }

    func freeze() -> TOMLValue {
        switch self {
        case .value(let value):
            return value
        case .table(let table):
            return TOMLValue(content: .table(table.freeze()), line: table.line)
        case .arrayOfTables(let array):
            let elements = array.elements.map { TOMLValue(content: .table($0.freeze()), line: $0.line) }
            return TOMLValue(content: .array(elements), line: array.line)
        }
    }
}

final class TOMLArrayOfTablesBuilder {
    let line: Int
    let path: String
    private(set) var elements: [TOMLTableBuilder] = []

    init(line: Int, path: String) {
        self.line = line
        self.path = path
    }

    func append(line: Int) -> TOMLTableBuilder {
        let element = TOMLTableBuilder(origin: .header, line: line, path: "\(path)[\(elements.count)]")
        elements.append(element)
        return element
    }
}
