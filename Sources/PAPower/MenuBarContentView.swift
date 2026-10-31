import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var monitor: PowerMonitor
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var updateChecker = GitHubUpdateChecker()
    @StateObject private var spotlightIndexing = SpotlightIndexingController()
    @ObservedObject var keyboardBacklight: KeyboardBacklightController

    /// 内容实际高度；超过屏幕可用高度时改为滚动显示。
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 13) {
                header
                powerCard
                historyCard
                activitySection
                batterySection
                keyboardBacklightSection
                Divider()
                controls
                accuracyNote
            }
            .padding(14)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(width: 330, height: min(contentHeight ?? maxPanelHeight, maxPanelHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .onAppear {
            launchAtLogin.refresh()
            spotlightIndexing.refresh()
            keyboardBacklight.refresh()
        }
    }

    /// 弹窗最多占用屏幕可用高度，扣除菜单栏下方的箭头与边距。
    private var maxPanelHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(visibleHeight - 40, 320)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 25))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("PAPower")
                    .font(.headline)
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("立即刷新")
        }
    }

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前整机功耗")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(primaryWattText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("W")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                temperatureMetric(
                    title: "CPU",
                    value: monitor.snapshot.temperatures.cpuCelsius,
                    warning: 90,
                    critical: 105
                )
                temperatureMetric(
                    title: "GPU",
                    value: monitor.snapshot.temperatures.gpuCelsius,
                    warning: 90,
                    critical: 105
                )
                temperatureMetric(
                    title: "SSD",
                    value: monitor.snapshot.temperatures.storageCelsius,
                    warning: 60,
                    critical: 75
                )
                temperatureMetric(
                    title: "电池",
                    value: monitor.snapshot.battery?.temperatureCelsius,
                    warning: 40,
                    critical: 45
                )
            }
            .padding(.vertical, 2)
            .help("CPU、GPU 与 SSD 显示当前可识别温区中的最高值；不同芯片提供的温区可能不同。")

            HStack(spacing: 18) {
                compactMetric(title: "均值", value: formattedWatts(monitor.averageWatts))
                compactMetric(title: "峰值", value: formattedWatts(monitor.peakWatts))
                Spacer()
                Text(monitor.snapshot.sampledAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("功耗趋势")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(monitor.historyDurationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            PowerSparkline(values: monitor.history.map(\.watts))
                .frame(height: 54)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("高活跃应用")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("按 CPU 估算")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if monitor.activeApps.isEmpty {
                Text("正在采样…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(monitor.activeApps.prefix(4)) { activity in
                    activityRow(activity)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .help("macOS 不提供可靠的逐应用瓦数；此列表按最近约一分钟的 CPU 活跃度估算并排序。")
    }

    private func activityRow(_ activity: ActiveApp) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = activity.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: activity.isSystemService ? "gearshape.2.fill" : "app.fill")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(activity.name)
                    .font(.caption)
                    .lineLimit(1)
                if activity.processCount > 1 {
                    Text("\(activity.processCount) 个相关进程")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            Text(String(format: "%.0f%%", activity.cpuPercent))
                .font(.caption.monospacedDigit())
                .foregroundStyle(activity.cpuPercent >= 25 ? .orange : .secondary)
        }
        .frame(height: activity.processCount > 1 ? 27 : 22)
    }

    @ViewBuilder
    private var batterySection: some View {
        if let battery = monitor.snapshot.battery {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("电池", systemImage: batterySymbol(battery))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(batteryStatus(battery))
                        .font(.subheadline.monospacedDigit())
                }

                HStack(spacing: 0) {
                    detailMetric(
                        title: "电池功率",
                        value: batteryFlowText(battery),
                        width: 102
                    )
                    detailMetric(
                        title: "电压",
                        value: battery.voltageVolts.map { String(format: "%.2f V", $0) } ?? "—",
                        width: 92
                    )
                    detailMetric(
                        title: "电流",
                        value: battery.currentAmps.map { String(format: "%+.2f A", $0) } ?? "—",
                        width: 102
                    )
                }

            }
        }
    }

    @ViewBuilder
    private var keyboardBacklightSection: some View {
        if keyboardBacklight.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("键盘背光", systemImage: "light.max")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.0f%%", keyboardBacklight.brightness * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "light.min")
                        .foregroundStyle(.secondary)
                    Slider(value: keyboardBrightnessBinding, in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("键盘亮度")
                    Image(systemName: "light.max")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if keyboardBacklight.supportsEffects {
                    HStack {
                        Text("动效")
                        Spacer()
                        if keyboardBacklight.effect != .off {
                            Picker("节奏", selection: keyboardEffectSpeedBinding) {
                                ForEach(KeyboardBacklightEffectSpeed.allCases) { speed in
                                    Text(speed.title).tag(speed)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 96)
                        }
                        Picker("动效", selection: keyboardEffectBinding) {
                            ForEach(KeyboardBacklightEffect.allCases) { effect in
                                Text(effect.title).tag(effect)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 86)
                    }
                    .font(.caption)
                    .help("亮度滑块决定动效最亮的程度。动效运行时暂停闲置熄灭，屏幕休眠、系统睡眠或合盖时自动暂停，关闭动效后恢复原亮度。")
                }

                Toggle("低光照下自动调节", isOn: keyboardAutoBrightnessBinding)
                    .font(.caption)
                    .help("开启后背光随环境光自动调亮或调暗，滑块设定的是基准亮度。")

                HStack {
                    Text("闲置后关闭背光")
                    Spacer()
                    Picker("闲置后关闭背光", selection: keyboardIdleDimBinding) {
                        ForEach(keyboardIdleDimOptions, id: \.self) { seconds in
                            Text(idleDimText(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 86)
                }
                .font(.caption)
            }
            .help("与系统设置中的键盘亮度同步；背光越亮耗电越高。")
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack {
                Text("菜单栏布局")
                Spacer()
                Picker("菜单栏布局", selection: spaciousLayoutBinding) {
                    Text("紧凑").tag(false)
                    Text("宽松").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
            }

            HStack {
                Text("小数位数")
                Spacer()
                Picker("小数位数", selection: decimalPlacesBinding) {
                    Text("1 位").tag(1)
                    Text("2 位").tag(2)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
            }

            HStack {
                Text("刷新频率")
                Spacer()
                Picker("刷新频率", selection: refreshIntervalBinding) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
            }

            Toggle("登录时自动启动", isOn: launchAtLoginBinding)

            spotlightControl

            updateControl

            if let error = launchAtLogin.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("版本 \(updateChecker.currentVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("退出 PAPower") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var spotlightControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Spotlight 索引", isOn: spotlightIndexingBinding)
                    .disabled(spotlightIndexing.isEnabled == nil || spotlightIndexing.isBusy)
                if spotlightIndexing.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .help("关闭后 Spotlight 不再为文件建立索引，可减少 mds_stores 的后台耗电；⌘空格、Finder 与邮件搜索会受影响。切换需要管理员密码。")

            if let error = spotlightIndexing.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        HStack {
            switch updateChecker.status {
            case .idle:
                Button("检查 GitHub 更新") {
                    updateChecker.check()
                }
                .buttonStyle(.plain)

            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("正在检查更新…")
                    .foregroundStyle(.secondary)

            case .upToDate:
                Label("已是最新版本", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("再次检查") {
                    updateChecker.check()
                }
                .buttonStyle(.plain)

            case let .updateAvailable(version, url):
                Label("发现 v\(version)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Spacer()
                Button("前往下载") {
                    updateChecker.openRelease(url)
                }
                .buttonStyle(.plain)

            case .failed:
                Text("检查失败")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("打开 GitHub") {
                    updateChecker.openRepository()
                }
                .buttonStyle(.plain)
                Button("重试") {
                    updateChecker.check()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var accuracyNote: some View {
        Text("菜单栏优先显示 PSTR 总板级功耗；它不包含电源适配器的转换损耗，因此不是插座侧电表读数。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

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

    /// 与系统设置一致的选项；当前值若不在列表中也保留，避免 Picker 显示空白。
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

    private var primaryWattText: String {
        monitor.snapshot.displayedWatts.map {
            String(format: "%.*f", monitor.decimalPlaces, $0)
        } ?? "—"
    }

    private var sourceDescription: String {
        switch monitor.snapshot.source {
        case .smcTotal:
            return "AppleSMC 实时板级功耗"
        case .batteryEstimate:
            return "电池端估算值"
        case .unavailable:
            return monitor.snapshot.diagnostic ?? "等待功耗数据"
        }
    }

    private func compactMetric(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private func temperatureMetric(
        title: String,
        value: Double?,
        warning: Double,
        critical: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f°", $0) } ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(temperatureColor(value, warning: warning, critical: critical))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            value.map { "\(title) 温度 \(Int($0.rounded())) 摄氏度" }
                ?? "\(title) 温度不可用"
        )
    }

    private func temperatureColor(
        _ value: Double?,
        warning: Double,
        critical: Double
    ) -> Color {
        guard let value else { return .secondary }
        if value >= critical { return .red }
        if value >= warning { return .orange }
        return .primary
    }

    private func detailMetric(title: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(width: width, alignment: .leading)
    }

    private func formattedWatts(_ watts: Double?) -> String {
        watts.map { String(format: "%.*f W", monitor.decimalPlaces, $0) } ?? "—"
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

private struct PowerSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1,
                  let observedMaximum = values.max() else {
                drawBaseline(context: &context, size: size)
                return
            }

            let upperBound = max(observedMaximum * 1.12, 1)
            let stepX = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height - CGFloat(value / upperBound) * size.height
                )
            }

            var fillPath = Path()
            fillPath.move(to: CGPoint(x: points[0].x, y: size.height))
            points.forEach { fillPath.addLine(to: $0) }
            fillPath.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            fillPath.closeSubpath()
            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [.accentColor.opacity(0.25), .accentColor.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var linePath = Path()
            linePath.move(to: points[0])
            points.dropFirst().forEach { linePath.addLine(to: $0) }
            context.stroke(
                linePath,
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityLabel("功耗历史趋势")
    }

    private func drawBaseline(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height - 1))
        path.addLine(to: CGPoint(x: size.width, y: size.height - 1))
        context.stroke(path, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
    }
}
