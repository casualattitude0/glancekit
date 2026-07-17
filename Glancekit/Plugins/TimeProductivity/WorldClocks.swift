import SwiftUI

/// A single row showing the live time in a given time zone. Ticks itself via
/// a local `Timer` — independent of the plugin's `refresh()` cadence.
struct TimeProdClockRow: View {
    let zoneIdentifier: String
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeZone: TimeZone {
        TimeZone(identifier: zoneIdentifier) ?? .current
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: now)
    }

    private var cityLabel: String {
        let comps = zoneIdentifier.split(separator: "/")
        return comps.last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zoneIdentifier
    }

    private var offsetLabel: String {
        let seconds = timeZone.secondsFromGMT(for: now)
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        return minutes == 0 ? String(format: "GMT%+d", hours) : String(format: "GMT%+d:%02d", hours, minutes)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(cityLabel).font(.body)
                Text(offsetLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(timeText).font(.body.monospacedDigit())
        }
        .onReceive(timer) { now = $0 }
    }
}
