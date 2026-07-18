import SwiftUI
import Observation

/// AI Assistant glance: a chat window backed by an `AIConversation`, which can
/// call the other glances as tools (via the `PluginRegistry`) and trigger a
/// refresh through the `RefreshCoordinator`.
///
/// Purely on-demand and user-driven — nothing to poll, so it opts out of the
/// shared refresh loop (`refreshInterval` 0, no-op `refresh()`). Provider
/// credentials live in `AIConfigStore` (key in `CredentialStore`, the rest in
/// namespaced `UserDefaults`), edited on the settings page.
@MainActor
@Observable
final class AIPlugin: GlancePlugin {
    nonisolated var id: String { "ai" }
    nonisolated var title: String { "Assistant" }
    nonisolated var iconSystemName: String { "sparkles" }

    /// The live conversation, built once with the registry + coordinator so it
    /// can reach the other glances as tools and request refreshes.
    let conversation: AIConversation

    init(registry: PluginRegistry, coordinator: RefreshCoordinator) {
        self.conversation = AIConversation(registry: registry, coordinator: coordinator)
    }

    func refresh() async {}

    /// A chat surface earns a roomier standalone window than the default — tall
    /// enough for a run of messages plus the input row to breathe, and wide
    /// enough for readable bubbles. Comparable to Notes' 660×640 two-pane.
    var preferredToolWindowSize: CGSize? { CGSize(width: 460, height: 620) }

    /// The chat owns its vertical layout — transcript fills, composer pins to the
    /// bottom — so it fills the tool window instead of being scroll-wrapped.
    var fillsToolWindow: Bool { true }

    func popoverSection() -> AnyView { AnyView(AIChatView(conversation: conversation)) }
    func settingsSection() -> AnyView { AnyView(AISettingsView()) }
}
