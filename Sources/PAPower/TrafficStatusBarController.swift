import AppKit
import Combine
import SwiftUI

@MainActor
final class TrafficStatusBarController: NSObject {
    private let monitor: TrafficMonitor
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()

    init(monitor: TrafficMonitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: 112)
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: TrafficMenuBarContentView(monitor: monitor)
        )
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.alignment = .center
            button.cell?.wraps = true
        }
        Publishers.CombineLatest(monitor.$snapshot, monitor.$diagnostic)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateButton() }
            .store(in: &subscriptions)
        updateButton()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let proxy = monitor.hasCurrentRates ? monitor.snapshot.proxyRate : nil
        let direct = monitor.hasCurrentRates ? monitor.snapshot.directRate : nil
        let text = "代 ↓\(TrafficFormat.compactRate(proxy?.download)) ↑\(TrafficFormat.compactRate(proxy?.upload))\n直 ↓\(TrafficFormat.compactRate(direct?.download)) ↑\(TrafficFormat.compactRate(direct?.upload))"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 0
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
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
}
