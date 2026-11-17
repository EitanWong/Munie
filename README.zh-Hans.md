# Munie

随时在身边的个人 AI 助手。

[English](README.md) · [文档](docs/README.md) · [项目状态](docs/project-status.md)

Munie 是原生 Apple Agent 前台。首个 iPhone–Mac 切片支持明确配对、选择授权项目、文字或短语音输入、让 Mac 上真实 Codex 执行、查看进展/结果、回答单次命令审批、取消和继续任务。重连先查询权威状态，不盲目重发。系统 Shortcuts 可打开输入，通知按任务路由。

Mac 上的 Tailscale Serve 提供私有 HTTPS；Codex 凭据留在 Mac。当前是固定 Codex 版本的受限子集，完整原生覆盖、Watch 远程任务和媒体仍属后续目标。真实模型、构建、设备、蜂窝、语音和通知送达分别记录于[项目状态](docs/project-status.md)，不能以编译或路由测试替代设备验收。其他平台保留本地记录基础，Apple TV 使用可清除缓存。

## 连接 iPhone 与 Mac

1. 在 Mac 安装并登录 Codex 0.162.1。用 Xcode 的 `MunieHost` scheme 构建/运行主机 app，启动服务并明确授权一个项目目录。
2. 两端安装并登录同一 Tailscale 网络。在 Mac 配置私有 Serve HTTPS 到 `http://127.0.0.1:9274`，不启用公网 Funnel；可选脚本见[测试说明](docs/testing.md#product-private-network-setup)。
3. Mac 输入自己的 Tailscale HTTPS 地址，创建两分钟邀请。iPhone 打开 Munie 扫描或手动输入邀请；在两端比对指纹，再由 Mac 确认项目权限。
4. 选择项目后输入/提交。语音仅在主动点击后开始，转写可编辑或丢弃；系统不支持离线识别时使用文字。Mac 需清醒在线。

审批只对确切动作有效；取消显示主机确认后的终态。可在 Mac 撤销设备或删除 Munie 的终态历史；原生 Codex 历史另行保留。推送是可选配置，需要支持 APNs 的团队及密钥；本地通知只反映 app 已观察的状态。

## 开始开发

要求：macOS，以及支持 Swift 6 并安装各 Apple 平台 SDK 的 Xcode。最低系统版本为 iOS/iPadOS 18、macOS 15、watchOS 11、tvOS 18、visionOS 2。初始化脚本将校验和固定的 XcodeGen 2.46.0 与 actionlint 1.7.12 下载到忽略提交的 `.tools/`。模拟器测试还需要已安装的 iPhone 模拟器运行时。

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
./scripts/check.sh
./scripts/test-ios.sh
```

真机安装前在忽略提交的 `config/Signing.xcconfig` 中设置签名团队与唯一 Bundle ID。生成的 Xcode 工程不入库；修改 `project.yml`。单项检查和环境限制见[开发说明](docs/development.md)、[测试说明](docs/testing.md)。

先读 [Agent 任务索引](docs/agent/README.md)，再按需读取 [Apple 开发规范与 HIG 指引](docs/standards/README.md)。这些是附有官方来源的项目规则，不代表已获 Apple 认证。

文档按主题命名、通过索引导航，每个主题只有一个权威来源。[维护规则](docs/maintenance.md)约束变更同步、过时内容移除和安全定期清理；仓库检查会拒绝未被索引或带数字前缀的文档。

## 仓库结构

| 路径 | 职责 |
|---|---|
| `apps/Munie/` | 原生多平台 SwiftUI 应用、共享展示层和资源 |
| `apps/MunieWatch/` | 独立 watchOS target 中的 Watch 专属交互 |
| `apps/MunieTests/`、`apps/MunieUITests/` | 应用单元测试和 iOS UI 测试 target |
| `apps/MunieMacHost/`、`apps/MunieHost/` | 原生 Mac 主机 UI、受监督执行、账本与传输 |
| `packages/MunieRemote/` | 跨端协议、有界传输与客户端恢复逻辑 |
| `packages/MunieCore/` | 可复用的记录模型、持久化和核心测试 |
| `docs/` | 产品决策、架构、流程、调研和项目状态 |
| `references/` | 固定版本的第三方索引与忽略提交的源码检出 |
| `scripts/` | 可重复执行的本地与 CI 自动化 |
| `.github/` | CI/CD 工作流与协作模板 |
| `Package.swift` | 主机模块、服务/guardian 可执行文件及 Mac 测试入口 |
| `config/` | 签名配置模板，个人值不入库 |
| `project.yml` | Xcode 工程的唯一配置源 |

`packages/` 是仓库分组约定，并非 Apple 强制目录名。每个包遵循标准的 `Package.swift`、`Sources/<Target>/`、`Tests/<Target>Tests/` 结构。当前本地 Swift Package 可直接由一个生成的 `.xcodeproj` 管理，无需额外创建 `.xcworkspace`。

`main` 是发布主分支，日常开发汇入 `dev`；功能使用 `feat_<module>_<purpose>` 分支和仓库旁的独立 worktree。见[贡献规范](CONTRIBUTING.md)。

优先采用原生能力、成熟且完成许可证审查的组件。出现真实的共享需求后再抽成 package，避免为尚未验证的设备接入提前建空层。当前运行时依赖与参考源码见[架构](docs/architecture.md)和[参考索引](references/README.md)。

## 隐私与发行

远程任务需要 Mac 本地 Codex 账户；独立本地记录无需模型账户。记录内容是敏感用户数据，处理原则见 [SECURITY](SECURITY.md)。项目尚未选择开源许可证或授予产品分发权；第三方项目保留各自许可证。
