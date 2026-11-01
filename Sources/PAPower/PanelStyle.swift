import AppKit
import SwiftUI

/// 面板的视觉基调，取“寂然不动，感而遂通”：平时只有墨色；朱砂（符箓之色）只在“感”时出现，
/// 即需要留意或正在生效的状态，且总在出事的地方就地出现，不另设提醒区。
enum PanelTheme {
    /// 朱砂。浅色 #B3361F（对白 6.1:1），深色 #F2735A（对 #1E1E1E 5.9:1），增强对比度时再加深／提亮。
    static let cinnabar = dynamic(light: 0xB3361F, dark: 0xF2735A, lightHighContrast: 0x8E2412, darkHighContrast: 0xFF8E78)

    /// 墨：控件的强调色（开关、滑块、主按钮），替代系统强调色，让平时的面板保持单色。
    static let ink = dynamic(light: 0x48484A, dark: 0x8E8E93, lightHighContrast: 0x1C1C1E, darkHighContrast: 0xC7C7CC)

    /// 宋体只用于题记与状态字，正文和控件仍用系统字体。
    static func song(_ size: CGFloat) -> Font {
        .custom("Songti SC", size: size, relativeTo: .body)
    }

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightHighContrast: UInt32,
        darkHighContrast: UInt32
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua
            ])
            switch match {
            case .darkAqua?: return NSColor(hex: dark)
            case .accessibilityHighContrastAqua?: return NSColor(hex: lightHighContrast)
            case .accessibilityHighContrastDarkAqua?: return NSColor(hex: darkHighContrast)
            default: return NSColor(hex: light)
            }
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 可展开的一行：平时只露出标题与一句摘要，点按后在原处展开细节。
/// 展开三角在行首，收起时指向右、展开时向下，与 Finder 等系统列表一致。
struct PanelDisclosure<Content: View>: View {
    let title: String
    let summary: String
    var isStirred = false
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(summary)
                        .foregroundStyle(isStirred ? AnyShapeStyle(PanelTheme.cinnabar) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 6)
                .frame(height: 30)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
            .accessibilityValue("\(summary)，\(isExpanded ? "已展开" : "已收起")")

            if isExpanded {
                content()
                    .padding(.leading, 22)
                    .padding(.trailing, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, -6)
    }
}

/// 一行开关：墨色复选框在前、标题在后，点按标题也可切换。
/// 自绘而不用系统开关：菜单栏应用的弹窗常处于非激活状态，系统开关会褪成灰色，开与关只剩滑块位置可辨，
/// 且不跟随墨色。复选框有勾选形状，任何状态下都一目了然；尺寸与行为与系统复选框一致。
struct QuietCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(InkCheckboxStyle())
    }
}

struct InkCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        InkCheckbox(configuration: configuration)
    }
}

private struct InkCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(PanelTheme.ink) : AnyShapeStyle(Color.clear))
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(
                            configuration.isOn ? AnyShapeStyle(PanelTheme.ink) : AnyShapeStyle(.secondary),
                            lineWidth: 1
                        )
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    }
                }
                .frame(width: 14, height: 14)

                configuration.label
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
        }
    }
}

/// 一行选择：标题在左，当前值在右；点按当前值弹出选项菜单（无边框的弹出按钮）。
struct QuietMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(label(option)).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(label(selection))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(label(selection))
        }
    }
}
