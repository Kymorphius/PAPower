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
