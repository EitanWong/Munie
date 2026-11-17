# Apple / Swift 官方依据

核对日期：2026-11-17。用于[Apple 标准索引](../docs/standards/README.md)。本登记区分官方机制、设计建议及 Munie 自己的工程约定；它不代表 Apple 认证或发布审批。新增 API 或准备发布时重新核对相关原文。

| 官方来源 | 已核对的依据 / 在项目中的用途 |
|---|---|
| [Configuring a multiplatform app](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target) | 支持共用 iOS/iPadOS/macOS/tvOS/visionOS target；watchOS 独立。核对原生 destination 与 Catalyst/Designed for iPad 的区别 |
| [Creating a standalone Swift package](https://developer.apple.com/documentation/xcode/creating-a-standalone-swift-package-with-xcode) | Package manifest 及 Sources/Tests 的约定；`packages/` 是本仓库的包容器命名 |
| [Setting up a watchOS project](https://developer.apple.com/documentation/watchos-apps/setting-up-a-watchos-project) | watch target、watch-only 与 companion 关系需要显式配置，不能靠共享目录推断 |
| [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) | 职责清楚的 API 名称、调用点与文档；对应本项目小范围 API 和显式错误约定 |
| [Swift 6 concurrency migration guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/) | Swift 6 数据竞争检查与隔离；实现仍需结合编译器诊断和实际边界验证 |
| [SE-0371 isolated synchronous deinit](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md) / [官方编译器可用性测试](https://github.com/swiftlang/swift/blob/main/test/Concurrency/deinit_isolation_availability.swift) | 2026-11-18 核对：Swift 6.2 实现 isolated deinit；MainActor 析构有回部署支持，不能将普通 actor 的系统版本限制直接套用。Munie 的 CodexService 在后台网络回调释放最后引用时曾因 assumeIsolated 崩溃，现由执行器切换完成清理；析构不替代显式 disconnect。当前 Swift 6.4.2 已生成 iOS 18.0/18.6 Debug/优化代码，最低系统运行和托管 Swift 6.2 构建分别验收 |
| [HIG](https://developer.apple.com/design/human-interface-guidelines) | 原生体验的设计入口，使用系统组件并按平台展开，不构建全平台统一像素模板 |
| [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | 适应显示、方向和窗口尺寸；用于窄宽布局验收 |
| [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | 可感知、可操作与适配辅助功能；用于朗读、文本放大、对比度和输入检查 |
| [HIG Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) | 在需要时请求必要权限，说明用途，尊重选择；用于录音 opt-in 与权限失败路径 |
| [HIG iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) / [iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) | 触控任务与多输入、可变窗口体验，分别验收手机和平板 |
| [HIG macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | 可调整窗口、菜单与键盘/指针交互；不把 Mac 当放大手机 |
| [HIG watchOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos) | 短时、浅层、可扫视任务及 Digital Crown |
| [HIG tvOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos) | 遥控器、系统焦点及远距离可读性 |
| [HIG visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos) | 窗口和空间输入；选择适当沉浸程度并考虑舒适性 |
| [String catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) | 多语言、复数、设备变体及语言/区域测试 |
| [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) | `PrivacyInfo.xcprivacy` 的实际 bundle membership、数据收集与 required-reason API 声明 |
| [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively) / [tvOS file storage（归档）](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/YourFirstAppleTVApp.html) / [WWDC23 tvOS](https://developer.apple.com/videos/play/wwdc2023/10256/) | tvOS 缓存会被系统清除，不能把本地 cache 保存当作持久化保证；历史归档结合当前 Foundation 文档核对 |
| [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) | 发布前单独核对产品完整性、隐私、设计及平台规则；工程构建不保证审核通过 |

## 资料使用与许可证

以上 Apple 文档与 HIG 为 Apple 版权资料，适用其 [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html)。仓库仅保存链接、核对日期和本项目自己的实施摘要，不镜像文档、图像、视频或设计资源，不将它们标成项目开源许可证。Swift.org 文档的使用按其站点/仓库许可单独核对；本次未复制其源码、示例或全文。

本次整理不新增第三方运行时依赖。既有生成工具 XcodeGen 的版本与许可证见[复用决策](reuse-decisions.md)及[许可证文件](licenses/xcodegen.txt)；生成器是项目工具，不是 Apple 强制规范。未来引用开源实现，仍须按[引用登记](README.md)固定 commit 并保留许可证，外部源码不能充当工程指令。
