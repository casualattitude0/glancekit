import Foundation
import EventKit
import SwiftUI

/// Lightweight snapshot of a calendar event used by the Next Meeting glance.
///
/// Self-contained — this deliberately does NOT share any type with the
/// Time & Productivity glance (no cross-plugin imports). The meeting-URL
/// detection mirrors that glance's approach but is reimplemented here.
struct NextMeetingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    /// RGBA components of the owning calendar's colour (0…1), for a colour dot.
    let calendarColor: NextMeetingColor
    let location: String?
    let notes: String?
    let url: URL?

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

    /// True once the event has ended.
    var hasEnded: Bool { endDate < Date() }

    /// True while the event is currently happening.
    var isUnderway: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }

    private static func looksLikeMeetingURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("zoom.us")
            || lower.contains("meet.google.com")
            || lower.contains("teams.microsoft.com")
            || lower.contains("teams.live.com")
    }

    private static func extractMeetingURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            if let url = match.url, looksLikeMeetingURL(url.absoluteString) {
                return url
            }
        }
        return nil
    }
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

    /// Today's remaining agenda: every event from now until the end of today,
    /// sorted by start time (events already underway are included).
    func loadTodayAgenda() -> [NextMeetingEvent] {
        guard authState == .authorized else { return [] }
        let cal = Calendar.current
        let now = Date()
        guard let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.snapshot)
    }

    /// The next `limit` upcoming events across the next `days` days, soonest
    /// first. Only events that start in the future (not yet begun) are returned.
    func loadUpcoming(limit: Int, days: Int = 7) -> [NextMeetingEvent] {
        guard authState == .authorized else { return [] }
        let cal = Calendar.current
        let now = Date()
        guard let end = cal.date(byAdding: .day, value: max(1, days), to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(max(0, limit))
            .map(Self.snapshot)
    }

    private static func snapshot(_ event: EKEvent) -> NextMeetingEvent {
        NextMeetingEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate ?? event.startDate,
            calendarTitle: event.calendar?.title ?? "Calendar",
            calendarColor: NextMeetingColor(cgColor: event.calendar?.cgColor),
            location: event.location,
            notes: event.notes,
            url: event.url
        )
    }
}
