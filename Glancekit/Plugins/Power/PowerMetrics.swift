import Foundation
import IOKit
import IOKit.ps

/// Network-free, richer-than-basic power/battery reader for `PowerPlugin`.
///
/// Two sources are combined:
/// - **IOPowerSources** (`IOPSCopy…`) for the live charge %, charge state, and
///   time-to-empty / time-to-full — the fast, blessed API.
/// - **AppleSmartBattery IORegistry** for the deep hardware stats the basic
///   battery readout lacks: cycle count, design vs. current max capacity
///   (→ health %), temperature, and any failure/condition flags.
///
/// Every accessor is defensive: a missing key or failed syscall yields `nil`
/// (never a throw or crash), so the UI can always fall back to "—".
enum PowerMetrics {

    // MARK: - Aggregate snapshot

    struct Snapshot {
        /// True when no battery power source is present (desktop Mac).
        var hasBattery: Bool = false

        // From IOPowerSources
        var percentage: Int?
        var state: ChargeState = .unknown
        var powerSource: PowerSource = .unknown
        /// Minutes until empty (discharging) — nil if unknown/calculating.
        var timeToEmptyMinutes: Int?
        /// Minutes until full (charging) — nil if unknown/calculating.
        var timeToFullMinutes: Int?

        // From AppleSmartBattery
        var cycleCount: Int?
        var designCapacity: Int?
        var maxCapacity: Int?
        /// maxCapacity / designCapacity * 100, when both are present.
        var healthPercent: Int?
        /// Degrees Celsius.
        var temperatureC: Double?
        /// Battery condition string, e.g. "Normal" / "Service Recommended".
        var condition: String?
        /// True when a permanent-failure flag is set.
        var permanentFailure: Bool = false

        // From IOPSCopyExternalPowerAdapterDetails
        var adapterWatts: Int?

        // Instantaneous electrical readings (AppleSmartBattery).
        /// Signed battery current in milliamps: negative while discharging,
        /// positive while charging. `nil` when the key is absent/implausible.
        var amperageMA: Int?
        /// Battery terminal voltage in millivolts. `nil` when absent.
        var voltageMV: Int?

        /// Instantaneous power in watts (|Amperage| × Voltage), signed the same
        /// way as `amperageMA`: negative = draining, positive = charging. `nil`
        /// unless both amperage and voltage are available.
        var powerWatts: Double? {
            guard let mA = amperageMA, let mV = voltageMV else { return nil }
            return (Double(mA) / 1000.0) * (Double(mV) / 1000.0)
        }

        /// Present full-charge capacity in mAh (AppleRawMaxCapacity / MaxCapacity)
        /// — only surfaced when it looks like a real mAh figure rather than a
        /// legacy percentage. `nil` otherwise.
        var fullChargeCapacityMAh: Int? {
            guard let m = maxCapacity, m > 500 else { return nil }
            return m
        }

        /// Health is considered degraded when the OS flags a non-normal
        /// condition, a permanent failure, or health drops below 80%.
        var healthIsDegraded: Bool {
            if permanentFailure { return true }
            if let condition, !condition.isEmpty,
               condition.caseInsensitiveCompare("Normal") != .orderedSame {
                return true
            }
            if let healthPercent, healthPercent < 80 { return true }
            return false
        }
    }

    enum ChargeState {
        case charging, charged, discharging, unknown
    }

    enum PowerSource {
        case ac, battery, unknown
    }

    // MARK: - Public entry point

    /// Reads everything, combining all sources. Never throws; on a desktop the
    /// returned snapshot has `hasBattery == false`.
    static func read() -> Snapshot {
        var snap = Snapshot()
        readPowerSources(into: &snap)
        readSmartBattery(into: &snap)
        snap.adapterWatts = readAdapterWatts()
        return snap
    }

    // MARK: - IOPowerSources

    private static func readPowerSources(into snap: inout Snapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            // Only care about the internal battery source.
            let type = desc[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }

            snap.hasBattery = true

            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
               let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0 {
                snap.percentage = Int((Double(capacity) / Double(maxCap) * 100).rounded())
            }

            if let sourceState = desc[kIOPSPowerSourceStateKey] as? String {
                snap.powerSource = (sourceState == kIOPSACPowerValue) ? .ac : .battery
            }

            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let isCharged = (desc[kIOPSIsChargedKey] as? Bool) ?? false
            if isCharged {
                snap.state = .charged
            } else if isCharging {
                snap.state = .charging
            } else {
                snap.state = .discharging
            }

            if let tte = desc[kIOPSTimeToEmptyKey] as? Int, tte > 0 {
                snap.timeToEmptyMinutes = tte
            }
            if let ttf = desc[kIOPSTimeToFullChargeKey] as? Int, ttf > 0 {
                snap.timeToFullMinutes = ttf
            }
            return
        }
    }

    // MARK: - AppleSmartBattery IORegistry

    private static func readSmartBattery(into snap: inout Snapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
        else { return }

        snap.hasBattery = true

        if let cycles = props["CycleCount"] as? Int { snap.cycleCount = cycles }

        if let design = props["DesignCapacity"] as? Int, design > 0 {
            snap.designCapacity = design
        }

        // AppleRawMaxCapacity is the truest full-charge capacity on Apple
        // Silicon; MaxCapacity is the fallback on older hardware.
        if let rawMax = props["AppleRawMaxCapacity"] as? Int, rawMax > 0 {
            snap.maxCapacity = rawMax
        } else if let maxCap = props["MaxCapacity"] as? Int, maxCap > 0 {
            snap.maxCapacity = maxCap
        }

        if let design = snap.designCapacity, let maxCap = snap.maxCapacity, design > 0 {
            snap.healthPercent = min(100, Int((Double(maxCap) / Double(design) * 100).rounded()))
        }

        if let raw = props["Temperature"] as? Int {
            snap.temperatureC = convertTemperature(raw)
        }

        // Instantaneous current (signed) and terminal voltage. Both are
        // best-effort: absent or implausible values simply stay nil.
        if let rawAmp = props["Amperage"] as? Int {
            snap.amperageMA = normalizedAmperage(rawAmp)
        } else if let rawAmp = props["InstantAmperage"] as? Int {
            snap.amperageMA = normalizedAmperage(rawAmp)
        }
        if let mV = props["Voltage"] as? Int, mV > 0, mV < 30000 {
            snap.voltageMV = mV
        }

        if let condition = props["BatteryHealthCondition"] as? String, !condition.isEmpty {
            snap.condition = condition
        } else if let serviceFlag = props["PermanentFailureStatus"] as? Int, serviceFlag != 0 {
            snap.condition = "Service Recommended"
        }

        if let pf = props["PermanentFailureStatus"] as? Int, pf != 0 {
            snap.permanentFailure = true
        }
    }

    /// AppleSmartBattery's `Temperature` is reported in centi-°C on Apple
    /// hardware (e.g. 3012 → 30.12 °C). Some machines report deci-Kelvin
    /// instead; disambiguate by magnitude and fall back to a sane range.
    private static func convertTemperature(_ raw: Int) -> Double? {
        guard raw > 0 else { return nil }
        // Centi-°C: value / 100 lands in a plausible 0–80 °C window.
        let asCentiC = Double(raw) / 100.0
        if asCentiC > 0 && asCentiC < 80 { return asCentiC }
        // Deci-Kelvin: (value / 10) - 273.15.
        let asKelvin = Double(raw) / 10.0 - 273.15
        if asKelvin > -20 && asKelvin < 120 { return asKelvin }
        return nil
    }

    /// AppleSmartBattery's `Amperage` is a signed current, but some machines
    /// surface it as an unsigned value that has wrapped past 2^31. Fold it back
    /// into a signed range and reject anything outside a plausible ±30 A band.
    private static func normalizedAmperage(_ raw: Int) -> Int? {
        var v = raw
        if v > Int(Int32.max) { v -= Int(UInt32.max) + 1 }
        guard abs(v) <= 30000 else { return nil }
        return v
    }

    // MARK: - Power adapter

    private static func readAdapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else { return nil }
        if let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 {
            return watts
        }
        return nil
    }
}
