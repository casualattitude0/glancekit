import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// UNIFIED QUICK SWITCH WINDOW
// ─────────────────────────────────────────────────────────────────────────────
// Quick Switch used to close one glance's tool window and open the next as you
// stepped around the ring — every glance a separate window at its own size,
// flickering open and shut. This replaces that with ONE fixed-size window: a
// navigation bar of every switchable glance across the top, and the selected
// glance's `popoverSection()` below. Clicking a tab or pressing the Quick Switch
// shortcut just swaps the body; the window stays put and keeps its size.
//
// `ToolWindowManager` owns the window (so it shares the auto-close and eyedropper
// suspend/resume machinery) and the long-lived `QuickSwitchModel` (so the nav bar
// and the shortcut drive the same selection, and closing the window doesn't lose
// which tool you were on — reopening resumes it).
// ─────────────────────────────────────────────────────────────────────────────

/// Selection state for the unified Quick Switch window: which glances are in the
/// switchable ring, and which one is on screen.
///
/// `@Observable` and long-lived (owned by `ToolWindowManager`) so the nav bar and
/// the body both react to a tab click *and* a shortcut press, and so the choice
/// survives the window closing — reopening lands on the tool you left on.
@MainActor
@Observable
final class QuickSwitchModel {
    private(set) var ring: [any GlancePlugin] = []

    var selectedID: String?

    /// The AI Assistant, pinned separately from the ring so it's reachable from
    /// any tool regardless of ring configuration — the "get help, then get back"
    /// affordance. Kept out of `ring` (see `configure`) so it never doubles as a
    /// ring tab.
    private(set) var assistant: (any GlancePlugin)?

    /// The tool to return to when leaving the Assistant: whatever was on screen
    /// when it was summoned. Lets a detour to the Assistant snap straight back to
    /// the original tool. `nil` once consumed or when navigating the ring directly.
    private(set) var originID: String?

    /// The user's configured Quick Switch shortcut, as a display string (e.g.
    /// "⌥⇥"), shown in the footer so the hint always names the real key rather
    /// than a hardcoded guess. `nil` when the shortcut is unbound.
    var switchShortcut: String?

    /// The glance currently shown — a ring tool or the pinned Assistant — falling
    /// back to the first ring tool.
    var current: (any GlancePlugin)? {
        if let selectedID {
            if let hit = ring.first(where: { $0.id == selectedID }) { return hit }
            if let assistant, assistant.id == selectedID { return assistant }
        }
        return ring.first
    }

    /// Every tool the window can show — the ring plus the pinned Assistant. Used
    /// to size the window to fit them all at once, so it never resizes on a switch.
    var allTools: [any GlancePlugin] {
        ring + (assistant.map { [$0] } ?? [])
    }

    /// Whether the Assistant is the tool on screen.
    var isShowingAssistant: Bool { assistant.map { $0.id == selectedID } ?? false }

    /// The title of the tool a Back button would return to, if any.
    var originTitle: String? {
        originID.flatMap { id in ring.first { $0.id == id }?.title }
    }

    /// Point the window at the ring plus the pinned Assistant, keeping the current
    /// selection when it's still valid and otherwise falling back to the first
    /// ring tool. Called on every Quick Switch press, so reconfiguring the ring in
    /// Settings takes effect at once.
    func configure(ring: [any GlancePlugin], assistant: (any GlancePlugin)?) {
        // Dedupe the Assistant out of the ring: it's pinned on its own, so letting
        // it also be a ring tab would show it twice.
        self.ring = ring.filter { $0.id != assistant?.id }
        self.assistant = assistant

        var valid = Set(self.ring.map(\.id))
        if let assistant { valid.insert(assistant.id) }
        if selectedID == nil || !(selectedID.map(valid.contains) ?? false) {
            selectedID = self.ring.first?.id ?? assistant?.id
        }
    }

    /// Select a ring tool directly (a nav-bar click). Clears any pending Back —
    /// navigating the ring by hand ends the Assistant detour.
    func select(_ id: String) {
        originID = nil
        selectedID = id
    }

    /// Jump to the Assistant, remembering the current tool so `returnToOrigin()`
    /// can come straight back. A no-op detail: re-summoning while already on the
    /// Assistant keeps the original origin rather than losing it.
    func showAssistant() {
        guard let assistant, selectedID != assistant.id else { return }
        originID = selectedID
        selectedID = assistant.id
    }

    /// Return from the Assistant to the tool it was summoned from, falling back to
    /// the first ring tool when that origin is gone.
    func returnToOrigin() {
        let target = originID.flatMap { id in ring.first { $0.id == id }?.id } ?? ring.first?.id
        originID = nil
        selectedID = target
    }

    /// Step to the next tool, wrapping — what the shortcut does with the window up.
    /// On the Assistant it instead snaps back to where you were, so the same key
    /// that cycles the ring also gets you out of an Assistant detour.
    func advance() {
        if isShowingAssistant { returnToOrigin(); return }
        guard !ring.isEmpty else { return }
        originID = nil
        let index = selectedID.flatMap { id in ring.firstIndex { $0.id == id } } ?? 0
        selectedID = ring[(index + 1) % ring.count].id
    }
}

/// The window body: nav bar on top, the selected glance's section below, a hint
/// and Close button at the foot.
struct QuickSwitchWindowContent: View {
    @Bindable var model: QuickSwitchModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navBar

            Divider()

            content

            Divider()

            footer
        }
        // Room for the transparent titlebar the content draws under.
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The nav bar: an optional Back button (shown on the Assistant, to snap back
    /// to the tool it was summoned from), the scrolling ring tabs, and the pinned
    /// Assistant on the trailing edge — always reachable, kept outside the scroll
    /// so it never slides off no matter how many glances are in the ring.
    private var navBar: some View {
        HStack(spacing: 8) {
            if model.isShowingAssistant, let origin = model.originTitle {
                backButton(to: origin)
            }

            ringTabs

            if let assistant = model.assistant {
                Divider().frame(height: 22)
                QuickSwitchTab(plugin: assistant, isSelected: model.isShowingAssistant) {
                    model.showAssistant()
                }
                .help("Ask the Assistant, then jump back")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The scrolling strip of ring tabs. The selected tab is tinted, and it
    /// scrolls itself into view when the shortcut advances past the visible edge.
    private var ringTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.ring, id: \.id) { plugin in
                        QuickSwitchTab(plugin: plugin, isSelected: plugin.id == model.selectedID) {
                            model.select(plugin.id)
                        }
                        .id(plugin.id)
                    }
                }
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Snaps back from the Assistant to the tool it was opened from.
    private func backButton(to title: String) -> some View {
        Button(action: model.returnToOrigin) {
            Label("Back to \(title)", systemImage: "chevron.left")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Return to \(title)")
    }

    @ViewBuilder
    private var content: some View {
        if let plugin = model.current {
            // The very same section a glance shows in its own tool window — title
            // row, divider, scrolling body — so switching tools here is identical
            // to opening each on its own, only without the window swap.
            ToolGlanceSection(plugin: plugin)
                // Rebuild on every switch: transient view state (a half-open
                // picker, scroll offset) resets per tool, while the glance's real
                // state lives in its @Observable plugin object and persists.
                .id(plugin.id)
        } else {
            // The ring emptied out from under us (every glance excluded/disabled).
            ContentUnavailableView(
                "No glances in Quick Switch",
                systemImage: "rectangle.stack",
                description: Text("Add glances to the ring in Settings → Quick Switch.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Names the user's real Quick Switch shortcut (which fires globally,
            // so it advances the ring even while this window is focused), not a
            // hardcoded key. Falls back to a pointer to Settings when unbound.
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var hint: String {
        // On the Assistant, point at the way back to the tool you came from.
        if model.isShowingAssistant, let origin = model.originTitle {
            if let shortcut = model.switchShortcut {
                return "\(shortcut) or Back to return to \(origin)"
            }
            return "Click Back to return to \(origin)"
        }
        if let shortcut = model.switchShortcut {
            return "\(shortcut) or click a tab to switch"
        }
        return "Click a tab to switch — set a shortcut in Settings → Shortcuts"
    }
}

/// One tab in the nav bar: icon + title, tinted when it's the glance on screen.
private struct QuickSwitchTab: View {
    let plugin: any GlancePlugin
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: plugin.iconSystemName)
                    .font(.system(size: 12, weight: .medium))
                Text(plugin.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.18)
                          : Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0.55 : 0), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(plugin.title)
    }
}
