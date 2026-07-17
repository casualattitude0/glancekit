import SwiftUI

/// Live countdown to a target date. Ticks via a local `Timer`.
struct TimeProdCountdownView: View {
    let label: String
    let targetDate: Date
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval {
        max(0, targetDate.timeIntervalSince(now))
    }

    private var remainingText: String {
        if remaining <= 0 { return "Arrived" }
        let total = Int(remaining.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, seconds)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label.isEmpty ? "Countdown" : label).font(.body)
                Text(targetDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(remainingText).font(.body.monospacedDigit())
        }
        .onReceive(timer) { now = $0 }
    }
}
