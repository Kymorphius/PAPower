import Darwin
import SwiftUI

@main
struct PAPowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--activity-probe") {
            ProbeReporter.printActivityAndExit()
        }

        if CommandLine.arguments.contains("--probe") {
            ProbeReporter.printSnapshotAndExit()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
