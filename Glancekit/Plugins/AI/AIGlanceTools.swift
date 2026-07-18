import Foundation

/// AI-assistant tools that operate the nine newer Glancekit glances (Timers,
/// Habits, Currency, Feeds, World Clock, Clipboard, Next Meeting, Network and
/// Power).
///
/// This mirrors `AIToolbox` in `AITools.swift`: `specs` describes every tool to
/// the model and `execute(_:)` runs a call the model chose, returning a short
/// string (compact JSON for list tools, a confirmation sentence for actions).
/// Each glance is reached through the injected `PluginRegistry` by its stable
/// id and downcast to its concrete plugin type. If a glance is missing or the
/// user has it disabled, the tool returns a friendly message instead of
/// crashing. After any mutation that changes visible state we call
/// `coordinator.reconcile()` (and the plugin's own `refresh()` where new data
/// must be fetched) so the rest of the app updates — mirroring `AITools.swift`.
///
/// Tool names are namespaced by glance (`timer_*`, `habit_*`, …) so they can't
/// collide with `AIToolbox`'s tools. Schema builders here are private to this
/// file and don't lean on `AIToolbox`'s.
///
/// `@MainActor` because it touches the plugins' observable state; a `struct`
/// holding only references, cheap to recreate per turn.
@MainActor
struct AIGlanceToolbox {
    private let registry: PluginRegistry
    private let coordinator: RefreshCoordinator

    init(registry: PluginRegistry, coordinator: RefreshCoordinator) {
        self.registry = registry
        self.coordinator = coordinator
    }

    // MARK: - Specs

    var specs: [AIToolSpec] {
        [
            // Timers
            AIToolSpec(
                name: "timer_start",
                description: "Start a countdown timer with an optional label and a duration in minutes and/or seconds.",
                parametersJSONSchema: Self.objectSchema([
                    "label": Self.stringProperty("Optional label for the timer, e.g. \"Tea\"."),
                    "minutes": Self.numberProperty("Whole minutes for the countdown."),
                    "seconds": Self.numberProperty("Additional seconds for the countdown."),
                ])),
            AIToolSpec(
                name: "timer_list",
                description: "List the current timers with their label, state, and time remaining.",
                parametersJSONSchema: Self.objectSchema([:])),
            AIToolSpec(
                name: "timer_stop",
                description: "Stop and remove a timer, identified by its label or id.",
                parametersJSONSchema: Self.objectSchema([
                    "timer": Self.stringProperty("The timer's label or id."),
                ], required: ["timer"])),

            // Habits
            AIToolSpec(
                name: "habit_list",
                description: "List habits with today's done-state and current streak.",
                parametersJSONSchema: Self.objectSchema([:])),
            AIToolSpec(
                name: "habit_add",
                description: "Add a habit with a name, optional SF Symbol icon, and a schedule.",
                parametersJSONSchema: Self.objectSchema([
                    "name": Self.stringProperty("The habit's name, e.g. \"Read 20 min\"."),
                    "icon": Self.stringProperty("Optional SF Symbol name, e.g. \"book\"."),
                    "schedule": Self.stringProperty("\"daily\" (default) or \"weekdays\"."),
                    "weekdays": Self.stringArrayProperty("When schedule is \"weekdays\": day names (Mon, Tue, …) or numbers 1=Sun…7=Sat."),
                ], required: ["name"])),
            AIToolSpec(
                name: "habit_complete",
                description: "Mark a habit as done today, identified by its name.",
                parametersJSONSchema: Self.objectSchema([
                    "name": Self.stringProperty("The habit's name."),
                ], required: ["name"])),

            // Currency
            AIToolSpec(
                name: "currency_list_rates",
                description: "List the current currency pairs, their rates, and change%.",
                parametersJSONSchema: Self.objectSchema([:])),
            AIToolSpec(
                name: "currency_add_pair",
                description: "Add a target currency to watch, by ISO code (e.g. \"CHF\").",
                parametersJSONSchema: Self.objectSchema([
                    "code": Self.stringProperty("ISO 4217 currency code to add as a target."),
                ], required: ["code"])),
            AIToolSpec(
                name: "currency_remove_pair",
                description: "Remove a watched target currency, by ISO code.",
                parametersJSONSchema: Self.objectSchema([
                    "code": Self.stringProperty("ISO 4217 currency code to remove from the targets."),
                ], required: ["code"])),
            AIToolSpec(
                name: "currency_set_base",
                description: "Set the base currency everything is quoted against, by ISO code.",
                parametersJSONSchema: Self.objectSchema([
                    "code": Self.stringProperty("ISO 4217 currency code to use as the base."),
                ], required: ["code"])),

            // Feeds
            AIToolSpec(
                name: "feed_list_unread",
                description: "List unread feed items with their title, source, and link.",
                parametersJSONSchema: Self.objectSchema([:])),
            AIToolSpec(
                name: "feed_add",
                description: "Add an RSS/Atom feed by URL, with an optional display name.",
                parametersJSONSchema: Self.objectSchema([
                    "url": Self.stringProperty("The feed URL (http/https)."),
                    "name": Self.stringProperty("Optional display name for the feed."),
                ], required: ["url"])),

            // World Clock
            AIToolSpec(
                name: "worldclock_list",
                description: "List the configured world-clock zones with the current time in each.",
                parametersJSONSchema: Self.objectSchema([:])),
            AIToolSpec(
                name: "worldclock_add_zone",
                description: "Add a world-clock zone by IANA identifier (e.g. \"Asia/Tokyo\").",
                parametersJSONSchema: Self.objectSchema([
                    "zone": Self.stringProperty("IANA time-zone identifier, e.g. \"Europe/Paris\"."),
                ], required: ["zone"])),
            AIToolSpec(
                name: "worldclock_remove_zone",
                description: "Remove a world-clock zone by IANA identifier.",
                parametersJSONSchema: Self.objectSchema([
                    "zone": Self.stringProperty("IANA time-zone identifier to remove."),
                ], required: ["zone"])),

            // Clipboard
            AIToolSpec(
                name: "clipboard_recent",
                description: "List the most recent clipboard entries. Images are shown as \"[image]\".",
                parametersJSONSchema: Self.objectSchema([
                    "count": Self.numberProperty("How many recent entries to return (default 10)."),
                ])),

            // Next Meeting
            AIToolSpec(
                name: "nextmeeting_agenda",
                description: "Show the next meeting and today's remaining agenda from Calendar.",
                parametersJSONSchema: Self.objectSchema([:])),

            // Network
            AIToolSpec(
                name: "network_status",
                description: "Read the current network status (online, connection type, latency, IPs, Wi-Fi, VPN).",
                parametersJSONSchema: Self.objectSchema([:])),

            // Power
            AIToolSpec(
                name: "power_status",
                description: "Read the current battery/power status (charge, state, health, temperature).",
                parametersJSONSchema: Self.objectSchema([:])),
        ]
    }

    /// The set of tool names this toolbox owns. Kept as the single source of
    /// truth for `handles(_:)` so it can never drift from `specs`.
    private var toolNames: Set<String> { Set(specs.map(\.name)) }

    func handles(_ name: String) -> Bool { toolNames.contains(name) }

    // MARK: - Execution

    /// Run one tool call. Never throws — any failure comes back as a plain
    /// message string the model can read and recover from.
    func execute(_ call: AIToolCall) async -> String {
        switch call.name {
        // Timers
        case "timer_start": return timerStart(call.arguments)
        case "timer_list": return timerList()
        case "timer_stop": return timerStop(call.arguments)
        // Habits
        case "habit_list": return habitList()
        case "habit_add": return habitAdd(call.arguments)
        case "habit_complete": return habitComplete(call.arguments)
        // Currency
        case "currency_list_rates": return await currencyListRates()
        case "currency_add_pair": return await currencyAddPair(call.arguments)
        case "currency_remove_pair": return await currencyRemovePair(call.arguments)
        case "currency_set_base": return await currencySetBase(call.arguments)
        // Feeds
        case "feed_list_unread": return await feedListUnread()
        case "feed_add": return await feedAdd(call.arguments)
        // World Clock
        case "worldclock_list": return worldClockList()
        case "worldclock_add_zone": return worldClockAddZone(call.arguments)
        case "worldclock_remove_zone": return worldClockRemoveZone(call.arguments)
        // Clipboard
        case "clipboard_recent": return clipboardRecent(call.arguments)
        // Next Meeting
        case "nextmeeting_agenda": return await nextMeetingAgenda()
        // Network
        case "network_status": return await networkStatus()
        // Power
        case "power_status": return await powerStatus()
        default:
            return "Unknown tool \"\(call.name)\"."
        }
    }

    // MARK: - Timers

    private func timerStart(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("timers", TimersPlugin.self) else {
            return unavailable("Timers", "timers")
        }
        let minutes = Self.int(args["minutes"]) ?? 0
        let seconds = Self.int(args["seconds"]) ?? 0
        guard minutes > 0 || seconds > 0 else {
            return "Give a duration in minutes and/or seconds greater than zero."
        }
        let label = (Self.string(args["label"]) ?? "").trimmingCharacters(in: .whitespaces)
        let before = Set(plugin.timers.map(\.id))
        plugin.addCustom(minutes: minutes, seconds: seconds, label: label)
        coordinator.reconcile()
        // Report the new timer's remaining time from the model.
        let started = plugin.timers.first { !before.contains($0.id) }
        let total = TimeInterval(minutes * 60 + seconds)
        let name = started.map { plugin.displayLabel($0) } ?? (label.isEmpty ? "Timer" : label)
        return "Started \u{2018}\(name)\u{2019} for \(TimersPlugin.mmss(total))."
    }

    private func timerList() -> String {
        guard let plugin = enabledPlugin("timers", TimersPlugin.self) else {
            return unavailable("Timers", "timers")
        }
        let now = Date()
        let payload = plugin.timers.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "label": plugin.displayLabel(item),
                "state": item.state.rawValue,
                "remaining": TimersPlugin.mmss(plugin.remaining(item, at: now)),
                "remainingSeconds": Int(plugin.remaining(item, at: now).rounded()),
                "repeats": item.repeats,
            ]
        }
        return Self.json(payload)
    }

    private func timerStop(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("timers", TimersPlugin.self) else {
            return unavailable("Timers", "timers")
        }
        let key = (Self.string(args["timer"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return "A timer label or id is required." }
        let match: TimerItem?
        if let uuid = UUID(uuidString: key) {
            match = plugin.timers.first { $0.id == uuid }
        } else {
            match = plugin.timers.first { plugin.displayLabel($0).caseInsensitiveCompare(key) == .orderedSame }
        }
        guard let target = match else {
            let available = plugin.timers.map { plugin.displayLabel($0) }
            return available.isEmpty
                ? "No timers are running."
                : "No timer matches \"\(key)\". Running: \(available.joined(separator: ", "))."
        }
        let name = plugin.displayLabel(target)
        plugin.delete(target.id)
        coordinator.reconcile()
        return "Stopped timer \u{2018}\(name)\u{2019}."
    }

    // MARK: - Habits

    private func habitList() -> String {
        guard let plugin = enabledPlugin("habits", HabitsPlugin.self) else {
            return unavailable("Habits", "habits")
        }
        let payload = plugin.activeHabits.map { habit -> [String: Any] in
            [
                "id": habit.id.uuidString,
                "name": habit.name,
                "icon": habit.icon,
                "schedule": Self.scheduleText(habit.schedule),
                "doneToday": plugin.isCompletedToday(habit),
                "streak": plugin.currentStreak(habit),
            ]
        }
        return Self.json(payload)
    }

    private func habitAdd(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("habits", HabitsPlugin.self) else {
            return unavailable("Habits", "habits")
        }
        let name = (Self.string(args["name"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "A habit name is required." }
        let iconRaw = (Self.string(args["icon"]) ?? "").trimmingCharacters(in: .whitespaces)
        let icon = iconRaw.isEmpty ? "circle" : iconRaw

        let scheduleKind = (Self.string(args["schedule"]) ?? "daily").lowercased()
        let schedule: Habit.Schedule
        if scheduleKind.hasPrefix("week") {
            let days = Self.parseWeekdays(args["weekdays"])
            guard !days.isEmpty else {
                return "For a weekly schedule, give at least one weekday (e.g. Mon, Wed, Fri)."
            }
            schedule = .weekdays(days)
        } else {
            schedule = .daily
        }

        plugin.addHabit(Habit(name: name, icon: icon, schedule: schedule))
        coordinator.reconcile()
        return "Added habit \u{2018}\(name)\u{2019} (\(Self.scheduleText(schedule)))."
    }

    private func habitComplete(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("habits", HabitsPlugin.self) else {
            return unavailable("Habits", "habits")
        }
        let name = (Self.string(args["name"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "A habit name is required." }
        guard let habit = plugin.activeHabits.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let available = plugin.activeHabits.map(\.name)
            return available.isEmpty
                ? "No habits exist yet."
                : "No habit matches \"\(name)\". Habits: \(available.joined(separator: ", "))."
        }
        if plugin.isCompletedToday(habit) {
            return "\u{2018}\(habit.name)\u{2019} is already marked done today (streak \(plugin.currentStreak(habit)))."
        }
        plugin.toggleToday(habit)
        coordinator.reconcile()
        // Re-read for the fresh streak.
        let streak = plugin.activeHabits.first { $0.id == habit.id }.map { plugin.currentStreak($0) } ?? plugin.currentStreak(habit)
        return "Marked \u{2018}\(habit.name)\u{2019} done today (streak \(streak))."
    }

    // MARK: - Currency

    private func currencyListRates() async -> String {
        guard let plugin = enabledPlugin("currency", CurrencyPlugin.self) else {
            return unavailable("Currency", "currency")
        }
        if plugin.rates.isEmpty { await plugin.refresh() }
        var payload: [String: Any] = ["base": plugin.base]
        payload["pairs"] = plugin.rates.map { rate -> [String: Any] in
            [
                "code": rate.code,
                "rate": rate.rate,
                "changePercent": rate.changePercent,
            ]
        }
        if let err = plugin.lastError { payload["note"] = err }
        return Self.json(payload)
    }

    private func currencyAddPair(_ args: [String: Any]) async -> String {
        guard let plugin = enabledPlugin("currency", CurrencyPlugin.self) else {
            return unavailable("Currency", "currency")
        }
        let code = (Self.string(args["code"]) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return "A currency code is required." }
        guard plugin.addTarget(code) else {
            if code == plugin.base { return "\(code) is already the base currency." }
            return "\(code) is already in the target list."
        }
        await plugin.refresh()
        coordinator.reconcile()
        return "Added \(code) as a target currency (base \(plugin.base))."
    }

    private func currencyRemovePair(_ args: [String: Any]) async -> String {
        guard let plugin = enabledPlugin("currency", CurrencyPlugin.self) else {
            return unavailable("Currency", "currency")
        }
        let code = (Self.string(args["code"]) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return "A currency code is required." }
        guard let idx = plugin.targets.firstIndex(of: code) else {
            let available = plugin.targets.joined(separator: ", ")
            return "\(code) isn't a target. Current targets: \(available.isEmpty ? "none" : available)."
        }
        plugin.removeTargets(at: IndexSet(integer: idx))
        await plugin.refresh()
        coordinator.reconcile()
        return "Removed \(code) from the target currencies."
    }

    private func currencySetBase(_ args: [String: Any]) async -> String {
        guard let plugin = enabledPlugin("currency", CurrencyPlugin.self) else {
            return unavailable("Currency", "currency")
        }
        let code = (Self.string(args["code"]) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return "A currency code is required." }
        guard code != plugin.base else { return "\(code) is already the base currency." }
        plugin.setBase(code)
        await plugin.refresh()
        coordinator.reconcile()
        return "Set the base currency to \(plugin.base)."
    }

    // MARK: - Feeds

    private func feedListUnread() async -> String {
        guard let plugin = enabledPlugin("feeds", FeedsPlugin.self) else {
            return unavailable("Feeds", "feeds")
        }
        if plugin.items.isEmpty { await plugin.refresh() }
        let payload = plugin.unreadItems.map { item -> [String: Any] in
            [
                "title": item.title,
                "source": item.sourceName,
                "link": item.url,
            ]
        }
        return Self.json(payload)
    }

    private func feedAdd(_ args: [String: Any]) async -> String {
        guard let plugin = enabledPlugin("feeds", FeedsPlugin.self) else {
            return unavailable("Feeds", "feeds")
        }
        let url = (Self.string(args["url"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return "A feed URL is required." }
        let name = Self.string(args["name"])?.trimmingCharacters(in: .whitespaces)
        if let error = plugin.addFeed(url: url, name: (name?.isEmpty == false) ? name : nil) {
            return error
        }
        await plugin.refresh()
        coordinator.reconcile()
        return "Added feed \(url)."
    }

    // MARK: - World Clock

    private func worldClockList() -> String {
        guard let plugin = enabledPlugin("worldclock", WorldClockPlugin.self) else {
            return unavailable("World Clock", "worldclock")
        }
        let now = Date()
        let payload = plugin.zones.map { zone -> [String: Any] in
            [
                "zone": zone.id,
                "name": zone.displayName,
                "time": WorldClockPlugin.compactTime(for: zone.id, at: now, use24Hour: plugin.use24Hour),
                "offset": WorldClockPlugin.offsetLabel(for: zone.id, at: now),
                "isHome": zone.id == plugin.homeZone,
            ]
        }
        return Self.json(payload)
    }

    private func worldClockAddZone(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("worldclock", WorldClockPlugin.self) else {
            return unavailable("World Clock", "worldclock")
        }
        let id = (Self.string(args["zone"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return "An IANA time-zone identifier is required." }
        guard TimeZone(identifier: id) != nil else {
            return "\"\(id)\" isn't a valid IANA time-zone identifier (e.g. \"Asia/Tokyo\")."
        }
        if plugin.zones.contains(where: { $0.id == id }) {
            return "\(WorldClockPlugin.cityLabel(for: id)) is already in the list."
        }
        plugin.zones.append(WorldClockZone(id: id))
        coordinator.reconcile()
        return "Added \(WorldClockPlugin.cityLabel(for: id)) (\(id))."
    }

    private func worldClockRemoveZone(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("worldclock", WorldClockPlugin.self) else {
            return unavailable("World Clock", "worldclock")
        }
        let id = (Self.string(args["zone"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return "An IANA time-zone identifier is required." }
        guard plugin.zones.contains(where: { $0.id == id }) else {
            return "\"\(id)\" isn't in the clock list."
        }
        guard id != plugin.homeZone else {
            return "Can't remove the home zone. Set another zone as home first."
        }
        plugin.zones.removeAll { $0.id == id }
        coordinator.reconcile()
        return "Removed \(WorldClockPlugin.cityLabel(for: id)) (\(id))."
    }

    // MARK: - Clipboard

    private func clipboardRecent(_ args: [String: Any]) -> String {
        guard let plugin = enabledPlugin("clipboard", ClipboardPlugin.self) else {
            return unavailable("Clipboard", "clipboard")
        }
        let count = max(1, min(Self.int(args["count"]) ?? 10, 50))
        let formatter = ISO8601DateFormatter()
        let payload = plugin.entries.prefix(count).map { entry -> [String: Any] in
            let text = entry.type == .image ? "[image]" : Self.clip(entry.text, to: 200)
            return [
                "text": text,
                "type": entry.type.rawValue,
                "pinned": entry.pinned,
                "copiedAt": formatter.string(from: entry.timestamp),
            ]
        }
        return Self.json(Array(payload))
    }

    // MARK: - Next Meeting

    private func nextMeetingAgenda() async -> String {
        guard let plugin = enabledPlugin("nextmeeting", NextMeetingPlugin.self) else {
            return unavailable("Next Meeting", "nextmeeting")
        }
        guard plugin.calendarAuthorized else {
            return "Calendar access hasn't been granted. Grant it in the Next Meeting glance's settings."
        }
        await plugin.refresh()
        let formatter = ISO8601DateFormatter()
        func encode(_ event: NextMeetingEvent) -> [String: Any] {
            var dict: [String: Any] = [
                "title": event.title,
                "start": formatter.string(from: event.startDate),
                "when": NextMeetingPlugin.timeRange(event),
                "calendar": event.calendarTitle,
            ]
            if let url = event.meetingURL { dict["meetingURL"] = url.absoluteString }
            return dict
        }
        var payload: [String: Any] = [:]
        if let next = plugin.nextEvent { payload["nextEvent"] = encode(next) }
        payload["today"] = plugin.todayAgenda.map(encode)
        payload["upcoming"] = plugin.upcoming.map(encode)
        if let err = plugin.lastError { payload["note"] = err }
        return Self.json(payload)
    }

    // MARK: - Network

    private func networkStatus() async -> String {
        guard let plugin = enabledPlugin("network", NetworkPlugin.self) else {
            return unavailable("Network", "network")
        }
        await plugin.refresh()
        var payload: [String: Any] = [
            "online": plugin.isOnline,
            "connectionType": plugin.connectionType.label,
        ]
        if let ms = plugin.latencyMs { payload["latencyMs"] = Int(ms.rounded()) }
        if let ip = plugin.publicIP { payload["publicIP"] = ip }
        if let gw = plugin.gatewayIP { payload["gatewayIP"] = gw }
        if let vpn = plugin.vpnInterface { payload["vpn"] = vpn.name }
        if let wifi = plugin.wifi {
            var w: [String: Any] = ["bars": wifi.bars]
            if let ssid = wifi.ssid { w["ssid"] = ssid }
            if let rssi = wifi.rssi { w["rssi"] = rssi }
            payload["wifi"] = w
        }
        payload["interfaces"] = plugin.interfaces.map { ["name": $0.name, "ipv4": $0.ipv4, "vpn": $0.isVPN] as [String: Any] }
        if let err = plugin.lastError { payload["note"] = err }
        return Self.json(payload)
    }

    // MARK: - Power

    private func powerStatus() async -> String {
        guard let plugin = enabledPlugin("power", PowerPlugin.self) else {
            return unavailable("Power", "power")
        }
        await plugin.refresh()
        let snap = plugin.snapshot
        guard snap.hasBattery else {
            return Self.json(["hasBattery": false])
        }
        var payload: [String: Any] = [
            "hasBattery": true,
            "state": Self.chargeStateText(snap.state),
            "powerSource": Self.powerSourceText(snap.powerSource),
            "healthDegraded": snap.healthIsDegraded,
        ]
        if let pct = snap.percentage { payload["percentage"] = pct }
        if let health = snap.healthPercent { payload["healthPercent"] = health }
        if let cycles = snap.cycleCount { payload["cycleCount"] = cycles }
        if let temp = snap.temperatureC { payload["temperatureC"] = temp }
        if let cond = snap.condition { payload["condition"] = cond }
        if let watts = snap.adapterWatts { payload["adapterWatts"] = watts }
        if let toEmpty = snap.timeToEmptyMinutes { payload["minutesToEmpty"] = toEmpty }
        if let toFull = snap.timeToFullMinutes { payload["minutesToFull"] = toFull }
        return Self.json(payload)
    }

    // MARK: - Plugin resolution

    /// The concrete plugin for `id`, but only when the user has the glance
    /// enabled. Returns `nil` when the glance is missing or disabled; callers
    /// pair this with `unavailable(_:_:)` for the message.
    private func enabledPlugin<T>(_ id: String, _ type: T.Type) -> T? {
        guard registry.isEnabled(id) else { return nil }
        return registry.plugin(id: id) as? T
    }

    /// A friendly explanation for why `enabledPlugin` returned nil.
    private func unavailable(_ label: String, _ id: String) -> String {
        if registry.plugin(id: id) == nil {
            return "The \(label) glance isn't available in this build."
        }
        if !registry.isEnabled(id) {
            return "The \(label) glance is turned off. Enable it (e.g. via enable_tool with id \"\(id)\") to use this."
        }
        return "The \(label) glance isn't available."
    }

    // MARK: - Schema builders

    private static func objectSchema(_ properties: [String: Any],
                                     required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func numberProperty(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func stringArrayProperty(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }

    // MARK: - Argument helpers

    /// Coerce a JSON value to a String (accepts strings and numbers).
    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// Coerce a JSON value to an Int (accepts numbers and numeric strings).
    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Coerce a JSON value to `[Any]`-of-strings/ints for weekday parsing.
    private static func rawArray(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let single = value { return [single] }
        return []
    }

    /// Parse a mixed list of weekday names ("Mon") and/or numbers (1=Sun…7=Sat)
    /// into the day-number set `Habit.Schedule.weekdays` expects.
    private static func parseWeekdays(_ value: Any?) -> Set<Int> {
        let names: [String: Int] = [
            "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
        ]
        var result = Set<Int>()
        for element in rawArray(value) {
            if let n = int(element), (1...7).contains(n) {
                result.insert(n)
            } else if let s = string(element) {
                let key = String(s.trimmingCharacters(in: .whitespaces).lowercased().prefix(3))
                if let n = names[key] { result.insert(n) }
            }
        }
        return result
    }

    // MARK: - Formatting helpers

    private static func scheduleText(_ schedule: Habit.Schedule) -> String {
        switch schedule {
        case .daily:
            return "daily"
        case .weekdays(let days):
            let order: [(Int, String)] = [
                (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"),
            ]
            let labels = order.filter { days.contains($0.0) }.map(\.1)
            return labels.isEmpty ? "no days" : labels.joined(separator: " ")
        }
    }

    private static func chargeStateText(_ state: PowerMetrics.ChargeState) -> String {
        switch state {
        case .charging: return "charging"
        case .charged: return "charged"
        case .discharging: return "discharging"
        case .unknown: return "unknown"
        }
    }

    private static func powerSourceText(_ source: PowerMetrics.PowerSource) -> String {
        switch source {
        case .ac: return "ac"
        case .battery: return "battery"
        case .unknown: return "unknown"
        }
    }

    /// Flatten newlines and cap a string for compact list output.
    private static func clip(_ text: String, to limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "\u{2026}"
    }

    /// Serialize a JSON-compatible value to a compact string, with a readable
    /// fallback so a serialization failure never surfaces as a crash.
    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return string
    }
}
