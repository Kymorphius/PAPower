import CryptoKit
import Foundation

enum LocalManagerTrafficError: LocalizedError {
    case configurationMissing
    case configurationUnreadable
    case configurationInvalid
    case controllerInvalid
    case authenticationFailed
    case apiUnavailable
    case responseInvalid
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .configurationMissing: return "未找到 local-manager 的 sing-box 配置。"
        case .configurationUnreadable: return "无法读取 local-manager 的 sing-box 配置。"
        case .configurationInvalid: return "local-manager 的 sing-box 配置未启用 Clash API。"
        case .controllerInvalid: return "流量接口必须使用本机回环地址和 HTTP。"
        case .authenticationFailed: return "流量接口认证失败，请检查 local-manager 的 Clash API 配置。"
        case .apiUnavailable: return "local-manager 流量接口不可用，请确认 sing-box 正在运行。"
        case .responseInvalid: return "local-manager 流量接口返回了无法识别的数据。"
        case .requestFailed: return "无法连接 local-manager 流量接口。"
        }
    }
}

private final class TrafficRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class LocalManagerTrafficClient {
    private struct Configuration: Decodable {
        struct Experimental: Decodable {
            struct ClashAPI: Decodable {
                let externalController: String?
                let secret: String?
                enum CodingKeys: String, CodingKey {
                    case externalController = "external_controller"
                    case secret
                }
            }
            let clashAPI: ClashAPI?
            enum CodingKeys: String, CodingKey { case clashAPI = "clash_api" }
        }
        let experimental: Experimental?
    }

    private struct ConnectionsResponse: Decodable {
        let uploadTotal: UInt64
        let downloadTotal: UInt64
        let connections: [TrafficConnection]

        private enum CodingKeys: String, CodingKey {
            case uploadTotal, downloadTotal, connections
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            uploadTotal = try values.decode(UInt64.self, forKey: .uploadTotal)
            downloadTotal = try values.decode(UInt64.self, forKey: .downloadTotal)
            guard values.contains(.connections) else {
                throw LocalManagerTrafficError.responseInvalid
            }
            connections = try values.decodeIfPresent([TrafficConnection].self, forKey: .connections) ?? []
        }
    }

    private struct ProxiesResponse: Decodable {
        struct Proxy: Decodable { let type: String }
        let proxies: [String: Proxy]
    }

    private struct Endpoint {
        let url: URL
        let secret: String?
        let sourceIdentity: String
        let sourceDescription: String
    }

    private let root: URL
    private let session: URLSession

    init(root: URL? = nil, session: URLSession? = nil) {
        self.root = root ?? URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["PAPOWER_LOCAL_MANAGER_ROOT"] ?? "/Applications/local-manager",
            isDirectory: true
        )
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 2
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration, delegate: TrafficRedirectBlocker(), delegateQueue: nil
            )
        }
    }

    deinit { session.invalidateAndCancel() }

    func capture() async throws -> TrafficReading {
        let endpoint = try discoverEndpoint()
        async let connectionData = request("connections", endpoint: endpoint)
        async let proxyData = request("proxies", endpoint: endpoint)
        let data = try await (connectionData, proxyData)
        do {
            let decoder = JSONDecoder()
            let connections = try decoder.decode(ConnectionsResponse.self, from: data.0)
            let proxies = try decoder.decode(ProxiesResponse.self, from: data.1)
            guard connections.connections.allSatisfy({ !$0.id.isEmpty }),
                  Set(connections.connections.map(\.id)).count == connections.connections.count else {
                throw LocalManagerTrafficError.responseInvalid
            }
            return TrafficReading(
                uploadTotal: connections.uploadTotal,
                downloadTotal: connections.downloadTotal,
                connections: connections.connections,
                proxyTypes: proxies.proxies.mapValues(\.type),
                sourceIdentity: endpoint.sourceIdentity,
                sourceDescription: endpoint.sourceDescription
            )
        } catch {
            throw LocalManagerTrafficError.responseInvalid
        }
    }

    private func discoverEndpoint() throws -> Endpoint {
        let candidates = [
            root.appendingPathComponent("var/state/network/sing-box/runtime.json"),
            root.appendingPathComponent("10.network/20.sing-box/sing-box.json")
        ]
        guard let configURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw LocalManagerTrafficError.configurationMissing
        }
        guard let data = try? Data(contentsOf: configURL) else {
            throw LocalManagerTrafficError.configurationUnreadable
        }
        guard let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              let api = configuration.experimental?.clashAPI,
              let controller = api.externalController, !controller.isEmpty else {
            throw LocalManagerTrafficError.configurationInvalid
        }
        let address = controller.contains("://") ? controller : "http://\(controller)"
        guard let components = URLComponents(string: address),
              components.scheme == "http", let host = components.host,
              isLoopback(host), let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url else {
            throw LocalManagerTrafficError.controllerInvalid
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Endpoint(
            url: url,
            secret: api.secret.flatMap { $0.isEmpty ? nil : $0 },
            sourceIdentity: "\(configURL.path)|\(digest)",
            sourceDescription: "local-manager · sing-box · \(components.host ?? "localhost"):\(port)"
        )
    }

    private func isLoopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy {
            guard let value = Int($0) else { return false }
            return (0...255).contains(value)
        }
    }

    private func request(_ path: String, endpoint: Endpoint) async throws -> Data {
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = endpoint.secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? URLError,
               [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(error.code) {
                throw LocalManagerTrafficError.apiUnavailable
            }
            throw LocalManagerTrafficError.requestFailed
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw LocalManagerTrafficError.responseInvalid
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw LocalManagerTrafficError.authenticationFailed
        }
        guard response.statusCode == 200 else { throw LocalManagerTrafficError.apiUnavailable }
        return result.0
    }
}
