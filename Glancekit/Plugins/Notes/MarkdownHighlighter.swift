import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// A small, iA-Writer-style markdown highlighter for the Notes editor.
//
// The design is deliberately split in two:
//
//   1. `markdownTokens(in:)` is a *pure* function — string in, ranges out, no
//      AppKit state. That is the whole point: it's the part with the fiddly
//      regex logic, and it can be driven from a standalone `swiftc` harness with
//      no app, no NSTextView, no window (see the project's testing note).
//
//   2. `MarkdownTheme` + `apply(tokens:to:...)` turn those ranges into text
//      attributes on an `NSTextStorage`. That half is trivial and doesn't need
//      testing — it's just "set this color on that range".
//
// The styling follows iA Writer's key idea: syntax *marks* (the `#`, the `**`,
// the brackets) stay visible but dimmed, rather than being hidden. What you
// typed is always exactly what you see.
// ─────────────────────────────────────────────────────────────────────────────

/// What a highlighted span *is*, independent of how it's coloured.
enum MarkdownTokenKind: Equatable {
    case heading(level: Int)   // the text of a `#`-prefixed line
    case bold                  // the content between `**`/`__`
    case italic                // the content between `*`/`_`
    case inlineCode            // the content between backticks
    case codeBlock             // a whole fenced ``` block, delimiters included
    case listMarker            // a leading `-`, `*`, `+`, or `1.`
    case blockquote            // the text of a `>`-prefixed line
    case link                  // the visible text of `[text](url)`
    case syntax                // a punctuation mark to dim (`#`, `**`, `](…)`, …)
}

/// One highlighted span: a character range and what it represents.
struct MarkdownToken: Equatable {
    let range: NSRange
    let kind: MarkdownTokenKind
}

/// Scans `string` for markdown constructs and returns the spans to style.
///
/// Content tokens come first, then every syntax-delimiter token, so that when
/// they're applied in order the dimmed delimiters always win over the content
/// colour underneath them. Spans inside fenced or inline code are not scanned
/// for further markdown — code is code.
func markdownTokens(in string: String) -> [MarkdownToken] {
    let ns = string as NSString
    let full = NSRange(location: 0, length: ns.length)

    var content: [MarkdownToken] = []
    var syntax: [MarkdownToken] = []

    // Ranges that inline scanning must skip: the insides of code, where a stray
    // `*` or `_` is a literal character, not emphasis.
    var codeRanges: [NSRange] = []

    func matches(_ pattern: String, _ options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return re.matches(in: string, range: full)
    }

    func intersectsCode(_ range: NSRange) -> Bool {
        codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    // ── Block level ──────────────────────────────────────────────────────────

    // Fenced code blocks first, so their contents are excluded from everything
    // below. Non-greedy across lines via `[\s\S]`.
    for m in matches("```[\\s\\S]*?```") {
        content.append(MarkdownToken(range: m.range, kind: .codeBlock))
        codeRanges.append(m.range)
    }

    // Inline code, single line. Also excluded from emphasis scanning.
    for m in matches("`[^`\\n]+`") where !intersectsCode(m.range) {
        content.append(MarkdownToken(range: m.range, kind: .inlineCode))
        codeRanges.append(m.range)
    }

    // ATX headings: `#`…`######` then whitespace then text.
    for m in matches("^(#{1,6})[ \\t]+(.+)$", [.anchorsMatchLines]) where !intersectsCode(m.range) {
        let hashes = m.range(at: 1)
        let level = hashes.length
        content.append(MarkdownToken(range: m.range, kind: .heading(level: level)))
        syntax.append(MarkdownToken(range: hashes, kind: .syntax))
    }

    // Blockquotes: a leading `>` (optionally indented) styles the whole line.
    for m in matches("^([ \\t]*>[ \\t]?)(.*)$", [.anchorsMatchLines]) where !intersectsCode(m.range) {
        content.append(MarkdownToken(range: m.range, kind: .blockquote))
        syntax.append(MarkdownToken(range: m.range(at: 1), kind: .syntax))
    }

    // List markers: `-`, `*`, `+`, or `1.` at the start of a line.
    for m in matches("^[ \\t]*([-*+]|\\d+\\.)[ \\t]+", [.anchorsMatchLines]) where !intersectsCode(m.range) {
        content.append(MarkdownToken(range: m.range(at: 1), kind: .listMarker))
    }

    // ── Inline level ─────────────────────────────────────────────────────────

    // Links: `[text](url)`. The visible text gets the accent; the brackets and
    // the url are dimmed as syntax.
    for m in matches("\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)") where !intersectsCode(m.range) {
        let whole = m.range
        let text = m.range(at: 1)
        content.append(MarkdownToken(range: text, kind: .link))
        // "[" before the text …
        syntax.append(MarkdownToken(
            range: NSRange(location: whole.location, length: text.location - whole.location),
            kind: .syntax))
        // … and "](url)" after it.
        let tailStart = text.location + text.length
        syntax.append(MarkdownToken(
            range: NSRange(location: tailStart, length: whole.location + whole.length - tailStart),
            kind: .syntax))
    }

    // Bold: `**text**` or `__text__`.
    for m in matches("(\\*\\*|__)(.+?)\\1") where !intersectsCode(m.range) {
        content.append(MarkdownToken(range: m.range(at: 2), kind: .bold))
        let open = m.range(at: 1)
        syntax.append(MarkdownToken(range: open, kind: .syntax))
        // The closing delimiter mirrors the opening one's length.
        let closeStart = m.range(at: 2).location + m.range(at: 2).length
        syntax.append(MarkdownToken(range: NSRange(location: closeStart, length: open.length), kind: .syntax))
    }

    // Italic: a single `*` or `_`, guarded so it doesn't fire on the `**` a bold
    // run already claimed, and doesn't span whitespace right inside the marks.
    for m in matches("(?<![*_])([*_])(?![*_\\s])(.+?)(?<![*_\\s])\\1(?![*_])") where !intersectsCode(m.range) {
        content.append(MarkdownToken(range: m.range(at: 2), kind: .italic))
        syntax.append(MarkdownToken(range: m.range(at: 1), kind: .syntax))
        let closeStart = m.range(at: 2).location + m.range(at: 2).length
        syntax.append(MarkdownToken(range: NSRange(location: closeStart, length: 1), kind: .syntax))
    }

    return content + syntax
}

// MARK: - Applying tokens to text

/// The fonts and colours a highlight pass draws with. Kept as a struct so the
/// editor can hand in system semantic colours (which follow light/dark), and so
/// a test can hand in anything and inspect what came out.
struct MarkdownTheme {
    var baseFont: NSFont
    var textColor: NSColor
    var syntaxColor: NSColor    // dimmed delimiters
    var accentColor: NSColor    // headings, list markers, links
    var codeColor: NSColor
    var codeBackground: NSColor
    var quoteColor: NSColor
    var dimmedColor: NSColor    // non-focused text in focus mode

    /// The standard iA-Writer-ish monospace look at a given point size.
    static func standard(pointSize: CGFloat) -> MarkdownTheme {
        MarkdownTheme(
            baseFont: .monospacedSystemFont(ofSize: pointSize, weight: .regular),
            textColor: .labelColor,
            syntaxColor: .tertiaryLabelColor,
            accentColor: .controlAccentColor,
            codeColor: .secondaryLabelColor,
            codeBackground: .quaternaryLabelColor.withAlphaComponent(0.18),
            quoteColor: .secondaryLabelColor,
            dimmedColor: .tertiaryLabelColor
        )
    }

    var boldFont: NSFont {
        NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    }
    var italicFont: NSFont {
        NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    }
    func headingFont(level: Int) -> NSFont {
        // Bigger for `#`, tapering toward the base size by `######`.
        let bump = max(0, CGFloat(4 - level)) * 1.5 + 1
        let font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize + bump, weight: .semibold)
        return font
    }
}

/// Repaints `storage` from scratch: a clean base pass, then the tokens, then —
/// if `focusParagraph` is given — a dimming pass over everything outside it.
///
/// `wrapAll` in one `beginEditing`/`endEditing` so the layout engine reflows
/// once, not once per attribute.
func applyMarkdownHighlight(
    to storage: NSTextStorage,
    theme: MarkdownTheme,
    focusParagraph: NSRange? = nil
) {
    let full = NSRange(location: 0, length: storage.length)
    guard full.length > 0 else { return }

    storage.beginEditing()
    defer { storage.endEditing() }

    storage.setAttributes([.font: theme.baseFont, .foregroundColor: theme.textColor], range: full)

    for token in markdownTokens(in: storage.string) {
        guard NSMaxRange(token.range) <= full.length else { continue }
        switch token.kind {
        case .heading(let level):
            storage.addAttributes([.font: theme.headingFont(level: level),
                                   .foregroundColor: theme.textColor], range: token.range)
        case .bold:
            storage.addAttribute(.font, value: theme.boldFont, range: token.range)
        case .italic:
            storage.addAttribute(.font, value: theme.italicFont, range: token.range)
        case .inlineCode, .codeBlock:
            storage.addAttributes([.foregroundColor: theme.codeColor,
                                   .backgroundColor: theme.codeBackground], range: token.range)
        case .listMarker, .link:
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: token.range)
        case .blockquote:
            storage.addAttribute(.foregroundColor, value: theme.quoteColor, range: token.range)
        case .syntax:
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: token.range)
        }
    }

    // Focus mode: flatten everything outside the active paragraph to one dim
    // colour, dropping its syntax colours entirely — the same "fade the rest of
    // the page" gesture iA Writer makes.
    if let focus = focusParagraph {
        for range in full.subtracting(focus) {
            storage.addAttribute(.foregroundColor, value: theme.dimmedColor, range: range)
        }
    }
}

private extension NSRange {
    /// The parts of `self` left after removing `other` — zero, one, or two
    /// pieces. Used to paint "everything but the focused paragraph".
    func subtracting(_ other: NSRange) -> [NSRange] {
        let clipped = NSIntersectionRange(self, other)
        guard clipped.length > 0 else { return [self] }
        var pieces: [NSRange] = []
        if clipped.location > location {
            pieces.append(NSRange(location: location, length: clipped.location - location))
        }
        let tail = clipped.location + clipped.length
        if tail < location + length {
            pieces.append(NSRange(location: tail, length: location + length - tail))
        }
        return pieces
    }
}
