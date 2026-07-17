import SwiftUI
import Observation

/// Flagship glance: a stock watchlist.
///
/// - Data source: `YahooQuoteProvider` (keyless) by default; switches to
///   `FinnhubQuoteProvider` automatically when a Finnhub key is present in
///   Keychain under `finnhub.apiKey`.
/// - Menu-bar: contributes a compact "AAPL 227.50 ▲0.8%" summary for the
///   currently-highlighted symbol (the label view rotates across all glances).
/// - Popover: per-symbol rows with price, % change, and an intraday sparkline.
///
/// This is the reference implementation cited in `Core/PLUGIN_CONTRACT.md`.
@MainActor
@Observable
final class StocksPlugin: GlancePlugin {
    nonisolated var id: String { "stocks" }
    nonisolated var title: String { "Stocks" }
    nonisolated var iconSystemName: String { "chart.line.uptrend.xyaxis" }
    var refreshInterval: TimeInterval { marketProbablyOpen ? 60 : 900 }

    /// Persisted watchlist.
    var symbols: [String] {
        didSet { UserDefaults.standard.set(symbols, forKey: watchlistKey) }
    }
    private let watchlistKey = "glancekit.stocks.watchlist"

    private(set) var quotes: [StockQuote] = []
    private(set) var lastError: String?

    init() {
        symbols = UserDefaults.standard.stringArray(forKey: watchlistKey)
            ?? ["AAPL", "MSFT", "NVDA"]
    }

    // MARK: GlancePlugin

    var menuBarSummary: String? { quotes.first.map(Self.summary) }

    /// One rotating entry per watchlist symbol, in watchlist order, so the bar
    /// cycles through the whole list rather than pinning the first quote.
    var menuBarSummaries: [String] { quotes.map(Self.summary) }

    private static func summary(_ q: StockQuote) -> String {
        let arrow = q.isUp ? "▲" : "▼"
        return String(format: "%@ %.2f %@%.2f%%", q.symbol, q.price, arrow, abs(q.changePercent))
    }

    func refresh() async {
        let provider: QuoteProvider
        if let key = CredentialStore.get("finnhub.apiKey"), !key.isEmpty {
            provider = FinnhubQuoteProvider(apiKey: key)
        } else {
            provider = YahooQuoteProvider()
        }
        do {
            let fetched = try await provider.fetchQuotes(symbols)
            // Preserve watchlist order.
            quotes = symbols.compactMap { sym in fetched.first { $0.symbol == sym } }
            lastError = fetched.isEmpty && !symbols.isEmpty ? "No data returned" : nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func popoverSection() -> AnyView {
        AnyView(StocksPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(StocksSettings(plugin: self))
    }

    // MARK: Helpers

    /// Rough US-market-hours heuristic (weekday, 9:30–16:00 ET) used only to
    /// pick a refresh cadence — not for correctness.
    private var marketProbablyOpen: Bool {
        var cal = Calendar(identifier: .gregorian)
        guard let et = TimeZone(identifier: "America/New_York") else { return true }
        cal.timeZone = et
        let now = Date()
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else { return true }
        if weekday == 1 || weekday == 7 { return false } // Sun/Sat
        let minutes = hour * 60 + minute
        return minutes >= (9 * 60 + 30) && minutes <= (16 * 60)
    }
}

// MARK: - Popover UI

private struct StocksPopover: View {
    let plugin: StocksPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if plugin.quotes.isEmpty {
                Text("No quotes yet…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugin.quotes) { quote in
                    HStack(spacing: 10) {
                        Text(quote.symbol)
                            .font(.body.weight(.semibold))
                            .frame(width: 64, alignment: .leading)

                        Sparkline(values: quote.series, up: quote.isUp)
                            .frame(width: 70, height: 24)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.2f", quote.price))
                                .font(.body.monospacedDigit())
                            Text(String(format: "%@%.2f%%", quote.isUp ? "+" : "−", abs(quote.changePercent)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(quote.isUp ? .green : .red)
                        }
                    }
                }
            }
        }
    }
}

/// A minimal filled line chart for an intraday series.
private struct Sparkline: View {
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

private struct StocksSettings: View {
    @Bindable var plugin: StocksPlugin
    @State private var symbolsText: String = ""
    @State private var finnhubKey: String = ""
    @State private var savedNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watchlist")
                .font(.headline)
            Text("Comma-separated ticker symbols.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("AAPL, MSFT, NVDA", text: $symbolsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Save watchlist") {
                plugin.symbols = symbolsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty }
                Task { await plugin.refresh() }
            }

            Divider()

            Text("Finnhub API key (optional)")
                .font(.headline)
            Text("Provide a key for more reliable quotes. Stored in your Keychain. Leave blank to use the keyless Yahoo source.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Finnhub API key", text: $finnhubKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save key") {
                    CredentialStore.set(finnhubKey.isEmpty ? nil : finnhubKey, for: "finnhub.apiKey")
                    savedNote = "Saved."
                    Task { await plugin.refresh() }
                }
                if let note = savedNote {
                    Text(note).font(.caption).foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            symbolsText = plugin.symbols.joined(separator: ", ")
            finnhubKey = CredentialStore.get("finnhub.apiKey") ?? ""
        }
    }
}
