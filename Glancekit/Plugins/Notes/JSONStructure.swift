import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The nesting structure of a JSON document: which bracket matches which, how
// deep each pair sits, and how much is inside it.
//
// This is what the editor's gutter folds on and what the bracket colours cycle
// through, so — like `jsonTokens` — it runs on the *forgiving* lexer, not the
// parser. Half-typed text still has structure worth showing; a document that
// doesn't parse yet must still fold and colour.
//
// Pure: string in, offsets out. Harness-testable with no app.
// ─────────────────────────────────────────────────────────────────────────────

/// One bracket pair and what's inside it.
struct JSONBlock: Equatable {
    /// UTF-16 offset of the opening `{` or `[`.
    let open: Int
    /// UTF-16 offset of the matching close, or nil while it's still unclosed.
    let close: Int?
    /// 0 for the outermost pair, 1 for its children, and so on. Bracket colours
    /// cycle on this.
    let depth: Int
    let isObject: Bool
    /// Members or elements directly inside — the count the collapsed row shows.
    let count: Int

    /// The text between the brackets, exclusive — what folding hides.
    var interior: NSRange? {
        guard let close else { return nil }
        return NSRange(location: open + 1, length: close - open - 1)
    }

    /// "3 keys" / "12 items", for the collapsed summary.
    var summary: String {
        let noun = isObject ? "key" : "item"
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// Matches every bracket pair in `string`, tolerating unclosed ones.
///
/// Brackets inside string literals are skipped, which is the whole reason this
/// walks the token stream rather than scanning for braces directly — a `{` in
/// `{"pattern": "^\\{"}` is data, not structure.
func jsonBlocks(in string: String) -> [JSONBlock] {
    let ns = string as NSString

    /// An open bracket still looking for its partner.
    struct Frame {
        let open: Int
        let isObject: Bool
        let depth: Int
        var commas: Int = 0
        /// Whether anything at all sits inside — an empty `{}` has 0 members,
        /// but `{"a":1}` has no commas and 1 member, so counting commas alone
        /// isn't enough.
        var hasContent = false
    }

    var stack: [Frame] = []
    var blocks: [JSONBlock] = []

    func finish(_ frame: Frame, close: Int?) {
        blocks.append(JSONBlock(
            open: frame.open,
            close: close,
            depth: frame.depth,
            isObject: frame.isObject,
            count: frame.hasContent ? frame.commas + 1 : 0))
    }

    for token in jsonTokens(in: string) {
        guard token.kind == .punctuation else {
            if !stack.isEmpty { stack[stack.count - 1].hasContent = true }
            continue
        }

        switch ns.substring(with: token.range) {
        case "{", "[":
            if !stack.isEmpty { stack[stack.count - 1].hasContent = true }
            stack.append(Frame(
                open: token.range.location,
                isObject: ns.substring(with: token.range) == "{",
                depth: stack.count))
        case "}", "]":
            guard let frame = stack.popLast() else { continue }  // stray closer
            finish(frame, close: token.range.location)
        case ",":
            if !stack.isEmpty { stack[stack.count - 1].commas += 1 }
        default:
            break  // ':' carries no structure of its own
        }
    }

    // Whatever is still open is a block the user hasn't finished typing. It
    // still colours and still reports a depth; it just can't fold.
    for frame in stack.reversed() { finish(frame, close: nil) }

    return blocks.sorted { $0.open < $1.open }
}

/// The innermost block containing `offset`, if any.
func jsonBlock(containing offset: Int, in blocks: [JSONBlock]) -> JSONBlock? {
    blocks
        .filter { block in
            guard let close = block.close else { return false }
            return block.open <= offset && offset <= close
        }
        .max { $0.depth < $1.depth }
}

/// The bracket pair to emphasise for a caret at `offset` — the pair the caret
/// sits directly beside, or failing that the innermost pair it's inside.
///
/// Beside-first is what makes the highlight feel like it's tracking you: land
/// on a `}` and it lights up *that* pair, rather than the parent you're
/// technically also inside.
func jsonBracketPair(forCaretAt offset: Int, in blocks: [JSONBlock]) -> JSONBlock? {
    let adjacent = blocks.first { block in
        guard let close = block.close else { return block.open == offset || block.open + 1 == offset }
        return block.open == offset || block.open + 1 == offset
            || close == offset || close + 1 == offset
    }
    return adjacent ?? jsonBlock(containing: offset, in: blocks)
}
