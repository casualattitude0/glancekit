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

    /// Persisted coordinates (non-secret prefs). These stay the source of truth
    /// the forecast API queries; they're set by picking a place in Settings
    /// rather than typed directly.
    var latitude: String {
        didSet { UserDefaults.standard.set(latitude, forKey: latKey) }
    }
    var longitude: String {
        didSet { UserDefaults.standard.set(longitude, forKey: lonKey) }
    }

    /// Human-readable name of the selected place, e.g. "San Francisco,
    /// California, United States". Display only — the forecast is fetched from
    /// `latitude`/`longitude`.
    var placeName: String {
        didSet { UserDefaults.standard.set(placeName, forKey: placeKey) }
    }

    /// Whether temperatures display in Celsius (`true`) or Fahrenheit (`false`).
    /// Drives the Open-Meteo `temperature_unit` query param so the API returns
    /// values already in the chosen unit — no client-side conversion needed.
    var useCelsius: Bool {
        didSet { UserDefaults.standard.set(useCelsius, forKey: unitKey) }
    }

    private let latKey = "glancekit.weather.lat"
    private let lonKey = "glancekit.weather.lon"
    private let placeKey = "glancekit.weather.place"
    private let unitKey = "glancekit.weather.celsius"

    /// The degree suffix shown after a temperature, e.g. "°C" / "°F".
    var unitSuffix: String { useCelsius ? "°C" : "°F" }

    private(set) var current: WeatherCurrent?
    private(set) var forecast: [WeatherDay] = []
    private(set) var lastError: String?

    private let network = NetworkClient()

    init() {
        latitude = UserDefaults.standard.string(forKey: latKey) ?? "37.77"
        longitude = UserDefaults.standard.string(forKey: lonKey) ?? "-122.42"
        placeName = UserDefaults.standard.string(forKey: placeKey) ?? "San Francisco, California, United States"
        useCelsius = UserDefaults.standard.bool(forKey: unitKey)
    }

    /// Look up places matching `query` via Open-Meteo's keyless geocoding API.
    /// Returns up to ten candidates (city + region + country) for the user to
    /// pick from in Settings. Throws on network/decoding failure.
    func searchPlaces(matching query: String) async throws -> [GeoPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let urlString = "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=10&language=en&format=json"
        let response = try await network.get(GeocodingResponse.self, from: urlString)
        return response.results ?? []
    }

    /// Adopt a place picked in Settings: store its coordinates and display name,
    /// then refresh the forecast for the new spot.
    func selectPlace(_ place: GeoPlace) async {
        latitude = String(place.latitude)
        longitude = String(place.longitude)
        placeName = place.displayName
        await refresh()
    }

    // MARK: GlancePlugin

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

        let unitParam = useCelsius ? "celsius" : "fahrenheit"
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latVal)&longitude=\(lonVal)&current=temperature_2m&daily=temperature_2m_max,temperature_2m_min,weather_code&forecast_days=3&temperature_unit=\(unitParam)"

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

    /// Surfaces notable weather. Storms and heavy precipitation earn an elevated
    /// card; otherwise the current temperature rides along as an ambient reading.
    func currentSignal() -> GlanceSignal? {
        guard let temp = current?.temperature else { return nil }
        let tempText = "\(Int(temp.rounded()))\(unitSuffix)"
        let todayCode = forecast.first?.code

        if let code = todayCode, let severe = Self.severeDescription(for: code) {
            return GlanceSignal(priority: .elevated, score: 0,
                                headline: "\(severe) · \(tempText)",
                                systemImage: WeatherCode.symbol(for: code), tint: .blue)
        }

        let symbol = todayCode.map(WeatherCode.symbol) ?? iconSystemName
        return GlanceSignal(priority: .ambient, score: 0,
                            headline: tempText, systemImage: symbol, tint: .secondary)
    }

    /// A short label for weather codes worth flagging (rain, snow, storms), or
    /// nil for calm conditions. Codes follow the WMO scheme (see `WeatherCode`).
    private static func severeDescription(for code: Int) -> String? {
        switch code {
        case 61, 63, 65, 66, 67: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 80, 81, 82: return "Heavy rain"
        case 95, 96, 99: return "Thunderstorm"
        default: return nil
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

// MARK: - Geocoding

/// One place returned by Open-Meteo's geocoding search.
struct GeoPlace: Decodable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    /// Primary administrative region (state/province), when provided.
    let admin1: String?

    /// "City, Region, Country" — omitting whichever parts the API left out.
    var displayName: String {
        [name, admin1, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct GeocodingResponse: Decodable {
    let results: [GeoPlace]?
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
                    Text("\(Int(temp.rounded()))\(plugin.unitSuffix)")
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

    @State private var query = ""
    @State private var results: [GeoPlace] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Location")
                .font(.headline)
            Text("Search for a city or area. Data comes from the keyless Open-Meteo API.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(plugin.placeName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack {
                TextField("Search city or area…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }

            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { place in
                        Button {
                            selectPlace(place)
                        } label: {
                            HStack {
                                Text(place.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .frame(maxWidth: 300)
            }

            Picker("Units:", selection: $plugin.useCelsius) {
                Text("Fahrenheit (°F)").tag(false)
                Text("Celsius (°C)").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .onChange(of: plugin.useCelsius) {
                Task { await plugin.refresh() }
            }

            Button("Refresh") {
                Task { await plugin.refresh() }
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isSearching else { return }
        isSearching = true
        searchError = nil
        Task {
            defer { isSearching = false }
            do {
                let found = try await plugin.searchPlaces(matching: q)
                results = found
                if found.isEmpty { searchError = "No matches for “\(q)”." }
            } catch {
                results = []
                searchError = error.localizedDescription
            }
        }
    }

    private func selectPlace(_ place: GeoPlace) {
        results = []
        query = ""
        searchError = nil
        Task { await plugin.selectPlace(place) }
    }
}
