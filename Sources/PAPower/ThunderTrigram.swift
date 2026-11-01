import AppKit
import SwiftUI

/// 震卦 ☳ 的几何：自上而下两条断开的阴爻、一条完整的阳爻，“一阳动于二阴之下”。
/// 菜单栏图标与面板页首共用，比例一致。坐标原点在左上。
struct TrigramMetrics {
    let width: CGFloat
    /// 爻的粗细。
    let bar: CGFloat
    /// 爻与爻之间的距离。
    let gap: CGFloat
    /// 阴爻中间断开的宽度。
    let split: CGFloat

    var height: CGFloat { bar * 3 + gap * 2 }
    var cornerRadius: CGFloat { bar * 0.25 }

    /// 菜单栏：宽 14pt（与原闪电图标同宽），爻粗 1.5pt 与旁边数字的笔画相当，总高 9.5pt 约等于数字高度。
    static let menuBar = TrigramMetrics(width: 14, bar: 1.5, gap: 2.5, split: 3.5)
    /// 面板页首，与菜单栏同比例放大。
    static let panel = TrigramMetrics(width: 18, bar: 2, gap: 3, split: 4.5)

    /// 两条阴爻的四段，自上而下、自左而右。
    func yinSegments(origin: CGPoint = .zero) -> [CGRect] {
        let segmentWidth = (width - split) / 2
        return (0..<2).flatMap { row -> [CGRect] in
            let y = origin.y + CGFloat(row) * (bar + gap)
            return [
                CGRect(x: origin.x, y: y, width: segmentWidth, height: bar),
                CGRect(x: origin.x + segmentWidth + split, y: y, width: segmentWidth, height: bar)
            ]
        }
    }

    func yangLine(origin: CGPoint = .zero) -> CGRect {
        CGRect(x: origin.x, y: origin.y + 2 * (bar + gap), width: width, height: bar)
    }
}

extension NSImage {
    /// 菜单栏用的震卦模板图：只用黑色与透明定义形状，由系统按菜单栏深浅与选中状态着色。
    /// alpha 小于 1 时整体变淡，用于暂时读不到功耗的状态。
    static func thunderTrigram(
        metrics: TrigramMetrics = .menuBar,
        canvas: NSSize = NSSize(width: 14, height: 14),
        alpha: CGFloat = 1
    ) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { rect in
            // 取到半点，各边在 2x 屏上落在整像素，避免发虚。
            let origin = CGPoint(
                x: ((rect.width - metrics.width) / 2 * 2).rounded() / 2,
                y: ((rect.height - metrics.height) / 2 * 2).rounded() / 2
            )
            NSColor.black.withAlphaComponent(alpha).setFill()
            for bar in metrics.yinSegments(origin: origin) + [metrics.yangLine(origin: origin)] {
                NSBezierPath(
                    roundedRect: bar,
                    xRadius: metrics.cornerRadius,
                    yRadius: metrics.cornerRadius
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 面板页首的震卦：平时三爻皆为墨色；有需要留意的状态时，底下的阳爻转为朱砂。
struct ThunderTrigram: View {
    var isStirred: Bool

    private let metrics = TrigramMetrics.panel

    var body: some View {
        let yin = metrics.yinSegments()
        ZStack(alignment: .topLeading) {
            ForEach(yin.indices, id: \.self) { index in
                bar(yin[index])
                    .foregroundStyle(.secondary)
            }
            bar(metrics.yangLine())
                .foregroundStyle(isStirred ? AnyShapeStyle(PanelTheme.cinnabar) : AnyShapeStyle(.secondary))
        }
        .frame(width: metrics.width, height: metrics.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func bar(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}
