import Foundation
import AuraCore

// aura-probe —— 命令行诊断 / 协议校准工具
//
//   aura-probe devices
//   aura-probe sensors
//   aura-probe frame --zone keyboard --mode breathe --color "#FF5C88" --bright 0.6
//   aura-probe raw --hex "EC 40 01 01 80 FF 5C 88" [--feature|--output]

/// 探针构建版本。每次发包都会 +0.1，运行时第一行就打印出来，
/// 这样一眼就能看出手里跑的是新二进制还是旧二进制（之前踩过这个坑）。
let auraProbeVersion = "0.20"

let arguments = Array(CommandLine.arguments.dropFirst())

// 任何命令都先打一行版本横幅
if !arguments.isEmpty {
    print("aura-probe v\(auraProbeVersion)  (AuraPilot)")
}

func printUsage() {
    print("""
    AuraPilot 诊断工具  v\(auraProbeVersion)

      aura-probe devices              列出 ASUS HID 接口（并标注匹配的协议包）
      aura-probe descriptor           解析并打印 HID 报告描述符（report ID / 各类型字节数）
      aura-probe profiles             列出内置协议包
      aura-probe sensors              读一次温度 / 风扇
      aura-probe verify               逐个尝试 5 种报文写法，定位内置键盘为什么没反应
      aura-probe bringup             复刻 macRogAuraCore 的 17B Feature 路径，连发 4 个颜色
      aura-probe one --color FF0000  只发一条就退出（与 macRogAuraCore 完全同构）
      aura-probe matrix              穷举 通道×长度×open×primers 全部组合（颜色无效时跑这个）
      aura-probe schedule            打印自动开关（时间 / 深色模式）的当前判定，不下发报文
      aura-probe frame [参数]         按协议包下发一帧
          --zone keyboard|lightBar|logo   默认 keyboard
          --mode solid|breathe|...        默认 solid
          --color "#FF5C88"               默认 #FF7FA8
          --bright 0.7                    0...1
          --speed 0.5                     0...1
          --profile mac-rogauracore-keyboard   默认 auto（按 PID 自动匹配）
      aura-probe raw --hex "EC 40 ..."  发送裸报告
          --report-id 0
          --output                        用 Output Report 而不是 Feature
          --profile <id>                  默认 auto
    """)
}

func hexBytes(_ text: String) -> [UInt8] {
    text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
        .compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
}

func value(for flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

/// 按 --profile 选择协议包；auto 表示按 PID 依次尝试内置包
func makeTransport(_ profileArg: String) -> HIDTransport {
    if profileArg != "auto" {
        guard let profile = ProtocolLibrary.profile(id: profileArg) else {
            let ids = ProtocolLibrary.builtInProfiles().map { $0.id }.joined(separator: ", ")
            print("未知协议包：\(profileArg)\n可用：\(ids)")
            exit(1)
        }
        let transport = HIDTransport(profile: profile)
        transport.logHandler = { print("[hid] \($0)") }
        do {
            _ = try transport.probe()
        } catch {
            print("连接失败（\(profile.id)）：\(error.localizedDescription)")
            exit(1)
        }
        return transport
    }

    // 不要用 makeBest：它内部 probe 时的日志拿不到，排查接口时正需要这些日志
    var lastError: Error?
    for profile in ProtocolLibrary.builtInProfiles() {
        let transport = HIDTransport(profile: profile)
        transport.logHandler = { print("[hid] \($0)") }
        do {
            _ = try transport.probe()
            print("[hid] 使用协议包：\(profile.id)")
            return transport
        } catch {
            lastError = error
            transport.close()
        }
    }
    print("未找到可用的 ASUS HID 设备：\(lastError?.localizedDescription ?? "未知错误")")
    exit(1)
}

// MARK: - verify：穷举报文写法

struct VerifyVariant {
    let title: String
    let color: String
    let colorName: String
    let feature: Bool      // 灯效帧用 Feature 还是 Output
    let padTo: Int         // 0 表示不补齐
    let primers: Bool      // 先发 G-Helper 的 primers：5D B9 / 5D "ASUS Tech.Inc."
    let featureInit: Bool  // 先发 5A + "ASUS Tech.Inc."（Feature，补齐 64B）
}

let asusTechInc: [UInt8] = [0x41, 0x53, 0x55, 0x53, 0x20, 0x54, 0x65, 0x63,
                            0x68, 0x2E, 0x49, 0x6E, 0x63, 0x2E]

func runVerify() {
    let transport = makeTransport("mac-rogauracore-keyboard")
    if let info = transport.descriptor {
        print("接口：\(info.summary)")
    }
    print("接下来依次尝试 5 种写法，每种间隔 1.5 秒。")
    print("请盯着键盘：每一步应该变成对应颜色，记住哪种颜色真的亮过。\n")

    func padded(_ bytes: [UInt8], to target: Int) -> [UInt8] {
        guard target > bytes.count else { return bytes }
        return bytes + [UInt8](repeating: 0, count: target - bytes.count)
    }

    func staticEffect(_ rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
        [0xB3, 0x00, 0x00, rgb.0, rgb.1, rgb.2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    func send(_ label: String, _ bytes: [UInt8], reportID: UInt8, feature: Bool, padTo: Int) {
        let buffer = padded(bytes, to: padTo)
        for (name, code) in transport.sendExact(buffer, reportID: reportID, feature: feature) {
            let status = code == 0 ? "OK" : "FAIL"
            let hex = String(format: "0x%08X", UInt32(bitPattern: code))
            print("  \(label) \(buffer.count)B → \(status) \(hex)   \(name)")
        }
    }

    // padTo 是 **payload** 长度，sendExact 会另加 report ID。
    // 本机描述符：0x5D / 0x5A 的 payload 都是 63B → 缓冲区 64B。这是唯一正确的长度。
    let variants: [VerifyVariant] = [
        VerifyVariant(title: "① 64B 缓冲区（payload 63B）Feature —— 真机描述符定案", color: "#FF0000", colorName: "红色",
                      feature: true, padTo: 63, primers: false, featureInit: false),
        VerifyVariant(title: "② 17B 短包 Feature（早期写法，已知会被静默丢弃）", color: "#00FF00", colorName: "绿色",
                      feature: true, padTo: 0, primers: false, featureInit: false),
        VerifyVariant(title: "③ 64B 缓冲区走 Output 通道", color: "#0000FF", colorName: "蓝色",
                      feature: false, padTo: 63, primers: false, featureInit: false),
        VerifyVariant(title: "④ primers + 64B Output（G-Helper AuraProbe 顺序）", color: "#FFFF00", colorName: "黄色",
                      feature: false, padTo: 63, primers: true, featureInit: false),
        VerifyVariant(title: "⑤ 5A 握手（64B Feature）+ 64B Feature 灯效", color: "#FF00FF", colorName: "洋红",
                      feature: true, padTo: 63, primers: false, featureInit: true)
    ]

    for variant in variants {
        print("\(variant.title) → 预期颜色：\(variant.colorName) \(variant.color)")
        if variant.primers {
            send("primer 0x5D 0xB9", [0xB9], reportID: 0x5D, feature: false, padTo: 0)
            send("primer 0x5D ASUS", asusTechInc, reportID: 0x5D, feature: false, padTo: 0)
        }
        if variant.featureInit {
            send("init 0x5A ASUS", asusTechInc + [0x00, 0x00], reportID: 0x5A, feature: true, padTo: 63)
        }
        let rgb = RGBColor(hex: variant.color)?.bytes ?? (0xFF, 0x00, 0x00)
        send("灯效 0x5D 0xB3", staticEffect(rgb), reportID: 0x5D, feature: variant.feature, padTo: variant.padTo)
        send("SET 0x5D 0xB5", [0xB5] + [UInt8](repeating: 0, count: 15), reportID: 0x5D, feature: variant.feature, padTo: variant.padTo)
        send("APPLY 0x5D 0xB4", [0xB4] + [UInt8](repeating: 0, count: 15), reportID: 0x5D, feature: variant.feature, padTo: variant.padTo)
        Thread.sleep(forTimeInterval: 1.5)
        print("")
    }

    transport.close()
    print("完成。哪一步键盘真的变了颜色，把编号告诉我；都没变也说一声。")
}

// MARK: - bringup：先点亮再上色

/// 读一次供电状态（pmset），失败返回未知；仅用于诊断提示
func powerSummary() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "batt"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "未知" }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    if text.contains("AC Power") { return "已接电源" }
    if text.contains("Battery Power") { return "电池供电" }
    return "未知"
}

/// 真机定案（2025-11，照片确认）：macRogAuraCore 的 `blue` / `cyan` / `yellow`
/// 都能真实变色，但**必须先跑 `initialize_keyboard`** —— 它发的是
/// `5A + "ASUS Tech.Inc." + 00 00`（17 字节 Feature）。不发握手，0x5D 的
/// 颜色帧会被设备直接忽略（这就是之前所有「OK 但不亮」的真正原因；
/// 握手和亮度共用 0x5A 通道，所以亮度一直是通的）。
func runBringup() {
    print("当前供电：\(powerSummary())")
    print("""
    流程：握手(5A ASUS Tech.Inc.) → 灯效(5D B3) → SET → APPLY，全 17B Feature。
    每步新建连接，请盯着键盘记颜色。
    """)

    let handshake: [UInt8] = [0x5A] + Array("ASUS Tech.Inc.".utf8) + [0x00, 0x00]   // 17B
    let setP: [UInt8] = [0x5D, 0xB5] + [UInt8](repeating: 0, count: 15)
    let applyP: [UInt8] = [0x5D, 0xB4] + [UInt8](repeating: 0, count: 15)

    let steps: [(String, String, (UInt8, UInt8, UInt8))] = [
        ("[1]", "粉色 #FF5C88", (0xFF, 0x5C, 0x88)),
        ("[2]", "绿色 #00FF00", (0x00, 0xFF, 0x00)),
        ("[3]", "蓝色 #0000FF", (0x00, 0x00, 0xFF)),
        ("[4]", "红色 #FF0000", (0xFF, 0x00, 0x00))
    ]

    for (label, name, rgb) in steps {
        print("\n\(label) \(name)")
        guard let profile = ProtocolLibrary.profile(id: "mac-rogauracore-keyboard") else { return }
        let transport = HIDTransport(profile: profile, openDevicesOnProbe: false)
        transport.logHandler = { _ in }
        do {
            _ = try transport.probe()
        } catch {
            print("  ✗ 连接失败：\(error.localizedDescription)")
            Thread.sleep(forTimeInterval: 1.2)
            continue
        }
        func send(_ label: String, _ frame: [UInt8]) {
            for (_, code) in transport.sendExact(frame, reportID: frame[0], feature: true) {
                let status = code == 0 ? "OK" : "FAIL 0x" + String(format: "%08X", UInt32(bitPattern: code))
                print("  \(label) \(frame.count)B → \(status)")
            }
        }
        send("握手", handshake)
        let effect: [UInt8] = [0x5D, 0xB3, 0x00, 0x00, rgb.0, rgb.1, rgb.2]
            + [UInt8](repeating: 0, count: 10)
        send("灯效", effect)
        send("SET ", setP)
        send("APPLY", applyP)
        transport.close()
        Thread.sleep(forTimeInterval: 2.0)
    }

    print("""

    哪几步变色了？全变 = 流路打通，我立刻收尾 App。
    """)
}

/// 单条发送后立即退出：与 macRogAuraCore 的可执行文件行为完全同构
/// （新进程 → 新 manager → 一条 17B Feature → 退出）。用来排除同进程内
/// 多次开/关 manager 带来的干扰。
func runOne() {
    let hex = value(for: "--color", in: arguments) ?? "#FF0000"
    guard let rgb = RGBColor(hex: hex)?.bytes else {
        print("颜色格式不对，用 --color FF5C88")
        exit(1)
    }
    guard let profile = ProtocolLibrary.profile(id: "mac-rogauracore-keyboard") else { exit(1) }
    let transport = HIDTransport(profile: profile, openDevicesOnProbe: false)
    transport.logHandler = { print("[hid] \($0)") }
    do { _ = try transport.probe() } catch {
        print("连接失败：\(error.localizedDescription)")
        exit(1)
    }
    let frame: [UInt8] = [0x5D, 0xB3, 0x00, 0x00, rgb.0, rgb.1, rgb.2]
        + [UInt8](repeating: 0, count: 10)
    for (name, code) in transport.sendExact(frame, reportID: 0x5D, feature: true) {
        let status = code == 0 ? "OK" : "FAIL 0x" + String(format: "%08X", UInt32(bitPattern: code))
        print("  灯效 17B Feature → \(status)   \(name)")
    }
    transport.close()
    print("已发送 \(hex)（17B Feature，不 open device）")
}

/// 把所有可能影响「0x5D 颜色帧是否生效」的变量一次跑完：
/// 通道（Feature / Output）× 缓冲区长度（17B / 64B）× 是否 open device × 有无 primers。
///
/// 背景：`macRogAuraCore on/off` 能开关灯（0x5A 亮度帧有效），但所有 17B Feature
/// 颜色帧都无效。G-Helper 在 PD 虚拟机里颜色正常，它走的是 HidSharp →
/// Output Report + 64B 缓冲区 + IOHIDDeviceOpen，这个组合此前从未完整测过。
func runMatrix() {
    print("当前供电：\(powerSummary())")
    print("""
    每步都会：新建连接 → （可选）open device → （可选）primers → 灯效 → SET → APPLY。
    请盯着键盘，记住每一步变成了什么颜色。
    """)

    struct Variant {
        let title: String
        let colorName: String
        let rgb: (UInt8, UInt8, UInt8)
        let feature: Bool
        let padTo64: Bool
        let open: Bool
        let primers: Bool
    }

    let variants: [Variant] = [
        Variant(title: "[A] Output 64B + open device + 无 primers", colorName: "红",
                rgb: (0xFF, 0x00, 0x00), feature: false, padTo64: true, open: true, primers: false),
        Variant(title: "[B] Output 64B + open device + primers（G-Helper 完整配置）", colorName: "绿",
                rgb: (0x00, 0xFF, 0x00), feature: false, padTo64: true, open: true, primers: true),
        Variant(title: "[C] Output 17B + open device", colorName: "蓝",
                rgb: (0x00, 0x00, 0xFF), feature: false, padTo64: false, open: true, primers: false),
        Variant(title: "[D] Feature 64B + open device", colorName: "黄",
                rgb: (0xFF, 0xFF, 0x00), feature: true, padTo64: true, open: true, primers: false),
        Variant(title: "[E] Feature 17B + 不 open（v0.4 的写法，对照）", colorName: "洋红",
                rgb: (0xFF, 0x00, 0xFF), feature: true, padTo64: false, open: false, primers: false)
    ]

    /// 组一个缓冲区：首字节 report ID，按需补零到 64
    func frame(_ rid: UInt8, _ payload: [UInt8], padTo64: Bool) -> [UInt8] {
        var out = [rid] + payload
        if padTo64, out.count < 64 { out += [UInt8](repeating: 0, count: 64 - out.count) }
        return out
    }

    for variant in variants {
        print("\n\(variant.title) → 预期颜色：\(variant.colorName)")

        guard let profile = ProtocolLibrary.profile(id: "mac-rogauracore-keyboard") else { return }
        let transport = HIDTransport(profile: profile, openDevicesOnProbe: variant.open)
        transport.logHandler = { _ in }
        do {
            _ = try transport.probe()
        } catch {
            print("  ✗ 连接失败：\(error.localizedDescription)")
            Thread.sleep(forTimeInterval: 1.5)
            continue
        }

        // 先把亮度设为 3（0x5A Feature 17B，这条已确认有效），保证灯是亮的
        let bright: [UInt8] = [0x5A, 0xBA, 0xC5, 0xC4, 0x03] + [UInt8](repeating: 0, count: 12)
        _ = transport.sendExact(bright, reportID: 0x5A, feature: true)

        if variant.primers {
            _ = transport.sendExact(frame(0x5D, [0xB9], padTo64: variant.padTo64), reportID: 0x5D, feature: variant.feature)
            _ = transport.sendExact(frame(0x5D, Array("ASUS Tech.Inc.".utf8), padTo64: variant.padTo64),
                                    reportID: 0x5D, feature: variant.feature)
        }

        let effect: [UInt8] = [0xB3, 0x00, 0x00, variant.rgb.0, variant.rgb.1, variant.rgb.2]
            + [UInt8](repeating: 0, count: 10)
        let setP: [UInt8] = [0xB5] + [UInt8](repeating: 0, count: 15)
        let applyP: [UInt8] = [0xB4] + [UInt8](repeating: 0, count: 15)

        for (label, payload) in [("灯效", effect), ("SET ", setP), ("APPLY", applyP)] {
            let buf = frame(0x5D, payload, padTo64: variant.padTo64)
            for (_, code) in transport.sendExact(buf, reportID: 0x5D, feature: variant.feature) {
                let status = code == 0 ? "OK" : "FAIL 0x" + String(format: "%08X", UInt32(bitPattern: code))
                let kind = variant.feature ? "Feature" : "Output "
                print("  \(label) \(buf.count)B \(kind) → \(status)")
            }
        }
        transport.close()
        Thread.sleep(forTimeInterval: 2.2)
    }

    print("""

    请反馈：A~E 哪一步真的出现了对应颜色（红/绿/蓝/黄/洋红）？
    """)
}

/// 只读：打印 App 里"自动开关灯光"此刻会怎么判，方便在终端核对，不发任何报文。
func runSchedule() {
    let config = ConfigStore().load().settings.autoLighting
    let dark = AutoLightingSchedulerStyleProbe.isDark
    let decision = AutoLighting.decide(config, at: Date(), isDarkMode: dark)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "zh_CN")

    print("现在时间：\(formatter.string(from: Date()))")
    print("系统外观：\(dark ? "深色" : "浅色")")
    print("自动开关：\(config.isEnabled ? "已启用" : "未启用")  触发方式：\(config.trigger.displayName)")
    if config.trigger != .darkMode {
        print("时间窗　：\(config.windowDescription)")
    }
    print("白天亮度：\(Int((config.daytimeLevel * 100).rounded()))%")
    print("判定结果：\(decision.isLit ? "点亮（亮度 100%）" : "熄灭（亮度 \(Int((decision.level * 100).rounded()))%）")")
    print("原因　　：\(decision.reason)")
    if let next = AutoLighting.nextTransition(config, after: Date()) {
        print("下次变化：\(formatter.string(from: next))")
    }
    print("配置文件：\(ConfigStore().fileURL.path)")
}

/// 读系统深浅色（与 App 内 `AutoLightingScheduler.isSystemDark` 同一套判断）
enum AutoLightingSchedulerStyleProbe {
    static var isDark: Bool {
        guard let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") else { return false }
        return style.caseInsensitiveCompare("dark") == .orderedSame
    }
}

guard let command = arguments.first else {
    printUsage()
    exit(0)
}

switch command {
case "devices":
    let devices = HIDTransport.discover()
    let profiles = ProtocolLibrary.builtInProfiles()
    if devices.isEmpty {
        print("未发现 VID 0x0B05（ASUS）的 HID 设备。")
        print("提示：内置键盘/灯条/Logo 灯走 ACPI-WMI，不会出现在 HID 列表里。")
    } else {
        let candidates = DeviceCatalog.list(profiles: profiles)
        for device in devices {
            print("• \(device.summary)")
            print("  locationID=\(device.locationID) serial=\(device.serial ?? "-")")
            let matched = profiles.filter { $0.matches(vendorID: device.vendorID, productID: device.productID) }
            if matched.isEmpty {
                print("  匹配协议包：无")
            } else {
                let names = matched.map { "\($0.id)\($0.productIDs.isEmpty ? "（泛用）" : "")\($0.isExperimental ? "（实验）" : "")" }
                print("  匹配协议包：\(names.joined(separator: ", "))")
            }
            if let candidate = candidates.first(where: { $0.id == device.id }) {
                print("  能否控灯：\(candidate.canControl ? "✅ 可以" : "⛔️ 不行")（\(candidate.note ?? "feature 报告长度够")）")
                print("  选择用 id：\(candidate.id)")
            }
        }
    }

case "descriptor":
    for line in HIDTransport.dumpReportDescriptors() {
        print(line)
    }

case "profiles":
    for profile in ProtocolLibrary.builtInProfiles() {
        let pids = profile.productIDs.isEmpty
            ? "任意 PID（泛用）"
            : profile.productIDs.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
        print("• \(profile.id)")
        print("  名称：\(profile.displayName)")
        print("  PID：\(pids)  灯区：\(profile.zones.map { $0.displayName }.joined(separator: "/"))")
        print("  最小报告：\(profile.minimumReportLength)B\(profile.isExperimental ? "  [实验]" : "")")
    }

case "sensors":
    let hub = SystemSensorHub()
    guard hub.isAvailable else {
        print("AppleSMC 不可用（可能被 SIP 限制，或该机型不暴露这些键）")
        exit(1)
    }
    let snapshot = hub.read()
    print("CPU: \(snapshot.cpuTemperature.map { String(format: "%.1f℃", $0) } ?? "—")")
    print("GPU: \(snapshot.gpuTemperature.map { String(format: "%.1f℃", $0) } ?? "—")")
    print("Fans: \(snapshot.fans.map { "\($0.name)=\($0.rpm)rpm" }.joined(separator: ", "))")
    print("Keys: \(snapshot.probedKeys.joined(separator: ", "))")

case "frame":
    let zone = AuraZone(rawValue: value(for: "--zone", in: arguments) ?? "keyboard") ?? .keyboard
    let mode = AuraMode.allCases.first { $0.protocolKey == (value(for: "--mode", in: arguments) ?? "solid") } ?? .solid
    let color = RGBColor(hex: value(for: "--color", in: arguments) ?? "#FF7FA8") ?? .sakura
    let brightness = Double(value(for: "--bright", in: arguments) ?? "0.7") ?? 0.7
    let speed = Double(value(for: "--speed", in: arguments) ?? "0.5") ?? 0.5

    let transport = makeTransport(value(for: "--profile", in: arguments) ?? "auto")
    if let info = transport.descriptor {
        print("已连接：\(info.product) [\(info.usbIdentifier)] \(info.summary)")
    }
    let frame = ZoneFrame(
        zone: zone,
        mode: mode,
        primary: color,
        secondary: .lilac,
        brightness: brightness,
        speed: speed,
        elapsed: 0
    )
    do {
        try transport.apply(frame)
        print("已下发：\(zone.displayName) \(mode.displayName) \(color.hexString) 亮度\(Int(brightness * 100))%")
        transport.close()
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }

case "raw":
    guard let hex = value(for: "--hex", in: arguments) else {
        print("需要 --hex \"EC 40 ...\"")
        exit(1)
    }
    let bytes = hexBytes(hex)
    guard !bytes.isEmpty else {
        print("--hex 解析为空")
        exit(1)
    }
    let reportID = UInt8(value(for: "--report-id", in: arguments) ?? "0") ?? 0
    let feature = !arguments.contains("--output")

    let transport = makeTransport(value(for: "--profile", in: arguments) ?? "auto")
    do {
        try transport.sendRaw(bytes, reportID: reportID, feature: feature)
        print("已发送 \(bytes.count) 字节（\(feature ? "Feature" : "Output") reportID=\(reportID)）")
        transport.close()
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }

case "verify":
    runVerify()

case "bringup":
    runBringup()

case "one":
    runOne()

case "matrix":
    runMatrix()

case "schedule":
    runSchedule()

default:
    printUsage()
}
