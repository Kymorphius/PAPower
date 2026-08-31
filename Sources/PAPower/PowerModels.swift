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

struct PowerSnapshot {
    let systemWatts: Double?
    let battery: BatterySnapshot?
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
