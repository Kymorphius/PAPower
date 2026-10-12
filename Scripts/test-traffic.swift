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
        route: String = "proxy", start: Date? = date.addingTimeInterval(-1),
        metadata: TrafficConnectionMetadata? = nil
    ) -> TrafficConnection {
        TrafficConnection(id: id, upload: upload, download: download, start: start, chains: [route], metadata: metadata)
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
        try expect(first.topSources.isEmpty, "First sample has no observed source rates")

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
        try expect(closed.topSources.count == 1, "Closed final bytes do not appear in source ranking")

        let empty = accumulator.consume(reading(1_220, 2_400), at: date.addingTimeInterval(3), uptime: 103)
        try expect(empty.connectionCount == 0 && empty.unclassifiedRate == TrafficValues(upload: 10, download: 20), "No active connections still account for global traffic")
        try expect(empty.topSources.isEmpty, "Global residual has no invented source")

        let restarted = accumulator.consume(reading(3, 4), at: date.addingTimeInterval(4), uptime: 104)
        try expect(restarted.combinedRate == nil && restarted.combinedTotal == empty.combinedTotal, "Restart creates a baseline and preserves measured totals")
        try expect(restarted.topSources.isEmpty, "Restart clears source ranking")

        accumulator.invalidateBaseline()
        let reconnected = accumulator.consume(reading(100_000, 100_000), at: date.addingTimeInterval(5), uptime: 105)
        try expect(reconnected.combinedRate == nil && reconnected.combinedTotal == empty.combinedTotal, "Failure/reconnect never accounts for an unobserved gap")
        try expect(reconnected.topSources.isEmpty, "Reconnect clears source ranking")
        let continued = accumulator.consume(reading(100_020, 100_030), at: date.addingTimeInterval(6), uptime: 106)
        try expect(continued.combinedRate == TrafficValues(upload: 20, download: 30), "Reconnect resumes from the new baseline")

        let slept = accumulator.consume(reading(500_000, 500_000), at: date.addingTimeInterval(50), uptime: 150)
        try expect(slept.combinedRate == nil && slept.combinedTotal == continued.combinedTotal, "Long sampling gaps cannot create spikes")
        try expect(slept.topSources.isEmpty, "Long intervals clear source ranking")
        let changed = accumulator.consume(reading(600_000, 600_000, identity: "new-config"), at: date.addingTimeInterval(51), uptime: 151)
        try expect(changed.combinedRate == nil && changed.combinedTotal == continued.combinedTotal, "Configuration changes establish a new baseline")
        try expect(changed.topSources.isEmpty, "Configuration changes clear source ranking")

        accumulator.reset()
        let reset = accumulator.consume(reading(700_000, 700_000), at: date.addingTimeInterval(52), uptime: 152)
        try expect(reset.combinedTotal == .zero && reset.monitoringSince == date.addingTimeInterval(52), "Reset restarts this monitoring session")
        try expect(reset.topSources.isEmpty, "Reset clears source ranking")
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

    static func testSourceRanking() throws {
        let main = TrafficConnectionMetadata(
            host: "service.example",
            processPath: "/Applications/Example Browser (Beta).app/Contents/MacOS/Example Browser (\(NSUserName()))"
        )
        let helper = TrafficConnectionMetadata(
            processPath: "/Applications/Example Browser (Beta).app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper (\(NSUserName()))"
        )
        let tool = TrafficConnectionMetadata(processPath: "/opt/example/bin/shared (\(NSUserName()))")
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(reading(1_000_000, 2_000_000, [
            connection("main", 1_000, 500, metadata: main),
            connection("helper", 200, 100, route: "direct", metadata: helper),
            connection("tool", 500_000, 500_000, metadata: tool)
        ]), at: date, uptime: 100)
        let active = accumulator.consume(reading(1_000_170, 2_000_260, [
            connection("main", 1_100, 700, metadata: main),
            connection("helper", 250, 150, route: "direct", metadata: helper),
            connection("tool", 500_020, 500_010, metadata: tool)
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(active.topSources.count == 2 && active.topSources[0].kind == .application, "Rank uses current transfer rate rather than lifetime counters")
        let app = active.topSources[0]
        try expect(app.name == "Example Browser (Beta)" && app.applicationPath == "/Applications/Example Browser (Beta).app", "Nested Helpers aggregate to the outer application and internal parentheses survive")
        try expect(app.rate == TrafficValues(upload: 150, download: 250), "Application rates aggregate all helper deltas")
        try expect(app.connectionCount == 2 && app.proxyConnectionCount == 1 && app.directConnectionCount == 1, "Same application preserves both route counts")
        try expect(app.routeDescription == "代理 + 直连" && app.kindDescription == "应用", "Source rows expose route and kind labels")
        try expect(active.topSources[1].name == "shared" && active.topSources[1].kind == .process, "Non-app paths use executable basename after the user suffix")

        let next = accumulator.consume(reading(1_000_270, 2_000_260, [
            connection("main", 1_100, 700, metadata: main),
            connection("helper", 250, 150, route: "direct", metadata: helper),
            connection("tool", 500_120, 500_010, metadata: tool)
        ]), at: date.addingTimeInterval(2), uptime: 102)
        try expect(next.topSources.count == 1 && next.topSources[0].name == "shared", "Idle prior leaders disappear and the current active source becomes first")
        try expect(next.topSources[0].rate == TrafficValues(upload: 100, download: 0), "Ranking does not retain previous interval traffic")

        var pathAccumulator = TrafficAccumulator()
        _ = pathAccumulator.consume(reading(0, 0), at: date, uptime: 100)
        let started = date.addingTimeInterval(0.5)
        let paths = [
            "/opt/one/bin/shared (\(NSUserName()))", "/opt/two/bin/shared (\(NSUserName()))",
            "/Applications/Example.app/../Other/tool (\(NSUserName()))",
            "/opt/Example.application/tool (\(NSUserName()))",
            "/Other/Example Browser (Beta).app/Contents/MacOS/Example Browser (\(NSUserName()))"
        ]
        let distinct = pathAccumulator.consume(reading(5, 0, paths.enumerated().map {
            connection("path\($0.offset)", 1, 0, start: started, metadata: .init(processPath: $0.element))
        }), at: date.addingTimeInterval(1), uptime: 101)
        try expect(distinct.topSources.count == 5, "Executable basenames in different paths remain distinct")
        try expect(distinct.topSources.filter { $0.kind == .application }.count == 1, "Lexical path normalization and .app component matching avoid false app attribution")
        try expect(distinct.topSources.contains { $0.detail == "/Applications/Other/tool" }, "Parent path segments normalize before app classification")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("papower-source-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Tool (\(NSUserName()))")
        try Data().write(to: original)
        var literalPath = TrafficAccumulator()
        _ = literalPath.consume(reading(0, 0), at: date, uptime: 100)
        let preserved = literalPath.consume(reading(1, 0, [
            connection("literal", 1, 0, start: started, metadata: .init(processPath: original.path))
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(preserved.topSources[0].detail == original.path, "An existing filename with an account-shaped suffix is not stripped")
    }

    static func testSourceFallbacksAndDecoding() throws {
        for metadata: Any in [NSNull(), [:], ["host": 42, "process": 123, "destinationPort": false]] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "optional", "upload": 0, "download": 0, "chains": ["direct"], "metadata": metadata
            ])
            _ = try JSONDecoder().decode(TrafficConnection.self, from: data)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "metadata", "upload": 0, "download": 0, "chains": ["direct"],
            "metadata": ["host": "service.example", "destinationIP": "2001:db8::1", "destinationPort": 443]
        ])
        let decoded = try JSONDecoder().decode(TrafficConnection.self, from: data)
        try expect(decoded.metadata?.destinationPort == "443", "Destination ports support both numeric and string API encodings")

        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(reading(0, 0), at: date, uptime: 100)
        let started = date.addingTimeInterval(0.5)
        let fallback = accumulator.consume(reading(7, 0, [
            connection("host", 1, 0, start: started, metadata: .init(host: "Service.Example.", processPath: "relative/Browser.app/tool")),
            connection("ipv6", 1, 0, start: started, metadata: .init(host: " ", destinationIP: "2001:db8::1", destinationPort: "443")),
            connection("ipv6-alt", 1, 0, start: started, metadata: .init(destinationIP: "2001:db8::1", destinationPort: "8443")),
            connection("unknown1", 1, 0, start: started), connection("unknown2", 1, 0, start: started),
            connection("process", 1, 0, start: started, metadata: .init(process: "service.example")),
            connection("named", 1, 0, start: started, metadata: .init(host: "ignored.example", processName: "Fixture Worker"))
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(fallback.topSources.count == 7, "Fallback identities and unknown connections remain independent")
        try expect(fallback.topSources.filter { $0.kind == .unknown }.count == 2, "Missing metadata never merges all unknown sources")
        try expect(fallback.topSources.contains { $0.name == "[2001:db8::1]:443" && $0.kind == .target }, "IPv6 destinations use bracketed addresses")
        try expect(fallback.topSources.contains { $0.name == "service.example" && $0.kind == .target }, "Hostname fallback normalizes the target without guessing an application")
        try expect(fallback.topSources.contains { $0.name == "service.example" && $0.kind == .process }, "Process and target names occupy separate identity namespaces")
        try expect(fallback.topSources.contains { $0.name == "Fixture Worker" && $0.kind == .process }, "Explicit process names take precedence over host fallback")
    }

    static func testSourceBudgetsAndIdentityChanges() throws {
        let a = TrafficConnectionMetadata(processPath: "/opt/example/a (\(NSUserName()))")
        let b = TrafficConnectionMetadata(processPath: "/opt/example/b (\(NSUserName()))")
        let c = TrafficConnectionMetadata(processPath: "/opt/example/c (\(NSUserName()))")
        var accumulator = TrafficAccumulator()
        _ = accumulator.consume(reading(0, 0, [
            connection("changed", 0, 0, metadata: a), connection("stable", 0, 0, metadata: c)
        ]), at: date, uptime: 100)
        let changed = accumulator.consume(reading(100, 40, [
            connection("changed", 100, 40, metadata: b), connection("stable", 100, 40, metadata: c)
        ]), at: date.addingTimeInterval(1), uptime: 101)
        try expect(changed.topSources.count == 1 && changed.topSources[0].name == "c", "Changed metadata cannot transfer the prior interval to a new identity")
        try expect(changed.topSources[0].rate == TrafficValues(upload: 50, download: 20), "Changed-source deltas still participate in the shared global scaling denominator")

        let stable = accumulator.consume(reading(200, 80, [
            connection("changed", 160, 70, metadata: b), connection("stable", 140, 50, metadata: c)
        ]), at: date.addingTimeInterval(2), uptime: 102)
        try expect(stable.topSources[0].name == "b" && stable.topSources[0].rate == TrafficValues(upload: 60, download: 30), "A new identity becomes attributable after its own stable baseline")

        var budget = TrafficAccumulator()
        _ = budget.consume(reading(0, 0), at: date, uptime: 100)
        let started = date.addingTimeInterval(0.5)
        let app = TrafficConnectionMetadata(processPath: "/Applications/Fixture.app/Contents/MacOS/Fixture (\(NSUserName()))")
        let raced = budget.consume(reading(100, 50, [
            connection("p", 200, 200, start: started, metadata: app),
            connection("d", 100, 100, route: "direct", start: started, metadata: app),
            connection("u", 100, 100, route: "group", start: started, metadata: .init(host: "unknown.example"))
        ]), at: date.addingTimeInterval(1), uptime: 101)
        let sourceSum = raced.topSources.reduce(TrafficValues.zero) { $0 + $1.rate }
        try expect(near(sourceSum.upload, 100) && near(sourceSum.download, 50), "Ranked sources share per-direction global scaling with traffic totals")
        try expect(raced.topSources[0].rate == TrafficValues(upload: 75, download: 37.5), "Grouped application deltas scale in both directions")
        try expect(raced.topSources[1].unclassifiedConnectionCount == 1 && raced.topSources[1].routeDescription == "未归类", "Unknown terminal types retain source-level route uncertainty")

        var capped = TrafficAccumulator()
        _ = capped.consume(reading(0, 0), at: date, uptime: 100)
        let tied = capped.consume(reading(11, 0, (0..<11).map {
            connection("tie\($0)", 1, 0, start: started, metadata: .init(host: String(format: "h%02d.example", $0)))
        }), at: date.addingTimeInterval(1), uptime: 101)
        try expect(tied.topSources.count == 10 && tied.topSources.map(\.id) == tied.topSources.map(\.id).sorted(), "Source ranking caps at ten and ties remain deterministic")
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
            try testSourceRanking()
            try testSourceFallbacksAndDecoding()
            try testSourceBudgetsAndIdentityChanges()
            try await testClient()
            print("Traffic tests passed: classification, residuals, baselines, sources, ranking, races, configuration, authentication and schema.")
        } catch {
            FileHandle.standardError.write(Data("Traffic tests failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
