// Run from the project root:
// swiftc -parse-as-library Sources/PAPower/TrafficModels.swift Sources/PAPower/TrafficAccumulator.swift \
//   Sources/PAPower/LocalManagerTrafficClient.swift Scripts/test-traffic.swift -o /tmp/papower-traffic-tests
// /tmp/papower-traffic-tests
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func near(_ actual: Double, _ expected: Double) -> Bool {
    abs(actual - expected) < 0.000_001
}

private final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: handler(request).0, httpVersion: "HTTP/1.1", headerFields: nil
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: handler(request).1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private enum TrafficTests {
    static let date = Date(timeIntervalSince1970: 1_000)
    static let types = ["proxy": "Shadowsocks", "direct": "Direct", "group": "Selector"]

    static func connection(
        _ id: String, _ upload: UInt64, _ download: UInt64,
        route: String = "proxy", start: Date? = date.addingTimeInterval(-1)
    ) -> TrafficConnection {
        TrafficConnection(id: id, upload: upload, download: download, start: start, chains: [route])
    }

    static func reading(
        _ upload: UInt64, _ download: UInt64, _ connections: [TrafficConnection] = [],
        identity: String = "fixture"
    ) -> TrafficReading {
        TrafficReading(
            uploadTotal: upload, downloadTotal: download, connections: connections,
            proxyTypes: types, sourceIdentity: identity, sourceDescription: "fixture"
        )
    }

    static func testAccumulation() throws {
        var accumulator = TrafficAccumulator()
        let first = accumulator.consume(reading(1_000, 2_000, [
            connection("p", 10, 20), connection("d", 30, 40, route: "direct")
        ]), at: date, uptime: 100)
        try expect(first.combinedRate == nil && first.combinedTotal == .zero, "First sample establishes a baseline")

        let second = accumulator.consume(reading(1_150, 2_300, [
            connection("p", 110, 220), connection("d", 80, 140, route: "direct")
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(second.proxyRate == TrafficValues(upload: 100, download: 200), "Proxy deltas use terminal outbound types")
        try expect(second.directRate == TrafficValues(upload: 50, download: 100), "Direct deltas are separate")
        try expect(second.unclassifiedTotal == .zero, "Fully observed sample has no residual")
        try expect(second.proxyConnectionCount == 1 && second.directConnectionCount == 1, "Connection counts classify separately")

        let closed = accumulator.consume(reading(1_210, 2_380, [
            connection("d", 100, 170, route: "direct")
        ]), at: date.addingTimeInterval(2), uptime: 102)
        try expect(closed.proxyRate == .zero, "Closed connection does not invent final bytes")
        try expect(closed.unclassifiedRate == TrafficValues(upload: 40, download: 50), "Closed tail remains unclassified")
        try expect(closed.combinedTotal == TrafficValues(upload: 210, download: 380), "Classified totals reconcile with global increments")

        let empty = accumulator.consume(reading(1_220, 2_400), at: date.addingTimeInterval(3), uptime: 103)
        try expect(empty.connectionCount == 0 && empty.unclassifiedRate == TrafficValues(upload: 10, download: 20), "No active connections still account for global traffic")

        let restarted = accumulator.consume(reading(3, 4), at: date.addingTimeInterval(4), uptime: 104)
        try expect(restarted.combinedRate == nil && restarted.combinedTotal == empty.combinedTotal, "Restart creates a baseline and preserves measured totals")

        accumulator.invalidateBaseline()
        let reconnected = accumulator.consume(reading(100_000, 100_000), at: date.addingTimeInterval(5), uptime: 105)
        try expect(reconnected.combinedRate == nil && reconnected.combinedTotal == empty.combinedTotal, "Failure/reconnect never accounts for an unobserved gap")
        let continued = accumulator.consume(reading(100_020, 100_030), at: date.addingTimeInterval(6), uptime: 106)
        try expect(continued.combinedRate == TrafficValues(upload: 20, download: 30), "Reconnect resumes from the new baseline")

        let slept = accumulator.consume(reading(500_000, 500_000), at: date.addingTimeInterval(50), uptime: 150)
        try expect(slept.combinedRate == nil && slept.combinedTotal == continued.combinedTotal, "Long sampling gaps cannot create spikes")
        let changed = accumulator.consume(reading(600_000, 600_000, identity: "new-config"), at: date.addingTimeInterval(51), uptime: 151)
        try expect(changed.combinedRate == nil && changed.combinedTotal == continued.combinedTotal, "Configuration changes establish a new baseline")

        accumulator.reset()
        let reset = accumulator.consume(reading(700_000, 700_000), at: date.addingTimeInterval(52), uptime: 152)
        try expect(reset.combinedTotal == .zero && reset.monitoringSince == date.addingTimeInterval(52), "Reset restarts this monitoring session")
    }

    static func testConnectionTimestamps() throws {
        for timestamp in ["2026-10-11T14:30:45Z", "2026-10-11T14:30:45.123456789Z"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "date", "upload": 0, "download": 0,
                "start": timestamp, "chains": ["direct"]
            ])
            let connection = try JSONDecoder().decode(TrafficConnection.self, from: data)
            try expect(connection.start != nil, "Core timestamps support both whole and fractional seconds")
        }
    }

    static func testAttributionBoundaries() throws {
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(reading(0, 0), at: date, uptime: 100)
        let new = accumulator.consume(reading(100, 100, [
            connection("p", 60, 60, start: date.addingTimeInterval(0.5))
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(new.proxyTotal == TrafficValues(upload: 60, download: 60), "New connection bytes are classified only inside the observation interval")
        try expect(new.unclassifiedTotal == TrafficValues(upload: 40, download: 40), "Unobserved closed connections remain unknown")

        var delayedAccumulator = TrafficAccumulator()
        _ = delayedAccumulator.consume(reading(500, 500), at: date, uptime: 100)
        let delayed = delayedAccumulator.consume(reading(600, 600, [connection("old", 10_000, 10_000)]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(delayed.proxyTotal == .zero && delayed.unclassifiedTotal == TrafficValues(upload: 100, download: 100), "Delayed old connections cannot attribute historical bytes")

        var raceAccumulator = TrafficAccumulator()
        _ = raceAccumulator.consume(reading(0, 0), at: date, uptime: 100)
        let started = date.addingTimeInterval(0.5)
        let race = raceAccumulator.consume(reading(100, 100, [
            connection("p", 200, 200, start: started),
            connection("d", 100, 100, route: "direct", start: started),
            connection("u", 100, 100, route: "group", start: started)
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(near(race.proxyTotal.upload, 50) && near(race.directTotal.upload, 25), "Non-atomic oversized active deltas respect the global budget")
        try expect(near(race.unclassifiedTotal.upload, 25) && near(race.combinedTotal.upload, 100), "Scaled totals preserve unknown traffic and reconcile exactly")
        try expect(race.unclassifiedConnectionCount == 1, "Selector groups do not count as proxies")

        let misleading = TrafficConnection(id: "terminal", upload: 1, download: 1, start: date, chains: ["group", "direct"])
        try expect(reading(0, 0).route(for: misleading) == .unclassified, "Only the first chain element is the terminal")
        let direct = TrafficConnection(id: "direct", upload: 1, download: 1, start: date, chains: ["direct", "proxy"])
        try expect(reading(0, 0).route(for: direct) == .direct, "Later chain names never override the terminal")
        let absent = connection("absent", 1, 1, route: "missing")
        try expect(reading(0, 0).route(for: absent) == .unclassified, "Unknown outbound types remain unknown")
    }

    static func testClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papower-traffic-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("var/state/network/sing-box/runtime.json")
        let fallback = root.appendingPathComponent("10.network/20.sing-box/sing-box.json")
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
        func config(_ controller: String, secret: String? = nil) throws -> Data {
            var api: [String: String] = ["external_controller": controller]
            if let secret { api["secret"] = secret }
            return try JSONSerialization.data(withJSONObject: ["experimental": ["clash_api": api]])
        }
        try config("127.0.0.1:9101", secret: "fixture-token").write(to: runtime)
        try config("127.0.0.1:9102").write(to: fallback)

        func client() -> LocalManagerTrafficClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            return LocalManagerTrafficClient(root: root, session: URLSession(configuration: configuration))
        }
        let connections = Data("{\"uploadTotal\":100,\"downloadTotal\":200,\"connections\":[]}".utf8)
        let proxies = Data("{\"proxies\":{\"direct\":{\"type\":\"Direct\"}}}".utf8)
        FixtureProtocol.handler = { request in
            guard request.url?.port == 9101,
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else {
                return (401, Data())
            }
            return (200, request.url?.path == "/connections" ? connections : proxies)
        }
        let runtimeReading = try await client().capture()
        try expect(runtimeReading.uploadTotal == 100 && runtimeReading.proxyTypes["direct"] == "Direct", "Runtime config wins and in-memory Bearer authentication is sent")
        try expect(!runtimeReading.sourceIdentity.contains("fixture-token") && !runtimeReading.sourceDescription.contains("fixture-token"), "No secret enters diagnostic identity or display")

        FixtureProtocol.handler = { request in
            (200, request.url?.path == "/connections"
                ? Data("{\"uploadTotal\":100,\"downloadTotal\":200,\"connections\":null}".utf8)
                : proxies)
        }
        let nullConnections = try await client().capture()
        try expect(nullConnections.connections.isEmpty, "Explicit null connections represents an empty tracker list")

        FixtureProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await client().capture()
            throw TestFailure(description: "Unauthorized API must fail")
        } catch LocalManagerTrafficError.authenticationFailed {}

        FixtureProtocol.handler = { request in
            (200, request.url?.path == "/connections" ? Data("{\"connections\":[]}".utf8) : proxies)
        }
        do {
            _ = try await client().capture()
            throw TestFailure(description: "Missing authoritative counters must fail")
        } catch LocalManagerTrafficError.responseInvalid {}

        try config("https://127.0.0.1:9101").write(to: runtime)
        do {
            _ = try await client().capture()
            throw TestFailure(description: "HTTPS controller must be rejected")
        } catch LocalManagerTrafficError.controllerInvalid {}

        try config("192.168.1.1:9101").write(to: runtime)
        do {
            _ = try await client().capture()
            throw TestFailure(description: "Remote controller must be rejected")
        } catch LocalManagerTrafficError.controllerInvalid {}

        try FileManager.default.removeItem(at: runtime)
        FixtureProtocol.handler = { request in
            guard request.url?.port == 9102, request.value(forHTTPHeaderField: "Authorization") == nil else {
                return (401, Data())
            }
            return (200, request.url?.path == "/connections" ? connections : proxies)
        }
        _ = try await client().capture()
    }

    static func main() async {
        do {
            try testAccumulation()
            try testConnectionTimestamps()
            try testAttributionBoundaries()
            try await testClient()
            print("Traffic tests passed: classification, residuals, baselines, races, configuration, authentication and schema.")
        } catch {
            FileHandle.standardError.write(Data("Traffic tests failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
