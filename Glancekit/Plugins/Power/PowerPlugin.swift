import SwiftUI
import Observation

/// A rich battery/power glance that goes deeper than the basic battery % in the
/// Mac Health glance: cycle count, battery health %, temperature, adapter
/// wattage, condition, and a rolling charge-history sparkline.
///
/// All readings come from IOKit (`PowerMetrics`) — no network, no secrets.
@MainActor
@Observable
final class PowerPlugin: GlancePlugin {
    nonisolated var id: String { "power" }
    nonisolated var title: String { "Power" }
    nonisolated var iconSystemName: String { "battery.100.bolt" }
    var refreshInterval: TimeInterval { 30 }

    /// A recommended popover size — the details grid + sparkline want room.
    var preferredToolWindowSize: CGSize? { CGSize(width: 320, height: 380) }

    // MARK: State

    private(set) var snapshot = PowerMetrics.Snapshot()

    /// Rolling charge history: percentage samples with timestamps, capped at
    /// `maxHistory`, persisted so the sparkline survives relaunches.
    private(set) var history: [HistorySample] = []
    private let maxHistory = 120

    // MARK: Persisted preferences

    var showHealth: Bool {
        didSet { UserDefaults.standard.set(showHealth, forKey: "glancekit.power.showHealth") }
    }
    var showCycles: Bool {
        didSet { UserDefaults.standard.set(showCycles, forKey: "glancekit.power.showCycles") }
    }
    var showTemperature: Bool {
        didSet { UserDefaults.standard.set(showTemperature, forKey: "glancekit.power.showTemperature") }
    }
    var showAdapter: Bool {
        didSet { UserDefaults.standard.set(showAdapter, forKey: "glancekit.power.showAdapter") }
    }
    var showCondition: Bool {
        didSet { UserDefaults.standard.set(showCondition, forKey: "glancekit.power.showCondition") }
    }
    /// Percentage at/below which a discharging battery earns an urgent signal.
    var lowThreshold: Int {
        didSet { UserDefaults.standard.set(lowThreshold, forKey: "glancekit.power.lowThreshold") }
    }

    struct HistorySample: Codable {
        let percent: Int
        let time: Date
    }

    private let historyKey = "glancekit.power.history"

    init() {
        let d = UserDefaults.standard
        showHealth = d.object(forKey: "glancekit.power.showHealth") as? Bool ?? true
        showCycles = d.object(forKey: "glancekit.power.showCycles") as? Bool ?? true
        showTemperature = d.object(forKey: "glancekit.power.showTemperature") as? Bool ?? true
        showAdapter = d.object(forKey: "glancekit.power.showAdapter") as? Bool ?? true
        showCondition = d.object(forKey: "glancekit.power.showCondition") as? Bool ?? true
        lowThreshold = d.object(forKey: "glancekit.power.lowThreshold") as? Int ?? 10

        if let data = d.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) {
            history = decoded
        }
    }

    // MARK: GlancePlugin

    func refresh() async {
        snapshot = PowerMetrics.read()
        if let pct = snapshot.percentage {
            history.append(HistorySample(percent: pct, time: Date()))
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: historyKey)
            }
        }
    }

    /// Emphasises what the basic battery readout does NOT: battery *health*.
    /// A degraded battery earns an elevated card; a low, discharging battery is
    /// urgent with a gauge accessory.
    func currentSignal() -> GlanceSignal? {
        guard snapshot.hasBattery else { return nil }

        // Urgent: low and draining.
        if snapshot.state == .discharging, let pct = snapshot.percentage, pct <= lowThreshold {
            var detail = "On battery"
            if let mins = snapshot.timeToEmptyMinutes {
                detail = "~\(formatMinutes(mins)) remaining"
            }
            return GlanceSignal(
                priority: .urgent,
                score: Double(100 - pct),
                headline: "Battery \(pct)% · plug in",
                detail: detail,
                systemImage: "battery.25",
                tint: .red,
                accessory: .gauge(Double(pct) / 100)
            )
        }

        // Elevated: battery health degraded / service recommended.
        if snapshot.healthIsDegraded {
            let healthText = snapshot.healthPercent.map { "\($0)%" } ?? "low"
            let cond = snapshot.condition ?? "Service recommended"
            return GlanceSignal(
                priority: .elevated,
                score: Double(100 - (snapshot.healthPercent ?? 0)),
                headline: "Battery health \(healthText)",
                detail: cond,
                systemImage: "battery.100.bolt",
                tint: .orange
            )
        }

        return nil
    }

    func popoverSection() -> AnyView { AnyView(PowerPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(PowerSettings(plugin: self)) }
}

// MARK: - Formatting helpers

private func formatMinutes(_ minutes: Int) -> String {
    guard minutes > 0 else { return "—" }
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Popover UI

private struct PowerPopover: View {
    let plugin: PowerPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plugin.snapshot.hasBattery {
                noBattery
            } else {
                header
                Divider()
                detailsGrid
                if plugin.history.count > 1 {
                    Divider()
                    chargeHistory
                }
            }
        }
    }

    private var noBattery: some View {
        HStack(spacing: 8) {
            Image(systemName: "powerplug")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No battery detected")
                    .font(.body.weight(.semibold))
                Text("This Mac runs on AC power only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        let snap = plugin.snapshot
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(snap.percentage.map { "\($0)%" } ?? "—")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            if snap.state == .charging || snap.state == .charged {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(stateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let remaining = remainingText {
                    Text(remaining)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateText: String {
        switch plugin.snapshot.state {
        case .charging: return "Charging"
        case .charged: return "Charged"
        case .discharging: return plugin.snapshot.powerSource == .battery ? "On battery" : "Not charging"
        case .unknown: return "—"
        }
    }

    private var remainingText: String? {
        let snap = plugin.snapshot
        if snap.state == .charging, let m = snap.timeToFullMinutes {
            return "\(formatMinutes(m)) to full"
        }
        if snap.state == .discharging, let m = snap.timeToEmptyMinutes {
            return "\(formatMinutes(m)) left"
        }
        return nil
    }

    private var detailsGrid: some View {
        let snap = plugin.snapshot
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if plugin.showHealth {
                row("Health", snap.healthPercent.map { "\($0)%" } ?? "—",
                    tint: snap.healthIsDegraded ? .orange : nil)
            }
            if plugin.showCycles {
                row("Cycle count", snap.cycleCount.map(String.init) ?? "—")
            }
            if plugin.showTemperature {
                row("Temperature", snap.temperatureC.map { String(format: "%.1f°C", $0) } ?? "—")
            }
            if plugin.showAdapter {
                row("Adapter", adapterText(snap))
            }
            if plugin.showCondition {
                row("Condition", snap.condition ?? "Normal",
                    tint: snap.healthIsDegraded ? .orange : nil)
            }
        }
    }

    private func adapterText(_ snap: PowerMetrics.Snapshot) -> String {
        if snap.powerSource == .ac, let w = snap.adapterWatts {
            return "\(w) W"
        }
        return snap.powerSource == .ac ? "Plugged" : "Unplugged"
    }

    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(tint ?? .primary)
                .gridColumnAlignment(.trailing)
        }
    }

    private var chargeHistory: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Charge history")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("last \(plugin.history.count)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            PowerSparkline(values: plugin.history.map { Double($0.percent) })
                .frame(height: 40)
        }
    }
}

/// A minimal filled line chart of the recent charge percentages, fixed to a
/// 0–100 vertical scale so the trend is read against the full range.
private struct PowerSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if values.count > 1 {
                let up = (values.last ?? 0) >= (values.first ?? 0)
                let color: Color = up ? .green : .orange
                let path = linePath(width: w, height: h)
                path
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .background(
                        filledPath(width: w, height: h)
                            .fill(color.opacity(0.15))
                    )
            } else {
                Rectangle().fill(.quaternary)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func point(_ i: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        let x = width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
        let clamped = min(max(values[i], 0), 100)
        let y = height * (1 - CGFloat(clamped / 100))
        return CGPoint(x: x, y: y)
    }

    private func linePath(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            for i in values.indices {
                let pt = point(i, width: width, height: height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func filledPath(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: CGPoint(x: 0, y: height))
            for i in values.indices {
                p.addLine(to: point(i, width: width, height: height))
            }
            p.addLine(to: CGPoint(x: width, y: height))
            p.closeSubpath()
        }
    }
}

// MARK: - Settings UI

private struct PowerSettings: View {
    @Bindable var plugin: PowerPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detail rows")
                .font(.headline)
            Text("Choose which battery details appear in the popover.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Battery health %", isOn: $plugin.showHealth)
            Toggle("Cycle count", isOn: $plugin.showCycles)
            Toggle("Temperature", isOn: $plugin.showTemperature)
            Toggle("Power adapter", isOn: $plugin.showAdapter)
            Toggle("Condition", isOn: $plugin.showCondition)

            Divider()

            Text("Low-battery alert")
                .font(.headline)
            Stepper(value: $plugin.lowThreshold, in: 5...50, step: 5) {
                Text("Alert at \(plugin.lowThreshold)% or below")
                    .font(.callout)
            }
            Text("The Smart Panel raises an urgent card when the battery drains to this level.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
