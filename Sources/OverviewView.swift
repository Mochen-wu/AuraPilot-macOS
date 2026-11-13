import SwiftUI
import AuraCore

struct OverviewView: View {
    @ObservedObject var store: AuraStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                stats
                appearanceCard
                zonesCard
                footnote
            }
            .padding(26)
        }
    }

    // MARK: - 外观

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                SectionHeader(title: "外观", subtitle: "深色模式可自动跟随系统，日常色任选")
                Spacer()
                Picker("", selection: Binding(
                    get: { store.settings.appearance },
                    set: { store.setAppearance($0) }
                )) {
                    ForEach(AppAppearance.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 264)
            }

            HStack(spacing: 12) {
                ForEach(AppThemeID.allCases, id: \.self) { id in
                    ThemeCard(
                        themeID: id,
                        isSelected: store.settings.themeID == id
                    ) {
                        store.setTheme(id)
                    }
                }
            }
        }
        .card()
    }

    // MARK: - 顶部

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Palette.heroGradient)

            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 210, height: 210)
                .offset(x: 60, y: -90)
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 130, height: 130)
                .offset(x: -30, y: 70)

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(store.device.name)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 7) {
                        Chip(text: store.device.kind.displayName, tint: .white, filled: true)
                        if store.snapshot.isSimulated {
                            Chip(text: "不影响真实硬件", tint: .white)
                        }
                        if let temp = store.sensors.cpuTemperature {
                            Chip(text: String(format: "CPU %.0f℃", temp), tint: .white)
                        }
                    }

                    Text(store.state.isOn ? "灯光已开启 · \(store.snapshot.presets.count) 套预设可用" : "灯光已全部关闭")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                }

                Spacer(minLength: 8)

                powerButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .frame(height: 158)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Palette.accent.opacity(0.25), radius: 18, x: 0, y: 8)
    }

    private var powerButton: some View {
        VStack(spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.toggleGlobal() }
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(store.state.isOn ? Palette.accentDeep : Color.white)
                    .frame(width: 48, height: 48)
                    .background(
                        Circle().fill(store.state.isOn ? Color.white : Color.white.opacity(0.16))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(store.state.isOn ? 0 : 0.5), lineWidth: 1.4)
                    )
            }
            .buttonStyle(.plain)

            Text(store.state.isOn ? "总开关 开" : "总开关 关")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - 数据卡

    private var stats: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 14
        ) {
            StatCard(
                title: "CPU 温度",
                value: store.sensors.cpuTemperature.map { String(format: "%.0f", $0) } ?? "—",
                unit: "℃",
                icon: "thermometer.medium",
                tint: Palette.accent,
                detail: store.sensors.source
            )
            StatCard(
                title: "风扇转速",
                value: store.sensors.fans.first.map { "\($0.rpm)" } ?? "—",
                unit: "RPM",
                icon: "fanblades",
                tint: Color(light: "#B98CFF", dark: "#C9A6FF"),
                detail: store.sensors.fans.isEmpty ? "macOS 未暴露风扇" : "\(store.sensors.fans.count) 个风扇"
            )
            StatCard(
                title: "键盘灯效",
                value: store.zone(.keyboard).mode.displayName,
                unit: "",
                icon: "keyboard",
                tint: Palette.positive,
                detail: store.zone(.keyboard).primary.hexString.uppercased()
            )
        }
    }

    // MARK: - 灯区

    private var zonesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                SectionHeader(title: "机身着灯", subtitle: "分区独立控制：模式、颜色、亮度")
                Spacer()
                Button("全部关闭") {
                    store.setAllOff()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.accentDeep)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Palette.accentSoft))
            }

            VStack(spacing: 0) {
                ForEach(AuraZone.allCases) { zone in
                    zoneRow(zone)
                    if zone != AuraZone.allCases.last {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(height: 1)
                            .padding(.leading, 34)
                    }
                }
            }
        }
        .card()
    }

    private func zoneRow(_ zone: AuraZone) -> some View {
        let state = store.zone(zone)
        let supported = store.device.capabilities.supports(zone)

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [state.primary.swiftUI, state.secondary.swiftUI],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                    .frame(width: 22, height: 22)
            }
            .opacity(state.isEnabled && store.state.isOn ? 1 : 0.3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(zone.displayName)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    if !supported {
                        Chip(text: "设备不支持", tint: Palette.muted)
                    }
                }
                Text("\(state.mode.displayName) · \(state.primary.hexString.uppercased())")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Slider(
                    value: Binding(
                        get: { store.zone(zone).brightness },
                        set: { store.setBrightness($0, zone: zone) }
                    ),
                    in: 0...1
                )
                .frame(width: 120)
                .tint(Palette.accent)
                .controlSize(.mini)
                .disabled(!supported)
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { store.zone(zone).isEnabled },
                    set: { store.setZoneEnabled($0, zone: zone) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Palette.accent)
            .disabled(!supported)
        }
        .padding(.vertical, 11)
        .opacity(supported ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedZone = zone
            withAnimation(.easeInOut(duration: 0.15)) { store.section = .lighting }
        }
    }

    private var footnote: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5))
            Text(store.snapshot.isSimulated
                 ? "当前为演示模式：界面与灯效引擎全速运行，但不会改动任何硬件。接入 ASUS HID 设备或远程桥后自动切换。"
                 : "已连接真实设备。亮度/速度档位由设备固件决定，界面会按能力自动收敛。")
            .font(.system(size: 10.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 2)
    }
}

private struct StatCard: View {
    var title: String
    var value: String
    var unit: String
    var icon: String
    var tint: Color
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
            }

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .card(padding: 15, radius: 16)
    }
}

// MARK: - 主题色卡

private struct ThemeCard: View {
    var themeID: AppThemeID
    var isSelected: Bool
    var action: () -> Void

    private var theme: AppTheme { ThemeRegistry.theme(for: themeID) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // 三色预览条
                HStack(spacing: 0) {
                    ForEach(Array(theme.swatch.enumerated()), id: \.offset) { _, hex in
                        Rectangle()
                            .fill(Color(hex: hex))
                    }
                }
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                )

                Text(themeID.displayName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Palette.accentDeep : Palette.ink)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Palette.accentSoft.opacity(0.55) : Palette.surfaceAlt.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent : Palette.hairline, lineWidth: isSelected ? 1.6 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
