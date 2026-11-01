import AppKit
import SwiftUI

/// 菜单栏面板。平时只显示功耗读数、走势、温度与电池；其余收成一行一句摘要，点按才在原处展开。
/// 需要留意的状态以朱砂就地显示，页首震卦的底爻随之转红。
struct MenuBarContentView: View {
    enum Section: String, CaseIterable {
        case activity
        case keyboard
        case sleep
        case settings
    }

    @ObservedObject var monitor: PowerMonitor
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var updateChecker = GitHubUpdateChecker()
    @StateObject private var spotlightIndexing = SpotlightIndexingController()
    @ObservedObject var keyboardBacklight: KeyboardBacklightController
    @ObservedObject var sleepSettings: SleepSettingsController
    /// 面板高度上限；为 nil 时按屏幕可用高度。生成 README 截图时放宽，以完整展开内容。
    var heightLimit: CGFloat?
    /// 打开面板时展开的区块；平时为 nil，每次打开都从静止状态开始。
    var initialSection: Section?

    @State private var openSection: Section?
    /// 内容实际高度；超过屏幕可用高度时改为滚动显示。
    @State private var contentHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header
                reading
                    .padding(.top, 12)
                PowerTrace(values: monitor.history.map(\.watts), isSurging: isSurging)
                    .frame(height: 30)
                    .padding(.top, 10)
                    .help(traceHelp)
                vitals
                    .padding(.top, 12)
                Divider()
                    .padding(.top, 14)
                sections
                    .padding(.top, 6)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(width: 330, height: min(contentHeight ?? maxPanelHeight, maxPanelHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .tint(PanelTheme.ink)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: openSection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: isStirred)
        .onAppear {
            openSection = initialSection
            launchAtLogin.refresh()
            spotlightIndexing.refresh()
            keyboardBacklight.refresh()
            sleepSettings.refresh()
        }
    }

    /// 弹窗最多占用屏幕可用高度，扣除菜单栏下方的箭头与边距。
    private var maxPanelHeight: CGFloat {
        if let heightLimit { return heightLimit }
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(visibleHeight - 40, 320)
    }

    // MARK: - 常驻内容

    private var header: some View {
        HStack(spacing: 8) {
            ThunderTrigram(isStirred: isStirred)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isStirred ? "有 \(stirredCount) 处需要留意" : "一切如常")
                .help("底爻转为朱砂时，表示有需要留意的状态，已在原处标出。")

            Spacer()

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("立即刷新")
            .accessibilityLabel("立即刷新")
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(primaryWattText)
                    .font(.system(size: 46, weight: .light))
                    .monospacedDigit()
                Text("W")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Text(readingCaption)
                    .foregroundStyle(.secondary)
                if isSurging {
                    Text(" · 陡升")
                        .foregroundStyle(PanelTheme.cinnabar)
                }
            }
            .font(.system(size: 11))
        }
        .accessibilityElement(children: .combine)
        .help("优先显示 PSTR 总板级功耗；它不包含电源适配器的转换损耗，因此不是插座侧电表读数。")
    }

    private var vitals: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                ForEach(temperatureReadings, id: \.title) { reading in
                    temperatureCell(reading)
                }
            }
            .help("CPU、GPU 与 SSD 显示当前可识别温区中的最高值；不同芯片提供的温区可能不同。")

            if let battery = monitor.snapshot.battery {
                batteryLine(battery)
            }
        }
        .font(.system(size: 12))
    }

    private func temperatureCell(_ reading: TemperatureReading) -> some View {
        let level = reading.level
        return HStack(spacing: 4) {
            if level != .normal {
                // 形状与颜色并用，不只靠颜色表达偏热。
                Circle()
                    .fill(PanelTheme.cinnabar)
                    .frame(width: 4, height: 4)
            }
            Text(reading.title)
                .foregroundStyle(.secondary)
            Text(reading.value.map { String(format: "%.0f°", $0) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(PanelTheme.cinnabar))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityText)
    }

    private func batteryLine(_ battery: BatterySnapshot) -> some View {
        let isLow = isBatteryLow(battery)
        return HStack(spacing: 6) {
            Image(systemName: batterySymbol(battery))
                .font(.system(size: 12))
            Text(batteryStatus(battery))
            Spacer()
            Text(batteryFlowText(battery))
                .monospacedDigit()
        }
        .foregroundStyle(isLow ? AnyShapeStyle(PanelTheme.cinnabar) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .combine)
        .help(batteryHelp(battery))
    }

    // MARK: - 点按展开的区块

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelDisclosure(
                title: "活跃应用",
                summary: activitySummary,
                isStirred: topActivity.map(isHighLoad) ?? false,
                isExpanded: openSection == .activity,
                toggle: { toggle(.activity) }
            ) {
                activityDetail
            }

            if keyboardBacklight.isAvailable {
                PanelDisclosure(
                    title: "键盘背光",
                    summary: keyboardSummary,
                    isExpanded: openSection == .keyboard,
                    toggle: { toggle(.keyboard) }
                ) {
                    keyboardDetail
                }
            }

            PanelDisclosure(
                title: "睡眠",
                summary: sleepSummary.text,
                isStirred: sleepSummary.isStirred,
                isExpanded: openSection == .sleep,
                toggle: { toggle(.sleep) }
            ) {
                sleepDetail
            }

            PanelDisclosure(
                title: "设置",
                summary: settingsSummary.text,
                isStirred: settingsSummary.isStirred,
                isExpanded: openSection == .settings,
                toggle: { toggle(.settings) }
            ) {
                settingsDetail
            }
        }
    }

    private func toggle(_ section: Section) {
        openSection = openSection == section ? nil : section
    }

    private var activityDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.activeApps.isEmpty {
                Text("正在采样…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.activeApps.prefix(5)) { activity in
                    activityRow(activity)
                }
            }
            Text("按近一分钟的 CPU 活跃度估算，并非逐应用耗电。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .font(.system(size: 13))
    }

    private func activityRow(_ activity: ActiveApp) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = activity.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: activity.isSystemService ? "gearshape.2" : "app")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)

            Text(activity.name)
                .lineLimit(1)
            if activity.processCount > 1 {
                Text("\(activity.processCount) 个进程")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(String(format: "%.0f%%", activity.cpuPercent))
                .monospacedDigit()
                .foregroundStyle(isHighLoad(activity) ? AnyShapeStyle(PanelTheme.cinnabar) : AnyShapeStyle(.secondary))
        }
        .frame(height: 20)
        .accessibilityElement(children: .combine)
    }

    private var keyboardDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "light.min")
                    .foregroundStyle(.secondary)
                Slider(value: keyboardBrightnessBinding, in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("键盘亮度")
                Image(systemName: "light.max")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", keyboardBacklight.brightness * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .help("与系统键盘亮度同步；动效开启时，它决定动效最亮的程度。")

            if keyboardBacklight.supportsEffects {
                QuietMenu(
                    title: "动效",
                    selection: keyboardEffectBinding,
                    options: KeyboardBacklightEffect.allCases,
                    label: \.title
                )
                .help("动效运行时暂停闲置熄灭，屏幕休眠、系统睡眠或合盖时自动暂停，关闭动效后恢复原亮度。")

                if keyboardBacklight.effect != .off {
                    HStack {
                        Text("节奏")
                        Spacer(minLength: 8)
                        Picker("节奏", selection: keyboardEffectSpeedBinding) {
                            ForEach(KeyboardBacklightEffectSpeed.allCases) { speed in
                                Text(speed.title).tag(speed)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 108)
                    }
                }
            }

            QuietCheckbox(title: "低光照下自动调节", isOn: keyboardAutoBrightnessBinding)
                .help("开启后背光随环境光自动调亮或调暗，滑块设定的是基准亮度。")

            QuietMenu(
                title: "闲置后熄灭",
                selection: keyboardIdleDimBinding,
                options: keyboardIdleDimOptions,
                label: idleDimText
            )
        }
        .font(.system(size: 13))
    }

    private var sleepDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuietMenu(
                title: "保持唤醒",
                selection: keepAwakeBinding,
                options: SleepSettingsController.KeepAwake.allCases,
                label: \.title
            )
            .help("阻止系统闲置睡眠，退出 PAPower 后自动失效。合盖仍会睡眠，需要时配合“合盖不睡眠”。")

            if let until = sleepSettings.keepAwakeUntil {
                Text("至 \(until.formatted(date: .omitted, time: .shortened)) 自动结束")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // 屏幕常亮从属于保持唤醒，缩进表示层级。
            QuietCheckbox(title: "唤醒时屏幕常亮", isOn: keepsDisplayAwakeBinding)
                .padding(.leading, 21)

            QuietCheckbox(title: "合盖不睡眠", isOn: sleepDisabledBinding)
                .disabled(sleepSettings.isSleepDisabled == nil || sleepSettings.isBusy)
                .help("系统级设置（pmset disablesleep）：合盖和闲置都不会睡眠，退出 PAPower 后仍然有效。切换需要管理员密码。")

            if sleepSettings.isSleepDisabled == true {
                Text("合盖后不会睡眠，放进包里前请关闭，以免发热耗电。")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.cinnabar)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let draft = sleepSettings.draft {
                sleepTimers(draft)
                    .padding(.top, 4)
                sleepBackgroundToggles(draft)

                if sleepSettings.hasPendingChanges {
                    HStack {
                        Button("还原") {
                            sleepSettings.discardChanges()
                        }
                        Spacer()
                        Button("应用更改") {
                            sleepSettings.applyChanges()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sleepSettings.isBusy)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                    .help("自动睡眠时间与后台活动通过 pmset 写入系统，需要管理员密码。")
                }
            }

            if sleepSettings.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            if let error = sleepSettings.errorMessage {
                errorText(error)
            }
        }
        .font(.system(size: 13))
    }

    private func sleepTimers(_ draft: SleepSettings) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("闲置后")
                if draft.hasBattery {
                    Text("电池")
                }
                if draft.hasAC {
                    Text("电源")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            GridRow {
                Text("睡眠")
                if draft.hasBattery {
                    sleepMinutesMenu("电池下自动睡眠", \.batterySleep)
                }
                if draft.hasAC {
                    sleepMinutesMenu("电源下自动睡眠", \.acSleep)
                }
            }

            GridRow {
                Text("关闭显示器")
                if draft.hasBattery {
                    sleepMinutesMenu("电池下关闭显示器", \.batteryDisplaySleep)
                }
                if draft.hasAC {
                    sleepMinutesMenu("电源下关闭显示器", \.acDisplaySleep)
                }
            }
        }
        .help("闲置多久后系统睡眠或关闭显示器；“从不”对应 pmset 的 0。")
    }

    private func sleepMinutesMenu(
        _ title: String,
        _ keyPath: WritableKeyPath<SleepSettings, Int?>
    ) -> some View {
        let options = sleepMinuteOptions(including: sleepSettings.applied?[keyPath: keyPath])
        return Menu {
            Picker(title, selection: sleepMinutesBinding(keyPath)) {
                ForEach(options, id: \.self) { minutes in
                    Text(sleepMinutesText(minutes)).tag(minutes)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(sleepMinutesText(sleepSettings.draft?[keyPath: keyPath] ?? 0))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func sleepBackgroundToggles(_ draft: SleepSettings) -> some View {
        if draft.powerNap != nil || draft.wakeForNetwork != nil || draft.tcpKeepAlive != nil {
            Text("睡眠时的后台活动")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        if draft.powerNap != nil {
            QuietCheckbox(title: "Power Nap", isOn: sleepFlagBinding(\.powerNap))
                .help("睡眠时定期唤醒以收邮件、同步 iCloud 和备份；关闭可减少睡眠耗电。")
        }
        if draft.wakeForNetwork != nil {
            QuietCheckbox(title: "网络唤醒", isOn: sleepFlagBinding(\.wakeForNetwork))
                .help("允许通过网络访问（如共享、远程登录）唤醒 Mac。")
        }
        if draft.tcpKeepAlive != nil {
            QuietCheckbox(title: "保持网络连接", isOn: sleepFlagBinding(\.tcpKeepAlive))
                .help("睡眠时维持网络连接，供“查找”和推送等服务使用；关闭可减少睡眠耗电。")
        }
    }

    private var settingsDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuietMenu(
                title: "菜单栏布局",
                selection: spaciousLayoutBinding,
                options: [false, true],
                label: { $0 ? "宽松" : "紧凑" }
            )
            QuietMenu(
                title: "小数位数",
                selection: decimalPlacesBinding,
                options: [1, 2],
                label: { "\($0) 位" }
            )
            QuietMenu(
                title: "刷新频率",
                selection: refreshIntervalBinding,
                options: [1.0, 2.0, 5.0],
                label: { "\(Int($0)) 秒" }
            )

            QuietCheckbox(title: "登录时自动启动", isOn: launchAtLoginBinding)
            if let error = launchAtLogin.errorMessage {
                errorText(error)
            }

            HStack(spacing: 6) {
                QuietCheckbox(title: "Spotlight 索引", isOn: spotlightIndexingBinding)
                    .disabled(spotlightIndexing.isEnabled == nil || spotlightIndexing.isBusy)
                    .fixedSize()
                if spotlightIndexing.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .help("关闭后 Spotlight 不再为文件建立索引，可减少 mds_stores 的后台耗电；⌘空格、Finder 与邮件搜索会受影响。切换需要管理员密码。")
            if let error = spotlightIndexing.errorMessage {
                errorText(error)
            }

            updateControl
                .padding(.top, 2)

            HStack {
                Spacer()
                Button("退出 PAPower") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .font(.system(size: 13))
    }

    @ViewBuilder
    private var updateControl: some View {
        HStack(spacing: 6) {
            switch updateChecker.status {
            case .idle:
                Text("版本 \(updateChecker.currentVersion)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("检查更新") {
                    updateChecker.check()
                }

            case .checking:
                Text("版本 \(updateChecker.currentVersion)")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.mini)
                Text("正在检查…")
                    .foregroundStyle(.secondary)

            case .upToDate:
                Text("版本 \(updateChecker.currentVersion) · 已是最新")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("再次检查") {
                    updateChecker.check()
                }

            case let .updateAvailable(version, url):
                Text("可更新到 v\(version)")
                    .foregroundStyle(PanelTheme.cinnabar)
                Spacer()
                Button("前往下载") {
                    updateChecker.openRelease(url)
                }

            case .failed:
                Text("检查更新失败")
                    .foregroundStyle(PanelTheme.cinnabar)
                Spacer()
                Button("打开 GitHub") {
                    updateChecker.openRepository()
                }
                Button("重试") {
                    updateChecker.check()
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(PanelTheme.cinnabar)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 需要留意的状态

    private enum TemperatureLevel {
        case normal
        case warm
        case hot
    }

    private struct TemperatureReading {
        let title: String
        let value: Double?
        let warning: Double
        let critical: Double

        var level: TemperatureLevel {
            guard let value, value >= warning else { return .normal }
            return value >= critical ? .hot : .warm
        }

        var accessibilityText: String {
            guard let value else { return "\(title) 温度不可用" }
            let degrees = "\(title) \(Int(value.rounded())) 摄氏度"
            switch level {
            case .normal: return degrees
            case .warm: return degrees + "，偏热"
            case .hot: return degrees + "，过热"
            }
        }
    }

    private var temperatureReadings: [TemperatureReading] {
        let temperatures = monitor.snapshot.temperatures
        return [
            TemperatureReading(title: "CPU", value: temperatures.cpuCelsius, warning: 90, critical: 105),
            TemperatureReading(title: "GPU", value: temperatures.gpuCelsius, warning: 90, critical: 105),
            TemperatureReading(title: "SSD", value: temperatures.storageCelsius, warning: 60, critical: 75),
            TemperatureReading(
                title: "电池",
                value: monitor.snapshot.battery?.temperatureCelsius,
                warning: 40,
                critical: 45
            )
        ]
    }

    /// 当前功耗明显高于近期均值时视为陡升；样本太少时不判断。
    private var isSurging: Bool {
        guard monitor.history.count >= 5,
              let watts = monitor.snapshot.displayedWatts,
              let average = monitor.averageWatts else {
            return false
        }
        return watts >= 15 && watts >= average * 1.6
    }

    private var topActivity: ActiveApp? {
        monitor.activeApps.first
    }

    private func isHighLoad(_ activity: ActiveApp) -> Bool {
        activity.cpuPercent >= 25
    }

    private func isBatteryLow(_ battery: BatterySnapshot) -> Bool {
        guard let percentage = battery.percentage else { return false }
        return percentage <= 20 && battery.isOnACPower != true
    }

    private var stirredCount: Int {
        var count = temperatureReadings.filter { $0.level != .normal }.count
        if let battery = monitor.snapshot.battery, isBatteryLow(battery) { count += 1 }
        if isSurging { count += 1 }
        if let top = topActivity, isHighLoad(top) { count += 1 }
        if sleepSummary.isStirred { count += 1 }
        if settingsSummary.isStirred { count += 1 }
        return count
    }

    private var isStirred: Bool {
        stirredCount > 0
    }

    // MARK: - 摘要

    private var activitySummary: String {
        guard let top = topActivity else { return "采样中" }
        return "\(top.name) \(Int(top.cpuPercent.rounded()))%"
    }

    private var keyboardSummary: String {
        let percent = "\(Int((keyboardBacklight.brightness * 100).rounded()))%"
        guard keyboardBacklight.supportsEffects, keyboardBacklight.effect != .off else { return percent }
        return "\(keyboardBacklight.effect.title) · \(percent)"
    }

    private var sleepSummary: (text: String, isStirred: Bool) {
        if sleepSettings.isSleepDisabled == true {
            return ("合盖不睡眠", true)
        }
        if sleepSettings.keepAwake != .off {
            if let until = sleepSettings.keepAwakeUntil {
                return ("保持唤醒至 \(until.formatted(date: .omitted, time: .shortened))", true)
            }
            return ("保持唤醒", true)
        }
        if sleepSettings.hasPendingChanges {
            return ("有未应用的更改", false)
        }
        guard let applied = sleepSettings.applied else { return ("", false) }
        // 按当前电源显示对应的自动睡眠时间；台式机没有电池设置。
        let onBattery = monitor.snapshot.battery?.isOnACPower == false
        let minutes = (onBattery ? applied.batterySleep : applied.acSleep) ?? applied.acSleep ?? applied.batterySleep
        guard let minutes, minutes > 0 else { return ("不自动睡眠", false) }
        return ("\(sleepMinutesText(minutes))后睡眠", false)
    }

    private var settingsSummary: (text: String, isStirred: Bool) {
        switch updateChecker.status {
        case let .updateAvailable(version, _):
            return ("可更新到 v\(version)", true)
        default:
            return ("v\(updateChecker.currentVersion)", false)
        }
    }

    private var readingCaption: String {
        let source: String
        switch monitor.snapshot.source {
        case .smcTotal:
            source = "整机功耗"
        case .batteryEstimate:
            source = "电池端估算"
        case .unavailable:
            return monitor.snapshot.diagnostic ?? "等待功耗数据"
        }
        guard let average = monitor.averageWatts, let peak = monitor.peakWatts else { return source }
        return "\(source) · 均 \(formattedWatts(average)) · 峰 \(formattedWatts(peak))"
    }

    private var traceHelp: String {
        let time = monitor.snapshot.sampledAt.formatted(date: .omitted, time: .standard)
        return "\(monitor.historyDurationText)的功耗走势 · 更新于 \(time)"
    }

    private func batteryHelp(_ battery: BatterySnapshot) -> String {
        let voltage = battery.voltageVolts.map { String(format: "%.2f V", $0) } ?? "—"
        let current = battery.currentAmps.map { String(format: "%+.2f A", $0) } ?? "—"
        return "电池功率按电压 × 电流计算 · 电压 \(voltage) · 电流 \(current)"
    }

    // MARK: - 绑定

    private var refreshIntervalBinding: Binding<Double> {
        Binding(
            get: { monitor.refreshInterval },
            set: { monitor.setRefreshInterval($0) }
        )
    }

    private var decimalPlacesBinding: Binding<Int> {
        Binding(
            get: { monitor.decimalPlaces },
            set: { monitor.setDecimalPlaces($0) }
        )
    }

    private var spaciousLayoutBinding: Binding<Bool> {
        Binding(
            get: { monitor.usesSpaciousLayout },
            set: { monitor.setSpaciousLayout($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var spotlightIndexingBinding: Binding<Bool> {
        Binding(
            get: { spotlightIndexing.isEnabled ?? false },
            set: { spotlightIndexing.setEnabled($0) }
        )
    }

    private var keyboardBrightnessBinding: Binding<Double> {
        Binding(
            get: { keyboardBacklight.brightness },
            set: { keyboardBacklight.setBrightness($0) }
        )
    }

    private var keyboardAutoBrightnessBinding: Binding<Bool> {
        Binding(
            get: { keyboardBacklight.isAutoBrightnessEnabled },
            set: { keyboardBacklight.setAutoBrightnessEnabled($0) }
        )
    }

    private var keyboardIdleDimBinding: Binding<Double> {
        Binding(
            get: { keyboardBacklight.idleDimSeconds },
            set: { keyboardBacklight.setIdleDimSeconds($0) }
        )
    }

    private var keyboardEffectBinding: Binding<KeyboardBacklightEffect> {
        Binding(
            get: { keyboardBacklight.effect },
            set: { keyboardBacklight.setEffect($0) }
        )
    }

    private var keyboardEffectSpeedBinding: Binding<KeyboardBacklightEffectSpeed> {
        Binding(
            get: { keyboardBacklight.effectSpeed },
            set: { keyboardBacklight.setEffectSpeed($0) }
        )
    }

    /// 与系统设置一致的选项；当前值若不在列表中也保留，避免选择框显示空白。
    private var keyboardIdleDimOptions: [Double] {
        let presets: [Double] = [5, 10, 30, 60, 300]
        let current = keyboardBacklight.idleDimSeconds
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private func idleDimText(_ seconds: Double) -> String {
        if seconds <= 0 { return "从不" }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds / 60)) 分钟"
        }
        return "\(Int(seconds)) 秒"
    }

    private var keepAwakeBinding: Binding<SleepSettingsController.KeepAwake> {
        Binding(
            get: { sleepSettings.keepAwake },
            set: { sleepSettings.setKeepAwake($0) }
        )
    }

    private var keepsDisplayAwakeBinding: Binding<Bool> {
        Binding(
            get: { sleepSettings.keepsDisplayAwake },
            set: { sleepSettings.setKeepsDisplayAwake($0) }
        )
    }

    private var sleepDisabledBinding: Binding<Bool> {
        Binding(
            get: { sleepSettings.isSleepDisabled ?? false },
            set: { sleepSettings.setSleepDisabled($0) }
        )
    }

    private func sleepMinutesBinding(_ keyPath: WritableKeyPath<SleepSettings, Int?>) -> Binding<Int> {
        Binding(
            get: { sleepSettings.draft?[keyPath: keyPath] ?? 0 },
            set: { minutes in sleepSettings.updateDraft { $0[keyPath: keyPath] = minutes } }
        )
    }

    private func sleepFlagBinding(_ keyPath: WritableKeyPath<SleepSettings, Bool?>) -> Binding<Bool> {
        Binding(
            get: { sleepSettings.draft?[keyPath: keyPath] ?? false },
            set: { isOn in sleepSettings.updateDraft { $0[keyPath: keyPath] = isOn } }
        )
    }

    /// 常用时长；系统当前值若不在列表中也保留，避免选择框显示空白。“从不”排在最后。
    private func sleepMinuteOptions(including current: Int?) -> [Int] {
        var options = [1, 2, 5, 10, 15, 30, 60, 180]
        if let current, current > 0, !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options + [0]
    }

    private func sleepMinutesText(_ minutes: Int) -> String {
        if minutes == 0 { return "从不" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    // MARK: - 格式

    private var primaryWattText: String {
        monitor.snapshot.displayedWatts.map {
            String(format: "%.*f", monitor.decimalPlaces, $0)
        } ?? "—"
    }

    private func formattedWatts(_ watts: Double) -> String {
        String(format: "%.*f W", monitor.decimalPlaces, watts)
    }

    private func batterySymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharging == true { return "battery.100percent.bolt" }
        switch battery.percentage ?? 0 {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryStatus(_ battery: BatterySnapshot) -> String {
        let percentage = battery.percentage.map { "\($0)%" } ?? "—"
        if battery.isCharging == true { return "\(percentage) · 充电中" }
        if battery.isOnACPower == true { return "\(percentage) · 已接电源" }
        return "\(percentage) · 使用电池"
    }

    private func batteryFlowText(_ battery: BatterySnapshot) -> String {
        guard let watts = battery.flowWatts else { return "—" }
        if abs(watts) < 0.05 { return "0.0 W" }
        return String(format: watts > 0 ? "+%.1f W" : "−%.1f W", abs(watts))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 功耗走势：一笔细墨线，不加渐变；末端一点，陡升时转为朱砂。
private struct PowerTrace: View {
    let values: [Double]
    let isSurging: Bool

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 3
            let width = size.width - inset * 2
            let height = size.height - inset * 2

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)

            guard values.count > 1, let maximum = values.max() else { return }
            let upperBound = max(maximum * 1.15, 1)
            let step = width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: inset + CGFloat(index) * step,
                    y: inset + height - CGFloat(value / upperBound) * height
                )
            }

            var line = Path()
            line.move(to: points[0])
            points.dropFirst().forEach { line.addLine(to: $0) }
            context.stroke(
                line,
                with: .color(.primary.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )

            if let end = points.last {
                let dot = Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5))
                context.fill(dot, with: .color(isSurging ? PanelTheme.cinnabar : .primary.opacity(0.7)))
            }
        }
        .accessibilityLabel(isSurging ? "功耗走势，正在陡升" : "功耗走势")
    }
}
