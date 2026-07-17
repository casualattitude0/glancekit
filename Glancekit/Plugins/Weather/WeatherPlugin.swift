import SwiftUI
import Observation

/// Weather glance backed by the free, keyless Open-Meteo API.
///
/// - Data source: `https://api.open-meteo.com/v1/forecast` — no API key needed.
/// - Location: a user-entered latitude/longitude (two text fields in Settings),
///   persisted in `UserDefaults` under `glancekit.weather.lat` /
///   `glancekit.weather.lon`. Defaults to San Francisco so it works out of the box.
/// - Menu-bar: compact current temperature like "72°".
/// - Popover: large current temperature + a 3-day mini forecast.
@MainActor
@Observable
final class WeatherPlugin: GlancePlugin {
    nonisolated var id: String { "weather" }
    nonisolated var title: String { "Weather" }
    nonisolated var iconSystemName: String { "cloud.sun" }
    var refreshInterval: TimeInterval { 900 }

    /// Persisted location (non-secret prefs).
    var latitude: String {
        didSet { UserDefaults.standard.set(latitude, forKey: latKey) }
    }
    var longitude: String {
        didSet { UserDefaults.standard.set(longitude, forKey: lonKey) }
    }

    private let latKey = "glancekit.weather.lat"
    private let lonKey = "glancekit.weather.lon"

    private(set) var current: WeatherCurrent?
    private(set) var forecast: [WeatherDay] = []
    private(set) var lastError: String?

    private let network = NetworkClient()

    init() {
        latitude = UserDefaults.standard.string(forKey: latKey) ?? "37.77"
        longitude = UserDefaults.standard.string(forKey: lonKey) ?? "-122.42"
    }

    // MARK: GlancePlugin

    var menuBarSummary: String? {
        guard let temp = current?.temperature else { return nil }
        return "\(Int(temp.rounded()))°"
    }

    func refresh() async {
        let lat = latitude.trimmingCharacters(in: .whitespaces)
        let lon = longitude.trimmingCharacters(in: .whitespaces)

        guard let latVal = Double(lat), let lonVal = Double(lon),
              (-90...90).contains(latVal), (-180...180).contains(lonVal) else {
            lastError = "Enter a valid latitude (−90…90) and longitude (−180…180) in Settings."
            current = nil
            forecast = []
            return
        }

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latVal)&longitude=\(lonVal)&current=temperature_2m&daily=temperature_2m_max,temperature_2m_min,weather_code&forecast_days=3&temperature_unit=fahrenheit"

        do {
            let response = try await network.get(WeatherResponse.self, from: urlString)
            current = WeatherCurrent(temperature: response.current?.temperature_2m)

            var days: [WeatherDay] = []
            if let daily = response.daily {
                let count = min(daily.time.count, min(daily.temperature_2m_max.count, min(daily.temperature_2m_min.count, daily.weather_code.count)))
                for i in 0..<count {
                    days.append(WeatherDay(
                        date: daily.time[i],
                        high: daily.temperature_2m_max[i],
                        low: daily.temperature_2m_min[i],
                        code: daily.weather_code[i]
                    ))
                }
            }
            forecast = days
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func popoverSection() -> AnyView {
        AnyView(WeatherPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(WeatherSettings(plugin: self))
    }
}

// MARK: - Domain models

/// Parsed current conditions surfaced to the UI.
struct WeatherCurrent {
    let temperature: Double?
}

/// One day of the mini forecast.
struct WeatherDay: Identifiable {
    let date: String
    let high: Double
    let low: Double
    let code: Int

    var id: String { date }

    /// Short weekday label (e.g. "Mon") derived from the ISO "yyyy-MM-dd" date.
    var weekdayLabel: String {
        let inFormatter = DateFormatter()
        inFormatter.locale = Locale(identifier: "en_US_POSIX")
        inFormatter.dateFormat = "yyyy-MM-dd"
        inFormatter.timeZone = TimeZone(identifier: "UTC")
        guard let d = inFormatter.date(from: date) else { return date }
        let out = DateFormatter()
        out.dateFormat = "EEE"
        return out.string(from: d)
    }

    /// SF Symbol chosen from the WMO weather code.
    var symbolName: String { WeatherCode.symbol(for: code) }
}

// MARK: - WMO weather code mapping

/// Maps Open-Meteo (WMO) `weather_code` values to SF Symbols.
enum WeatherCode {
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 61, 63, 65, 66, 67: return "cloud.rain"
        case 71, 73, 75, 77: return "cloud.snow"
        case 80, 81, 82: return "cloud.heavyrain"
        case 85, 86: return "cloud.snow"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}

// MARK: - API decoding

private struct WeatherResponse: Decodable {
    let current: Current?
    let daily: Daily?

    struct Current: Decodable {
        let temperature_2m: Double?
    }

    struct Daily: Decodable {
        let time: [String]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let weather_code: [Int]
    }
}

// MARK: - Popover UI

private struct WeatherPopover: View {
    let plugin: WeatherPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let temp = plugin.current?.temperature {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(temp.rounded()))°")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let today = plugin.forecast.first {
                        Image(systemName: today.symbolName)
                            .font(.title)
                            .symbolRenderingMode(.multicolor)
                    }
                }
            } else if plugin.lastError == nil {
                Text("Loading weather…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !plugin.forecast.isEmpty {
                Divider()
                ForEach(plugin.forecast) { day in
                    HStack(spacing: 10) {
                        Text(day.weekdayLabel)
                            .font(.body.weight(.medium))
                            .frame(width: 44, alignment: .leading)
                        Image(systemName: day.symbolName)
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 24)
                        Spacer()
                        Text("\(Int(day.high.rounded()))°")
                            .font(.body.monospacedDigit())
                        Text("\(Int(day.low.rounded()))°")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Settings UI

private struct WeatherSettings: View {
    @Bindable var plugin: WeatherPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Location")
                .font(.headline)
            Text("Enter the latitude and longitude to show weather for. Data comes from the keyless Open-Meteo API.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Latitude:")
                    .font(.caption)
                    .frame(width: 70, alignment: .leading)
                TextField("37.77", text: $plugin.latitude)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            HStack {
                Text("Longitude:")
                    .font(.caption)
                    .frame(width: 70, alignment: .leading)
                TextField("-122.42", text: $plugin.longitude)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            Button("Save & refresh") {
                Task { await plugin.refresh() }
            }
        }
    }
}
