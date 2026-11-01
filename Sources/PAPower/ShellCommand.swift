import Foundation

/// 在后台线程执行系统命令；需要管理员权限的命令经 osascript 弹出系统密码框。
enum ShellCommand {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        /// osascript 的 -128 表示用户在密码框点了取消，不当作错误。
        var isUserCancelled: Bool { stderr.contains("-128") }
    }

    static func run(_ path: String, _ arguments: [String]) async -> Result {
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
                return Result(status: -1, stdout: "", stderr: error.localizedDescription)
            }

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }

    /// command 会嵌入 AppleScript 字符串，调用方只传固定路径与数字参数，不含引号。
    static func runAsAdministrator(_ command: String) async -> Result {
        let script = "do shell script \"\(command)\" with administrator privileges"
        return await run("/usr/bin/osascript", ["-e", script])
    }

    /// 失败时给面板显示的错误；成功或用户取消时为 nil。
    static func failureMessage(_ result: Result, fallback: String) -> String? {
        guard result.status != 0, !result.isUserCancelled else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }
}
