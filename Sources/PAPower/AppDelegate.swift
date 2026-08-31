import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(monitor: PowerMonitor())
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private static let symbolWidth: CGFloat = 14

    private let monitor: PowerMonitor
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()

    init(monitor: PowerMonitor) {
        self.monitor = monitor
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
            rootView: MenuBarContentView(monitor: monitor)
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

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .semibold
        )
        let image = NSImage(
            systemSymbolName: monitor.menuBarSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfiguration)
        image?.isTemplate = true
        image?.size = NSSize(width: Self.symbolWidth, height: Self.symbolWidth)

        button.image = image
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
