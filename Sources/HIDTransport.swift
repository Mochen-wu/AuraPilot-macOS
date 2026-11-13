import Foundation
import IOKit
import IOKit.hid

/// 枚举到的 HID 设备（用于诊断与协议校准）
public struct HIDDeviceDescriptor: Hashable, Sendable, Identifiable {
    public var vendorID: Int
    public var productID: Int
    public var product: String
    public var manufacturer: String
    public var serial: String?
    public var usagePage: Int
    public var usage: Int
    public var maxFeatureReportSize: Int
    public var locationID: Int

    public var id: String { "\(vendorID)-\(productID)-\(locationID)" }

    public var usbIdentifier: String {
        String(format: "0x%04X:0x%04X", vendorID, productID)
    }

    public var summary: String {
        "\(product) [\(usbIdentifier)] usage=\(String(format: "0x%04X/0x%02X", usagePage, usage)) feature=\(maxFeatureReportSize)B"
    }
}

/// macOS 上唯一能真正控制灯光的原生通道：USB HID。
///
/// 说明：内置键盘的**灯效控制**走 HID（N-KEY Device，PID 0x19B6，Aura 接口在
/// usage page 0xFF89），握手/亮度/颜色帧都能发；只有 EC 层的电源、电池、开机策略
/// 走 ACPI-WMI（见 docs/03-硬件协议笔记.md），那部分 macOS 无栈可用。
/// 外接 ROG 键盘（Falchion 等）的 Aura 接口在 usage page 0xFF00。
public final class HIDTransport: AuraTransport {
    public let kind: TransportKind = .hid
    public var logHandler: ((String) -> Void)?

    /// Aura 控制接口可能出现的厂商用途页。
    /// 0xFF00：外接 ROG（Falchion RX LP 实测）
    /// 0xFF89：ASUS 内置键盘 N-KEY Device（descriptor 实测 usage page 0xFF89 / usage 0x10）
    /// 两个都要匹配；但绝不能出现"不带用途页"的条目，否则 IOHIDManagerOpen 整体 0xE00002E2。
    static let auraUsagePages: [Int] = [0xFF00, 0xFF89]

    private let profile: ProtocolProfile
    private var manager: IOHIDManager?
    /// 同一 VID/PID 可能暴露多个接口（键盘输入 / Consumer Control / Aura 控制），
    /// macRogAuraCore 的做法是对所有匹配接口广播，这里保持一致。
    private var devices: [IOHIDDevice] = []
    /// 打分最高的「主接口」，灯效事务只认它的写入结果。
    ///
    /// 为什么必须区分：APPLY(5D B4) 之后 N-KEY 的 Aura 接口会从 USB 掉线重枚举，
    /// 常驻进程里旧句柄随即失效；但同机其它接口仍会接受 Feature Report 并返回 OK。
    /// 旧写法只要「任意一个接口成功」就算这帧成功，于是颜色帧被写到不控灯的接口、
    /// 事务不抛错、recover() 永远不触发 —— 表现就是「总开关第一次能用，之后改颜色
    /// /模式/预设全部没反应」。现在主接口一失败就抛错，交给 recover() 重新枚举。
    private var primaryDevice: IOHIDDevice?
    public private(set) var descriptor: HIDDeviceDescriptor?
    private var isOpen = false
    /// 防止 recover() → probe() → 写初始化帧 → 失败 → recover() 的递归
    private var isRecovering = false

    /// 是否在 probe 时对每个接口调用 IOHIDDeviceOpen。
    ///
    /// 默认 **false**：macRogAuraCore 就只 `IOHIDManagerOpen`、从不 open device，
    /// 而它在真机上能正常改颜色。我们之前每个接口都 `IOHIDDeviceOpen`，
    /// 很可能正是这条让 SetReport 走到另一条路径、命令返回 OK 但灯不响应。
    public let openDevicesOnProbe: Bool

    /// 用户在界面上手动指定的接口（`HIDDeviceDescriptor.id`）。nil 表示自动打分挑选。
    public let preferredDeviceID: String?

    public init(profile: ProtocolProfile,
                openDevicesOnProbe: Bool = false,
                preferredDeviceID: String? = nil) {
        self.profile = profile
        self.openDevicesOnProbe = openDevicesOnProbe
        self.preferredDeviceID = preferredDeviceID
    }

    deinit {
        close()
    }

    // MARK: - 枚举

    /// 列出当前系统上所有 ASUS（VID 0x0B05）HID 接口，给 aura-probe 与诊断面板用。
    public static func discover(vendorIDs: Set<Int> = [0x0B05]) -> [HIDDeviceDescriptor] {
        // macOS SDK 中 IOHIDManagerCreate 返回非可选值（CF_RETURNS_RETAINED 且非空），不能 guard let
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var matching: [[String: Any]] = []
        for vendorID in vendorIDs {
            // macOS 26 实测：匹配字典里出现任何**不带 kIOHIDPrimaryUsagePageKey** 的条目
            // （裸 VID 或 VID+PID），整个 IOHIDManagerOpen 都会返回 0xE00002E2。
            // 所以只放带用途页的条目，但**用途页不止一个**：
            //   0xFF00 —— 外接 ROG（Falchion 等）的 Aura 控制接口
            //   0xFF89 —— 内置键盘 N-KEY Device 的 Aura 控制接口（descriptor 实测 usage 0xFF89/0x10）
            // 只写 0xFF00 会让内置键盘永远匹配不到，App 就只认外接键盘。
            for page in Self.auraUsagePages {
                matching.append([
                    kIOHIDVendorIDKey: vendorID,
                    kIOHIDPrimaryUsagePageKey: page
                ])
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var result: [HIDDeviceDescriptor] = []
        for device in deviceSet {
            result.append(describe(device))
        }
        return result.sorted { $0.locationID < $1.locationID }
    }

    /// 打印每个 ASUS HID 接口的**报告描述符解析结果**（report ID / 各类型字节数）。
    ///
    /// 这是判断「该发 16B 还是 17B、0x5D 到底声明成 Feature 还是 Output」的唯一可靠依据：
    /// IOHIDDeviceSetReport 只按描述符校验长度，长度不对就是 0x10000003。
    public static func dumpReportDescriptors(vendorIDs: Set<Int> = [0x0B05]) -> [String] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var matching: [[String: Any]] = []
        for vendorID in vendorIDs {
            // 同 probe()：不带用途页的条目会让整个 IOHIDManagerOpen 报 0xE00002E2
            for page in Self.auraUsagePages {
                matching.append([kIOHIDVendorIDKey: vendorID, kIOHIDPrimaryUsagePageKey: page])
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !deviceSet.isEmpty else {
            return ["未发现 ASUS（0x0B05）HID 设备"]
        }

        var lines: [String] = []
        for device in deviceSet.sorted(by: { describe($0).locationID < describe($1).locationID }) {
            let info = describe(device)
            guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
                lines.append("• \(info.summary)  描述符读取失败")
                continue
            }
            lines.append("• \(info.summary)  描述符 \(data.count) 字节")
            let rows = parseReportDescriptor([UInt8](data))
            if rows.isEmpty {
                lines.append("    （未解析出任何报告）")
            } else {
                lines.append(contentsOf: rows.map { "    " + $0 })
            }
        }
        return lines
    }

    /// 极简 HID 报告描述符解析：只关心 Report ID 与 input/output/feature 的位宽。
    static func parseReportDescriptor(_ bytes: [UInt8]) -> [String] {
        var reportID: UInt8 = 0
        var reportSize = 0
        var reportCount = 0
        var bits: [UInt8: [String: Int]] = [:]
        var index = 0

        while index < bytes.count {
            let prefix = bytes[index]
            if prefix == 0xFE {                       // 长条目
                guard index + 2 < bytes.count else { break }
                index += 3 + Int(bytes[index + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let length = sizeCode == 3 ? 4 : sizeCode
            let type = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            guard index + 1 + length <= bytes.count else { break }
            var value = 0
            for offset in 0..<length {
                value |= Int(bytes[index + 1 + offset]) << (8 * offset)
            }
            index += 1 + length

            switch (type, tag) {
            case (1, 0x8):                            // Global: Report ID
                reportID = UInt8(value & 0xFF)
            case (1, 0x7):                            // Global: Report Size（位）
                reportSize = value
            case (1, 0x9):                            // Global: Report Count
                reportCount = value
            case (0, 0x8), (0, 0x9), (0, 0xB):        // Main: Input / Output / Feature
                let kind = tag == 0x8 ? "input" : (tag == 0x9 ? "output" : "feature")
                var entry = bits[reportID] ?? [:]
                entry[kind, default: 0] += reportSize * reportCount
                bits[reportID] = entry
            default:
                break
            }
        }

        return bits.keys.sorted().map { id in
            let entry = bits[id] ?? [:]
            func bytesOf(_ key: String) -> String {
                guard let value = entry[key], value > 0 else { return "—" }
                return "\(Int(ceil(Double(value) / 8.0)))B"
            }
            return String(format: "ReportID 0x%02X : input %@ / output %@ / feature %@",
                          id, bytesOf("input"), bytesOf("output"), bytesOf("feature"))
        }
    }

    static func describe(_ device: IOHIDDevice) -> HIDDeviceDescriptor {        func intProperty(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
        }
        func stringProperty(_ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
        }
        return HIDDeviceDescriptor(
            vendorID: intProperty(kIOHIDVendorIDKey),
            productID: intProperty(kIOHIDProductIDKey),
            product: stringProperty(kIOHIDProductKey),
            manufacturer: stringProperty(kIOHIDManufacturerKey),
            serial: IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
            usagePage: intProperty(kIOHIDPrimaryUsagePageKey),
            usage: intProperty(kIOHIDPrimaryUsageKey),
            maxFeatureReportSize: intProperty(kIOHIDMaxFeatureReportSizeKey),
            locationID: intProperty(kIOHIDLocationIDKey)
        )
    }

    // MARK: - 打开

    /// 连接设备。这一个 APPLY 之后接口会掉线重枚举（描述符 0x5D 声明了 63B feature /
    /// 63B output，发完提交帧后 USB 会短暂消失），所以枚举本身要重试几次。
    public func probe() throws -> DeviceInfo {
        var lastError: Error = AuraError.deviceNotFound("未发现任何匹配的 Aura HID 设备")
        for attempt in 0..<3 {
            do {
                return try probeOnce()
            } catch {
                lastError = error
                if attempt < 2 {
                    // 设备刚被上一轮事务踢下线时，通常 0.3~1s 内会重新枚举出来
                    Thread.sleep(forTimeInterval: 0.45)
                }
            }
        }
        throw lastError
    }

    private func probeOnce() throws -> DeviceInfo {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        var matching: [[String: Any]] = []
        for vendorID in profile.vendorIDs {
            if profile.productIDs.isEmpty {
                for page in Self.auraUsagePages {
                    matching.append([
                        kIOHIDVendorIDKey: vendorID,
                        kIOHIDPrimaryUsagePageKey: page
                    ])
                }
            } else {
                for productID in profile.productIDs {
                    // 注意：macOS 26 实测，匹配字典里只要出现**不带用途页**的
                    // [VID+PID] 条目，整个 IOHIDManagerOpen 就返回 0xE00002E2
                    // （kIOReturnNotPrivileged），把同一批里本来能用的条目也毒死。
                    // 所以只放带用途页的条目，且 0xFF00 / 0xFF89 两个页都要放：
                    // 内置键盘的 Aura 接口在 0xFF89，漏了就等于"没有内置键盘"。
                    for page in Self.auraUsagePages {
                        matching.append([
                            kIOHIDVendorIDKey: vendorID,
                            kIOHIDProductIDKey: productID,
                            kIOHIDPrimaryUsagePageKey: page
                        ])
                    }
                }
            }
        }
        guard !matching.isEmpty else {
            throw AuraError.deviceNotFound("协议包 \(profile.id) 没有配置 VID")
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw AuraError.hidFailure(code: openResult, context: "IOHIDManagerOpen")
        }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !deviceSet.isEmpty else {
            throw AuraError.deviceNotFound("VID \(profile.vendorIDs.map { String(format: "0x%04X", $0) }) 的 Aura HID 接口")
        }

        // 多接口设备很常见：N-KEY 键盘会同时暴露普通键盘、Consumer Control、Aura 控制接口。
        // 按「厂商用途页 > 满足协议最小报告长度 > 报告更大」打分，避免把灯效帧发给键盘输入接口。
        let candidates = deviceSet.map { ($0, HIDTransport.describe($0)) }
        let minimum = profile.minimumReportLength
        func score(_ item: (IOHIDDevice, HIDDeviceDescriptor)) -> Int {
            let info = item.1
            var value = 0
            if Self.auraUsagePages.contains(info.usagePage) { value += 100 }
            // rogauracore 的 Aura 控制接口在产品名里就叫 N-KEY Device
            let name = info.product.lowercased()
            if name.contains("n-key") || name.contains("aura") || name.contains("rog") { value += 60 }
            if minimum > 0, info.maxFeatureReportSize >= minimum { value += 50 }
            value += min(info.maxFeatureReportSize, 64)
            return value
        }
        var ranked = candidates.sorted { score($0) > score($1) }
        // 用户手动指定的接口优先。找不到（没插 / 换了口）就回退自动选择，不阻断连接。
        if let preferred = preferredDeviceID {
            if let index = ranked.firstIndex(where: { $0.1.id == preferred }) {
                let picked = ranked.remove(at: index)
                ranked.insert(picked, at: 0)
                logHandler?("已按用户选择固定接口：\(picked.1.summary)")
            } else {
                logHandler?("用户指定的接口 \(preferred) 当前不在线，回退自动选择")
            }
        }
        for (_, info) in ranked {
            logHandler?("候选接口：\(info.summary)")
        }
        guard let best = ranked.first?.1 else {
            throw AuraError.deviceNotFound("可用的 Aura HID 接口")
        }

        // macRogAuraCore 从不 IOHIDDeviceOpen，只靠 IOHIDManagerOpen 就能 SetReport。
        // 默认跟随它（openDevicesOnProbe = false）；只有需要 Output Report 的机型
        // 才把该开关打开（部分固件要求设备已 open 才接受 output）。
        if openDevicesOnProbe {
            for (candidate, info) in ranked {
                let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                if result != kIOReturnSuccess {
                    logHandler?("IOHIDDeviceOpen 失败（继续尝试发送）：\(info.summary) code=\(result)")
                }
            }
        }
        devices = ranked.map { $0.0 }
        primaryDevice = ranked.first?.0
        isOpen = !devices.isEmpty
        descriptor = best
        logHandler?("已连接 \(devices.count) 个 Aura 接口，主接口：\(best.summary)（openDevice=\(openDevicesOnProbe)）")

        // 初始化握手（如 rogauracore 的 "ASUS Tech.Inc." 帧），失败不阻断连接
        do {
            for initFrame in profile.initFrames ?? [] {
                let bytes = try FrameRenderer.render(
                    ZoneFrame(zone: .keyboard, mode: .solid, primary: .off, secondary: .off,
                              brightness: 0, speed: 0, elapsed: 0),
                    spec: initFrame
                )
                try write(bytes, spec: initFrame, devices: devices)
            }
        } catch {
            logHandler?("初始化帧发送失败：\(error.localizedDescription)")
        }

        var capabilities = profile.capabilities
        capabilities.zones = Set(profile.zones)

        return DeviceInfo(
            id: best.id,
            name: best.product.isEmpty ? profile.displayName : best.product,
            vendor: best.manufacturer.isEmpty ? "ASUSTeK COMPUTER INC." : best.manufacturer,
            serial: best.serial,
            kind: .hid,
            capabilities: capabilities,
            note: profile.isExperimental ? "协议包未经真机校准，若无效请用 aura-probe 校准 template" : profile.notes
        )
    }

    /// 按协议包顺序尝试连接，返回第一个成功的
    public static func makeBest(profiles: [ProtocolProfile]) throws -> HIDTransport {
        var lastError: Error = AuraError.deviceNotFound("未发现任何匹配的 Aura HID 设备")
        for profile in profiles {
            let transport = HIDTransport(profile: profile)
            do {
                _ = try transport.probe()
                return transport
            } catch {
                transport.close()
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - 下发

    public func apply(_ frame: ZoneFrame) throws {
        try applyBatch([frame])
    }

    /// 一次事务下发多个灯区。这是**唯一正确**的多灯区下发方式，原因见 performBatch。
    public func applyBatch(_ frames: [ZoneFrame]) throws {
        guard isOpen, !devices.isEmpty else { throw AuraError.transportClosed }
        guard !frames.isEmpty else { return }

        // 帧级日志：把每次事务实际下发的模式 / 颜色 / 亮度打到终端。
        // 之前所有日志都只有"配置层"信息，排查「改颜色没反应」只能靠猜；
        // 现在一眼就能看出是"帧没发出去"还是"帧发了颜色不对"还是"接口写失败"。
        let digest = frames.map { frame in
            "\(frame.zone.shortName)=\(frame.mode.displayName)/\(frame.primary.hexString.uppercased())/\(Int((frame.brightness * 100).rounded()))%"
        }.joined(separator: " ")
        logHandler?("📤 下发 \(frames.count) 帧：\(digest)")

        do {
            try performBatch(frames)
            logHandler?("✅ 事务完成（亮度 + 灯效 + SET/APPLY 已提交到主接口）")
        } catch {
            // 这台机器的 Aura 接口在收到 APPLY(5D B4) 之后会**从 USB 上掉线重枚举**，
            // 旧句柄全部失效（后续 SetReport 一律 0x10000003）。所以不能只重试单条报文，
            // 必须重新枚举后把「亮度→灯效→SET→APPLY」整个事务重打一遍。
            logHandler?("⚠️ 主接口写入失败：\(error.localizedDescription) → 重新枚举后整体重打")
            guard recover() else { throw error }
            try performBatch(frames)
            logHandler?("✅ 重打完成（SET/APPLY 已提交）")
        }
    }

    /// 一次完整的灯效事务。顺序不可换：
    /// 全局亮度(0x5A) → 各灯区灯效(0x5D B3) → SET(0x5D B5) → APPLY(0x5D B4)。
    ///
    /// **为什么必须批量**：固件是"写缓冲区 → SET 提交 → APPLY 生效"的模型，
    /// 缓冲区只有一份。以前每个灯区各自跑一遍完整事务，第二个灯区一 APPLY，
    /// 第一个灯区（键盘）就被覆盖——表现就是"灯条/Logo 一开，键盘就不亮了"。
    /// 正确做法是所有灯区帧都写进同一份缓冲区，最后只 APPLY 一次。
    private func performBatch(_ frames: [ZoneFrame]) throws {
        var specs: [(ZoneFrame, AuraFrameSpec)] = []
        for frame in frames {
            guard let spec = profile.frame(for: frame.zone) else { continue }
            switch spec.channel.kind {
            case .hidFeature, .hidOutput:
                specs.append((frame, spec))
            case .asusDeviceSet:
                throw AuraError.unsupported("该协议包使用 ACPI-WMI 通道，macOS 无法直接执行；请启用远程桥 agent")
            }
        }
        guard !specs.isEmpty else { return }

        // 1. 亮度帧是**设备级**的（0x5A 一条管所有灯区），只发一次，
        //    否则三个灯区各发一条，最后一条会把前面的亮度覆盖掉。
        let brightnessSource = specs.first { $0.0.zone == .keyboard } ?? specs[0]
        for attached in brightnessSource.1.attached ?? [] {
            let attachedBytes = try FrameRenderer.render(brightnessSource.0, spec: attached)
            try write(attachedBytes, spec: attached, devices: devices)
        }

        // 2. 各灯区灯效帧写进同一份缓冲区（顺序无关，但不能中途 APPLY）
        //
        // 单个灯区失败**不能中断整批**：这台机器可能根本没有灯条/Logo 硬件，
        // 固件对未知灯区返回错误时，键盘帧已经写进缓冲区，仍应继续提交。
        // 否则就退化成"一次灯条写失败 → 键盘也不亮"。
        var firstZoneError: Error?
        var written = 0
        for (frame, spec) in specs {
            do {
                let bytes = try FrameRenderer.render(frame, spec: spec)
                try write(bytes, spec: spec, devices: devices)
                written += 1
            } catch {
                if firstZoneError == nil { firstZoneError = error }
                logHandler?("灯区 \(frame.zone.displayName) 下发失败（跳过，继续其它灯区）：\(error.localizedDescription)")
            }
        }
        if written == 0, let firstZoneError { throw firstZoneError }

        // 3. 提交：SET 一次 + APPLY 一次
        let anchor = brightnessSource.0
        for commit in profile.commitFrames ?? [] {
            let commitBytes = try FrameRenderer.render(anchor, spec: commit)
            try write(commitBytes, spec: commit, devices: devices)
        }
        if let commit = profile.commit {
            let commitBytes = try FrameRenderer.render(anchor, spec: commit)
            try write(commitBytes, spec: commit, devices: devices)
        }
    }

    /// 重新枚举设备。APPLY 之后接口会锁死，所有 SetReport 返回 0x10000003，
    /// 只有关掉 manager 重新 open 才能恢复——App 里每一帧事务都要靠这个续命。
    @discardableResult
    public func recover() -> Bool {
        guard !isRecovering else { return false }
        isRecovering = true
        defer { isRecovering = false }
        close()
        do {
            _ = try probe()
            logHandler?("接口已重新枚举")
            return true
        } catch {
            logHandler?("重新枚举失败：\(error.localizedDescription)")
            return false
        }
    }

    private func write(_ bytes: [UInt8], spec: AuraFrameSpec, devices allDevices: [IOHIDDevice]) throws {
        let channel = spec.channel
        let reportType: IOHIDReportType = channel.kind == .hidOutput ? kIOHIDReportTypeOutput : kIOHIDReportTypeFeature
        // 与 macRogAuraCore / HidSharp 一致：缓冲区首字节是 report ID，长度包含它
        var payload: [UInt8] = channel.reportID != 0 ? [channel.reportID] + bytes : bytes
        // 本机 N-KEY 键盘的 0x5D / 0x5A 在描述符里声明的是 **63 字节 payload**
        // （kIOHIDMaxFeatureReportSize = 64 含 report ID）。长度不足时 SetReport 会
        // 返回 OK 但设备静默丢弃，所以必须补齐到 64；超过 63 则直接报 0x10000003。
        if spec.padToMaxReportLength {
            let target = descriptor?.maxFeatureReportSize ?? 0
            if target > payload.count {
                payload += [UInt8](repeating: 0, count: target - payload.count)
            }
        }
        // 常驻进程里只认主接口：APPLY 之后它会掉线重枚举，旧句柄失效。
        // 若继续对所有接口广播、并且「任一成功就算成功」，无关接口返回的 OK
        // 会掩盖主接口的失败，帧写到不控灯的接口上、recover() 也不会触发。
        let targets: [IOHIDDevice] = primaryDevice.map { [$0] } ?? allDevices
        var lastError: IOReturn = kIOReturnError
        var anySuccess = false
        var failedCodes: [String] = []
        for device in targets {
            let result = payload.withUnsafeBufferPointer { pointer -> IOReturn in
                guard let base = pointer.baseAddress else { return kIOReturnError }
                return IOHIDDeviceSetReport(
                    device,
                    reportType,
                    CFIndex(channel.reportID),
                    base,
                    CFIndex(pointer.count)
                )
            }
            if result == kIOReturnSuccess {
                anySuccess = true
            } else {
                lastError = result
                failedCodes.append(String(format: "0x%08X", result))
            }
        }
        if !failedCodes.isEmpty {
            logHandler?("   ⚠️ \(spec.name) 主接口写入失败：\(failedCodes.joined(separator: ",")) → 交给 recover() 重新枚举")
        }
        guard anySuccess else {
            throw AuraError.hidFailure(
                code: lastError,
                context: "IOHIDDeviceSetReport(\(spec.name), \(payload.count)B × \(targets.count) 接口, 设备声明 \(descriptor?.maxFeatureReportSize ?? 0)B)"
            )
        }
    }

    /// 校准时用的裸发送：直接把字节敲到设备上，不做任何协议解释
    public func sendRaw(_ bytes: [UInt8], reportID: UInt8 = 0, feature: Bool = true) throws {
        guard isOpen, !devices.isEmpty else { throw AuraError.transportClosed }
        let spec = AuraFrameSpec(name: "raw", channel: feature ? .feature(reportID) : .output(reportID),
                                 length: bytes.count, template: [])
        try write(bytes, spec: spec, devices: devices)
    }

    /// 校准专用：原样发送缓冲区（**不再自动拼接 report ID**），并回传每个接口的 IOReturn。
    /// `aura-probe verify` 用它穷举「带不带 ID / Feature 还是 Output / 补齐到 64 字节」等变体。
    public func sendExact(_ buffer: [UInt8], reportID: UInt8, feature: Bool) -> [(String, Int32)] {
        guard isOpen, !devices.isEmpty else { return [("未连接", -1)] }
        let reportType: IOHIDReportType = feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
        var out: [(String, Int32)] = []
        for device in devices {
            let name = HIDTransport.describe(device).summary
            let result = buffer.withUnsafeBufferPointer { pointer -> IOReturn in
                guard let base = pointer.baseAddress else { return kIOReturnError }
                return IOHIDDeviceSetReport(device, reportType, CFIndex(reportID), base, CFIndex(pointer.count))
            }
            out.append((name, Int32(result)))
        }
        return out
    }

    public func close() {
        for device in devices {
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices = []
        primaryDevice = nil
        manager = nil
        isOpen = false
    }
}
