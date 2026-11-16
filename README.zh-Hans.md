# Munie

随时在身边的个人 AI 助手。

[English](README.md) · [文档](docs/README.md) · [项目状态](docs/project-status.md)

Munie 是 Apple 原生个人 AI 前台：记录当下的想法，之后找回，并逐步支持交给可替换的 AI 执行端处理。工程基础提供本地文字记录：iPhone、iPad、Mac、Apple TV、Apple Vision Pro 共用原生多平台应用 target，Apple Watch 使用独立 target。共享代码不代表设备间自动同步。远程执行、语音、Watch 连接和 Ray-Ban Meta 接入仍是后续里程碑。Apple TV 记录使用可被系统清理的缓存。

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

## 仓库结构

| 路径 | 职责 |
|---|---|
| `apps/Munie/` | 原生多平台 SwiftUI 应用、共享展示层和资源 |
| `apps/MunieWatch/` | 独立 watchOS target 中的 Watch 专属交互 |
| `apps/MunieTests/`、`apps/MunieUITests/` | 应用单元测试和 iOS UI 测试 target |
| `packages/MunieCore/` | 可复用的记录模型、持久化和核心测试 |
| `docs/` | 产品决策、架构、流程、调研和项目状态 |
| `references/` | 固定版本的第三方索引与忽略提交的源码检出 |
| `scripts/` | 可重复执行的本地与 CI 自动化 |
| `.github/` | CI/CD 工作流与协作模板 |
| `Package.swift` | 应用状态逻辑的 Mac 测试入口，不是发布库 |
| `config/` | 签名配置模板，个人值不入库 |
| `project.yml` | Xcode 工程的唯一配置源 |

`packages/` 是仓库分组约定，并非 Apple 强制目录名。每个包遵循标准的 `Package.swift`、`Sources/<Target>/`、`Tests/<Target>Tests/` 结构。当前本地 Swift Package 可直接由一个生成的 `.xcodeproj` 管理，无需额外创建 `.xcworkspace`。

`main` 是发布主分支，日常开发汇入 `dev`；功能使用 `feat_<module>_<purpose>` 分支和仓库旁的独立 worktree。见[贡献规范](CONTRIBUTING.md)。

优先采用原生能力、成熟且完成许可证审查的组件。出现真实的共享需求后再抽成 package，避免为尚未验证的设备接入提前建空层。当前运行时依赖与参考源码见[架构](docs/architecture.md)和[参考索引](references/README.md)。

## 隐私与发行

本地记录基础不要求模型账户或服务器。记录内容是敏感用户数据，处理原则见 [SECURITY](SECURITY.md)。项目尚未选择开源许可证或授予产品分发权；第三方项目保留各自许可证。
