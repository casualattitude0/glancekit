import SwiftUI
import Observation

// MARK: - Context

/// The situational context the panel reasons about: what time it is and what
/// that implies. Lets the feed greet the user and phrase its brief for the
/// moment rather than reading the same at 8am and 8pm.
struct PanelContext {
    enum PartOfDay { case morning, afternoon, evening, night }

    let partOfDay: PartOfDay
    let isWeekend: Bool

    init(date: Date = Date(), calendar: Calendar = .current) {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: partOfDay = .morning
        case 12..<17: partOfDay = .afternoon
        case 17..<22: partOfDay = .evening
        default: partOfDay = .night
        }
        let weekday = calendar.component(.weekday, from: date)
        isWeekend = (weekday == 1 || weekday == 7)
    }

    /// A short, time-appropriate greeting used to open the brief.
    var greeting: String {
        switch partOfDay {
        case .morning: return "Good morning."
        case .afternoon: return "Good afternoon."
        case .evening: return "Good evening."
        case .night: return "Late night."
        }
    }
}

// MARK: - Brief

/// The one-line natural-language summary shown at the top of the Smart Panel —
/// the part that makes the feed feel like it's *thinking* rather than listing.
///
/// It always shows something instantly: a rule-based sentence composed from the
/// ranked signals and the context. When an AI provider is configured, it then
/// upgrades that sentence in the background to a genuinely written one via the
/// same `AIClient` the Assistant uses. If the AI call fails or isn't configured,
/// the rule-based line stands — so the brief is never blank and never blocks.
@MainActor
@Observable
final class SmartBriefModel {

    /// The current brief text shown in the header.
    private(set) var text: String = ""
    /// True once an AI provider has replaced the rule-based line — drives a small
    /// "sparkles" cue so the user can tell the smart summary landed.
    private(set) var isAIWritten: Bool = false

    /// Signature of the last state we briefed, so we don't re-run on every render
    /// or spend an AI call when nothing meaningful changed. Deliberately *coarse*
    /// — which glances and at what urgency, not their live numbers — so the brief
    /// holds still while a price or percentage ticks underneath it.
    private var lastSignature: String = ""
    private var aiTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// A system prompt tuned for a terse status brief, distinct from the
    /// Assistant's own action-oriented prompt.
    private static let briefSystemPrompt = """
    You are the status narrator inside Glancekit, a macOS menu-bar app. Given the \
    user's current status items, write ONE short, friendly, natural sentence \
    (under 20 words) telling them what matters right now. Lead with what's most \
    urgent. No preamble, no lists, no markdown, no emoji. If nothing is pressing, \
    say so warmly.
    """

    /// Recompute the brief for the current feed. Cheap and idempotent: it no-ops
    /// when the *situation* is unchanged (same glances, same urgency), so a live
    /// number ticking never rewrites the sentence. When the situation does change,
    /// the apply is debounced by a beat so a value flapping across a threshold
    /// settles before the text moves.
    func update(context: PanelContext, items: [(title: String, headline: String, detail: String?, priority: GlanceSignal.Priority, isNew: Bool)]) {
        // Coarse: id-less, number-less — only which cards and how urgent.
        let signature = items.map { "\($0.title)|\($0.priority.rawValue)|\($0.isNew)" }.joined(separator: "~")
        guard signature != lastSignature else { return }
        lastSignature = signature

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // Let a threshold-crossing metric settle before the text moves.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.apply(context: context, items: items, signature: signature)
        }
    }

    private func apply(context: PanelContext, items: [(title: String, headline: String, detail: String?, priority: GlanceSignal.Priority, isNew: Bool)], signature: String) {
        // Instant, deterministic line — never blank.
        text = Self.ruleBased(context: context, items: items)
        isAIWritten = false

        // Upgrade to an AI-written line when a provider is configured.
        aiTask?.cancel()
        let store = AIConfigStore.shared
        guard store.isConfigured, !items.isEmpty else { return }

        let config = AIRequestConfig(
            providerKind: store.providerKind,
            endpoint: store.effectiveEndpoint,
            apiKey: store.apiKey,
            model: store.model,
            systemPrompt: Self.briefSystemPrompt
        )
        let prompt = Self.prompt(context: context, items: items)
        aiTask = Task { [weak self] in
            await self?.runAI(config: config, prompt: prompt, signature: signature)
        }
    }

    private func runAI(config: AIRequestConfig, prompt: String, signature: String) async {
        do {
            let result = try await AIClient().runTurn(config: config, history: [.user(prompt)], tools: [])
            guard !Task.isCancelled, signature == lastSignature,
                  let written = result.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !written.isEmpty
            else { return }
            text = written
            isAIWritten = true
        } catch {
            // Keep the rule-based line; the brief must never surface an error.
        }
    }

    // MARK: Rule-based fallback

    private static func ruleBased(context: PanelContext, items: [(title: String, headline: String, detail: String?, priority: GlanceSignal.Priority, isNew: Bool)]) -> String {
        let notable = items.filter { $0.priority > .ambient }
        guard !notable.isEmpty else {
            return "\(context.greeting) Nothing needs your attention right now."
        }
        let lead = notable.contains { $0.priority == .urgent } ? "Heads up" : "Worth a look"
        let phrases = notable.prefix(3).map { $0.headline }
        return "\(context.greeting) \(lead): \(phrases.joined(separator: ", "))."
    }

    private static func prompt(context: PanelContext, items: [(title: String, headline: String, detail: String?, priority: GlanceSignal.Priority, isNew: Bool)]) -> String {
        var lines = ["Time of day: \(context.partOfDay). Weekend: \(context.isWeekend)."]
        lines.append("Current status items (most urgent first):")
        for item in items {
            var line = "- [\(priorityLabel(item.priority))] \(item.title): \(item.headline)"
            if let detail = item.detail { line += " (\(detail))" }
            if item.isNew { line += " [new since last check]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func priorityLabel(_ priority: GlanceSignal.Priority) -> String {
        switch priority {
        case .urgent: return "urgent"
        case .elevated: return "notable"
        case .normal: return "routine"
        case .ambient: return "ambient"
        }
    }
}
