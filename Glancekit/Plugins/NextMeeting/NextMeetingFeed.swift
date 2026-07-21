import Foundation
import EventKit
import SwiftUI

/// Lightweight snapshot of a calendar event used by the Next Meeting glance.
///
/// Self-contained — this deliberately does NOT share any type with another
/// glance (no cross-plugin imports); each EventKit-backed glance owns its own
/// snapshot types and feed. See `docs/PLUGIN_CONTRACT.md`.
struct NextMeetingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    /// Stable identifier of the owning calendar (survives across launches).
    let calendarIdentifier: String
    let calendarTitle: String
    /// RGBA components of the owning calendar's colour (0…1), for a colour dot.
    let calendarColor: NextMeetingColor
    let location: String?
    let notes: String?
    let url: URL?
    /// True for all-day events (start/end span whole days, no clock time).
    let isAllDay: Bool
    /// True when the current user has declined this event's invitation.
    let isDeclined: Bool

    /// Best-effort meeting URL detected in the event's url/location/notes.
    var meetingURL: URL? {
        if let url, NextMeetingEvent.looksLikeMeetingURL(url.absoluteString) {
            return url
        }
        for candidate in [location, notes].compactMap({ $0 }) {
            if let found = NextMeetingEvent.extractMeetingURL(from: candidate) {
                return found
            }
        }
        return nil
    }

    /// Every http(s) link detected across the event's url, location and notes,
    /// de-duplicated and preserving first-seen order. The detected `meetingURL`
    /// (if any) is surfaced first.
    var allLinks: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let key = url.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(url)
        }
        add(meetingURL)
        add(url)
        for candidate in [location, notes].compactMap({ $0 }) {
            for link in NextMeetingEvent.extractLinks(from: candidate) { add(link) }
        }
        return result
    }

    /// True once the event has ended.
    var hasEnded: Bool { endDate < Date() }

    /// True while the event is currently happening.
    var isUnderway: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }

    /// Host substrings that identify a joinable video-meeting link.
    private static let meetingHosts: [String] = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "around.co",
        "chime.aws",
        "gotomeeting.com"
    ]

    private static func looksLikeMeetingURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return meetingHosts.contains { lower.contains($0) }
    }

    private static func extractMeetingURL(from text: String) -> URL? {
        for url in extractLinks(from: text) where looksLikeMeetingURL(url.absoluteString) {
            return url
        }
        return nil
    }

    /// All links found in a free-text blob, in document order.
    static func extractLinks(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { $0.url }
    }
}

/// Static description of an `EKCalendar`, used to build the calendar-picker UI
/// without leaking EventKit types out of the feed.
struct NextMeetingCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let color: NextMeetingColor
    /// The account/source the calendar belongs to (e.g. "iCloud", "Google").
    let sourceTitle: String
}

/// A Sendable, SwiftUI-friendly RGBA colour captured from an `EKCalendar`.
struct NextMeetingColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    static let fallback = NextMeetingColor(red: 0.4, green: 0.5, blue: 0.9, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(cgColor: CGColor?) {
        guard let cgColor,
              let converted = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3 else {
            self = .fallback
            return
        }
        self.red = Double(comps[0])
        self.green = Double(comps[1])
        self.blue = Double(comps[2])
        self.alpha = comps.count >= 4 ? Double(comps[3]) : 1
    }
}

enum NextMeetingAuthState {
    case unknown
    case notAuthorized
    case authorized
}

/// Filtering options threaded through every event query so the agenda, the
/// upcoming list and the Smart Panel signal all see the same set of events.
struct NextMeetingQueryOptions {
    /// Selected calendar identifiers. `nil` means "all calendars" (the default);
    /// an empty set means the user has explicitly selected none.
    var calendarIDs: Set<String>?
    /// Hide all-day events (holidays, birthdays, multi-day trips).
    var hideAllDay: Bool
    /// Include events the current user has declined.
    var showDeclined: Bool
    /// How many days ahead the "upcoming" query reaches.
    var lookAheadDays: Int
}

/// Thin EventKit wrapper for the Next Meeting glance.
///
/// Never throws out of its load methods — denied/undetermined authorization
/// yields empty results plus an authorization state the plugin uses to gate
/// the section. Requests *full* access to events.
@MainActor
final class NextMeetingFeed {
    private let store = EKEventStore()

    func requestCalendarAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    var authState: NextMeetingAuthState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined, .restricted, .denied, .writeOnly: return .notAuthorized
        @unknown default: return .notAuthorized
        }
    }

    /// Every event calendar the user has, for the calendar picker. Empty when
    /// access hasn't been granted yet.
    func availableCalendars() -> [NextMeetingCalendar] {
        guard authState == .authorized else { return [] }
        return store.calendars(for: .event)
            .map {
                NextMeetingCalendar(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    color: NextMeetingColor(cgColor: $0.cgColor),
                    sourceTitle: $0.source?.title ?? "Calendar"
                )
            }
            .sorted {
                if $0.sourceTitle != $1.sourceTitle {
                    return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    /// Resolves selected identifiers to concrete `EKCalendar`s.
    ///
    /// Returns `nil` for "all calendars" (pass straight to the predicate).
    /// Returns a non-nil (possibly empty) array when the user has made an
    /// explicit selection — identifiers for calendars that no longer exist are
    /// silently dropped, so a removed calendar can't crash or resurrect events.
    private func resolveCalendars(_ ids: Set<String>?) -> [EKCalendar]? {
        guard let ids else { return nil }
        return store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
    }

    /// Today's remaining agenda: every event from now until the end of today,
    /// sorted by start time (events already underway are included).
    func loadTodayAgenda(options: NextMeetingQueryOptions) -> [NextMeetingEvent] {
        guard authState == .authorized else { return [] }
        let cal = Calendar.current
        let now = Date()
        guard let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return [] }
        return fetch(start: now, end: endOfDay, options: options)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    /// The next upcoming events across the configured look-ahead window, soonest
    /// first. Only events that start in the future (not yet begun) are returned.
    func loadUpcoming(limit: Int, options: NextMeetingQueryOptions) -> [NextMeetingEvent] {
        guard authState == .authorized else { return [] }
        let cal = Calendar.current
        let now = Date()
        let days = max(1, options.lookAheadDays)
        guard let end = cal.date(byAdding: .day, value: days, to: now) else { return [] }
        return Array(
            fetch(start: now, end: end, options: options)
                .filter { $0.startDate >= now }
                .sorted { $0.startDate < $1.startDate }
                .prefix(max(0, limit))
        )
    }

    /// Shared fetch: resolves the calendar filter, runs the predicate and
    /// applies the all-day / declined filters. An explicit empty selection
    /// short-circuits to no events (a plain empty predicate is ambiguous).
    private func fetch(start: Date, end: Date, options: NextMeetingQueryOptions) -> [NextMeetingEvent] {
        let calendars = resolveCalendars(options.calendarIDs)
        if options.calendarIDs != nil, calendars?.isEmpty == true { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
            .filter { options.showDeclined || !Self.isDeclined($0) }
            .filter { !(options.hideAllDay && $0.isAllDay) }
            .map(Self.snapshot)
    }

    /// Whether the current user declined this event (best-effort: checks the
    /// attendee flagged as the current user).
    private static func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    private static func snapshot(_ event: EKEvent) -> NextMeetingEvent {
        NextMeetingEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate ?? event.startDate,
            calendarIdentifier: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "Calendar",
            calendarColor: NextMeetingColor(cgColor: event.calendar?.cgColor),
            location: event.location,
            notes: event.notes,
            url: event.url,
            isAllDay: event.isAllDay,
            isDeclined: isDeclined(event)
        )
    }
}
