import AppKit
import SwiftUI

struct TrafficMenuBarContentView: View {
    @ObservedObject var monitor: TrafficMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.system(size: 25))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("网络流量").font(.headline)
                    Text("local-manager · 实时采样")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(monitor.isRefreshing)
                .help("立即刷新流量")
            }

            if let diagnostic = monitor.diagnostic {
                Label(diagnostic, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !monitor.hasCurrentRates {
                Text("正在建立流量采样…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            trafficCard(
                title: "代理流量", symbol: "network", color: .blue,
                rate: monitor.hasCurrentRates ? monitor.snapshot.proxyRate : nil,
                total: monitor.snapshot.proxyTotal,
                connections: monitor.snapshot.proxyConnectionCount
            )
            trafficCard(
                title: "直连流量", symbol: "arrow.up.right", color: .green,
                rate: monitor.hasCurrentRates ? monitor.snapshot.directRate : nil,
                total: monitor.snapshot.directTotal,
                connections: monitor.snapshot.directConnectionCount
            )

            if hasUnclassifiedTraffic {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("未归类").font(.caption.weight(.medium))
                        Spacer()
                        Text("↓ \(TrafficFormat.rate(currentUnclassifiedRate?.download))  ↑ \(TrafficFormat.rate(currentUnclassifiedRate?.upload))")
                            .font(.caption.monospacedDigit())
                    }
                    Text("本次累计 ↓ \(TrafficFormat.quantity(monitor.snapshot.unclassifiedTotal.download))  ↑ \(TrafficFormat.quantity(monitor.snapshot.unclassifiedTotal.upload))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            highTrafficSources

            Divider()
            HStack {
                Text("累计自 \(monitor.snapshot.monitoringSince.formatted(date: .omitted, time: .shortened)) 起")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清零") { monitor.resetTotals() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Text("仅统计 local-manager 管理的连接。采样间隔内结束的短连接等无法归属的流量计入“未归类”；绕过它的流量不在此列。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开 local-manager") {
                    NSWorkspace.shared.open(URL(string: "http://127.0.0.1:6060")!)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("退出 PAPower") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 330)
    }

    private var currentUnclassifiedRate: TrafficValues? {
        monitor.hasCurrentRates ? monitor.snapshot.unclassifiedRate : nil
    }

    private var highTrafficSources: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("高流量来源")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("实时 · 前 5 项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !monitor.hasCurrentRates {
                Text(monitor.diagnostic == nil ? "等待下一次采样…" : "流量接口恢复后更新排行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if monitor.snapshot.topSources.isEmpty {
                Text("当前没有可归属的活动流量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    Text("↓ 下载").frame(width: 65, alignment: .trailing)
                    Text("↑ 上传").frame(width: 65, alignment: .trailing)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(monitor.snapshot.topSources.prefix(5)) { source in
                            trafficSourceRow(source)
                        }
                    }
                }
                .frame(height: min(110, CGFloat(min(5, monitor.snapshot.topSources.count)) * 39 - 7))
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .help("按当前下载与上传速度的合计排序；应用无法识别时显示目标域名或 IP。仅包含采样中能归属的活动连接。")
    }

    private func trafficSourceRow(_ source: TrafficSourceActivity) -> some View {
        HStack(spacing: 8) {
            Group {
                if let path = source.applicationPath {
                    Image(nsImage: TrafficSourceIconCache.shared.icon(for: path))
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: source.kind == .process ? "terminal.fill" : "network")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(source.routeDescription) · \(source.connectionCount) 个连接")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TrafficFormat.rate(source.rate.download))
                .frame(width: 65, alignment: .trailing)
            Text(TrafficFormat.rate(source.rate.upload))
                .frame(width: 65, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .frame(height: 32)
        .help("\(source.kindDescription)：\(source.detail)")
        .accessibilityElement(children: .combine)
    }

    private var hasUnclassifiedTraffic: Bool {
        let total = monitor.snapshot.unclassifiedTotal
        let rate = currentUnclassifiedRate
        return total.upload > 0 || total.download > 0
            || (rate?.upload ?? 0) > 0 || (rate?.download ?? 0) > 0
            || monitor.snapshot.unclassifiedConnectionCount > 0
    }

    private func trafficCard(
        title: String, symbol: String, color: Color,
        rate: TrafficValues?, total: TrafficValues, connections: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
                Spacer()
                Text(monitor.diagnostic == nil ? "\(connections) 个连接" : "连接数 —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                directionMetric("下载", symbol: "arrow.down", rate: rate?.download, total: total.download)
                directionMetric("上传", symbol: "arrow.up", rate: rate?.upload, total: total.upload)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.065))
        }
    }

    private func directionMetric(_ title: String, symbol: String, rate: Double?, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TrafficFormat.rate(rate))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("累计 \(TrafficFormat.quantity(total))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class TrafficSourceIconCache {
    static let shared = TrafficSourceIconCache()
    private var icons: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if icons.count >= 64 { icons.removeAll(keepingCapacity: true) }
        icons[path] = icon
        return icon
    }
}
