import Foundation
import IOKit
import IOKit.ps

final class BatteryReader {
    private var batteryService: io_registry_entry_t = 0

    init() {
        batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
    }

    deinit {
        if batteryService != 0 {
            IOObjectRelease(batteryService)
        }
    }

    func read() -> BatterySnapshot? {
        let publicDescription = readPowerSourceDescription()
        guard publicDescription != nil || batteryService != 0 else { return nil }

        let currentCapacity = number(in: publicDescription, key: "Current Capacity")?.doubleValue
        let maxCapacity = number(in: publicDescription, key: "Max Capacity")?.doubleValue
        let percentage: Int? = {
            guard let currentCapacity, let maxCapacity, maxCapacity > 0 else { return nil }
            return Int((currentCapacity / maxCapacity * 100).rounded())
        }()

        let publicCurrent = number(in: publicDescription, key: "Current")?.doubleValue
        let currentMilliAmps = registryNumber("InstantAmperage")?.doubleValue
            ?? registryNumber("Amperage")?.doubleValue
            ?? publicCurrent
        let voltageMilliVolts = registryNumber("Voltage")?.doubleValue
            ?? number(in: publicDescription, key: "Voltage")?.doubleValue

        let publicPowerState = publicDescription?["Power Source State"] as? String
        let registryExternal = registryNumber("ExternalConnected")?.boolValue
        let isOnACPower = publicPowerState.map { $0 == "AC Power" } ?? registryExternal

        let publicCharging = number(in: publicDescription, key: "Is Charging")?.boolValue
        let registryCharging = registryNumber("IsCharging")?.boolValue

        let rawTemperature = registryNumber("Temperature")?.doubleValue
            ?? number(in: publicDescription, key: "Temperature")?.doubleValue
        let temperature = rawTemperature.map { $0 > 200 ? $0 / 100.0 : $0 }

        return BatterySnapshot(
            percentage: percentage,
            isCharging: publicCharging ?? registryCharging,
            isOnACPower: isOnACPower,
            voltageVolts: voltageMilliVolts.map { $0 / 1_000.0 },
            currentAmps: currentMilliAmps.map { $0 / 1_000.0 },
            temperatureCelsius: temperature
        )
    }

    private func readPowerSourceDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let rawList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            return nil
        }

        let sources = rawList as [CFTypeRef]
        var firstPresentSource: [String: Any]?

        for source in sources {
            guard let unmanaged = IOPSGetPowerSourceDescription(info, source),
                  let description = unmanaged.takeUnretainedValue() as? [String: Any],
                  (description["Is Present"] as? NSNumber)?.boolValue != false else {
                continue
            }

            if description["Type"] as? String == "InternalBattery" {
                return description
            }
            firstPresentSource = firstPresentSource ?? description
        }
        return firstPresentSource
    }

    private func registryNumber(_ key: String) -> NSNumber? {
        guard batteryService != 0,
              let value = IORegistryEntryCreateCFProperty(
                batteryService,
                key as CFString,
                kCFAllocatorDefault,
                0
              )?.takeRetainedValue() else {
            return nil
        }
        return value as? NSNumber
    }

    private func number(in dictionary: [String: Any]?, key: String) -> NSNumber? {
        dictionary?[key] as? NSNumber
    }
}
