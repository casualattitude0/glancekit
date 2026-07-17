import Foundation
import EventKit
import AppKit
import Photos
import IOKit
import IOKit.ps
import Darwin

// Self-contained data fetchers for the desktop widgets. The widget runs in its
// own sandboxed process and does not share code or storage with the app, so it
// fetches everything itself using config supplied on the widget (App Intents).

// MARK: - Stocks (Yahoo, keyless)

struct WidgetStockQuote: Identifiable {
    let symbol: String
    let price: Double
    let changePercent: Double
    var id: String { symbol }
    var isUp: Bool { changePercent >= 0 }
}

enum StockFetcher {
    static func parseSymbols(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    static func fetch(symbols: [String]) async -> [WidgetStockQuote] {
        var out: [WidgetStockQuote] = []
        for s in symbols.prefix(10) {
            if let q = await fetchOne(s) { out.append(q) }
        }
        return out
    }

    private static func fetchOne(_ symbol: String) async -> WidgetStockQuote? {
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=1d&interval=5m") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Glancekit/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any] else { return nil }
        let price = (meta["regularMarketPrice"] as? Double) ?? 0
        let prev = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double) ?? 0
        let pct = prev == 0 ? 0 : (price - prev) / prev * 100
        return WidgetStockQuote(symbol: symbol, price: price, changePercent: pct)
    }
}

// MARK: - GitHub (token supplied via widget config)

struct WidgetGitHubCounts {
    let unread: Int
    let openPRs: Int
}

enum GitHubFetcher {
    static func fetch(token: String?) async -> WidgetGitHubCounts? {
        guard let token, !token.isEmpty else { return nil }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Glancekit",
        ]
        async let unread = fetchUnread(headers)
        async let prs = fetchPRCount(headers)
        let (u, p) = await (unread, prs)
        guard u != nil || p != nil else { return nil }
        return WidgetGitHubCounts(unread: u ?? 0, openPRs: p ?? 0)
    }

    private static func get(_ urlStr: String, _ headers: [String: String]) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private static func fetchUnread(_ h: [String: String]) async -> Int? {
        guard let d = await get("https://api.github.com/notifications", h),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        return arr.count
    }

    private static func fetchPRCount(_ h: [String: String]) async -> Int? {
        guard let ud = await get("https://api.github.com/user", h),
              let uj = try? JSONSerialization.jsonObject(with: ud) as? [String: Any],
              let login = uj["login"] as? String else { return nil }
        let q = "is:open is:pr author:\(login)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let d = await get("https://api.github.com/search/issues?q=\(q)", h),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["total_count"] as? Int
    }
}

// MARK: - Next event (EventKit, read directly)

struct WidgetEvent {
    let title: String
    let date: Date
}

enum EventFetcher {
    static func nextEvent() -> WidgetEvent? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 14, to: now) else { return nil }
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: pred)
            .filter { $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
        guard let e = events.first else { return nil }
        return WidgetEvent(title: e.title ?? "Event", date: e.startDate)
    }
}

// MARK: - Weather (Open-Meteo, keyless)

struct WidgetWeather {
    let temperature: Double?
    let forecast: [WidgetWeatherDay]
    let error: String?
}

struct WidgetWeatherDay: Identifiable {
    let date: String
    let high: Double
    let low: Double
    let code: Int

    var id: String { date }

    var weekday: String {
        let formatter = ISO8601DateFormatter()
        guard let parsed = formatter.date(from: "\(date)T00:00:00Z") else { return date }
        return parsed.formatted(.dateTime.weekday(.abbreviated))
    }

    var symbolName: String { WidgetWeatherCode.symbol(for: code) }
}

enum WeatherFetcher {
    static func fetch(latitude: String, longitude: String) async -> WidgetWeather {
        let lat = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let lon = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latValue = Double(lat), let lonValue = Double(lon),
              (-90...90).contains(latValue), (-180...180).contains(lonValue) else {
            return WidgetWeather(temperature: nil, forecast: [], error: "Enter a valid latitude and longitude")
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latValue)),
            URLQueryItem(name: "longitude", value: String(lonValue)),
            URLQueryItem(name: "current", value: "temperature_2m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
            URLQueryItem(name: "forecast_days", value: "3"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
        ]
        guard let url = components.url else {
            return WidgetWeather(temperature: nil, forecast: [], error: "Couldn't build weather request")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return WidgetWeather(temperature: nil, forecast: [], error: "Weather service is unavailable")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let daily = decoded.daily
            let dateCount = daily?.time.count ?? 0
            let highCount = daily?.temperature_2m_max.count ?? 0
            let lowCount = daily?.temperature_2m_min.count ?? 0
            let codeCount = daily?.weather_code.count ?? 0
            let count = min(dateCount, min(highCount, min(lowCount, codeCount)))
            let forecast = (0..<count).map { index in
                WidgetWeatherDay(
                    date: daily!.time[index],
                    high: daily!.temperature_2m_max[index],
                    low: daily!.temperature_2m_min[index],
                    code: daily!.weather_code[index]
                )
            }
            return WidgetWeather(temperature: decoded.current?.temperature_2m, forecast: forecast, error: nil)
        } catch {
            return WidgetWeather(temperature: nil, forecast: [], error: error.localizedDescription)
        }
    }

    private struct Response: Decodable {
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
}

enum WidgetWeatherCode {
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 61, 63, 65, 66, 67: return "cloud.rain"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow"
        case 80, 81, 82: return "cloud.heavyrain"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}

// MARK: - Custom API

struct WidgetCustomAPIResult {
    let label: String
    let value: String?
    let error: String?
}

enum CustomAPIFetcher {
    static func fetch(label: String, urlString: String, jsonPath: String, headersText: String?) async -> WidgetCustomAPIResult {
        let displayLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom API" : label
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return WidgetCustomAPIResult(label: displayLabel, value: nil, error: "Enter a valid URL")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        for (name, value) in headers(from: headersText ?? "") {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return WidgetCustomAPIResult(label: displayLabel, value: nil, error: "Request failed")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                return WidgetCustomAPIResult(label: displayLabel, value: nil, error: "Response is not valid JSON")
            }
            guard let value = WidgetJSONPath.evaluate(path: jsonPath, in: json) else {
                return WidgetCustomAPIResult(label: displayLabel, value: nil, error: "Path not found")
            }
            return WidgetCustomAPIResult(label: displayLabel, value: value, error: nil)
        } catch {
            return WidgetCustomAPIResult(label: displayLabel, value: nil, error: error.localizedDescription)
        }
    }

    private static func headers(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let split = line.firstIndex(of: ":") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[String(key)] = String(value)
        }
        return result
    }
}

enum WidgetJSONPath {
    private enum Token {
        case key(String)
        case index(Int)
    }

    static func evaluate(path: String, in root: Any) -> String? {
        let tokens = tokenize(path)
        guard !tokens.isEmpty else { return stringify(root) }

        var current: Any = root
        for token in tokens {
            switch token {
            case .key(let key):
                guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return stringify(current)
    }

    private static func tokenize(_ path: String) -> [Token] {
        var tokens: [Token] = []
        var key = ""
        var iterator = path.makeIterator()

        func appendKey() {
            guard !key.isEmpty else { return }
            tokens.append(.key(key))
            key = ""
        }

        while let character = iterator.next() {
            switch character {
            case ".":
                appendKey()
            case "[":
                appendKey()
                var index = ""
                while let nested = iterator.next(), nested != "]" { index.append(nested) }
                if let value = Int(index.trimmingCharacters(in: .whitespaces)) { tokens.append(.index(value)) }
            default:
                key.append(character)
            }
        }
        appendKey()
        return tokens
    }

    private static func stringify(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case is NSNull:
            return "null"
        case let object as [String: Any]:
            return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
        case let array as [Any]:
            return (try? JSONSerialization.data(withJSONObject: array)).flatMap { String(data: $0, encoding: .utf8) }
        default:
            return "\(value)"
        }
    }
}

// MARK: - Mac Health

struct WidgetSystemStats {
    let cpuPercent: Double?
    let usedMemory: UInt64?
    let totalMemory: UInt64?
    let batteryPercent: Int?
    let isCharging: Bool
    let diskFree: Int64?
    let downloadRate: Double?
    let uploadRate: Double?
    let vpnActive: Bool?
    let uptime: TimeInterval
}

enum SystemStatsFetcher {
    private struct CPUTicks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    private struct InterfaceCounts {
        var received: [String: UInt64] = [:]
        var sent: [String: UInt64] = [:]
        var hasVPN = false
    }

    static func fetch() async -> WidgetSystemStats {
        let firstTicks = cpuTicks()
        let firstNetwork = interfaceCounts()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let secondTicks = cpuTicks()
        let secondNetwork = interfaceCounts()

        let memory = memoryInfo()
        let battery = batteryInfo()
        return WidgetSystemStats(
            cpuPercent: cpuPercent(before: firstTicks, after: secondTicks),
            usedMemory: memory?.used,
            totalMemory: memory?.total,
            batteryPercent: battery?.percent,
            isCharging: battery?.isCharging ?? false,
            diskFree: diskFreeBytes(),
            downloadRate: throughput(before: firstNetwork, after: secondNetwork, received: true),
            uploadRate: throughput(before: firstNetwork, after: secondNetwork, received: false),
            vpnActive: secondNetwork?.hasVPN,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private static func cpuPercent(before: CPUTicks?, after: CPUTicks?) -> Double? {
        guard let before, let after else { return nil }
        let user = Double(after.user &- before.user)
        let system = Double(after.system &- before.system)
        let idle = Double(after.idle &- before.idle)
        let nice = Double(after.nice &- before.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return max(0, min(100, (user + system + nice) / total * 100))
    }

    private static func memoryInfo() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard status == KERN_SUCCESS, total > 0 else { return nil }
        let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * UInt64(vm_kernel_page_size)
        return (min(used, total), total)
    }

    private static func batteryInfo() -> (percent: Int, isCharging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            return (Int((Double(current) / Double(maximum) * 100).rounded()), description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    private static func diskFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        return Int64(stats.f_bsize) * Int64(stats.f_bavail)
    }

    private static func interfaceCounts() -> InterfaceCounts? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var result = InterfaceCounts()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let address = item.pointee
            current = address.ifa_next
            guard let namePointer = address.ifa_name else { continue }
            let name = String(cString: namePointer)
            if name.hasPrefix("utun") { result.hasVPN = true }
            guard let interfaceAddress = address.ifa_addr,
                  interfaceAddress.pointee.sa_family == UInt8(AF_LINK),
                  let data = address.ifa_data else { continue }
            let counts = data.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
            result.received[name, default: 0] += UInt64(counts.ifi_ibytes)
            result.sent[name, default: 0] += UInt64(counts.ifi_obytes)
        }
        return result
    }

    private static func throughput(before: InterfaceCounts?, after: InterfaceCounts?, received: Bool) -> Double? {
        guard let before, let after else { return nil }
        let old = received ? before.received : before.sent
        let new = received ? after.received : after.sent
        let delta = new.reduce(UInt64(0)) { total, item in
            guard !item.key.hasPrefix("lo") else { return total }
            return total + (item.value >= (old[item.key] ?? item.value) ? item.value - (old[item.key] ?? item.value) : 0)
        }
        return Double(delta) / 0.25
    }
}

// MARK: - Photos

struct WidgetPhoto {
    let imageData: Data?
    let caption: String?
    let isAuthorized: Bool
}

enum PhotoFetcher {
    static func latestPhoto() -> WidgetPhoto {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return WidgetPhoto(imageData: nil, caption: nil, isAuthorized: false)
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = assets.firstObject else {
            return WidgetPhoto(imageData: nil, caption: nil, isAuthorized: true)
        }

        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isNetworkAccessAllowed = true
        var image: NSImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 900, height: 600),
            contentMode: .aspectFill,
            options: requestOptions
        ) { result, _ in image = result }

        let caption = asset.creationDate?.formatted(date: .abbreviated, time: .omitted)
        return WidgetPhoto(imageData: image?.tiffRepresentation, caption: caption, isAuthorized: true)
    }
}
