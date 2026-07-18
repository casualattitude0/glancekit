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

    /// The glance currently shown, falling back to the first in the ring.
    var current: (any GlancePlugin)? {
        if let selectedID, let hit = ring.first(where: { $0.id == selectedID }) { return hit }
        return ring.first
    }

    /// Point the window at `plugins`, keeping the current selection when it's
    /// still in the ring and otherwise falling back to the first. Called on every
    /// Quick Switch press, so reconfiguring the ring in Settings takes effect at
    /// once — a glance dropped from the ring can't stay selected.
    func setRing(_ plugins: [any GlancePlugin]) {
        ring = plugins
        if selectedID == nil || !plugins.contains(where: { $0.id == selectedID }) {
            selectedID = plugins.first?.id
        }
    }

    func select(_ id: String) { selectedID = id }

    /// Step to the next tool, wrapping — what the shortcut does with the window up.
    func advance() { step(by: 1) }

    /// Step to the previous tool, wrapping — the in-window back accelerator.
    func retreat() { step(by: -1) }

    private func step(by delta: Int) {
        guard !ring.isEmpty else { return }
        let index = selectedID.flatMap { id in ring.firstIndex { $0.id == id } } ?? 0
        selectedID = ring[(index + delta + ring.count) % ring.count].id
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

    /// A horizontal, scrolling strip of every glance in the ring. The selected
    /// tab is tinted, and it scrolls itself into view when the shortcut advances
    /// past the visible edge so the current tool is always on screen.
    private var navBar: some View {
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
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let plugin = model.current {
            Group {
                // A glance that owns its own vertical layout fills the window;
                // everything else scrolls to fit — same contract the old per-glance
                // tool window honored via `fillsToolWindow`.
                if plugin.fillsToolWindow {
                    plugin.popoverSection()
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        plugin.popoverSection()
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            // Rebuild the body on every switch: transient view state (a half-open
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
            Text("⇧⌘[  /  ⇧⌘]  to switch")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
        // Safari-style next/prev-tab accelerators, kept out of the layout. Using
        // ⇧⌘[ / ⇧⌘] rather than bare arrows so switching never steals the arrow
        // keys from a glance's own text field (e.g. the Notes editor).
        .background(accelerators)
    }

    private var accelerators: some View {
        ZStack {
            Button("", action: model.advance)
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("", action: model.retreat)
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
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
