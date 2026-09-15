/// A TOML 1.0 reader that keeps the source line of every value, so semantic errors can name a line.
struct TOMLParser {
    let file: String
    let scalars: [Unicode.Scalar]
    var index = 0
    var line = 1
    /// The key path errors are reported against.
    var context: String?
    let root: TOMLTableBuilder
    var current: TOMLTableBuilder

    static func parse(_ text: String, file: String) throws(ConfigurationError) -> TOMLTable {
        var parser = TOMLParser(file: file, text: text)
        try parser.parseDocument()
        return parser.root.freeze()
    }

    private init(file: String, text: String) {
        self.file = file
        self.scalars = Array(text.unicodeScalars)
        self.root = TOMLTableBuilder(origin: .header, line: 1, path: nil)
        self.current = root
    }

    // MARK: - Cursor

    var peek: Unicode.Scalar? {
        peek(0)
    }

    func peek(_ offset: Int) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    func hasPrefix(_ prefix: String) -> Bool {
        var offset = 0
        for scalar in prefix.unicodeScalars {
            guard peek(offset) == scalar else { return false }
            offset += 1
        }
        return true
    }

    mutating func skipWhitespace() {
        while peek == " " || peek == "\t" {
            index += 1
        }
    }

    /// Consumes `\n` or `\r\n`. Returns false, consuming nothing, at anything else.
    mutating func consumeNewline() -> Bool {
        if peek == "\n" {
            index += 1
        } else if peek == "\r" && peek(1) == "\n" {
            index += 2
        } else {
            return false
        }
        line += 1
        return true
    }

    func error(_ reason: ConfigurationError.Reason, key: String?? = .none, line: Int? = nil) -> ConfigurationError {
        ConfigurationError(file: file, line: line ?? self.line, key: key ?? context, reason: reason)
    }

    func syntax(_ message: String) -> ConfigurationError {
        error(.syntax(message))
    }

    static func describe(_ scalar: Unicode.Scalar?) -> String {
        guard let scalar else { return "end of file" }
        switch scalar {
        case "\n", "\r": return "end of line"
        case " "..."~": return "'\(Character(scalar))'"
        default: return "U+\(String(scalar.value, radix: 16, uppercase: true))"
        }
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F
    }

    // MARK: - Document

    private mutating func parseDocument() throws(ConfigurationError) {
        if peek == "\u{FEFF}" {
            index += 1
        }
        while true {
            context = current.path
            skipWhitespace()
            guard let scalar = peek else { return }
            switch scalar {
            case "#", "\n", "\r":
                try parseEndOfLine()
            case "[":
                try parseHeader()
                try parseEndOfLine()
            default:
                try parseKeyValue(into: current)
                try parseEndOfLine()
            }
        }
    }

    /// Whitespace, an optional comment, then a newline or the end of the file.
    mutating func parseEndOfLine() throws(ConfigurationError) {
        skipWhitespace()
        if peek == "#" {
            try skipComment()
        }
        guard peek != nil, !consumeNewline() else { return }
        throw syntax("expected end of line, found \(Self.describe(peek))")
    }

    mutating func skipComment() throws(ConfigurationError) {
        index += 1
        while let scalar = peek, scalar != "\n" {
            if scalar == "\r" && peek(1) == "\n" {
                return
            }
            guard !Self.isControl(scalar) else {
                throw syntax("control character \(Self.describe(scalar)) is not allowed in a comment")
            }
            index += 1
        }
    }

    // MARK: - Keys

    mutating func parseKey() throws(ConfigurationError) -> [String] {
        var keys: [String] = []
        while true {
            skipWhitespace()
            keys.append(try parseSimpleKey())
            skipWhitespace()
            guard peek == "." else { return keys }
            index += 1
        }
    }

    private mutating func parseSimpleKey() throws(ConfigurationError) -> String {
        switch peek {
        case "\"":
            return try parseBasicString()
        case "'":
            return try parseLiteralString()
        default:
            var key = String.UnicodeScalarView()
            while let scalar = peek, TOMLKey.isBareScalar(scalar) {
                key.append(scalar)
                index += 1
            }
            guard !key.isEmpty else {
                throw syntax("expected a key, found \(Self.describe(peek))")
            }
            return String(key)
        }
    }
}
