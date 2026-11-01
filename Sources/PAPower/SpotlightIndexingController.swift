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
            let output = await ShellCommand.run(Self.mdutilPath, ["-s", Self.statusVolume])
            isEnabled = Self.parseStatus(output.stdout)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            let result = await ShellCommand.runAsAdministrator(
                "\(Self.mdutilPath) -a -i \(enabled ? "on" : "off")"
            )
            errorMessage = ShellCommand.failureMessage(result, fallback: "切换 Spotlight 索引失败")

            let status = await ShellCommand.run(Self.mdutilPath, ["-s", Self.statusVolume])
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
}
