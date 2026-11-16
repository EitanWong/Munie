# 架构决策索引

只保存仍有意义的选择、原因与复查条件；实现细节链接到唯一专题。文件按主题命名，无数字前缀；被替代的有效内容合并后删除旧文档，历史由 Git 保存。

| 决策 | 状态 / 范围 |
|---|---|
| [原生 Apple 工程](native-apple-foundation.md) | 接受；target、package、生成器与小范围依赖边界 |
| [随身 Agent 与 Codex 执行端](remote-agent-foundation.md) | 设计接受；远程实现待执行，任务状态/信任/失败恢复契约 |

需求归[需求基线](../requirements.md)，当前实现归[架构](../architecture.md)，完成证据归[项目状态](../project-status.md)，操作规范归[标准索引](../standards/README.md)。不在决策文档再维护第二份状态或需求清单。
