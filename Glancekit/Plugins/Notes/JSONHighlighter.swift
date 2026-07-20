import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Syntax colouring for the Notes editor's JSON mode.
//
// Split like `MarkdownHighlighter`: `jsonTokens(in:)` is pure (string in, ranges
// out) and testable from a `swiftc` harness; applying them to an `NSTextStorage`
// is the trivial half.
//
// It deliberately does NOT reuse the parser in `JSONFormatter`: highlighting has
// to keep working on half-typed, not-yet-valid text — the common case while you
// paste and edit. So this is a forgiving lexer that colours what it can
// recognise and skips what it can't.
// ─────────────────────────────────────────────────────────────────────────────

enum JSONTokenKind: Equatable {
    case key        // a string used as an object key (the `"a"` in `"a": 1`)
    case string     // any other string literal
    case number
    case literal    // true / false / null
    case punctuation  // braces, brackets, commas, colons
}

struct JSONToken: Equatable {
    let range: NSRange
    let kind: JSONTokenKind
}

/// Lexes `string` into colourable spans, tolerating malformed input.
///
/// A string literal becomes `.key` rather than `.string` when the next
/// non-whitespace character after it is a colon — the same cue a reader uses,
/// and one that survives text that doesn't parse.
func jsonTokens(in string: String) -> [JSONToken] {
    let scalars = Array(string.unicodeScalars)
    // NSRange is UTF-16-based, so track UTF-16 offsets alongside the scalar
    // index — anything astral (an emoji in a value) would otherwise shift every
    // range after it.
    var utf16Offset = 0
    var index = 0
    var tokens: [JSONToken] = []

    /// Index of the last string token emitted, so a following `:` can promote it.
    var lastStringToken: Int?

    func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    while index < scalars.count {
        let scalar = scalars[index]
        let start = utf16Offset

        switch scalar {
        case "\"":
            // Scan to the closing quote, honouring backslash escapes. An
            // unterminated string (still being typed) colours to end of line.
            var scanner = index + 1
            var width = UInt32(scalar.utf16.count)
            while scanner < scalars.count {
                let next = scalars[scanner]
                width += UInt32(next.utf16.count)
                if next == "\\" {
                    scanner += 1
                    if scanner < scalars.count { width += UInt32(scalars[scanner].utf16.count) }
                } else if next == "\"" {
                    scanner += 1
                    break
                } else if next == "\n" {
                    // Bail before the newline: don't paint the rest of the file.
                    width -= UInt32(next.utf16.count)
                    break
                }
                scanner += 1
            }
            tokens.append(JSONToken(range: NSRange(location: start, length: Int(width)), kind: .string))
            lastStringToken = tokens.count - 1
            utf16Offset += Int(width)
            index = scanner

        case "{", "}", "[", "]", ",", ":":
            if scalar == ":", let last = lastStringToken {
                // The string just before this colon is a key.
                tokens[last] = JSONToken(range: tokens[last].range, kind: .key)
            }
            tokens.append(JSONToken(range: NSRange(location: start, length: 1), kind: .punctuation))
            if scalar != ":" { lastStringToken = nil }
            utf16Offset += 1
            index += 1

        case "t", "f", "n":
            var scanner = index
            while scanner < scalars.count, ("a"..."z").contains(scalars[scanner]) { scanner += 1 }
            let word = String(String.UnicodeScalarView(scalars[index..<scanner]))
            if word == "true" || word == "false" || word == "null" {
                tokens.append(JSONToken(
                    location: start, length: word.utf16.count, kind: .literal))
            }
            utf16Offset += word.utf16.count
            index = scanner
            lastStringToken = nil

        default:
            if scalar == "-" || isDigit(scalar) {
                var scanner = index + 1
                while scanner < scalars.count,
                      isDigit(scalars[scanner]) || "+-.eE".unicodeScalars.contains(scalars[scanner]) {
                    scanner += 1
                }
                let length = scanner - index  // digits and signs are all 1 UTF-16 unit
                tokens.append(JSONToken(
                    location: start, length: length, kind: .number))
                utf16Offset += length
                index = scanner
            } else {
                // Whitespace or junk: skip, but a newline between a string and
                // its would-be colon still counts as whitespace, so only reset
                // the pending-key cue on something substantive.
                if !scalar.properties.isWhitespace { lastStringToken = nil }
                utf16Offset += scalar.utf16.count
                index += 1
            }
            continue
        }
    }

    return tokens
}

private extension JSONToken {
    init(location: Int, length: Int, kind: JSONTokenKind) {
        self.init(range: NSRange(location: location, length: length), kind: kind)
    }
}

// MARK: - Applying tokens to text

/// The colours a JSON highlight pass draws with. Semantic system colours, so it
/// follows light/dark like the markdown theme does.
struct JSONTheme {
    var baseFont: NSFont
    var textColor: NSColor
    var keyColor: NSColor
    var stringColor: NSColor
    var numberColor: NSColor
    var literalColor: NSColor
    var punctuationColor: NSColor
    /// Cycled by nesting depth, so a bracket and its partner share a tint and
    /// you can tell which `}` closes which `{` without counting. Kept short and
    /// distinct — more colours than this stop being distinguishable at a
    /// glance and start looking like confetti.
    var bracketColors: [NSColor]
    /// Behind the bracket pair the caret is on.
    var emphasisBackground: NSColor

    static func standard(pointSize: CGFloat) -> JSONTheme {
        JSONTheme(
            baseFont: .monospacedSystemFont(ofSize: pointSize, weight: .regular),
            textColor: .labelColor,
            // Keys carry the accent, the way headings do in markdown mode: they
            // are the structure you scan for.
            keyColor: .controlAccentColor,
            stringColor: .systemGreen,
            numberColor: .systemOrange,
            literalColor: .systemPurple,
            // Commas and colons dim out, same idea as dimmed markdown syntax.
            // Brackets are the exception — they get `bracketColors` by depth.
            punctuationColor: .tertiaryLabelColor,
            bracketColors: [.systemRed, .systemBlue, .systemTeal],
            emphasisBackground: .selectedTextBackgroundColor
        )
    }

    var keyFont: NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
    }

    /// Brackets carry weight as well as colour — the structure should read even
    /// for someone who can't tell the tints apart.
    var bracketFont: NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold)
    }
}

/// Repaints `storage` as JSON: a clean base pass, then the tokens, then the
/// bracket structure on top.
///
/// `blocks` tints each bracket pair by nesting depth; `emphasized` is the pair
/// the caret is on, which gets a background chip so you can see where the block
/// you're in begins and ends.
func applyJSONHighlight(
    to storage: NSTextStorage,
    theme: JSONTheme,
    blocks: [JSONBlock] = [],
    emphasized: JSONBlock? = nil
) {
    let full = NSRange(location: 0, length: storage.length)
    guard full.length > 0 else { return }

    storage.beginEditing()
    defer { storage.endEditing() }

    storage.setAttributes([.font: theme.baseFont, .foregroundColor: theme.textColor], range: full)

    for token in jsonTokens(in: storage.string) {
        guard NSMaxRange(token.range) <= full.length else { continue }
        switch token.kind {
        case .key:
            storage.addAttributes([.font: theme.keyFont,
                                   .foregroundColor: theme.keyColor], range: token.range)
        case .string:
            storage.addAttribute(.foregroundColor, value: theme.stringColor, range: token.range)
        case .number:
            storage.addAttribute(.foregroundColor, value: theme.numberColor, range: token.range)
        case .literal:
            storage.addAttribute(.foregroundColor, value: theme.literalColor, range: token.range)
        case .punctuation:
            storage.addAttribute(.foregroundColor, value: theme.punctuationColor, range: token.range)
        }
    }

    // Brackets last, so the depth tint wins over the flat punctuation colour.
    guard !theme.bracketColors.isEmpty else { return }
    for block in blocks {
        let color = theme.bracketColors[block.depth % theme.bracketColors.count]
        for location in [block.open, block.close].compactMap({ $0 }) {
            let range = NSRange(location: location, length: 1)
            guard NSMaxRange(range) <= full.length else { continue }
            storage.addAttributes([.foregroundColor: color, .font: theme.bracketFont], range: range)
        }
    }

    if let emphasized {
        for location in [emphasized.open, emphasized.close].compactMap({ $0 }) {
            let range = NSRange(location: location, length: 1)
            guard NSMaxRange(range) <= full.length else { continue }
            storage.addAttribute(.backgroundColor, value: theme.emphasisBackground, range: range)
        }
    }
}
