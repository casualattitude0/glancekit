import SwiftUI
import Observation
import CoreWLAN
import Darwin

/// Network / connectivity glance.
///
/// Goes beyond the throughput + VPN readout of the System (Mac Health) glance by
/// adding: HTTP-measured reachability/latency probes against a **user-managed
/// list of hosts** (add / delete / reorder), a rolling latency-history sparkline
/// for the primary host, the public IP (throttled), a per-interface IPv4 listing,
/// VPN (`utun`) detection, the default gateway, and live Wi-Fi SSID + signal
/// strength via CoreWLAN.
///
/// Everything here is defensive — `refresh()` never throws and treats a fully
/// failed set of probes as a clean "Offline" state rather than an error crash.
/// A single host being down (while others answer) is *not* offline.
@MainActor
@Observable
final class NetworkPlugin: GlancePlugin {
    nonisolated var id: String { "network" }
    nonisolated var title: String { "Network" }
    nonisolated var iconSystemName: String { "network" }
    var refreshInterval: TimeInterval { refreshSeconds }

    // MARK: Persisted prefs (non-secret → UserDefaults, namespaced)

    /// The primary host — the one whose latency drives the headline signal and
    /// the history sparkline. Its URL matches one entry in `hosts`.
    var latencyHost: String {
        didSet {
            guard latencyHost != oldValue else { return }
            UserDefaults.standard.set(latencyHost, forKey: Keys.latencyHost)
        }
    }
    /// The user-managed list of hosts to probe. Persisted as JSON.
    var hosts: [NetworkHost] {
        didSet {
            guard hosts != oldValue else { return }
            if let data = try? JSONEncoder().encode(hosts) {
                UserDefaults.standard.set(data, forKey: Keys.hosts)
            }
        }
    }
    /// Refresh cadence in seconds (also drives `refreshInterval`).
    var refreshSeconds: TimeInterval {
        didSet {
            guard refreshSeconds != oldValue else { return }
            UserDefaults.standard.set(refreshSeconds, forKey: Keys.refreshSeconds)
        }
    }
    var showPublicIP: Bool {
        didSet {
            guard showPublicIP != oldValue else { return }
            UserDefaults.standard.set(showPublicIP, forKey: Keys.showPublicIP)
        }
    }
    var showLatency: Bool {
        didSet {
            guard showLatency != oldValue else { return }
            UserDefaults.standard.set(showLatency, forKey: Keys.showLatency)
        }
    }
    var showWiFi: Bool {
        didSet {
            guard showWiFi != oldValue else { return }
            UserDefaults.standard.set(showWiFi, forKey: Keys.showWiFi)
        }
    }
    var showVPN: Bool {
        didSet {
            guard showVPN != oldValue else { return }
            UserDefaults.standard.set(showVPN, forKey: Keys.showVPN)
        }
    }
    var showInterfaces: Bool {
        didSet {
            guard showInterfaces != oldValue else { return }
            UserDefaults.standard.set(showInterfaces, forKey: Keys.showInterfaces)
        }
    }
    var showGateway: Bool {
        didSet {
            guard showGateway != oldValue else { return }
            UserDefaults.standard.set(showGateway, forKey: Keys.showGateway)
        }
    }

    private enum Keys {
        static let latencyHost = "glancekit.network.latencyHost"
        static let hosts = "glancekit.network.customHosts"
        static let refreshSeconds = "glancekit.network.refreshSeconds"
        static let showPublicIP = "glancekit.network.showPublicIP"
        static let showLatency = "glancekit.network.showLatency"
        static let showWiFi = "glancekit.network.showWiFi"
        static let showVPN = "glancekit.network.showVPN"
        static let showInterfaces = "glancekit.network.showInterfaces"
        static let showGateway = "glancekit.network.showGateway"
    }

    /// Preset probe hosts used to seed a fresh install. All are lightweight
    /// endpoints. The user can then add / delete / reorder freely.
    struct LatencyPreset: Identifiable, Hashable {
        let name: String
        let url: String
        var id: String { url }
    }
    static let latencyPresets: [LatencyPreset] = [
        LatencyPreset(name: "Apple", url: "https://www.apple.com/library/test/success.html"),
        LatencyPreset(name: "Cloudflare", url: "https://1.1.1.1/"),
        LatencyPreset(name: "Google", url: "https://www.google.com/generate_204")
    ]

    private static let historyCap = 40

    // MARK: Observed state

    private(set) var isOnline: Bool = false
    private(set) var latencyMs: Double?          // primary host latency
    private(set) var latencyHistory: [Double] = []
    /// Per-host probe result, keyed by `NetworkHost.id`.
    private(set) var hostSamples: [String: HostSample] = [:]
    private(set) var publicIP: String?
    private(set) var gatewayIP: String?
    private(set) var interfaces: [NetInterface] = []
    private(set) var wifi: WiFiInfo?
    private(set) var lastError: String?
    private(set) var isRefreshing: Bool = false

    /// The IPv4-carrying `utun` interface, if any (a live VPN tunnel).
    var vpnInterface: NetInterface? {
        interfaces.first { $0.isVPN }
    }

    /// The host whose latency drives the headline signal + history.
    var primaryHost: NetworkHost? {
        hosts.first { $0.url == latencyHost } ?? hosts.first
    }

    private var lastPublicIPFetch: Date?
    private let publicIPTTL: TimeInterval = 300 // refetch public IP at most every 5 min
    private let client = NetworkClient(timeout: 8)

    // MARK: Value types

    struct NetworkHost: Identifiable, Hashable, Codable {
        let id: String
        var name: String
        var url: String
    }

    struct HostSample: Hashable {
        let latencyMs: Double?
        var ok: Bool { latencyMs != nil }
    }

    struct NetInterface: Identifiable, Hashable {
        let name: String
        let ipv4: String
        var isVPN: Bool { name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") }
        var id: String { "\(name)-\(ipv4)" }
    }

    struct WiFiInfo: Hashable {
        /// nil when hidden by lack of Location permission on modern macOS.
        let ssid: String?
        let rssi: Int?      // dBm; more negative = weaker
        let channel: Int?

        /// 0…3 bar strength derived from RSSI.
        var bars: Int {
            guard let rssi else { return 0 }
            if rssi > -60 { return 3 }
            if rssi > -70 { return 2 }
            if rssi > -80 { return 1 }
            return 0
        }
    }

    /// The dominant connection type, used as a headline accent.
    enum ConnectionType {
        case offline, vpn, wifi, wired, unknown

        var label: String {
            switch self {
            case .offline: return "Offline"
            case .vpn: return "VPN"
            case .wifi: return "Wi-Fi"
            case .wired: return "Ethernet"
            case .unknown: return "Online"
            }
        }
        var systemImage: String {
            switch self {
            case .offline: return "wifi.slash"
            case .vpn: return "lock.shield"
            case .wifi: return "wifi"
            case .wired: return "cable.connector"
            case .unknown: return "network"
            }
        }
    }

    var connectionType: ConnectionType {
        if !isOnline { return .offline }
        if vpnInterface != nil { return .vpn }
        if let w = wifi, w.rssi != nil { return .wifi }
        if interfaces.contains(where: { !$0.isVPN }) { return .wired }
        return .unknown
    }

    // MARK: Init

    init() {
        let d = UserDefaults.standard
        latencyHost = d.string(forKey: Keys.latencyHost) ?? NetworkPlugin.latencyPresets[0].url
        refreshSeconds = d.object(forKey: Keys.refreshSeconds) as? TimeInterval ?? 30
        showPublicIP = d.object(forKey: Keys.showPublicIP) as? Bool ?? true
        showLatency = d.object(forKey: Keys.showLatency) as? Bool ?? true
        showWiFi = d.object(forKey: Keys.showWiFi) as? Bool ?? true
        showVPN = d.object(forKey: Keys.showVPN) as? Bool ?? true
        showInterfaces = d.object(forKey: Keys.showInterfaces) as? Bool ?? true
        showGateway = d.object(forKey: Keys.showGateway) as? Bool ?? true

        if let data = d.data(forKey: Keys.hosts),
           let decoded = try? JSONDecoder().decode([NetworkHost].self, from: data),
           !decoded.isEmpty {
            hosts = decoded
        } else {
            hosts = NetworkPlugin.latencyPresets.map {
                NetworkHost(id: UUID().uuidString, name: $0.name, url: $0.url)
            }
        }

        // Keep the primary in sync with the list without triggering didSet
        // recursion (plain assignment, guarded to a single write).
        if !hosts.contains(where: { $0.url == latencyHost }), let first = hosts.first {
            latencyHost = first.url
        }
    }

    // MARK: Host management

    func addHost(name: String, url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let normalized = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmedName.isEmpty ? normalized : trimmedName
        hosts.append(NetworkHost(id: UUID().uuidString, name: display, url: normalized))
    }

    func deleteHosts(at offsets: IndexSet) {
        let removed = offsets.map { hosts[$0] }
        hosts.remove(atOffsets: offsets)
        for r in removed { hostSamples[r.id] = nil }
        ensurePrimaryValid()
    }

    func moveHosts(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
    }

    /// Promote a host to primary (drives the signal + history). Resets the
    /// jitter history so the sparkline reflects the newly-selected host.
    func makePrimary(_ host: NetworkHost) {
        guard latencyHost != host.url else { return }
        latencyHost = host.url
        latencyHistory.removeAll()
        latencyMs = hostSamples[host.id]?.latencyMs
    }

    /// If the primary URL no longer names a host, fall back to the first one.
    private func ensurePrimaryValid() {
        if !hosts.contains(where: { $0.url == latencyHost }), let first = hosts.first {
            latencyHost = first.url
            latencyHistory.removeAll()
        }
    }

    // MARK: GlancePlugin

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Local reads first — these never touch the network and always succeed.
        interfaces = Self.readInterfaces()
        wifi = Self.readWiFi()
        gatewayIP = Self.defaultGatewayIPv4()

        // Probe every configured host concurrently, off the main actor.
        let hostsSnapshot = hosts
        let client = self.client
        var samples: [String: HostSample] = [:]
        if !hostsSnapshot.isEmpty {
            samples = await withTaskGroup(of: (String, HostSample).self) { group in
                for h in hostsSnapshot {
                    group.addTask {
                        let ms = await Self.probe(url: h.url, client: client)
                        return (h.id, HostSample(latencyMs: ms))
                    }
                }
                var acc: [String: HostSample] = [:]
                for await (hid, sample) in group { acc[hid] = sample }
                return acc
            }
        }
        hostSamples = samples

        // Online = ANY host answered. One host being down is not "offline".
        let anyReachable = samples.values.contains { $0.ok }
        isOnline = anyReachable

        // Primary host latency drives the headline signal + history sparkline.
        let primaryMs = primaryHost.flatMap { samples[$0.id]?.latencyMs }
        latencyMs = primaryMs
        if let ms = primaryMs {
            latencyHistory.append(ms)
            if latencyHistory.count > Self.historyCap {
                latencyHistory.removeFirst(latencyHistory.count - Self.historyCap)
            }
        }

        // Public IP — throttled, and only worth fetching when we look online.
        if anyReachable {
            lastError = nil
            let due = lastPublicIPFetch.map { Date().timeIntervalSince($0) >= publicIPTTL } ?? true
            if due || publicIP == nil {
                await fetchPublicIP()
            }
        } else {
            // Offline is a clean state, not an error.
            lastError = hostsSnapshot.isEmpty ? "No hosts configured" : "Offline"
        }
    }

    /// Time a single HTTP reachability probe. Returns latency in ms, or nil if
    /// the host did not answer. Runs off the main actor.
    nonisolated static func probe(url: String, client: NetworkClient) async -> Double? {
        let start = Date()
        do {
            _ = try await client.data(from: url)
            return Date().timeIntervalSince(start) * 1000
        } catch {
            return nil
        }
    }

    private func fetchPublicIP() async {
        struct IPResponse: Decodable { let ip: String }
        do {
            let resp = try await client.get(IPResponse.self, from: "https://api.ipify.org?format=json")
            publicIP = resp.ip
            lastPublicIPFetch = Date()
        } catch {
            // Leave the previous value in place; a single miss isn't fatal.
        }
    }

    /// Offline is the loud case; a live VPN or a slow link is quieter context.
    func currentSignal() -> GlanceSignal? {
        if !isOnline {
            return GlanceSignal(priority: .urgent, score: 1000,
                                headline: "Offline",
                                detail: "No network reachability",
                                systemImage: "wifi.slash", tint: .red)
        }
        if let ms = latencyMs, ms > 400 {
            return GlanceSignal(priority: .normal, score: ms,
                                headline: String(format: "High latency %.0fms", ms),
                                systemImage: "timer", tint: .orange)
        }
        if showVPN, let vpn = vpnInterface {
            return GlanceSignal(priority: .ambient, score: 10,
                                headline: "VPN on · \(vpn.name)",
                                detail: vpn.ipv4,
                                systemImage: "lock.shield", tint: .green)
        }
        // Otherwise surface an ambient "Online" card, tagged with the connection
        // type, using Wi-Fi strength as a gauge (or the latency history as a
        // sparkline) when we have it.
        if let ms = latencyMs {
            let type = connectionType
            let accessory: GlanceSignal.Accessory
            if let bars = wifi?.bars, wifi?.rssi != nil {
                accessory = .gauge(Double(bars) / 3.0)
            } else if latencyHistory.count > 1 {
                accessory = .sparkline(latencyHistory, up: false)
            } else {
                accessory = .none
            }
            return GlanceSignal(priority: .ambient, score: 1,
                                headline: String(format: "%@ · %.0fms", type.label, ms),
                                systemImage: type.systemImage, tint: .green,
                                accessory: accessory)
        }
        return nil
    }

    func popoverSection() -> AnyView { AnyView(NetworkPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(NetworkSettings(plugin: self)) }

    // MARK: - Local interface enumeration (getifaddrs)

    /// Active, non-loopback interfaces with an IPv4 address. Reimplements the
    /// `getifaddrs` walk used by `SystemMetrics` (not imported — plugins are
    /// independent), but keyed on `AF_INET` to read addresses rather than the
    /// `AF_LINK` byte counters.
    static func readInterfaces() -> [NetInterface] {
        var out: [NetInterface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return out }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let addr = current.pointee

            // Skip down interfaces.
            let flags = Int32(addr.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }

            guard let namePtr = addr.ifa_name else { continue }
            let name = String(cString: namePtr)
            if name.hasPrefix("lo") { continue }

            guard let sa = addr.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            guard ok == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }

            out.append(NetInterface(name: name, ipv4: ip))
        }
        // Stable, friendly ordering: physical first, tunnels after.
        return out.sorted { a, b in
            if a.isVPN != b.isVPN { return !a.isVPN }
            return a.name < b.name
        }
    }

    // MARK: - Default gateway (sysctl PF_ROUTE dump)

    /// Best-effort default IPv4 gateway (router) address, read from the routing
    /// table via `sysctl(NET_RT_DUMP)`. Fully bounds-checked and uses
    /// `loadUnaligned`, so a malformed table yields `nil` rather than a crash.
    /// No entitlement or permission is required.
    static func defaultGatewayIPv4() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buf, &needed, nil, 0) == 0 else { return nil }
        let regionLen = min(needed, buf.count)

        return buf.withUnsafeBytes { raw -> String? in
            let hdrSize = MemoryLayout<rt_msghdr>.size
            var offset = 0
            while offset + hdrSize <= regionLen {
                let rtm = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let msgLen = Int(rtm.rtm_msglen)
                if msgLen < hdrSize || offset + msgLen > regionLen { break }

                let flags = Int32(rtm.rtm_flags)
                let addrs = Int32(rtm.rtm_addrs)
                let wantsGateway = (flags & RTF_GATEWAY) != 0
                let hasDstAndGw = (addrs & RTA_DST) != 0 && (addrs & RTA_GATEWAY) != 0

                if wantsGateway && hasDstAndGw {
                    var p = offset + hdrSize
                    let msgEnd = offset + msgLen
                    var dstIsDefault = false
                    var gateway: String?

                    for i in 0..<8 {                 // RTAX_MAX
                        let bit = Int32(1 << i)
                        if (addrs & bit) == 0 { continue }
                        guard p + 2 <= msgEnd else { break }
                        let saLen = Int(raw[p])       // sockaddr.sa_len (byte 0)
                        let family = raw[p + 1]       // sockaddr.sa_family (byte 1)

                        if i == 0 {                   // RTAX_DST
                            if saLen <= 2 {
                                dstIsDefault = true   // wildcard destination
                            } else if family == UInt8(AF_INET), p + 8 <= msgEnd {
                                let s = raw.loadUnaligned(fromByteOffset: p + 4, as: in_addr.self)
                                if s.s_addr == 0 { dstIsDefault = true }
                            }
                        } else if i == 1,             // RTAX_GATEWAY
                                  family == UInt8(AF_INET),
                                  p + 8 <= msgEnd {
                            var s = raw.loadUnaligned(fromByteOffset: p + 4, as: in_addr.self)
                            var cstr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            if inet_ntop(AF_INET, &s, &cstr, socklen_t(INET_ADDRSTRLEN)) != nil {
                                gateway = String(cString: cstr)
                            }
                        }

                        // Advance to the next sockaddr (4-byte aligned, min 4).
                        let advance = saLen == 0 ? 4 : (saLen + 3) & ~3
                        p += advance
                        if p > msgEnd { break }
                    }

                    if dstIsDefault, let gw = gateway { return gw }
                }
                offset += msgLen
            }
            return nil
        }
    }

    // MARK: - Wi-Fi (CoreWLAN)

    /// Best-effort Wi-Fi read. On recent macOS `ssid()` returns nil without
    /// Location permission — handled gracefully (nil SSID), never a crash.
    static func readWiFi() -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        // If there's no signal at all, treat Wi-Fi as absent (e.g. Ethernet-only).
        let rssi = iface.rssiValue()
        let channel = iface.wlanChannel()?.channelNumber
        let ssid = iface.ssid() // may be nil (permission) or when not associated
        if ssid == nil && rssi == 0 && channel == nil { return nil }
        return WiFiInfo(ssid: ssid, rssi: rssi == 0 ? nil : rssi, channel: channel)
    }
}

// MARK: - Popover UI

private struct NetworkPopover: View {
    let plugin: NetworkPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status header + connection type + manual "Test now".
            HStack(spacing: 6) {
                Circle()
                    .fill(plugin.isOnline ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(plugin.connectionType.label)
                    .font(.headline)
                    .foregroundStyle(plugin.isOnline ? .green : .red)
                if plugin.isOnline {
                    Image(systemName: plugin.connectionType.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await plugin.refresh() }
                } label: {
                    if plugin.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test now", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(plugin.isRefreshing)
                .help("Re-run all probes now")
            }

            if plugin.showPublicIP {
                NetworkRow(label: "Public IP", systemImage: "globe") {
                    HStack(spacing: 6) {
                        Text(plugin.publicIP ?? "—")
                            .font(.body.monospacedDigit())
                        if let ip = plugin.publicIP {
                            NetworkCopyButton(value: ip, help: "Copy public IP")
                        }
                    }
                }
            }

            if plugin.showGateway {
                NetworkRow(label: "Gateway", systemImage: "arrow.up.arrow.down.circle") {
                    HStack(spacing: 6) {
                        Text(plugin.gatewayIP ?? "—")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(plugin.gatewayIP == nil ? .secondary : .primary)
                        if let gw = plugin.gatewayIP {
                            NetworkCopyButton(value: gw, help: "Copy gateway IP")
                        }
                    }
                }
            }

            if plugin.showLatency {
                NetworkRow(label: "Latency", systemImage: "timer") {
                    if let ms = plugin.latencyMs {
                        Text(String(format: "%.0f ms", ms))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Self.latencyColor(ms))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }

                // Jitter history for the primary host.
                if plugin.latencyHistory.count > 1 {
                    NetworkLatencySparkline(values: plugin.latencyHistory)
                        .frame(height: 22)
                        .padding(.leading, 2)
                }

                // Per-host latency list.
                NetworkHostList(plugin: plugin)
                    .padding(.top, 2)
            }

            if plugin.showWiFi, let wifi = plugin.wifi {
                NetworkRow(label: "Wi-Fi", systemImage: "wifi") {
                    HStack(spacing: 8) {
                        if let ssid = wifi.ssid {
                            Text(ssid).font(.body)
                            NetworkCopyButton(value: ssid, help: "Copy SSID")
                        } else {
                            Text("SSID hidden — needs Location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        NetworkBars(bars: wifi.bars)
                        if let rssi = wifi.rssi {
                            Text("\(rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if plugin.showVPN {
                NetworkRow(label: "VPN", systemImage: "lock.shield") {
                    if let vpn = plugin.vpnInterface {
                        Text("On · \(vpn.name)")
                            .foregroundStyle(.green)
                    } else {
                        Text("Off").foregroundStyle(.secondary)
                    }
                }
            }

            if plugin.showInterfaces {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Interfaces", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if plugin.interfaces.isEmpty {
                        Text("None active").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(plugin.interfaces) { iface in
                            HStack {
                                Text(iface.name)
                                    .font(.caption.weight(.medium))
                                    .frame(width: 66, alignment: .leading)
                                Text(iface.ipv4)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if iface.isVPN {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                NetworkCopyButton(value: iface.ipv4, help: "Copy \(iface.name) IP")
                                    .font(.caption2)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    static func latencyColor(_ ms: Double) -> Color {
        if ms > 400 { return .red }
        if ms > 150 { return .orange }
        return .green
    }
}

/// The per-host latency list shown in the popover.
private struct NetworkHostList: View {
    let plugin: NetworkPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Hosts", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if plugin.hosts.isEmpty {
                Text("No hosts configured — add one in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(plugin.hosts) { host in
                    let sample = plugin.hostSamples[host.id]
                    HStack(spacing: 6) {
                        Image(systemName: host.url == plugin.latencyHost ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(host.url == plugin.latencyHost ? .yellow : .secondary)
                        Text(host.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let sample {
                            if let ms = sample.latencyMs {
                                Text(String(format: "%.0f ms", ms))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(NetworkPopover.latencyColor(ms))
                            } else {
                                Text("down")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Text("—").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// A label + trailing value row used throughout the popover.
private struct NetworkRow<Content: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.callout)
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 4)
            content()
        }
    }
}

/// A one-tap clipboard copy button for a string value.
private struct NetworkCopyButton: View {
    let value: String
    let help: String

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// A 0…3 signal-bars indicator.
private struct NetworkBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 5 + CGFloat(i) * 4)
            }
        }
    }
}

/// A minimal line chart for the rolling latency history (lower = better, so it
/// is not direction-coloured like the Stocks sparkline).
private struct NetworkLatencySparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max(), hi > lo {
                let w = geo.size.width
                let h = geo.size.height
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(values.count - 1)
                        let y = h * (1 - CGFloat((v - lo) / (hi - lo)))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            } else {
                Rectangle().fill(.quaternary).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - Settings UI

private struct NetworkSettings: View {
    @Bindable var plugin: NetworkPlugin
    @State private var newName: String = ""
    @State private var newURL: String = ""

    private var canAdd: Bool {
        !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsPage("Latency hosts", intro: "Hosts pinged for the reachability / latency probe. The starred host drives the headline and the history sparkline.") {
            if plugin.hosts.isEmpty {
                SettingsHelp("No hosts — add one below.")
            } else {
                List {
                    ForEach(plugin.hosts) { host in
                        HStack(spacing: 8) {
                            Button {
                                plugin.makePrimary(host)
                            } label: {
                                Image(systemName: host.url == plugin.latencyHost ? "star.fill" : "star")
                                    .foregroundStyle(host.url == plugin.latencyHost ? .yellow : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Make primary")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.name).font(.callout)
                                Text(host.url)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { plugin.deleteHosts(at: $0) }
                    .onMove { plugin.moveHosts(from: $0, to: $1) }
                }
                .frame(height: 150)
            }

            HStack(spacing: 6) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                TextField("https://example.com", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    plugin.addHost(name: newName, url: newURL)
                    newName = ""
                    newURL = ""
                    Task { await plugin.refresh() }
                }
                .disabled(!canAdd)
            }

            Divider()

            HStack {
                Text("Refresh every")
                Picker("", selection: $plugin.refreshSeconds) {
                    Text("15s").tag(TimeInterval(15))
                    Text("30s").tag(TimeInterval(30))
                    Text("1m").tag(TimeInterval(60))
                    Text("2m").tag(TimeInterval(120))
                    Text("5m").tag(TimeInterval(300))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            SettingsSectionHeader("Rows to show")
            SettingsToggleRow("Public IP", isOn: $plugin.showPublicIP)
            SettingsToggleRow("Gateway", isOn: $plugin.showGateway)
            SettingsToggleRow("Latency, history & hosts", isOn: $plugin.showLatency)
            SettingsToggleRow("Wi-Fi", isOn: $plugin.showWiFi)
            SettingsToggleRow("VPN", isOn: $plugin.showVPN)
            SettingsToggleRow("Interfaces", isOn: $plugin.showInterfaces)
        }
    }
}
