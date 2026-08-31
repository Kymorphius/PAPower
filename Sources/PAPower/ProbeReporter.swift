import Darwin
import Foundation

enum ProbeReporter {
    @MainActor
    static func printActivityAndExit() -> Never {
        let sampler = ProcessActivitySampler()
        let activities = sampler.capture(force: true)

        let payload: [[String: Any]] = activities.map { activity in
            [
                "name": activity.name,
                "cpuPercent": activity.cpuPercent,
                "processCount": activity.processCount,
                "isSystemService": activity.isSystemService
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(EXIT_SUCCESS)
    }

    static func printSnapshotAndExit() -> Never {
        let snapshot = PowerSampler().capture()
        var payload: [String: Any] = [
            "measurementSource": snapshot.source.rawValue,
            "sampledAt": ISO8601DateFormatter().string(from: snapshot.sampledAt)
        ]

        if let watts = snapshot.systemWatts {
            payload["systemWatts"] = watts
        }
        if let displayedWatts = snapshot.displayedWatts {
            payload["displayedWatts"] = displayedWatts
        }
        if let diagnostic = snapshot.diagnostic {
            payload["diagnostic"] = diagnostic
        }
        if let battery = snapshot.battery {
            var batteryPayload: [String: Any] = [:]
            batteryPayload["percentage"] = battery.percentage
            batteryPayload["isCharging"] = battery.isCharging
            batteryPayload["isOnACPower"] = battery.isOnACPower
            batteryPayload["voltageVolts"] = battery.voltageVolts
            batteryPayload["currentAmps"] = battery.currentAmps
            batteryPayload["flowWatts"] = battery.flowWatts
            batteryPayload["temperatureCelsius"] = battery.temperatureCelsius
            payload["battery"] = batteryPayload
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(EXIT_SUCCESS)
    }
}
