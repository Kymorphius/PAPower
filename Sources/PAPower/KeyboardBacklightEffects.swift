import Foundation

/// 键盘背光动效。内建背光是单区白光，动效只能是整体亮度随时间变化。
enum KeyboardBacklightEffect: String, CaseIterable, Identifiable {
    case off
    case breathe
    case heartbeat
    case blink
    case candle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .breathe: return "呼吸"
        case .heartbeat: return "心跳"
        case .blink: return "闪烁"
        case .candle: return "烛光"
        }
    }

    /// 一个循环的关键帧，按中速节奏给出；烛光每轮随机生成，避免看出重复。
    func cycle() -> [KeyboardBacklightKeyframe] {
        switch self {
        case .off:
            return []
        case .breathe:
            return [
                KeyboardBacklightKeyframe(level: 1, fade: 1.6, hold: 0.3),
                KeyboardBacklightKeyframe(level: 0, fade: 1.6, hold: 0.5)
            ]
        case .heartbeat:
            return [
                KeyboardBacklightKeyframe(level: 1, fade: 0.09, hold: 0.06),
                KeyboardBacklightKeyframe(level: 0.3, fade: 0.16, hold: 0),
                KeyboardBacklightKeyframe(level: 1, fade: 0.09, hold: 0.06),
                KeyboardBacklightKeyframe(level: 0, fade: 0.35, hold: 0.45)
            ]
        case .blink:
            return [
                KeyboardBacklightKeyframe(level: 1, fade: 0, hold: 0.5),
                KeyboardBacklightKeyframe(level: 0, fade: 0, hold: 0.5)
            ]
        case .candle:
            return (0..<6).map { _ in
                KeyboardBacklightKeyframe(
                    level: .random(in: 0.35...1),
                    fade: .random(in: 0.08...0.28),
                    hold: .random(in: 0...0.12)
                )
            }
        }
    }
}

enum KeyboardBacklightEffectSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow: return "慢"
        case .normal: return "中"
        case .fast: return "快"
        }
    }

    /// 关键帧时长的倍率，越小节奏越快。
    var durationScale: Double {
        switch self {
        case .slow: return 1.6
        case .normal: return 1
        case .fast: return 0.6
        }
    }
}

struct KeyboardBacklightKeyframe {
    /// 相对动效亮度（亮度滑块）的比例，0…1。
    let level: Double
    /// 渐变到 level 的时长，由系统完成渐变；0 表示直接跳变。
    let fade: TimeInterval
    /// 渐变结束后停留的时长。
    let hold: TimeInterval
}
