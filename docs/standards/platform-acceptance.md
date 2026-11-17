# 平台验收矩阵 / Platform acceptance

这是开发与验收要求，不是通过记录。实际结果、运行时、提交与剩余工作统一维护在[项目状态](../project-status.md)。最低系统版本以根 `project.yml` 与 `packages/MunieCore/Package.swift` 为准。

| 平台 | 工程边界 | 至少执行的交互检查 | 官方 HIG |
|---|---|---|---|
| iOS / iPhone | `Munie` 的 iOS destination，iPhone 设备族 | 触控记录/找回/删除、系统返回、键盘遮挡、旋转、冷启动与后台恢复 | [iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) |
| iPadOS | 同一 iOS target，iPad 设备族 | 窄/宽窗口及多任务尺寸、列表/详情切换、触控与键盘/指针、大字及输入法 | [iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) |
| macOS | `Munie` 的原生 macOS destination | 窗口调整、菜单与快捷键、键盘遍历、指针选择、当前单窗口约束；开放多窗口前验证草稿和数据所有权 | [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) |
| watchOS | 独立 `MunieWatch` target | 单次短任务、浅层导航、Digital Crown 滚动、系统文本输入、锁屏与中断、独立启动 | [watchOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos) |
| tvOS | `Munie` 的原生 tvOS destination；当前数据位于可清除缓存 | Siri Remote 焦点可达性、返回、文本输入、跨房间可读性、共享屏幕隐私、清除缓存后的空状态与提示 | [tvOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos) |
| visionOS | `Munie` 的原生 visionOS destination | 标准窗口大小、眼手间接输入、可访问输入、控件选择及视觉舒适度 | [visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos) |

watchOS 优先短而明确的操作，不复制桌面分栏；tvOS 使用系统焦点而非依赖触控手势；visionOS 的文本与列表工作优先标准窗口，新增沉浸体验需有具体场景及舒适性验证。各平台只复用适合的 UI 与领域逻辑；“通用”不意味着每个平台提供完全相同的交互。

## 配件与硬件入口

这些是 R18/R19 的条件验收要求，均待实现与设备验证；机制与系统限制唯一维护在[入口规范](entry-points.md)，不代表已经支持。AirPods、Pencil 是配件，HomePod 不作为独立 app target。

| 入口 | 必须记录的条件 | 可观察验收 |
|---|---|---|
| iPhone Action button / Watch Shortcut | 具体机型、系统、用户配置的快捷指令、锁屏与前后台 | 一次触发抵达正确任务输入；按[硬件规范](entry-points.md#硬件触发与掌控感)验证接受与反馈 |
| AirPods / 耳机 | 型号/固件、连接设备、Siri/通知播报设置、音频路由 | 任务输入及简短反馈；戴摘/通话/路由切换不把私密内容意外外放 |
| iPad / Pencil | 窗口尺寸、Pencil 型号、前台状态、用户首选动作 | 原生输入及素材/结果审阅可达；不支持的硬件动作有同目标替代入口 |
| HomePod | Personal Requests、用户身份、配对设备和可执行 Shortcut 条件 | 受支持条件下抵达同一任务；不可用时明确原因与手机继续路径 |
| CarPlay | 类别资格/entitlement、系统与连接条件 | 仅在资格与实现通过后验收短语音/听觉反馈；复杂审批转到安全设备场景，无资格不声明支持 |

## 跨设备任务接续

这是受认证状态同步实现后的准入检查，当前尚未实现。以同一真实任务运行“设备 A 发起 → 设备 B 找回/继续 → A 重连”：两端指向相同主机、项目和任务，显示权威状态与相同权限范围；接续本身不重新提交或重复执行。覆盖源设备离线、目标设备未配对/被撤销、入口不可用与状态过期，明确失败和可用替代路径，不自动扩大权限。复杂审批必须在目标设备完整展示对象与后果；无法展示时保留待审批并提供明确转交路径。以真实 request/thread/turn、状态事件与副作用次数核对，不能用同名界面或共享代码作为接续证据。

## 分开记录三层证据

1. **构建**：Xcode 版本、scheme、destination、配置、签名设置、命令及退出状态。iPhone 与 iPad 共享 SDK；一次 iOS 编译不能证明两种布局已验收。
2. **执行**：相关 package/app/UI 测试及实际 simulator/device 运行。缺少运行时、硬件或权限时，写出具体缺项与下一条执行动作。
3. **体验与分发**：English/简体中文、可用性、VoiceOver、文本放大、外观/运动偏好、平台输入、数据生命周期、真实签名与分发。构建成功不等于这些检查通过。

在具备持久存储的平台运行当前能力的关键链路：创建 → 保存 → 重启 → 找回/详情 → 确认删除 → 再次重启，并检查错误保留输入与实际数据位置。tvOS 另测正常缓存尚存的重启链路与缓存丢失后的行为，不能据此保证数据持久保存。尚未实现跨设备同步时，必须明确数据仅在本设备；不要把同名 app 或共享 package 当成同步机制。

当前工程的 tvOS、visionOS 分发图标仍需补齐；所有平台的硬件 UX、输入与无障碍验收均需独立证据。独立 watch target 不代表已经实现 WatchConnectivity 或与 iPhone 同步。最终可发布范围以状态记录与发布验收为准。

检查命令与自动化入口见[测试](../testing.md)和[开发](../development.md)。新增 entitlement、录音、远程执行或设备互联时，按实际能力追加权限拒绝、离线、重试、取消和凭据撤销等场景，不预先声称这些能力存在。
