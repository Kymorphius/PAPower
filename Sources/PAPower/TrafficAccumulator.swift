import Foundation

struct TrafficAccumulator {
    private struct Baseline {
        let reading: TrafficReading
        let sampledAt: Date
        let uptime: TimeInterval
    }

    private var baseline: Baseline?
    private var monitoringSince: Date?
    private var proxyTotal = TrafficValues.zero
    private var directTotal = TrafficValues.zero
    private var unclassifiedTotal = TrafficValues.zero
    private let maximumSamplingGap: TimeInterval

    init(maximumSamplingGap: TimeInterval = 10) {
        self.maximumSamplingGap = maximumSamplingGap
    }

    mutating func invalidateBaseline() {
        baseline = nil
    }

    mutating func reset() {
        baseline = nil
        monitoringSince = nil
        proxyTotal = .zero
        directTotal = .zero
        unclassifiedTotal = .zero
    }

    mutating func consume(
        _ reading: TrafficReading,
        at date: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TrafficSnapshot {
        if monitoringSince == nil { monitoringSince = date }
        defer { baseline = Baseline(reading: reading, sampledAt: date, uptime: uptime) }

        var proxyRate: TrafficValues?
        var directRate: TrafficValues?
        var unclassifiedRate: TrafficValues?

        if let previous = baseline {
            let elapsed = uptime - previous.uptime
            let old = previous.reading
            if elapsed.isFinite, elapsed > 0, elapsed <= maximumSamplingGap,
               old.sourceIdentity == reading.sourceIdentity,
               reading.uploadTotal >= old.uploadTotal,
               reading.downloadTotal >= old.downloadTotal {
                let global = TrafficValues(
                    upload: Double(reading.uploadTotal - old.uploadTotal),
                    download: Double(reading.downloadTotal - old.downloadTotal)
                )
                // A closed connection's final bytes cannot be recovered from /connections.
                // Global counters remain authoritative; the residual stays unclassified.
                var proxy = TrafficValues.zero
                var direct = TrafficValues.zero
                var unclassified = TrafficValues.zero
                let oldConnections = Dictionary(
                    old.connections.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for connection in reading.connections {
                    let delta: TrafficValues
                    if let earlier = oldConnections[connection.id], earlier.start == connection.start {
                        guard connection.upload >= earlier.upload,
                              connection.download >= earlier.download else { continue }
                        delta = TrafficValues(
                            upload: Double(connection.upload - earlier.upload),
                            download: Double(connection.download - earlier.download)
                        )
                    } else if let started = connection.start, started > previous.sampledAt {
                        delta = TrafficValues(
                            upload: Double(connection.upload), download: Double(connection.download)
                        )
                    } else {
                        // Delayed appearance of an older connection is not a new transfer.
                        continue
                    }
                    switch reading.route(for: connection) {
                    case .proxy: proxy = proxy + delta
                    case .direct: direct = direct + delta
                    case .unclassified: unclassified = unclassified + delta
                    }
                }

                let upload = reconcile(
                    global: global.upload, proxy: proxy.upload,
                    direct: direct.upload, unclassified: unclassified.upload
                )
                let download = reconcile(
                    global: global.download, proxy: proxy.download,
                    direct: direct.download, unclassified: unclassified.download
                )
                let proxyDelta = TrafficValues(upload: upload.proxy, download: download.proxy)
                let directDelta = TrafficValues(upload: upload.direct, download: download.direct)
                let unclassifiedDelta = TrafficValues(
                    upload: upload.unclassified, download: download.unclassified
                )
                proxyTotal = proxyTotal + proxyDelta
                directTotal = directTotal + directDelta
                unclassifiedTotal = unclassifiedTotal + unclassifiedDelta
                proxyRate = perSecond(proxyDelta, elapsed: elapsed)
                directRate = perSecond(directDelta, elapsed: elapsed)
                unclassifiedRate = perSecond(unclassifiedDelta, elapsed: elapsed)
            }
        }

        var proxyCount = 0
        var directCount = 0
        var unclassifiedCount = 0
        for connection in reading.connections {
            switch reading.route(for: connection) {
            case .proxy: proxyCount += 1
            case .direct: directCount += 1
            case .unclassified: unclassifiedCount += 1
            }
        }
        return TrafficSnapshot(
            sampledAt: date,
            proxyRate: proxyRate,
            directRate: directRate,
            unclassifiedRate: unclassifiedRate,
            proxyTotal: proxyTotal,
            directTotal: directTotal,
            unclassifiedTotal: unclassifiedTotal,
            connectionCount: reading.connections.count,
            proxyConnectionCount: proxyCount,
            directConnectionCount: directCount,
            unclassifiedConnectionCount: unclassifiedCount,
            monitoringSince: monitoringSince ?? date,
            sourceDescription: reading.sourceDescription
        )
    }

    private func reconcile(
        global: Double, proxy: Double, direct: Double, unclassified: Double
    ) -> (proxy: Double, direct: Double, unclassified: Double) {
        // The API snapshots counters non-atomically. Scale competing active deltas to
        // the authoritative global budget instead of emitting negative residuals.
        let active = proxy + direct + unclassified
        let scale = active > global && active > 0 ? global / active : 1
        let proxyValue = min(global, proxy * scale)
        let directValue = min(max(0, global - proxyValue), direct * scale)
        return (proxyValue, directValue, max(0, global - proxyValue - directValue))
    }

    private func perSecond(_ values: TrafficValues, elapsed: TimeInterval) -> TrafficValues {
        TrafficValues(upload: values.upload / elapsed, download: values.download / elapsed)
    }
}
