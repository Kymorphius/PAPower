import Foundation

struct TrafficValues: Equatable, Codable {
    let upload: Double
    let download: Double

    static let zero = TrafficValues(upload: 0, download: 0)

    static func + (lhs: TrafficValues, rhs: TrafficValues) -> TrafficValues {
        TrafficValues(upload: lhs.upload + rhs.upload, download: lhs.download + rhs.download)
    }
}

enum TrafficSourceKind: String, Codable {
    case application
    case process
    case target
    case unknown
}

struct TrafficSourceActivity: Identifiable, Codable {
    let id: String
    let name: String
    let detail: String
    let kind: TrafficSourceKind
    let applicationPath: String?
    let rate: TrafficValues
    let connectionCount: Int
    let proxyConnectionCount: Int
    let directConnectionCount: Int
    let unclassifiedConnectionCount: Int

    var kindDescription: String {
        switch kind {
        case .application: return "应用"
        case .process: return "进程"
        case .target: return "目标"
        case .unknown: return "未知"
        }
    }

    var routeDescription: String {
        var routes: [String] = []
        if proxyConnectionCount > 0 { routes.append("代理") }
        if directConnectionCount > 0 { routes.append("直连") }
        if unclassifiedConnectionCount > 0 { routes.append("未归类") }
        return routes.isEmpty ? "未归类" : routes.joined(separator: " + ")
    }
}

struct TrafficSnapshot: Codable {
    let sampledAt: Date
    let proxyRate: TrafficValues?
    let directRate: TrafficValues?
    let unclassifiedRate: TrafficValues?
    let proxyTotal: TrafficValues
    let directTotal: TrafficValues
    let unclassifiedTotal: TrafficValues
    let connectionCount: Int
    let proxyConnectionCount: Int
    let directConnectionCount: Int
    let unclassifiedConnectionCount: Int
    let monitoringSince: Date
    let sourceDescription: String
    let topSources: [TrafficSourceActivity]

    var combinedRate: TrafficValues? {
        guard let proxyRate, let directRate, let unclassifiedRate else { return nil }
        return proxyRate + directRate + unclassifiedRate
    }

    var combinedTotal: TrafficValues {
        proxyTotal + directTotal + unclassifiedTotal
    }

    static var empty: TrafficSnapshot { TrafficSnapshot(
        sampledAt: .now,
        proxyRate: nil,
        directRate: nil,
        unclassifiedRate: nil,
        proxyTotal: .zero,
        directTotal: .zero,
        unclassifiedTotal: .zero,
        connectionCount: 0,
        proxyConnectionCount: 0,
        directConnectionCount: 0,
        unclassifiedConnectionCount: 0,
        monitoringSince: .now,
        sourceDescription: "local-manager · sing-box",
        topSources: []
    ) }
}

enum TrafficRoute {
    case proxy
    case direct
    case unclassified
}

struct TrafficConnection: Decodable {
    let id: String
    let upload: UInt64
    let download: UInt64
    let start: Date?
    let chains: [String]
    let metadata: TrafficConnectionMetadata?

    init(
        id: String, upload: UInt64, download: UInt64, start: Date?, chains: [String],
        metadata: TrafficConnectionMetadata? = nil
    ) {
        self.id = id
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, upload, download, start, chains, metadata
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        upload = try values.decode(UInt64.self, forKey: .upload)
        download = try values.decode(UInt64.self, forKey: .download)
        chains = try values.decode([String].self, forKey: .chains)
        metadata = try? values.decodeIfPresent(TrafficConnectionMetadata.self, forKey: .metadata)
        if let timestamp = try values.decodeIfPresent(String.self, forKey: .start) {
            // Value styles share Foundation's parser cache; constructing a formatter
            // for every connection adds noticeable work to each one-second poll.
            start = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
                ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
        } else {
            start = nil
        }
    }
}

struct TrafficConnectionMetadata: Decodable {
    let host: String?
    let destinationIP: String?
    let destinationPort: String?
    let processPath: String?
    let process: String?
    let processName: String?

    init(
        host: String? = nil, destinationIP: String? = nil, destinationPort: String? = nil,
        processPath: String? = nil, process: String? = nil, processName: String? = nil
    ) {
        self.host = host
        self.destinationIP = destinationIP
        self.destinationPort = destinationPort
        self.processPath = processPath
        self.process = process
        self.processName = processName
    }

    private enum CodingKeys: String, CodingKey {
        case host, destinationIP, destinationPort, processPath, process, processName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try? values.decode(String.self, forKey: .host)
        destinationIP = try? values.decode(String.self, forKey: .destinationIP)
        if let port = try? values.decode(String.self, forKey: .destinationPort) {
            destinationPort = port
        } else if let port = try? values.decode(UInt16.self, forKey: .destinationPort) {
            destinationPort = String(port)
        } else {
            destinationPort = nil
        }
        processPath = try? values.decode(String.self, forKey: .processPath)
        process = try? values.decode(String.self, forKey: .process)
        processName = try? values.decode(String.self, forKey: .processName)
    }
}

struct TrafficReading {
    let uploadTotal: UInt64
    let downloadTotal: UInt64
    let connections: [TrafficConnection]
    let proxyTypes: [String: String]
    let sourceIdentity: String
    let sourceDescription: String

    func route(for connection: TrafficConnection) -> TrafficRoute {
        // sing-box exposes the terminal outbound first, followed by selector groups.
        guard let terminal = connection.chains.first,
              let type = proxyTypes[terminal]?.lowercased() else {
            return .unclassified
        }
        if type == "direct" { return .direct }

        // Group, reject and future types stay unknown; names alone are not evidence.
        let proxyTypes: Set<String> = [
            "socks", "socks4", "socks5", "http", "https", "shadowsocks",
            "shadowsocksr", "snell", "vmess", "vless", "trojan", "hysteria",
            "hysteria2", "tuic", "wireguard", "ssh", "shadowtls", "anytls", "naive"
        ]
        return proxyTypes.contains(type) ? .proxy : .unclassified
    }
}
