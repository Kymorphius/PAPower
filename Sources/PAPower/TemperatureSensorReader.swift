import Foundation
import Darwin
import PAPowerTemperatureBridge

struct RawTemperatureSensor {
    let name: String
    let identifier: String
    let celsius: Double
}

final class TemperatureSensorReader {
    private enum ChipGeneration {
        case m1, m2, m3, m4, m5, intel, unknown
    }

    private let smc: SMCClient
    private let generation: ChipGeneration
    private let minimumRefreshInterval: TimeInterval = 5
    private var lastCaptureTimestamp: TimeInterval?
    private var cachedTemperatures = ComponentTemperatures.empty

    init(smc: SMCClient = SMCClient()) {
        self.smc = smc
        self.generation = Self.detectChipGeneration()
    }

    func capture(force: Bool = false) -> ComponentTemperatures {
        let now = ProcessInfo.processInfo.systemUptime
        if !force,
           let lastCaptureTimestamp,
           now - lastCaptureTimestamp < minimumRefreshInterval {
            return cachedTemperatures
        }

        let hidSensors = shouldReadHIDSensors ? readRawSensors() : []
        let cpu = hottestHIDTemperature(
            in: hidSensors,
            preferredPrefixes: [
                "pacc mtr temp sensor", "eacc mtr temp sensor",
                "cpu", "pmu tdie"
            ],
            fallbackPrefixes: ["pmu tdev"]
        )
            ?? firstValidSMCValue(for: cpuHotspotKeys)
            ?? maximumValidSMCValue(for: cpuCoreKeys)
        let gpu = hottestHIDTemperature(
            in: hidSensors,
            preferredPrefixes: ["gpu mtr temp sensor", "gpu", "pmu2 tdie"],
            fallbackPrefixes: ["pmu2 tdev"]
        )
            ?? maximumValidSMCValue(for: gpuCoreKeys)
        let storage = hottestHIDTemperature(
            in: hidSensors,
            nameContains: ["nand"]
        )
            ?? firstValidSMCValue(for: storageKeys)

        cachedTemperatures = ComponentTemperatures(
            cpuCelsius: cpu,
            gpuCelsius: gpu,
            storageCelsius: storage.flatMap {
                Self.isPlausibleTemperature($0) ? $0 : nil
            }
        )
        lastCaptureTimestamp = now
        return cachedTemperatures
    }

    func readRawSensors() -> [RawTemperatureSensor] {
        var buffer = [PATemperatureSensorReading](
            repeating: PATemperatureSensorReading(),
            count: 128
        )
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            PAReadTemperatureSensors(pointer.baseAddress, Int32(pointer.count))
        }
        guard count > 0 else { return [] }

        return buffer.prefix(Int(count)).map { reading in
            RawTemperatureSensor(
                name: string(from: reading.name),
                identifier: string(from: reading.identifier),
                celsius: reading.celsius
            )
        }
    }

    private func string<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            guard let baseAddress = bytes.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }

    private var cpuHotspotKeys: [String] {
        switch generation {
        case .m3, .m4, .m5:
            return ["TCMz", "TCDX"]
        case .m1, .m2:
            return ["TCMz", "TC0D"]
        case .intel:
            return ["TC0D", "TC0E", "TCXC", "TC0P"]
        case .unknown:
            return ["TCMz", "TC0D", "TC0P"]
        }
    }

    private var gpuHotspotKeys: [String] {
        switch generation {
        case .m3, .m4, .m5:
            return ["TRDX"]
        case .m1, .m2, .intel, .unknown:
            return ["TG0D", "TG0P"]
        }
    }

    private var shouldReadHIDSensors: Bool {
        switch generation {
        case .intel:
            return false
        case .m1, .m2, .m3, .m4, .m5, .unknown:
            return true
        }
    }

    private var storageKeys: [String] {
        ["TH0x", "T5SP", "TS0P", "Ts0P"]
    }

    private var cpuCoreKeys: [String] {
        switch generation {
        case .m1:
            return [
                "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H",
                "Tp0L", "Tp0P", "Tp0X", "Tp0b"
            ]
        case .m2:
            return [
                "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05",
                "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"
            ]
        case .m3:
            return [
                "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09",
                "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49",
                "Tf4A", "Tf4B", "Tf4D", "Tf4E"
            ]
        case .m4:
            return [
                "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05",
                "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"
            ]
        case .m5:
            return [
                "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
                "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
            ]
        case .intel:
            return ["TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C"]
        case .unknown:
            return []
        }
    }

    private var gpuCoreKeys: [String] {
        switch generation {
        case .m1:
            return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case .m2:
            return ["Tg0f", "Tg0j"]
        case .m3:
            return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case .m4:
            return ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        case .m5:
            return ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        case .intel:
            return ["TCGC", "TG0D", "TG0P"]
        case .unknown:
            return []
        }
    }

    private func firstValidSMCValue(for keys: [String]) -> Double? {
        keys.lazy.compactMap { key in
            self.smc.readDouble(key).flatMap { value in
                Self.isPlausibleTemperature(value) ? value : nil
            }
        }.first
    }

    private func maximumValidSMCValue(for keys: [String]) -> Double? {
        keys.compactMap { key in
            self.smc.readDouble(key).flatMap { value in
                Self.isPlausibleTemperature(value) ? value : nil
            }
        }.max()
    }

    private func hottestHIDTemperature(
        in sensors: [RawTemperatureSensor],
        preferredPrefixes: [String] = [],
        fallbackPrefixes: [String] = [],
        nameContains fragments: [String] = []
    ) -> Double? {
        func maximum(prefixes: [String], fragments: [String]) -> Double? {
            sensors.compactMap { sensor -> Double? in
                guard Self.isPlausibleTemperature(sensor.celsius) else {
                    return nil
                }
                let name = sensor.name.lowercased()
                let matchesPrefix = prefixes.contains { name.hasPrefix($0) }
                let containsFragment = fragments.contains { name.contains($0) }
                return matchesPrefix || containsFragment ? sensor.celsius : nil
            }.max()
        }

        return maximum(prefixes: preferredPrefixes, fragments: fragments)
            ?? maximum(prefixes: fallbackPrefixes, fragments: [])
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value.isFinite && value >= 5 && value <= 125
    }

    private static func detectChipGeneration() -> ChipGeneration {
        let brand = systemString(named: "machdep.cpu.brand_string")
        if brand.localizedCaseInsensitiveContains("Apple M1") { return .m1 }
        if brand.localizedCaseInsensitiveContains("Apple M2") { return .m2 }
        if brand.localizedCaseInsensitiveContains("Apple M3") { return .m3 }
        if brand.localizedCaseInsensitiveContains("Apple M4") { return .m4 }
        if brand.localizedCaseInsensitiveContains("Apple M5") { return .m5 }
        #if arch(x86_64)
        return .intel
        #else
        return .unknown
        #endif
    }

    private static func systemString(named name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return ""
        }
        return String(cString: bytes)
    }
}
