import SwiftUI
import AppKit
import AuraCore

// MARK: - 主题定义

/// 单一外观（浅色或深色）下的完整配色，hex 字符串便于集中调色
struct ThemeScheme {
    let bg: String
    let surface: String
    let surfaceAlt: String
    let accent: String
    let accentDeep: String
    let accentSoft: String
    let ink: String
    let muted: String
    let hairline: String
    let positive: String
    let warning: String
    let danger: String
    let heroTop: String
    let heroBottom: String
    let softTop: String
    let softBottom: String
    let heroShadow: String
}

/// 一个完整主题：浅色 + 深色两套方案
struct AppTheme {
    let id: AppThemeID
    let light: ThemeScheme
    let dark: ThemeScheme
    /// 主题预览色板（设置页的色卡）
    let swatch: [String]
}

enum ThemeRegistry {
    static let all: [AppThemeID: AppTheme] = [
        .pink: AppTheme(id: .pink,
            light: ThemeScheme(
                bg: "#FFF8FA", surface: "#FFFFFF", surfaceAlt: "#FFF0F5",
                accent: "#FF4F87", accentDeep: "#E23D77", accentSoft: "#FFD9E5",
                ink: "#2A1720", muted: "#8E7580", hairline: "#F3DEE7",
                positive: "#2FA37A", warning: "#D98200", danger: "#D62B47",
                heroTop: "#FF7FA8", heroBottom: "#E23D77",
                softTop: "#FFE3EC", softBottom: "#FFF8FA",
                heroShadow: "#E23D77"
            ),
            dark: ThemeScheme(
                bg: "#151013", surface: "#201A1E", surfaceAlt: "#271E23",
                accent: "#FF6E9C", accentDeep: "#D93A72", accentSoft: "#4A2A37",
                ink: "#F7EAF0", muted: "#A78F9B", hairline: "#33262C",
                positive: "#4BC08A", warning: "#FFB020", danger: "#FF6B7F",
                heroTop: "#B93A63", heroBottom: "#7A2545",
                softTop: "#291C22", softBottom: "#1B1418",
                heroShadow: "#7A2545"
            ),
            swatch: ["#FF4F87", "#FFD9E5", "#FFF0F5"]
        ),
        .lightPink: AppTheme(id: .lightPink,
            light: ThemeScheme(
                bg: "#FFFBFC", surface: "#FFFFFF", surfaceAlt: "#FFF5F7",
                accent: "#FF8FAB", accentDeep: "#E96F92", accentSoft: "#FFE4EB",
                ink: "#3A2430", muted: "#9C838E", hairline: "#F6E3E9",
                positive: "#2FA37A", warning: "#D98200", danger: "#D62B47",
                heroTop: "#FFB3C6", heroBottom: "#F78CA0",
                softTop: "#FFF0F4", softBottom: "#FFFBFC",
                heroShadow: "#F78CA0"
            ),
            dark: ThemeScheme(
                bg: "#1A1216", surface: "#251B20", surfaceAlt: "#2C2026",
                accent: "#FFA5BC", accentDeep: "#E0708E", accentSoft: "#4C3038",
                ink: "#F8ECF0", muted: "#AC93A0", hairline: "#382A31",
                positive: "#4BC08A", warning: "#FFB020", danger: "#FF6B7F",
                heroTop: "#C4587A", heroBottom: "#8C3A55",
                softTop: "#2B1E24", softBottom: "#1D1519",
                heroShadow: "#8C3A55"
            ),
            swatch: ["#FF8FAB", "#FFE4EB", "#FFF5F7"]
        ),
        .white: AppTheme(id: .white,
            light: ThemeScheme(
                bg: "#FAFBFC", surface: "#FFFFFF", surfaceAlt: "#F2F4F7",
                accent: "#4A5568", accentDeep: "#2D3748", accentSoft: "#E2E8F0",
                ink: "#1A202C", muted: "#718096", hairline: "#E4E9EF",
                positive: "#2FA37A", warning: "#D98200", danger: "#D62B47",
                heroTop: "#4E5D73", heroBottom: "#2B3648",
                softTop: "#F2F4F7", softBottom: "#FAFBFC",
                heroShadow: "#2B3648"
            ),
            dark: ThemeScheme(
                bg: "#101317", surface: "#1A1F26", surfaceAlt: "#212832",
                accent: "#A0AEC0", accentDeep: "#7B8AA0", accentSoft: "#2C3540",
                ink: "#EDF1F5", muted: "#93A1B0", hairline: "#2B3440",
                positive: "#4BC08A", warning: "#FFB020", danger: "#FF6B7F",
                heroTop: "#3D4859", heroBottom: "#222B38",
                softTop: "#1D242E", softBottom: "#11151A",
                heroShadow: "#222B38"
            ),
            swatch: ["#4A5568", "#E2E8F0", "#FAFBFC"]
        ),
        .blue: AppTheme(id: .blue,
            light: ThemeScheme(
                bg: "#F7FAFF", surface: "#FFFFFF", surfaceAlt: "#EDF3FE",
                accent: "#3D7BFF", accentDeep: "#2B5FE3", accentSoft: "#D3E2FF",
                ink: "#12203A", muted: "#6E7FA0", hairline: "#DCE6F7",
                positive: "#2FA37A", warning: "#D98200", danger: "#D62B47",
                heroTop: "#5B93FF", heroBottom: "#2B5FE3",
                softTop: "#E4EEFF", softBottom: "#F7FAFF",
                heroShadow: "#2B5FE3"
            ),
            dark: ThemeScheme(
                bg: "#0F141C", surface: "#181F2B", surfaceAlt: "#1F2836",
                accent: "#6B9BFF", accentDeep: "#3E6FE0", accentSoft: "#26344A",
                ink: "#E9EFF9", muted: "#8B99B5", hairline: "#2A3546",
                positive: "#4BC08A", warning: "#FFB020", danger: "#FF6B7F",
                heroTop: "#3D66B8", heroBottom: "#22406E",
                softTop: "#1C2636", softBottom: "#11161F",
                heroShadow: "#22406E"
            ),
            swatch: ["#3D7BFF", "#D3E2FF", "#EDF3FE"]
        ),
        .rainbow: AppTheme(id: .rainbow,
            light: ThemeScheme(
                bg: "#FDFBFF", surface: "#FFFFFF", surfaceAlt: "#F6F0FF",
                accent: "#7C4DFF", accentDeep: "#5E35D6", accentSoft: "#E6DBFF",
                ink: "#241638", muted: "#83729C", hairline: "#E8DDF6",
                positive: "#2FA37A", warning: "#D98200", danger: "#D62B47",
                heroTop: "#FF6FB0", heroBottom: "#7C4DFF",
                softTop: "#F0E7FF", softBottom: "#FDFBFF",
                heroShadow: "#7C4DFF"
            ),
            dark: ThemeScheme(
                bg: "#120F1C", surface: "#1C1829", surfaceAlt: "#241F33",
                accent: "#A585FF", accentDeep: "#7C58E8", accentSoft: "#342A4E",
                ink: "#F1EBFA", muted: "#9C8FBB", hairline: "#322A48",
                positive: "#4BC08A", warning: "#FFB020", danger: "#FF6B7F",
                heroTop: "#8A4BC0", heroBottom: "#4A2B85",
                softTop: "#241D38", softBottom: "#141021",
                heroShadow: "#4A2B85"
            ),
            swatch: ["#FF6FB0", "#7C4DFF", "#3EC6E0"]
        )
    ]

    static func theme(for id: AppThemeID) -> AppTheme { all[id] ?? all[.pink]! }
}

// MARK: - 调色板（保持静态 API，全部视图无需感知主题切换）

enum Palette {
    /// 当前主题，由 ThemeSync 在设置变化时写入
    static var currentID: AppThemeID = .pink

    static var theme: AppTheme { ThemeRegistry.theme(for: currentID) }

    private static func resolve(_ keyPath: KeyPath<ThemeScheme, String>) -> Color {
        Color(light: theme.light[keyPath: keyPath], dark: theme.dark[keyPath: keyPath])
    }

    static var bg: Color { resolve(\.bg) }
    static var surface: Color { resolve(\.surface) }
    static var surfaceAlt: Color { resolve(\.surfaceAlt) }
    static var accent: Color { resolve(\.accent) }
    static var accentDeep: Color { resolve(\.accentDeep) }
    static var accentSoft: Color { resolve(\.accentSoft) }
    static var ink: Color { resolve(\.ink) }
    static var muted: Color { resolve(\.muted) }
    static var hairline: Color { resolve(\.hairline) }
    static var positive: Color { resolve(\.positive) }
    static var warning: Color { resolve(\.warning) }
    static var danger: Color { resolve(\.danger) }

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(light: theme.light.heroTop, dark: theme.dark.heroTop),
                Color(light: theme.light.heroBottom, dark: theme.dark.heroBottom)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var softGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(light: theme.light.softTop, dark: theme.dark.softTop),
                Color(light: theme.light.softBottom, dark: theme.dark.softBottom)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// hero 阴影基色（按外观解析），用于 .opacity() 调制
    static var heroShadowHex: (light: String, dark: String) {
        (theme.light.heroShadow, theme.dark.heroShadow)
    }

    /// 把外观设置落到位（NSApp.appearance + 当前主题），幂等；必须在主线程调用
    static func apply(appearance: AppAppearance, themeID: AppThemeID) {
        currentID = themeID
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }

    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        let value = UInt32(text, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension AuraCore.RGBColor {
    var swiftUI: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent)
        )
    }
}

// MARK: - 主题同步（外观覆盖 + 整树刷新）

/// 挂在根视图上：把设置里的外观/主题落到 NSApp.appearance 与 Palette，
/// 并用 .id() 强制整树重建，让静态 Palette 的变化立即生效。
struct ThemeSync: ViewModifier {
    @ObservedObject var store: AuraStore

    func body(content: Content) -> some View {
        if store.themeKey != Self.appliedKey {
            Self.appliedKey = store.themeKey
            Palette.apply(appearance: store.settings.appearance, themeID: store.settings.themeID)
        }
        return content
            .id(store.themeKey)
    }

    /// 记录上次落地的组合键，避免每次快照刷新都重设 NSApp.appearance
    private static var appliedKey: String?
}

// MARK: - 通用组件

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = 18) -> some View {
        modifier(CardModifier(padding: padding, radius: radius))
    }
}

/// 小标签，例如"演示模式""USB HID"
struct Chip: View {
    var text: String
    var tint: Color = Palette.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.12))
            )
            .foregroundStyle(filled ? Color.white : tint)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

/// 粉色滑块
struct PinkSlider: View {
    var title: String
    var value: Binding<Double>
    var range: ClosedRange<Double> = 0...1
    var valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer()
                Text(valueText).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
            }
            Slider(value: value, in: range)
                .tint(Palette.accent)
                .controlSize(.small)
        }
    }
}
