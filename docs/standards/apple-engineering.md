# Apple 工程规范 / Engineering

本页把官方机制与 Munie 的仓库约定分开。事实来源与核对日期见[来源登记](../../references/apple-platform-guidance.md)；具体 target、路径和最低版本以根 `project.yml` 与各 `Package.swift` 为准。

## 目录与 Xcode

Apple 使用 project、target、scheme、build configuration 和资源 membership 描述应用；并未规定所有 Apple 项目必须采用同一套仓库目录名。`apps/`、`packages/`、`scripts/`、`docs/` 是本项目约定。

| 对象 | 本项目位置与规则 |
|---|---|
| Xcode 工程 | 根 `Munie.xcodeproj`；由根 `project.yml` 经 `scripts/bootstrap.sh` 生成。修改生成源，避免手改生成物 |
| 多平台应用 | `apps/Munie/`；`App/` 负责生命周期与依赖组合，`Features/` 负责功能 UI，`Resources/` 负责 bundle 资源 |
| watchOS | `apps/MunieWatch/`；独立 watch target，允许复用明确列入该 target 的共享 app 源码与 domain package |
| 共享逻辑 | `packages/MunieCore/` 与 `packages/MunieRemote/`；标准 `Package.swift`、`Sources/<Target>/`、`Tests/<TestTarget>/`，无 app UI 或设备 SDK |
| 应用测试 | `apps/MunieTests/`、`apps/MunieUITests/`；测试 target 与对应 app 分离 |
| 配置与自动化 | `config/`、`scripts/`；签名个人配置、缓存与产物保持 ignored |

`packages/` 是多个本地 Swift Package 的容器，不是 SwiftPM 自身的源码目录。实际 package roots 是 `packages/MunieCore/` 与 `packages/MunieRemote/`。不要为迎合目录外观添加空 package，或把 `.xcodeproj` 塞进已有 package。

一个 Xcode project 足够组织目前的 app、测试和本地包。只有出现多个需要统一管理的 project 或工具明确要求时才增加 `.xcworkspace`；文件数量不代表工程更标准。

## 多平台 target

[Apple 多平台配置](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target)允许 iOS、iPadOS、原生 macOS、tvOS、原生 visionOS 共用一个 app target；watchOS 使用独立 target。iPhone/iPad 属于同一 iOS SDK target 的不同设备族。原生 Mac/Vision destination 与 Catalyst/Designed for iPad 是不同选择，文档和验证不得混称。

新增平台时同时检查 app 与依赖包的最低版本、API availability、资源、Info.plist、签名及 scheme。共享 policy 和数据模型；在入口或小范围 view/adapter 内处理平台差异，避免在 core 中散布设备判断。只为已声明平台启用对应 capability，不能把不支持的 API 编译失败转为无条件空实现。

## Swift 与并发

遵循 [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)：名字说明职责，调用点清楚，公开 API 说明输入、结果及错误。优先小范围、具体的类型；只有出现真实共享行为才抽包。

项目采用 Swift 6 完整并发检查。UI 状态明确归属 `MainActor`，共享可变存储按 actor 隔离，通过 `async` 边界注入依赖。检查跨 actor 值的 `Sendable` 与任务取消；不要为消除诊断直接添加 `@unchecked Sendable`、`nonisolated(unsafe)` 或无证据的 `try?`。actor 并不自动解决多进程或跨设备数据一致性。

## 代码质量与资源边界

每个 API 明确输入不变量、成功含义、错误与所有者；优先具体类型和最小可见性。错误在边界翻译，保留可诊断原因，不能用 catch 后空结果掩盖损坏或失败。用户输入、转写与模型输出始终是数据，不可转成任意路径、shell 或权限决定。

异步工作有明确生命周期与取消所有者，检查跨 `await` 后状态是否仍有效；并发结果按任务 ID 归属，防止旧请求覆盖新界面。避免无主 `Task`、无限流、无限重试和无界队列；新增任务需说明超时、背压与回收。不得在 MainActor 同步做磁盘/网络或重计算，按[性能规范](performance.md)测量实际边界。

评审重点是用户状态、数据和权限不变量；不以覆盖率数字或快照数量代替失败、并发、取消、重连和恢复测试。诊断默认只含必要 ID/耗时/状态，禁止正文、媒体、凭据；新增依赖先记录固定版本、许可、维护及替代方案，生成物和缓存不进源码。

## 资源、签名与隐私

将 asset catalog、string catalog 和隐私 manifest 纳入正确 target；不要靠磁盘上“存在文件”判断 bundle 已包含它。用户可见文案采用 English 与简体中文，日期和数字使用 locale-aware 格式；持久化模型使用稳定语言无关字段。

选择存储路径时核对平台文件系统语义。当前 tvOS 使用可能被系统清理的 cache，必须向用户说明且不能声称永久保存；其他平台的本地文件也不意味着跨设备同步。watchOS 目前独立保存本机数据，设备互联需要另行设计与验收。

`PrivacyInfo.xcprivacy` 必须描述实际数据收集及适用 required-reason API；新增 SDK 时复查其隐私资料与许可证。权限在用户触发所需功能时请求，并提供明确用途及拒绝后的可用路径。录音保持 opt-in，保留明确停止与数据控制。只声明实际使用的 entitlement；凭据使用平台安全存储，不写入源码、日志或移动中继 payload。

签名、App Store 隐私信息和 manifest 是不同责任。设备构建前配置真实 bundle identity 与 team；模拟器或 `CODE_SIGNING_ALLOWED=NO` 的构建成功不能证明可分发。提交前另查[发布指引](../release.md)和最新 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

## 变更验收

按[平台矩阵](platform-acceptance.md)构建受影响 destination，执行相关 package/app 测试、格式与仓库检查；按[测试说明](../testing.md)保留实际命令和结果。UI 变化补充对应设备、输入与无障碍验证。工具或运行时缺失应记为未验证及具体阻塞，不能记为通过。
