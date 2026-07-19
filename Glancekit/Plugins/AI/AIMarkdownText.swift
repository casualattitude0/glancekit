import SwiftUI

/// Renders an assistant reply as markdown.
///
/// SwiftUI's `Text(AttributedString(markdown:))` only gets us half way: it
/// styles **bold**, *italic*, `code` and links, but markdown's *block* syntax —
/// headings, bullets, numbered lists, fenced code — is not inline syntax, so it
/// either survives as literal "- " and "**" or collapses onto one line
/// depending on the parse options. Models answer in exactly that block syntax,
/// so the reply has to be split into blocks here and each one laid out; the
/// inline parser then handles what's left inside a block, where it does work.
///
/// Deliberately small: this covers what a chat reply actually contains, not the
/// CommonMark spec. Tables, block quotes, and nested ordered lists fall through
/// to plain paragraphs rather than being half-rendered — a wrong-looking table
/// reads worse than a plain one.
struct AIMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let content):
                    inline(content)
                case .heading(let content, let level):
                    inline(content)
                        // Only three steps: a chat bubble is too narrow for a
                        // six-level hierarchy to read as one.
                        .font(level <= 1 ? .headline : level == 2 ? .subheadline.weight(.semibold) : .callout.weight(.semibold))
                case .listItem(let content, let marker, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        inline(content)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .code(let content):
                    // Code shouldn't wrap mid-token, so it scrolls sideways
                    // instead of forcing the whole bubble wider.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    /// One block, with its inline markdown parsed. Falls back to the raw string
    /// if the inline parser rejects it, so a stray bracket can never blank out a
    /// reply.
    private func inline(_ content: String) -> Text {
        let parsed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return Text(parsed ?? AttributedString(content))
    }

    // MARK: - Block parsing

    fileprivate enum Block {
        case paragraph(String)
        case heading(String, level: Int)
        /// `marker` is the literal bullet or number drawn in the gutter, so an
        /// ordered list keeps the model's own numbering rather than being
        /// renumbered from one.
        case listItem(String, marker: String, indent: Int)
        case code(String)
    }

    /// Split the reply into blocks, line by line.
    ///
    /// Consecutive plain lines are joined into one paragraph so a reply that
    /// hard-wraps mid-sentence doesn't render as a stack of fragments — but a
    /// blank line, a list item, or a heading always ends the run, which is what
    /// keeps the structure the model intended.
    fileprivate static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                } else {
                    flushParagraph()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if let item = Self.listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            paragraph.append(trimmed)
        }

        // An unterminated fence still has content worth showing.
        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(_ trimmed: String) -> Block? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // "#hashtag" is not a heading — ATX syntax requires the space.
        guard rest.first == " " else { return nil }
        return .heading(rest.trimmingCharacters(in: .whitespaces), level: hashes)
    }

    private static func listItem(_ line: String) -> Block? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            let content = String(trimmed.dropFirst(bullet.count))
            // A markdown horizontal rule ("---") reads as a bullet otherwise.
            guard !content.isEmpty else { return nil }
            return .listItem(content, marker: "•", indent: indent)
        }

        // "1. " / "2) " — keep the model's own number in the gutter.
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        let content = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .listItem(content, marker: "\(digits).", indent: indent)
    }
}
