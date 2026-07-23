import SwiftUI
import Observation
import EventKit
import AppKit

/// A rich, standalone calendar glance focused on your *next meeting*: a live
/// countdown ring, a one-click Join for detected meeting links, optional
/// auto-open of the link just before start, and today's remaining agenda.
///
/// It owns its own EventKit feed (`NextMeetingFeed`) and never imports another
/// plugin. All EventKit access is best-effort: denied/undetermined
/// authorization never crashes `refresh()`, it just surfaces a grant prompt
/// via `requiredPermissions` (see `docs/PLUGIN_CONTRACT.md` rule 4).
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
    /// How many days ahead the "upcoming" list reaches.
    var lookAheadDays: Int {
        didSet { UserDefaults.standard.set(lookAheadDays, forKey: Keys.lookAheadDays) }
    }
    /// Max number of today's events to show.
    var todayLimit: Int {
        didSet { UserDefaults.standard.set(todayLimit, forKey: Keys.todayLimit) }
    }
    /// Hide all-day events (holidays, birthdays, multi-day trips).
    var hideAllDay: Bool {
        didSet { UserDefaults.standard.set(hideAllDay, forKey: Keys.hideAllDay) }
    }
    /// Include events the current user has declined.
    var showDeclined: Bool {
        didSet { UserDefaults.standard.set(showDeclined, forKey: Keys.showDeclined) }
    }
    /// Selected calendar identifiers. `nil` means every calendar (the default);
    /// an empty set means the user has explicitly chosen none.
    var selectedCalendarIDs: Set<String>? {
        didSet {
            if let selectedCalendarIDs {
                UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: Keys.selectedCalendars)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedCalendars)
            }
        }
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
        static let lookAheadDays = "glancekit.nextmeeting.lookAheadDays"
        static let todayLimit = "glancekit.nextmeeting.todayLimit"
        static let hideAllDay = "glancekit.nextmeeting.hideAllDay"
        static let showDeclined = "glancekit.nextmeeting.showDeclined"
        static let selectedCalendars = "glancekit.nextmeeting.selectedCalendars"
    }

    init() {
        let defaults = UserDefaults.standard
        meetingJoinEnabled = defaults.object(forKey: Keys.meetingJoinEnabled) as? Bool ?? true
        autoOpenEnabled = defaults.object(forKey: Keys.autoOpenEnabled) as? Bool ?? false
        autoOpenMinutes = defaults.object(forKey: Keys.autoOpenMinutes) as? Int ?? 1
        upcomingCount = defaults.object(forKey: Keys.upcomingCount) as? Int ?? 5
        lookAheadDays = defaults.object(forKey: Keys.lookAheadDays) as? Int ?? 7
        todayLimit = defaults.object(forKey: Keys.todayLimit) as? Int ?? 10
        hideAllDay = defaults.object(forKey: Keys.hideAllDay) as? Bool ?? false
        showDeclined = defaults.object(forKey: Keys.showDeclined) as? Bool ?? false
        if let ids = defaults.object(forKey: Keys.selectedCalendars) as? [String] {
            selectedCalendarIDs = Set(ids)
        } else {
            selectedCalendarIDs = nil
        }
    }

    /// The filter shared by every query and the Smart Panel signal.
    private var queryOptions: NextMeetingQueryOptions {
        NextMeetingQueryOptions(
            calendarIDs: selectedCalendarIDs,
            hideAllDay: hideAllDay,
            showDeclined: showDeclined,
            lookAheadDays: lookAheadDays
        )
    }

    // MARK: GlancePlugin

    func refresh() async {
        lastError = nil
        guard feed.authState == .authorized else {
            todayAgenda = []
            upcoming = []
            return
        }
        let options = queryOptions
        todayAgenda = Array(feed.loadTodayAgenda(options: options).prefix(max(1, todayLimit)))
        upcoming = feed.loadUpcoming(limit: max(1, upcomingCount), options: options)
        maybeAutoOpen()
    }

    /// The calendars available for selection (empty until access is granted).
    func availableCalendars() -> [NextMeetingCalendar] {
        feed.availableCalendars()
    }

    /// Whether a calendar is currently included. `nil` selection = all included.
    func isCalendarSelected(_ id: String) -> Bool {
        guard let selectedCalendarIDs else { return true }
        return selectedCalendarIDs.contains(id)
    }

    /// Toggle a calendar in/out of the selection. Starting from the "all"
    /// default (`nil`), the first toggle expands to the concrete set so the
    /// change is explicit; a set covering every calendar collapses back to
    /// `nil` so newly-added calendars are still included by default.
    func setCalendar(_ id: String, included: Bool, allIDs: [String]) {
        var set = selectedCalendarIDs ?? Set(allIDs)
        if included { set.insert(id) } else { set.remove(id) }
        if set == Set(allIDs) {
            selectedCalendarIDs = nil
        } else {
            selectedCalendarIDs = set
        }
    }

    /// Reset to "all calendars".
    func selectAllCalendars() { selectedCalendarIDs = nil }

    /// Explicitly select no calendars.
    func selectNoCalendars() { selectedCalendarIDs = [] }

    /// True only when the user has explicitly deselected every calendar.
    var hasNoCalendarsSelected: Bool {
        if let selectedCalendarIDs { return selectedCalendarIDs.isEmpty }
        return false
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
        if event.isAllDay {
            // Show the day for all-day events; single-day ones read "All day".
            let cal = Calendar.current
            if cal.isDate(event.startDate, inSameDayAs: event.endDate)
                || event.endDate.timeIntervalSince(event.startDate) <= 86_400 {
                return "All day"
            }
            let start = event.startDate.formatted(date: .abbreviated, time: .omitted)
            let end = event.endDate.formatted(date: .abbreviated, time: .omitted)
            return "All day · \(start) – \(end)"
        }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    /// Copies a URL to the general pasteboard.
    static func copyLink(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }
}

// MARK: - Popover UI

private struct NextMeetingPopover: View {
    let plugin: NextMeetingPlugin
    /// The event whose detail sheet is open, if any.
    @State private var detailEvent: NextMeetingEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(GlanceStyle.warning)
            }

            if plugin.hasNoCalendarsSelected {
                NextMeetingEmptyState(
                    icon: "calendar.badge.exclamationmark",
                    text: "No calendars selected. Choose calendars in Settings."
                )
            } else {
                NextMeetingNextCard(plugin: plugin) { detailEvent = $0 }

                NextMeetingAgendaSection(
                    title: "Today",
                    events: plugin.todayAgenda,
                    emptyText: "No more events today.",
                    showJoin: plugin.meetingJoinEnabled,
                    onSelect: { detailEvent = $0 }
                )

                if plugin.upcomingCount > 0 {
                    NextMeetingAgendaSection(
                        title: "Upcoming",
                        events: plugin.upcoming,
                        emptyText: "No upcoming events.",
                        showJoin: plugin.meetingJoinEnabled,
                        onSelect: { detailEvent = $0 }
                    )
                }
            }
        }
        .task { await plugin.refresh() }
        .sheet(item: $detailEvent) { event in
            NextMeetingDetail(event: event, showJoin: plugin.meetingJoinEnabled) {
                detailEvent = nil
            }
        }
    }
}

private struct NextMeetingEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
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

/// The hero card: countdown ring + title + Join for the next event.
private struct NextMeetingNextCard: View {
    let plugin: NextMeetingPlugin
    let onSelect: (NextMeetingEvent) -> Void
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
                .contentShape(Rectangle())
                .onTapGesture { onSelect(event) }
            } else {
                NextMeetingEmptyState(icon: "calendar", text: "No upcoming meetings.")
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
                    urgent ? GlanceStyle.warning : Color.accentColor,
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
    let onSelect: (NextMeetingEvent) -> Void

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
                        NextMeetingRow(event: event, showJoin: showJoin, onSelect: onSelect)
                    }
                }
            }
        }
    }
}

private struct NextMeetingRow: View {
    let event: NextMeetingEvent
    let showJoin: Bool
    let onSelect: (NextMeetingEvent) -> Void

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
                    .strikethrough(event.isDeclined, color: .secondary)
                Text(NextMeetingPlugin.timeRange(event))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if meetingURL != nil {
                Button {
                    if let url = meetingURL { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Join meeting")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(event) }
    }
}

// MARK: - Detail UI

/// Full event detail: title, time range, calendar, location, notes, and every
/// detected link with open/copy buttons.
private struct NextMeetingDetail: View {
    let event: NextMeetingEvent
    let showJoin: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(event.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if event.isDeclined {
                Label("You declined this event", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            detailRow(icon: "clock", text: NextMeetingPlugin.timeRange(event))

            HStack(spacing: 8) {
                Circle()
                    .fill(event.calendarColor.swiftUIColor)
                    .frame(width: 10, height: 10)
                Text(event.calendarTitle)
                    .font(.callout)
            }

            if let location = event.location, !location.isEmpty {
                detailRow(icon: "mappin.and.ellipse", text: location)
            }

            if showJoin, let url = event.meetingURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Join meeting", systemImage: "video")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            let links = event.allLinks
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Links")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(links, id: \.absoluteString) { link in
                        NextMeetingLinkRow(url: link)
                    }
                }
            }

            if let notes = event.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

private struct NextMeetingLinkRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(url.absoluteString)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tint)
            Spacer(minLength: 4)
            Button {
                NextMeetingPlugin.copyLink(url)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy link")
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("Open link")
        }
    }
}

// MARK: - Settings UI

private struct NextMeetingSettings: View {
    @Bindable var plugin: NextMeetingPlugin

    var body: some View {
        SettingsPage("Join") {
            SettingsToggleRow("Show meeting Join button", isOn: $plugin.meetingJoinEnabled)

            Divider()

            SettingsSectionHeader("Auto-open")
            SettingsToggleRow("Auto-open meeting link before start", isOn: $plugin.autoOpenEnabled)
            Stepper(
                "Open \(plugin.autoOpenMinutes) minute\(plugin.autoOpenMinutes == 1 ? "" : "s") before start",
                value: $plugin.autoOpenMinutes,
                in: 0...30
            )
            .disabled(!plugin.autoOpenEnabled)
            SettingsHelp("Best-effort: opens the next meeting's link once when it comes within range.")

            Divider()

            SettingsSectionHeader("Agenda")
            Stepper(
                "Show up to \(plugin.todayLimit) event\(plugin.todayLimit == 1 ? "" : "s") today",
                value: $plugin.todayLimit,
                in: 1...20
            )
            Stepper(
                "Show \(plugin.upcomingCount) upcoming event\(plugin.upcomingCount == 1 ? "" : "s")",
                value: $plugin.upcomingCount,
                in: 0...10
            )
            Stepper(
                "Look ahead \(plugin.lookAheadDays) day\(plugin.lookAheadDays == 1 ? "" : "s")",
                value: $plugin.lookAheadDays,
                in: 1...30
            )
            SettingsToggleRow("Hide all-day events", isOn: $plugin.hideAllDay)
            SettingsToggleRow("Show declined events", isOn: $plugin.showDeclined)

            Divider()

            NextMeetingCalendarPicker(plugin: plugin)

            Divider()

            SettingsSectionHeader("Access")
            Button("Grant Calendar access") {
                Task { await plugin.requestCalendarAccess() }
            }
        }
    }
}

/// Multi-select list of the user's calendars. "All calendars" is the default
/// (nil selection); toggling any calendar off makes the selection explicit.
private struct NextMeetingCalendarPicker: View {
    let plugin: NextMeetingPlugin
    @State private var calendars: [NextMeetingCalendar] = []

    private var allIDs: [String] { calendars.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsSectionHeader("Calendars")
                Spacer()
                Button("All") { plugin.selectAllCalendars() }
                    .controlSize(.small)
                Button("None") { plugin.selectNoCalendars() }
                    .controlSize(.small)
            }

            if !plugin.calendarAuthorized {
                SettingsHelp("Grant Calendar access to choose calendars.")
            } else if calendars.isEmpty {
                SettingsHelp("No calendars found.")
            } else {
                ForEach(calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { plugin.isCalendarSelected(calendar.id) },
                        set: { plugin.setCalendar(calendar.id, included: $0, allIDs: allIDs) }
                    )) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(calendar.color.swiftUIColor)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(calendar.title)
                                Text(calendar.sourceTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if plugin.hasNoCalendarsSelected {
                    Text("No calendars selected — the glance will be empty.")
                        .font(.caption)
                        .foregroundStyle(GlanceStyle.warning)
                }
            }
        }
        .onAppear { calendars = plugin.availableCalendars() }
    }
}
