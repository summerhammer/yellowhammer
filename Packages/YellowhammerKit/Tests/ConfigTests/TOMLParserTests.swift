@testable import Config
import Foundation
import Testing

private struct NotATable: Error {}

private func value(_ text: String, at path: [String]) throws -> TOMLValue {
    var table = try TOMLParser.parse(text, file: "test.toml")
    for key in path.dropLast() {
        guard case .table(let child) = try #require(table[key]).content else {
            throw NotATable()
        }
        table = child
    }
    return try #require(table[path[path.count - 1]])
}

private func value(_ text: String, at path: String...) throws -> TOMLValue {
    try value(text, at: path)
}

private func content(_ text: String, at path: String...) throws -> TOMLValue.Content {
    try value(text, at: path).content
}

private func parseError(_ text: String) -> ConfigurationError? {
    do {
        _ = try TOMLParser.parse(text, file: "test.toml")
        return nil
    } catch {
        return error
    }
}

// MARK: - Keys and comments

@Test("Comments, bare, quoted and dotted keys")
func keys() throws {
    let text = """
    # a comment
    bare_key-1 = 1 # trailing comment
    "quoted key" = 2
    'literal key' = 3
    site."google.com" . enabled = true
    """
    #expect(try content(text, at: "bare_key-1") == .integer(1))
    #expect(try content(text, at: "quoted key") == .integer(2))
    #expect(try content(text, at: "literal key") == .integer(3))
    #expect(try content(text, at: "site", "google.com", "enabled") == .boolean(true))
}

@Test("A key without a value, and a value without a newline, are syntax errors")
func keySyntaxErrors() {
    #expect(parseError("key =\n")?.line == 1)
    #expect(parseError("key = 1 2\n")?.key == "key")
    #expect(parseError("a = 1\n= 2\n")?.line == 2)
}

// MARK: - Strings

@Test("Basic strings decode every escape")
func basicStringEscapes() throws {
    let text = #"s = "tab\there \"q\" back\\slash \u00E9 \U0001F600 \b\f\n\r""#
    #expect(try content(text, at: "s") == .string("tab\there \"q\" back\\slash \u{E9} \u{1F600} \u{08}\u{0C}\n\r"))
}

@Test("Invalid escapes, unterminated strings and control characters are rejected")
func basicStringErrors() {
    #expect(parseError(#"s = "\x""#)?.reason == .syntax(#"invalid escape sequence '\x'"#))
    #expect(parseError(#"s = "\uD800""#) != nil)
    #expect(parseError("s = \"open\nt = 1")?.line == 1)
    #expect(parseError("s = \"a\u{01}b\"") != nil)
}

@Test("Literal strings keep backslashes")
func literalStrings() throws {
    #expect(try content(#"s = 'C:\Users\nodejs'"#, at: "s") == .string(#"C:\Users\nodejs"#))
}

@Test("Multi-line basic strings trim the first newline and line-ending backslashes")
func multilineBasicStrings() throws {
    let text = "s = \"\"\"\nRoses\r\nViolets\"\"\"\n"
        + "t = \"\"\"\\\n   The quick \\\n\n  brown.\"\"\"\n"
        + "u = \"\"\"\"\"quoted\"\"\"\"\"\n"
    #expect(try content(text, at: "s") == .string("Roses\nViolets"))
    #expect(try content(text, at: "t") == .string("The quick brown."))
    #expect(try content(text, at: "u") == .string("\"\"quoted\"\""))
    #expect(try value(text, at: "t").line == 4)
    #expect(try value(text, at: "u").line == 8)
}

@Test("Multi-line literal strings keep content verbatim")
func multilineLiteralStrings() throws {
    let text = "s = '''\nfirst \\n\n  second'''\nt = ''''one'''' \n"
    #expect(try content(text, at: "s") == .string("first \\n\n  second"))
    #expect(try content(text, at: "t") == .string("'one'"))
    #expect(parseError("s = '''open\n")?.reason == .syntax("unterminated multi-line string"))
}

// MARK: - Numbers, booleans and date-times

@Test("Integers in every base, with underscores")
func integers() throws {
    let text = "a = +99\nb = -17\nc = 1_000\nd = 0xDEAD_beef\ne = 0o755\nf = 0b1101\ng = 0"
    #expect(try content(text, at: "a") == .integer(99))
    #expect(try content(text, at: "b") == .integer(-17))
    #expect(try content(text, at: "c") == .integer(1000))
    #expect(try content(text, at: "d") == .integer(0xDEADBEEF))
    #expect(try content(text, at: "e") == .integer(0o755))
    #expect(try content(text, at: "f") == .integer(13))
    #expect(try content(text, at: "g") == .integer(0))
}

@Test("Leading zeros, doubled underscores and overflow are rejected", arguments: [
    "a = 01", "a = 1__0", "a = _1", "a = 9223372036854775808", "a = -0x1"
])
func invalidIntegers(_ text: String) {
    #expect(parseError(text) != nil)
}

@Test("Floats with fractions, exponents, inf and nan")
func floats() throws {
    let text = "a = 3.1415\nb = -0.01\nc = 5e+22\nd = 6.626e-34\ne = 224_617.445_991\nf = -inf\ng = nan"
    #expect(try content(text, at: "a") == .float(3.1415))
    #expect(try content(text, at: "b") == .float(-0.01))
    #expect(try content(text, at: "c") == .float(5e+22))
    #expect(try content(text, at: "d") == .float(6.626e-34))
    #expect(try content(text, at: "e") == .float(224_617.445_991))
    #expect(try content(text, at: "f") == .float(-.infinity))
    guard case .float(let nan) = try content(text, at: "g") else {
        Issue.record("expected a float")
        return
    }
    #expect(nan.isNaN)
    #expect(parseError("a = 1.") != nil)
    #expect(parseError("a = .5") != nil)
}

@Test("Booleans")
func booleans() throws {
    #expect(try content("a = true", at: "a") == .boolean(true))
    #expect(try content("a = false", at: "a") == .boolean(false))
    #expect(parseError("a = True") != nil)
}

@Test("Date-times are validated and kept as written")
func dateTimes() throws {
    let text = """
    a = 1979-05-27T07:32:00Z
    b = 1979-05-27 07:32:00.999-07:00
    c = 1979-05-27T07:32:00
    d = 1979-05-27
    e = 07:32:00
    """
    #expect(try content(text, at: "a") == .dateTime("1979-05-27T07:32:00Z"))
    #expect(try content(text, at: "b") == .dateTime("1979-05-27 07:32:00.999-07:00"))
    #expect(try content(text, at: "c") == .dateTime("1979-05-27T07:32:00"))
    #expect(try content(text, at: "d") == .dateTime("1979-05-27"))
    #expect(try content(text, at: "e") == .dateTime("07:32:00"))
    #expect(parseError("a = 1979-13-01") != nil)
    #expect(parseError("a = 1979-02-29T00:00:00Z") != nil)
    #expect(parseError("a = 1979-05-27T25:00:00") != nil)
}

// MARK: - Arrays and inline tables

@Test("Arrays span lines, allow a trailing comma and mix types; each element keeps its line")
func arrays() throws {
    let text = "a = [\n  1, # one\n  \"two\",\n  [3],\n  { four = 4 },\n]\n"
    let array = try value(text, at: "a")
    guard case .array(let elements) = array.content else {
        Issue.record("expected an array")
        return
    }
    #expect(elements.map(\.line) == [2, 3, 4, 5])
    #expect(elements[0].content == .integer(1))
    #expect(elements[1].content == .string("two"))
    #expect(elements[2].content == .array([TOMLValue(content: .integer(3), line: 4)]))
    #expect(parseError("a = [1 2]")?.key == "a")
    #expect(parseError("a = [1,")?.line == 1)
}

@Test("Inline tables support dotted keys and reject trailing commas, newlines and duplicates")
func inlineTables() throws {
    #expect(try content("t = { a.b = 1, c = 'x' }", at: "t", "a", "b") == .integer(1))
    #expect(try content("t = {}", at: "t") == .table(TOMLTable(entries: [], line: 1)))
    #expect(parseError("t = { a = 1, }") != nil)
    #expect(parseError("t = { a = 1,\n b = 2 }") != nil)
    #expect(parseError("t = { a = 1, a = 2 }")?.reason == .duplicateKey(firstLine: 1))
}

// MARK: - Tables

@Test("Headers, dotted headers, implicit super-tables and arrays of tables")
func tables() throws {
    let text = """
    [a.b.c]
    x = 1

    [a]
    y = 2

    [[fruits]]
    name = "apple"

    [fruits.physical]
    color = "red"

    [[fruits]]
    name = "banana"
    """
    #expect(try content(text, at: "a", "b", "c", "x") == .integer(1))
    #expect(try content(text, at: "a", "y") == .integer(2))
    #expect(try value(text, at: "a").line == 4)
    let fruits = try value(text, at: "fruits")
    guard case .array(let elements) = fruits.content, elements.count == 2 else {
        Issue.record("expected two fruits")
        return
    }
    #expect(elements.map(\.line) == [7, 13])
    guard case .table(let apple) = elements[0].content else {
        Issue.record("expected a table")
        return
    }
    #expect(apple["physical"]?.line == 10)
}

@Test("CRLF line endings count lines")
func crlf() throws {
    #expect(try value("a = 1\r\n\r\nb = 2\r\n", at: "b").line == 3)
    #expect(parseError("a = 1\rb = 2") != nil)
}

@Test("Define-once rules", arguments: [
    DefineOnceCase("[a]\n[a]", line: 2, key: "a", .tableRedefined(firstLine: 1)),
    DefineOnceCase("[a]\nb = 1\n[a.b]", line: 3, key: "a.b", .duplicateKey(firstLine: 2)),
    DefineOnceCase("a.b = 1\n[a]", line: 2, key: "a", .tableRedefined(firstLine: 1)),
    DefineOnceCase("[a.b]\n[a]\nb.c = 1", line: 3, key: "a.b", .tableRedefined(firstLine: 1)),
    DefineOnceCase("a = { b = 1 }\n[a.c]", line: 2, key: "a", .duplicateKey(firstLine: 1)),
    DefineOnceCase("a = { b = 1 }\na.c = 2", line: 2, key: "a", .duplicateKey(firstLine: 1)),
    DefineOnceCase("a = [1]\n[[a]]", line: 2, key: "a", .duplicateKey(firstLine: 1)),
    DefineOnceCase("[a]\n[[a]]", line: 2, key: "a", .tableRedefined(firstLine: 1)),
    DefineOnceCase("[[a]]\n[a]", line: 2, key: "a", .tableRedefined(firstLine: 1))
])
func defineOnce(_ testCase: DefineOnceCase) {
    let error = parseError(testCase.text)
    #expect(error?.line == testCase.line)
    #expect(error?.key == testCase.key)
    #expect(error?.reason == testCase.reason)
}

@Test("Valid ways to extend tables", arguments: [
    "[a.b]\n[a]", "[fruit]\napple.color = 'red'\n[fruit.apple.texture]\nsmooth = true", "[[a.b]]\n[[a.b]]\n[a]"
])
func validTableExtensions(_ text: String) {
    #expect(parseError(text) == nil)
}

struct DefineOnceCase: Sendable, CustomTestStringConvertible {
    let text: String
    let line: Int
    let key: String
    let reason: ConfigurationError.Reason

    init(_ text: String, line: Int, key: String, _ reason: ConfigurationError.Reason) {
        self.text = text
        self.line = line
        self.key = key
        self.reason = reason
    }

    var testDescription: String { text.replacingOccurrences(of: "\n", with: "⏎") }
}
