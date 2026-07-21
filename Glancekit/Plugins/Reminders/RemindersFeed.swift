import Foundation
import EventKit

/// A Sendable, SwiftUI-friendly RGBA colour captured from an `EKCalendar`
/// (a reminder list). Mirrors `NextMeetingColor` — each glance owns its own
/// snapshot type so no plugin imports another (see `docs/PLUGIN_CONTRACT.md`).
struct ReminderColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var swiftUIColorComponents: (Double, Double, Double, Double) { (red, green, blue, alpha) }

    static let fallback = ReminderColor(red: 0.4, green: 0.5, blue: 0.9, alpha: 1)

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

/// One selectable reminder list (an `EKCalendar` of type `.reminder`).
struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
    let color: ReminderColor
}

/// A Sendable snapshot of a single reminder. Grouping/sorting lives in the
/// plugin; the feed just hands back a flat, best-effort list.
struct ReminderSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    /// The concrete due date, when the reminder has due date components.
    let dueDate: Date?
    /// Whether those components carry a time-of-day (vs. an all-day due date).
    let hasTime: Bool
    let isCompleted: Bool
    /// EventKit priority: 0 = none, 1 (high) … 9 (low). See `PriorityBucket`.
    let priority: Int
    let notes: String?
    let listID: String
    let listTitle: String
    let listColor: ReminderColor
}

enum ReminderAuthState {
    case unknown
    case notAuthorized
    case authorized
}

/// Options that shape a reminders query.
struct RemindersQueryOptions {
    /// `nil` means every list (the default); an empty set means none selected.
    var listIDs: Set<String>?
}

/// Thin, self-contained wrapper around EventKit's reminders store. Never throws
/// out of its load path — callers get an empty list plus an authorization state
/// so the popover chrome can render a grant prompt.
@MainActor
final class RemindersFeed {
    private let store = EKEventStore()

    /// Full access is read **and** write — completing a reminder saves it back.
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    var authState: ReminderAuthState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .authorized
        case .notDetermined, .restricted, .denied, .writeOnly: return .notAuthorized
        @unknown default: return .notAuthorized
        }
    }

    /// Reminder lists available for selection (empty until access is granted).
    func availableLists() -> [ReminderList] {
        guard authState == .authorized else { return [] }
        return store.calendars(for: .reminder)
            .map {
                ReminderList(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? "",
                    color: ReminderColor(cgColor: $0.cgColor)
                )
            }
            .sorted {
                if $0.sourceTitle != $1.sourceTitle {
                    return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    /// Loads the incomplete reminders in the selected lists. Returns `[]` when
    /// access isn't granted or the user has explicitly chosen no lists.
    func loadIncomplete(options: RemindersQueryOptions) async -> [ReminderSnapshot] {
        guard authState == .authorized else { return [] }

        let all = store.calendars(for: .reminder)
        let calendars: [EKCalendar]?
        if let ids = options.listIDs {
            guard !ids.isEmpty else { return [] }  // explicit "none" → nothing
            calendars = all.filter { ids.contains($0.calendarIdentifier) }
        } else {
            calendars = nil  // all lists
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars)

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? [])
                    .filter { !$0.isCompleted }
                    .map { Self.snapshot(from: $0) }
                continuation.resume(returning: snapshots)
            }
        }
    }

    /// Marks a reminder complete/incomplete and saves. Best-effort: a missing
    /// item or save failure is swallowed (the next refresh reconciles state).
    @discardableResult
    func setCompleted(_ id: String, _ completed: Bool) -> Bool {
        guard authState == .authorized,
              let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    private static func snapshot(from reminder: EKReminder) -> ReminderSnapshot {
        let comps = reminder.dueDateComponents
        let hasTime = comps?.hour != nil || comps?.minute != nil
        return ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled reminder",
            dueDate: comps?.date,
            hasTime: hasTime,
            isCompleted: reminder.isCompleted,
            priority: reminder.priority,
            notes: reminder.notes,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            listTitle: reminder.calendar?.title ?? "",
            listColor: ReminderColor(cgColor: reminder.calendar?.cgColor)
        )
    }
}
