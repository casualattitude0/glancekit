import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The JSON editing surface: a monospaced field with a fold gutter, depth-tinted
// brackets, indent guides, and ⇥ / ⇧⇥ bound to format / minify.
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
    /// Fires when ⌘↩ is pressed — the popover saves the note.
    var onCommandReturn: () -> Void = {}
    /// ⇥ / ⇧⇥. Return true to claim the key; false lets a literal tab through,
    /// which is what half-typed JSON wants.
    var onTab: () -> Bool = { false }
    var onBacktab: () -> Bool = { false }

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
        textView.onTab = { context.coordinator.parent.onTab() }
        textView.onBacktab = { context.coordinator.parent.onBacktab() }

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
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.fontSize = fontSize
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        textView.string = text
        scrollView.documentView = textView

        // The fold gutter lives in the scroll view's vertical ruler slot, so it
        // scrolls with the text for free.
        let gutter = JSONGutterView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.gutter = gutter
        foldController?.textView = textView

        textView.refreshStructure()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FoldingTextView else { return }

        context.coordinator.parent = self

        if textView.string != text {
            let selected = textView.selectedRange()
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            // Replace *through* the text view rather than assigning `.string`,
            // so the swap joins the undo stack: ⌘Z after a ⇥ reformat puts back
            // exactly what you pasted. It also runs the delegate's fold
            // bookkeeping, which drops folds the new text has invalidated.
            if textView.shouldChangeText(in: whole, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: whole, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
                textView.clearFolds()
            }
            textView.setSelectedRange(NSRange(
                location: min(selected.location, (text as NSString).length), length: 0))
        }

        textView.fontSize = fontSize
        textView.refreshStructure()

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
            // `updateNSView` also routes its writes through `didChangeText` (to
            // keep undo working), which lands back here. Writing the binding
            // again from inside a view update is what SwiftUI complains about,
            // so only publish a value that actually differs.
            if parent.text != textView.string { parent.text = textView.string }
            textView.refreshStructure()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // The matched-bracket emphasis follows the caret.
            guard let textView = notification.object as? FoldingTextView else { return }
            textView.refreshStructure()
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

/// An `NSTextView` that can hide ranges of its own text without deleting them.
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
    /// Return true to swallow the key; false to fall through to the text view.
    var onTab: (() -> Bool)?
    var onBacktab: (() -> Bool)?

    var fontSize: CGFloat = 13
    weak var gutter: JSONGutterView?

    /// Interiors currently hidden, in document order, non-overlapping.
    private(set) var folds: [NSRange] = []
    /// The bracket structure of the current text — recomputed on every edit and
    /// shared by the highlighter, the gutter, and the indent guides.
    private(set) var blocks: [JSONBlock] = []

    /// Characters that survive a fold to carry the `…`.
    private var ellipsisCarriers: Set<Int> = []
    /// Merged hidden ranges, so nested folds are one run rather than several.
    private var hiddenRuns: [NSRange] = []

    // MARK: Structure

    /// Re-lexes the document, repaints it, and refreshes the gutter. Cheap
    /// enough for a note-sized payload on every keystroke; if a pasted blob ever
    /// makes it feel heavy, this is the single place to add a coalescing timer.
    func refreshStructure() {
        blocks = jsonBlocks(in: string)
        guard let storage = textStorage else { return }

        let caret = selectedRange().length == 0 ? selectedRange().location : NSNotFound
        let pair = caret == NSNotFound ? nil : jsonBracketPair(forCaretAt: caret, in: blocks)

        applyJSONHighlight(
            to: storage,
            theme: .standard(pointSize: fontSize),
            blocks: blocks,
            emphasized: pair)

        gutter?.needsDisplay = true
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
        gutter?.needsDisplay = true
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

    // MARK: Indent guides

    /// Faint verticals joining each multi-line block's brackets, so the nesting
    /// reads at a glance instead of by counting spaces. Drawn under the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager, let textContainer, !blocks.isEmpty else { return }
        let inset = textContainerInset
        let colors = JSONTheme.standard(pointSize: fontSize).bracketColors

        for block in foldableBlocks where !isFolded(block) {
            guard let close = block.close else { continue }
            let openRect = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: block.open, length: 1),
                    actualCharacterRange: nil),
                in: textContainer)
            let closeRect = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: close, length: 1),
                    actualCharacterRange: nil),
                in: textContainer)

            // From under the opening bracket down to the closing one, on the
            // bracket's own column.
            let x = (openRect.minX + inset.width).rounded() + 0.5
            let top = openRect.maxY + inset.height
            let bottom = closeRect.minY + inset.height
            guard bottom > top else { continue }

            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: top))
            line.line(to: NSPoint(x: x, y: bottom))
            line.lineWidth = 1
            colors[block.depth % colors.count].withAlphaComponent(0.22).setStroke()
            line.stroke()
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // ⌘↩ → save. Return alone stays a newline in the field.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    // Tab arrives as an action, not a raw key: AppKit's key bindings already map
    // ⇥ → insertTab: and ⇧⇥ → insertBacktab:, so intercepting here (rather than
    // in `keyDown`) keeps the field's normal behaviour when the callback passes.
    override func insertTab(_ sender: Any?) {
        if onTab?() == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if onBacktab?() == true { return }
        super.insertBacktab(sender)
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

    /// Clicking a collapsed run expands it — otherwise the caret would land
    /// inside text you can't see.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let run = hiddenRuns.first(where: { NSLocationInRange(index, $0) }) {
            folds.removeAll { NSIntersectionRange($0, run).length > 0 }
            applyFolds()
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - The gutter

/// The fold rail down the left edge: one control per multi-line block, at the
/// line its opening bracket sits on. Clicking one collapses or expands it.
final class JSONGutterView: NSRulerView {
    private weak var textView: FoldingTextView?
    /// Where each control was last drawn, so a click can be matched back to its
    /// block without recomputing the layout.
    private var hitTargets: [(rect: NSRect, block: JSONBlock)] = []

    init(scrollView: NSScrollView, textView: FoldingTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 16
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        hitTargets = []
        let inset = textView.textContainerInset.height
        let side: CGFloat = 9

        for block in textView.foldableBlocks {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: block.open, length: 1),
                actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

            // Text-view coordinates → ruler coordinates, which is just the
            // scroll offset the ruler already tracks.
            let y = convert(NSPoint(x: 0, y: lineRect.midY + inset), from: textView).y
            let box = NSRect(
                x: (ruleThickness - side) / 2, y: (y - side / 2).rounded(), width: side, height: side)
            guard box.intersects(rect) else { continue }

            draw(box: box, collapsed: textView.isFolded(block))
            hitTargets.append((rect: box.insetBy(dx: -3, dy: -3), block: block))
        }
    }

    /// A rounded square with a minus (expanded) or a plus (collapsed) — the
    /// disclosure idiom every JSON viewer uses, drawn small enough to sit in a
    /// 16pt rail.
    private func draw(box: NSRect, collapsed: Bool) {
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = hitTargets.first(where: { $0.rect.contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        textView?.toggleFold(target.block)
    }
}
