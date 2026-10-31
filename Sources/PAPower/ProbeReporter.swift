import Darwin
import Foundation

enum ProbeReporter {
    static func printTemperaturesAndExit() -> Never {
        let sensors = TemperatureSensorReader().readRawSensors()
        let hidPayload: [[String: Any]] = sensors.map { sensor in
            [
                "name": sensor.name,
                "identifier": sensor.identifier,
                "celsius": sensor.celsius
            ]
        }
        let smc = SMCClient()
        let candidateKeys = [
            "TCMz", "TCDX",
            "Te05", "Te0L", "Te0P", "Te0S",
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
            "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
            "Tf14", "Tf18", "Tf19", "Tf1A",
            "Tf24", "Tf28", "Tf29", "Tf2A",
            "TRDX", "TH0x", "TVm0", "TVm1", "TVm2", "TMVR"
        ]
        let smcPayload = Dictionary(uniqueKeysWithValues: candidateKeys.compactMap { key in
            smc.readDouble(key).map { (key, $0) }
        })
        let payload: [String: Any] = [
            "hid": hidPayload,
            "smc": smcPayload
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(EXIT_SUCCESS)
    }

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
        var temperaturePayload: [String: Any] = [:]
        if let cpuCelsius = snapshot.temperatures.cpuCelsius {
            temperaturePayload["cpuCelsius"] = cpuCelsius
        }
        if let gpuCelsius = snapshot.temperatures.gpuCelsius {
            temperaturePayload["gpuCelsius"] = gpuCelsius
        }
        if let storageCelsius = snapshot.temperatures.storageCelsius {
            temperaturePayload["storageCelsius"] = storageCelsius
        }
        payload["temperatures"] = temperaturePayload
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
