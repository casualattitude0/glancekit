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
    /// Archived habits are hidden from the popover but keep their history.
    var isArchived: Bool
    /// Optional soft goal: how many times per week the user aims to do this.
    var targetPerWeek: Int?

    init(id: UUID = UUID(),
         name: String,
         icon: String = "circle",
         schedule: Schedule = .daily,
         createdAt: Date = Date(),
         completedDays: Set<String> = [],
         isArchived: Bool = false,
         targetPerWeek: Int? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.schedule = schedule
        self.createdAt = createdAt
        self.completedDays = completedDays
        self.isArchived = isArchived
        self.targetPerWeek = targetPerWeek
    }

    // Custom decoding so JSON written by earlier versions (which had no
    // `isArchived` / `targetPerWeek` keys, and could in principle lack the
    // optional-init fields) still decodes cleanly. New fields fall back to
    // safe defaults when absent. Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, schedule, createdAt, completedDays, isArchived, targetPerWeek
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "circle"
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? .daily
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedDays = try c.decodeIfPresent(Set<String>.self, forKey: .completedDays) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        targetPerWeek = try c.decodeIfPresent(Int.self, forKey: .targetPerWeek)
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

    /// Non-archived habits scheduled for today, in list order.
    func habitsDueToday() -> [Habit] {
        habits.filter { !$0.isArchived && isScheduled($0, on: Date()) }
    }

    /// Non-archived habits, in list order.
    var activeHabits: [Habit] { habits.filter { !$0.isArchived } }

    /// Archived habits, in list order.
    var archivedHabits: [Habit] { habits.filter { $0.isArchived } }

    func isCompletedToday(_ habit: Habit) -> Bool {
        habit.completedDays.contains(todayKey)
    }

    /// Whether a habit is marked complete on an arbitrary date.
    func isCompleted(_ habit: Habit, on date: Date) -> Bool {
        habit.completedDays.contains(dayKey(for: date))
    }

    /// Toggle today's completion for a habit and persist.
    func toggleToday(_ habit: Habit) {
        toggle(habit, on: Date())
    }

    /// Toggle completion for an arbitrary (non-future) day and persist. Future
    /// days are ignored — you can't complete a habit ahead of time.
    func toggle(_ habit: Habit, on date: Date) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        let cal = calendar
        if cal.startOfDay(for: date) > cal.startOfDay(for: Date()) { return }
        let key = dayKey(for: date)
        if habits[idx].completedDays.contains(key) {
            habits[idx].completedDays.remove(key)
        } else {
            habits[idx].completedDays.insert(key)
        }
    }

    func addHabit(_ habit: Habit) { habits.append(habit) }

    func deleteHabit(_ habit: Habit) { habits.removeAll { $0.id == habit.id } }

    /// Replace a habit in place (edit name / icon / schedule / target), preserving
    /// its position and completion history. No-op if it no longer exists.
    func updateHabit(_ habit: Habit) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[idx] = habit
    }

    /// Archive or unarchive a habit (keeps history either way).
    func setArchived(_ habit: Habit, _ archived: Bool) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[idx].isArchived = archived
    }

    // MARK: Reordering (persisted via didSet)

    /// Move rows for a SwiftUI `.onMove`. Offsets are indices into `habits`.
    func moveHabits(fromOffsets source: IndexSet, toOffset destination: Int) {
        habits.move(fromOffsets: source, toOffset: destination)
    }

    func moveHabitUp(_ habit: Habit) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }), idx > 0 else { return }
        habits.swapAt(idx, idx - 1)
    }

    func moveHabitDown(_ habit: Habit) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }), idx < habits.count - 1 else { return }
        habits.swapAt(idx, idx + 1)
    }

    /// Clear a habit's completion history (keeps the habit itself).
    func resetHistory(_ habit: Habit) {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[idx].completedDays.removeAll()
    }

    // MARK: History helpers

    /// The last `count` days as start-of-day dates, oldest first (ending today).
    func recentDays(_ count: Int) -> [Date] {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap {
            cal.date(byAdding: .day, value: -$0, to: today)
        }
    }

    /// Completion rate over the last 7 days, counting only scheduled days.
    /// `nil` when nothing was scheduled in the window.
    func weeklyCompletionRate(_ habit: Habit) -> Double? {
        let cal = calendar
        var scheduled = 0
        var done = 0
        var day = cal.startOfDay(for: Date())
        for _ in 0..<7 {
            if isScheduled(habit, on: day) {
                scheduled += 1
                if habit.completedDays.contains(dayKey(for: day)) { done += 1 }
            }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        guard scheduled > 0 else { return nil }
        return Double(done) / Double(scheduled)
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

// MARK: - Shared weekday labels

private let habitsWeekdaySymbols: [(Int, String)] = [
    (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"),
    (5, "Thu"), (6, "Fri"), (7, "Sat")
]

private func habitsScheduleText(_ schedule: Habit.Schedule) -> String {
    switch schedule {
    case .daily:
        return "Every day"
    case .weekdays(let days):
        let labels = habitsWeekdaySymbols.filter { days.contains($0.0) }.map(\.1)
        return labels.isEmpty ? "No days set" : labels.joined(separator: " ")
    }
}

// MARK: - Popover UI

private struct HabitsPopover: View {
    @Bindable var plugin: HabitsPlugin
    @State private var route: HabitsSheetRoute?

    private var due: [Habit] { plugin.habitsDueToday() }
    private var notDue: [Habit] {
        plugin.habits.filter { !$0.isArchived && !plugin.isScheduled($0, on: Date()) }
    }
    private var doneCount: Int { due.filter { plugin.isCompletedToday($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plugin.activeHabits.isEmpty {
                HabitsEmptyState { route = .add }
            } else {
                HStack {
                    Text("\(doneCount)/\(due.count) done today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        route = .add
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a habit")
                }

                ForEach(due) { habit in
                    HabitsRow(plugin: plugin, habit: habit, restDay: false) {
                        route = .detail(habit.id)
                    }
                }
                if !notDue.isEmpty {
                    ForEach(notDue) { habit in
                        HabitsRow(plugin: plugin, habit: habit, restDay: true) {
                            route = .detail(habit.id)
                        }
                    }
                }
            }
        }
        .task { await plugin.refresh() }
        .sheet(item: $route) { route in
            switch route {
            case .add:
                HabitsEditor(plugin: plugin, habitID: nil)
            case .edit(let id):
                HabitsEditor(plugin: plugin, habitID: id)
            case .detail(let id):
                HabitsDetail(plugin: plugin, habitID: id) { editID in
                    self.route = .edit(editID)
                }
            }
        }
    }
}

private struct HabitsRow: View {
    @Bindable var plugin: HabitsPlugin
    let habit: Habit
    let restDay: Bool
    var onOpen: () -> Void = {}

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
        // Tapping the label area (not the checkbox) opens the history detail.
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .opacity(restDay ? 0.55 : 1)
    }
}

private struct HabitsEmptyState: View {
    var onAdd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No habits yet", systemImage: "checkmark.seal")
                .font(.body.weight(.semibold))
            Text("Add your first habit to start building a streak.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onAdd()
            } label: {
                Label("Add a habit", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail view (streaks + tappable history heat strip)

private struct HabitsDetail: View {
    @Bindable var plugin: HabitsPlugin
    let habitID: UUID
    /// When set, an Edit button appears that routes to the habit editor. Lets the
    /// detail sheet double as the entry point for editing from the habit window,
    /// so you never have to open Settings to change a habit.
    var onEdit: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    private var habit: Habit? { plugin.habits.first { $0.id == habitID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let habit {
                HStack(spacing: 8) {
                    Image(systemName: habit.icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(habit.name).font(.title3.weight(.bold))
                    Spacer()
                    if let onEdit {
                        Button {
                            onEdit(habitID)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button("Done") { dismiss() }
                }

                Text(habitsScheduleText(habit.schedule))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 18) {
                    stat("Current", "🔥 \(plugin.currentStreak(habit))")
                    stat("Longest", "🔥 \(plugin.longestStreak(habit))")
                    if let rate = plugin.weeklyCompletionRate(habit) {
                        stat("This week", "\(Int((rate * 100).rounded()))%")
                    }
                    if let target = habit.targetPerWeek {
                        stat("Target", "\(target)/wk")
                    }
                }

                Divider()

                Text("Last 28 days")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HabitsHeatStrip(plugin: plugin, habit: habit)
                Text("Tap any scheduled day to toggle it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Divider()

                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset history", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Reset all completion history for \(habit.name)?",
                                    isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset history", role: .destructive) { plugin.resetHistory(habit) }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This habit was deleted.").font(.body)
                    Button("Done") { dismiss() }
                }
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct HabitsHeatStrip: View {
    @Bindable var plugin: HabitsPlugin
    let habit: Habit

    private static let dayNumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "d"
        return f
    }()

    private var days: [Date] { plugin.recentDays(28) }
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 5), count: 7)

    private var createdStart: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.startOfDay(for: habit.createdAt)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(days, id: \.self) { day in
                let beforeCreation = day < createdStart
                let scheduled = plugin.isScheduled(habit, on: day)
                let done = plugin.isCompleted(habit, on: day)
                let interactive = scheduled && !beforeCreation

                RoundedRectangle(cornerRadius: 5)
                    .fill(fill(scheduled: scheduled, done: done, beforeCreation: beforeCreation))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(Self.dayNumFormatter.string(from: day))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(done ? Color.white : Color.secondary)
                    )
                    .opacity(beforeCreation ? 0.25 : (scheduled ? 1 : 0.5))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if interactive { plugin.toggle(habit, on: day) }
                    }
                    .help(interactive
                          ? (done ? "Completed" : "Not done")
                          : (beforeCreation ? "Before this habit existed" : "Rest day"))
            }
        }
    }

    private func fill(scheduled: Bool, done: Bool, beforeCreation: Bool) -> Color {
        if beforeCreation { return Color.gray.opacity(0.15) }
        if !scheduled { return Color.gray.opacity(0.12) }
        return done ? Color.green : Color.gray.opacity(0.28)
    }
}

// MARK: - Settings UI

private enum HabitsSheetRoute: Identifiable {
    case add
    case edit(UUID)
    case detail(UUID)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let id): return "edit-\(id.uuidString)"
        case .detail(let id): return "detail-\(id.uuidString)"
        }
    }
}

private struct HabitsSettings: View {
    @Bindable var plugin: HabitsPlugin

    @State private var newName: String = ""
    @State private var newIcon: String = "star"
    @State private var isDaily: Bool = true
    @State private var selectedWeekdays: Set<Int> = [2, 3, 4, 5, 6] // Mon–Fri
    @State private var route: HabitsSheetRoute?

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
                    ForEach(habitsWeekdaySymbols, id: \.0) { num, label in
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

            if plugin.activeHabits.isEmpty {
                Text("No habits yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugin.activeHabits) { habit in
                    HabitsSettingsRow(
                        plugin: plugin,
                        habit: habit,
                        onEdit: { route = .edit(habit.id) },
                        onDetail: { route = .detail(habit.id) }
                    )
                }
            }

            if !plugin.archivedHabits.isEmpty {
                Divider()
                Text("Archived")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(plugin.archivedHabits) { habit in
                    HabitsArchivedRow(plugin: plugin, habit: habit) {
                        route = .detail(habit.id)
                    }
                }
            }
        }
        .sheet(item: $route) { route in
            switch route {
            case .add:
                HabitsEditor(plugin: plugin, habitID: nil)
            case .edit(let id):
                HabitsEditor(plugin: plugin, habitID: id)
            case .detail(let id):
                HabitsDetail(plugin: plugin, habitID: id) { editID in
                    self.route = .edit(editID)
                }
            }
        }
    }
}

private struct HabitsSettingsRow: View {
    @Bindable var plugin: HabitsPlugin
    let habit: Habit
    var onEdit: () -> Void
    var onDetail: () -> Void
    @State private var confirmDelete = false

    private var subtitle: String {
        var parts = [habitsScheduleText(habit.schedule)]
        if let t = habit.targetPerWeek { parts.append("target \(t)/wk") }
        parts.append("longest 🔥\(plugin.longestStreak(habit))")
        return parts.joined(separator: " · ")
    }

    private var canMoveUp: Bool { plugin.habits.first?.id != habit.id }
    private var canMoveDown: Bool { plugin.habits.last?.id != habit.id }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                Button { plugin.moveHabitUp(habit) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                Button { plugin.moveHabitDown(habit) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
            }
            .font(.caption2)

            Image(systemName: habit.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name).font(.body)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(action: onDetail) {
                Image(systemName: "chart.bar")
            }
            .buttonStyle(.borderless)
            .help("History & streaks")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit habit")

            Button {
                plugin.setArchived(habit, true)
            } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(.borderless)
            .help("Archive (hide but keep history)")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete habit")
            .confirmationDialog("Delete \(habit.name)? This erases its history.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { plugin.deleteHabit(habit) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct HabitsArchivedRow: View {
    @Bindable var plugin: HabitsPlugin
    let habit: Habit
    var onDetail: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: habit.icon)
                .frame(width: 20)
                .foregroundStyle(.tertiary)
            Text(habit.name)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()

            Button(action: onDetail) {
                Image(systemName: "chart.bar")
            }
            .buttonStyle(.borderless)
            .help("History & streaks")

            Button {
                plugin.setArchived(habit, false)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Unarchive")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete habit")
            .confirmationDialog("Delete \(habit.name)? This erases its history.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { plugin.deleteHabit(habit) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .opacity(0.8)
    }
}

// MARK: - Editor (edit an existing habit)

private struct HabitsEditor: View {
    @Bindable var plugin: HabitsPlugin
    /// `nil` creates a brand-new habit; otherwise edits the habit with this id.
    let habitID: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var icon: String = "star"
    @State private var isDaily: Bool = true
    @State private var selectedWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var hasTarget: Bool = false
    @State private var target: Int = 3
    @State private var loaded = false

    private var isNew: Bool { habitID == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// True unless we're editing a habit that has since been deleted out from
    /// under us. Creating a new habit is always valid.
    private var habitExists: Bool {
        guard let habitID else { return true }
        return plugin.habits.contains(where: { $0.id == habitID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isNew ? "New habit" : "Edit habit").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            if habitExists {
                TextField("Name (e.g. Read 20 min)", text: $name)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Image(systemName: icon.isEmpty ? "questionmark" : icon)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    TextField("SF Symbol (e.g. book, dumbbell)", text: $icon)
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Schedule", selection: $isDaily) {
                    Text("Every day").tag(true)
                    Text("Specific weekdays").tag(false)
                }
                .pickerStyle(.segmented)

                if !isDaily {
                    HStack(spacing: 4) {
                        ForEach(habitsWeekdaySymbols, id: \.0) { num, label in
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

                Toggle("Weekly target", isOn: $hasTarget)
                if hasTarget {
                    Stepper("Aim for \(target)× per week", value: $target, in: 1...7)
                        .font(.callout)
                }

                HStack {
                    Spacer()
                    Button(isNew ? "Add habit" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty)
                }
            } else {
                Text("This habit no longer exists.")
                Button("Close") { dismiss() }
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        // New habit: keep the default field values.
        guard let habitID, let h = plugin.habits.first(where: { $0.id == habitID }) else {
            loaded = true
            return
        }
        loaded = true
        name = h.name
        icon = h.icon
        switch h.schedule {
        case .daily:
            isDaily = true
        case .weekdays(let days):
            isDaily = false
            if !days.isEmpty { selectedWeekdays = days }
        }
        if let t = h.targetPerWeek {
            hasTarget = true
            target = min(max(t, 1), 7)
        }
    }

    private func save() {
        let n = trimmedName
        guard !n.isEmpty else { return }
        let trimmedIcon = icon.trimmingCharacters(in: .whitespaces)
        let resolvedIcon = trimmedIcon.isEmpty ? "circle" : trimmedIcon
        let schedule: Habit.Schedule = isDaily ? .daily : .weekdays(selectedWeekdays)
        let resolvedTarget = hasTarget ? target : nil

        if let habitID {
            guard var h = plugin.habits.first(where: { $0.id == habitID }) else { return }
            h.name = n
            h.icon = resolvedIcon
            h.schedule = schedule
            h.targetPerWeek = resolvedTarget
            plugin.updateHabit(h)
        } else {
            plugin.addHabit(Habit(name: n,
                                  icon: resolvedIcon,
                                  schedule: schedule,
                                  targetPerWeek: resolvedTarget))
        }
        dismiss()
    }
}
