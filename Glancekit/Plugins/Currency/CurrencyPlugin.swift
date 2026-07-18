import SwiftUI
import Observation

/// Currency / FX-rate glance: watch a base currency against a list of targets.
///
/// - Data source: `OpenERateProvider` (keyless `open.er-api.com`) by default.
/// - open.er-api gives only the latest snapshot, so this plugin keeps its own
///   short rolling history per pair (persisted in `UserDefaults`) and derives
///   change% and the sparkline from it — mirroring how Stocks shows an intraday
///   sparkline.
/// - Popover: one row per pair with "1 USD = 0.92 EUR", a sparkline, and a
///   coloured change%.
///
/// Modelled closely on `StocksPlugin`.
@MainActor
@Observable
final class CurrencyPlugin: GlancePlugin {
    nonisolated var id: String { "currency" }
    nonisolated var title: String { "Currency" }
    nonisolated var iconSystemName: String { "dollarsign.arrow.circlepath" }
    // FX moves slowly; a 15-minute cadence is plenty. Overnight/weekend rates
    // barely move, so there's no benefit to going faster.
    var refreshInterval: TimeInterval { marketProbablyActive ? 900 : 1800 }

    /// Persisted base currency (uppercased ISO code).
    var base: String {
        didSet { UserDefaults.standard.set(base, forKey: baseKey) }
    }
    /// Persisted target currency codes.
    var targets: [String] {
        didSet { UserDefaults.standard.set(targets, forKey: targetsKey) }
    }

    private let baseKey = "glancekit.currency.base"
    private let targetsKey = "glancekit.currency.targets"
    private let historyKey = "glancekit.currency.history"

    /// Number of samples kept per pair for the sparkline / change window.
    private let historyLimit = 30

    private(set) var rates: [CurrencyRate] = []
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?

    init() {
        base = (UserDefaults.standard.string(forKey: baseKey) ?? "USD").uppercased()
        targets = UserDefaults.standard.stringArray(forKey: targetsKey)
            ?? ["EUR", "JPY", "GBP", "TWD", "CNY"]
    }

    // MARK: GlancePlugin

    func refresh() async {
        let provider: RateProvider = OpenERateProvider()
        let wantedBase = base
        let wanted = targets.filter { $0 != wantedBase }
        guard !wantedBase.isEmpty, !wanted.isEmpty else {
            rates = []
            lastError = "Add a base currency and at least one target."
            return
        }
        do {
            let snapshot = try await provider.fetchRates(base: wantedBase)
            var history = loadHistory()
            var built: [CurrencyRate] = []
            var missing: [String] = []

            for code in wanted {
                guard let rate = snapshot.rates[code] else {
                    missing.append(code)
                    continue
                }
                let key = "\(wantedBase)/\(code)"
                var series = history[key] ?? []
                series.append(rate)
                if series.count > historyLimit {
                    series.removeFirst(series.count - historyLimit)
                }
                history[key] = series

                let first = series.first ?? rate
                let changePercent = first == 0 ? 0 : ((rate - first) / first) * 100
                built.append(CurrencyRate(
                    base: wantedBase,
                    code: code,
                    rate: rate,
                    changePercent: changePercent,
                    series: series
                ))
            }

            // Drop history for pairs no longer watched so the store can't grow
            // without bound.
            let liveKeys = Set(wanted.map { "\(wantedBase)/\($0)" })
            history = history.filter { liveKeys.contains($0.key) }
            saveHistory(history)

            rates = built
            lastUpdated = snapshot.updated
            if built.isEmpty {
                lastError = "No rates returned for \(wanted.joined(separator: ", "))."
            } else if !missing.isEmpty {
                lastError = "Unknown code(s): \(missing.joined(separator: ", "))."
            } else {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Surfaces the pair that has moved the most over the current window, with
    /// its sparkline. A flat market stays ambient; a larger move earns a higher
    /// priority — mirroring Stocks' biggest-mover card.
    func currentSignal() -> GlanceSignal? {
        guard let mover = rates.max(by: { abs($0.changePercent) < abs($1.changePercent) }) else {
            return nil
        }
        let magnitude = abs(mover.changePercent)
        let headline = String(format: "%@/%@ %@%.2f%% · %.4f",
                              mover.base, mover.code,
                              mover.isUp ? "+" : "−", magnitude, mover.rate)
        let tint: Color = mover.isUp ? .green : .red
        let priority: GlanceSignal.Priority
        if magnitude >= 1 { priority = .elevated }
        else if magnitude >= 0.25 { priority = .normal }
        else { priority = .ambient }
        return GlanceSignal(priority: priority, score: magnitude,
                            headline: headline,
                            systemImage: iconSystemName, tint: tint,
                            accessory: mover.series.count > 1 ? .sparkline(mover.series, up: mover.isUp) : .none)
    }

    func popoverSection() -> AnyView {
        AnyView(CurrencyPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(CurrencySettings(plugin: self))
    }

    // MARK: Helpers

    /// FX trades ~24×5. Used only to pick a refresh cadence, not for correctness:
    /// on weekends rates are effectively frozen, so slow down.
    private var marketProbablyActive: Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let weekday = cal.component(.weekday, from: Date())
        return weekday != 1 // Sunday
    }

    // MARK: History persistence

    private func loadHistory() -> [String: [Double]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: historyKey) else { return [:] }
        var result: [String: [Double]] = [:]
        for (key, value) in raw {
            if let arr = value as? [Double] {
                result[key] = arr
            } else if let arr = value as? [NSNumber] {
                result[key] = arr.map { $0.doubleValue }
            }
        }
        return result
    }

    private func saveHistory(_ history: [String: [Double]]) {
        UserDefaults.standard.set(history, forKey: historyKey)
    }
}

/// A single currency pair plus a rolling series used to draw the sparkline and
/// derive change%.
struct CurrencyRate: Identifiable, Equatable {
    /// Base currency code, e.g. "USD".
    let base: String
    /// Target currency code, e.g. "EUR".
    let code: String
    /// Units of `code` per 1 unit of `base`.
    let rate: Double
    /// Percent change over the retained history window.
    let changePercent: Double
    /// Recent rates, oldest → newest, for the sparkline.
    let series: [Double]

    var id: String { "\(base)/\(code)" }
    var isUp: Bool { changePercent >= 0 }
}

// MARK: - Popover UI

private struct CurrencyPopover: View {
    let plugin: CurrencyPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if plugin.rates.isEmpty {
                Text("No rates yet…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugin.rates) { rate in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(rate.code)")
                                .font(.body.weight(.semibold))
                            Text("1 \(rate.base) =")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 64, alignment: .leading)

                        CurrencySparkline(values: rate.series, up: rate.isUp)
                            .frame(width: 70, height: 24)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.4f", rate.rate))
                                .font(.body.monospacedDigit())
                            Text(String(format: "%@%.2f%%", rate.isUp ? "+" : "−", abs(rate.changePercent)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(rate.isUp ? .green : .red)
                        }
                    }
                }
            }
        }
    }
}

/// A minimal filled line chart for a rolling rate series.
private struct CurrencySparkline: View {
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

// MARK: - Settings UI

private struct CurrencySettings: View {
    @Bindable var plugin: CurrencyPlugin
    @State private var baseText: String = ""
    @State private var targetsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Base currency")
                .font(.headline)
            Text("A single ISO currency code, e.g. USD.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("USD", text: $baseText)
                .textFieldStyle(.roundedBorder)

            Text("Target currencies")
                .font(.headline)
            Text("Comma-separated ISO currency codes.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("EUR, JPY, GBP, TWD, CNY", text: $targetsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Button("Save") {
                let newBase = baseText.trimmingCharacters(in: .whitespaces).uppercased()
                if !newBase.isEmpty { plugin.base = newBase }
                plugin.targets = targetsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty }
                Task { await plugin.refresh() }
            }
        }
        .onAppear {
            baseText = plugin.base
            targetsText = plugin.targets.joined(separator: ", ")
        }
    }
}
