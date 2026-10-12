import Darwin
import Foundation

struct TrafficAccumulator {
    private struct Baseline {
        let reading: TrafficReading
        let sampledAt: Date
        let uptime: TimeInterval
    }

    private struct SourceIdentity {
        let id: String
        let name: String
        let detail: String
        let kind: TrafficSourceKind
        let applicationPath: String?
    }

    private struct SourceAggregate {
        let source: SourceIdentity
        var delta = TrafficValues.zero
        var proxyCount = 0
        var directCount = 0
        var unclassifiedCount = 0

        mutating func addConnection(route: TrafficRoute) {
            switch route {
            case .proxy: proxyCount += 1
            case .direct: directCount += 1
            case .unclassified: unclassifiedCount += 1
            }
        }

        mutating func addDelta(_ values: TrafficValues) {
            delta = delta + values
        }
    }

    private var baseline: Baseline?
    private var monitoringSince: Date?
    private var proxyTotal = TrafficValues.zero
    private var directTotal = TrafficValues.zero
    private var unclassifiedTotal = TrafficValues.zero
    private var applicationNames: [String: String] = [:]
    private var normalizedPaths: [String: String] = [:]
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
        var topSources: [TrafficSourceActivity] = []

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
                var sources: [String: SourceAggregate] = [:]
                let oldConnections = Dictionary(
                    old.connections.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for connection in reading.connections {
                    let route = reading.route(for: connection)
                    let identity = source(for: connection)
                    if sources[identity.id] == nil {
                        sources[identity.id] = SourceAggregate(source: identity)
                    }
                    sources[identity.id]?.addConnection(route: route)
                    let delta: TrafficValues
                    var sourceUnchanged = true
                    if let earlier = oldConnections[connection.id], earlier.start == connection.start {
                        guard connection.upload >= earlier.upload,
                              connection.download >= earlier.download else { continue }
                        delta = TrafficValues(
                            upload: Double(connection.upload - earlier.upload),
                            download: Double(connection.download - earlier.download)
                        )
                        // Process metadata can arrive or change after a tracker is created.
                        // Such an interval cannot safely belong to the newly reported source.
                        sourceUnchanged = source(for: earlier).id == identity.id
                    } else if let started = connection.start, started > previous.sampledAt {
                        delta = TrafficValues(
                            upload: Double(connection.upload), download: Double(connection.download)
                        )
                    } else {
                        // Delayed appearance of an older connection is not a new transfer.
                        continue
                    }
                    switch route {
                    case .proxy: proxy = proxy + delta
                    case .direct: direct = direct + delta
                    case .unclassified: unclassified = unclassified + delta
                    }
                    if sourceUnchanged {
                        sources[identity.id]?.addDelta(delta)
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
                topSources = rankedSources(
                    sources, uploadScale: upload.scale, downloadScale: download.scale, elapsed: elapsed
                )
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
            sourceDescription: reading.sourceDescription,
            topSources: topSources
        )
    }

    private func reconcile(
        global: Double, proxy: Double, direct: Double, unclassified: Double
    ) -> (proxy: Double, direct: Double, unclassified: Double, scale: Double) {
        // The API snapshots counters non-atomically. Scale competing active deltas to
        // the authoritative global budget instead of emitting negative residuals.
        let active = proxy + direct + unclassified
        let scale = active > global && active > 0 ? global / active : 1
        let proxyValue = min(global, proxy * scale)
        let directValue = min(max(0, global - proxyValue), direct * scale)
        return (proxyValue, directValue, max(0, global - proxyValue - directValue), scale)
    }

    private func rankedSources(
        _ sources: [String: SourceAggregate], uploadScale: Double,
        downloadScale: Double, elapsed: TimeInterval
    ) -> [TrafficSourceActivity] {
        sources.values.compactMap { aggregate in
            let rate = TrafficValues(
                upload: aggregate.delta.upload * uploadScale / elapsed,
                download: aggregate.delta.download * downloadScale / elapsed
            )
            guard rate.upload > 0 || rate.download > 0 else { return nil }
            return TrafficSourceActivity(
                id: aggregate.source.id,
                name: aggregate.source.name,
                detail: aggregate.source.detail,
                kind: aggregate.source.kind,
                applicationPath: aggregate.source.applicationPath,
                rate: rate,
                connectionCount: aggregate.proxyCount + aggregate.directCount + aggregate.unclassifiedCount,
                proxyConnectionCount: aggregate.proxyCount,
                directConnectionCount: aggregate.directCount,
                unclassifiedConnectionCount: aggregate.unclassifiedCount
            )
        }.sorted {
            let lhs = $0.rate.upload + $0.rate.download
            let rhs = $1.rate.upload + $1.rate.download
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }.prefix(10).map { $0 }
    }

    private mutating func source(for connection: TrafficConnection) -> SourceIdentity {
        if let rawPath = nonempty(connection.metadata?.processPath),
           let processPath = normalizedProcessPath(rawPath) {
            let components = (processPath as NSString).pathComponents
            if let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                let appPath = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
                let name: String
                if let cached = applicationNames[appPath] {
                    name = cached
                } else {
                    let bundle = Bundle(path: appPath)
                    name = nonempty(bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? nonempty(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
                    applicationNames[appPath] = name
                }
                return SourceIdentity(
                    id: "application:\(appPath)", name: name, detail: appPath,
                    kind: .application, applicationPath: appPath
                )
            }
            return SourceIdentity(
                id: "process-path:\(processPath)",
                name: URL(fileURLWithPath: processPath).lastPathComponent,
                detail: processPath, kind: .process, applicationPath: nil
            )
        }
        if let processName = nonempty(connection.metadata?.processName)
            ?? nonempty(connection.metadata?.process) {
            return SourceIdentity(
                id: "process-name:\(processName)", name: processName,
                detail: "按进程名称统计", kind: .process, applicationPath: nil
            )
        }
        if let host = nonempty(connection.metadata?.host) {
            let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !normalizedHost.isEmpty {
                return SourceIdentity(
                    id: "target-host:\(normalizedHost)", name: normalizedHost,
                    detail: "按目标地址统计", kind: .target, applicationPath: nil
                )
            }
        }
        if let ip = nonempty(connection.metadata?.destinationIP) {
            let normalizedIP = ip.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            let address = normalizedIP.contains(":") ? "[\(normalizedIP)]" : normalizedIP
            let port = nonempty(connection.metadata?.destinationPort).map { ":\($0)" } ?? ""
            return SourceIdentity(
                id: "target-address:\(address)\(port)", name: "\(address)\(port)",
                detail: "按目标地址统计", kind: .target, applicationPath: nil
            )
        }
        let started = connection.start.map { String($0.timeIntervalSince1970) } ?? "no-start"
        return SourceIdentity(
            id: "unknown:\(connection.id):\(started)", name: "未知来源",
            detail: "连接 \(connection.id.prefix(8))", kind: .unknown, applicationPath: nil
        )
    }

    private mutating func normalizedProcessPath(_ value: String) -> String? {
        if let cached = normalizedPaths[value] { return cached }
        var path = value
        // sing-box appends a user identity to processPath. Strip only its final
        // recognized account suffix, preserving parentheses in actual filenames.
        if path.hasSuffix(")"), let range = path.range(of: " (", options: .backwards) {
            let suffix = path[range.upperBound..<path.index(before: path.endIndex)]
            if !suffix.isEmpty && !suffix.contains("/") && !suffix.contains("(") && !suffix.contains(")") {
                let account = String(suffix)
                let isAccount: Bool
                if let uid = UInt32(account) {
                    isAccount = getpwuid(uid) != nil
                } else {
                    isAccount = getpwnam(account) != nil
                }
                if isAccount && !FileManager.default.fileExists(atPath: path) {
                    path = String(path[..<range.lowerBound])
                }
            }
        }
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalizedPaths.count >= 128 { normalizedPaths.removeAll(keepingCapacity: true) }
        normalizedPaths[value] = normalized
        return normalized
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func perSecond(_ values: TrafficValues, elapsed: TimeInterval) -> TrafficValues {
        TrafficValues(upload: values.upload / elapsed, download: values.download / elapsed)
    }
}
