import Foundation

/// Shared derivations for time-zone display labels, so the World Clock glance
/// (and any future consumer) computes city names and GMT offsets one way
/// instead of reimplementing the same math.
enum TimeZoneLabel {
    /// City label from the last path component of an IANA identifier, with
    /// underscores turned into spaces (e.g. "America/New_York" → "New York").
    static func city(for identifier: String) -> String {
        let comps = identifier.split(separator: "/")
        return comps.last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
    }

    /// GMT offset label computed for `date` so DST is reflected,
    /// e.g. "GMT+9" or "GMT+5:30".
    static func gmtOffset(for identifier: String, at date: Date) -> String {
        let tz = TimeZone(identifier: identifier) ?? .current
        let seconds = tz.secondsFromGMT(for: date)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        return minutes == 0
            ? String(format: "GMT%+d", hours)
            : String(format: "GMT%+d:%02d", hours, minutes)
    }
}
