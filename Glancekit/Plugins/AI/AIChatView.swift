import SwiftUI
import Observation

/// The chat surface for the AI Assistant glance: a scrolling transcript above a
/// bottom compose row. User turns sit on the right in tinted bubbles, assistant
/// turns on the left, each optionally prefaced by the small "action" chips that
/// record the tools it reached for.
///
/// Renders in both containers the glance can open in — the narrow menu-bar
/// popover column and the wider standalone tool window (see
/// `AIPlugin.preferredToolWindowSize`) — so everything is width-flexible.
struct AIChatView: View {
    let conversation: AIConversation

    var body: some View {
        // `@Bindable` needs a var; take one off the passed-in reference so the
        // input row can bind two-way while the plugin still owns the object.
        AIChatBody(conversation: conversation)
    }
}

private struct AIChatBody: View {
    @Bindable var conversation: AIConversation

    /// The current draft in the compose field. View-local: a fresh window opens
    /// with an empty box, and sending clears it.
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            transcript

            if let error = conversation.lastError {
                AIErrorBanner(message: error) { conversation.lastError = nil }
            }

            if let request = AIApprovalGate.shared.pending {
                AIApprovalBanner(request: request)
            }

            Divider()

            if conversation.isConfigured {
                composer
            } else {
                AIUnconfiguredHint()
            }
        }
        // Fill the container so the transcript takes the slack and the composer
        // pins to the bottom, instead of everything bunching at the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    /// A slim top bar whose one job is starting a fresh chat. "New Chat" clears
    /// the transcript and any error via `conversation.clear()` — the same action
    /// that cleans up the current chat, so there's a single, unambiguous control
    /// rather than a separate "clear" that would do the same thing.
    private var header: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button {
                conversation.clear()
                draft = ""
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(!hasChat)
            .help("Start a new chat — clears the current one")
        }
    }

    /// Whether there's anything to clear: messages, an in-flight reply, or a
    /// lingering error. Keeps "New Chat" disabled on an already-empty transcript.
    private var hasChat: Bool {
        !conversation.messages.isEmpty || conversation.isResponding || conversation.lastError != nil
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        // An empty, idle chat centers its hint in the freed space; once there are
        // messages (or a reply is landing) the scrolling transcript takes over.
        if conversation.messages.isEmpty && !conversation.isResponding {
            AITranscriptEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            scrollingTranscript
        }
    }

    private var scrollingTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(conversation.messages) { message in
                        AIMessageRow(message: message)
                            .id(message.id)
                    }

                    if conversation.isResponding {
                        AIThinkingRow()
                            .id(Self.thinkingAnchor)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            // Follow the newest content: a fresh message, streamed text growing,
            // or the thinking row appearing while a reply is in flight.
            .onChange(of: conversation.messages.last?.id) { _, _ in scrollToEnd(proxy) }
            .onChange(of: conversation.messages.last?.text) { _, _ in scrollToEnd(proxy) }
            .onChange(of: conversation.isResponding) { _, _ in scrollToEnd(proxy) }
        }
    }

    private static let thinkingAnchor = "ai.thinking.anchor"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            // While a reply is in flight the thinking row is the last thing in the
            // stack; otherwise follow the newest message.
            if conversation.isResponding {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = conversation.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // A bounded, growing editor rather than a single-line field, so a
            // pasted paragraph stays readable. ⌘↩ and ↩ both send; Shift+↩ is
            // handled by the field as a newline.
            AIComposeField(text: $draft, onSubmit: send)
                .frame(minHeight: 32, maxHeight: 96)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask anything…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .help("Send (↩ or ⌘↩)")
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !conversation.isResponding
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        conversation.send(text)
    }
}

// MARK: - Message row

private struct AIMessageRow: View {
    let message: AIConversation.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 32)
                userBubble
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    if !message.toolActivity.isEmpty {
                        AIToolActivityList(activity: message.toolActivity)
                    }
                    if !message.text.isEmpty {
                        // Only the assistant's side renders markdown: it's what
                        // writes in markdown. Echoing the user's own typing back
                        // restyled would be a surprise, and a stray asterisk in
                        // a question shouldn't silently turn into italics.
                        AIMarkdownText(text: message.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Spacer(minLength: 32)
            }
        }
    }

    private var userBubble: some View {
        Text(message.text)
            .font(.callout)
            .textSelection(.enabled)
            // The bubble sits right, but its text reads left: a ragged-left edge
            // makes every line start in a different place, which costs more to
            // read than the symmetry buys.
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }
}

/// The small captioned "action" chips above an assistant turn, one per tool the
/// model reached for while composing the reply.
private struct AIToolActivityList: View {
    let activity: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(activity.enumerated()), id: \.offset) { _, entry in
                Label(entry, systemImage: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.4), in: Capsule())
            }
        }
    }
}

/// The left-aligned "thinking" placeholder shown while `isResponding` and the
/// assistant hasn't produced (or is still streaming) its reply.
private struct AIThinkingRow: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Empty / error / unconfigured states

private struct AITranscriptEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Ask the assistant anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("It can read your other glances to answer.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct AIErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The in-chat consent prompt shown while a mutating or external (MCP) tool call
/// is blocked on the user's decision. Wired to `AIApprovalGate.shared`.
private struct AIApprovalBanner: View {
    let request: AIApprovalGate.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: request.isMCP ? "network.badge.shield.half.filled" : "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(request.isMCP ? "Run external tool?" : "Allow this action?")
                    .font(.caption.weight(.semibold))
            }
            Text(request.displayName)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
            Text(request.argsSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Deny") { AIApprovalGate.shared.resolve(.deny) }
                    .controlSize(.small)
                Button("Allow once") { AIApprovalGate.shared.resolve(.allowOnce) }
                    .controlSize(.small)
                Button("Always allow") { AIApprovalGate.shared.resolve(.allowAlways) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AIUnconfiguredHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
            Text("Configure a provider in Settings to start chatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Compose field

/// A multi-line compose box that sends on ↩ / ⌘↩ and inserts a newline on
/// ⇧↩. Wraps `NSTextView` so the Return-key semantics can be tuned; the app's
/// Notes editor takes the same approach for its own key handling.
private struct AIComposeField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .callout)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: AIComposeField

        init(_ parent: AIComposeField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Plain Return sends; Shift+Return falls through to insert a newline.
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift { return false }
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
