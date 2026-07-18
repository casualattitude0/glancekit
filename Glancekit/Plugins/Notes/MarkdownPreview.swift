import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// A lightweight block-level markdown renderer for the Notes preview.
//
// SwiftUI's `Text(AttributedString(markdown:))` only styles *inline* runs — it
// collapses headings, lists, and blockquotes into flat paragraphs. So this
// parses the draft into blocks itself and lays each out as its own view, while
// still leaning on `AttributedString` for the inline styling *within* a block
// (bold, italic, code, links) via `Note.renderInline`.
//
// It deliberately draws no scroller of its own: the tool window already scrolls,
// and a nested one would trap the wheel (same reasoning as the saved-notes
// list). Blocks just flow and the window handles overflow.
// ─────────────────────────────────────────────────────────────────────────────

struct MarkdownPreview: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                Text("Nothing to preview yet.")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Note.renderInline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 2 : 0)

        case .paragraph(let text):
            Text(Note.renderInline(text))
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Note.renderInline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary)
                    .frame(width: 3)
                Text(Note.renderInline(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))

        case .rule:
            Divider()
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        // #=20 tapering toward the body size by ######.
        [20, 18, 16, 15, 14, 13][max(0, min(5, level - 1))]
    }
}

// MARK: - Block model

/// One rendered chunk of a note.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([Item])
    case quote(String)
    case code(String)
    case rule

    struct Item: Equatable {
        let marker: String   // "•" for bullets, "1." etc. for ordered
        let text: String
    }

    /// Splits raw markdown into blocks. Line-based and forgiving — anything it
    /// doesn't recognise becomes paragraph text, so a note always previews.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: .newlines)

        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: gather until the closing fence (or end of text).
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1 // consume the closing fence
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Heading.
            if let m = trimmed.range(of: "^#{1,6}[ \\t]+", options: .regularExpression) {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex,
                                             to: trimmed.firstIndex(where: { $0 != "#" }) ?? trimmed.startIndex)
                blocks.append(.heading(level: level, text: String(trimmed[m.upperBound...])))
                i += 1
                continue
            }

            // List: gather consecutive marker lines into one block.
            if let item = listItem(trimmed) {
                flushParagraph()
                var items: [Item] = [item]
                i += 1
                while i < lines.count,
                      let next = listItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(items))
                continue
            }

            // Blockquote: gather consecutive `>` lines.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = [stripQuote(trimmed)]
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(stripQuote(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            }

            // Anything else accumulates into the current paragraph.
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// Parses a single line as a list item, or nil if it isn't one. Ordered
    /// markers keep their number; bullets normalise to "•".
    private static func listItem(_ line: String) -> Item? {
        if let m = line.range(of: "^[-*+][ \\t]+", options: .regularExpression) {
            return Item(marker: "•", text: String(line[m.upperBound...]))
        }
        if let m = line.range(of: "^\\d+\\.[ \\t]+", options: .regularExpression) {
            let marker = line[..<m.upperBound].trimmingCharacters(in: .whitespaces)
            return Item(marker: marker, text: String(line[m.upperBound...]))
        }
        return nil
    }

    private static func stripQuote(_ line: String) -> String {
        guard let m = line.range(of: "^>[ \\t]?", options: .regularExpression) else { return line }
        return String(line[m.upperBound...])
    }
}
