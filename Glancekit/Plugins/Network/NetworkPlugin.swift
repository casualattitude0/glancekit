import SwiftUI
import Observation
import CoreWLAN
import Darwin

/// Network / connectivity glance.
///
/// Goes beyond the throughput + VPN readout of the System (Mac Health) glance by
/// adding: an HTTP-measured reachability/latency probe, the public IP (throttled),
/// a per-interface IPv4 listing, VPN (`utun`) detection, and live Wi-Fi SSID +
/// signal strength via CoreWLAN.
///
/// Everything here is defensive — `refresh()` never throws and treats a failed
/// probe as a clean "Offline" state rather than an error crash.
@MainActor
@Observable
final class NetworkPlugin: GlancePlugin {
    nonisolated var id: String { "network" }
    nonisolated var title: String { "Network" }
    nonisolated var iconSystemName: String { "network" }
    var refreshInterval: TimeInterval { 30 }

    // MARK: Persisted prefs (non-secret → UserDefaults, namespaced)

    /// The host used for the HTTP reachability/latency probe.
    var latencyHost: String {
        didSet {
            guard latencyHost != oldValue else { return }
            UserDefaults.standard.set(latencyHost, forKey: Keys.latencyHost)
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

    private enum Keys {
        static let latencyHost = "glancekit.network.latencyHost"
        static let showPublicIP = "glancekit.network.showPublicIP"
        static let showLatency = "glancekit.network.showLatency"
        static let showWiFi = "glancekit.network.showWiFi"
        static let showVPN = "glancekit.network.showVPN"
        static let showInterfaces = "glancekit.network.showInterfaces"
    }

    /// Preset probe hosts offered in settings. All are lightweight endpoints.
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

    // MARK: Observed state

    private(set) var isOnline: Bool = false
    private(set) var latencyMs: Double?
    private(set) var publicIP: String?
    private(set) var interfaces: [NetInterface] = []
    private(set) var wifi: WiFiInfo?
    private(set) var lastError: String?

    /// The IPv4-carrying `utun` interface, if any (a live VPN tunnel).
    var vpnInterface: NetInterface? {
        interfaces.first { $0.isVPN }
    }

    private var lastPublicIPFetch: Date?
    private let publicIPTTL: TimeInterval = 300 // refetch public IP at most every 5 min
    private let client = NetworkClient(timeout: 8)

    // MARK: Value types

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

    // MARK: Init

    init() {
        let d = UserDefaults.standard
        latencyHost = d.string(forKey: Keys.latencyHost) ?? NetworkPlugin.latencyPresets[0].url
        showPublicIP = d.object(forKey: Keys.showPublicIP) as? Bool ?? true
        showLatency = d.object(forKey: Keys.showLatency) as? Bool ?? true
        showWiFi = d.object(forKey: Keys.showWiFi) as? Bool ?? true
        showVPN = d.object(forKey: Keys.showVPN) as? Bool ?? true
        showInterfaces = d.object(forKey: Keys.showInterfaces) as? Bool ?? true
    }

    // MARK: GlancePlugin

    func refresh() async {
        // Local reads first — these never touch the network and always succeed.
        interfaces = Self.readInterfaces()
        wifi = Self.readWiFi()

        // Reachability / latency probe.
        var reachable = false
        let start = Date()
        do {
            _ = try await client.data(from: latencyHost)
            latencyMs = Date().timeIntervalSince(start) * 1000
            reachable = true
            lastError = nil
        } catch {
            latencyMs = nil
            // Not necessarily fatal for the user, but this is our online signal.
        }

        isOnline = reachable

        // Public IP — throttled, and only worth fetching when we look online.
        if reachable {
            let due = lastPublicIPFetch.map { Date().timeIntervalSince($0) >= publicIPTTL } ?? true
            if due || publicIP == nil {
                await fetchPublicIP()
            }
        } else {
            // Offline is a clean state, not an error.
            lastError = "Offline"
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
        // Otherwise surface an ambient "Online" card, using Wi-Fi strength as a
        // gauge when we have it.
        if let ms = latencyMs {
            let accessory: GlanceSignal.Accessory
            if let bars = wifi?.bars, wifi?.rssi != nil {
                accessory = .gauge(Double(bars) / 3.0)
            } else {
                accessory = .none
            }
            return GlanceSignal(priority: .ambient, score: 1,
                                headline: String(format: "Online · %.0fms", ms),
                                systemImage: "wifi", tint: .green,
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
            // Status header.
            HStack(spacing: 6) {
                Circle()
                    .fill(plugin.isOnline ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(plugin.isOnline ? "Online" : "Offline")
                    .font(.headline)
                    .foregroundStyle(plugin.isOnline ? .green : .red)
                Spacer()
            }

            if plugin.showPublicIP {
                NetworkRow(label: "Public IP", systemImage: "globe") {
                    HStack(spacing: 6) {
                        Text(plugin.publicIP ?? "—")
                            .font(.body.monospacedDigit())
                        if let ip = plugin.publicIP {
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(ip, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy public IP")
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
            }

            if plugin.showWiFi, let wifi = plugin.wifi {
                NetworkRow(label: "Wi-Fi", systemImage: "wifi") {
                    HStack(spacing: 8) {
                        if let ssid = wifi.ssid {
                            Text(ssid).font(.body)
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

// MARK: - Settings UI

private struct NetworkSettings: View {
    @Bindable var plugin: NetworkPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Latency test host")
                .font(.headline)
            Text("Which endpoint to time for the reachability / latency probe.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Host", selection: $plugin.latencyHost) {
                ForEach(NetworkPlugin.latencyPresets) { preset in
                    Text(preset.name).tag(preset.url)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: plugin.latencyHost) {
                Task { await plugin.refresh() }
            }

            Divider()

            Text("Rows to show")
                .font(.headline)
            Toggle("Public IP", isOn: $plugin.showPublicIP)
            Toggle("Latency", isOn: $plugin.showLatency)
            Toggle("Wi-Fi", isOn: $plugin.showWiFi)
            Toggle("VPN", isOn: $plugin.showVPN)
            Toggle("Interfaces", isOn: $plugin.showInterfaces)
        }
    }
}
