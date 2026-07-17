import Foundation
import EventKit

/// Lightweight, Sendable snapshot of an upcoming calendar event.
struct TimeProdEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let location: String?
    let notes: String?
    let url: URL?

    /// Best-effort meeting URL detected in the event's url/location/notes.
    var meetingURL: URL? {
        if let url, TimeProdEvent.looksLikeMeetingURL(url.absoluteString) {
            return url
        }
        for candidate in [location, notes].compactMap({ $0 }) {
            if let found = TimeProdEvent.extractMeetingURL(from: candidate) {
                return found
            }
        }
        return nil
    }

    private static func looksLikeMeetingURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("zoom.us") || lower.contains("meet.google.com") || lower.contains("teams.microsoft.com") || lower.contains("teams.live.com")
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

/// Lightweight snapshot of an incomplete reminder.
struct TimeProdReminder: Identifiable {
    let id: String
    let title: String
    let dueDate: Date?
}

enum EventKitAuthState {
    case unknown
    case notAuthorized
    case authorized
}

/// Thin wrapper around EventKit for calendar events + reminders.
/// Never throws out of `loadNextEvent`/`loadReminders` — callers get empty
/// results plus an authorization state to render a "grant access" message.
@MainActor
final class TimeProdEventKitFeed {
    private let store = EKEventStore()

    func requestCalendarAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func requestRemindersAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    var calendarAuthState: EventKitAuthState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined, .restricted, .denied, .writeOnly: return .notAuthorized
        @unknown default: return .notAuthorized
        }
    }

    var remindersAuthState: EventKitAuthState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .authorized
        case .notDetermined, .restricted, .denied, .writeOnly: return .notAuthorized
        @unknown default: return .notAuthorized
        }
    }

    /// Returns the next upcoming event within the next 14 days, if any.
    func loadNextEvent() -> TimeProdEvent? {
        guard calendarAuthState == .authorized else { return nil }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 14, to: now) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
        guard let next = events.first else { return nil }
        return TimeProdEvent(
            id: next.eventIdentifier ?? UUID().uuidString,
            title: next.title ?? "Untitled event",
            startDate: next.startDate,
            location: next.location,
            notes: next.notes,
            url: next.url
        )
    }

    /// Returns a handful of incomplete reminders, soonest due first.
    func loadReminders(limit: Int = 5) async -> [TimeProdReminder] {
        guard remindersAuthState == .authorized else { return [] }
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let incomplete = (reminders ?? [])
                    .filter { !$0.isCompleted }
                    .sorted { lhs, rhs in
                        let l = lhs.dueDateComponents?.date ?? .distantFuture
                        let r = rhs.dueDateComponents?.date ?? .distantFuture
                        return l < r
                    }
                    .prefix(limit)
                    .map {
                        TimeProdReminder(
                            id: $0.calendarItemIdentifier,
                            title: $0.title ?? "Untitled reminder",
                            dueDate: $0.dueDateComponents?.date
                        )
                    }
                continuation.resume(returning: Array(incomplete))
            }
        }
    }
}
