import Darwin
import Foundation

enum TrafficProbeReporter {
    static func printAndExit() -> Never {
        Task {
            do {
                let client = LocalManagerTrafficClient()
                var accumulator = TrafficAccumulator()
                var samples: [TrafficSnapshot] = []
                samples.append(accumulator.consume(try await client.capture()))
                try await Task.sleep(nanoseconds: 1_000_000_000)
                samples.append(accumulator.consume(try await client.capture()))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try encoder.encode(samples))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(EXIT_SUCCESS)
            } catch {
                // Do not expose configuration, credentials, connection metadata or raw responses.
                let payload = ["error": error.localizedDescription]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                    FileHandle.standardError.write(data)
                    FileHandle.standardError.write(Data("\n".utf8))
                }
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
