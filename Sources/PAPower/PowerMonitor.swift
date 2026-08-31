import AppKit
import Combine
import Foundation

@MainActor
final class PowerMonitor: ObservableObject {
    private enum DefaultsKey {
        static let refreshInterval = "refreshInterval"
        static let decimalPlaces = "menuBarDecimalPlaces"
        static let spaciousLayout = "menuBarSpaciousLayout"
    }

    private static let figureSpace = "\u{2007}"

    @Published private(set) var snapshot = PowerSnapshot.empty
    @Published private(set) var history: [PowerSample] = []
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var decimalPlaces: Int
    @Published private(set) var usesSpaciousLayout: Bool
    @Published private(set) var activeApps: [ActiveApp] = []

    private let sampler = PowerSampler()
    private let processActivitySampler = ProcessActivitySampler()
    private var timer: Timer?

    init() {
        let savedInterval = UserDefaults.standard.double(forKey: DefaultsKey.refreshInterval)
        refreshInterval = [1.0, 2.0, 5.0].contains(savedInterval) ? savedInterval : 1.0
        let savedDecimalPlaces = UserDefaults.standard.integer(forKey: DefaultsKey.decimalPlaces)
        decimalPlaces = [1, 2].contains(savedDecimalPlaces) ? savedDecimalPlaces : 1
        usesSpaciousLayout = UserDefaults.standard.object(
            forKey: DefaultsKey.spaciousLayout
        ) as? Bool ?? false
        refresh()
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
    }

    var menuBarText: String {
        let layoutSpacing = usesSpaciousLayout ? Self.figureSpace : ""
        let unitSpacing = usesSpaciousLayout ? " " : ""

        guard let watts = snapshot.displayedWatts else {
            let placeholder = "-." + String(repeating: "-", count: decimalPlaces)
            return layoutSpacing + Self.figureSpace + placeholder + unitSpacing + "W"
        }

        let safeWatts = max(0, watts)
        let integerDigits = max(1, String(Int(safeWatts)).count)
        let rawNumber = String(format: "%.*f", decimalPlaces, safeWatts)

        // The two integer slots keep the lightning and W anchored while the
        // usual sub-100 W reading changes between one and two integer digits.
        // Compact mode ends directly in W; spacious mode adds one figure-space
        // after the symbol and a normal space before W.
        let leadingSlots = max(0, 2 - integerDigits)
        let leading = String(repeating: Self.figureSpace, count: leadingSlots)
        return layoutSpacing + leading + rawNumber + unitSpacing + "W"
    }

    var menuBarSymbol: String {
        switch snapshot.source {
        case .smcTotal:
            return "bolt.fill"
        case .batteryEstimate:
            return "battery.50percent"
        case .unavailable:
            return "bolt.slash"
        }
    }

    var accessibilitySummary: String {
        guard let watts = snapshot.displayedWatts else { return "PAPower，暂时无法读取功耗" }
        return String(format: "PAPower，当前功耗 %.1f 瓦", watts)
    }

    var averageWatts: Double? {
        guard !history.isEmpty else { return nil }
        return history.map(\.watts).reduce(0, +) / Double(history.count)
    }

    var peakWatts: Double? {
        history.map(\.watts).max()
    }

    var historyDurationText: String {
        let seconds = max(Int(Double(max(history.count - 1, 0)) * refreshInterval), 0)
        if seconds < 60 { return "最近 \(seconds) 秒" }
        return "最近 \(seconds / 60) 分钟"
    }

    func refresh() {
        snapshot = sampler.capture()
        activeApps = processActivitySampler.capture()
        if let watts = snapshot.displayedWatts {
            history.append(PowerSample(date: snapshot.sampledAt, watts: watts))
            if history.count > 120 {
                history.removeFirst(history.count - 120)
            }
        }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard [1.0, 2.0, 5.0].contains(interval), interval != refreshInterval else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: DefaultsKey.refreshInterval)
        scheduleTimer()
    }

    func setDecimalPlaces(_ places: Int) {
        guard [1, 2].contains(places), places != decimalPlaces else { return }
        decimalPlaces = places
        UserDefaults.standard.set(places, forKey: DefaultsKey.decimalPlaces)
    }

    func setSpaciousLayout(_ isEnabled: Bool) {
        guard isEnabled != usesSpaciousLayout else { return }
        usesSpaciousLayout = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.spaciousLayout)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }
}
