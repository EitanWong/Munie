# 原生 Apple 工程边界

日期：2026-11-17。状态：接受。整合原先重复的两份初始化决策；产品范围由[需求](../requirements.md)和[远程 Agent 决策](remote-agent-foundation.md)唯一维护。

## 决定与原因

保留自己拥有的 SwiftUI 原生前台与小范围 Foundation-only `MunieCore`；领域逻辑不依赖设备 SDK。使用 Apple 支持的多 destination `Munie` target 和独立 `MunieWatch` target，复用明确的展示层/资源，设备交互留在 app。采用 `project.yml` + checksum 固定的 XcodeGen 生成普通 Xcode 工程；生成器是开发工具，不是运行时依赖。

当前一个 Xcode project 足够；每个 package 遵循 SwiftPM 标准目录。只在真实共享行为出现后提取 package。原生文件与 async store 接口满足初始本地记录场景，数据库、跨进程共享和同步在产生实际需求时单独设计。多平台编译基础不改变 iPhone→Mac Codex 主链路的产品优先级。

## 替代与复查条件

逐个平台复制 app target/源码会增加当前维护成本；Catalyst 不等于原生 Mac，watchOS 不能混入多 destination target。暂不增加 UI framework、通用插件框架或空 package。若 capability、签名、扩展、独立发布或平台交互出现真实差异，再拆 target/边界。

现有存储、窗口及平台限制以[架构](../architecture.md)为准，实际证据以[项目状态](../project-status.md)为准；此处不重复其列表。实现遵循[Apple 工程规范](../standards/apple-engineering.md)，官方依据与工具许可见[来源登记](../../references/apple-platform-guidance.md)。
