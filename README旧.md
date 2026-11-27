# AuraPilot · 极光领航
本程序在G64JVR适用，也许同样适用于USB HID协议内置键盘的ROG笔记本电脑。
macOS 原生的 ASUS ROG 灯光控制台。粉色系界面，菜单栏常驻，后台是一套可替换传输层的灯效引擎，面向黑苹果机型与 macOS 用户。

> **背景说明**：Windows 上的 G-Helper 无法直接移植到 macOS——它是 C#/WinForms，笔记本灯光走 ACPI-WMI，而 XNU 内核没有这条栈。本项目在 macOS 侧**独立重写**后台与界面，并把传输层做成可替换：USB HID（原生可用）/ 远程桥（另一台机器代理 ACPI）/ 演示模式。
> 详细论证见 [`docs/01-可行性报告.md`](docs/01-可行性报告.md)。

![AuraPilot 界面预览](docs/ui-preview.png)

---

## 当前状态

后台已完成，前台为可用的第一版。

| 模块 | 状态 | 说明 |
|---|---|---|
| 灯效引擎 | ✅ | 9 种模式（静态/呼吸/循环/彩虹/星光/流星雨/高光/激光/涟漪），30fps 软件渲染，确定性可测 |
| 协议包系统 | ✅ | JSON DSL（`$mode/$r/$g/$b/$brightness/$speed/$sum8`），改机型不用改代码 |
| HID 传输 | ✅ | IOHIDDevice 枚举 + Feature/Output 报告写入，支持裸报文校准 |
| 远程桥传输 | ✅ | HTTP JSON 客户端，供"Mac 控制另一台 ASUS 机器"使用 |
| 演示传输 | ✅ | 无硬件时全速跑通 UI 与引擎 |
| 传感器 | ✅ | AppleSMC 只读：CPU/GPU 温度、风扇转速；缺测显示"—" |
| 配置与预设 | ✅ | JSON 原子写入、损坏自愈、内置 5 套预设 + 自定义 |
| 状态栏 | ✅ | 实时温度、总开关、模式、颜色轮换、右键菜单 |
| 主窗口 | ✅ | 概览 / 灯效 / 预设 / 诊断 四页 |
| 界面主题 | ✅ | 跟随系统自动切换深色；日常色五套主题：樱花粉 / 浅粉 / 极简白 / 天青蓝 / 五彩缤纷，可持久化 |
| 风扇曲线 / 功耗模式 | ❌ | macOS 不可达，明确不做（见可行性报告第 3 节） |
| AniMe Matrix | ❌ | 暂不支持 |

### 验证状态

| 部分 | 状态 |
|---|---|
| AuraCore 全模块 | 已用 Swift 5.10 编译通过 |
| 单元测试 | 56 个全部通过（渲染器 / 灯效 / 引擎 / 配置 / 协议库 / rogauracore / Falchion 报文） |
| `HIDTransport` / `SMCSensorReader` | 已用 IOKit 桩做类型检查通过（真机行为需实测） |
| 内置键盘协议包 | 已按 G-Helper `app/USB/Aura.cs` + macRogAuraCore 双向核对：灯效 Output / 亮度 Feature 补齐 64B / primers，报文布局有单测锁定 |
| App 层（SwiftUI / AppKit） | 语法解析通过，未在本机构建；需在 Xcode 里首次编译确认 |
| 真实硬件 | **未实测**，协议包常量需按机型校准 |

---

## 快速开始

### 预编译包

`Releases/` 目录下附带 `AuraPilot-v0.20.zip`，解压后把 `App/AuraPilot.app` 拖入「应用程序」即可首次体验；首次打开需在「系统设置 → 隐私与安全性」允许未签名应用运行。

### 从源码编译

依赖：Xcode 15+ / Swift 5.10+、macOS 13+。

```bash
# 进入源码目录
cd Sources

# 命令行探针：列出 HID 设备、匹配协议包
swift run aura-probe devices

# 列出内置协议包
swift run aura-probe profiles

# 读取一次温度 / 风扇转速
swift run aura-probe sensors

# 真机下发一帧（示例：内置键盘静态粉色）
swift run aura-probe frame --profile mac-rogauracore-keyboard \
    --mode solid --color "#FF5C88" --bright 0.8
```

第一次启动会进入**演示模式**（状态栏图标 + 粉色主界面），此时不改动任何硬件，仅用于预览界面与灯效引擎。

---

## 目录结构

```
AuraPilot-git/
├─ App/                     预编译 AuraPilot.app
├─ Releases/                版本打包 zip
├─ Sources/                 Swift 源码（探针 / 传输 / 协议库 / 界面 / 主题）
│  ├─ main.swift            aura-probe 命令行诊断工具入口
│  ├─ HIDTransport.swift    USB HID 传输层
│  ├─ ProtocolLibrary.swift 协议包与报文组装
│  ├─ OverviewView.swift    SwiftUI 概览页
│  └─ Theme.swift           界面配色与主题
├─ docs/                    设计文档与截图
│  ├─ 01-可行性报告.md
│  ├─ 02-架构.md
│  ├─ 03-硬件协议笔记.md
│  └─ ui-preview.png
├─ .gitignore
├─ LICENSE
└─ README.md
```

---

## 接真机

### 外置 ROG 键盘 / 鼠标（USB HID）

运行探针拿到接口后，按 [`docs/03-硬件协议笔记.md`](docs/03-硬件协议笔记.md) 第 2 节校准报文，把协议包放到 `~/Library/Application Support/AuraPilot/protocols/` 即可，不用重新编译。

### 笔记本内置键盘（rogauracore 协议，已内置）

部分 ROG 机型把内置键盘的 Aura 控制器暴露成 USB HID 接口，macOS 可以直接驱动——协议包已逐字节核对并内置为 `mac-rogauracore-keyboard`（17 字节 feature report，支持 静态 / 双色呼吸 / 色彩循环 + 4 档亮度）。

已知可用 PID：`0x1854`(GL553/GL753)、`0x1869`(GL503/FX503/GL703)、`0x1866`(GL504/GL703/GX501/GM501)、`0x19B6`(GA503)。先跑探针枚举：

- 列表出现上述 PID → 直接可用，软件动态灯效（彩虹/涟漪等）由引擎逐帧下发；
- 出现其它 `0x0B05:xxxx` 接口 → 把 PID 加进协议包 `productIDs` 试一次（JSON 外置，不用重编译）；
- 什么都没有 → 该机型内置灯走 ACPI-WMI，回退远程桥方案。

### 笔记本灯条 / Logo 灯（远程桥）

需要一台能跑 ACPI-WMI 的机器做 agent（Windows 或 Linux），Mac 端在配置文件打开 `settings.bridge`：

```json
"bridge": { "isEnabled": true, "baseURL": "http://192.168.1.20:8712", "token": null, "timeout": 2.0 }
```

接口仅两个：`GET /v1/aura/info`、`POST /v1/aura/frame`，详见协议笔记第 4 节。

---

## 设计取舍

- **不仿 Windows 界面**：状态栏是主入口，主窗口是单页四标签，符合 macOS 习惯；
- **粉色是品牌色，不是满屏粉**：`#FF4F87` 做主色，浅色底 `#FFF8FA`，深色自动降饱和；
- **不确定就不显示**：传感器读不到就显示"—"，不会编造数字；
- **假功能不如没有**：风扇曲线、功耗模式直接标注不支持，不做"点了没反应"的按钮；
- **协议包外置**：真机适配是数据问题，不是代码问题。

---

## 路线图

1. **协议校准**：接入一台真实 ROG 键盘，把 `generic-hid-aura` 的偏移量落成可用包；
2. **逐键渲染**：`perKey` 能力已预留，需要键盘布局表 + 批量帧；
3. **远程桥 agent**：Windows 侧 30 行 C# 封装 `AsusACPI.DeviceSet`；
4. **AniMe Matrix**：USB 协议 + 帧缓冲，工作量大，单独立项；
5. **开机自启**：`SMAppService` 注册登录项。

---

## 致谢

本项目的协议调研、报文核对与界面实现，站在了以下开源项目与工具的肩膀上：

- **[G-Helper](https://github.com/seerge/g-helper)**（seerge/g-helper，GPL-3.0）：Windows 端 ROG 控制工具，Aura USB HID 报文布局、模式定义与协议枚举的核心参考来源；
- **[macRogAuraCore](https://github.com/black-dragon74/macRogAuraCore)**（black.dragon74 / Nick，MIT）：macOS 下 ROG 键盘灯命令行控制参考，内置键盘协议包逐字节核对的依据；
- **WorkBuddy**：项目协作、资料整理与流程辅助；
- **豆包 AI**：方案讨论、代码生成、文档撰写与调试辅助。

> 协议对照：G-Helper 为 GPL-3.0，本项目作为其协议逻辑的衍生参考作品，整体以 GPL-3.0 发布；macRogAuraCore 为 MIT 宽松协议，其协议信息可被自由引用。

---

## 免责声明

"ASUS"、"ROG"、"TUF"、"Armoury Crate" 均为华硕电脑股份有限公司的商标。本项目为个人非官方工具，与华硕无任何关联，仅出于互操作目的使用公开协议信息。修改灯光 / 硬件设置存在影响设备的风险，请自行评估。

## 许可证

本项目以 **GNU General Public License v3.0** 发布，详见 [`LICENSE`](LICENSE)。
