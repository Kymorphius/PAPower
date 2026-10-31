import AppKit
import Darwin
import Foundation
import IOKit

/// 封装 CoreBrightness 私有框架中的 KeyboardBrightnessClient（与控制中心键盘亮度滑块同源）。
/// 私有 API 不保证跨系统版本稳定，因此全部通过运行时查找，缺失时整体视为不可用。
final class KeyboardBrightnessClient {
    struct State {
        /// 当前生效亮度，0…1；背光关闭或闲置熄灭时为 0。
        let brightness: Double
        let isAutoBrightnessEnabled: Bool
        /// 背光已关闭：亮度被调到 0（含亮度键关到底）或闲置熄灭时由系统置位。
        let isSuppressed: Bool
        let idleDimSeconds: Double
    }

    private typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias GetDouble = @convention(c) (AnyObject, Selector, UInt64) -> Double
    private typealias GetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias SetFade = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
    private typealias SetDouble = @convention(c) (AnyObject, Selector, Double, UInt64) -> Bool
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private static let fadeSelector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
    private static let suspendIdleSelector = NSSelectorFromString("suspendIdleDimming:forKeyboard:")

    private let client: NSObject
    private let keyboardID: UInt64

    init?() {
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            return nil
        }
        let client = type.init()
        let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard client.responds(to: idsSelector),
              let ids = client.perform(idsSelector)?.takeRetainedValue() as? [NSNumber],
              !ids.isEmpty else {
            return nil
        }
        self.client = client
        // 优先内建键盘；外接的妙控键盘没有背光，一般不会出现在列表里。
        let builtIn = ids.first { Self.callBool(client, "isKeyboardBuiltIn:", $0.uint64Value) == true }
        keyboardID = (builtIn ?? ids[0]).uint64Value
    }

    /// 动效依赖系统渐变与暂停闲置熄灭两个接口。
    var supportsEffects: Bool {
        client.responds(to: Self.fadeSelector) && client.responds(to: Self.suspendIdleSelector)
    }

    func readState() -> State? {
        guard let brightness = getFloat("brightnessForKeyboard:"),
              let isAuto = getBool("isAutoBrightnessEnabledForKeyboard:") else {
            return nil
        }
        return State(
            brightness: Double(min(max(brightness, 0), 1)),
            isAutoBrightnessEnabled: isAuto,
            isSuppressed: getBool("isBacklightSuppressedOnKeyboard:") ?? false,
            idleDimSeconds: getDouble("idleDimTimeForKeyboard:") ?? 0
        )
    }

    @discardableResult
    func setBrightness(_ value: Double) -> Bool {
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let imp = implementation(selector) else { return false }
        let clamped = Float(min(max(value, 0), 1))
        return unsafeBitCast(imp, to: SetFloat.self)(client, selector, clamped, keyboardID)
    }

    /// 动效用：由系统在 duration 内平滑渐变到目标亮度，不提交为用户设定。
    /// 每个关键帧只调用一次，系统服务几乎不增加 CPU 占用（逐帧写入约贵 20 倍）。
    @discardableResult
    func fade(to value: Double, over duration: TimeInterval) -> Bool {
        guard let imp = implementation(Self.fadeSelector) else { return false }
        let clamped = Float(min(max(value, 0), 1))
        let milliseconds = Int32((max(duration, 0) * 1000).rounded())
        return unsafeBitCast(imp, to: SetFade.self)(
            client, Self.fadeSelector, clamped, milliseconds, false, keyboardID
        )
    }

    /// 暂停闲置熄灭，让动效在不碰键盘时也持续显示。
    @discardableResult
    func setIdleDimmingSuspended(_ suspended: Bool) -> Bool {
        guard let imp = implementation(Self.suspendIdleSelector) else { return false }
        return unsafeBitCast(imp, to: SetBool.self)(
            client, Self.suspendIdleSelector, suspended, keyboardID
        )
    }

    @discardableResult
    func setAutoBrightnessEnabled(_ enabled: Bool) -> Bool {
        let selector = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        guard let imp = implementation(selector) else { return false }
        return unsafeBitCast(imp, to: SetBool.self)(client, selector, enabled, keyboardID)
    }

    @discardableResult
    func setIdleDimSeconds(_ seconds: Double) -> Bool {
        let selector = NSSelectorFromString("setIdleDimTime:forKeyboard:")
        guard let imp = implementation(selector) else { return false }
        return unsafeBitCast(imp, to: SetDouble.self)(client, selector, seconds, keyboardID)
    }

    private func implementation(_ selector: Selector) -> IMP? {
        client.responds(to: selector) ? client.method(for: selector) : nil
    }

    private func getFloat(_ name: String) -> Float? {
        let selector = NSSelectorFromString(name)
        return implementation(selector).map {
            unsafeBitCast($0, to: GetFloat.self)(client, selector, keyboardID)
        }
    }

    private func getDouble(_ name: String) -> Double? {
        let selector = NSSelectorFromString(name)
        return implementation(selector).map {
            unsafeBitCast($0, to: GetDouble.self)(client, selector, keyboardID)
        }
    }

    private func getBool(_ name: String) -> Bool? {
        Self.callBool(client, name, keyboardID)
    }

    private static func callBool(_ client: NSObject, _ name: String, _ id: UInt64) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard client.responds(to: selector) else { return nil }
        return unsafeBitCast(client.method(for: selector), to: GetBool.self)(client, selector, id)
    }
}

/// 面板中的键盘背光控制：亮度、低光照自动调节、闲置熄灭时间与动效，均作用于系统设置。
@MainActor
final class KeyboardBacklightController: ObservableObject {
    private enum DefaultsKey {
        static let effect = "keyboardBacklightEffect"
        static let effectSpeed = "keyboardBacklightEffectSpeed"
        /// 最近一次背光亮着时的亮度；闲置熄灭时读数为 0，靠它找回用户亮度。
        static let lastLitBrightness = "keyboardBacklightLastLitBrightness"
        /// 动效运行期间要写回的用户亮度；启动时仍存在，说明上次没有正常收尾（崩溃或被强制结束）。
        static let pendingRestore = "keyboardBacklightPendingRestore"
    }

    /// 动效暂停的原因；任一存在时不再写入亮度。
    private enum PauseReason {
        case screensAsleep
        case systemAsleep
        case sessionInactive
    }

    @Published private(set) var isAvailable = false
    @Published private(set) var supportsEffects = false
    @Published private(set) var brightness: Double = 0
    @Published private(set) var isAutoBrightnessEnabled = false
    @Published private(set) var isSuppressed = false
    @Published private(set) var idleDimSeconds: Double = 0
    @Published private(set) var effect: KeyboardBacklightEffect
    @Published private(set) var effectSpeed: KeyboardBacklightEffectSpeed

    private let client = KeyboardBrightnessClient()
    private let rootDomain: io_registry_entry_t
    private var isWaking = false
    private var pendingBrightness: Double?

    private var effectTask: Task<Void, Never>?
    /// 动效的最亮程度，也是动效结束后写回的用户亮度；动效未运行时为 nil。
    private var effectBrightness: Double?
    private var pauseReasons: Set<PauseReason> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        effect = defaults.string(forKey: DefaultsKey.effect)
            .flatMap(KeyboardBacklightEffect.init(rawValue:)) ?? .off
        effectSpeed = defaults.string(forKey: DefaultsKey.effectSpeed)
            .flatMap(KeyboardBacklightEffectSpeed.init(rawValue:)) ?? .normal
        rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        supportsEffects = client?.supportsEffects ?? false
        // 上次动效没有正常收尾时，沿用当时记下的用户亮度，而不是读取停在某一帧的当前值。
        effectBrightness = defaults.object(forKey: DefaultsKey.pendingRestore) as? Double

        refresh()
        observeSystemState()

        if effect != .off, supportsEffects {
            startEffect()
        } else if effectBrightness != nil {
            stopEffect()
        }
    }

    deinit {
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
        }
    }

    func refresh() {
        guard let state = client?.readState() else {
            isAvailable = false
            return
        }
        isAvailable = true
        isAutoBrightnessEnabled = state.isAutoBrightnessEnabled
        idleDimSeconds = state.idleDimSeconds

        // 动效运行时读数只是动画中的某一帧，面板显示动效亮度。
        if let effectBrightness {
            brightness = effectBrightness
            return
        }
        brightness = state.brightness
        isSuppressed = state.isSuppressed
        if state.brightness > 0 {
            rememberLitBrightness(state.brightness)
        }
    }

    func setBrightness(_ value: Double) {
        guard let client else { return }
        brightness = value
        if effectBrightness != nil {
            // 动效运行中：滑块调的是动效最亮程度，下一帧生效，结束后也写回这个亮度。
            setEffectBrightness(value)
            return
        }
        if value > 0 {
            rememberLitBrightness(value)
        }
        if isWaking {
            pendingBrightness = value
            return
        }
        if value > 0, isSuppressed, isAutoBrightnessEnabled {
            wakeBacklight(client, to: value)
            return
        }
        client.setBrightness(value)
        isSuppressed = value == 0
    }

    func setAutoBrightnessEnabled(_ enabled: Bool) {
        client?.setAutoBrightnessEnabled(enabled)
        refresh()
    }

    func setIdleDimSeconds(_ seconds: Double) {
        client?.setIdleDimSeconds(seconds)
        refresh()
    }

    func setEffect(_ newEffect: KeyboardBacklightEffect) {
        guard newEffect != effect else { return }
        effect = newEffect
        UserDefaults.standard.set(newEffect.rawValue, forKey: DefaultsKey.effect)
        if newEffect == .off {
            stopEffect()
        } else {
            startEffect()
        }
    }

    /// 节奏从下一帧开始生效。
    func setEffectSpeed(_ speed: KeyboardBacklightEffectSpeed) {
        effectSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: DefaultsKey.effectSpeed)
    }

    /// 退出前写回用户亮度并恢复闲置熄灭；动效设置保留，下次启动继续。
    func prepareForTermination() {
        stopEffect()
        // 唤醒流程会先关闭自动调节；退出时等不到异步收尾，就地等待并恢复，免得自动调节被留在关闭状态。
        if isWaking, let client {
            Thread.sleep(forTimeInterval: 0.5)
            finishWaking(client, fallback: brightness)
        }
    }

    /// 开着自动调节时，单独设亮度清不掉“背光已关闭”标记。需先关闭自动调节设亮度，
    /// 等系统生效（实测 0.2 秒不够）后再恢复自动调节，并重设一次亮度作为自动调节的基准。
    private func wakeBacklight(_ client: KeyboardBrightnessClient, to value: Double) {
        isWaking = true
        client.setAutoBrightnessEnabled(false)
        client.setBrightness(value)

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            finishWaking(client, fallback: value)
        }
    }

    private func finishWaking(_ client: KeyboardBrightnessClient, fallback value: Double) {
        guard isWaking else { return }
        client.setAutoBrightnessEnabled(true)
        let target = pendingBrightness ?? value
        pendingBrightness = nil
        client.setBrightness(target)
        isSuppressed = target == 0
        isWaking = false
    }

    // MARK: - 动效

    private func startEffect() {
        guard supportsEffects else { return }
        if effectBrightness == nil {
            setEffectBrightness(capturedUserBrightness())
        }
        brightness = effectBrightness ?? 0
        restartEffectLoop()
    }

    /// 停止动效：写回用户亮度，再恢复闲置熄灭。
    private func stopEffect() {
        effectTask?.cancel()
        effectTask = nil
        guard let restore = effectBrightness else { return }
        effectBrightness = nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingRestore)
        brightness = restore
        restoreUserBrightness(restore)
        client?.setIdleDimmingSuspended(false)
    }

    private func restartEffectLoop() {
        effectTask?.cancel()
        effectTask = nil
        guard effectBrightness != nil, pauseReasons.isEmpty, let client else { return }
        client.setIdleDimmingSuspended(true)
        effectTask = Task { [weak self] in
            await self?.runEffectLoop(client)
        }
    }

    /// 暂停时只停止写入，不写回亮度：屏幕休眠时写入可能把键盘重新点亮。
    private func pauseEffectLoop() {
        effectTask?.cancel()
        effectTask = nil
        client?.setIdleDimmingSuspended(false)
    }

    private func runEffectLoop(_ client: KeyboardBrightnessClient) async {
        while !Task.isCancelled {
            if isLidClosed {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let frames = effect.cycle()
            guard !frames.isEmpty else { return }
            for frame in frames {
                guard !Task.isCancelled else { return }
                let scale = effectSpeed.durationScale
                client.fade(to: frame.level * (effectBrightness ?? 0), over: frame.fade * scale)
                let seconds = (frame.fade + frame.hold) * scale
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func setEffectBrightness(_ value: Double) {
        effectBrightness = value
        UserDefaults.standard.set(value, forKey: DefaultsKey.pendingRestore)
    }

    /// 背光亮着时读数就是用户亮度；读到 0 时分不清是闲置熄灭、手动关闭还是环境光压暗，
    /// 改用最近一次亮着时的亮度。动效结束时不会因此写回 0，免得开着自动调节时背光一直不亮。
    private func capturedUserBrightness() -> Double {
        if let state = client?.readState(), state.brightness > 0 {
            rememberLitBrightness(state.brightness)
            return state.brightness
        }
        let saved = UserDefaults.standard.double(forKey: DefaultsKey.lastLitBrightness)
        return saved > 0 ? saved : 0.5
    }

    private func rememberLitBrightness(_ value: Double) {
        UserDefaults.standard.set(value, forKey: DefaultsKey.lastLitBrightness)
    }

    /// 动效最后一帧可能停在 0；写回后背光仍未亮起（开着自动调节时会出现），按唤醒流程重新点亮。
    private func restoreUserBrightness(_ value: Double) {
        guard let client else { return }
        client.setBrightness(value)
        if value > 0, isAutoBrightnessEnabled, client.readState()?.brightness == 0 {
            wakeBacklight(client, to: value)
        } else {
            isSuppressed = value == 0
        }
    }

    /// 合盖（接外接显示器时不会睡眠）时键盘不可见，动效停止写入。
    private var isLidClosed: Bool {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(
                  rootDomain,
                  "AppleClamshellState" as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue() else {
            return false
        }
        return (value as? Bool) ?? false
    }

    private func observeSystemState() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions: [(Notification.Name, PauseReason, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (NSWorkspace.willSleepNotification, .systemAsleep, true),
            (NSWorkspace.didWakeNotification, .systemAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)
        ]
        for (name, reason, isPaused) in transitions {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setPaused(isPaused, for: reason)
                }
            }
            observers.append(observer)
        }
    }

    private func setPaused(_ isPaused: Bool, for reason: PauseReason) {
        if isPaused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        guard effectBrightness != nil else { return }
        if pauseReasons.isEmpty {
            if effectTask == nil {
                restartEffectLoop()
            }
        } else if effectTask != nil {
            pauseEffectLoop()
        }
    }
}
