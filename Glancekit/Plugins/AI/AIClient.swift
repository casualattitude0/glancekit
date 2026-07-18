import Foundation

// MARK: - Shared value types

/// A tool the model may call, described the way both providers expect: a name,
/// a description, and a JSON-Schema object (`{"type":"object","properties":…,
/// "required":…}`) for the arguments.
struct AIToolSpec {
    let name: String
    let description: String
    let parametersJSONSchema: [String: Any]
}

/// A single tool invocation the model asked for. `arguments` is the decoded
/// JSON object (already parsed from the provider's wire form).
struct AIToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// A tool result to feed back to the model, tagged with the call it answers.
struct AIToolResult {
    let callID: String
    let name: String
    let content: String
}

/// Failures surfaced while talking to a chat API.
enum AIChatError: Error, LocalizedError {
    case notConfigured
    case http(Int, String)
    case decoding(String)
    case noContent
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The AI assistant isn't configured yet. Add an API key and model in Settings."
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(trimmed)"
        case .decoding(let detail):
            return "Couldn't read the model's response: \(detail)"
        case .noContent:
            return "The model returned an empty response."
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }
}

/// The normalized outcome of one model turn.
///
/// `rawAssistantMessage` is the provider-native assistant message (an untyped
/// JSON object). The caller appends it verbatim to the running history so the
/// follow-up request — carrying tool results — stays well-formed for that
/// provider.
struct AITurnResult {
    let assistantText: String?
    let toolCalls: [AIToolCall]
    let rawAssistantMessage: Any
}

// MARK: - Request config

/// A flat snapshot of everything a request needs, so `AIClient` never touches
/// the `@MainActor` config store off the main actor.
struct AIRequestConfig {
    let providerKind: AIProviderKind
    let endpoint: String
    let apiKey: String
    let model: String
    let systemPrompt: String
}

// MARK: - Client

/// Stateless encoder/decoder for the two supported chat APIs.
///
/// The agentic loop lives in `AIConversation`; `AIClient` only knows how to run
/// *one* turn: given the running history plus tool specs, POST it and return the
/// assistant's text and/or tool calls. History is passed in every call — the
/// client holds no conversation state, only its `URLSession`.
struct AIClient {

    /// One entry in the running conversation, provider-agnostic. Each provider's
    /// encoder serializes these into its own wire shape.
    enum HistoryItem {
        case user(String)
        /// A provider-native assistant message, as returned by a prior turn's
        /// `AITurnResult.rawAssistantMessage`.
        case assistant(raw: Any)
        case toolResults([AIToolResult])
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// Run a single model turn.
    func runTurn(config: AIRequestConfig,
                 history: [HistoryItem],
                 tools: [AIToolSpec]) async throws -> AITurnResult {
        guard let url = URL(string: config.endpoint) else {
            throw AIChatError.transport("Invalid endpoint URL: \(config.endpoint)")
        }

        let body: [String: Any]
        switch config.providerKind {
        case .anthropic:
            body = Self.anthropicBody(config: config, history: history, tools: tools)
        case .openAICompatible:
            body = Self.openAIBody(config: config, history: history, tools: tools)
        }

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw AIChatError.decoding("Couldn't encode the request: \(error.localizedDescription)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        switch config.providerKind {
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIChatError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw AIChatError.http(http.statusCode, bodyString)
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AIChatError.decoding("Response was not valid JSON.")
        }

        switch config.providerKind {
        case .anthropic:
            return try Self.parseAnthropic(json)
        case .openAICompatible:
            return try Self.parseOpenAI(json)
        }
    }

    // MARK: - Anthropic

    private static func anthropicBody(config: AIRequestConfig,
                                      history: [HistoryItem],
                                      tools: [AIToolSpec]) -> [String: Any] {
        var messages: [[String: Any]] = []
        for item in history {
            switch item {
            case .user(let text):
                messages.append(["role": "user", "content": text])
            case .assistant(let raw):
                if let dict = raw as? [String: Any] {
                    messages.append(dict)
                }
            case .toolResults(let results):
                let blocks: [[String: Any]] = results.map { result in
                    [
                        "type": "tool_result",
                        "tool_use_id": result.callID,
                        "content": result.content,
                    ]
                }
                messages.append(["role": "user", "content": blocks])
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 2048,
            "messages": messages,
        ]
        let system = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = tools.map { spec in
                [
                    "name": spec.name,
                    "description": spec.description,
                    "input_schema": spec.parametersJSONSchema,
                ]
            }
        }
        return body
    }

    private static func parseAnthropic(_ json: Any) throws -> AITurnResult {
        guard let root = json as? [String: Any] else {
            throw AIChatError.decoding("Expected a JSON object.")
        }
        // Anthropic returns errors as {"type":"error","error":{"message":…}}.
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIChatError.decoding(message)
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw AIChatError.noContent
        }

        var texts: [String] = []
        var toolCalls: [AIToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                guard !name.isEmpty else { continue }
                toolCalls.append(AIToolCall(id: id, name: name, arguments: input))
            default:
                continue
            }
        }

        let assistantText = texts.isEmpty ? nil : texts.joined(separator: "\n")
        // Round-trip the assistant message so a follow-up tool_result request
        // references valid tool_use ids.
        let rawMessage: [String: Any] = ["role": "assistant", "content": content]
        return AITurnResult(assistantText: assistantText,
                            toolCalls: toolCalls,
                            rawAssistantMessage: rawMessage)
    }

    // MARK: - OpenAI-compatible

    private static func openAIBody(config: AIRequestConfig,
                                   history: [HistoryItem],
                                   tools: [AIToolSpec]) -> [String: Any] {
        var messages: [[String: Any]] = []
        let system = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for item in history {
            switch item {
            case .user(let text):
                messages.append(["role": "user", "content": text])
            case .assistant(let raw):
                if let dict = raw as? [String: Any] {
                    messages.append(dict)
                }
            case .toolResults(let results):
                for result in results {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": result.callID,
                        "content": result.content,
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { spec in
                [
                    "type": "function",
                    "function": [
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": spec.parametersJSONSchema,
                    ],
                ]
            }
        }
        return body
    }

    private static func parseOpenAI(_ json: Any) throws -> AITurnResult {
        guard let root = json as? [String: Any] else {
            throw AIChatError.decoding("Expected a JSON object.")
        }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIChatError.decoding(message)
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIChatError.noContent
        }

        // content may be a string, null, or (rarely) an array of parts.
        var assistantText: String?
        if let text = message["content"] as? String, !text.isEmpty {
            assistantText = text
        } else if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            assistantText = joined.isEmpty ? nil : joined
        }

        var toolCalls: [AIToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for call in rawCalls {
                let id = call["id"] as? String ?? UUID().uuidString
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String, !name.isEmpty else { continue }
                let arguments = decodeArguments(function["arguments"])
                toolCalls.append(AIToolCall(id: id, name: name, arguments: arguments))
            }
        }

        return AITurnResult(assistantText: assistantText,
                            toolCalls: toolCalls,
                            rawAssistantMessage: message)
    }

    /// OpenAI ships tool-call arguments as a JSON *string*; decode defensively so
    /// a malformed or empty argument blob yields `[:]` rather than throwing.
    private static func decodeArguments(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
