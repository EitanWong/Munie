# Agent 入口 / Agent index

按“入口 → 当前任务 → 专题 → 官方来源”逐层读取；不需要先遍历整个仓库或研究归档。

## 先读两份文件

1. [工程契约](../../AGENTS.md)：目录、分支、隐私、验证及 PR 责任。
2. [项目状态](../project-status.md)：已实现能力、实际验证、阻塞与下一步。状态中的未验证项不能当作已完成。

## 按任务选择最短路径

| 当前任务 | 首先读取 | 然后定位 |
|---|---|---|
| 明确需求或安排下一片工作 | [需求基线](../requirements.md)与[基础准入](../foundation-readiness.md) | 当前 R 编号 → 实际状态 → 最小可验收切片 |
| 熟悉代码与数据流 | [架构](../architecture.md) | `apps/` 的组合入口 → `CaptureStore` → `packages/MunieCore` |
| 调整目录、target、SDK 或最低版本 | [Apple 工程规范](../standards/apple-engineering.md) | 根 `project.yml`、`config/`、各 `Package.swift` |
| 新增或修改界面 | [HIG 项目指引](../standards/human-interface.md) | 所属 app 的 `Features/`、`Resources/`；再读目标平台验收行 |
| 添加共享逻辑 | [架构边界](../architecture.md)与 [Swift 规则](../standards/apple-engineering.md#swift-与并发) | `packages/MunieCore/Sources/` 与对应 `Tests/` |
| 修复失败或回归 | [测试](../testing.md) | 失败命令、最小复现、相关测试及 `scripts/` |
| 测量性能或调整预算 | [性能规范](../standards/performance.md) | `benchmark-core.sh` → Release 基准 → 原始样本/预算 |
| 设计语音、快捷入口或远程任务 | [入口规范](../standards/entry-points.md)与[远程决策](../decisions/remote-agent-foundation.md) | 官方协议 / 固定源码 / 多模态研究，先验边界再实现 |
| 实施配对、主机服务或多设备审批 | [信任与服务设计](../decisions/device-trust-and-host-service.md) | 当前原生 Mac / Remodex v2 附近配对 → 授权、撤销、实际服务与设备验收；Tailscale / bearer 为保留检查点，identity 研究独立保留 |
| 对接 Codex 或其他 harness | [Harness 规范](../standards/harness-integration.md) | 版本化能力清单 → 官方接口/许可 → adapter 与行为验收 |
| 整理文档、清理和消除过时内容 | [维护规则](../maintenance.md) | 唯一来源表 → 索引/链接检查 → 实际代码与PR状态 |
| 添加权限、SDK 或远程连接 | [安全边界](../../SECURITY.md)与 [隐私规则](../standards/apple-engineering.md#资源签名与隐私) | [引用登记](../../references/README.md)，再检查所属 app/adapter |
| 准备集成或发布 | [开发](../development.md)、[发布](../release.md) | 当前 PR、精确 head 的 CI、review threads |
| 做产品决策或实验 | [产品](../product.md) | 仅按需要读取[研究归档](../research/README.md)；归档不代表实现结果 |

完整专题入口见 [Apple 标准索引](../standards/README.md)，其他维护文档见[文档目录](../README.md)。

## 本次改动的完成记录

用实际证据更新状态：改了哪个行为/target、执行命令、精确提交、结果、仍缺的设备/运行时、下一步。行为变化同步架构或 ADR；新增第三方能力同步来源与许可证。将长日志留在 ignored `build/` 或 CI artifacts，文档只保留可追溯结论。

先检查 `git status` 和已存在 worktree，再在 `dev` 派生的 sibling `feat_<module>_<purpose>` worktree 工作。按 [AGENTS](../../AGENTS.md) 完成 review、CI 和集成；不能用“已有目录”或“声明支持”替代平台构建及运行证据。
