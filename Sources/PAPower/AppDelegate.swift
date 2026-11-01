import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    /// 键盘动效在面板关闭后仍要运行，并在退出前写回用户亮度，因此由应用持有。
    private var keyboardBacklight: KeyboardBacklightController?
    /// 保持唤醒的电源断言要在面板关闭后继续生效，同样由应用持有。
    private var sleepSettings: SleepSettingsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = PanelSnapshot.outputPath {
            PanelSnapshot.run(
                to: path,
                monitor: PowerMonitor(),
                keyboardBacklight: KeyboardBacklightController(runsEffects: false),
                sleepSettings: SleepSettingsController()
            )
            return
        }

        LaunchAtLoginController.applyDefaultOnFirstLaunch()
        let keyboardBacklight = KeyboardBacklightController()
        self.keyboardBacklight = keyboardBacklight
        let sleepSettings = SleepSettingsController()
        self.sleepSettings = sleepSettings

        statusBarController = StatusBarController(
            monitor: PowerMonitor(),
            keyboardBacklight: keyboardBacklight,
            sleepSettings: sleepSettings
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardBacklight?.prepareForTermination()
    }
}

@MainActor
private final class StatusBarController: NSObject {
    /// 菜单栏图标：震卦模板图，读不到功耗时变淡。
    private static let trigram = NSImage.thunderTrigram()
    private static let dimmedTrigram = NSImage.thunderTrigram(alpha: 0.35)

    private let monitor: PowerMonitor
    private let keyboardBacklight: KeyboardBacklightController
    private let sleepSettings: SleepSettingsController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()

    init(
        monitor: PowerMonitor,
        keyboardBacklight: KeyboardBacklightController,
        sleepSettings: SleepSettingsController
    ) {
        self.monitor = monitor
        self.keyboardBacklight = keyboardBacklight
        self.sleepSettings = sleepSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configurePopover()
        configureButton()
        observeMonitor()
        updateButton()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                monitor: monitor,
                keyboardBacklight: keyboardBacklight,
                sleepSettings: sleepSettings
            )
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
    }

    private func observeMonitor() {
        Publishers.CombineLatest3(
            monitor.$snapshot,
            monitor.$decimalPlaces,
            monitor.$usesSpaciousLayout
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateButton()
            }
            .store(in: &subscriptions)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }

        button.image = monitor.hasReading ? Self.trigram : Self.dimmedTrigram
        button.attributedTitle = statusTitle(monitor.menuBarText)
        button.toolTip = monitor.accessibilitySummary
        button.setAccessibilityLabel(monitor.accessibilitySummary)
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func statusTitle(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
    }
}
