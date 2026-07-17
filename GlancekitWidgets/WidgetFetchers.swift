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
        for s in symbols {
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
              let first = results.first,
              let meta = first["meta"] as? [String: Any] else { return nil }
        // Match QuoteProvider: fall back to the last intraday close when
        // regularMarketPrice is absent, instead of showing 0.00 / a bogus %.
        let closes = ((first["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?
            .first?["close"] as? [Any?] ?? []
        let lastClose = closes.reversed().compactMap { $0 as? Double }.first
        let price = (meta["regularMarketPrice"] as? Double) ?? lastClose ?? 0
        let prev = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double) ?? 0
        let pct = prev == 0 ? 0 : (price - prev) / prev * 100
        return WidgetStockQuote(symbol: symbol, price: price, changePercent: pct)
    }
}

// MARK: - GitHub (token supplied via widget config)

struct WidgetGitHubNotification: Identifiable {
    let id: String
    let title: String
    let repo: String
}

struct WidgetGitHubPullRequest: Identifiable {
    let id: Int
    let number: Int
    let title: String
    let repo: String
    /// "success" | "pending" | "failure" | "error", or nil when unknown.
    let ciState: String?
}

/// A year of contributions, already padded to 7 rows per week so the heatmap
/// can draw weekday-aligned columns without re-deriving weekdays in the view.
struct WidgetGitHubContributions {
    let total: Int
    /// One entry per week; each is 7 optional day counts, Sunday…Saturday.
    let weeks: [[Int?]]
}

struct WidgetGitHubCounts {
    let unread: Int
    let openPRs: Int
    var login: String? = nil
    var notifications: [WidgetGitHubNotification] = []
    var pullRequests: [WidgetGitHubPullRequest] = []
    var contributions: WidgetGitHubContributions? = nil
}

enum GitHubFetcher {
    /// The small widget only renders the two counts, so it skips the extra
    /// requests (contribution calendar, per-PR CI status) that the medium and
    /// large layouts need. `detailed: false` keeps it to two API calls.
    static func fetch(token: String?, detailed: Bool = false) async -> WidgetGitHubCounts? {
        guard let token, !token.isEmpty else { return nil }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Glancekit",
        ]
        async let notificationsTask = fetchNotifications(headers)
        async let contributionsTask = detailed ? await fetchContributions(headers) : nil
        async let loginTask = fetchLogin(headers)

        let notifications = await notificationsTask
        var prs: (total: Int, items: [WidgetGitHubPullRequest])?
        if let login = await loginTask {
            prs = await fetchPRs(headers, login: login, detailed: detailed)
        }
        guard notifications != nil || prs != nil else { return nil }

        return WidgetGitHubCounts(
            unread: notifications?.count ?? 0,
            openPRs: prs?.total ?? 0,
            login: await loginTask,
            notifications: notifications ?? [],
            pullRequests: prs?.items ?? [],
            contributions: await contributionsTask
        )
    }

    private static func get(_ urlStr: String, _ headers: [String: String]) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return await send(req)
    }

    private static func send(_ req: URLRequest) async -> Data? {
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private static func fetchNotifications(_ h: [String: String]) async -> [WidgetGitHubNotification]? {
        guard let d = await get("https://api.github.com/notifications", h),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        // Match GitHubPlugin: only unread notifications, capped at the first 10
        // the API returns (Array(fetchedNotifications.prefix(10))).
        return arr.prefix(10).compactMap { item -> WidgetGitHubNotification? in
            guard (item["unread"] as? Bool) == true,
                  let id = item["id"] as? String,
                  let title = (item["subject"] as? [String: Any])?["title"] as? String else { return nil }
            let repo = (item["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            return WidgetGitHubNotification(id: id, title: title, repo: repo)
        }
    }

    private static func fetchLogin(_ h: [String: String]) async -> String? {
        guard let d = await get("https://api.github.com/user", h),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["login"] as? String
    }

    private static func fetchPRs(_ h: [String: String], login: String, detailed: Bool) async -> (total: Int, items: [WidgetGitHubPullRequest])? {
        let q = "is:open is:pr author:\(login)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let d = await get("https://api.github.com/search/issues?q=\(q)", h),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let total = j["total_count"] as? Int else { return nil }
        guard detailed else { return (total, []) }

        // Only the PRs the largest layout can show — each CI status costs two
        // more API calls, so don't spend rate limit on rows nobody sees.
        let items = (j["items"] as? [[String: Any]] ?? []).prefix(maxDetailedPRs).compactMap { item -> WidgetGitHubPullRequest? in
            guard let id = item["id"] as? Int,
                  let number = item["number"] as? Int,
                  let title = item["title"] as? String else { return nil }
            return WidgetGitHubPullRequest(id: id, number: number, title: title, repo: repoFullName(from: item["repository_url"] as? String ?? ""), ciState: nil)
        }

        let withStatus = await withTaskGroup(of: (Int, String?).self) { group -> [Int: String] in
            for pr in items {
                group.addTask { (pr.id, await fetchCIState(h, repo: pr.repo, number: pr.number)) }
            }
            var states: [Int: String] = [:]
            for await (id, state) in group { states[id] = state }
            return states
        }
        return (total, items.map {
            WidgetGitHubPullRequest(id: $0.id, number: $0.number, title: $0.title, repo: $0.repo, ciState: withStatus[$0.id])
        })
    }

    /// Number of PR rows the large layout renders; also the CI-status budget.
    static let maxDetailedPRs = 4

    /// Matches GitHubAPI.Issue.repoFullName: "owner/repo" out of the API link.
    private static func repoFullName(from repositoryURL: String) -> String {
        let parts = repositoryURL.split(separator: "/")
        guard parts.count >= 2 else { return repositoryURL }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    private static func fetchCIState(_ h: [String: String], repo: String, number: Int) async -> String? {
        guard let pd = await get("https://api.github.com/repos/\(repo)/pulls/\(number)", h),
              let pj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
              let sha = (pj["head"] as? [String: Any])?["sha"] as? String,
              let sd = await get("https://api.github.com/repos/\(repo)/commits/\(sha)/status", h),
              let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any] else { return nil }
        return sj["state"] as? String
    }

    private static func fetchContributions(_ h: [String: String]) async -> WidgetGitHubContributions? {
        let query = """
        query { viewer { contributionsCollection { contributionCalendar { \
        totalContributions weeks { contributionDays { date contributionCount weekday } } } } } }
        """
        guard let url = URL(string: "https://api.github.com/graphql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Fine-grained tokens without profile read access get a 200 + `errors`
        // here; the nil-chain below treats that the same as a transport failure
        // and the heatmap is simply omitted.
        guard let data = await send(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let calendar = ((((json["data"] as? [String: Any])?["viewer"] as? [String: Any])?["contributionsCollection"] as? [String: Any])?["contributionCalendar"]) as? [String: Any],
              let total = calendar["totalContributions"] as? Int,
              let weeks = calendar["weeks"] as? [[String: Any]] else { return nil }

        let padded = weeks.map { week -> [Int?] in
            let days = week["contributionDays"] as? [[String: Any]] ?? []
            // Pad to 7 rows so weekdays line up even on partial weeks.
            var column = [Int?](repeating: nil, count: 7)
            for day in days {
                guard let weekday = day["weekday"] as? Int, (0..<7).contains(weekday) else { continue }
                column[weekday] = day["contributionCount"] as? Int
            }
            return column
        }
        return WidgetGitHubContributions(total: total, weeks: padded)
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
        return WidgetEvent(title: e.title ?? "Untitled event", date: e.startDate)
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
        // Match WeatherDay.weekdayLabel: parse the UTC "yyyy-MM-dd" date, then
        // format an abbreviated weekday ("EEE") in the device's local time zone.
        let inFormatter = DateFormatter()
        inFormatter.locale = Locale(identifier: "en_US_POSIX")
        inFormatter.dateFormat = "yyyy-MM-dd"
        inFormatter.timeZone = TimeZone(identifier: "UTC")
        guard let parsed = inFormatter.date(from: date) else { return date }
        let out = DateFormatter()
        out.dateFormat = "EEE"
        return out.string(from: parsed)
    }

    var symbolName: String { WidgetWeatherCode.symbol(for: code) }
}

enum WeatherFetcher {
    static func fetch(latitude: String, longitude: String) async -> WidgetWeather {
        let lat = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let lon = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latValue = Double(lat), let lonValue = Double(lon),
              (-90...90).contains(latValue), (-180...180).contains(lonValue) else {
            return WidgetWeather(temperature: nil, forecast: [], error: "Enter a valid latitude (−90…90) and longitude (−180…180) in Settings.")
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

        var request = URLRequest(url: url, timeoutInterval: 15)
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
                return WidgetCustomAPIResult(label: displayLabel, value: nil, error: "Path \"\(jsonPath)\" not found")
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
            if let data = try? JSONSerialization.data(withJSONObject: object),
               let string = String(data: data, encoding: .utf8) { return string }
            return "{…}"
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array),
               let string = String(data: data, encoding: .utf8) { return string }
            return "[…]"
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
    let batteryTimeRemainingMinutes: Int?
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
            batteryTimeRemainingMinutes: battery?.timeRemaining,
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

    private static func batteryInfo() -> (percent: Int, isCharging: Bool, timeRemaining: Int?)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            var minutesRemaining: Int?
            if let timeToEmpty = description[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
                minutesRemaining = timeToEmpty
            } else if let timeToFull = description[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
                minutesRemaining = timeToFull
            }
            return (Int((Double(current) / Double(maximum) * 100).rounded()), description[kIOPSIsChargingKey] as? Bool ?? false, minutesRemaining)
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

        // Match PhotoSource caption: medium date style, else the asset id.
        let caption: String
        if let date = asset.creationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            caption = formatter.string(from: date)
        } else {
            caption = asset.localIdentifier
        }
        return WidgetPhoto(imageData: image?.tiffRepresentation, caption: caption, isAuthorized: true)
    }
}
