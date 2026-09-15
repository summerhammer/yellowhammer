extension TOMLParser {
    mutating func parseValue() throws(ConfigurationError) -> TOMLValue {
        let startLine = line
        let content: TOMLValue.Content
        switch peek {
        case nil, "\n", "\r", "#":
            throw syntax("expected a value, found \(Self.describe(peek))")
        case "\"":
            content = .string(hasPrefix("\"\"\"") ? try parseMultilineBasicString() : try parseBasicString())
        case "'":
            content = .string(hasPrefix("'''") ? try parseMultilineLiteralString() : try parseLiteralString())
        case "[":
            content = .array(try parseArray())
        case "{":
            content = .table(try parseInlineTable(line: startLine))
        default:
            content = try parseBareValue()
        }
        return TOMLValue(content: content, line: startLine)
    }

    // MARK: - Arrays and inline tables

    private mutating func parseArray() throws(ConfigurationError) -> [TOMLValue] {
        let path = context
        index += 1
        var elements: [TOMLValue] = []
        while true {
            try skipArrayWhitespace()
            if peek == "]" {
                index += 1
                return elements
            }
            context = "\(path ?? "")[\(elements.count)]"
            elements.append(try parseValue())
            context = path
            try skipArrayWhitespace()
            switch peek {
            case ",":
                index += 1
            case "]":
                index += 1
                return elements
            case nil:
                throw syntax("unterminated array")
            default:
                throw syntax("expected ',' or ']' in an array, found \(Self.describe(peek))")
            }
        }
    }

    private mutating func skipArrayWhitespace() throws(ConfigurationError) {
        while true {
            skipWhitespace()
            if peek == "#" {
                try skipComment()
            }
            guard consumeNewline() else { return }
        }
    }

    private mutating func parseInlineTable(line: Int) throws(ConfigurationError) -> TOMLTable {
        let path = context
        let table = TOMLTableBuilder(origin: .inline, line: line, path: path)
        index += 1
        skipWhitespace()
        if peek == "}" {
            index += 1
            return table.freeze()
        }
        while true {
            try parseKeyValue(into: table)
            context = path
            skipWhitespace()
            switch peek {
            case ",":
                index += 1
                skipWhitespace()
                if peek == "}" {
                    throw syntax("a trailing comma is not allowed in an inline table")
                }
            case "}":
                index += 1
                return table.freeze()
            case "\n", "\r":
                throw syntax("an inline table must be on a single line")
            case nil:
                throw syntax("unterminated inline table")
            default:
                throw syntax("expected ',' or '}' in an inline table, found \(Self.describe(peek))")
            }
        }
    }

    // MARK: - Booleans, numbers and date-times

    private mutating func parseBareValue() throws(ConfigurationError) -> TOMLValue.Content {
        var token = readToken()
        if Self.isDate(token), peek == " ", let next = peek(1), ("0"..."9").contains(next) {
            index += 1
            token += " " + readToken()
        }
        guard !token.isEmpty else {
            throw syntax("expected a value, found \(Self.describe(peek))")
        }
        if let content = try scalarContent(token) {
            return content
        }
        throw syntax("invalid value '\(token)'")
    }

    private mutating func readToken() -> String {
        var token = String.UnicodeScalarView()
        while let scalar = peek, TOMLKey.isBareScalar(scalar) || "+.:".unicodeScalars.contains(scalar) {
            token.append(scalar)
            index += 1
        }
        return String(token)
    }

    private func scalarContent(_ token: String) throws(ConfigurationError) -> TOMLValue.Content? {
        switch token {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if let integer = try integer(token) {
            return .integer(integer)
        }
        if let float = float(token) {
            return .float(float)
        }
        if try dateTime(token) {
            return .dateTime(token)
        }
        return nil
    }

    private func integer(_ token: String) throws(ConfigurationError) -> Int64? {
        let radix: Int
        let digits: String
        if token.wholeMatch(of: #/[+-]?(0|[1-9](_?[0-9])*)/#) != nil {
            (radix, digits) = (10, token)
        } else if token.wholeMatch(of: #/0x[0-9A-Fa-f](_?[0-9A-Fa-f])*/#) != nil {
            (radix, digits) = (16, String(token.dropFirst(2)))
        } else if token.wholeMatch(of: #/0o[0-7](_?[0-7])*/#) != nil {
            (radix, digits) = (8, String(token.dropFirst(2)))
        } else if token.wholeMatch(of: #/0b[01](_?[01])*/#) != nil {
            (radix, digits) = (2, String(token.dropFirst(2)))
        } else {
            return nil
        }
        guard let value = Int64(digits.filter { $0 != "_" }, radix: radix) else {
            throw syntax("integer '\(token)' is out of range")
        }
        return value
    }

    private func float(_ token: String) -> Double? {
        let pattern = #/[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?/#
        guard token.wholeMatch(of: pattern) != nil, token.contains(where: { ".eE".contains($0) }) else {
            return nil
        }
        return Double(token.filter { $0 != "_" })
    }

    static func isDate(_ token: String) -> Bool {
        token.wholeMatch(of: #/[0-9]{4}-[0-9]{2}-[0-9]{2}/#) != nil
    }
}
