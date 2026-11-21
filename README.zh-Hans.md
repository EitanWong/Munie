# Munie

随时在身边的个人 AI 助手。

[English](README.md) · [文档](docs/README.md) · [项目状态](docs/project-status.md)

Munie 是控制 Mac 上 Codex 的原生 Apple 前台。主要 iPhone 实现现已改为直接采用 [Remodex](https://github.com/Emanuele-web04/remodex) 源码，沿用其会话、Markdown、diff、项目/git、审批与恢复功能，产品名称仍为 Munie。此前原生客户端与主机保留为回退检查点。[需求基线](docs/requirements.md)继续约束语音、系统入口、隐私、中英双语及后续 Apple 平台能力。

新底座正在验收：主流程控件已加入中英双语，录音限制为 30 秒，通知可返回对应会话。高级界面翻译、真实音频与系统入口、通知送达仍需验收，见[项目状态](docs/project-status.md)。固定提交、排除的上游品牌/二进制和发行 notice 阻塞见[移植记录](references/remodex-adoption.md)。

## 连接 iPhone 与 Mac

产品安装方式是两个 App：Mac 上的 Munie 和 iPhone 上的 Munie。新的本地 Mac 构建采用以下流程：

1. 打开 Mac 上的 Munie，按提示在浏览器登录 Codex，使用默认工作区或选择项目文件夹。
2. 打开 iPhone 上的 Munie，选择自动发现的 Mac。
3. 核对两端显示的数字并确认配对，然后在手机上发起任务。

运行依赖、本地服务启动和连接配置由 Mac App 管理；普通引导没有终端命令、npm 安装或服务器地址输入。当前产品切片先实现附近连接，外出自动连接仍未完成。实际构建/验收与发行限制见[项目状态](docs/project-status.md)。目前尚无公开安装发行版；[开发说明](docs/development.md)单独保留开发者构建与旧网络诊断入口。

## 开始开发

要求：macOS，以及支持 Swift 6 并安装各 Apple 平台 SDK 的 Xcode。新 iPhone target 最低为 iOS 18.6；保留基础的最低版本为 iOS/iPadOS 18、macOS 15、watchOS 11、tvOS 18、visionOS 2。初始化脚本将校验和固定的 XcodeGen 2.46.0 与 actionlint 1.7.12 下载到忽略提交的 `.tools/`。模拟器测试还需要已安装的 iPhone 模拟器运行时。

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
./scripts/check.sh
./scripts/test-remodex-ios.sh
```

真机安装前在忽略提交的 `config/Signing.xcconfig` 中设置签名团队与唯一 Bundle ID。生成的 Xcode 工程不入库；修改 `project.yml`。单项检查和环境限制见[开发说明](docs/development.md)、[测试说明](docs/testing.md)。

先读 [Agent 任务索引](docs/agent/README.md)，再按需读取 [Apple 开发规范与 HIG 指引](docs/standards/README.md)。这些是附有官方来源的项目规则，不代表已获 Apple 认证。

文档按主题命名、通过索引导航，每个主题只有一个权威来源。[维护规则](docs/maintenance.md)约束变更同步、过时内容移除和安全定期清理；仓库检查会拒绝未被索引或带数字前缀的文档。

## 仓库结构

| 路径 | 职责 |
|---|---|
| `apps/MunieRemodex/` | 主要原生 iPhone 移植客户端、单元/UI 测试与许可文本 |
| `apps/MunieDesktop/`、`apps/MunieDesktopTests/` | 原生 Mac 伴侣、内置执行生命周期与离线应用测试 |
| `apps/MunieRemodexBridge/`、`apps/MunieRemodexRelay/` | 移植的 Mac bridge 与私有自托管 relay |
| `apps/Munie/` | 保留的多平台原生回退检查点与资源 |
| `apps/MunieWatch/` | 独立 watchOS target 中的 Watch 专属交互 |
| `apps/MunieTests/`、`apps/MunieUITests/` | 应用单元测试和 iOS UI 测试 target |
| `apps/MunieMacHost/`、`apps/MunieHost/` | 原生 Mac 主机 UI、受监督执行、账本与传输 |
| `packages/MunieRemote/` | 跨端协议、有界传输与客户端恢复逻辑 |
| `packages/MunieNearby/` | iPhone 与 Mac 共用的有界附近发现与两端明确确认配对 |
| `packages/MunieCore/` | 可复用的记录模型、持久化和核心测试 |
| `docs/` | 产品决策、架构、流程、调研和项目状态 |
| `references/` | 固定版本的第三方索引与忽略提交的源码检出 |
| `scripts/` | 可重复执行的本地与 CI 自动化 |
| `.github/` | CI/CD 工作流与协作模板 |
| `Package.swift` | 主机模块、服务/guardian 可执行文件及 Mac 测试入口 |
| `config/` | 签名配置模板，个人值不入库 |
| `project.yml` | Xcode 工程的唯一配置源 |

`packages/` 是仓库分组约定，并非 Apple 强制目录名。每个包遵循标准的 `Package.swift`、`Sources/<Target>/`、`Tests/<Target>Tests/` 结构。当前本地 Swift Package 可直接由一个生成的 `.xcodeproj` 管理，无需额外创建 `.xcworkspace`。

`main` 是发布主分支，日常开发汇入 `dev`；功能使用 `feat_<module>_<purpose>` 分支。见[工作树流程](docs/development.md#daily-workflow)和[贡献规范](CONTRIBUTING.md)。

优先采用原生能力、成熟且完成许可证审查的组件。出现真实的共享需求后再抽成 package，避免为尚未验证的设备接入提前建空层。当前运行时依赖与参考源码见[架构](docs/architecture.md)和[参考索引](references/README.md)。

## 隐私与发行

远程任务需要 Mac 本地 Codex 账户；独立本地记录无需模型账户。记录内容是敏感用户数据，处理原则见 [SECURITY](SECURITY.md)。项目尚未选择开源许可证或授予产品分发权；第三方项目保留各自许可证。
