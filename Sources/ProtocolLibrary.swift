import Foundation

/// 协议包仓库。
///
/// 内置包覆盖两类通道：
/// 1. `asus-wmi-tuf-keyboard` —— 直接照搬 G-Helper 的 AsusACPI 实现（真实可用，
///    但需要一台能跑 ACPI-WMI 的机器，即远程桥 agent）。
/// 2. `generic-hid-aura` —— HID 通道的校准起点（实验性，字节布局必须按真机校正）。
///
/// 用户可以把自定义协议包放进
/// `~/Library/Application Support/AuraPilot/protocols/*.json`，无需改代码即可扩展新机型。
public enum ProtocolLibrary {

    public static func builtInProfiles() -> [ProtocolProfile] {
        // 顺序即连接优先级：PID 精确匹配的包必须在泛用 HID 包之前
        [rogAuraCore(), falchionFamily(), falchionOmni(), wmiTUFKeyboard(), wmiLaptopZones(), genericHID()]
    }

    /// 按 id 精确取内置协议包（用户 JSON 包由 loadAll() 提供）
    public static func profile(id: String) -> ProtocolProfile? {
        builtInProfiles().first { $0.id == id }
    }

    /// ROG Falchion 全家的 Aura 包（G-Helper `AsusKeyboard.cs` 逐字节核对）。
    ///
    /// 65 字节 output report（含 report ID 0x00），每包设备都会 ACK：
    /// `00 51 2C [mode] 00 [speed] [亮度%] [colorMode] 00 02 R G B R2 G2 B2 R3 G3 B3 ...补0`
    /// mode：0=静态 1=呼吸 2=色彩循环 3=反应 4=波浪 5=涟漪 6=星光 7=流沙 8=流动 9=雨滴 15=直控
    /// speed：慢=255 正常=30 快=10（越小越快）；亮度 0...100
    /// 保存到板载存储：`50 55`（只应手动触发，不能跟着每帧发）
    /// 电量查询：`12 01` → 应答 [6]=百分比 [9]=是否充电
    public static func falchionFamily() -> ProtocolProfile {
        let modes: [String: UInt8] = [
            AuraMode.off.protocolKey: 0x00,
            AuraMode.solid.protocolKey: 0x00,
            AuraMode.breathe.protocolKey: 0x01,
            AuraMode.cycle.protocolKey: 0x02,
            AuraMode.highlight.protocolKey: 0x03,
            AuraMode.rainbow.protocolKey: 0x04,
            AuraMode.ripple.protocolKey: 0x05,
            AuraMode.star.protocolKey: 0x06,
            AuraMode.rain.protocolKey: 0x09
        ]
        let frame = AuraFrameSpec(
            name: "Falchion Aura 包",
            channel: .output(0x00),
            length: 64,
            template: [
                "0x51", "0x2C", "$mode", "0",
                "$speed", "$brightnessPercent",
                "0", "0", "0x02",
                "$r", "$g", "$b", "$r2", "$g2", "$b2",
                "0", "0", "0"
            ],
            modeCodes: modes,
            zoneCodes: [AuraZone.keyboard.rawValue: 0x00],
            brightnessLevels: 0,
            speedLevels: 3,
            // 速度查表（反向：UI 越快字节越小）
            speedValues: [255, 30, 10]
        )
        return ProtocolProfile(
            id: "asus-falchion-keyboard",
            displayName: "ROG Falchion / RX / Ace（外设）",
            vendorIDs: [0x0B05],
            productIDs: [0x193C, 0x193E, 0x1B04, 0x1B7E, 0x1A64],
            zones: [.keyboard],
            frames: [AuraZone.keyboard.rawValue: frame],
            isExperimental: true,
            notes: "协议来自 G-Helper AsusKeyboard.cs（外设走 output report 且设备逐包 ACK）。Rainbow=硬件波浪；颜色模式字节现为单色(0)，双色呼吸需把模板第 7 项改成 16。真机待校准。"
        )
    }

    /// Falchion RX Low Profile（OMNI 版）：PID 0x1ACE，走 mi_02&col02 接口、
    /// report ID 0x02、64 字节报告（含 ID），波浪/涟漪/流沙用分片序列（首片 16 字节）。
    public static func falchionOmni() -> ProtocolProfile {
        var profile = falchionFamily()
        profile.id = "asus-falchion-rx-lp-omni"
        profile.displayName = "ROG Falchion RX 矮轴 LP（OMNI）"
        profile.productIDs = [0x1ACE]
        profile.isExperimental = true
        profile.notes = "同 Falchion 协议族，但 report ID=0x02、64 字节含 ID、接口 mi_02&col02；波浪/涟漪需要 02→01→00 分片（引擎当前以静态+软件动画覆盖，硬件分片待真机校准）。电量可查：12 01。"
        var frame = profile.frames[AuraZone.keyboard.rawValue]!
        frame.channel = .output(0x02)
        frame.length = 63
        profile.frames[AuraZone.keyboard.rawValue] = frame
        return profile
    }

    /// rogauracore 协议（macRogAuraCore 移植验证），macOS 下驱动**内置键盘灯**的主力协议包。
    ///
    /// 报文为 17 字节 HID **Feature** Report，report ID 0x5D / 0x5A：
    /// - 灯效帧：`5D B3 [zone] [mode] R G B [speed] 00 R2 G2 B2 00 00 00 00 00`
    ///   mode：0=静态 1=双色呼吸 2=色彩循环；speed 查表 {0xE1, 0xEB, 0xF5}
    /// - 亮度帧：`5A BA C5 C4 [0...3] ...`
    /// - 提交序列：`5D B5`（SET）→ `5D B4`（APPLY）
    ///
    /// 关键事实（点不亮的根因排查结论）：
    ///  - **macOS 上所有报文（含灯效/SET/APPLY）都必须走 Feature Report**
    ///    （`IOHIDDeviceSetReport(kIOHIDReportTypeFeature)`），这已在用户真机上由
    ///    macRogAuraCore 验证可行；G-Helper 走 Output 是 Windows/虚拟机路径，macOS 原生不适用。
    ///  - 报文恰好 17 字节（ID+16B），**不补齐**到 64。
    ///  - 普通 static 颜色**不需要** primers（5D B9 / "ASUS Tech.Inc."），
    ///    macRogAuraCore 源码里 `MESSAGE_INITIALIZE_KEYBOARD` 定义了但从未发送。
    ///
    /// 来源：github.com/black-dragon74/macRogAuraCore（BSD-3）与 nnrohu fork（2025），
    /// 上游为 Will Roberts 的 rogauracore；G-Helper `app/USB/Aura.cs` 交叉印证字节布局。
    /// 支持机型 PID：0x1854(GL553/GL753) 0x1869(GL503/FX503/GL703) 0x1866(GL504/GL703/GX501/GM501)
    /// 0x19B6(GA503/幻15 等 N-KEY) 0x1932(Strix Arion)。其它机型 PID 需用 aura-probe 枚举后加进来。
    public static func rogAuraCore() -> ProtocolProfile {
        // **真机已验证有效的路径**（macRogAuraCore 在 macOS 上能正常改颜色）：
        //   全部报文走 Feature Report，缓冲区 17 字节 = 1B report ID + 16B payload。
        //
        // 注意：`aura-probe descriptor` 会显示描述符声明 feature/output 各 63B，
        // 但实测 17 字节短包**能被接受并生效**——之前「补齐到 64B」的推断是错的，
        // 那段弯路源于我们把 IOHIDDeviceOpen 也打开了（macRogAuraCore 从不 open device）。
        let frame = AuraFrameSpec(
            name: "rogauracore 灯效帧",
            channel: .feature(0x5D),
            length: 16,
            // 字节布局与 macRogAuraCore 的 single_static 逐字节一致：
            //   [0]=0x5d [1]=0xb3 [2]=zone [3]=mode [4..6]=RGB [7]=speed [8..15]=0
            template: [
                "0xB3", "$zone", "$mode",
                "$r", "$g", "$b", "$speedAnimated",
                "0", "$dualFlag", "$r2Animated", "$g2Animated", "$b2Animated",
                "0", "0", "0", "0"
            ],
            modeCodes: [
                AuraMode.off.protocolKey: 0x00,
                AuraMode.solid.protocolKey: 0x00,
                AuraMode.breathe.protocolKey: 0x01,
                AuraMode.cycle.protocolKey: 0x02
            ],
            zoneCodes: [AuraZone.keyboard.rawValue: 0x00],
            brightnessLevels: 0,
            speedLevels: 3,
            speedValues: [0xE1, 0xEB, 0xF5],
            // 亮度是独立报告 0x5A，同样 17 字节
            attached: [
                AuraFrameSpec(
                    name: "rogauracore 亮度",
                    channel: .feature(0x5A),
                    length: 16,
                    template: ["0xBA", "0xC5", "0xC4", "$brightness"]
                        + [String](repeating: "0", count: 12),
                    brightnessLevels: 4
                )
            ]
        )

        // SET / APPLY：`5D B5 00*15` / `5D B4 00*15`，17 字节 Feature
        let commitSet = AuraFrameSpec(
            name: "rogauracore 提交 SET",
            channel: .feature(0x5D),
            length: 16,
            template: ["0xB5"] + [String](repeating: "0", count: 15)
        )
        let commitApply = AuraFrameSpec(
            name: "rogauracore 提交 APPLY",
            channel: .feature(0x5D),
            length: 16,
            template: ["0xB4"] + [String](repeating: "0", count: 15)
        )

        // 初始化握手（真机验证**必须先发**：不发它，0x5D 的颜色帧会被设备忽略）。
        // macRogAuraCore 的 initialize_keyboard 命令发的就是这条：
        // 5A + "ASUS Tech.Inc." + 00 00，17 字节 Feature。
        let initialize = AuraFrameSpec(
            name: "rogauracore 初始化握手",
            channel: .feature(0x5A),
            length: 16,
            template: [
                "0x41", "0x53", "0x55", "0x53", "0x20",
                "0x54", "0x65", "0x63", "0x68", "0x2E",
                "0x49", "0x6E", "0x63", "0x2E", "0x00", "0x00"
            ]
        )

        // 灯条 / Logo：沿用 rogauracore 的区码 keyboard=0x00 / lightbar=0x01 / logo=0x02。
        // 这台机器有没有该硬件由真机决定：没有的话帧无效果，但也不会报错。
        // UI 会按 zones 声明启用对应控件，用户实测确认。
        var lightBarFrame = frame
        lightBarFrame.name = "rogauracore 灯条"
        lightBarFrame.zoneCodes = [AuraZone.lightBar.rawValue: 0x01]
        // 亮度是设备级的一条 0x5A 报告，只挂在键盘帧上；
        // 三个灯区各带一份的话，最后一条会把前面的亮度覆盖掉。
        lightBarFrame.attached = nil
        var logoFrame = frame
        logoFrame.name = "rogauracore Logo 灯"
        logoFrame.zoneCodes = [AuraZone.logo.rawValue: 0x02]
        logoFrame.attached = nil

        return ProtocolProfile(
            id: "mac-rogauracore-keyboard",
            displayName: "ROG 内置键盘（rogauracore）",
            vendorIDs: [0x0B05],
            productIDs: [0x1854, 0x1869, 0x1866, 0x19B6, 0x1932],
            zones: [.keyboard, .lightBar, .logo],
            frames: [
                AuraZone.keyboard.rawValue: frame,
                AuraZone.lightBar.rawValue: lightBarFrame,
                AuraZone.logo.rawValue: logoFrame
            ],
            commitFrames: [commitSet, commitApply],
            initFrames: [initialize],
            isExperimental: false,
            notes: "与 macRogAuraCore 一致：先发 0x5A 握手（ASUS Tech.Inc.）再发颜色，Feature 通道、17 字节、不 IOHIDDeviceOpen。模式码只有 off/solid=0x00、breathe=0x01、cycle=0x02；真机 N-KEY(0x19B6) 实测只有静态生效，其余取决于固件版本。G-Helper 里彩虹/星光等模式属于 WMI/Falchion 协议族，本协议包没有对应模式码。"
        )
    }

    /// 来自 G-Helper `AsusACPI.cs`：
    /// TUF_KB = 0x00100056，6 字节参数 [0xB4, mode, R, G, B, speed]
    public static func wmiTUFKeyboard() -> ProtocolProfile {
        let modes: [String: UInt8] = [
            AuraMode.off.protocolKey: 0,
            AuraMode.solid.protocolKey: 0,
            AuraMode.breathe.protocolKey: 1,
            AuraMode.cycle.protocolKey: 2,
            AuraMode.rainbow.protocolKey: 3,
            AuraMode.star.protocolKey: 4,
            AuraMode.rain.protocolKey: 5,
            AuraMode.highlight.protocolKey: 6,
            AuraMode.laser.protocolKey: 7,
            AuraMode.ripple.protocolKey: 8
        ]

        let frame = AuraFrameSpec(
            name: "TUF 键盘 RGB",
            channel: .deviceSet(0x0010_0056),
            length: 6,
            template: ["0xB4", "$mode", "$r", "$g", "$b", "$speed"],
            modeCodes: modes,
            zoneCodes: [AuraZone.keyboard.rawValue: 0],
            brightnessLevels: 0,
            speedLevels: 0
        )

        let brightness = AuraFrameSpec(
            name: "TUF 键盘背光亮度",
            channel: .deviceSet(0x0005_0021),
            length: 0,
            template: ["$brightnessAsus"],
            modeCodes: [:],
            zoneCodes: [:],
            brightnessLevels: 4,
            speedLevels: 0
        )

        return ProtocolProfile(
            id: "asus-wmi-tuf-keyboard",
            displayName: "ASUS TUF / ROG 键盘（WMI）",
            vendorIDs: [0x0B05],
            productIDs: [],
            zones: [.keyboard],
            frames: [
                AuraZone.keyboard.rawValue: frame,
                "keyboardBrightness": brightness
            ],
            commit: nil,
            offFrames: nil,
            isExperimental: false,
            notes: "参数布局来自 G-Helper AsusACPI.TUFKeyboardRGB，仅 ACPI-WMI 通道可用（需远程桥 agent）。"
        )
    }

    /// HID 通道的通用起点。ASUS 外置键盘/鼠标/灯控盒走厂商自定义报告，
    /// 常见结构是 64 字节 payload + 0xEC 命令字，但每个机型的字段偏移不同。
    /// 这里给一个可运行的骨架，真机校准时只改 template 即可。
    public static func genericHID() -> ProtocolProfile {
        let modes: [String: UInt8] = [
            AuraMode.off.protocolKey: 0x00,
            AuraMode.solid.protocolKey: 0x01,
            AuraMode.breathe.protocolKey: 0x02,
            AuraMode.cycle.protocolKey: 0x03,
            AuraMode.rainbow.protocolKey: 0x04,
            AuraMode.star.protocolKey: 0x05,
            AuraMode.rain.protocolKey: 0x06,
            AuraMode.highlight.protocolKey: 0x07,
            AuraMode.laser.protocolKey: 0x08,
            AuraMode.ripple.protocolKey: 0x09
        ]

        let frame = AuraFrameSpec(
            name: "Aura HID 通用",
            channel: .feature(0x00),
            length: 64,
            template: [
                "0xEC", "0x40",
                "$zone", "$mode", "$brightness", "$speed",
                "$r", "$g", "$b",
                "$r2", "$g2", "$b2"
            ],
            modeCodes: modes,
            zoneCodes: [
                AuraZone.keyboard.rawValue: 0x01,
                AuraZone.lightBar.rawValue: 0x02,
                AuraZone.logo.rawValue: 0x03
            ],
            brightnessLevels: 0,
            speedLevels: 0
        )

        return ProtocolProfile(
            id: "generic-hid-aura",
            displayName: "Aura HID 通用（实验）",
            vendorIDs: [0x0B05],
            productIDs: [],
            zones: AuraZone.allCases,
            frames: [
                AuraZone.keyboard.rawValue: frame,
                AuraZone.lightBar.rawValue: frame,
                AuraZone.logo.rawValue: frame
            ],
            commit: AuraFrameSpec(
                name: "提交",
                channel: .feature(0x00),
                length: 64,
                template: ["0xEC", "0x52"],
                modeCodes: [:],
                zoneCodes: [:]
            ),
            offFrames: nil,
            isExperimental: true,
            notes: "字段偏移需按真机校准；用 aura-probe 抓设备描述符后修改 template。"
        )
    }

    /// 三灯区笔记本协议包（远程桥用）。
    ///
    /// 端点取自 G-Helper `AsusACPI.cs` 中的 TUF_KB / TUF_KB2 一对：
    /// 0x00100056 主键盘通道、0x0010005a 备用通道（部分机型用它驱动灯条/Logo）。
    /// 具体哪个端点对应灯条与 Logo 因机型而异，需要真机确认，故标记为实验性。
    public static func wmiLaptopZones() -> ProtocolProfile {
        let modes: [String: UInt8] = [
            AuraMode.off.protocolKey: 0,
            AuraMode.solid.protocolKey: 0,
            AuraMode.breathe.protocolKey: 1,
            AuraMode.cycle.protocolKey: 2,
            AuraMode.rainbow.protocolKey: 3,
            AuraMode.star.protocolKey: 4,
            AuraMode.rain.protocolKey: 5,
            AuraMode.highlight.protocolKey: 6,
            AuraMode.laser.protocolKey: 7,
            AuraMode.ripple.protocolKey: 8
        ]

        func spec(deviceID: UInt32, zoneCode: UInt8) -> AuraFrameSpec {
            AuraFrameSpec(
                name: "WMI \(String(format: "0x%08X", deviceID))",
                channel: .deviceSet(deviceID),
                length: 6,
                template: ["0xB4", "$mode", "$r", "$g", "$b", "$speed"],
                modeCodes: modes,
                zoneCodes: [AuraZone.keyboard.rawValue: zoneCode],
                brightnessLevels: 0,
                speedLevels: 0
            )
        }

        return ProtocolProfile(
            id: "asus-wmi-laptop-3zone",
            displayName: "ASUS 笔记本三灯区（桥接）",
            vendorIDs: [0x0B05],
            productIDs: [],
            zones: AuraZone.allCases,
            frames: [
                AuraZone.keyboard.rawValue: spec(deviceID: 0x0010_0056, zoneCode: 0x01),
                AuraZone.lightBar.rawValue: spec(deviceID: 0x0010_005A, zoneCode: 0x02),
                AuraZone.logo.rawValue: spec(deviceID: 0x0010_005A, zoneCode: 0x03)
            ],
            commit: nil,
            offFrames: nil,
            isExperimental: true,
            notes: "端点映射需按机型确认；桥 agent 收到 deviceID+params 后调用 AsusACPI.DeviceSet。"
        )
    }

    // MARK: - 磁盘加载

    public static func userProtocolsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AuraPilot/protocols", isDirectory: true)
    }

    /// 内置 + 用户自定义（用户同 id 覆盖内置）
    public static func loadAll() -> [ProtocolProfile] {
        var result = builtInProfiles()
        let directory = userProtocolsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? decoder.decode(ProtocolProfile.self, from: data) else {
                continue
            }
            if let index = result.firstIndex(where: { $0.id == profile.id }) {
                result[index] = profile
            } else {
                result.append(profile)
            }
        }
        return result
    }

    /// 首次运行时释放一份可编辑样例，降低校准门槛
    public static func writeSampleIfNeeded() {
        let directory = userProtocolsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sample = directory.appendingPathComponent("example-hid-aura.json")
        guard !FileManager.default.fileExists(atPath: sample.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(genericHID()) {
            try? data.write(to: sample, options: .atomic)
        }
    }
}
