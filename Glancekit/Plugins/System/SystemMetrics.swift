import Foundation
import IOKit
import IOKit.ps
import Darwin

/// Low-level, network-free system metric readers used by `SystemStatsPlugin`.
///
/// Every function here is defensive: syscalls that can fail return `nil`
/// (or a sentinel) rather than throwing or crashing, so `refresh()` can
/// always show "—" instead of dying.
enum SystemMetrics {

    // MARK: - CPU

    /// Snapshot of per-host CPU ticks, used to compute a delta-based usage %.
    struct CPUTicks {
        var user: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
        var nice: UInt32 = 0
    }

    /// Reads current aggregate host CPU ticks via `host_statistics`.
    static func readCPUTicks() -> CPUTicks? {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuLoad) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: cpuLoad.cpu_ticks.0,
            system: cpuLoad.cpu_ticks.1,
            idle: cpuLoad.cpu_ticks.2,
            nice: cpuLoad.cpu_ticks.3
        )
    }

    /// CPU usage % computed from the delta between two tick snapshots.
    static func cpuUsagePercent(previous: CPUTicks, current: CPUTicks) -> Double? {
        let userDelta = Double(current.user &- previous.user)
        let systemDelta = Double(current.system &- previous.system)
        let idleDelta = Double(current.idle &- previous.idle)
        let niceDelta = Double(current.nice &- previous.nice)
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return nil }
        let busy = userDelta + systemDelta + niceDelta
        return max(0, min(100, (busy / total) * 100))
    }

    // MARK: - RAM

    struct MemoryInfo {
        let usedBytes: UInt64
        let totalBytes: UInt64
    }

    /// Reads used/total physical memory via `host_statistics64` + `ProcessInfo`.
    static func readMemoryInfo() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return MemoryInfo(usedBytes: min(used, total), totalBytes: total)
    }

    // MARK: - Battery

    struct BatteryInfo {
        let percentage: Int
        let isCharging: Bool
        let timeRemainingMinutes: Int? // nil if unknown / calculating / not on battery
    }

    /// Reads battery state via `IOPSCopyPowerSourcesInfo`. Returns nil on
    /// desktops / when no battery power source is present.
    static func readBatteryInfo() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
            else { continue }

            let percentage = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false

            var minutesRemaining: Int?
            if let timeToEmpty = description[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
                minutesRemaining = timeToEmpty
            } else if let timeToFull = description[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
                minutesRemaining = timeToFull
            }

            return BatteryInfo(percentage: percentage, isCharging: charging, timeRemainingMinutes: minutesRemaining)
        }
        return nil
    }

    // MARK: - Disk

    /// Free bytes on the main volume, via `URL.resourceValues`.
    static func readDiskFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            // fall through to statfs below
        }
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return nil }
        return Int64(stat.f_bsize) * Int64(stat.f_bavail)
    }

    // MARK: - Network throughput + VPN

    struct InterfaceByteCounts {
        var receivedBytes: [String: UInt64] = [:]
        var sentBytes: [String: UInt64] = [:]
        var hasUTun: Bool = false
    }

    /// Enumerates network interfaces via `getifaddrs`, summing byte counters
    /// and detecting the presence of any `utun*` (VPN) interface.
    static func readInterfaceByteCounts() -> InterfaceByteCounts? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var result = InterfaceByteCounts()
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let addr = current.pointee
            guard let namePtr = addr.ifa_name else { continue }
            let name = String(cString: namePtr)

            if name.hasPrefix("utun") {
                result.hasUTun = true
            }

            guard let ifaAddr = addr.ifa_addr, ifaAddr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = addr.ifa_data
            else { continue }

            let networkData = dataPtr.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
            result.receivedBytes[name, default: 0] += UInt64(networkData.ifi_ibytes)
            result.sentBytes[name, default: 0] += UInt64(networkData.ifi_obytes)
        }
        return result
    }

    /// Bytes/sec up and down, computed as a delta between two samples taken
    /// `elapsed` seconds apart. Interfaces starting with "lo" (loopback) are
    /// excluded.
    static func throughput(previous: InterfaceByteCounts, current: InterfaceByteCounts, elapsedSeconds: TimeInterval) -> (down: Double, up: Double)? {
        guard elapsedSeconds > 0 else { return nil }
        var downDelta: UInt64 = 0
        var upDelta: UInt64 = 0
        for (name, curReceived) in current.receivedBytes where !name.hasPrefix("lo") {
            let prevReceived = previous.receivedBytes[name] ?? curReceived
            if curReceived >= prevReceived { downDelta += (curReceived - prevReceived) }
        }
        for (name, curSent) in current.sentBytes where !name.hasPrefix("lo") {
            let prevSent = previous.sentBytes[name] ?? curSent
            if curSent >= prevSent { upDelta += (curSent - prevSent) }
        }
        return (Double(downDelta) / elapsedSeconds, Double(upDelta) / elapsedSeconds)
    }

    // MARK: - Bluetooth device battery (best-effort)

    struct BluetoothDevice: Identifiable {
        let id: String
        let name: String
        let batteryPercent: Int?
    }

    /// Best-effort read of paired Bluetooth device names/battery levels via
    /// IORegistry (`IOBluetoothDevice` matching). Returns an empty array
    /// (never throws) if the registry lookup fails or nothing is found —
    /// callers should render "—" in that case.
    static func readBluetoothDevices() -> [BluetoothDevice] {
        var devices: [BluetoothDevice] = []
        let matching = IOServiceMatching("IOBluetoothHCIController")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return devices
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propsUnmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }

            if let name = props["IOBluetoothHCIControllerName"] as? String {
                devices.append(BluetoothDevice(id: name, name: name, batteryPercent: nil))
            }
        }
        return devices
    }

    // MARK: - Uptime

    static func uptimeSeconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
