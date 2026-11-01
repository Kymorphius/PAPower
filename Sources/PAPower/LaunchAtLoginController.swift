import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    private static let didApplyDefaultKey = "launchAtLoginDefaultApplied"

    /// 首次启动时默认开启登录启动，只做一次；之后用户关掉就保持关闭。
    static func applyDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didApplyDefaultKey) else { return }
        defaults.set(true, forKey: didApplyDefaultKey)
        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
