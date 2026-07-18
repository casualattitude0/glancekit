import Foundation
import Observation

/// The human-in-the-loop gate for tool calls the assistant wants to run.
///
/// Read-only tools run silently; anything that *mutates* app state or reaches an
/// external MCP server is routed through here first. The agentic loop
/// (`AIConversation`) suspends on `request(_:)` until the user answers in the
/// chat surface (`AIChatView`), which calls `resolve(_:)`. A per-tool
/// "always allow" memory (persisted) lets a trusted tool skip the prompt next
/// time.
///
/// A singleton so the running conversation, the chat UI, and the Settings page
/// (which lists and revokes remembered allowances) all see the same state — one
/// conversation runs at a time, so a single pending slot is sufficient.
@MainActor
@Observable
final class AIApprovalGate {
    static let shared = AIApprovalGate()

    /// A tool call awaiting the user's decision.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// The wire tool name (e.g. `currency_add_pair`, `mcp__fs__read_file`).
        let toolName: String
        /// A friendly label for the prompt.
        let displayName: String
        /// A compact, truncated view of the arguments.
        let argsSummary: String
        /// Whether this call hits an external MCP server (shown more prominently).
        let isMCP: Bool
    }

    enum Decision { case allowOnce, allowAlways, deny }

    /// The call currently blocking the loop, or `nil` when nothing is pending.
    private(set) var pending: Request?

    private var continuation: CheckedContinuation<Decision, Never>?

    /// Tool names the user chose to always allow. Persisted so the choice sticks
    /// across launches.
    private(set) var alwaysAllowed: Set<String>
    private let allowKey = "glancekit.ai.mcp.allowedTools"

    private init() {
        alwaysAllowed = Set(UserDefaults.standard.stringArray(forKey: allowKey) ?? [])
    }

    func isAlwaysAllowed(_ name: String) -> Bool { alwaysAllowed.contains(name) }

    /// Ask the user to approve a tool call. Suspends until they decide. If a
    /// prompt is somehow already pending, denies immediately rather than deadlock.
    func request(_ request: Request) async -> Decision {
        guard pending == nil else { return .deny }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = request
        }
    }

    /// Answer the pending prompt. Called from the chat UI.
    func resolve(_ decision: Decision) {
        guard let continuation, let request = pending else { return }
        if decision == .allowAlways {
            alwaysAllowed.insert(request.toolName)
            persistAllowed()
        }
        self.continuation = nil
        self.pending = nil
        continuation.resume(returning: decision)
    }

    /// Drop a remembered allowance (Settings control).
    func revoke(_ name: String) {
        guard alwaysAllowed.remove(name) != nil else { return }
        persistAllowed()
    }

    /// Deny anything pending — used when a conversation is cleared mid-prompt.
    func cancelPending() {
        guard let continuation else { return }
        self.continuation = nil
        self.pending = nil
        continuation.resume(returning: .deny)
    }

    private func persistAllowed() {
        UserDefaults.standard.set(Array(alwaysAllowed), forKey: allowKey)
    }
}
