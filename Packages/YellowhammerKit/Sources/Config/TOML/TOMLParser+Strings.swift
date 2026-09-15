extension TOMLParser {
    mutating func parseBasicString() throws(ConfigurationError) -> String {
        index += 1
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek, scalar != "\n", scalar != "\r" else {
                throw syntax("unterminated string")
            }
            switch scalar {
            case "\"":
                index += 1
                return String(result)
            case "\\":
                result.append(try parseEscape())
            default:
                try appendLiteral(scalar, to: &result)
            }
        }
    }

    mutating func parseMultilineBasicString() throws(ConfigurationError) -> String {
        index += 3
        _ = consumeNewline()
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek else {
                throw syntax("unterminated multi-line string")
            }
            if scalar == "\"" {
                if try closeMultiline(quote: "\"", appendingTo: &result) {
                    return String(result)
                }
            } else if scalar == "\\" {
                if !skipLineEndingBackslash() {
                    result.append(try parseEscape())
                }
            } else if consumeNewline() {
                result.append("\n")
            } else {
                try appendLiteral(scalar, to: &result)
            }
        }
    }

    mutating func parseLiteralString() throws(ConfigurationError) -> String {
        index += 1
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek, scalar != "\n", scalar != "\r" else {
                throw syntax("unterminated string")
            }
            if scalar == "'" {
                index += 1
                return String(result)
            }
            try appendLiteral(scalar, to: &result)
        }
    }

    mutating func parseMultilineLiteralString() throws(ConfigurationError) -> String {
        index += 3
        _ = consumeNewline()
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = peek else {
                throw syntax("unterminated multi-line string")
            }
            if scalar == "'" {
                if try closeMultiline(quote: "'", appendingTo: &result) {
                    return String(result)
                }
            } else if consumeNewline() {
                result.append("\n")
            } else {
                try appendLiteral(scalar, to: &result)
            }
        }
    }

    private mutating func appendLiteral(
        _ scalar: Unicode.Scalar, to result: inout String.UnicodeScalarView
    ) throws(ConfigurationError) {
        guard !Self.isControl(scalar) else {
            throw syntax("control character \(Self.describe(scalar)) must be escaped in a string")
        }
        result.append(scalar)
        index += 1
    }

    /// At a run of quotes: three to five close the string, the extra ones being content. Returns
    /// false when the run is shorter than three, having appended it.
    private mutating func closeMultiline(
        quote: Unicode.Scalar, appendingTo result: inout String.UnicodeScalarView
    ) throws(ConfigurationError) -> Bool {
        var count = 0
        while peek(count) == quote {
            count += 1
        }
        guard count <= 5 else {
            throw syntax("too many quotes closing a multi-line string")
        }
        index += count
        let content = count >= 3 ? count - 3 : count
        result.append(contentsOf: repeatElement(quote, count: content))
        return count >= 3
    }

    /// A backslash followed only by whitespace to the end of the line trims through the next
    /// non-whitespace character.
    private mutating func skipLineEndingBackslash() -> Bool {
        var offset = 1
        while peek(offset) == " " || peek(offset) == "\t" {
            offset += 1
        }
        guard peek(offset) == "\n" || (peek(offset) == "\r" && peek(offset + 1) == "\n") else {
            return false
        }
        index += offset
        while true {
            skipWhitespace()
            guard consumeNewline() else { return true }
        }
    }

    private mutating func parseEscape() throws(ConfigurationError) -> Unicode.Scalar {
        index += 1
        guard let escape = peek else {
            throw syntax("unterminated string")
        }
        index += 1
        switch escape {
        case "u": return try parseUnicodeEscape(digits: 4)
        case "U": return try parseUnicodeEscape(digits: 8)
        default:
            guard let scalar = Self.simpleEscapes[escape] else {
                throw syntax("invalid escape sequence '\\\(Character(escape))'")
            }
            return scalar
        }
    }

    private static let simpleEscapes: [Unicode.Scalar: Unicode.Scalar] = [
        "b": "\u{08}", "t": "\t", "n": "\n", "f": "\u{0C}", "r": "\r", "\"": "\"", "\\": "\\"
    ]

    private mutating func parseUnicodeEscape(digits: Int) throws(ConfigurationError) -> Unicode.Scalar {
        var hex = ""
        for _ in 0..<digits {
            guard let scalar = peek, scalar.properties.isASCIIHexDigit else {
                throw syntax("expected \(digits) hexadecimal digits in a unicode escape")
            }
            hex.unicodeScalars.append(scalar)
            index += 1
        }
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw syntax("unicode escape '\(hex)' is not a Unicode scalar value")
        }
        return scalar
    }
}
