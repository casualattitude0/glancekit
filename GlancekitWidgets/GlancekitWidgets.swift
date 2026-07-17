import WidgetKit
import SwiftUI
import AppIntents
import AppKit

// MARK: - Widget bundle entry point

@main
struct GlancekitWidgetBundle: WidgetBundle {
    var body: some Widget {
        StocksWidget()
        NextEventWidget()
        GitHubWidget()
        SystemStatsWidget()
        PhotosWidget()
        CustomAPIWidget()
        ColorPickerWidget()
        ColorPaletteWidget()
        WeatherWidget()
    }
}

private struct UpdatedFooter: View {
    let date: Date
    var body: some View {
        Text("as of \(date, style: .time)")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Stocks (configurable: symbols)

struct StocksConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Stocks"
    static var description = IntentDescription("Choose which ticker symbols to display.")

    @Parameter(title: "Symbols (comma-separated)", default: "AAPL,MSFT,NVDA")
    var symbols: String
}

struct StocksEntry: TimelineEntry {
    let date: Date
    let quotes: [WidgetStockQuote]
}

struct StocksProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StocksEntry {
        StocksEntry(date: Date(), quotes: [WidgetStockQuote(symbol: "AAPL", price: 227.5, changePercent: 0.82)])
    }
    func snapshot(for configuration: StocksConfigIntent, in context: Context) async -> StocksEntry {
        let quotes = await StockFetcher.fetch(symbols: StockFetcher.parseSymbols(configuration.symbols))
        return StocksEntry(date: Date(), quotes: quotes)
    }
    func timeline(for configuration: StocksConfigIntent, in context: Context) async -> Timeline<StocksEntry> {
        let quotes = await StockFetcher.fetch(symbols: StockFetcher.parseSymbols(configuration.symbols))
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        return Timeline(entries: [StocksEntry(date: Date(), quotes: quotes)], policy: .after(next))
    }
}

struct StocksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.glancekit.widget.stocks",
                               intent: StocksConfigIntent.self,
                               provider: StocksProvider()) { entry in
            StocksWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Stocks")
        .description("Your watchlist at a glance. Edit the widget to set symbols.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct StocksWidgetView: View {
    let entry: StocksEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Stocks", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if entry.quotes.isEmpty {
                Spacer(); Text("No data").font(.callout).foregroundStyle(.secondary); Spacer()
            } else {
                ForEach(entry.quotes.prefix(family == .systemSmall ? 3 : 6)) { q in
                    HStack {
                        Text(q.symbol).font(.callout.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2f", q.price)).font(.callout.monospacedDigit())
                        Text(String(format: "%@%.2f%%", q.isUp ? "+" : "−", abs(q.changePercent)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(q.isUp ? .green : .red)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Spacer(minLength: 0)
            }
            UpdatedFooter(date: entry.date)
        }
    }
}

// MARK: - Next event (static, reads EventKit)

struct NextEventEntry: TimelineEntry {
    let date: Date
    let event: WidgetEvent?
}

struct NextEventProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEventEntry {
        NextEventEntry(date: Date(), event: WidgetEvent(title: "Standup", date: Date().addingTimeInterval(720)))
    }
    func getSnapshot(in context: Context, completion: @escaping (NextEventEntry) -> Void) {
        completion(NextEventEntry(date: Date(), event: EventFetcher.nextEvent()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEventEntry>) -> Void) {
        let entry = NextEventEntry(date: Date(), event: EventFetcher.nextEvent())
        let next = Calendar.current.date(byAdding: .minute, value: 10, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct NextEventWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.glancekit.widget.nextevent", provider: NextEventProvider()) { entry in
            NextEventWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Time & Productivity")
        .description("Your next calendar event from Time & Productivity.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NextEventWidgetView: View {
    let entry: NextEventEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next Event", systemImage: "calendar")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let e = entry.event {
                Text(e.title).font(.headline).lineLimit(2)
                Text(e.date, style: .relative).font(.subheadline).foregroundStyle(.blue)
                Text(e.date, format: .dateTime.weekday().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No upcoming events").font(.callout).foregroundStyle(.secondary)
                Text("(grant Calendar access in Glancekit)")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            UpdatedFooter(date: entry.date)
        }
    }
}

// MARK: - GitHub (configurable: token)

struct GitHubConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "GitHub"
    static var description = IntentDescription("Paste a fine-grained GitHub token to show your counts.")

    @Parameter(title: "GitHub token")
    var token: String?
}

struct GitHubEntry: TimelineEntry {
    let date: Date
    let counts: WidgetGitHubCounts?
    let configured: Bool
}

struct GitHubProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GitHubEntry {
        GitHubEntry(date: Date(), counts: WidgetGitHubCounts(unread: 3, openPRs: 2), configured: true)
    }
    func snapshot(for configuration: GitHubConfigIntent, in context: Context) async -> GitHubEntry {
        let configured = !(configuration.token ?? "").isEmpty
        return GitHubEntry(date: Date(), counts: await GitHubFetcher.fetch(token: configuration.token), configured: configured)
    }
    func timeline(for configuration: GitHubConfigIntent, in context: Context) async -> Timeline<GitHubEntry> {
        let configured = !(configuration.token ?? "").isEmpty
        let counts = await GitHubFetcher.fetch(token: configuration.token)
        let next = Calendar.current.date(byAdding: .minute, value: 20, to: Date()) ?? Date()
        return Timeline(entries: [GitHubEntry(date: Date(), counts: counts, configured: configured)], policy: .after(next))
    }
}

struct GitHubWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.glancekit.widget.github",
                               intent: GitHubConfigIntent.self,
                               provider: GitHubProvider()) { entry in
            GitHubWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("GitHub")
        .description("Unread notifications and open PRs. Edit the widget to add a token.")
        .supportedFamilies([.systemSmall])
    }
}

private struct GitHubWidgetView: View {
    let entry: GitHubEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let g = entry.counts {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge")
                    Text("\(g.unread)").font(.title2.weight(.semibold).monospacedDigit())
                    Text("unread").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull")
                    Text("\(g.openPRs)").font(.title2.weight(.semibold).monospacedDigit())
                    Text("open PRs").font(.caption).foregroundStyle(.secondary)
                }
            } else if !entry.configured {
                Text("Edit widget to add a GitHub token").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Couldn't load — check token").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            UpdatedFooter(date: entry.date)
        }
    }
}

// MARK: - Mac Health

struct SystemStatsEntry: TimelineEntry {
    let date: Date
    let stats: WidgetSystemStats
}

struct SystemStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SystemStatsEntry {
        SystemStatsEntry(
            date: Date(),
            stats: WidgetSystemStats(
                cpuPercent: 24,
                usedMemory: 12_884_901_888,
                totalMemory: 17_179_869_184,
                batteryPercent: 82,
                isCharging: false,
                diskFree: 245_672_468_480,
                downloadRate: 312_000,
                uploadRate: 54_000,
                vpnActive: false,
                uptime: 93_600
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemStatsEntry) -> Void) {
        Task { completion(SystemStatsEntry(date: Date(), stats: await SystemStatsFetcher.fetch())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemStatsEntry>) -> Void) {
        Task {
            let entry = SystemStatsEntry(date: Date(), stats: await SystemStatsFetcher.fetch())
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct SystemStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.glancekit.widget.system", provider: SystemStatsProvider()) { entry in
            SystemStatsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac Health")
        .description("CPU, memory, power, disk, network, VPN, and uptime at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SystemStatsWidgetView: View {
    let entry: SystemStatsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Mac Health", systemImage: "cpu")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            SystemMetricRow(icon: "cpu", label: "CPU", value: entry.stats.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
            SystemMetricRow(icon: "memorychip", label: "RAM", value: memoryText)
            SystemMetricRow(icon: "battery.100", label: "Battery", value: batteryText)
            SystemMetricRow(icon: "internaldrive", label: "Disk", value: entry.stats.diskFree.map { "\(formatBytes($0)) free" } ?? "—")
            if family == .systemMedium {
                SystemMetricRow(icon: "arrow.up.arrow.down.circle", label: "Network", value: networkText)
                SystemMetricRow(icon: "lock.shield", label: "VPN", value: entry.stats.vpnActive.map { $0 ? "On" : "Off" } ?? "—")
                SystemMetricRow(icon: "clock.arrow.circlepath", label: "Uptime", value: formatUptime(entry.stats.uptime))
            }
            Spacer(minLength: 0)
            UpdatedFooter(date: entry.date)
        }
    }

    private var memoryText: String {
        guard let used = entry.stats.usedMemory, let total = entry.stats.totalMemory else { return "—" }
        return "\(formatBytes(Int64(used))) / \(formatBytes(Int64(total)))"
    }

    private var batteryText: String {
        guard let percent = entry.stats.batteryPercent else { return "—" }
        return "\(percent)%\(entry.stats.isCharging ? " charging" : "")"
    }

    private var networkText: String {
        guard let down = entry.stats.downloadRate, let up = entry.stats.uploadRate else { return "—" }
        return "↓\(formatRate(down)) ↑\(formatRate(up))"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private func formatRate(_ bytes: Double) -> String {
        let kilobytes = bytes / 1024
        return kilobytes < 1024 ? String(format: "%.0f KB/s", kilobytes) : String(format: "%.1f MB/s", kilobytes / 1024)
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / (24 * 60)
        let hours = (minutes / 60) % 24
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes % 60)m"
    }
}

private struct SystemMetricRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).frame(width: 15).foregroundStyle(.secondary)
            Text(label).font(.caption)
            Spacer(minLength: 3)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Photos

struct PhotosEntry: TimelineEntry {
    let date: Date
    let photo: WidgetPhoto
}

struct PhotosProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhotosEntry {
        PhotosEntry(date: Date(), photo: WidgetPhoto(imageData: nil, caption: "Today", isAuthorized: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (PhotosEntry) -> Void) {
        completion(PhotosEntry(date: Date(), photo: PhotoFetcher.latestPhoto()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhotosEntry>) -> Void) {
        let entry = PhotosEntry(date: Date(), photo: PhotoFetcher.latestPhoto())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct PhotosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.glancekit.widget.photos", provider: PhotosProvider()) { entry in
            PhotosWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Photos")
        .description("Your newest photo from the Photos library.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct PhotosWidgetView: View {
    let entry: PhotosEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let data = entry.photo.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Rectangle().fill(.quaternary)
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2)
                    Text(entry.photo.isAuthorized ? "No photos found" : "Grant Photos access")
                        .font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }

            HStack {
                Label("Photos", systemImage: "photo.on.rectangle")
                Spacer()
                if let caption = entry.photo.caption { Text(caption) }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(8)
        }
    }
}

// MARK: - Custom API

struct CustomAPIConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Custom API"
    static var description = IntentDescription("Configure a REST/JSON endpoint and the value to display.")

    @Parameter(title: "Label", default: "Custom API")
    var label: String

    @Parameter(title: "URL")
    var url: String?

    @Parameter(title: "JSON path", default: "")
    var jsonPath: String

    @Parameter(title: "Headers (one per line: Key: Value)", default: "")
    var headers: String
}

struct CustomAPIEntry: TimelineEntry {
    let date: Date
    let result: WidgetCustomAPIResult
}

struct CustomAPIProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CustomAPIEntry {
        CustomAPIEntry(date: Date(), result: WidgetCustomAPIResult(label: "Bitcoin", value: "104,234", error: nil))
    }

    func snapshot(for configuration: CustomAPIConfigIntent, in context: Context) async -> CustomAPIEntry {
        CustomAPIEntry(date: Date(), result: await load(configuration))
    }

    func timeline(for configuration: CustomAPIConfigIntent, in context: Context) async -> Timeline<CustomAPIEntry> {
        let entry = CustomAPIEntry(date: Date(), result: await load(configuration))
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func load(_ configuration: CustomAPIConfigIntent) async -> WidgetCustomAPIResult {
        await CustomAPIFetcher.fetch(
            label: configuration.label,
            urlString: configuration.url ?? "",
            jsonPath: configuration.jsonPath,
            headersText: configuration.headers
        )
    }
}

struct CustomAPIWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.glancekit.widget.customapi", intent: CustomAPIConfigIntent.self, provider: CustomAPIProvider()) { entry in
            CustomAPIWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Custom API")
        .description("Display a value from any REST/JSON endpoint.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct CustomAPIWidgetView: View {
    let entry: CustomAPIEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.result.label, systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let value = entry.result.value {
                Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(2).minimumScaleFactor(0.65)
            } else {
                Text(entry.result.error ?? "No value").font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Spacer(minLength: 0)
            UpdatedFooter(date: entry.date)
        }
    }
}

// MARK: - Color Picker

struct ColorPickerConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Color Picker"
    static var description = IntentDescription("Show a color selected in Glancekit.")

    @Parameter(title: "Current hex color", default: "#0091FF")
    var hex: String
}

struct ColorPickerEntry: TimelineEntry {
    let date: Date
    let hex: String
}

struct ColorPickerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ColorPickerEntry { ColorPickerEntry(date: Date(), hex: "#0091FF") }

    func snapshot(for configuration: ColorPickerConfigIntent, in context: Context) async -> ColorPickerEntry {
        ColorPickerEntry(date: Date(), hex: configuration.hex)
    }

    func timeline(for configuration: ColorPickerConfigIntent, in context: Context) async -> Timeline<ColorPickerEntry> {
        let entry = ColorPickerEntry(date: Date(), hex: configuration.hex)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct ColorPickerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.glancekit.widget.colorpicker", intent: ColorPickerConfigIntent.self, provider: ColorPickerProvider()) { entry in
            ColorPickerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Color Picker")
        .description("Keep a sampled color visible. Use Glancekit to sample a screen color.")
        .supportedFamilies([.systemSmall])
    }
}

private struct ColorPickerWidgetView: View {
    let entry: ColorPickerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Color Picker", systemImage: "eyedropper")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 12)
                .fill(color(for: entry.hex))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            Text(normalizedHex(entry.hex))
                .font(.headline.monospaced().weight(.semibold))
            Text("Sample colors in Glancekit")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Color Palette

struct ColorPaletteConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Color Palette"
    static var description = IntentDescription("Choose the colors to keep in your desktop palette.")

    @Parameter(title: "Primary color", default: "#0091FF")
    var primary: String

    @Parameter(title: "Accent color", default: "#FF2D55")
    var accent: String

    @Parameter(title: "Neutral color", default: "#8E8E93")
    var neutral: String
}

struct ColorPaletteEntry: TimelineEntry {
    let date: Date
    let colors: [String]
}

struct ColorPaletteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ColorPaletteEntry {
        ColorPaletteEntry(date: Date(), colors: ["#0091FF", "#FF2D55", "#8E8E93"])
    }

    func snapshot(for configuration: ColorPaletteConfigIntent, in context: Context) async -> ColorPaletteEntry {
        ColorPaletteEntry(date: Date(), colors: [configuration.primary, configuration.accent, configuration.neutral])
    }

    func timeline(for configuration: ColorPaletteConfigIntent, in context: Context) async -> Timeline<ColorPaletteEntry> {
        let entry = ColorPaletteEntry(date: Date(), colors: [configuration.primary, configuration.accent, configuration.neutral])
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct ColorPaletteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.glancekit.widget.colorpalette", intent: ColorPaletteConfigIntent.self, provider: ColorPaletteProvider()) { entry in
            ColorPaletteWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Color Palette")
        .description("A compact palette for the colors you use most.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ColorPaletteWidgetView: View {
    let entry: ColorPaletteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Color Palette", systemImage: "paintpalette")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(entry.colors, id: \.self) { hex in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(color(for: hex))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        Text(normalizedHex(hex)).font(.system(size: 9, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
            Text("Edit colors in the widget or Glancekit")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private func normalizedHex(_ raw: String) -> String {
    let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let digits = stripped.hasPrefix("#") ? String(stripped.dropFirst()) : stripped
    guard digits.count == 6, UInt64(digits, radix: 16) != nil else { return "#0091FF" }
    return "#\(digits)"
}

private func color(for hex: String) -> Color {
    let digits = String(normalizedHex(hex).dropFirst())
    let value = UInt64(digits, radix: 16) ?? 0x0091FF
    return Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255,
        opacity: 1
    )
}

// MARK: - Weather

struct WeatherConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Weather"
    static var description = IntentDescription("Set the latitude and longitude for your weather forecast.")

    @Parameter(title: "Latitude", default: "37.77")
    var latitude: String

    @Parameter(title: "Longitude", default: "-122.42")
    var longitude: String
}

struct WeatherEntry: TimelineEntry {
    let date: Date
    let weather: WidgetWeather
}

struct WeatherProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(
            date: Date(),
            weather: WidgetWeather(
                temperature: 72,
                forecast: [
                    WidgetWeatherDay(date: "2026-07-17", high: 74, low: 58, code: 1),
                    WidgetWeatherDay(date: "2026-07-18", high: 77, low: 59, code: 0),
                    WidgetWeatherDay(date: "2026-07-19", high: 70, low: 57, code: 61),
                ],
                error: nil
            )
        )
    }

    func snapshot(for configuration: WeatherConfigIntent, in context: Context) async -> WeatherEntry {
        WeatherEntry(date: Date(), weather: await WeatherFetcher.fetch(latitude: configuration.latitude, longitude: configuration.longitude))
    }

    func timeline(for configuration: WeatherConfigIntent, in context: Context) async -> Timeline<WeatherEntry> {
        let entry = WeatherEntry(date: Date(), weather: await WeatherFetcher.fetch(latitude: configuration.latitude, longitude: configuration.longitude))
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct WeatherWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.glancekit.widget.weather", intent: WeatherConfigIntent.self, provider: WeatherProvider()) { entry in
            WeatherWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Weather")
        .description("Current weather and a three-day forecast.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct WeatherWidgetView: View {
    let entry: WeatherEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Weather", systemImage: "cloud.sun")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let temperature = entry.weather.temperature {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(temperature.rounded()))°")
                        .font(.system(size: family == .systemSmall ? 40 : 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let current = entry.weather.forecast.first {
                        Image(systemName: current.symbolName).font(.title2).symbolRenderingMode(.multicolor)
                    }
                }
            } else {
                Text(entry.weather.error ?? "No weather data").font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            if !entry.weather.forecast.isEmpty {
                ForEach(Array(entry.weather.forecast.prefix(family == .systemSmall ? 2 : 3))) { day in
                    HStack {
                        Text(day.weekday).frame(width: 34, alignment: .leading)
                        Image(systemName: day.symbolName).frame(width: 20).symbolRenderingMode(.multicolor)
                        Spacer()
                        Text("\(Int(day.high.rounded()))°").monospacedDigit()
                        Text("\(Int(day.low.rounded()))°").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
            UpdatedFooter(date: entry.date)
        }
    }
}
