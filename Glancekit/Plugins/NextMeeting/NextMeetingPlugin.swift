import SwiftUI
import Observation
import EventKit
import AppKit

/// A rich, standalone calendar glance focused on your *next meeting*: a live
/// countdown ring, a one-click Join for detected meeting links, optional
/// auto-open of the link just before start, and today's remaining agenda.
///
/// This is a separate glance from Time & Productivity's single "Next Event"
/// row — it owns its own EventKit feed (`NextMeetingFeed`) and never imports
/// another plugin. All EventKit access is best-effort: denied/undetermined
/// authorization never crashes `refresh()`, it just surfaces a grant prompt
/// via `requiredPermissions` (see `PLUGIN_CONTRACT.md` rule 4).
@MainActor
@Observable
final class NextMeetingPlugin: GlancePlugin {
    nonisolated var id: String { "nextmeeting" }
    nonisolated var title: String { "Next Meeting" }
    nonisolated var iconSystemName: String { "calendar.badge.clock" }
    var refreshInterval: TimeInterval { 60 }

    // MARK: Persisted settings

    /// Show the prominent "Join" button when the next event has a meeting link.
    var meetingJoinEnabled: Bool {
        didSet { UserDefaults.standard.set(meetingJoinEnabled, forKey: Keys.meetingJoinEnabled) }
    }
    /// Auto-open the next meeting's link shortly before it starts.
    var autoOpenEnabled: Bool {
        didSet { UserDefaults.standard.set(autoOpenEnabled, forKey: Keys.autoOpenEnabled) }
    }
    /// How many minutes before start to auto-open the link.
    var autoOpenMinutes: Int {
        didSet { UserDefaults.standard.set(autoOpenMinutes, forKey: Keys.autoOpenMinutes) }
    }
    /// How many upcoming events to list beyond today.
    var upcomingCount: Int {
        didSet { UserDefaults.standard.set(upcomingCount, forKey: Keys.upcomingCount) }
    }

    // MARK: Live state

    private(set) var todayAgenda: [NextMeetingEvent] = []
    private(set) var upcoming: [NextMeetingEvent] = []
    private(set) var lastError: String?

    /// The next event that hasn't started yet (soonest first). Drives the ring.
    var nextEvent: NextMeetingEvent? {
        upcoming.first
    }

    private let feed = NextMeetingFeed()
    /// Event ids we've already auto-opened this session, so we don't reopen.
    private var autoOpenedIDs: Set<String> = []

    private enum Keys {
        static let meetingJoinEnabled = "glancekit.nextmeeting.meetingJoin"
        static let autoOpenEnabled = "glancekit.nextmeeting.autoOpen"
        static let autoOpenMinutes = "glancekit.nextmeeting.autoOpenMinutes"
        static let upcomingCount = "glancekit.nextmeeting.upcomingCount"
    }

    init() {
        let defaults = UserDefaults.standard
        meetingJoinEnabled = defaults.object(forKey: Keys.meetingJoinEnabled) as? Bool ?? true
        autoOpenEnabled = defaults.object(forKey: Keys.autoOpenEnabled) as? Bool ?? false
        autoOpenMinutes = defaults.object(forKey: Keys.autoOpenMinutes) as? Int ?? 1
        upcomingCount = defaults.object(forKey: Keys.upcomingCount) as? Int ?? 5
    }

    // MARK: GlancePlugin

    func refresh() async {
        lastError = nil
        guard feed.authState == .authorized else {
            todayAgenda = []
            upcoming = []
            return
        }
        todayAgenda = feed.loadTodayAgenda()
        upcoming = feed.loadUpcoming(limit: max(1, upcomingCount))
        maybeAutoOpen()
    }

    /// Best-effort: if enabled and the next event with a meeting link is within
    /// the configured window and hasn't been opened yet, open it once.
    private func maybeAutoOpen() {
        guard autoOpenEnabled else { return }
        guard let event = nextEvent,
              let url = event.meetingURL,
              !autoOpenedIDs.contains(event.id) else { return }
        let minutesUntil = event.startDate.timeIntervalSinceNow / 60
        // Only open when we're inside the window and the meeting hasn't passed.
        guard minutesUntil <= Double(autoOpenMinutes), minutesUntil > -1 else { return }
        autoOpenedIDs.insert(event.id)
        NSWorkspace.shared.open(url)
    }

    func requestCalendarAccess() async {
        _ = await feed.requestCalendarAccess()
        await refresh()
    }

    var calendarAuthorized: Bool { feed.authState == .authorized }

    /// Calendar is the only permission. Returns an ungranted `GlancePermission`
    /// when not yet authorized; `[]` once granted (the popover chrome renders
    /// the grant prompt — we don't render our own gate).
    var requiredPermissions: [GlancePermission] {
        guard feed.authState != .authorized else { return [] }
        return [GlancePermission(
            id: "nextmeeting.calendar",
            title: "Calendar",
            iconSystemName: "calendar",
            rationale: "Show your next meeting and today's agenda.",
            status: { Self.eventKitStatus(EKEventStore.authorizationStatus(for: .event)) },
            request: { [weak self] in await self?.requestCalendarAccess() },
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        )]
    }

    private static func eventKitStatus(_ status: EKAuthorizationStatus) -> GlancePermission.Status {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Surfaces the next meeting as it approaches: urgent inside 15 minutes,
    /// elevated inside an hour, ambient further out. Nil once it's well
    /// underway (>5 min in) or when nothing is upcoming.
    func currentSignal() -> GlanceSignal? {
        guard let event = nextEvent else { return nil }
        let minutes = event.startDate.timeIntervalSinceNow / 60
        guard minutes > -5 else { return nil }

        let priority: GlanceSignal.Priority
        if minutes <= 15 { priority = .urgent }
        else if minutes <= 60 { priority = .elevated }
        else { priority = .ambient }

        let tint: Color = priority == .urgent ? .orange : .accentColor
        var join: GlanceSignal.QuickAction?
        if meetingJoinEnabled, minutes <= 60, let url = event.meetingURL {
            join = GlanceSignal.QuickAction(title: "Join", systemImage: "video") {
                NSWorkspace.shared.open(url)
            }
        }
        return GlanceSignal(
            priority: priority,
            score: max(0, 1440 - minutes),
            headline: "\(event.title) · \(Self.relativeShort(event.startDate))",
            systemImage: "calendar.badge.clock",
            tint: tint,
            quickAction: join
        )
    }

    func popoverSection() -> AnyView {
        AnyView(NextMeetingPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(NextMeetingSettings(plugin: self))
    }

    // MARK: Helpers

    static func relativeShort(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "in \(seconds / 3600)h" }
        return "in \(seconds / 86_400)d"
    }

    static func timeRange(_ event: NextMeetingEvent) -> String {
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}

// MARK: - Popover UI

private struct NextMeetingPopover: View {
    let plugin: NextMeetingPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            NextMeetingNextCard(plugin: plugin)

            NextMeetingAgendaSection(
                title: "Today",
                events: plugin.todayAgenda,
                emptyText: "No more events today.",
                showJoin: plugin.meetingJoinEnabled
            )

            if plugin.upcomingCount > 0 {
                NextMeetingAgendaSection(
                    title: "Upcoming",
                    events: plugin.upcoming,
                    emptyText: "No upcoming events.",
                    showJoin: plugin.meetingJoinEnabled
                )
            }
        }
        .task { await plugin.refresh() }
    }
}

/// The hero card: countdown ring + title + Join for the next event.
private struct NextMeetingNextCard: View {
    let plugin: NextMeetingPlugin
    /// Ticks once a second so the ring and "in Nm" stay live.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The ring represents the last hour before start.
    private let windowSeconds: Double = 3600

    var body: some View {
        Group {
            if let event = plugin.nextEvent {
                HStack(alignment: .center, spacing: 14) {
                    ring(for: event)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.headline)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(event.calendarColor.swiftUIColor)
                                .frame(width: 8, height: 8)
                            Text(event.calendarTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(NextMeetingPlugin.timeRange(event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if plugin.meetingJoinEnabled, let url = event.meetingURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Join", systemImage: "video")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            } else {
                Label("No upcoming meetings.", systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
        .onReceive(ticker) { now = $0 }
    }

    @ViewBuilder
    private func ring(for event: NextMeetingEvent) -> some View {
        let remaining = max(0, event.startDate.timeIntervalSince(now))
        // Fills as the meeting approaches: 0 at (start - window), 1 at start.
        let progress = min(1, max(0, (windowSeconds - remaining) / windowSeconds))
        let urgent = remaining <= 15 * 60
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    urgent ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
            VStack(spacing: 0) {
                Text(centerText(remaining: remaining))
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(width: 60, height: 60)
    }

    private func centerText(remaining: Double) -> String {
        if remaining <= 0 { return "now" }
        let mins = Int(remaining) / 60
        if mins < 60 { return "in \(max(1, mins))m" }
        let hours = mins / 60
        if hours < 24 { return "in \(hours)h" }
        return "in \(hours / 24)d"
    }
}

private struct NextMeetingAgendaSection: View {
    let title: String
    let events: [NextMeetingEvent]
    let emptyText: String
    let showJoin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if events.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(events) { event in
                        NextMeetingRow(event: event, showJoin: showJoin)
                    }
                }
            }
        }
    }
}

private struct NextMeetingRow: View {
    let event: NextMeetingEvent
    let showJoin: Bool

    var body: some View {
        let meetingURL = showJoin ? event.meetingURL : nil
        HStack(spacing: 8) {
            Circle()
                .fill(event.calendarColor.swiftUIColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.body)
                    .lineLimit(1)
                Text(NextMeetingPlugin.timeRange(event))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let url = meetingURL {
                Image(systemName: "video.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .help("Join meeting")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = meetingURL {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Settings UI

private struct NextMeetingSettings: View {
    @Bindable var plugin: NextMeetingPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join").font(.headline)
            Toggle("Show meeting Join button", isOn: $plugin.meetingJoinEnabled)

            Divider()

            Text("Auto-open").font(.headline)
            Toggle("Auto-open meeting link before start", isOn: $plugin.autoOpenEnabled)
            Stepper(
                "Open \(plugin.autoOpenMinutes) minute\(plugin.autoOpenMinutes == 1 ? "" : "s") before start",
                value: $plugin.autoOpenMinutes,
                in: 0...30
            )
            .disabled(!plugin.autoOpenEnabled)
            Text("Best-effort: opens the next meeting's link once when it comes within range.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Upcoming").font(.headline)
            Stepper(
                "Show \(plugin.upcomingCount) upcoming event\(plugin.upcomingCount == 1 ? "" : "s")",
                value: $plugin.upcomingCount,
                in: 0...10
            )

            Divider()

            Text("Access").font(.headline)
            Button("Grant Calendar access") {
                Task { await plugin.requestCalendarAccess() }
            }
        }
    }
}
