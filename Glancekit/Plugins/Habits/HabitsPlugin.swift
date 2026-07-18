import SwiftUI
import Observation

// MARK: - Model

/// A single tracked habit. Codable so the full list round-trips to
/// `UserDefaults` as JSON. Completion is stored as a set of day-keys
/// ("yyyy-MM-dd" in the user's current timezone) so the time of day a habit is
/// checked off can never shift which calendar day it counts for.
struct Habit: Codable, Identifiable, Equatable {
    enum Schedule: Codable, Equatable {
        /// Due every day.
        case daily
        /// Due only on the given weekday numbers (1 = Sun … 7 = Sat).
        case weekdays(Set<Int>)
    }

    var id: UUID
    var name: String
    var icon: String            // SF Symbol name
    var schedule: Schedule
    var createdAt: Date
    /// Day-keys ("yyyy-MM-dd") the habit was completed on.
    var completedDays: Set<String>

    init(id: UUID = UUID(),
         name: String,
         icon: String = "circle",
         schedule: Schedule = .daily,
         createdAt: Date = Date(),
         completedDays: Set<String> = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.schedule = schedule
        self.createdAt = createdAt
        self.completedDays = completedDays
    }
}

// MARK: - Plugin

/// Daily habit / streak tracker.
///
/// Keyless and offline — the whole habit list lives in `UserDefaults` as JSON.
/// Streaks are computed from the set of completed day-keys, only counting the
/// days a habit was actually scheduled.
@MainActor
@Observable
final class HabitsPlugin: GlancePlugin {
    nonisolated var id: String { "habits" }
    nonisolated var title: String { "Habits" }
    nonisolated var iconSystemName: String { "checkmark.seal" }
    // 30 min: refresh the "today" boundary and the late-day streak-risk escalation.
    var refreshInterval: TimeInterval { 1800 }

    /// The full habit list, persisted as JSON on every mutation.
    var habits: [Habit] {
        didSet { persist() }
    }

    private let storageKey = "glancekit.habits.list"

    /// Fixed calendar in the user's current timezone, used for both day-key
    /// derivation and weekday lookups so everything agrees on "today".
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }

    /// Formatter that turns a `Date` into a stable "yyyy-MM-dd" day-key.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Habit].self, from: data) {
            habits = decoded
        } else {
            habits = []
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(habits) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: GlancePlugin

    /// Nothing to fetch — habits are local. `refresh()` just nudges the
    /// `@Observable` graph so the popover recomputes "today" after a boundary
    /// crossing or a late-day escalation. Never throws, never crashes.
    func refresh() async {
        // Reassigning the same value re-publishes the observable state cheaply.
        // (Avoid mutating in a didSet — this is a plain read+write of the array.)
        let current = habits
        habits = current
    }

    func currentSignal() -> GlanceSignal? {
        let due = habitsDueToday()
        guard !due.isEmpty else { return nil }
        let undone = due.filter { !isCompletedToday($0) }
        guard !undone.isEmpty else { return nil }

        // Escalate after 20:00 local if a habit with a live streak is still
        // undone — a streak is genuinely at risk of breaking tonight.
        let hour = calendar.component(.hour, from: Date())
        let atRisk = hour >= 20
            ? undone.compactMap { h -> (Habit, Int)? in
                let s = currentStreak(h)
                return s > 0 ? (h, s) : nil
              }.max(by: { $0.1 < $1.1 })
            : nil

        let headline: String
        let priority: GlanceSignal.Priority
        if let (habit, streak) = atRisk {
            headline = "\(habit.name) streak at risk · 🔥\(streak)"
            priority = .elevated
        } else {
            headline = "\(undone.count) habit\(undone.count == 1 ? "" : "s") left today"
            priority = .normal
        }

        let firstDue = undone[0]
        let quick = GlanceSignal.QuickAction(
            title: "Mark \(firstDue.name)",
            systemImage: "checkmark.circle"
        ) { [weak self] in
            self?.toggleToday(firstDue)
        }

        return GlanceSignal(
            priority: priority,
            score: Double(undone.count),
            headline: headline,
            detail: "\(due.count - undone.count)/\(due.count) done today",
            systemImage: iconSystemName,
            quickAction: quick
        )
    }

    func popoverSection() -> AnyView { AnyView(HabitsPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(HabitsSettings(plugin: self)) }

    // MARK: Day / schedule logic

    /// The "yyyy-MM-dd" key for a date in the user's current timezone.
    func dayKey(for date: Date) -> String { Self.dayKeyFormatter.string(from: date) }

    private var todayKey: String { dayKey(for: Date()) }

    /// Weekday (1 = Sun … 7 = Sat) for a date.
    private func weekday(of date: Date) -> Int { calendar.component(.weekday, from: date) }

    /// Whether a habit is scheduled on the given date.
    func isScheduled(_ habit: Habit, on date: Date) -> Bool {
        switch habit.schedule {
        case .daily: return true
        case .weekdays(let days): return days.contains(weekday(of: date))
        }
    }

    /// Habits scheduled for today, in list order.
    func habitsDueToday() -> [Habit] {
        habits.filter { isScheduled($0, on: Date()) }
    }

    func isCompletedToday(_ habit: Habit) -> Bool {
        habit.completedDays.contains(todayKey)
    }

    /// Toggle today's completion for a habit and persist.
    func toggleToday(_ habit: Habit) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        let key = todayKey
        if habits[idx].completedDays.contains(key) {
            habits[idx].completedDays.remove(key)
        } else {
            habits[idx].completedDays.insert(key)
        }
    }

    func addHabit(_ habit: Habit) { habits.append(habit) }

    func deleteHabit(_ habit: Habit) { habits.removeAll { $0.id == habit.id } }

    /// Clear a habit's completion history (keeps the habit itself).
    func resetHistory(_ habit: Habit) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[idx].completedDays.removeAll()
    }

    // MARK: Streaks

    /// Current streak: walk backwards day by day from today, counting only the
    /// days the habit is *scheduled*. Every scheduled day must be completed to
    /// keep the run alive; non-scheduled days are skipped without breaking it.
    ///
    /// Today counts if it's already done. If today is scheduled but not yet
    /// done, we don't treat that as a break — we simply start counting from
    /// yesterday, so an unfinished-but-still-open today can't zero a live streak.
    func currentStreak(_ habit: Habit) -> Int {
        let cal = calendar
        var streak = 0
        var day = Date()

        // If today is scheduled and not yet completed, begin from yesterday.
        if isScheduled(habit, on: day) && !habit.completedDays.contains(dayKey(for: day)) {
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = prev
        }

        // Don't walk earlier than the habit's creation day.
        let createdKey = dayKey(for: habit.createdAt)
        while true {
            let key = dayKey(for: day)
            if isScheduled(habit, on: day) {
                if habit.completedDays.contains(key) {
                    streak += 1
                } else {
                    break // a scheduled day was missed — streak ends
                }
            }
            if key == createdKey { break }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Longest streak ever: scan from creation day to today, counting maximal
    /// runs of completed scheduled days (skipping non-scheduled days).
    func longestStreak(_ habit: Habit) -> Int {
        let cal = calendar
        var day = cal.startOfDay(for: habit.createdAt)
        let today = cal.startOfDay(for: Date())
        var best = 0
        var run = 0
        while day <= today {
            if isScheduled(habit, on: day) {
                if habit.completedDays.contains(dayKey(for: day)) {
                    run += 1
                    best = max(best, run)
                } else {
                    run = 0
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return best
    }
}

// MARK: - Popover UI

private struct HabitsPopover: View {
    @Bindable var plugin: HabitsPlugin

    private var due: [Habit] { plugin.habitsDueToday() }
    private var notDue: [Habit] {
        plugin.habits.filter { !plugin.isScheduled($0, on: Date()) }
    }
    private var doneCount: Int { due.filter { plugin.isCompletedToday($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plugin.habits.isEmpty {
                HabitsEmptyState()
            } else {
                HStack {
                    Text("\(doneCount)/\(due.count) done today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ForEach(due) { habit in
                    HabitsRow(plugin: plugin, habit: habit, restDay: false)
                }
                if !notDue.isEmpty {
                    ForEach(notDue) { habit in
                        HabitsRow(plugin: plugin, habit: habit, restDay: true)
                    }
                }
            }
        }
        .task { await plugin.refresh() }
    }
}

private struct HabitsRow: View {
    @Bindable var plugin: HabitsPlugin
    let habit: Habit
    let restDay: Bool

    private var done: Bool { plugin.isCompletedToday(habit) }
    private var streak: Int { plugin.currentStreak(habit) }

    var body: some View {
        HStack(spacing: 10) {
            if restDay {
                Image(systemName: "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(width: 26)
            } else {
                Button {
                    plugin.toggleToday(habit)
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(done ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 26)
            }

            Image(systemName: habit.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name)
                    .font(.body)
                    .strikethrough(done && !restDay, color: .secondary)
                if restDay {
                    Text("Rest day")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if streak > 0 {
                Text("🔥 \(streak)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(restDay ? Color.secondary : Color.orange)
            }
        }
        .opacity(restDay ? 0.55 : 1)
    }
}

private struct HabitsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No habits yet", systemImage: "checkmark.seal")
                .font(.body.weight(.semibold))
            Text("Add a habit in Settings to start building a streak.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings UI

private struct HabitsSettings: View {
    @Bindable var plugin: HabitsPlugin

    @State private var newName: String = ""
    @State private var newIcon: String = "star"
    @State private var isDaily: Bool = true
    @State private var selectedWeekdays: Set<Int> = [2, 3, 4, 5, 6] // Mon–Fri

    private let weekdaySymbols: [(Int, String)] = [
        (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"),
        (5, "Thu"), (6, "Fri"), (7, "Sat")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a habit")
                .font(.headline)

            TextField("Name (e.g. Read 20 min)", text: $newName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Image(systemName: newIcon.isEmpty ? "questionmark" : newIcon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                TextField("SF Symbol (e.g. book, dumbbell)", text: $newIcon)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Schedule", selection: $isDaily) {
                Text("Every day").tag(true)
                Text("Specific weekdays").tag(false)
            }
            .pickerStyle(.segmented)

            if !isDaily {
                HStack(spacing: 4) {
                    ForEach(weekdaySymbols, id: \.0) { num, label in
                        let on = selectedWeekdays.contains(num)
                        Button(label) {
                            if on { selectedWeekdays.remove(num) }
                            else { selectedWeekdays.insert(num) }
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                        .controlSize(.small)
                    }
                }
            }

            Button("Add habit") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let icon = newIcon.trimmingCharacters(in: .whitespaces)
                let schedule: Habit.Schedule = isDaily
                    ? .daily
                    : .weekdays(selectedWeekdays.isEmpty ? [] : selectedWeekdays)
                plugin.addHabit(Habit(name: name,
                                      icon: icon.isEmpty ? "circle" : icon,
                                      schedule: schedule))
                newName = ""
                newIcon = "star"
                isDaily = true
                selectedWeekdays = [2, 3, 4, 5, 6]
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)

            Divider()

            Text("Your habits")
                .font(.headline)

            if plugin.habits.isEmpty {
                Text("No habits yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugin.habits) { habit in
                    HabitsSettingsRow(plugin: plugin, habit: habit)
                }
            }
        }
    }
}

private struct HabitsSettingsRow: View {
    @Bindable var plugin: HabitsPlugin
    let habit: Habit

    private var scheduleText: String {
        switch habit.schedule {
        case .daily:
            return "Every day"
        case .weekdays(let days):
            let order = [1, 2, 3, 4, 5, 6, 7]
            let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
            let labels = order.filter { days.contains($0) }.compactMap { names[$0] }
            return labels.isEmpty ? "No days set" : labels.joined(separator: " ")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: habit.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name).font(.body)
                Text("\(scheduleText) · longest 🔥\(plugin.longestStreak(habit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                plugin.resetHistory(habit)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset history")

            Button {
                plugin.deleteHabit(habit)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete habit")
        }
    }
}
