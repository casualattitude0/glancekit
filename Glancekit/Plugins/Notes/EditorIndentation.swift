import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Line indentation for the Notes editors.
//
// ⇥ indents the line(s) the selection touches; ⇧⇥ unindents them. Shared by both
// the markdown ("Write") field and the JSON field via an `NSTextView` extension,
// so the two behave identically — ⇥ is *always* a plain indent, never a JSON
// reformat.
//
// Everything routes through `shouldChangeText` / `didChangeText`, so a ⇥ joins
// the undo stack as one step and the SwiftUI binding updates the usual way.
// ─────────────────────────────────────────────────────────────────────────────

extension NSTextView {

    /// Indents every line the current selection touches by one `indent` unit.
    ///
    /// With no selection this indents the caret's own line and carries the caret
    /// along with its text; with a selection it re-selects the affected lines so
    /// repeated ⇥ keeps indenting the same block.
    func indentSelectedLines(with indent: String) {
        guard !indent.isEmpty else { return }
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = operatingLineRange(for: selection, in: ns)
        let starts = lineStarts(in: lineRange, in: ns)
        let unit = (indent as NSString).length

        // Rebuild the affected lines with the indent prepended.
        var rebuilt = ""
        for (i, start) in starts.enumerated() {
            let end = (i + 1 < starts.count) ? starts[i + 1] : NSMaxRange(lineRange)
            rebuilt += indent + ns.substring(with: NSRange(location: start, length: end - start))
        }

        guard replace(lineRange, with: rebuilt) else { return }

        if selection.length == 0 {
            // Caret keeps its column: it shifts right by the one indent inserted
            // on its line.
            setSelectedRange(NSRange(location: selection.location + unit, length: 0))
        } else {
            // Keep the whole block selected — each line grew by one unit.
            setSelectedRange(NSRange(
                location: lineRange.location, length: lineRange.length + unit * starts.count))
        }
    }

    /// Removes one level of leading indentation from every line the selection
    /// touches: a leading tab, or up to `indent`-width of leading spaces.
    func unindentSelectedLines(with indent: String) {
        guard !indent.isEmpty else { return }
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = operatingLineRange(for: selection, in: ns)
        let starts = lineStarts(in: lineRange, in: ns)
        let unit = (indent as NSString).length

        // How many leading characters to drop from each line, and rebuild.
        var removals: [(start: Int, count: Int)] = []
        var rebuilt = ""
        for (i, start) in starts.enumerated() {
            let end = (i + 1 < starts.count) ? starts[i + 1] : NSMaxRange(lineRange)
            let line = ns.substring(with: NSRange(location: start, length: end - start))
            let drop = leadingIndentWidth(of: line, unit: unit)
            removals.append((start, drop))
            rebuilt += String(line.dropFirst(drop))
        }

        let totalRemoved = removals.reduce(0) { $0 + $1.count }
        guard totalRemoved > 0, replace(lineRange, with: rebuilt) else { return }

        // Shift each selection edge left by however many removed characters sat
        // before it.
        func removedBefore(_ position: Int) -> Int {
            removals.reduce(0) { $0 + max(0, min($1.count, position - $1.start)) }
        }

        if selection.length == 0 {
            let caret = selection.location - removedBefore(selection.location)
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            setSelectedRange(NSRange(
                location: lineRange.location, length: lineRange.length - totalRemoved))
        }
    }

    // MARK: - Shared bits

    /// The full-line range the operation covers. A selection that ends exactly at
    /// the start of the next line (because it swept up a trailing newline) does
    /// not drag that next line in.
    private func operatingLineRange(for selection: NSRange, in ns: NSString) -> NSRange {
        var range = selection
        if selection.length > 0 {
            let end = NSMaxRange(selection)
            if end > selection.location, end <= ns.length, ns.character(at: end - 1) == 0x0A {
                range = NSRange(location: selection.location, length: selection.length - 1)
            }
        }
        return ns.lineRange(for: range)
    }

    /// The UTF-16 start offset of every line inside `lineRange`.
    private func lineStarts(in lineRange: NSRange, in ns: NSString) -> [Int] {
        var starts: [Int] = []
        var index = lineRange.location
        while index < NSMaxRange(lineRange) {
            starts.append(index)
            index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
        }
        if starts.isEmpty { starts.append(lineRange.location) }  // an empty last line
        return starts
    }

    /// How many leading characters count as one indent level: a single tab, or
    /// up to `unit` spaces.
    private func leadingIndentWidth(of line: String, unit: Int) -> Int {
        if line.first == "\t" { return 1 }
        var spaces = 0
        for character in line {
            if character == " ", spaces < unit { spaces += 1 } else { break }
        }
        return spaces
    }

    /// Replaces `range` through the undo-aware path, returning whether it took.
    private func replace(_ range: NSRange, with replacement: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        return true
    }
}
