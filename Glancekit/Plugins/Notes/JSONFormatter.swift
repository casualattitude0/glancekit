import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The JSON half of the Notes editor: parse, pretty-print, minify, sort, repair.
//
// Same split as `MarkdownHighlighter`: this file is *pure* — string in, string
// (or error) out, no AppKit, no view state — so it can be driven from a
// standalone `swiftc` harness with no app running.
//
// Why a hand-written parser instead of `JSONSerialization`:
//
//   • `NSDictionary` loses key order, so "format but DON'T sort" would be
//     impossible — the keys would come back in hash order, silently scrambling
//     what the user pasted.
//   • Numbers become `NSNumber`, so `1.0` round-trips as `1` and `1e9` as
//     `1000000000`. Keeping the number's source text verbatim means formatting
//     only ever changes *whitespace and key order* — never a value.
//   • A parse failure can say where it happened, which is what the editor's
//     status line shows.
//   • It can't be taught to repair. Most text that lands in this field was
//     copied out of a debugger, a log, or Python — near-JSON, not JSON. See
//     "Lenient mode" below.
//
// ── Lenient mode ─────────────────────────────────────────────────────────────
//
// Formatting parses leniently: strict JSON is a subset, so valid input behaves
// exactly as before, and near-JSON gets repaired into valid JSON on ⇥ rather
// than rejected. Every repair is *reported*, never silent — the status bar
// lists what would change before you press anything.
//
// What it accepts beyond RFC 8259:
//
//   {a: 1}              unquoted keys
//   {'a': 'b'}          single-quoted strings
//   [1, 2,]             trailing commas
//   {"a": 1} // note    // and /* */ comments
//   {True, False, None} Python's literals (a pasted dict is the common case)
//   {+1, .5, 007}       loose numbers, normalised to valid JSON
//   { {"a": 1}, {…} }   keyless members — see `resolveMembers`
// ─────────────────────────────────────────────────────────────────────────────

/// A parsed JSON document. Objects keep their keys in an array of pairs rather
/// than a dictionary, so source order survives when sorting is off.
enum JSONNode: Equatable {
    case null
    case bool(Bool)
    /// The number's source text, verbatim — never re-rendered from a Double.
    case number(String)
    case string(String)
    case array([JSONNode])
    case object([JSONMember])
}

/// One `"key": value` pair of an object.
struct JSONMember: Equatable {
    var key: String
    var value: JSONNode
}

/// What a lenient parse produced, and what it had to fix to get there.
struct JSONParseResult: Equatable {
    let node: JSONNode
    /// Human-readable repair notes, e.g. `["trailing comma ×2", "unquoted key"]`.
    /// Empty when the input was already strict JSON.
    let repairs: [String]

    var wasRepaired: Bool { !repairs.isEmpty }
}

/// Why a document wouldn't parse, and where.
struct JSONParseError: Error, Equatable {
    let message: String
    /// 1-based, for a human-readable status line.
    let line: Int
    let column: Int

    var localizedDescription: String { "\(message) (line \(line), column \(column))" }
}

// MARK: - Public entry points

/// Pretty-prints `text`, optionally sorting every object's keys.
///
/// Parses leniently, so near-JSON is repaired rather than refused. Throws
/// `JSONParseError` when even that can't make sense of it — the caller shows
/// the message rather than mangling what the user typed.
func formatJSON(_ text: String, indent: Int = 2, sortKeys: Bool = true) throws -> String {
    renderJSON(try parseJSONLeniently(text).node, indent: indent, sortKeys: sortKeys)
}

/// Collapses `text` onto a single line, optionally sorting keys.
func minifyJSON(_ text: String, sortKeys: Bool = true) throws -> String {
    renderJSON(try parseJSONLeniently(text).node, indent: 0, sortKeys: sortKeys)
}

/// Parses a whole document by the book. Trailing content after the top-level
/// value is an error, so a half-pasted second object doesn't silently vanish.
func parseJSON(_ text: String) throws -> JSONNode {
    var parser = JSONParser(text, lenient: false)
    let node = try parser.parseValue()
    try parser.expectEndOfInput()
    return node
}

/// Parses `text`, repairing the near-JSON listed in this file's header, and
/// reports every repair it made.
func parseJSONLeniently(_ text: String) throws -> JSONParseResult {
    var parser = JSONParser(text, lenient: true)
    let node = try parser.parseValue()
    try parser.expectEndOfInput()
    return JSONParseResult(node: node, repairs: parser.repairs)
}

/// Renders a parsed document back to text.
///
/// `indent` of 0 means minified — one line, no spaces. Sorting is
/// case-insensitive with a case-sensitive tiebreak, so `Name` and `name` land
/// next to each other in a stable order rather than in ASCII order (all
/// capitals first), which is how a human would file them.
func renderJSON(_ node: JSONNode, indent: Int = 2, sortKeys: Bool = true) -> String {
    var out = ""
    writeJSON(node, into: &out, indent: indent, sortKeys: sortKeys, depth: 0)
    return out
}

/// Orders object keys the way `renderJSON(sortKeys: true)` does.
func jsonKeysAreOrdered(_ a: String, _ b: String) -> Bool {
    let cased = a.compare(b, options: [.caseInsensitive, .numeric])
    if cased != .orderedSame { return cased == .orderedAscending }
    return a < b
}

// MARK: - Rendering

private func writeJSON(
    _ node: JSONNode, into out: inout String, indent: Int, sortKeys: Bool, depth: Int
) {
    let pretty = indent > 0
    let pad = pretty ? String(repeating: " ", count: indent * depth) : ""
    let innerPad = pretty ? String(repeating: " ", count: indent * (depth + 1)) : ""
    let newline = pretty ? "\n" : ""
    let colon = pretty ? ": " : ":"

    switch node {
    case .null:
        out += "null"
    case .bool(let value):
        out += value ? "true" : "false"
    case .number(let text):
        out += text
    case .string(let text):
        out += quoteJSONString(text)

    case .array(let elements):
        // An empty container stays `[]` rather than becoming two lines — the
        // convention every formatter follows, and it keeps sparse data compact.
        guard !elements.isEmpty else { out += "[]"; return }
        out += "[" + newline
        for (offset, element) in elements.enumerated() {
            out += innerPad
            writeJSON(element, into: &out, indent: indent, sortKeys: sortKeys, depth: depth + 1)
            if offset < elements.count - 1 { out += "," }
            out += newline
        }
        out += pad + "]"

    case .object(let members):
        guard !members.isEmpty else { out += "{}"; return }
        let ordered = sortKeys
            ? members.sorted { jsonKeysAreOrdered($0.key, $1.key) }
            : members
        out += "{" + newline
        for (offset, member) in ordered.enumerated() {
            out += innerPad + quoteJSONString(member.key) + colon
            writeJSON(member.value, into: &out, indent: indent, sortKeys: sortKeys, depth: depth + 1)
            if offset < ordered.count - 1 { out += "," }
            out += newline
        }
        out += pad + "}"
    }
}

/// Escapes a string to a JSON literal. Non-ASCII is left alone — the editor is
/// UTF-8 throughout, and `\u`-escaping emoji would only make the text harder to
/// read than what the user pasted.
func quoteJSONString(_ string: String) -> String {
    var out = "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// Rewrites the three number spellings JSON rejects into the one it accepts:
/// `+1` → `1`, `.5` → `0.5`, `007` → `7`, `1.` → `1`.
///
/// Each has exactly one valid-JSON form with the same value, which is why these
/// are safe to normalise while `1.0` and `1e9` are left alone — those already
/// parse, so touching them would change the document for no reason.
func normalizeLooseNumber(_ text: String) -> String {
    var body = Substring(text)

    var sign = ""
    if body.hasPrefix("+") { body = body.dropFirst() }
    else if body.hasPrefix("-") { sign = "-"; body = body.dropFirst() }

    // Split the exponent off; it has its own sign and never needs repair.
    var exponent = ""
    if let marker = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exponent = String(body[marker...])
        body = body[..<marker]
    }

    var integerPart = body
    var fractionPart = Substring("")
    if let dot = body.firstIndex(of: ".") {
        integerPart = body[..<dot]
        fractionPart = body[body.index(after: dot)...]
    }

    let digits = integerPart.drop { $0 == "0" }
    // `0`, `000`, and `.5` all need a single leading zero to be legal.
    let integer = digits.isEmpty ? "0" : String(digits)
    let fraction = fractionPart.isEmpty ? "" : "." + fractionPart

    return sign + integer + fraction + exponent
}

// MARK: - Parsing

/// A single-pass RFC 8259 parser over the text's unicode scalars, with an
/// opt-in repair mode.
///
/// Strict by default on purpose: the *status line* has to be able to tell you
/// your JSON is wrong. Leniency is a separate mode used by the format actions,
/// and everything it forgives is recorded in `repairs` so the fix is never
/// invisible.
private struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private let lenient: Bool

    /// Repair kinds in first-seen order, with how many times each fired.
    private var repairLog: [(kind: String, count: Int)] = []

    init(_ text: String, lenient: Bool) {
        scalars = Array(text.unicodeScalars)
        self.lenient = lenient
    }

    var repairs: [String] {
        repairLog.map { $0.count > 1 ? "\($0.kind) ×\($0.count)" : $0.kind }
    }

    private mutating func note(_ kind: String) {
        if let existing = repairLog.firstIndex(where: { $0.kind == kind }) {
            repairLog[existing].count += 1
        } else {
            repairLog.append((kind: kind, count: 1))
        }
    }

    // MARK: Values

    mutating func parseValue() throws -> JSONNode {
        skipIgnorable()
        guard let scalar = peek() else { throw error("Empty document") }

        switch scalar {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "'":
            guard lenient else { throw error("Strings must use double quotes") }
            note("single-quoted string")
            return .string(try parseString())
        default:
            if scalar == "-" || scalar == "+" || scalar == "." || ("0"..."9").contains(scalar) {
                return .number(try parseNumber())
            }
            if isIdentifierScalar(scalar) { return try parseWordValue() }
            throw error("Unexpected character \(describe(scalar))")
        }
    }

    /// `true` / `false` / `null`, plus — leniently — Python's `True` / `False` /
    /// `None` and any other bare word, which becomes a string.
    private mutating func parseWordValue() throws -> JSONNode {
        let start = index
        while let scalar = peek(), isIdentifierScalar(scalar) { advance() }
        let word = String(String.UnicodeScalarView(scalars[start..<index]))

        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }

        guard lenient else { throw error("Expected true, false, or null") }

        switch word {
        case "True", "False", "None":
            note("Python literal")
            return word == "None" ? .null : .bool(word == "True")
        default:
            // A bare word becomes a string. That does change a value, so it's
            // logged loudly — it's the one repair that isn't purely syntactic.
            note("unquoted value → string")
            return .string(word)
        }
    }

    private mutating func parseObject() throws -> JSONNode {
        advance()  // {
        // Keys are optional here so lenient input can carry keyless members;
        // `resolveMembers` decides what the result actually is.
        var members: [(key: String?, value: JSONNode)] = []
        skipIgnorable()
        if peek() == "}" { advance(); return try resolveMembers(members) }

        while true {
            skipIgnorable()
            // A `}` right here means the previous member ended with a comma.
            if peek() == "}" {
                guard lenient else { throw error("Expected a quoted key") }
                note("trailing comma")
                advance()
                return try resolveMembers(members)
            }
            members.append(try parseMember())
            skipIgnorable()
            switch peek() {
            case ",": advance()
            case "}": advance(); return try resolveMembers(members)
            case nil: throw error("Unclosed object")
            default: throw error("Expected ',' or '}' in object")
            }
        }
    }

    /// One `key: value`, or — leniently — a bare value with no key at all.
    ///
    /// The key can't be decided by lookahead alone: `{"a": 1}` and `{ {"a": 1} }`
    /// both start with `"`. So it parses whatever is there and then looks for
    /// the colon, treating what it read as a key if one shows up and as a
    /// keyless value if one doesn't.
    private mutating func parseMember() throws -> (key: String?, value: JSONNode) {
        guard let scalar = peek() else { throw error("Unclosed object") }

        if scalar == "\"" || (lenient && scalar == "'") {
            if scalar == "'" { note("single-quoted string") }
            let text = try parseString()
            skipIgnorable()
            if peek() == ":" {
                advance()
                return (key: text, value: try parseValue())
            }
            guard lenient else { throw error("Expected ':' after key \"\(text)\"") }
            note("member without a key")
            return (key: nil, value: .string(text))
        }

        if lenient, isIdentifierScalar(scalar) {
            // Could be an unquoted key, or a keyless `true`/`None`/bare word.
            let start = index
            while let next = peek(), isIdentifierScalar(next) { advance() }
            let word = String(String.UnicodeScalarView(scalars[start..<index]))
            skipIgnorable()
            if peek() == ":" {
                advance()
                note("unquoted key")
                return (key: word, value: try parseValue())
            }
            index = start  // put it back; it's a value, not a key
            note("member without a key")
            return (key: nil, value: try parseValue())
        }

        guard lenient else { throw error("Expected a quoted key") }
        note("member without a key")
        return (key: nil, value: try parseValue())
    }

    /// Turns the collected members into a node.
    ///
    /// A brace-wrapped run of keyless members — the `{ {…}, {…} }` shape that
    /// shows up when someone hand-assembles records — is *a list*, so it
    /// becomes an array. That preserves every value and needs no invented
    /// names.
    ///
    /// Mixed keyed and keyless members can't become an array without losing the
    /// keys, so the keyless ones get positional names instead. Both repairs are
    /// logged, because both change the document's shape rather than its
    /// whitespace.
    private mutating func resolveMembers(
        _ members: [(key: String?, value: JSONNode)]
    ) throws -> JSONNode {
        guard members.contains(where: { $0.key == nil }) else {
            return .object(members.map { JSONMember(key: $0.key ?? "", value: $0.value) })
        }

        if members.allSatisfy({ $0.key == nil }) {
            note("keyless object → array")
            return .array(members.map(\.value))
        }

        note("keyless member → positional key")
        var position = 0
        return .object(members.map { member in
            if let key = member.key { return JSONMember(key: key, value: member.value) }
            position += 1
            return JSONMember(key: "item\(position)", value: member.value)
        })
    }

    private mutating func parseArray() throws -> JSONNode {
        advance()  // [
        var elements: [JSONNode] = []
        skipIgnorable()
        if peek() == "]" { advance(); return .array(elements) }

        while true {
            skipIgnorable()
            if peek() == "]" {
                guard lenient else { throw error("Expected a value") }
                note("trailing comma")
                advance()
                return .array(elements)
            }
            elements.append(try parseValue())
            skipIgnorable()
            switch peek() {
            case ",": advance()
            case "]": advance(); return .array(elements)
            case nil: throw error("Unclosed array")
            default: throw error("Expected ',' or ']' in array")
            }
        }
    }

    /// Reads a `"…"` string — or, leniently, a `'…'` one. The closing quote has
    /// to match the opening one, so an apostrophe inside a double-quoted string
    /// stays an apostrophe.
    private mutating func parseString() throws -> String {
        guard let quote = peek() else { throw error("Expected a string") }
        advance()  // opening quote
        var out = String.UnicodeScalarView()

        while let scalar = peek() {
            advance()
            switch scalar {
            case quote:
                return String(out)
            case "\\":
                guard let escape = peek() else { throw error("Unfinished escape") }
                advance()
                switch escape {
                case "\"": out.append("\"")
                case "'": out.append("'")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u": out.append(try parseUnicodeEscape())
                default: throw error("Invalid escape \\\(escape)")
                }
            default:
                if scalar.value < 0x20 { throw error("Control character in string") }
                out.append(scalar)
            }
        }
        throw error("Unclosed string")
    }

    /// Reads the four hex digits after `\u`, joining a surrogate pair with the
    /// `\uXXXX` that follows it so astral characters (emoji) survive a round
    /// trip instead of decomposing into two broken halves.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let high = try parseHexQuad()
        if (0xD800...0xDBFF).contains(high) {
            guard peek() == "\\" else { throw error("Lone surrogate in string") }
            advance()
            guard peek() == "u" else { throw error("Lone surrogate in string") }
            advance()
            let low = try parseHexQuad()
            guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid surrogate pair") }
            let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { throw error("Invalid surrogate pair") }
            return scalar
        }
        guard let scalar = Unicode.Scalar(high) else { throw error("Invalid \\u escape") }
        return scalar
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = peek(), let digit = Character(scalar).hexDigitValue else {
                throw error("Invalid \\u escape")
            }
            advance()
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    /// Grammar-checks the number and returns its *source text*, so `1.0`,
    /// `1e9`, and `-0` come back out exactly as they went in.
    ///
    /// Leniently, the three shapes JSON rejects but everything else writes —
    /// `+1`, `.5`, `007` — are accepted and normalised. Normalising is safe
    /// here: each has exactly one valid-JSON spelling with the same value.
    private mutating func parseNumber() throws -> String {
        let start = index
        // Set by any repair, and the *only* thing that lets the source text be
        // rewritten. A number that parses strictly is returned untouched.
        var loose = false

        if peek() == "+" {
            guard lenient else { throw error("A number can't start with '+'") }
            note("leading '+'")
            loose = true
            advance()
        } else if peek() == "-" {
            advance()
        }

        let integerStart = index
        skipDigits()
        let integerDigits = index - integerStart

        if integerDigits == 0 {
            guard peek() == "." else { throw error("Expected a digit") }
            guard lenient else { throw error("Expected a digit") }
            note("bare '.5' number")
            loose = true
        } else if integerDigits > 1, scalars[integerStart] == "0" {
            guard lenient else { throw error("A number can't have a leading zero") }
            note("leading zero")
            loose = true
        }

        if peek() == "." {
            advance()
            let fractionStart = index
            skipDigits()
            if index == fractionStart {
                guard lenient else { throw error("Expected a digit after '.'") }
                note("trailing '.'")
                loose = true
            }
        }

        if peek() == "e" || peek() == "E" {
            advance()
            if peek() == "+" || peek() == "-" { advance() }
            let exponentStart = index
            skipDigits()
            if index == exponentStart { throw error("Expected a digit in the exponent") }
        }

        let source = String(String.UnicodeScalarView(scalars[start..<index]))
        return loose ? normalizeLooseNumber(source) : source
    }

    mutating func expectEndOfInput() throws {
        skipIgnorable()
        if let scalar = peek() {
            throw error("Unexpected \(describe(scalar)) after the end of the document")
        }
    }

    // MARK: Cursor

    private func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() { index += 1 }

    private mutating func skipDigits() {
        while let scalar = peek(), ("0"..."9").contains(scalar) { advance() }
    }

    private func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
            || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "$"
    }

    /// Whitespace, plus — leniently — `//` and `/* */` comments.
    private mutating func skipIgnorable() {
        while true {
            while let scalar = peek(),
                  scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                advance()
            }
            guard lenient, peek() == "/", let next = scalars[safe: index + 1] else { return }
            if next == "/" {
                note("comment")
                while let scalar = peek(), scalar != "\n" { advance() }
            } else if next == "*" {
                note("comment")
                advance(); advance()
                while index < scalars.count {
                    if peek() == "*", scalars[safe: index + 1] == "/" {
                        advance(); advance()
                        break
                    }
                    advance()
                }
            } else {
                return
            }
        }
    }

    private func describe(_ scalar: Unicode.Scalar) -> String {
        scalar.value < 0x20 ? "control character" : "'\(scalar)'"
    }

    /// Builds an error carrying the current 1-based line/column.
    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for scalar in scalars[0..<min(index, scalars.count)] {
            if scalar == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }
}

private extension Array {
    /// Bounds-checked lookahead — the parser peeks one past the cursor often
    /// enough that guarding each site by hand would bury the logic.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
