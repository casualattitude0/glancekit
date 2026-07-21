import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The Notes editing surface: a monospaced, live-highlighting markdown field.
//
// SwiftUI's `TextEditor` can't do inline syntax highlighting on macOS 14, so
// this wraps an `NSTextView`. The text view owns a bounded, internally-scrolling
// area — a real editing surface rather than a box that grows without limit —
// and repaints its own `NSTextStorage` on every edit via `MarkdownHighlighter`.
//
// Focus binding: the popover wants the caret to land here the moment it opens
// (so ⌥2 → type → ⌘↩ never touches the mouse). `wantsFocus` is a one-shot
// trigger — the view makes itself first responder and flips it back to false.
// ─────────────────────────────────────────────────────────────────────────────

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// When true, dims every paragraph except the one holding the caret.
    var focusMode: Bool
    /// Set true to request first-responder; the view resets it to false.
    @Binding var wantsFocus: Bool
    /// The point size the mono font is drawn at.
    var fontSize: CGFloat = 13
    /// Spaces per indent level. ⇥ inserts this many; ⇧⇥ removes them.
    var indentWidth: Int = 4
    /// Fires when ⌘↩ is pressed while editing — the popover saves the note.
    var onCommandReturn: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        // Size the text view to fill the scroll view's width and grow downward,
        // the standard "text view inside a scroller" wiring a bare `NSTextView()`
        // doesn't set up on its own — without it, lines won't wrap to the width
        // and vertical scrolling misbehaves.
        let contentSize = scrollView.contentSize
        let textView = FocusableTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        let bigDimension = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: bigDimension, height: bigDimension)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width, height: bigDimension)

        textView.delegate = context.coordinator
        // Routed through the coordinator rather than captured directly: the
        // struct this closure would capture is the one from *this* runloop turn,
        // and `updateNSView` replaces `coordinator.parent` on every redraw.
        textView.onCommandReturn = { context.coordinator.parent.onCommandReturn() }
        textView.indentWidth = indentWidth

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // A little breathing room between lines, iA-Writer style.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        textView.string = text
        context.coordinator.highlight(textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusableTextView else { return }

        context.coordinator.parent = self
        textView.indentWidth = indentWidth

        // Only overwrite the field when the model genuinely diverges (e.g. a
        // note was loaded for editing, or the draft cleared on save). Writing it
        // back on every keystroke would fight the user's typing and reset the
        // caret.
        if textView.string != text {
            let selected = textView.selectedRange()
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            // Replace *through* the text view rather than assigning `.string`,
            // so the swap joins the undo stack: ⌘Z after a ⇥ reformat puts back
            // exactly what you pasted.
            if textView.shouldChangeText(in: whole, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: whole, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
            }
            textView.setSelectedRange(NSRange(
                location: min(selected.location, (text as NSString).length), length: 0))
        }

        context.coordinator.highlight(textView)

        if wantsFocus {
            // Defer: the window may not be key yet on the same runloop turn the
            // popover appears.
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                wantsFocus = false
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // `updateNSView` also routes its writes through `didChangeText` (to
            // keep undo working), which lands back here. Writing the binding
            // again from inside a view update is what SwiftUI complains about,
            // so only publish a value that actually differs.
            if parent.text != textView.string { parent.text = textView.string }
            highlight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Focus mode follows the caret, so a selection move has to repaint.
            guard parent.focusMode, let textView = notification.object as? NSTextView else { return }
            highlight(textView)
        }

        /// Repaints the whole field, preserving the caret. In focus mode the
        /// active paragraph is whichever one the (collapsed) selection sits in.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let theme = MarkdownTheme.standard(pointSize: parent.fontSize)

            var focus: NSRange?
            if parent.focusMode {
                let sel = textView.selectedRange()
                focus = (textView.string as NSString).paragraphRange(for: sel)
            }
            applyMarkdownHighlight(to: storage, theme: theme, focusParagraph: focus)
        }
    }
}

/// An `NSTextView` that lets ⌘↩ through to a callback (for "Save") and reliably
/// takes first-responder when asked.
private final class FocusableTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    /// Spaces per indent level for ⇥ / ⇧⇥.
    var indentWidth: Int = 4
    private var indentString: String { String(repeating: " ", count: max(1, indentWidth)) }

    override func keyDown(with event: NSEvent) {
        // ⌘↩ → save. Return alone stays a newline in the field.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    // ⇥ indents the line(s) the selection touches; ⇧⇥ unindents them.
    override func insertTab(_ sender: Any?) {
        indentSelectedLines(with: indentString)
    }

    override func insertBacktab(_ sender: Any?) {
        unindentSelectedLines(with: indentString)
    }
}
