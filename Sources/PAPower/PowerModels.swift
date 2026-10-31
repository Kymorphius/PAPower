import Foundation

struct BatterySnapshot {
    let percentage: Int?
    let isCharging: Bool?
    let isOnACPower: Bool?
    let voltageVolts: Double?
    let currentAmps: Double?
    let temperatureCelsius: Double?

    var flowWatts: Double? {
        guard let voltageVolts, let currentAmps else { return nil }
        return voltageVolts * currentAmps
    }
}

enum MeasurementSource: String {
    case smcTotal = "smc-pstr"
    case batteryEstimate = "battery-estimate"
    case unavailable
}

struct ComponentTemperatures {
    let cpuCelsius: Double?
    let gpuCelsius: Double?
    let storageCelsius: Double?

    var hasAnyValue: Bool {
        cpuCelsius != nil || gpuCelsius != nil || storageCelsius != nil
    }

    static let empty = ComponentTemperatures(
        cpuCelsius: nil,
        gpuCelsius: nil,
        storageCelsius: nil
    )
}

struct PowerSnapshot {
    let systemWatts: Double?
    let battery: BatterySnapshot?
    let temperatures: ComponentTemperatures
    let sampledAt: Date
    let source: MeasurementSource
    let diagnostic: String?

    var displayedWatts: Double? {
        if let systemWatts {
            return systemWatts
        }

        guard source == .batteryEstimate, let flow = battery?.flowWatts else {
            return nil
        }
        return abs(flow)
    }

    static let empty = PowerSnapshot(
        systemWatts: nil,
        battery: nil,
        temperatures: .empty,
        sampledAt: .now,
        source: .unavailable,
        diagnostic: nil
    )
}

struct PowerSample: Identifiable {
    let id = UUID()
    let date: Date
    let watts: Double
}
