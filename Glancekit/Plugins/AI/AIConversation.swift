import Foundation
import Observation

/// The running chat between the user and the assistant, and the agentic loop
/// that drives it.
///
/// This is the observable model the AI glance's UI binds to. `send(_:)` appends
/// the user's message and kicks off a background task that: builds the provider
/// history, asks the model for a turn, runs any tools it requests, feeds the
/// results back, and repeats until the model answers in prose (capped so a
/// misbehaving model can't loop forever). It composes `AIClient`,
/// `AIConfigStore.shared`, and `AIToolbox` internally.
@MainActor
@Observable
final class AIConversation {

    enum Role {
        case user
        case assistant
    }

    /// One turn shown in the transcript. `toolActivity` is the running list of
    /// actions the assistant took for this turn (e.g. "Created palette 'Sunset'"),
    /// shown alongside its prose.
    struct Message: Identifiable, Equatable {
        let id: UUID
        let role: Role
        var text: String
        var toolActivity: [String]

        init(id: UUID = UUID(), role: Role, text: String = "", toolActivity: [String] = []) {
            self.id = id
            self.role = role
            self.text = text
            self.toolActivity = toolActivity
        }
    }

    /// The visible transcript. The system prompt is not represented here.
    var messages: [Message] = []

    /// True while a `send(_:)` task is in flight.
    var isResponding: Bool = false

    /// The most recent failure, cleared on the next `send(_:)`.
    var lastError: String? = nil

    var isConfigured: Bool { AIConfigStore.shared.isConfigured }

    /// Safety cap on model↔tool round-trips within a single `send(_:)`.
    private let maxIterations = 6

    private let registry: PluginRegistry
    private let coordinator: RefreshCoordinator
    private let client = AIClient()

    private var task: Task<Void, Never>?

    init(registry: PluginRegistry, coordinator: RefreshCoordinator) {
        self.registry = registry
        self.coordinator = coordinator
    }

    /// Send a user message and run the agentic loop to produce a reply.
    func send(_ userText: String) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isResponding else { return }

        lastError = nil
        messages.append(Message(role: .user, text: trimmed))

        guard isConfigured else {
            lastError = AIChatError.notConfigured.errorDescription
            return
        }

        isResponding = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
            self.isResponding = false
        }
    }

    /// Empty the transcript and clear any error.
    func clear() {
        task?.cancel()
        task = nil
        messages.removeAll()
        lastError = nil
        isResponding = false
    }

    // MARK: - Agentic loop

    private func runLoop() async {
        let config = AIRequestConfig(
            providerKind: AIConfigStore.shared.providerKind,
            endpoint: AIConfigStore.shared.effectiveEndpoint,
            apiKey: AIConfigStore.shared.apiKey,
            model: AIConfigStore.shared.model,
            systemPrompt: AIConfigStore.shared.systemPrompt)

        let toolbox = AIToolbox(registry: registry, coordinator: coordinator)

        var history = baseHistory(providerKind: config.providerKind)
        var assistantIndex: Int?

        do {
            for iteration in 0..<maxIterations {
                let result = try await client.runTurn(config: config, history: history, tools: toolbox.specs)

                // No tool calls → this is the final prose answer.
                if result.toolCalls.isEmpty {
                    let text = result.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty && assistantIndex == nil {
                        throw AIChatError.noContent
                    }
                    setFinalText(text, at: &assistantIndex)
                    return
                }

                // The model wants to act. Record the raw assistant message so the
                // follow-up tool_result request is well-formed, then run each tool.
                history.append(.assistant(raw: result.rawAssistantMessage))

                if let thinking = result.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !thinking.isEmpty {
                    setFinalText(thinking, at: &assistantIndex)
                }

                var results: [AIToolResult] = []
                for call in result.toolCalls {
                    let output = await toolbox.execute(call)
                    results.append(AIToolResult(callID: call.id, name: call.name, content: output))
                    appendActivity(output, at: &assistantIndex)
                }
                history.append(.toolResults(results))

                // If this was the last allowed iteration, stop with a note rather
                // than silently dropping the model's next turn.
                if iteration == maxIterations - 1 {
                    appendActivity("Reached the action limit for one message.", at: &assistantIndex)
                }
            }
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = description
            // Drop an empty assistant bubble that never received content.
            if let index = assistantIndex, messages.indices.contains(index),
               messages[index].text.isEmpty, messages[index].toolActivity.isEmpty {
                messages.remove(at: index)
            }
        }
    }

    // MARK: - History reconstruction

    /// Build the provider history from the visible transcript. Prior assistant
    /// turns are replayed as their final prose (tool round-trips from earlier
    /// turns don't need re-sending — the prose carries the context forward).
    private func baseHistory(providerKind: AIProviderKind) -> [AIClient.HistoryItem] {
        var history: [AIClient.HistoryItem] = []
        for message in messages {
            switch message.role {
            case .user:
                history.append(.user(message.text))
            case .assistant:
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                history.append(.assistant(raw: Self.assistantRaw(text: text, providerKind: providerKind)))
            }
        }
        return history
    }

    /// A minimal provider-native assistant message carrying only prose, for
    /// replaying earlier turns.
    private static func assistantRaw(text: String, providerKind: AIProviderKind) -> [String: Any] {
        switch providerKind {
        case .anthropic:
            return ["role": "assistant", "content": [["type": "text", "text": text]]]
        case .openAICompatible:
            return ["role": "assistant", "content": text]
        }
    }

    // MARK: - Transcript mutation

    /// Ensure there's an assistant message for the current turn, returning its
    /// index. Created lazily so a turn that errors before any output leaves no
    /// empty bubble.
    private func ensureAssistantMessage(at index: inout Int?) -> Int {
        if let index, messages.indices.contains(index) { return index }
        messages.append(Message(role: .assistant))
        let newIndex = messages.count - 1
        index = newIndex
        return newIndex
    }

    private func setFinalText(_ text: String, at index: inout Int?) {
        let i = ensureAssistantMessage(at: &index)
        messages[i].text = text
    }

    private func appendActivity(_ line: String, at index: inout Int?) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let i = ensureAssistantMessage(at: &index)
        messages[i].toolActivity.append(trimmed)
    }
}
