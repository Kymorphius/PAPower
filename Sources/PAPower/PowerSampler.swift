import Foundation

final class PowerSampler {
    private let smc = SMCClient()
    private let batteryReader = BatteryReader()

    func capture() -> PowerSnapshot {
        let battery = batteryReader.read()
        let rawSystemWatts = smc.readDouble("PSTR")
        let systemWatts = rawSystemWatts.flatMap { value -> Double? in
            guard value.isFinite, value >= 0, value < 2_000 else { return nil }
            return value
        }

        let source: MeasurementSource
        if systemWatts != nil {
            source = .smcTotal
        } else if battery?.isOnACPower == false, battery?.flowWatts != nil {
            source = .batteryEstimate
        } else {
            source = .unavailable
        }

        return PowerSnapshot(
            systemWatts: systemWatts,
            battery: battery,
            sampledAt: .now,
            source: source,
            diagnostic: systemWatts == nil
                ? (smc.connectionError ?? "此机型未提供 PSTR 总功耗传感器")
                : nil
        )
    }
}
