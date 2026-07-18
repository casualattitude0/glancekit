import SwiftUI
import AppKit

/// The **Smart Panel**: the dynamic menu-bar layout that surfaces the glances
/// that need attention right now instead of showing every enabled glance in a
/// fixed row (that's `ClassicPanelView`).
///
/// It has three parts that together make it feel aware rather than list-like:
///   • a one-line **brief** at the top (rule-based instantly, AI-written when a
///     provider is configured) that says what matters right now;
///   • a **ranked feed** of rich cards — each carries real content (a memory
///     gauge, a stock sparkline, the actual notification title), an inline
///     action where there's an obvious next step, and a "NEW" badge when it
///     wasn't there last time you looked;
///   • a pinned **Assistant + Notes** footer, always one click away.
///
/// Every glance is `@Observable` and updates inside `refresh()`, so the ranking,
/// badges, and brief all recompute reactively as the machine's state changes.
struct SmartPanelView: View {
    @Environment(PluginRegistry.self) private var registry
    @Environment(SmartPanelHistory.self) private var history

    @State private var brief = SmartBriefModel()

    /// Pinned to the footer, so they're excluded from the ranked feed above.
    private static let pinnedIDs: Set<String> = ["ai", "notes"]

    /// Soft ceiling on cards. Generous, so the dynamic feed shows the whole
    /// picture — every glance that has something to say — not just the top few.
    private static let cardCap = 10

    var body: some View {
        let context = PanelContext()
        let ranked = rankedSignals(
            from: registry.enabledPluginsInOrder.filter { !Self.pinnedIDs.contains($0.id) },
            cap: Self.cardCap
        )
        let deltas = Dictionary(uniqueKeysWithValues: ranked.map {
            ($0.plugin.id, history.delta(id: $0.plugin.id, headline: $0.signal.headline, score: $0.signal.score))
        })
        let briefItems = ranked.map { item in
            (title: item.plugin.title, headline: item.signal.headline, detail: item.signal.detail,
             priority: item.signal.priority, isNew: deltas[item.plugin.id]?.isNew ?? false)
        }
        // Coarse key: which glances and how urgent (plus novelty) — NOT their live
        // numbers — so the brief holds still while a price or percentage ticks.
        let signature = ranked.map {
            "\($0.plugin.id)|\($0.signal.priority.rawValue)|\(deltas[$0.plugin.id]?.isNew ?? false)"
        }.joined(separator: "~")

        VStack(spacing: 0) {
            PanelHeader()

            Divider()

            if !brief.text.isEmpty {
                BriefBar(text: brief.text, isAIWritten: brief.isAIWritten)
                Divider()
            }

            feed(ranked: ranked, deltas: deltas)

            Divider()

            PinnedToolsFooter(pluginIDs: ["ai", "notes"])
        }
        // Recompute the brief only when the feed's contents change, not on every
        // render — keeps it cheap and spends an AI call only when it's warranted.
        .task(id: signature) { brief.update(context: context, items: briefItems) }
        // Record what was shown so the next open can flag what's changed.
        .onDisappear {
            history.commit(ranked.map { ($0.plugin.id, $0.signal.headline, $0.signal.score) })
        }
    }

    @ViewBuilder
    private func feed(ranked: [RankedSignal], deltas: [String: SmartPanelHistory.Delta]) -> some View {
        if ranked.isEmpty {
            ContentUnavailableView(
                "All quiet",
                systemImage: "checkmark.circle",
                description: Text("Nothing needs your attention right now.")
            )
            .padding(.vertical, 24)
        } else {
            // No scroll view: the panel grows to fit every card, so nothing hides
            // below a fold the user can't see. The feed is naturally bounded by
            // how many glances have something to say.
            VStack(spacing: 6) {
                ForEach(ranked) { item in
                    SignalCard(ranked: item, delta: deltas[item.plugin.id] ?? .none) {
                        open(item.plugin)
                    }
                }
            }
            .padding(12)
        }
    }

    /// Open the glance's standalone tool window at the mouse, then dismiss the
    /// panel — the same popover-capture dance `PopoverRootView` uses for Settings.
    private func open(_ plugin: any GlancePlugin) {
        let popover = NSApp.keyWindow
        ToolWindowManager.shared.toggle(plugin: plugin)
        popover?.close()
    }
}

// MARK: - Ranking

/// A glance paired with the signal it's currently reporting.
struct RankedSignal: Identifiable {
    let plugin: any GlancePlugin
    let signal: GlanceSignal
    @MainActor var id: String { plugin.id }
}

/// Rank the glances' current signals for the feed. Every glance that reports a
/// signal gets a card, sorted by urgency then score — the urgent things rise to
/// the top and the quiet `ambient` readings fill in beneath them, up to `cap`.
/// So the dynamic panel shows the full picture at a glance while still leading
/// with what matters most.
@MainActor
func rankedSignals(from plugins: [any GlancePlugin], cap: Int) -> [RankedSignal] {
    plugins
        .compactMap { plugin in plugin.currentSignal().map { RankedSignal(plugin: plugin, signal: $0) } }
        .sorted { ($0.signal.priority, $0.signal.score) > ($1.signal.priority, $1.signal.score) }
        .prefix(cap)
        .map { $0 }
}

// MARK: - Brief bar

private struct BriefBar: View {
    let text: String
    let isAIWritten: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isAIWritten ? "sparkles" : "text.alignleft")
                .font(.caption)
                .foregroundStyle(isAIWritten ? .purple : .secondary)
                .help(isAIWritten ? "Written by your assistant" : "Summary")
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Signal card

private struct SignalCard: View {
    let ranked: RankedSignal
    let delta: SmartPanelHistory.Delta
    let onTap: () -> Void

    @State private var isHovering = false

    private var accent: Color { ranked.signal.tint ?? priorityColor(ranked.signal.priority) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)

            Image(systemName: ranked.signal.systemImage ?? ranked.plugin.iconSystemName)
                .font(.body)
                .foregroundStyle(accent)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ranked.signal.headline)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if delta.isNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue, in: Capsule())
                    } else if delta.changed {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .help("Updated since you last looked")
                    }
                }

                if let detail = ranked.signal.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                accessory

                if let action = ranked.signal.quickAction {
                    Button {
                        action.run()
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text(ranked.plugin.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0.04))
        )
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help("Open \(ranked.plugin.title)")
    }

    @ViewBuilder
    private var accessory: some View {
        switch ranked.signal.accessory {
        case .none:
            EmptyView()
        case .gauge(let value):
            GaugeBar(value: value, tint: accent)
                .frame(height: 5)
                .frame(maxWidth: 150, alignment: .leading)
        case .sparkline(let values, let up):
            MiniSparkline(values: values, up: up)
                .frame(width: 120, height: 22)
        }
    }

    /// A neutral fallback tint when a signal doesn't specify its own colour.
    private func priorityColor(_ priority: GlanceSignal.Priority) -> Color {
        switch priority {
        case .urgent: return .red
        case .elevated: return .orange
        case .normal: return .accentColor
        case .ambient: return .secondary
        }
    }
}

// MARK: - Accessory views

/// A 0…1 filled capsule bar for a ratio reading (memory, disk, battery).
private struct GaugeBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(3, geo.size.width * min(1, max(0, value))))
            }
        }
    }
}

/// A minimal filled line chart for an intraday series — a compact echo of the
/// Stocks popover sparkline, self-contained so the card doesn't depend on it.
private struct MiniSparkline: View {
    let values: [Double]
    let up: Bool

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max(), hi > lo {
                let w = geo.size.width
                let h = geo.size.height
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(values.count - 1)
                        let y = h * (1 - CGFloat((v - lo) / (hi - lo)))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(up ? Color.green : Color.red, lineWidth: 1.5)
            } else {
                Rectangle().fill(.quaternary).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - Pinned tools footer

/// Always-present launchers for the Assistant and Notes, so the two core tools
/// stay one click away regardless of what the ranked feed is showing. Each opens
/// its standalone tool window and dismisses the panel.
private struct PinnedToolsFooter: View {
    @Environment(PluginRegistry.self) private var registry
    let pluginIDs: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(pluginIDs, id: \.self) { id in
                if let plugin = registry.plugin(id: id) {
                    Button {
                        let popover = NSApp.keyWindow
                        ToolWindowManager.shared.toggle(plugin: plugin)
                        popover?.close()
                    } label: {
                        Label(plugin.title, systemImage: plugin.iconSystemName)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
