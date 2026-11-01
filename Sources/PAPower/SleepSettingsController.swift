import Foundation
import IOKit.pwr_mgt

/// pmset 中与睡眠相关的设置；nil 表示本机没有该电源或不支持该项（如台式机没有电池）。
struct SleepSettings: Equatable {
    /// 分钟，0 表示从不。
    var batterySleep: Int?
    var batteryDisplaySleep: Int?
    var acSleep: Int?
    var acDisplaySleep: Int?
    var powerNap: Bool?
    var wakeForNetwork: Bool?
    var tcpKeepAlive: Bool?

    var hasBattery: Bool { batterySleep != nil }
    var hasAC: Bool { acSleep != nil }

    /// 解析 `pmset -g custom`：按 “Battery Power:” “AC Power:” 分节，每行“键 值”。
    /// 后台活动项在电池与电源下分开存储，任一电源开启即视为开启，应用时两者一起设置。
    static func parse(_ output: String) -> SleepSettings? {
        var sections: [String: [String: Int]] = [:]
        var current: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                current = String(trimmed.dropLast())
                continue
            }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard let current, parts.count >= 2, let value = Int(parts[parts.count - 1]) else {
                continue
            }
            sections[current, default: [:]][parts.dropLast().joined(separator: " ")] = value
        }

        let battery = sections["Battery Power"]
        let ac = sections["AC Power"]
        guard battery != nil || ac != nil else { return nil }

        func flag(_ key: String) -> Bool? {
            let values = [battery?[key], ac?[key]].compactMap { $0 }
            return values.isEmpty ? nil : values.contains { $0 != 0 }
        }

        return SleepSettings(
            batterySleep: battery?["sleep"],
            batteryDisplaySleep: battery?["displaysleep"],
            acSleep: ac?["sleep"],
            acDisplaySleep: ac?["displaysleep"],
            powerNap: flag("powernap"),
            wakeForNetwork: flag("womp"),
            tcpKeepAlive: flag("tcpkeepalive")
        )
    }

    /// 生成把 applied 改成 self 所需的 pmset 命令，用 && 串成一条，只需授权一次。
    func pmsetCommand(from applied: SleepSettings) -> String? {
        func timers(_ sleep: Int?, _ display: Int?, _ oldSleep: Int?, _ oldDisplay: Int?) -> [String] {
            var arguments: [String] = []
            if let sleep, sleep != oldSleep { arguments += ["sleep", "\(sleep)"] }
            if let display, display != oldDisplay { arguments += ["displaysleep", "\(display)"] }
            return arguments
        }

        var commands: [String] = []
        let battery = timers(batterySleep, batteryDisplaySleep, applied.batterySleep, applied.batteryDisplaySleep)
        if !battery.isEmpty {
            commands.append((["/usr/bin/pmset", "-b"] + battery).joined(separator: " "))
        }
        let ac = timers(acSleep, acDisplaySleep, applied.acSleep, applied.acDisplaySleep)
        if !ac.isEmpty {
            commands.append((["/usr/bin/pmset", "-c"] + ac).joined(separator: " "))
        }

        var background: [String] = []
        for (key, new, old) in [
            ("powernap", powerNap, applied.powerNap),
            ("womp", wakeForNetwork, applied.wakeForNetwork),
            ("tcpkeepalive", tcpKeepAlive, applied.tcpKeepAlive)
        ] {
            if let new, new != old { background += [key, new ? "1" : "0"] }
        }
        if !background.isEmpty {
            commands.append((["/usr/bin/pmset", "-a"] + background).joined(separator: " "))
        }
        return commands.isEmpty ? nil : commands.joined(separator: " && ")
    }
}

/// 面板中的睡眠控制。
/// - 保持唤醒：进程内的电源断言，无需授权，退出 PAPower 即失效。
/// - 合盖不睡眠：`pmset disablesleep`，系统级，立即生效。
/// - 自动睡眠时间与后台活动：先在面板里编辑，点“应用更改”后一次授权写入。
@MainActor
final class SleepSettingsController: ObservableObject {
    enum KeepAwake: Int, CaseIterable, Identifiable {
        case off = 0
        case thirtyMinutes = 30
        case oneHour = 60
        case twoHours = 120
        case fourHours = 240
        case indefinitely = -1

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .off: return "关闭"
            case .thirtyMinutes: return "30 分钟"
            case .oneHour: return "1 小时"
            case .twoHours: return "2 小时"
            case .fourHours: return "4 小时"
            case .indefinitely: return "一直"
            }
        }
    }

    private enum DefaultsKey {
        static let keepsDisplayAwake = "keepAwakeIncludesDisplay"
    }

    @Published private(set) var keepAwake: KeepAwake = .off
    @Published private(set) var keepAwakeUntil: Date?
    @Published private(set) var keepsDisplayAwake: Bool
    @Published private(set) var isSleepDisabled: Bool?
    /// 系统当前生效的设置。
    @Published private(set) var applied: SleepSettings?
    /// 面板中编辑中的设置，未应用前与 applied 不同。
    @Published private(set) var draft: SleepSettings?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private var assertionID: IOPMAssertionID?
    private var expiryTask: Task<Void, Never>?

    var hasPendingChanges: Bool {
        guard let draft, let applied else { return false }
        return draft != applied
    }

    init() {
        keepsDisplayAwake = UserDefaults.standard.bool(forKey: DefaultsKey.keepsDisplayAwake)
        refresh()
    }

    /// 重新读取系统设置；未应用的编辑会被丢弃。
    func refresh() {
        Task {
            async let custom = ShellCommand.run("/usr/bin/pmset", ["-g", "custom"])
            async let live = ShellCommand.run("/usr/bin/pmset", ["-g"])
            let settings = SleepSettings.parse(await custom.stdout)
            applied = settings
            draft = settings
            isSleepDisabled = Self.parseSleepDisabled(await live.stdout)
        }
    }

    // MARK: - 保持唤醒

    func setKeepAwake(_ option: KeepAwake) {
        keepAwake = option
        expiryTask?.cancel()
        expiryTask = nil
        releaseAssertion()
        keepAwakeUntil = nil
        guard option != .off else { return }

        guard createAssertion() else {
            keepAwake = .off
            errorMessage = "无法阻止系统睡眠"
            return
        }
        guard option.rawValue > 0 else { return }

        let until = Date().addingTimeInterval(TimeInterval(option.rawValue * 60))
        keepAwakeUntil = until
        // 分段等待并比对墙上时间：合盖睡眠期间 Task.sleep 不计时，醒来后要按实际时间判断是否到期。
        expiryTask = Task { [weak self] in
            while !Task.isCancelled, Date() < until {
                let remaining = until.timeIntervalSinceNow
                try? await Task.sleep(nanoseconds: UInt64(min(max(remaining, 0), 30) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.setKeepAwake(.off)
        }
    }

    func setKeepsDisplayAwake(_ enabled: Bool) {
        keepsDisplayAwake = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.keepsDisplayAwake)
        guard assertionID != nil else { return }
        releaseAssertion()
        if !createAssertion() {
            setKeepAwake(.off)
            errorMessage = "无法阻止系统睡眠"
        }
    }

    /// 屏幕常亮的断言同时阻止系统闲置睡眠，因此二选一即可。
    private func createAssertion() -> Bool {
        let type = keepsDisplayAwake
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "PAPower Keep Awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }

    private func releaseAssertion() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    // MARK: - 合盖不睡眠

    func setSleepDisabled(_ disabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            let result = await ShellCommand.runAsAdministrator(
                "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
            )
            errorMessage = ShellCommand.failureMessage(result, fallback: "切换合盖不睡眠失败")
            let live = await ShellCommand.run("/usr/bin/pmset", ["-g"])
            isSleepDisabled = Self.parseSleepDisabled(live.stdout)
            isBusy = false
        }
    }

    // MARK: - 自动睡眠时间与后台活动

    func updateDraft(_ change: (inout SleepSettings) -> Void) {
        guard var settings = draft else { return }
        change(&settings)
        draft = settings
    }

    func discardChanges() {
        draft = applied
    }

    func applyChanges() {
        guard !isBusy, let draft, let applied,
              let command = draft.pmsetCommand(from: applied) else { return }
        isBusy = true
        errorMessage = nil
        Task {
            let result = await ShellCommand.runAsAdministrator(command)
            errorMessage = ShellCommand.failureMessage(result, fallback: "应用睡眠设置失败")
            let custom = await ShellCommand.run("/usr/bin/pmset", ["-g", "custom"])
            let settings = SleepSettings.parse(custom.stdout)
            self.applied = settings
            // 取消授权时保留编辑，方便再次点击应用。
            if !result.isUserCancelled {
                self.draft = settings
            }
            isBusy = false
        }
    }

    /// `pmset -g` 中的 “SleepDisabled  0/1”；即 `pmset disablesleep` 的当前值。
    nonisolated static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "SleepDisabled", let value = Int(parts[1]) {
                return value != 0
            }
        }
        return nil
    }
}
