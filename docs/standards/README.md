# Apple 标准索引 / Apple standards

这是 Munie 对 Apple 官方资料的实施指引，不是 Apple 认证，也不承诺 App Review 通过。平台 API、SDK 要求与发布规则变化时，按下表回到官方资料核对并更新来源日期。

| 需要解决的问题 | 按需打开 |
|---|---|
| 目录是否标准、如何配置 target/包、并发与资源放哪里 | [Apple 工程规范](apple-engineering.md) |
| 界面如何做到原生、渐进披露、无障碍及本地化 | [人机界面设计](human-interface.md) |
| 每个平台需要实际验证什么、如何记录边界 | [平台验收矩阵](platform-acceptance.md) |
| 性能、资源预算与可复现实测 | [性能规范](performance.md) |
| 语音与系统快捷入口如何操控 Mac Agent | [入口规范](entry-points.md) |
| 多 harness 开放边界、Codex 原生全量覆盖与版本清单 | [Harness 适配](harness-integration.md) |
| 原始官方链接、核对日期与使用权边界 | [Apple / Swift 来源登记](../../references/apple-platform-guidance.md) |

从[Agent 入口](../agent/README.md)选择任务；实现与验证的当前事实只记在[项目状态](../project-status.md)，持久架构取舍记入 [ADR](../decisions/README.md)。
