import SwiftUI
import Observation

/// A rich, standalone world-clock glance.
///
/// Goes beyond a plain list of times: each zone shows a live-ticking clock, its
/// GMT offset, a day/night indicator, and a Today/Tomorrow/Yesterday marker
/// relative to the home zone. A meeting-planner strip tints the next ~12 hours
/// green where they land inside working hours (09:00–17:59) in each zone, so
/// overlapping availability is visible at a glance. Zones are searchable,
/// re-orderable, and deletable, and one is marked "home".
///
/// Everything is local computation — no network, no secrets. Views tick
/// themselves off a single shared `Timer.publish`, so `refreshInterval` is 0.
@MainActor
@Observable
final class WorldClockPlugin: GlancePlugin {
    nonisolated var id: String { "worldclock" }
    nonisolated var title: String { "World Clock" }
    nonisolated var iconSystemName: String { "globe" }
    var refreshInterval: TimeInterval { 0 }

    var preferredToolWindowSize: CGSize? { CGSize(width: 380, height: 460) }

    // MARK: Persisted state

    /// Ordered list of IANA zone identifiers shown in the glance.
    var zones: [String] {
        didSet { UserDefaults.standard.set(zones, forKey: Self.zonesKey) }
    }

    /// The zone treated as "home" — highlighted, and the baseline for the
    /// Today/Tomorrow/Yesterday day markers.
    var homeZone: String {
        didSet { UserDefaults.standard.set(homeZone, forKey: Self.homeKey) }
    }

    /// Show times in 24-hour form when true, 12-hour (with AM/PM) when false.
    var use24Hour: Bool {
        didSet { UserDefaults.standard.set(use24Hour, forKey: Self.use24Key) }
    }

    private static let zonesKey = "glancekit.worldclock.zones"
    private static let homeKey = "glancekit.worldclock.home"
    private static let use24Key = "glancekit.worldclock.use24hour"

    init() {
        let home = UserDefaults.standard.string(forKey: Self.homeKey)
            ?? TimeZone.current.identifier
        homeZone = home

        if let saved = UserDefaults.standard.stringArray(forKey: Self.zonesKey), !saved.isEmpty {
            zones = saved
        } else {
            // A sensible default spread, always including the user's home zone.
            var defaults = [home, "America/Los_Angeles", "America/New_York",
                            "Europe/London", "Asia/Tokyo"]
            // De-dupe while preserving order.
            var seen = Set<String>()
            defaults = defaults.filter { seen.insert($0).inserted }
            zones = defaults
        }

        use24Hour = UserDefaults.standard.object(forKey: Self.use24Key) as? Bool ?? false
    }

    // MARK: GlancePlugin

    /// Purely local — nothing to fetch. Kept trivial and crash-free: it just
    /// ensures the home zone is present in the list.
    func refresh() async {
        if !zones.contains(homeZone) {
            zones.insert(homeZone, at: 0)
        }
    }

    /// Ambient by nature: shows the home time plus one other zone, e.g.
    /// "Tokyo 23:14 · London 14:14". Never shouts.
    func currentSignal() -> GlanceSignal? {
        guard !zones.isEmpty else { return nil }
        let now = Date()
        let homeText = WorldClockPlugin.compactTime(for: homeZone, at: now, use24Hour: use24Hour)
        let homeCity = WorldClockPlugin.cityLabel(for: homeZone)

        // Pick the first zone that isn't home, if any.
        if let other = zones.first(where: { $0 != homeZone }) {
            let otherText = WorldClockPlugin.compactTime(for: other, at: now, use24Hour: use24Hour)
            let otherCity = WorldClockPlugin.cityLabel(for: other)
            return GlanceSignal(
                priority: .ambient,
                score: 0,
                headline: "\(otherCity) \(otherText) · \(homeCity) \(homeText)",
                systemImage: iconSystemName
            )
        }
        return GlanceSignal(
            priority: .ambient,
            score: 0,
            headline: "\(homeCity) \(homeText)",
            systemImage: iconSystemName
        )
    }

    func popoverSection() -> AnyView {
        AnyView(WorldClockPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(WorldClockSettings(plugin: self))
    }

    // MARK: Shared formatting helpers (nonisolated so views can reuse them)

    /// City label derived from the last path component of an IANA identifier,
    /// with underscores turned into spaces (e.g. "America/New_York" → "New York").
    nonisolated static func cityLabel(for identifier: String) -> String {
        let comps = identifier.split(separator: "/")
        return comps.last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
    }

    /// Compact time string for the signal/headline.
    nonisolated static func compactTime(for identifier: String, at date: Date, use24Hour: Bool) -> String {
        let tz = TimeZone(identifier: identifier) ?? .current
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        return f.string(from: date)
    }

    /// GMT offset label, e.g. "GMT+9" or "GMT+5:30".
    nonisolated static func offsetLabel(for identifier: String, at date: Date) -> String {
        let tz = TimeZone(identifier: identifier) ?? .current
        let seconds = tz.secondsFromGMT(for: date)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        return minutes == 0
            ? String(format: "GMT%+d", hours)
            : String(format: "GMT%+d:%02d", hours, minutes)
    }

    /// The local hour (0…23) in a zone at a given instant.
    nonisolated static func localHour(for identifier: String, at date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier) ?? .current
        return cal.component(.hour, from: date)
    }

    /// Simple day/night from the local hour: 6:00–18:59 is day.
    nonisolated static func isDaytime(for identifier: String, at date: Date) -> Bool {
        let hour = localHour(for: identifier, at: date)
        return hour >= 6 && hour < 19
    }

    /// Day rollover of a zone relative to the home zone: -1, 0 or +1.
    nonisolated static func dayDelta(for identifier: String, relativeTo home: String, at date: Date) -> Int {
        func dayNumber(_ id: String) -> Int {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: id) ?? .current
            let c = cal.dateComponents([.year, .month, .day], from: date)
            // Encode Y/M/D into a comparable ordinal via day count from a fixed ref.
            let refComps = DateComponents(year: c.year, month: c.month, day: c.day)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            let d = utc.date(from: refComps) ?? date
            return Int(d.timeIntervalSince1970 / 86_400)
        }
        return dayNumber(identifier) - dayNumber(home)
    }

    nonisolated static func dayMarker(delta: Int) -> String? {
        switch delta {
        case 0: return nil
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let d where d > 1: return "+\(d) days"
        default: return "\(delta) days"
        }
    }
}

// MARK: - Popover UI

private struct WorldClockPopover: View {
    let plugin: WorldClockPlugin
    @State private var now = Date()

    // One shared ticker for the whole popover — rows read `now` from here.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var orderedZones: [String] {
        // Home first, then the rest in configured order.
        let rest = plugin.zones.filter { $0 != plugin.homeZone }
        return plugin.zones.contains(plugin.homeZone) ? [plugin.homeZone] + rest : plugin.zones
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plugin.zones.isEmpty {
                Text("No clocks yet — add a city in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(orderedZones, id: \.self) { zone in
                    WorldClockClockRow(
                        zoneIdentifier: zone,
                        homeZone: plugin.homeZone,
                        isHome: zone == plugin.homeZone,
                        use24Hour: plugin.use24Hour,
                        now: now
                    )
                }

                Divider()

                WorldClockMeetingPlanner(
                    zones: orderedZones,
                    homeZone: plugin.homeZone,
                    now: now
                )
            }
        }
        .onReceive(ticker) { now = $0 }
    }
}

/// A single clock row: city, offset, day/night icon, day marker, and time.
private struct WorldClockClockRow: View {
    let zoneIdentifier: String
    let homeZone: String
    let isHome: Bool
    let use24Hour: Bool
    let now: Date

    private var timeText: String {
        let tz = TimeZone(identifier: zoneIdentifier) ?? .current
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = use24Hour ? "HH:mm:ss" : "h:mm:ss a"
        return f.string(from: now)
    }

    private var isDay: Bool { WorldClockPlugin.isDaytime(for: zoneIdentifier, at: now) }

    private var dayMarker: String? {
        let delta = WorldClockPlugin.dayDelta(for: zoneIdentifier, relativeTo: homeZone, at: now)
        return WorldClockPlugin.dayMarker(delta: delta)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDay ? "sun.max.fill" : "moon.fill")
                .font(.callout)
                .foregroundStyle(isDay ? .yellow : .indigo)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(WorldClockPlugin.cityLabel(for: zoneIdentifier))
                        .font(.body.weight(isHome ? .semibold : .regular))
                    if isHome {
                        Text("HOME")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 6) {
                    Text(WorldClockPlugin.offsetLabel(for: zoneIdentifier, at: now))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let marker = dayMarker {
                        Text(marker)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Text(timeText)
                .font(.body.monospacedDigit().weight(isHome ? .semibold : .regular))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, isHome ? 6 : 0)
        .background(
            isHome
                ? AnyView(RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.08)))
                : AnyView(Color.clear)
        )
    }
}

/// Meeting-planner strip: a row per zone, columns are the next 12 hours starting
/// from the current hour. Cells inside working hours (09:00–17:59) are tinted
/// green so overlapping availability across zones is easy to spot.
private struct WorldClockMeetingPlanner: View {
    let zones: [String]
    let homeZone: String
    let now: Date

    private let hoursAhead = 12

    private func isWorkingHour(_ hour: Int) -> Bool {
        hour >= 9 && hour < 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meeting planner — next 12h")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Header row: home-zone hours as the reference timeline.
            HStack(spacing: 2) {
                Text("")
                    .frame(width: 52, alignment: .leading)
                ForEach(0..<hoursAhead, id: \.self) { offset in
                    let date = now.addingTimeInterval(TimeInterval(offset) * 3600)
                    let hour = WorldClockPlugin.localHour(for: homeZone, at: date)
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(zones, id: \.self) { zone in
                HStack(spacing: 2) {
                    Text(WorldClockPlugin.cityLabel(for: zone))
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 52, alignment: .leading)

                    ForEach(0..<hoursAhead, id: \.self) { offset in
                        let date = now.addingTimeInterval(TimeInterval(offset) * 3600)
                        let hour = WorldClockPlugin.localHour(for: zone, at: date)
                        let working = isWorkingHour(hour)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(working ? Color.green.opacity(0.55) : Color.gray.opacity(0.15))
                            .frame(height: 14)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                hour == 0
                                    ? RoundedRectangle(cornerRadius: 2).stroke(.orange.opacity(0.6), lineWidth: 1)
                                    : nil
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Settings UI

private struct WorldClockSettings: View {
    @Bindable var plugin: WorldClockPlugin
    @State private var query: String = ""

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return TimeZone.knownTimeZoneIdentifiers
            .filter { id in
                let last = id.split(separator: "/").last.map(String.init) ?? id
                return id.lowercased().contains(q)
                    || last.replacingOccurrences(of: "_", with: " ").lowercased().contains(q)
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clock display")
                .font(.headline)
            Toggle("Use 24-hour time", isOn: $plugin.use24Hour)

            Divider()

            Text("Add a city")
                .font(.headline)
            TextField("Search time zones (e.g. Tokyo, Paris)…", text: $query)
                .textFieldStyle(.roundedBorder)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.self) { id in
                        Button {
                            if !plugin.zones.contains(id) {
                                plugin.zones.append(id)
                            }
                            query = ""
                        } label: {
                            HStack {
                                Text(WorldClockPlugin.cityLabel(for: id))
                                Text(id).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if plugin.zones.contains(id) {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                } else {
                                    Image(systemName: "plus.circle")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            Text("Your clocks")
                .font(.headline)
            Text("Drag to reorder. The home zone anchors the day markers.")
                .font(.caption).foregroundStyle(.secondary)

            if plugin.zones.isEmpty {
                Text("No cities added yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(plugin.zones, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(WorldClockPlugin.cityLabel(for: id))
                                Text(WorldClockPlugin.offsetLabel(for: id, at: Date()))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if id == plugin.homeZone {
                                Text("HOME")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tint)
                            } else {
                                Button("Set home") { plugin.homeZone = id }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .onMove { indices, newOffset in
                        plugin.zones.move(fromOffsets: indices, toOffset: newOffset)
                    }
                    .onDelete { offsets in
                        // Never delete the home zone out from under the day markers.
                        let removable = offsets.filter { plugin.zones[$0] != plugin.homeZone }
                        plugin.zones.remove(atOffsets: IndexSet(removable))
                    }
                }
                .frame(minHeight: 160)
                .listStyle(.inset)
            }
        }
    }
}
