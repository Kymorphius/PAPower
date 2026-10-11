import AppKit

enum TrafficStatusImage {
    static let size = NSSize(width: 89, height: 20)

    static func make(proxy: TrafficValues?, direct: TrafficValues?) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            drawRow(label: "代", values: proxy, y: 0)
            drawRow(label: "直", values: direct, y: 10)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawRow(label: String, values: TrafficValues?, y: CGFloat) {
        // Each row uses a 10-point line box. Independent columns keep arrows
        // anchored and values right aligned as their units and digit counts change.
        draw(label, x: 4, y: y, width: 10, alignment: .left)
        draw("↓", x: 18, y: y, width: 6, alignment: .center)
        draw(rate(values?.download), x: 26, y: y, width: 22, alignment: .right)
        draw("↑", x: 55, y: y, width: 6, alignment: .center)
        draw(rate(values?.upload), x: 63, y: y, width: 22, alignment: .right)
    }

    private static func rate(_ bytes: Double?) -> String {
        TrafficFormat.compactRate(bytes).trimmingCharacters(in: .whitespaces)
    }

    private static func draw(
        _ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        (text as NSString).draw(
            in: NSRect(x: x, y: y, width: width, height: 10),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
        )
    }
}
