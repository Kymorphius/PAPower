import Foundation

struct TrafficValues: Equatable, Codable {
    let upload: Double
    let download: Double

    static let zero = TrafficValues(upload: 0, download: 0)

    static func + (lhs: TrafficValues, rhs: TrafficValues) -> TrafficValues {
        TrafficValues(upload: lhs.upload + rhs.upload, download: lhs.download + rhs.download)
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
        sourceDescription: "local-manager · sing-box"
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

    init(id: String, upload: UInt64, download: UInt64, start: Date?, chains: [String]) {
        self.id = id
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
    }

    private enum CodingKeys: String, CodingKey {
        case id, upload, download, start, chains
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        upload = try values.decode(UInt64.self, forKey: .upload)
        download = try values.decode(UInt64.self, forKey: .download)
        chains = try values.decode([String].self, forKey: .chains)
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
