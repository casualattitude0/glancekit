import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// A rich, standalone world-clock glance.
///
/// Goes beyond a plain list of times: each zone shows a live-ticking clock, its
/// GMT offset, a day/night indicator, a Today/Tomorrow/Yesterday marker and the
/// hour difference relative to the home zone. Each clock can carry a custom
/// label ("HQ" instead of "New York"). A meeting-planner strip tints the next
/// ~12 hours green where they land inside working hours (09:00–17:59) in each
/// zone, and a scrubbable reference line lets you pick any instant (now ± hours)
/// and read it in every zone at once. Zones are searchable, re-orderable,
/// deletable and re-labelable, and one is marked "home".
///
/// Everything is local computation — no network, no secrets. Views tick
/// themselves off a single shared `Timer.publish`, so `refreshInterval` is 0.
/// All zone maths goes through `TimeZone`/`Calendar` for the relevant instant,
/// so DST transitions are handled correctly — no fixed offsets are ever assumed.
@MainActor
@Observable
final class WorldClockPlugin: GlancePlugin {
    nonisolated var id: String { "worldclock" }
    nonisolated var title: String { "World Clock" }
    nonisolated var iconSystemName: String { "globe" }
    var refreshInterval: TimeInterval { 0 }

    var preferredToolWindowSize: CGSize? { CGSize(width: 380, height: 520) }

    // MARK: Persisted state

    /// Ordered list of zones shown in the glance. Each carries an IANA
    /// identifier and an optional user-supplied label.
    var zones: [WorldClockZone] {
        didSet { persistZones() }
    }

    /// The zone identifier treated as "home" — highlighted, and the baseline for
    /// the Today/Tomorrow/Yesterday day markers and the hour-difference labels.
    var homeZone: String {
        didSet { UserDefaults.standard.set(homeZone, forKey: Self.homeKey) }
    }

    /// Show times in 24-hour form when true, 12-hour (with AM/PM) when false.
    var use24Hour: Bool {
        didSet { UserDefaults.standard.set(use24Hour, forKey: Self.use24Key) }
    }

    /// Detailed rows show offset, difference, day marker and seconds; compact
    /// rows show just the name and time on a single line.
    var detailedView: Bool {
        didSet { UserDefaults.standard.set(detailedView, forKey: Self.detailedKey) }
    }

    private static let zonesKey = "glancekit.worldclock.zones"
    private static let homeKey = "glancekit.worldclock.home"
    private static let use24Key = "glancekit.worldclock.use24hour"
    private static let detailedKey = "glancekit.worldclock.detailed"

    init() {
        let home = UserDefaults.standard.string(forKey: Self.homeKey)
            ?? TimeZone.current.identifier
        homeZone = home

        if let loaded = Self.loadZones(), !loaded.isEmpty {
            zones = loaded
        } else {
            // A sensible default spread, always including the user's home zone.
            var ids = [home, "America/Los_Angeles", "America/New_York",
                       "Europe/London", "Asia/Tokyo"]
            // De-dupe while preserving order.
            var seen = Set<String>()
            ids = ids.filter { seen.insert($0).inserted }
            zones = ids.map { WorldClockZone(id: $0) }
        }

        use24Hour = UserDefaults.standard.object(forKey: Self.use24Key) as? Bool ?? false
        detailedView = UserDefaults.standard.object(forKey: Self.detailedKey) as? Bool ?? true

        // Normalise storage: rewrite the (possibly migrated-from-[String]) list
        // in the current Codable representation so old data is durable.
        persistZones()
    }

    // MARK: Persistence

    private func persistZones() {
        if let data = try? JSONEncoder().encode(zones) {
            UserDefaults.standard.set(data, forKey: Self.zonesKey)
        }
    }

    /// Loads the zone list, migrating the legacy plain `[String]` representation
    /// (bare IANA identifiers) into the labelled `WorldClockZone` model.
    private static func loadZones() -> [WorldClockZone]? {
        let ud = UserDefaults.standard
        // New format: JSON-encoded [WorldClockZone].
        if let data = ud.data(forKey: zonesKey),
           let decoded = try? JSONDecoder().decode([WorldClockZone].self, from: data) {
            return decoded.isEmpty ? nil : decoded
        }
        // Legacy format: a plain array of IANA identifier strings.
        if let legacy = ud.stringArray(forKey: zonesKey), !legacy.isEmpty {
            return legacy.map { WorldClockZone(id: $0) }
        }
        return nil
    }

    // MARK: GlancePlugin

    /// Purely local — nothing to fetch. Kept trivial and crash-free: it just
    /// ensures the home zone is present in the list.
    func refresh() async {
        if !zones.contains(where: { $0.id == homeZone }) {
            zones.insert(WorldClockZone(id: homeZone), at: 0)
        }
    }

    /// Ambient by nature: shows the home time plus one other zone, e.g.
    /// "Tokyo 23:14 · London 14:14". Never shouts.
    func currentSignal() -> GlanceSignal? {
        guard !zones.isEmpty else { return nil }
        let now = Date()
        let homeText = WorldClockPlugin.compactTime(for: homeZone, at: now, use24Hour: use24Hour)
        let homeName = zones.first(where: { $0.id == homeZone })?.displayName
            ?? WorldClockPlugin.cityLabel(for: homeZone)

        // Pick the first zone that isn't home, if any.
        if let other = zones.first(where: { $0.id != homeZone }) {
            let otherText = WorldClockPlugin.compactTime(for: other.id, at: now, use24Hour: use24Hour)
            return GlanceSignal(
                priority: .ambient,
                score: 0,
                headline: "\(other.displayName) \(otherText) · \(homeName) \(homeText)",
                systemImage: iconSystemName
            )
        }
        return GlanceSignal(
            priority: .ambient,
            score: 0,
            headline: "\(homeName) \(homeText)",
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

    /// GMT offset label, e.g. "GMT+9" or "GMT+5:30", computed for `date` so DST
    /// is reflected.
    nonisolated static func offsetLabel(for identifier: String, at date: Date) -> String {
        let tz = TimeZone(identifier: identifier) ?? .current
        let seconds = tz.secondsFromGMT(for: date)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        return minutes == 0
            ? String(format: "GMT%+d", hours)
            : String(format: "GMT%+d:%02d", hours, minutes)
    }

    /// Hour(-and-minute) difference of a zone relative to home, computed at
    /// `date` so it stays correct across DST changes on either side.
    /// Returns e.g. "+8h", "-5:30", or "same".
    nonisolated static func differenceLabel(for identifier: String, relativeTo home: String, at date: Date) -> String {
        let tz = TimeZone(identifier: identifier) ?? .current
        let homeTz = TimeZone(identifier: home) ?? .current
        let diff = tz.secondsFromGMT(for: date) - homeTz.secondsFromGMT(for: date)
        if diff == 0 { return "same" }
        let sign = diff > 0 ? "+" : "-"
        let hours = abs(diff) / 3600
        let minutes = (abs(diff) / 60) % 60
        return minutes == 0
            ? "\(sign)\(hours)h"
            : "\(sign)\(hours):\(String(format: "%02d", minutes))"
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

// MARK: - Model

/// A configured clock: an IANA time-zone identifier plus an optional custom
/// label. Codable so the list persists; the legacy `[String]` form is migrated
/// on load in `WorldClockPlugin.loadZones()`.
struct WorldClockZone: Codable, Identifiable, Equatable, Hashable {
    /// IANA identifier, e.g. "America/New_York". Also serves as the stable
    /// identity for `ForEach` (duplicates are guarded against on add).
    var id: String
    /// Optional user-supplied label shown instead of the derived city name.
    var label: String?

    init(id: String, label: String? = nil) {
        self.id = id
        self.label = label
    }

    /// Trimmed custom label when non-empty, otherwise the derived city name.
    var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label.trimmingCharacters(in: .whitespaces)
        }
        return WorldClockPlugin.cityLabel(for: id)
    }
}

// MARK: - Clipboard

@MainActor
private func worldClockCopyToPasteboard(_ string: String) {
    #if canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
    #endif
}

// MARK: - Popover UI

private struct WorldClockPopover: View {
    @Bindable var plugin: WorldClockPlugin
    @State private var now = Date()
    /// Reference offset in hours for the meeting-planner scrubber (now ± hours).
    @State private var referenceOffset: Double = 0

    // One shared ticker for the whole popover — rows read `now` from here.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var orderedZones: [WorldClockZone] {
        // Home first, then the rest in configured order.
        let rest = plugin.zones.filter { $0.id != plugin.homeZone }
        if let home = plugin.zones.first(where: { $0.id == plugin.homeZone }) {
            return [home] + rest
        }
        return plugin.zones
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plugin.zones.isEmpty {
                Text("No clocks yet — add a city in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Button {
                        plugin.detailedView.toggle()
                    } label: {
                        Image(systemName: plugin.detailedView
                              ? "rectangle.compress.vertical"
                              : "rectangle.expand.vertical")
                    }
                    .buttonStyle(.borderless)
                    .help(plugin.detailedView ? "Compact view" : "Detailed view")
                }

                ForEach(orderedZones) { zone in
                    WorldClockClockRow(
                        zone: zone,
                        homeZone: plugin.homeZone,
                        isHome: zone.id == plugin.homeZone,
                        use24Hour: plugin.use24Hour,
                        detailed: plugin.detailedView,
                        now: now
                    )
                }

                Divider()

                WorldClockMeetingPlanner(
                    zones: orderedZones,
                    homeZone: plugin.homeZone,
                    use24Hour: plugin.use24Hour,
                    now: now,
                    referenceOffset: $referenceOffset
                )
            }
        }
        .onReceive(ticker) { now = $0 }
    }
}

/// A single clock row: day/night icon, name (+ optional custom label), offset,
/// day marker, difference from home, and the live time. Tap to copy the time.
private struct WorldClockClockRow: View {
    let zone: WorldClockZone
    let homeZone: String
    let isHome: Bool
    let use24Hour: Bool
    let detailed: Bool
    let now: Date

    @State private var copied = false

    private var timeText: String {
        let tz = TimeZone(identifier: zone.id) ?? .current
        let f = DateFormatter()
        f.timeZone = tz
        if detailed {
            f.dateFormat = use24Hour ? "HH:mm:ss" : "h:mm:ss a"
        } else {
            f.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        }
        return f.string(from: now)
    }

    private var isDay: Bool { WorldClockPlugin.isDaytime(for: zone.id, at: now) }

    private var dayMarker: String? {
        let delta = WorldClockPlugin.dayDelta(for: zone.id, relativeTo: homeZone, at: now)
        return WorldClockPlugin.dayMarker(delta: delta)
    }

    private func copyNow() {
        let compact = WorldClockPlugin.compactTime(for: zone.id, at: now, use24Hour: use24Hour)
        worldClockCopyToPasteboard("\(zone.displayName) \(compact)")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDay ? "sun.max.fill" : "moon.fill")
                .font(.callout)
                .foregroundStyle(isDay ? .yellow : .indigo)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(zone.displayName)
                        .font(.body.weight(isHome ? .semibold : .regular))
                        .lineLimit(1)
                    if isHome {
                        Text("HOME")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                if detailed {
                    HStack(spacing: 6) {
                        Text(WorldClockPlugin.offsetLabel(for: zone.id, at: now))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !isHome {
                            Text(WorldClockPlugin.differenceLabel(for: zone.id, relativeTo: homeZone, at: now))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        if let marker = dayMarker {
                            Text(marker)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Spacer()

            if copied {
                Label("Copied", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Text(timeText)
                    .font(.body.monospacedDigit().weight(isHome ? .semibold : .regular))
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, isHome ? 6 : 0)
        .background(
            isHome
                ? AnyView(RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.08)))
                : AnyView(Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { copyNow() }
        .help("Tap to copy this zone's time")
    }
}

/// Meeting-planner section. Two parts:
///  1. A **scrubber** (slider + steppers + Now) that picks a reference instant
///     `now + referenceOffset` and shows what it is in every zone — so you can
///     plan "if we meet at 3pm my time, it's X there", DST included.
///  2. The existing static **working-hours strip**: a row per zone over the next
///     12 hours, cells tinted green inside working hours (09:00–17:59). The
///     column matching the scrubber's reference hour is highlighted.
private struct WorldClockMeetingPlanner: View {
    let zones: [WorldClockZone]
    let homeZone: String
    let use24Hour: Bool
    let now: Date
    @Binding var referenceOffset: Double

    private let hoursAhead = 12
    private let minOffset: Double = -12
    private let maxOffset: Double = 24

    private var referenceDate: Date {
        now.addingTimeInterval(referenceOffset * 3600)
    }

    /// Column in the working-hours strip that lines up with the reference hour,
    /// or nil when the reference falls outside the visible 12-hour window.
    private var highlightColumn: Int? {
        let col = Int(referenceOffset.rounded())
        return (0..<hoursAhead).contains(col) ? col : nil
    }

    private func isWorkingHour(_ hour: Int) -> Bool {
        hour >= 9 && hour < 18
    }

    private var homeReferenceText: String {
        WorldClockPlugin.compactTime(for: homeZone, at: referenceDate, use24Hour: use24Hour)
    }

    private var homeDisplayName: String {
        zones.first(where: { $0.id == homeZone })?.displayName
            ?? WorldClockPlugin.cityLabel(for: homeZone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // MARK: Scrubber
            HStack {
                Text("Plan a time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(offsetLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button {
                    referenceOffset = max(minOffset, referenceOffset - 1)
                } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless)

                Slider(value: $referenceOffset, in: minOffset...maxOffset, step: 1)

                Button {
                    referenceOffset = min(maxOffset, referenceOffset + 1)
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)

                Button("Now") { referenceOffset = 0 }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .disabled(referenceOffset == 0)
            }

            // Reference readout: the picked instant in each zone.
            Text("\(homeReferenceText) in \(homeDisplayName):")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(zones) { zone in
                referenceRow(zone)
            }

            Divider().padding(.vertical, 2)

            // MARK: Working-hours strip (next 12h)
            Text("Working hours — next 12h")
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
                        .foregroundStyle(highlightColumn == offset ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(zones) { zone in
                stripRow(zone)
            }
        }
    }

    private var offsetLabel: String {
        if referenceOffset == 0 { return "Now" }
        return String(format: "%@%dh", referenceOffset > 0 ? "+" : "-", Int(abs(referenceOffset)))
    }

    private func referenceRow(_ zone: WorldClockZone) -> some View {
        let refTime = WorldClockPlugin.compactTime(for: zone.id, at: referenceDate, use24Hour: use24Hour)
        let delta = WorldClockPlugin.dayDelta(for: zone.id, relativeTo: homeZone, at: referenceDate)
        let marker = WorldClockPlugin.dayMarker(delta: delta)
        return HStack(spacing: 6) {
            Text(zone.displayName)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            Text(refTime)
                .font(.system(size: 10).monospacedDigit().weight(.medium))
            if let marker {
                Text(marker)
                    .font(.system(size: 9).weight(.medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if zone.id != homeZone {
                Text(WorldClockPlugin.differenceLabel(for: zone.id, relativeTo: homeZone, at: referenceDate))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stripRow(_ zone: WorldClockZone) -> some View {
        HStack(spacing: 2) {
            Text(zone.displayName)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 52, alignment: .leading)
            ForEach(0..<hoursAhead, id: \.self) { offset in
                stripCell(zone: zone, offset: offset)
            }
        }
    }

    private func stripCell(zone: WorldClockZone, offset: Int) -> some View {
        let date = now.addingTimeInterval(TimeInterval(offset) * 3600)
        let hour = WorldClockPlugin.localHour(for: zone.id, at: date)
        let working = isWorkingHour(hour)
        return RoundedRectangle(cornerRadius: 2)
            .fill(working ? Color.green.opacity(0.55) : Color.gray.opacity(0.15))
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .overlay(cellOverlay(offset: offset, hour: hour))
    }

    @ViewBuilder
    private func cellOverlay(offset: Int, hour: Int) -> some View {
        if highlightColumn == offset {
            RoundedRectangle(cornerRadius: 2).stroke(.tint, lineWidth: 1.5)
        } else if hour == 0 {
            RoundedRectangle(cornerRadius: 2).stroke(.orange.opacity(0.6), lineWidth: 1)
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

    private func isAdded(_ id: String) -> Bool {
        plugin.zones.contains(where: { $0.id == id })
    }

    /// Two-way binding to a zone's custom label by identifier. Writing back
    /// mutates the array element, which triggers the `zones` observer and
    /// persists — empty strings clear the label.
    private func labelBinding(for zoneID: String) -> Binding<String> {
        Binding(
            get: { plugin.zones.first(where: { $0.id == zoneID })?.label ?? "" },
            set: { newValue in
                guard let idx = plugin.zones.firstIndex(where: { $0.id == zoneID }) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                plugin.zones[idx].label = trimmed.isEmpty ? nil : newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clock display")
                .font(.headline)
            Toggle("Use 24-hour time", isOn: $plugin.use24Hour)
            Toggle("Detailed rows (offset, difference, seconds)", isOn: $plugin.detailedView)

            Divider()

            Text("Add a city")
                .font(.headline)
            TextField("Search time zones (e.g. Tokyo, Paris)…", text: $query)
                .textFieldStyle(.roundedBorder)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.self) { id in
                        Button {
                            if !isAdded(id) {
                                plugin.zones.append(WorldClockZone(id: id))
                            }
                            query = ""
                        } label: {
                            HStack {
                                Text(WorldClockPlugin.cityLabel(for: id))
                                Text(id).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if isAdded(id) {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                } else {
                                    Image(systemName: "plus.circle")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdded(id))
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            Text("Your clocks")
                .font(.headline)
            Text("Drag to reorder. Rename a clock to give it a custom label. The home zone anchors the day markers.")
                .font(.caption).foregroundStyle(.secondary)

            if plugin.zones.isEmpty {
                Text("No cities added yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(plugin.zones) { zone in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField(WorldClockPlugin.cityLabel(for: zone.id),
                                          text: labelBinding(for: zone.id))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                                Text("\(WorldClockPlugin.cityLabel(for: zone.id)) · \(WorldClockPlugin.offsetLabel(for: zone.id, at: Date()))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if zone.id == plugin.homeZone {
                                Text("HOME")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tint)
                            } else {
                                Button("Set home") { plugin.homeZone = zone.id }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    plugin.zones.removeAll { $0.id == zone.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this clock")
                            }
                        }
                    }
                    .onMove { indices, newOffset in
                        plugin.zones.move(fromOffsets: indices, toOffset: newOffset)
                    }
                    .onDelete { offsets in
                        // Never delete the home zone out from under the day markers.
                        let removable = offsets.filter { plugin.zones[$0].id != plugin.homeZone }
                        plugin.zones.remove(atOffsets: IndexSet(removable))
                    }
                }
                .frame(minHeight: 180)
                .listStyle(.inset)
            }
        }
    }
}
