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
            .font(GlanceStyle.mini)
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
                    .font(GlanceStyle.mini).foregroundStyle(.tertiary)
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
        GitHubEntry(date: Date(), counts: .preview, configured: true)
    }
    func snapshot(for configuration: GitHubConfigIntent, in context: Context) async -> GitHubEntry {
        let configured = !(configuration.token ?? "").isEmpty
        let counts = await GitHubFetcher.fetch(token: configuration.token, detailed: context.family != .systemSmall)
        return GitHubEntry(date: Date(), counts: counts, configured: configured)
    }
    func timeline(for configuration: GitHubConfigIntent, in context: Context) async -> Timeline<GitHubEntry> {
        let configured = !(configuration.token ?? "").isEmpty
        let counts = await GitHubFetcher.fetch(token: configuration.token, detailed: context.family != .systemSmall)
        let next = Calendar.current.date(byAdding: .minute, value: 20, to: Date()) ?? Date()
        return Timeline(entries: [GitHubEntry(date: Date(), counts: counts, configured: configured)], policy: .after(next))
    }
}

private extension WidgetGitHubCounts {
    /// Gallery/placeholder sample: the widget can't hit the API there, and an
    /// empty shell would misrepresent what the layouts actually show.
    static var preview: WidgetGitHubCounts {
        WidgetGitHubCounts(
            unread: 3,
            openPRs: 2,
            login: "octocat",
            notifications: [
                WidgetGitHubNotification(id: "1", title: "Review requested: caching layer", repo: "acme/api"),
                WidgetGitHubNotification(id: "2", title: "CI failed on main", repo: "acme/web"),
                WidgetGitHubNotification(id: "3", title: "New comment on #412", repo: "acme/docs"),
            ],
            pullRequests: [
                WidgetGitHubPullRequest(id: 1, number: 128, title: "Add widget timeline refresh", repo: "acme/web", ciState: "success"),
                WidgetGitHubPullRequest(id: 2, number: 131, title: "Fix token keychain migration", repo: "acme/api", ciState: "pending"),
            ],
            contributions: WidgetGitHubContributions(
                total: 1_284,
                weeks: (0..<53).map { week in (0..<7).map { day in (week * 7 + day) % 5 } }
            )
        )
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
        .description("Notifications, open PRs, and your contribution graph. Edit the widget to add a token.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct GitHubWidgetView: View {
    let entry: GitHubEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                if family != .systemSmall, let login = entry.counts?.login {
                    Spacer()
                    Text("@\(login)")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if let counts = entry.counts {
                switch family {
                case .systemSmall: small(counts)
                case .systemMedium: medium(counts)
                default: large(counts)
                }
            } else {
                Spacer(minLength: 0)
                if entry.configured {
                    Text("Couldn't load — check token").font(.caption).foregroundStyle(GlanceStyle.warning)
                } else {
                    Text("Edit widget to add a GitHub token").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            UpdatedFooter(date: entry.date)
        }
    }

    // MARK: Small — the two counts only.

    @ViewBuilder
    private func small(_ counts: WidgetGitHubCounts) -> some View {
        Spacer(minLength: 0)
        HStack(spacing: 6) {
            Image(systemName: "bell.badge")
            Text("\(counts.unread)").font(.title2.weight(.semibold).monospacedDigit())
            Text("unread").font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull")
            Text("\(counts.openPRs)").font(.title2.weight(.semibold).monospacedDigit())
            Text("open PRs").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
    }

    // MARK: Medium — counts, heatmap, and the top PR.

    @ViewBuilder
    private func medium(_ counts: WidgetGitHubCounts) -> some View {
        GitHubCountsRow(counts: counts)
        if let contributions = counts.contributions {
            ContributionHeatmap(contributions: contributions, cell: 4)
        }
        Spacer(minLength: 0)
        if let pr = counts.pullRequests.first {
            GitHubPRRow(pr: pr)
        } else if let note = counts.notifications.first {
            GitHubNotificationRow(note: note)
        }
    }

    // MARK: Large — counts, heatmap, PRs, and notifications.

    @ViewBuilder
    private func large(_ counts: WidgetGitHubCounts) -> some View {
        GitHubCountsRow(counts: counts)
        if let contributions = counts.contributions {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(contributions.total) contributions in the last year")
                    .font(.caption.weight(.semibold))
                ContributionHeatmap(contributions: contributions, cell: 5)
            }
        }
        GitHubSection(title: "My PRs", isEmpty: counts.pullRequests.isEmpty, emptyText: "No open pull requests") {
            ForEach(counts.pullRequests) { GitHubPRRow(pr: $0) }
        }
        GitHubSection(title: "Notifications", isEmpty: counts.notifications.isEmpty, emptyText: "No unread notifications") {
            ForEach(counts.notifications.prefix(4)) { GitHubNotificationRow(note: $0) }
        }
        Spacer(minLength: 0)
    }
}

private struct GitHubCountsRow: View {
    let counts: WidgetGitHubCounts

    var body: some View {
        HStack(spacing: 14) {
            metric(icon: "bell.badge", value: counts.unread, label: "unread")
            metric(icon: "arrow.triangle.pull", value: counts.openPRs, label: "open PRs")
            Spacer(minLength: 0)
        }
    }

    private func metric(icon: String, value: Int, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text("\(value)").font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct GitHubSection<Content: View>: View {
    let title: String
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            if isEmpty {
                Text(emptyText).font(.caption2).foregroundStyle(.secondary)
            } else {
                content
            }
        }
    }
}

private struct GitHubPRRow: View {
    let pr: WidgetGitHubPullRequest

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ciColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(pr.title).font(.caption).lineLimit(1)
                Text("\(pr.repo) #\(pr.number)").font(GlanceStyle.mini).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // Matches GitHubPlugin.ciColor.
    private var ciColor: Color {
        switch pr.ciState {
        case "success": return .green
        case "pending": return .yellow
        case "failure", "error": return .red
        default: return .gray
        }
    }
}

private struct GitHubNotificationRow: View {
    let note: WidgetGitHubNotification

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.blue).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(note.title).font(.caption).lineLimit(1)
                Text(note.repo).font(GlanceStyle.mini).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// GitHub-style contribution heatmap: one column per week, one cell per day.
/// Mirrors the popover's heatmap, but sized for the wider widget column.
private struct ContributionHeatmap: View {
    let contributions: WidgetGitHubContributions
    let cell: CGFloat

    private let gap: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(contributions.weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color(for: week[weekday]))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    // Matches GitHubPlugin's ramp: absent/empty days are faint, then green.
    private func color(for count: Int?) -> Color {
        switch count {
        case .none, .some(0): return .gray.opacity(0.15)
        case .some(1...2): return .green.opacity(0.4)
        case .some(3...5): return .green.opacity(0.6)
        case .some(6...9): return .green.opacity(0.8)
        default: return .green
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
                batteryTimeRemainingMinutes: 184,
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
            SystemMetricRow(icon: "internaldrive", label: "Disk", value: entry.stats.diskFree.map { String(format: "%.1f GB free", Double($0) / 1_073_741_824) } ?? "—")
            if family == .systemMedium {
                SystemMetricRow(icon: "arrow.up.arrow.down.circle", label: "Network", value: networkText)
                SystemMetricRow(icon: "lock.shield", label: "VPN", value: entry.stats.vpnActive.map { $0 ? "Connected" : "Off" } ?? "—")
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
        var text = "\(percent)%"
        if entry.stats.isCharging { text += " ⚡" }
        if let minutes = entry.stats.batteryTimeRemainingMinutes {
            text += " (\(minutes / 60)h\(minutes % 60)m)"
        }
        return text
    }

    private var networkText: String {
        guard let down = entry.stats.downloadRate, let up = entry.stats.uploadRate else { return "—" }
        return "↓\(formatRate(down)) ↑\(formatRate(up))"
    }

    // Matches SystemStatsPlugin.formatBytes: "%.1fG" (no space, single "G").
    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1fG", Double(bytes) / 1_073_741_824)
    }

    // Matches SystemStatsPlugin.formatRate: no space before the unit.
    private func formatRate(_ bytes: Double) -> String {
        let kilobytes = bytes / 1024
        return kilobytes < 1024 ? String(format: "%.0fKB/s", kilobytes) : String(format: "%.1fMB/s", kilobytes / 1024)
    }

    // Matches SystemStatsPlugin.formatUptime: "Xd Yh" / "Xh Ym" / "Xm".
    private func formatUptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
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
                Text(entry.result.error ?? "No value").font(.caption).foregroundStyle(GlanceStyle.warning).lineLimit(3)
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
                        Text(normalizedHex(hex)).font(GlanceStyle.mini.monospaced()).lineLimit(1).minimumScaleFactor(0.7)
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
                        .font(GlanceStyle.hero(family == .systemSmall ? 40 : 46))
                    if let current = entry.weather.forecast.first {
                        Image(systemName: current.symbolName).font(.title2).symbolRenderingMode(.multicolor)
                    }
                }
            } else {
                Text(entry.weather.error ?? "No weather data").font(.caption).foregroundStyle(GlanceStyle.warning).lineLimit(2)
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
