import AppKit
import SwiftUI

/// `--panel-snapshot <路径> [--appearance light|dark] [--open activity|keyboard|sleep|settings]`：
/// 采样几秒拿到真实数据后，把完整展开的面板渲染成 PNG 并退出，用于 README 截图与检查各个状态。
/// 不创建菜单栏项，键盘背光只读不写，不影响正在运行的 PAPower。
@MainActor
enum PanelSnapshot {
    static var outputPath: String? {
        argument(after: "--panel-snapshot")
    }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// 高活跃应用需要两次进程采样之间的间隔，温度与睡眠设置也是异步读取。
    private static let warmUp: UInt64 = 8_000_000_000

    static func run(
        to path: String,
        monitor: PowerMonitor,
        keyboardBacklight: KeyboardBacklightController,
        sleepSettings: SleepSettingsController
    ) {
        switch argument(after: "--appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        let view = MenuBarContentView(
            monitor: monitor,
            keyboardBacklight: keyboardBacklight,
            sleepSettings: sleepSettings,
            heightLimit: 10_000,
            initialSection: argument(after: "--open").flatMap(MenuBarContentView.Section.init(rawValue:))
        )
        .background(Color(nsColor: .windowBackgroundColor))

        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 10_000),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView

        Task {
            try? await Task.sleep(nanoseconds: warmUp)
            // 首次布局后内容高度经 preference 回传，再布局一次才得到最终尺寸。
            hostingView.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let size = hostingView.fittingSize
            window.setContentSize(size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()

            var status = EXIT_FAILURE
            if let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]),
                   (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                    print("已生成：\(path)（\(bitmap.pixelsWide)×\(bitmap.pixelsHigh)）")
                    status = EXIT_SUCCESS
                }
            }
            if status != EXIT_SUCCESS {
                FileHandle.standardError.write(Data("面板截图生成失败\n".utf8))
            }
            exit(status)
        }
    }
}
