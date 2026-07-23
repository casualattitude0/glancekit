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

    /// When true, the popover shows the inverted quote ("1 EUR = 1.08 USD")
    /// instead of the native direction ("1 USD = 0.92 EUR").
    var invertDisplay: Bool {
        didSet { UserDefaults.standard.set(invertDisplay, forKey: invertKey) }
    }

    private let baseKey = "glancekit.currency.base"
    private let targetsKey = "glancekit.currency.targets"
    private let historyKey = "glancekit.currency.history"
    private let invertKey = "glancekit.currency.invert"

    /// Number of samples kept per pair for the sparkline / change window.
    private let historyLimit = 30

    private(set) var rates: [CurrencyRate] = []
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?

    init() {
        base = (UserDefaults.standard.string(forKey: baseKey) ?? "USD").uppercased()
        targets = UserDefaults.standard.stringArray(forKey: targetsKey)
            ?? ["EUR", "JPY", "GBP", "TWD", "CNY"]
        invertDisplay = UserDefaults.standard.bool(forKey: invertKey)
    }

    // MARK: Target / base management (used by settings)

    /// Sets the base currency from a raw code, normalising to uppercase, and
    /// drops it from the targets if present (a base can't be its own target).
    func setBase(_ code: String) {
        let newBase = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !newBase.isEmpty, newBase != base else { return }
        base = newBase
        if let idx = targets.firstIndex(of: newBase) {
            targets.remove(at: idx)
        }
    }

    /// Adds a target currency if it's a valid, non-duplicate code that isn't the
    /// base. Returns whether it was added, so the UI can report a duplicate.
    @discardableResult
    func addTarget(_ code: String) -> Bool {
        let newCode = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !newCode.isEmpty, newCode != base,
              !targets.contains(newCode) else { return false }
        targets.append(newCode)
        return true
    }

    /// Removes the targets at the given offsets (supports `.onDelete`-style calls
    /// and single-row minus buttons).
    func removeTargets(at offsets: IndexSet) {
        targets.remove(atOffsets: offsets)
    }

    /// Moves a target one slot toward the front of the list.
    func moveTargetUp(_ code: String) {
        guard let i = targets.firstIndex(of: code), i > 0 else { return }
        targets.swapAt(i, i - 1)
    }

    /// Moves a target one slot toward the back of the list.
    func moveTargetDown(_ code: String) {
        guard let i = targets.firstIndex(of: code), i < targets.count - 1 else { return }
        targets.swapAt(i, i + 1)
    }

    /// Replaces the whole target list from a de-duplicated, normalised set of
    /// codes (used by the power-user comma field). Order is preserved.
    func setTargets(_ codes: [String]) {
        var seen = Set<String>()
        var result: [String] = []
        for raw in codes {
            let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !code.isEmpty, code != base, seen.insert(code).inserted else { continue }
            result.append(code)
        }
        targets = result
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
                    .foregroundStyle(GlanceStyle.warning)
            }
            if plugin.rates.isEmpty {
                Text("No rates yet…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugin.rates) { rate in
                    row(for: rate)
                }
            }
        }
    }

    /// One pair row, honouring the invert-display preference. Kept as a helper so
    /// the derived values live in ordinary function-body `let`s.
    private func row(for rate: CurrencyRate) -> some View {
        let invert = plugin.invertDisplay
        // Which currency the "1 …" is quoted in, and which the value is
        // expressed in — these flip when inverted.
        let unitCode = invert ? rate.code : rate.base
        let quoteCode = invert ? rate.base : rate.code
        let value = invert ? (rate.rate == 0 ? 0 : 1 / rate.rate) : rate.rate
        // The inverse rate moves opposite to the native rate.
        let up = invert ? !rate.isUp : rate.isUp
        let change = invert ? -rate.changePercent : rate.changePercent
        let series = invert ? rate.series.map { $0 == 0 ? 0 : 1 / $0 } : rate.series

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(quoteCode)
                    .font(.body.weight(.semibold))
                Text("1 \(unitCode) =")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)

            CurrencySparkline(values: series, up: up)
                .frame(width: 70, height: 24)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.4f", value))
                    .font(.body.monospacedDigit())
                Text(String(format: "%@%.2f%%", up ? "+" : "−", abs(change)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(up ? .green : .red)
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
                .stroke(up ? GlanceStyle.positive : GlanceStyle.negative, lineWidth: 1.5)
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
    @State private var addSearch: String = ""
    @State private var amountText: String = "1"
    @State private var showPowerUser = false
    @State private var targetsText: String = ""

    var body: some View {
        SettingsPage("Base currency", intro: "Everything is quoted against this currency.") {
            baseSection
            Divider()
            targetsSection
            Divider()
            converterSection
            Divider()
            displaySection
            Divider()
            powerUserSection
        }
        .onAppear {
            targetsText = plugin.targets.joined(separator: ", ")
        }
    }

    // MARK: Base

    private var baseSection: some View {
        Picker("Base currency", selection: baseBinding) {
            ForEach(CurrencyCatalog.codes, id: \.self) { code in
                Text(CurrencyCatalog.label(for: code)).tag(code)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 320, alignment: .leading)
    }

    /// Routes selection through `setBase` so persistence, de-duping against the
    /// target list, and a refresh all happen together.
    private var baseBinding: Binding<String> {
        Binding(
            get: { plugin.base },
            set: { newValue in
                plugin.setBase(newValue)
                targetsText = plugin.targets.joined(separator: ", ")
                Task { await plugin.refresh() }
            }
        )
    }

    // MARK: Targets

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Target currencies")

            if plugin.targets.isEmpty {
                Label("No target currencies yet. Add one below.", systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(plugin.targets.enumerated()), id: \.element) { index, code in
                    targetRow(code: code, index: index)
                }
            }

            addRow
        }
    }

    private func targetRow(code: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(CurrencyCatalog.flag(for: code) ?? "💱")
            VStack(alignment: .leading, spacing: 1) {
                Text(code).font(.body.weight(.medium))
                Text(CurrencyCatalog.name(for: code))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                plugin.moveTargetUp(code)
                syncPowerUserField()
                Task { await plugin.refresh() }
            } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)

            Button {
                plugin.moveTargetDown(code)
                syncPowerUserField()
                Task { await plugin.refresh() }
            } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == plugin.targets.count - 1)

            Button(role: .destructive) {
                plugin.removeTargets(at: IndexSet(integer: index))
                syncPowerUserField()
                Task { await plugin.refresh() }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(GlanceStyle.negative)
        }
        .padding(.vertical, 2)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Add currency (search code or name)…", text: $addSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320, alignment: .leading)

            if !addSearch.isEmpty {
                if addMatches.isEmpty {
                    SettingsHelp("No matching currency.")
                } else {
                    ForEach(addMatches, id: \.self) { code in
                        Button {
                            plugin.addTarget(code)
                            addSearch = ""
                            syncPowerUserField()
                            Task { await plugin.refresh() }
                        } label: {
                            Text(CurrencyCatalog.label(for: code))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// Candidate codes for the add field: not already a target, not the base,
    /// matching the search text on code or localized name. Capped for tidiness.
    private var addMatches: [String] {
        let query = addSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let existing = Set(plugin.targets)
        return CurrencyCatalog.codes.filter { code in
            guard code != plugin.base, !existing.contains(code) else { return false }
            return code.lowercased().contains(query)
                || CurrencyCatalog.name(for: code).lowercased().contains(query)
        }
        .prefix(8)
        .map { $0 }
    }

    // MARK: Converter

    private var converterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Converter")
            HStack(spacing: 6) {
                TextField("Amount", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text(plugin.base)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if plugin.rates.isEmpty {
                SettingsHelp("Rates load after the first refresh.")
            } else if let amount = parsedAmount {
                ForEach(plugin.rates) { rate in
                    HStack {
                        Text("\(formatted(amount)) \(rate.base)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("\(formatted(amount * rate.rate)) \(rate.code)")
                            .font(.body.monospacedDigit().weight(.medium))
                    }
                    .font(.callout)
                }
            } else {
                SettingsHelp("Enter a number to convert.")
            }
        }
    }

    private var parsedAmount: Double? {
        Double(amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: Display

    private var displaySection: some View {
        SettingsToggleRow(
            "Invert quotes (show 1 target = N base)",
            detail: plugin.invertDisplay
                ? "Showing e.g. 1 EUR = 1.08 USD."
                : "Showing e.g. 1 USD = 0.92 EUR.",
            isOn: $plugin.invertDisplay
        )
    }

    // MARK: Power user

    private var powerUserSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup("Edit as text (power user)", isExpanded: $showPowerUser) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsHelp("Comma-separated ISO currency codes.")
                    TextField("EUR, JPY, GBP", text: $targetsText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("Apply list") {
                        plugin.setTargets(targetsText.split(separator: ",").map(String.init))
                        targetsText = plugin.targets.joined(separator: ", ")
                        Task { await plugin.refresh() }
                    }
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
    }

    private func syncPowerUserField() {
        targetsText = plugin.targets.joined(separator: ", ")
    }
}
