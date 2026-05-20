# chenniXOS

基于 AtlasOS 深度定制的 Windows 11 优化 Playbook，主打游戏性能、隐私保护和日常易用性。

## 支持版本

- Windows 11 24H2 (Build 26100)
- Windows 11 25H2 (Build 26200)

## 安装前置条件

- Windows Defender 已切换（可通过 AME Wizard 完成）
- 无第三方杀毒软件
- 网络连接正常
- 无待处理的 Windows 更新
- UCPD 已禁用
- 接通电源

## 安装

1. 下载 [AME Wizard](https://ameliorated.io/)
2. 获取 chenniXOS 的 `.apbx` 文件（见 [Releases](https://github.com/chenni0828/chenniXOS/releases)）
3. 以管理员身份运行 AME Wizard，选择 chenniXOS Playbook
4. 按照界面提示选择你需要的配置选项
5. 等待安装完成，约 10 分钟

## 安装选项

安装时会让你选这些：

| 选项 | 默认值 | 说明 |
|------|--------|------|
| Windows Defender | 启用 | 禁用会降低安全性，仅高级用户考虑 |
| 缓解措施 | Windows 默认 | 禁用可能损害现代 CPU 性能 |
| 自动更新 | 禁用 | 禁用可避免不可预期的兼容性问题 |
| 前台优先级 | 2 | 影响前台与后台进程的 CPU 时间分配 |
| 禁用 SysMain | 可选 | SSD 用户建议禁用 |
| 禁用核心隔离 | 可选 | 即内存完整性（VBS） |
| 禁用设置同步 | 可选 | 需微软账户同步时勿勾选 |
| 移除 Edge | 可选 | 移除后仍可重新安装 |
| 移除 OneDrive | 可选 | 同上 |
| 移除截图工具 | 可选 | 同上 |
| 禁用休眠 | 可选 | 释放休眠文件占用的磁盘空间 |
| 电源限制 | 可选 | 禁用 Power Throttling，追求性能可关闭 |
| 超级低延迟 | 可选 | 深度低延迟优化，详见下方说明 |
| 软件安装来源 | 本地 | 本地使用内置安装包，在线从 GitHub 拉取最新版 |
| 鼠标加速 | 禁用 | 禁用可获得 1:1 原始输入，FPS 玩家首选 |

安装完成后，桌面会出现 **chenniX** 文件夹，里面可以随时切换以上设置。

## 项目结构

```
├── playbook.conf              # Playbook 主配置
├── Configuration/             # YAML 配置（所有优化逻辑）
│   ├── main.yml               # 执行编排
│   ├── core/                  # 核心步骤：环境、软件、服务、组件、默认设置
│   └── tweaks/                # 优化步骤：网络、性能、隐私、易用性、安全、精简、脚本
├── Executables/               # 脚本、模块和资源
│   ├── chenniXDesktop/        # 桌面配置文件夹（安装后出现在桌面上）
│   ├── chenniXModules/        # PowerShell 模块、注册表、CAB 包、工具
│   ├── Software/              # 本地安装包（7-Zip、VC++、DirectX、NanaZip）
│   └── Themes/                # chenniX 暗色主题
└── README.md
```

## 优化内容一览

### 性能
- 移除 30+ 预装 AppX（Teams、Copilot、Clipchamp、Xbox、Skype、Maps 等）
- 禁用不必要的后台进程和服务
- 禁用容错堆（FTH）、诊断日志、电源效率诊断
- .NET NGEN 预编译加速 PowerShell 启动
- 可选：禁用 SysMain / 核心隔离 / 节能 / 休眠
- 可选：前台优先级分离值调整（2 / 26 / 38）

### 隐私
- 禁用 Windows 遥测（AllowTelemetry=0）
- 禁用 7 个遥测服务
- 禁用 PowerShell / .NET / NVIDIA / Office 遥测
- 禁用 Copilot、Recall、AI 分析
- 禁用搜索网络结果、Bing 搜索
- 禁用广告、活动 Feed、应用追踪
- 禁用错误报告、AppCompat
- 禁用设备名称遥测、DiagTrack ETL 日志
- 禁用位置服务、设备监控

### 易用性
- 移除 Windows 广告和推荐
- 文件资源管理器改进（紧凑视图、快速访问等）
- 右键菜单增强（终端、取得所有权）
- 任务栏定制
- 可切换的视觉效果
- NTP 时间服务器配置
- 桌面 / 开始菜单快捷方式

### 安全
- 限制匿名 SAM 访问
- 禁用远程协助
- 阻止 BitLocker 自动设备加密
- 可选：Defender 开关、缓解措施配置、核心隔离

### 网络
- 重置为 Atlas 默认网络配置
- 禁用带宽节流
- 禁用 DNS 多播
- 可选：文件共享开关

### 游戏专项
- 键盘 2000Hz 轮询率
- CS2 优化
- 三角洲行动优化
- 可选：禁用鼠标加速（1:1 原始输入）

### 超级低延迟（可选）

勾选后自动执行全部深度低延迟优化，牺牲部分安全性/节能换取最低延迟，仅推荐竞技游戏玩家。建议同时选择「禁用缓解措施」。

| 优化项 | 操作 | 说明 |
|--------|------|------|
| MPO 禁用 | `OverlayTestMode=5` | 禁用多平面叠加，解决 NVIDIA/AMD 微卡顿、闪烁、黑屏。集显用户需谨慎 |
| GPU TDR 延长 | `TdrDelay=12` | 超时检测延迟 12 秒，防止高负载游戏 TDR 崩溃 |
| MSI 模式 | 为 PCI 设备启用 | Message Signaled Interrupts，中断延迟更低 |
| HPET 移除 | bcdedit + 禁用设备 | 移除已知延迟源，回退到 TSC；禁用 HPET 设备（ACPI\\PNP0103） |
| Nagle 禁用 | `TcpAckFrequency=1, TCPNoDelay=1` | 禁用 TCP Nagle 算法，网络响应更快 |
| 禁用页面合并 | `DisablePageCombining=1` | 减少内存合并操作延迟 |
| 禁用定时器聚合 | `GlobalTimerCoalescing=0, CoalescingTimerInterval=0` | 消除定时器聚合延迟 |
| 多媒体调度优化 | `NoLazyMode=1` | 禁用懒模式，调度更积极 |
| 网络节流最大化 | `NetworkThrottlingIndex=0xFFFFFFFF` | 前台多媒体进程网络不限速 |
| 定时器分辨率 | `TimerResolution=10` | 注册表层静态默认值，与 SetTimerResolution.exe 互补 |
| VBS/HVCI 禁用 | 关闭虚拟化安全 | 与核心隔离选项幂等共存 |
| DMA 重映射禁用 | 关闭 SecureBoot 场景 | 减少 IOMMU 开销；⚠️ Thunderbolt/USB4 设备可直读内存 |

## 安装后可切换

桌面 chenniX 文件夹里的所有设置都可以随时切换，不需要重装：

- Defender 开关
- 缓解措施开关
- 自动更新开关
- 休眠 / 电源限制开关
- 核心隔离开关
- Edge 安装 / 卸载
- 鼠标加速开关
- 终端右键菜单
- 文件共享开关
- 通知开关
- 超级低延迟开关（MPO / TDR / MSI / HPET / Nagle 等）
- ……更多

## 致谢

- [AtlasOS](https://ameliorated.io/) — Playbook 框架和基础优化思路
- [ShadowWhisperer](https://github.com/ShadowWhisperer) — Remove-MS-Edge 工具

## 免责声明

**安装前请务必备份重要文件。** 本项目会修改系统核心设置，虽然大部分可以恢复，但仍建议创建系统还原点或完整备份。

当前为测试版本（v0.1），部分功能仍在验证中，如遇问题欢迎提 Issue。
