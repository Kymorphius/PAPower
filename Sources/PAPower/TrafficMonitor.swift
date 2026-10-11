import Combine
import Foundation

@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var snapshot = TrafficSnapshot.empty
    @Published private(set) var diagnostic: String?
    @Published private(set) var isRefreshing = false

    private let client = LocalManagerTrafficClient()
    private var accumulator = TrafficAccumulator()
    private var pollingTask: Task<Void, Never>?
    private var samplingGeneration: UInt = 0

    init() {
        // Network I/O stays asynchronous and independent of power sampling.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = samplingGeneration
        defer { isRefreshing = false }

        do {
            let reading = try await client.capture()
            guard !Task.isCancelled, generation == samplingGeneration else { return }
            snapshot = accumulator.consume(reading)
            diagnostic = nil
        } catch {
            guard !Task.isCancelled, generation == samplingGeneration else { return }
            accumulator.invalidateBaseline()
            diagnostic = error.localizedDescription
        }
    }

    func resetTotals() {
        samplingGeneration &+= 1
        accumulator.reset()
        snapshot = .empty
        Task { await refresh() }
    }

    var hasCurrentRates: Bool {
        diagnostic == nil && snapshot.proxyRate != nil
    }

    var accessibilitySummary: String {
        if diagnostic != nil { return "PAPower 网络流量，local-manager 暂时不可用" }
        guard hasCurrentRates else { return "PAPower 网络流量，正在采样" }
        return "PAPower 网络流量，代理下载 \(TrafficFormat.rate(snapshot.proxyRate?.download))，上传 \(TrafficFormat.rate(snapshot.proxyRate?.upload))；直连下载 \(TrafficFormat.rate(snapshot.directRate?.download))，上传 \(TrafficFormat.rate(snapshot.directRate?.upload))"
    }
}

enum TrafficFormat {
    static func rate(_ bytes: Double?) -> String {
        guard let bytes else { return "—" }
        return quantity(bytes) + "/s"
    }

    static func quantity(_ bytes: Double) -> String {
        let safe = bytes.isFinite ? max(0, bytes) : 0
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = safe
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let decimals = index == 0 || value >= 100 ? 0 : 1
        return String(format: "%.*f %@", decimals, value, units[index])
    }

    static func compactRate(_ bytes: Double?) -> String {
        guard let bytes else { return "   —" }
        let safe = bytes.isFinite ? max(0, bytes) : 0
        let units = ["B", "K", "M", "G", "T"]
        var value = safe
        var index = 0
        while value >= 999.5, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = value < 10 && index > 0
            ? String(format: "%.1f%@", value, units[index])
            : String(format: "%.0f%@", value, units[index])
        return String(repeating: " ", count: max(0, 4 - text.count)) + text
    }
}
