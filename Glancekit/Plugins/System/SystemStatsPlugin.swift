import SwiftUI
import Observation
import Foundation

/// "Mac health" glance: local system metrics only, no network access.
///
/// Each metric is an independent, user-toggleable readout persisted in
/// `UserDefaults` under keys namespaced `glancekit.system.<metric>`. All
/// underlying syscalls live in `SystemMetrics.swift` and are defensive —
/// `refresh()` never crashes, showing "—" for any metric it can't read.
@MainActor
@Observable
final class SystemStatsPlugin: GlancePlugin {
    nonisolated var id: String { "system" }
    nonisolated var title: String { "Mac Health" }
    nonisolated var iconSystemName: String { "cpu" }
    var refreshInterval: TimeInterval { 3 }

    // MARK: - Per-metric toggles (persisted)

    enum Metric: String, CaseIterable, Identifiable {
        case cpu, ram, battery, disk, network, vpn, bluetooth, uptime
        var id: String { rawValue }

        var label: String {
            switch self {
            case .cpu: return "CPU usage"
            case .ram: return "RAM"
            case .battery: return "Battery"
            case .disk: return "Disk free"
            case .network: return "Network throughput"
            case .vpn: return "VPN status"
            case .bluetooth: return "Bluetooth battery"
            case .uptime: return "Uptime"
            }
        }

        var icon: String {
            switch self {
            case .cpu: return "cpu"
            case .ram: return "memorychip"
            case .battery: return "battery.100"
            case .disk: return "internaldrive"
            case .network: return "arrow.up.arrow.down.circle"
            case .vpn: return "lock.shield"
            case .bluetooth: return "dot.radiowaves.left.and.right"
            case .uptime: return "clock.arrow.circlepath"
            }
        }

        var defaultsKey: String { "glancekit.system.\(rawValue)" }
    }

    private(set) var enabledMetrics: Set<Metric>

    func isEnabled(_ metric: Metric) -> Bool { enabledMetrics.contains(metric) }

    func setEnabled(_ metric: Metric, _ enabled: Bool) {
        if enabled { enabledMetrics.insert(metric) } else { enabledMetrics.remove(metric) }
        UserDefaults.standard.set(enabled, forKey: metric.defaultsKey)
    }

    // MARK: - Observable readouts

    private(set) var cpuUsagePercent: Double?
    private(set) var memoryUsedBytes: UInt64?
    private(set) var memoryTotalBytes: UInt64?
    private(set) var batteryInfo: SystemMetrics.BatteryInfo?
    private(set) var diskFreeBytes: Int64?
    private(set) var networkDownBytesPerSec: Double?
    private(set) var networkUpBytesPerSec: Double?
    private(set) var vpnActive: Bool?
    private(set) var bluetoothDevices: [SystemMetrics.BluetoothDevice] = []
    private(set) var uptimeSeconds: TimeInterval?
    private(set) var lastError: String?

    // Sampling state for delta-based metrics.
    private var lastCPUTicks: SystemMetrics.CPUTicks?
    private var lastInterfaceCounts: SystemMetrics.InterfaceByteCounts?
    private var lastSampleDate: Date?

    init() {
        let defaults = UserDefaults.standard
        var initial = Set<Metric>()
        for metric in Metric.allCases {
            // Default to enabled on first launch (key absent).
            if defaults.object(forKey: metric.defaultsKey) == nil || defaults.bool(forKey: metric.defaultsKey) {
                initial.insert(metric)
            }
        }
        enabledMetrics = initial
    }

    // MARK: GlancePlugin

    func refresh() async {
        // CPU: needs a delta between two tick snapshots.
        if let ticks = SystemMetrics.readCPUTicks() {
            if let previous = lastCPUTicks {
                cpuUsagePercent = SystemMetrics.cpuUsagePercent(previous: previous, current: ticks)
            }
            lastCPUTicks = ticks
        } else {
            cpuUsagePercent = nil
        }

        // RAM
        if let mem = SystemMetrics.readMemoryInfo() {
            memoryUsedBytes = mem.usedBytes
            memoryTotalBytes = mem.totalBytes
        } else {
            memoryUsedBytes = nil
            memoryTotalBytes = nil
        }

        // Battery
        batteryInfo = SystemMetrics.readBatteryInfo()

        // Disk
        diskFreeBytes = SystemMetrics.readDiskFreeBytes()

        // Network throughput + VPN presence (share one getifaddrs pass).
        let now = Date()
        if let counts = SystemMetrics.readInterfaceByteCounts() {
            vpnActive = counts.hasUTun
            if let previousCounts = lastInterfaceCounts, let previousDate = lastSampleDate {
                let elapsed = now.timeIntervalSince(previousDate)
                if let rates = SystemMetrics.throughput(previous: previousCounts, current: counts, elapsedSeconds: elapsed) {
                    networkDownBytesPerSec = rates.down
                    networkUpBytesPerSec = rates.up
                }
            }
            lastInterfaceCounts = counts
            lastSampleDate = now
        } else {
            vpnActive = nil
            networkDownBytesPerSec = nil
            networkUpBytesPerSec = nil
        }

        // Bluetooth (best-effort, never throws)
        bluetoothDevices = SystemMetrics.readBluetoothDevices()

        // Uptime
        uptimeSeconds = SystemMetrics.uptimeSeconds()

        lastError = nil
    }

    func popoverSection() -> AnyView {
        AnyView(SystemStatsPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(SystemStatsSettings(plugin: self))
    }

    // MARK: - Formatting helpers

    static func formatBytes(_ bytes: UInt64) -> String {
        String(format: "%.1fG", Double(bytes) / 1_073_741_824)
    }

    static func formatRate(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1024 { return String(format: "%.0fKB/s", kb) }
        return String(format: "%.1fMB/s", kb / 1024)
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Popover UI

private struct SystemStatsPopover: View {
    let plugin: SystemStatsPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let enabled = SystemStatsPlugin.Metric.allCases.filter { plugin.isEnabled($0) }
            if enabled.isEmpty {
                Text("No metrics enabled. Turn some on in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(enabled) { metric in
                    HStack(spacing: 10) {
                        Image(systemName: metric.icon)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(metric.label)
                            .font(.body)
                        Spacer()
                        Text(valueText(for: metric))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func valueText(for metric: SystemStatsPlugin.Metric) -> String {
        switch metric {
        case .cpu:
            guard let v = plugin.cpuUsagePercent else { return "—" }
            return String(format: "%.0f%%", v)
        case .ram:
            guard let used = plugin.memoryUsedBytes, let total = plugin.memoryTotalBytes else { return "—" }
            return "\(SystemStatsPlugin.formatBytes(used)) / \(SystemStatsPlugin.formatBytes(total))"
        case .battery:
            guard let b = plugin.batteryInfo else { return "—" }
            var text = "\(b.percentage)%"
            if b.isCharging { text += " ⚡" }
            if let minutes = b.timeRemainingMinutes {
                text += " (\(minutes / 60)h\(minutes % 60)m)"
            }
            return text
        case .disk:
            guard let free = plugin.diskFreeBytes else { return "—" }
            return String(format: "%.1f GB free", Double(free) / 1_073_741_824)
        case .network:
            guard let down = plugin.networkDownBytesPerSec, let up = plugin.networkUpBytesPerSec else { return "—" }
            return "↓\(SystemStatsPlugin.formatRate(down)) ↑\(SystemStatsPlugin.formatRate(up))"
        case .vpn:
            guard let active = plugin.vpnActive else { return "—" }
            return active ? "Connected" : "Off"
        case .bluetooth:
            guard let first = plugin.bluetoothDevices.first else { return "—" }
            if let pct = first.batteryPercent { return "\(first.name): \(pct)%" }
            return "\(first.name): —"
        case .uptime:
            guard let seconds = plugin.uptimeSeconds else { return "—" }
            return SystemStatsPlugin.formatUptime(seconds)
        }
    }
}

// MARK: - Settings UI

private struct SystemStatsSettings: View {
    @Bindable var plugin: SystemStatsPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Metrics")
                .font(.headline)
            Text("Choose which local system metrics to show. Nothing here uses the network.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(SystemStatsPlugin.Metric.allCases) { metric in
                Toggle(isOn: Binding(
                    get: { plugin.isEnabled(metric) },
                    set: { plugin.setEnabled(metric, $0) }
                )) {
                    Label(metric.label, systemImage: metric.icon)
                }
            }
        }
    }
}
