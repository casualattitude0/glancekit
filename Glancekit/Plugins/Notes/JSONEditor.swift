import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The JSON editing surface: a monospaced field with an in-margin fold gutter,
// depth-tinted brackets, indent guides, and ⇥ / ⇧⇥ bound to format / minify.
//
// It's a separate `NSViewRepresentable` from `MarkdownEditor` rather than
// another flag on it, because the two need different TextKit stacks:
//
//   • Markdown is happy with whatever `NSTextView()` gives it (TextKit 2 on
//     macOS 14).
//   • Folding is implemented by suppressing *glyphs*, which is TextKit 1's
//     `NSLayoutManager` delegate. So this one builds its stack by hand to pin
//     TextKit 1 — `NSTextView(frame:textContainer:)` is the documented way to
//     opt out.
//
// Why glyph suppression and not "delete the text and put it back": the document
// stays intact while folded. Nothing can save a placeholder to disk, the find
// bar still searches inside collapsed blocks, and undo never sees a fold. A
// fold is purely how the text is *drawn*.
//
// ── Rewrite notes (what this version fixes) ──────────────────────────────────
//
// The old version drove the fold gutter with an `NSRulerView`, which drew its
// controls *outside* the scroll view's clip and into the neighbouring SwiftUI
// views — the stray ⊟ marks below the field, and the "saved list keeps
// flickering" that came from the ruler re-invalidating on every keystroke.
// The gutter now lives *inside* the text view's own left inset, in the same
// coordinate space as the indent guides, so it can only ever draw where the
// text draws and scrolls/clips for free.
//
// The old version also re-lexed and re-`setAttributes`'d the *entire* document
// on every `textDidChange`, every `textViewDidChangeSelection`, and again inside
// `updateNSView` — three full passes per keystroke, which stomped on IME marked
// text (CJK composition) and thrashed layout. Now there is one highlight pass
// per actual edit, selection changes only re-tint the caret's bracket pair, and
// nothing touches the storage while marked text is being composed.
// ─────────────────────────────────────────────────────────────────────────────

/// A handle on the editor's folding, for controls that live outside the text
/// view (the status bar's Fold All / Expand All).
///
/// SwiftUI has no way to reach into an `NSViewRepresentable`'s view, and
/// threading every fold action through the binding would put view state into
/// the model. A weak handle keeps folding where it belongs — in the view — and
/// still lets a button ask for it.
@MainActor
final class JSONFoldController {
    fileprivate weak var textView: FoldingTextView?

    func foldAll() { textView?.foldAll() }
    func expandAll() { textView?.clearFolds() }

    /// Whether there's anything to fold, so the buttons can disable rather than
    /// sit there doing nothing.
    var hasFoldableBlocks: Bool { !(textView?.foldableBlocks.isEmpty ?? true) }
}

struct JSONEditor: NSViewRepresentable {
    @Binding var text: String
    /// Optional handle letting outside controls fold and unfold.
    var foldController: JSONFoldController?
    /// Set true to request first-responder; the view resets it to false.
    @Binding var wantsFocus: Bool
    var fontSize: CGFloat = 13
    /// Spaces per indent level. ⇥ inserts this many; ⇧⇥ removes them.
    var indentWidth: Int = 2
    /// Fires when ⌘↩ is pressed — the popover saves the note.
    var onCommandReturn: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        // TextKit 1, explicitly: storage → layout manager → container → view.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let contentSize = scrollView.contentSize
        let bigDimension = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(
            size: NSSize(width: contentSize.width, height: bigDimension))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = FoldingTextView(
            frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: bigDimension, height: bigDimension)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.delegate = context.coordinator
        layoutManager.delegate = textView

        textView.onCommandReturn = { context.coordinator.parent.onCommandReturn() }
        textView.indentWidth = indentWidth

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Prose spellcheck on a payload of identifiers is nothing but red
        // squiggles, so JSON mode turns it off outright.
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        // The left inset is the fold gutter's home. Text starts after it; the
        // fold controls are drawn into it (see `FoldingTextView.gutterWidth`).
        textView.textContainerInset = NSSize(width: FoldingTextView.gutterWidth, height: 8)
        textView.fontSize = fontSize
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        textView.string = text
        scrollView.documentView = textView

        foldController?.textView = textView

        textView.relex()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FoldingTextView else { return }

        context.coordinator.parent = self
        textView.indentWidth = indentWidth

        // Only touch the storage when the text genuinely came from *outside* the
        // view (a ⇥ reformat, an edit from elsewhere). During plain typing the
        // strings already match, so this whole block is skipped — which is what
        // keeps typing from thrashing layout and flickering the sibling views.
        if textView.string != text {
            let selected = textView.selectedRange()
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            // Replace *through* the text view rather than assigning `.string`,
            // so the swap joins the undo stack: ⌘Z after a ⇥ reformat puts back
            // exactly what you pasted. `didChangeText()` then routes back through
            // the delegate's `textDidChange`, which re-lexes once.
            if textView.shouldChangeText(in: whole, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: whole, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
                textView.clearFolds()
                textView.relex()
            }
            textView.setSelectedRange(NSRange(
                location: min(selected.location, (text as NSString).length), length: 0))
        }

        if textView.fontSize != fontSize {
            textView.fontSize = fontSize
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.typingAttributes = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            textView.relex()
        }

        if wantsFocus {
            // Defer: the window may not be key yet on the same runloop turn the
            // popover appears.
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                wantsFocus = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor

        init(_ parent: JSONEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? FoldingTextView else { return }
            // `updateNSView` also routes its writes through `didChangeText`, which
            // lands here. Writing the binding again from inside a view update is
            // what SwiftUI complains about, so only publish a value that differs.
            if parent.text != textView.string { parent.text = textView.string }
            textView.relex()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // The matched-bracket emphasis follows the caret — a cheap re-tint,
            // not a re-lex.
            guard let textView = notification.object as? FoldingTextView else { return }
            textView.refreshEmphasis()
        }

        /// Fold bookkeeping runs here, *before* the edit lands, because this is
        /// the one place that knows both the range being replaced and by how
        /// much the text is about to move.
        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let textView = textView as? FoldingTextView else { return true }
            let delta = (replacementString.map { ($0 as NSString).length } ?? 0) - range.length
            textView.adjustFolds(forEditIn: range, delta: delta)
            return true
        }
    }
}

// MARK: - The text view

/// An `NSTextView` that can hide ranges of its own text without deleting them,
/// and draws its own fold gutter into its left inset.
///
/// Hiding happens in the layout manager's glyph-generation callback: characters
/// inside a folded range get the `.null` glyph property (drawn as nothing, zero
/// width) and their newlines get `.zeroAdvancement`, which is what actually
/// pulls the following lines up. One survivor per folded run keeps its slot and
/// has its glyph swapped for `…`, so a collapsed block reads `{…}` rather than
/// `{}` — in a monospaced font the substitute is exactly as wide as the
/// character it replaces, so nothing shifts.
final class FoldingTextView: NSTextView, NSLayoutManagerDelegate {
    var onCommandReturn: (() -> Void)?

    var fontSize: CGFloat = 13
    /// Spaces per indent level for ⇥ / ⇧⇥.
    var indentWidth: Int = 2
    private var indentString: String { String(repeating: " ", count: max(1, indentWidth)) }

    /// Width of the left inset reserved for the fold gutter. Text begins after
    /// it; fold controls are drawn inside it.
    static let gutterWidth: CGFloat = 22
    /// The fold control (a rounded square) and where it sits in the gutter.
    private static let foldBoxSide: CGFloat = 9
    private static let foldBoxX: CGFloat = 4

    /// Interiors currently hidden, in document order, non-overlapping.
    private(set) var folds: [NSRange] = []
    /// The bracket structure of the current text — recomputed on each edit and
    /// shared by the highlighter, the gutter, and the indent guides.
    private(set) var blocks: [JSONBlock] = []

    /// Characters that survive a fold to carry the `…`.
    private var ellipsisCarriers: Set<Int> = []
    /// Merged hidden ranges, so nested folds are one run rather than several.
    private var hiddenRuns: [NSRange] = []

    /// The bracket-pair ranges currently wearing the caret emphasis, so a later
    /// selection change can clear exactly them without a full repaint.
    private var emphasizedRanges: [NSRange] = []

    /// Where each fold control was last drawn, so a click maps back to its block
    /// without recomputing layout.
    private var foldHitTargets: [(rect: NSRect, block: JSONBlock)] = []

    // MARK: Structure & colour

    /// Re-lexes the document and repaints it. Cheap enough for a note-sized
    /// payload on every keystroke; if a pasted blob ever makes it feel heavy,
    /// this is the single place to add a coalescing timer.
    ///
    /// Held off entirely while an input method is composing marked text — a
    /// `setAttributes` over the whole storage mid-composition tears the IME's
    /// underline off, which is exactly what made CJK typing miserable. The next
    /// edit after the composition commits re-lexes as normal.
    func relex() {
        guard !hasMarkedText() else { return }
        blocks = jsonBlocks(in: string)
        guard let storage = textStorage else { return }

        applyJSONHighlight(
            to: storage,
            theme: .standard(pointSize: fontSize),
            blocks: blocks,
            emphasized: nil)
        // The full pass reset every background, so the record of what was
        // emphasised is stale; re-derive it from the caret.
        emphasizedRanges = []
        applyEmphasis(currentBracketPair())

        needsDisplay = true
    }

    /// Re-tints just the bracket pair the caret sits on. No re-lex, no full
    /// attribute pass — safe to run on every selection change.
    func refreshEmphasis() {
        guard !hasMarkedText() else { return }
        applyEmphasis(currentBracketPair())
    }

    /// The bracket pair to emphasise for the current caret, or nil when there's
    /// a selection (emphasis only makes sense for a point).
    private func currentBracketPair() -> JSONBlock? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        return jsonBracketPair(forCaretAt: selection.location, in: blocks)
    }

    /// Swaps the emphasis background from wherever it was to `pair`'s brackets.
    private func applyEmphasis(_ pair: JSONBlock?) {
        guard let storage = textStorage else { return }
        let length = storage.length

        for range in emphasizedRanges where NSMaxRange(range) <= length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        emphasizedRanges = []

        if let pair {
            let background = JSONTheme.standard(pointSize: fontSize).emphasisBackground
            for location in [pair.open, pair.close].compactMap({ $0 }) {
                let range = NSRange(location: location, length: 1)
                guard NSMaxRange(range) <= length else { continue }
                storage.addAttribute(.backgroundColor, value: background, range: range)
                emphasizedRanges.append(range)
            }
        }
        needsDisplay = true
    }

    // MARK: Folding

    /// Whether `block`'s interior is hidden right now.
    func isFolded(_ block: JSONBlock) -> Bool {
        guard let interior = block.interior else { return false }
        return folds.contains { NSEqualRanges($0, interior) }
    }

    /// Blocks worth a gutter control: closed, and spanning more than one line.
    /// A one-line block has nothing to gain from folding.
    var foldableBlocks: [JSONBlock] {
        let ns = string as NSString
        return blocks.filter { block in
            guard let interior = block.interior, interior.length > 0 else { return false }
            return ns.range(of: "\n", options: [], range: interior).location != NSNotFound
        }
    }

    func toggleFold(_ block: JSONBlock) {
        guard let interior = block.interior else { return }
        if let existing = folds.firstIndex(where: { NSEqualRanges($0, interior) }) {
            folds.remove(at: existing)
        } else {
            folds.append(interior)
            folds.sort { $0.location < $1.location }
        }
        applyFolds()
    }

    func foldAll() {
        folds = foldableBlocks.compactMap(\.interior).sorted { $0.location < $1.location }
        applyFolds()
    }

    func clearFolds() {
        guard !folds.isEmpty else { return }
        folds = []
        applyFolds()
    }

    /// Keeps folds pointing at the right text across an edit.
    ///
    /// A fold whose interior the edit touches is dropped rather than resized:
    /// the block it described may not even exist afterwards, and a stale fold
    /// hides text the user is in the middle of typing. Folds entirely after the
    /// edit just shift.
    func adjustFolds(forEditIn range: NSRange, delta: Int) {
        guard !folds.isEmpty else { return }
        let survivors: [NSRange] = folds.compactMap { fold in
            if NSMaxRange(fold) <= range.location { return fold }  // entirely before
            if fold.location >= NSMaxRange(range) {                // entirely after
                return NSRange(location: fold.location + delta, length: fold.length)
            }
            return nil                                             // touched → drop
        }
        guard survivors.count != folds.count
                || !zip(survivors, folds).allSatisfy({ NSEqualRanges($0, $1) }) else { return }
        folds = survivors
        applyFolds()
    }

    /// Recomputes the hidden runs and asks the layout manager to redo its
    /// glyphs. Glyph *generation* is what folding hooks, so invalidating layout
    /// alone wouldn't re-run it.
    private func applyFolds() {
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Merge overlapping/adjacent folds so a parent and its already-folded
        // child produce one run with one ellipsis, not two.
        var runs: [NSRange] = []
        for fold in folds.sorted(by: { $0.location < $1.location }) {
            if let last = runs.last, fold.location <= NSMaxRange(last) {
                runs[runs.count - 1] = NSUnionRange(last, fold)
            } else {
                runs.append(fold)
            }
        }
        hiddenRuns = runs

        // One survivor per run carries the `…`. Control characters can't: the
        // layout manager routes those through `shouldUse action:` instead of
        // drawing a glyph, so a newline would swallow the substitution.
        ellipsisCarriers = Set(runs.compactMap { run in
            (run.location..<NSMaxRange(run)).first { index in
                guard index < ns.length else { return false }
                let scalar = ns.character(at: index)
                return scalar != 0x0A && scalar != 0x0D && scalar != 0x09
            }
        })

        guard let layoutManager else { return }
        layoutManager.invalidateGlyphs(
            forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        needsDisplay = true
    }

    private func isHidden(_ characterIndex: Int) -> Bool {
        hiddenRuns.contains { NSLocationInRange(characterIndex, $0) }
    }

    // MARK: NSLayoutManagerDelegate — the fold itself

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        // 0 means "I didn't touch anything, carry on" — the fast path for the
        // overwhelmingly common unfolded case.
        guard !hiddenRuns.isEmpty else { return 0 }

        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var touched = false

        for offset in 0..<glyphRange.length {
            let characterIndex = characterIndexes[offset]
            guard isHidden(characterIndex) else { continue }
            touched = true
            if ellipsisCarriers.contains(characterIndex), let ellipsis = Self.ellipsisGlyph(in: font) {
                newGlyphs[offset] = ellipsis
            } else {
                newProperties[offset] = .null
            }
        }

        guard touched else { return 0 }

        layoutManager.setGlyphs(
            &newGlyphs, properties: &newProperties, characterIndexes: characterIndexes,
            font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    /// Hidden newlines must not break the line, or the folded block would still
    /// occupy its full height with nothing drawn in it.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isHidden(charIndex) ? .zeroAdvancement : action
    }

    private static var ellipsisGlyphCache: [String: CGGlyph] = [:]

    private static func ellipsisGlyph(in font: NSFont) -> CGGlyph? {
        let key = "\(font.fontName)-\(font.pointSize)"
        if let cached = ellipsisGlyphCache[key] { return cached == 0 ? nil : cached }
        var characters: [UniChar] = [0x2026]  // …
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, 1)
        ellipsisGlyphCache[key] = glyphs[0]
        return glyphs[0] == 0 ? nil : glyphs[0]
    }

    // MARK: Gutter & indent guides
    //
    // Both are drawn under the text, in the text view's own coordinate space —
    // the layout manager's bounding rects plus the container inset. Because it
    // all lives inside the text view, it scrolls and clips with the text and can
    // never bleed into the surrounding SwiftUI views the way an `NSRulerView`
    // did.

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        foldHitTargets = []
        guard let layoutManager, let textContainer, !blocks.isEmpty else { return }
        let inset = textContainerInset
        let colors = JSONTheme.standard(pointSize: fontSize).bracketColors

        for block in foldableBlocks {
            // A block whose opening bracket is itself folded away (nested inside
            // a collapsed parent) has no visible line to hang a control or guide
            // on, so skip it.
            guard !isHidden(block.open) else { continue }

            let openRect = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: block.open, length: 1),
                    actualCharacterRange: nil),
                in: textContainer)

            // Indent guide: a faint vertical joining the block's brackets, on the
            // opening bracket's column, only while the block is open.
            if !isFolded(block), let close = block.close {
                let closeRect = layoutManager.boundingRect(
                    forGlyphRange: layoutManager.glyphRange(
                        forCharacterRange: NSRange(location: close, length: 1),
                        actualCharacterRange: nil),
                    in: textContainer)
                let x = (openRect.minX + inset.width).rounded() + 0.5
                let top = openRect.maxY + inset.height
                let bottom = closeRect.minY + inset.height
                if bottom > top {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: x, y: top))
                    line.line(to: NSPoint(x: x, y: bottom))
                    line.lineWidth = 1
                    colors[block.depth % colors.count].withAlphaComponent(0.22).setStroke()
                    line.stroke()
                }
            }

            // Fold control, in the left gutter, centred on the opening line.
            let centerY = openRect.midY + inset.height
            let box = NSRect(
                x: Self.foldBoxX,
                y: (centerY - Self.foldBoxSide / 2).rounded(),
                width: Self.foldBoxSide,
                height: Self.foldBoxSide)
            // Always register the hit target so a click lands even if the mark
            // was outside this particular dirty rect; only paint when it shows.
            foldHitTargets.append((rect: box.insetBy(dx: -3, dy: -3), block: block))
            guard box.intersects(rect) else { continue }
            drawFoldControl(box: box, collapsed: isFolded(block))
        }
    }

    /// A rounded square with a minus (expanded) or a plus (collapsed) — the
    /// disclosure idiom every JSON viewer uses.
    private func drawFoldControl(box: NSRect, collapsed: Bool) {
        NSColor.tertiaryLabelColor.setStroke()
        let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        frame.lineWidth = 1
        frame.stroke()

        NSColor.secondaryLabelColor.setStroke()
        let mark = NSBezierPath()
        let mid = NSPoint(x: box.midX, y: box.midY)
        let arm = box.width / 2 - 2.5
        mark.move(to: NSPoint(x: mid.x - arm, y: mid.y))
        mark.line(to: NSPoint(x: mid.x + arm, y: mid.y))
        if collapsed {
            mark.move(to: NSPoint(x: mid.x, y: mid.y - arm))
            mark.line(to: NSPoint(x: mid.x, y: mid.y + arm))
        }
        mark.lineWidth = 1
        mark.stroke()
    }

    // MARK: Keys & mouse

    override func keyDown(with event: NSEvent) {
        // ⌘↩ → save. Return alone stays a newline in the field.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    // Tab arrives as an action, not a raw key: AppKit's key bindings already map
    // ⇥ → insertTab: and ⇧⇥ → insertBacktab:. ⇥ indents the line(s) the selection
    // touches, ⇧⇥ unindents them — never a JSON reformat.
    override func insertTab(_ sender: Any?) {
        indentSelectedLines(with: indentString)
    }

    override func insertBacktab(_ sender: Any?) {
        unindentSelectedLines(with: indentString)
    }

    /// ⌥⌘← / ⌥⌘→ fold and unfold the block around the caret — the same keys
    /// Xcode uses, so the muscle memory transfers.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let required: NSEvent.ModifierFlags = [.command, .option]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == required,
              let characters = event.charactersIgnoringModifiers
        else { return super.performKeyEquivalent(with: event) }

        // ← and → arrive as function-key private-use scalars.
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)

        guard let block = jsonBlock(containing: selectedRange().location, in: blocks) else {
            return super.performKeyEquivalent(with: event)
        }
        switch characters {
        case left where !isFolded(block):
            toggleFold(block)
            return true
        case right where isFolded(block):
            toggleFold(block)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // A fold control in the gutter toggles its block.
        if let target = foldHitTargets.first(where: { $0.rect.contains(point) }) {
            toggleFold(target.block)
            return
        }

        // Clicking a collapsed run expands it — otherwise the caret would land
        // inside text you can't see.
        let index = characterIndexForInsertion(at: point)
        if let run = hiddenRuns.first(where: { NSLocationInRange(index, $0) }) {
            folds.removeAll { NSIntersectionRange($0, run).length > 0 }
            applyFolds()
            return
        }
        super.mouseDown(with: event)
    }
}
