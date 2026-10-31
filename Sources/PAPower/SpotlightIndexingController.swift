import Foundation

/// 通过 mdutil 读取与切换 Spotlight 索引；切换需要管理员授权，由 osascript 弹出系统密码框。
@MainActor
final class SpotlightIndexingController: ObservableObject {
    @Published private(set) var isEnabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private static let mdutilPath = "/usr/bin/mdutil"
    /// 用户数据所在卷；它的状态代表 Spotlight 是否在为用户文件建索引。
    private static let statusVolume = "/System/Volumes/Data"

    init() {
        refresh()
    }

    func refresh() {
        Task {
            let output = await Self.run(Self.mdutilPath, ["-s", Self.statusVolume])
            isEnabled = Self.parseStatus(output.stdout)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            let command = "\(Self.mdutilPath) -a -i \(enabled ? "on" : "off")"
            let script = "do shell script \"\(command)\" with administrator privileges"
            let result = await Self.run("/usr/bin/osascript", ["-e", script])

            // -128 表示用户在密码框点了取消，不当作错误。
            if result.status != 0, !result.stderr.contains("-128") {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = message.isEmpty ? "切换 Spotlight 索引失败" : message
            }

            let status = await Self.run(Self.mdutilPath, ["-s", Self.statusVolume])
            isEnabled = Self.parseStatus(status.stdout)
            isBusy = false
        }
    }

    nonisolated static func parseStatus(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("indexing enabled") { return true }
        if text.contains("indexing disabled") { return false }
        return nil
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> ProcessResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
            }

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }
}
