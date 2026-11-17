# Harness 集成与原生能力

本页是执行框架集成的唯一规范入口；产品目标以[需求](../requirements.md)为准，信任、任务状态和恢复规则复用[远程 Agent 决策](../decisions/remote-agent-foundation.md)。当前完成设计、协议范围清单、离线工具、本机握手与确定性 provider 驱动的原生生命周期研究；没有产品远程 adapter，也没有实现下列产品原生能力。

## 开放边界与首发完整性

Munie 面向多种 Agent/Harness。Codex 是首个执行框架，目标是完整接入选定版本的原生能力；Claude Code、Pi、Hermes、OpenClaw、WorkBuddy、Qoder 保留后续独立 adapter 位置。这里列出产品方向，不表示这些项目的身份、协议、许可或可集成都已验证。模型/provider 与 Harness 分开建模，不能把一个模型的聊天接口当成某个框架的完整实现。

共享层表达设备入口、任务展示和必要的关联信息；框架专属能力通过版本化原生扩展呈现。不得为了跨框架统一而只保留最低公分母聊天，也不得把 Codex 原生字段塞进所有 adapter 都必须仿造的模型。高级操作按需展开，但能力不能在传输、事件映射或 UI 中被静默丢掉。先落实设计约束，在真实 Codex adapter 和测试中形成接口；第二个实际框架接入时再抽取已证明共用的实现，不先建空 package、插件引擎或无人调用的路由层。

## HarnessAdapter 设计契约

下面是 Munie 的职责约定，不是已存在的 Swift 类型或上游字段名。

| 边界 | 必须保留的内容 / 可观察验收 |
|---|---|
| 身份与版本 | Harness 标识、主机、安装版本、协议版本、账号/权限上下文；thread/turn/item/tool/request 的上游 ID 与本项目 ID 分开保存。跨主机/框架的同名 ID 不得串线 |
| 能力协商 | 在版本、账号、模型/provider、平台、配置及运行时 feature flag 上下文中判定；区分实现且可用、上游不可用、实验性、受策略限制、尚未验证、未实现，并向 UI 返回原因。未知版本不能假装兼容 |
| 共享操作 | 只规范已经存在的共同语义，如开始/继续、读取真实状态、取消；具体权限、终态与结果来源不能被“统一”成猜测。语义不等价时保留差异并测试 |
| 原生扩展 | 按 Harness/协议版本命名并绑定具体 schema；完整承载该框架独有的设置、操作、参数、响应、事件和交互。只有经过主机授权及类型校验的明确方法映射可以执行，手机不能透传任意 RPC 或任意本机命令 |
| 双向请求 | ServerRequest 需要回应，ServerNotification 不需要；审批、用户问题、MCP elicitation、动态工具与凭据刷新各自映射。保留上游 request ID、动作、权限选项、错误和有效期，不能一律当成文本通知或自动同意 |
| 事件与重连 | 保留原生方法和类型、thread/turn/item 关联、顺序/游标与终态；增量、完整快照、删除、resolved 事件语义分开。未知事件显式记录类型和兼容状态，不能伪造完成或无声忽略 |
| 错误与资源 | 保留原生 code/type/来源和可重试性，并附安全的用户解释；分页、背压、大小上限与取消继续遵循远程决策。日志不保存原始凭据或用户正文 |
| 原生 UI | 普通任务直达输入和进展；模型/配置/插件等选项按能力显示。审批展示实际动作和权限，结果跳回原任务。VoiceOver、双语、短语音和 Watch 的受限屏幕不能导致能力语义丢失 |

能力协商不是“启用全部 feature flag”。对于管理策略、账号、平台或上游实验 gate，先保留可解释的不可用状态；不能越权、伪造支持或因服务端拒绝而悄悄换一种执行方式。特别是原生 shell/process、文件写入、配置/插件安装、账号与远程控制操作，必须独立评审其实际权限和副作用。完整性目标与最小权限同时成立。

## Codex 范围清单与漂移

2026-11-17 在本机观察 `codex-cli 0.162.1`，分别执行默认和 `--experimental` JSON Schema 导出；未启动模型任务或远程连接。[机器清单](../../references/codex-capabilities.json)完整列出实际导出的每个方法、协议方向、Munie 分类、默认导出是否存在和当前实现状态。没有手写筛选只保留常用方法。

| 协议联合类型 | 默认导出 | 含实验能力导出 | 当前实现 |
|---|---|---|---|
| `ClientRequest` | 105 | 170 | 0 |
| `ServerRequest` | 10 | 11 | 0 |
| `ServerNotification` | 84 | 84 | 0 |
| `ClientNotification` | 1 | 1 | 0 |
| 合计 | 200 | 266 | 0 |

默认导出包含一个方法，不代表它稳定、当前启用、该账号可用或该平台支持；同一方法也可有需显式 opt-in 的实验字段。实验导出还含平台专属、兼容旧协议和测试方法；清单保留它们并要求逐项判定，不能删除后宣称完整。类型中的 variant/字段能力也不能只靠方法数判断，例如子 agent 项、输入模态、权限选项、会话配置、工具结果和原生事件内容均需分别映射。

```sh
codex --version
codex app-server generate-json-schema --out build/codex-schema-stable
codex app-server generate-json-schema --experimental --out build/codex-schema-experimental
python3 scripts/catalog-codex.py \
  --schema-dir build/codex-schema-experimental \
  --default-schema-dir build/codex-schema-stable \
  --cli-version 'codex-cli 0.162.1' --check references/codex-capabilities.json
```

CI 无需安装 Codex；运行 `python3 scripts/catalog-codex.py --validate-catalog references/codex-capabilities.json` 检查已提交清单的版本、四种方向、唯一方法、计数、默认导出标志、分类、SHA-256 格式与全部未实现状态。此模式只验证结构完整，明确不验证当前安装协议是否漂移。

升级时先在新的 ignored `build/` 目录导出，确认实际 CLI 版本，再运行检查。工具只读取已有文件，不调用 Codex、网络或模型；同样输入产生同样清单。`--check` 对新增/删除方法、方向、实现状态、版本和全 schema 指纹漂移退出非零；参数、响应或事件 variant 变了，即使方法名没变也会失败。新增分类未知时保留 `other_native`，要求 review；不得静默跳过新方法。

清单保存默认 317 / 实验 447 个 JSON 文件的聚合 SHA-256：按相对路径排序，以“路径、NUL、排序键的规范 JSON、NUL”连接后哈希。完整 schema 留在 ignored 目录，不提交其大体积正文。核对差异与官方说明后，用相同参数将 `--check` 改为 `--output` 生成候选，再 review。当前生成器固定输出 `unimplemented`，防止把列出方法当成已支持；未来实现证据应逐项关联真实 adapter、功能测试和设备验收，再评审状态机制。

## 完整原生支持的通过条件

实施前先按[测试入口](../testing.md#opt-in-local-codex-protocol-experiment)运行固定版本、系统隔离的 no-turn 探针，读取[协议研究](../../references/codex-protocol-research.md)。握手及不存在任务的拒绝只说明这些协议边界；不得据此把清单状态改为已实现，或声称真实审批、取消与恢复通过。

其后的 native lifecycle 夹具验证真实 app-server 状态、单次命令审批及优雅重启后的已知 thread 读取/继续；模型内容来自合成 provider。后续[账本集成实验](../testing.md#ledger-integrated-native-codex-experiment)另外执行了运行中工具取消和特定崩溃窗口。两者均不能证明真实模型、所有恢复情况或手机访问，也不改变产品清单的 `unimplemented` 状态。审批回复必须核对本次 `availableDecisions`、实际动作及原 request/thread/turn/item；终态、恢复方式与测试范围不得被统一成一个“通过”。

以下按能力组织验收，机器清单仍保留全部原始方法，不能用这个摘要替代逐项范围。

| 能力组 | 必须覆盖的真实行为 |
|---|---|
| 初始化、版本与配置 | 握手和通知、实验能力协商、模型/提供商可用性、权限配置、账号状态；不把本地 schema 存在当服务端已可调用 |
| 会话、项目与上下文 | 创建/继续/分叉、历史分页、订阅、归档/恢复/删除、项目/分组、附件、目标、队列和设置；每项保留原生关联与副作用 |
| 执行与协作 | 开始、steer、中断、review、原生子 agent 项与工具、计划/diff、输出增量、使用量及来源；区分请求接收与真实完成 |
| 权限与双向交互 | 命令/文件/权限审批、原生审批选项、拒绝/撤销/超时、用户输入、MCP elicitation、工具调用及凭据刷新；无响应不等于批准 |
| 工具与扩展生态 | Skills/hooks、MCP 状态/资源/工具、apps/plugins/marketplaces、相关更新事件；遵守上游开发中能力的生产限制 |
| 文件、命令与原生控制 | 文件 API、命令/进程、PTY、后台终端、环境、搜索、memory/rollout、remoteControl；逐项验证权限边界，不对外暴露裸原生通道 |
| 语音与多模态 | 所选版本允许的原生 input/output 与 realtime 事件、权限及中断；模型/账号/功能 gate 分开核实，不能因协议存在就承诺视频或持续音频 |
| 诊断及兼容 | 错误、警告、过时接口、平台专属和测试面、未知事件/版本、断连恢复与资源限制；不可适用项必须附上游依据和可见状态 |

宣布“完整支持”前，每项原生能力必须有准确映射、正反路径、字段/响应/事件 variant 覆盖、权限边界、版本上下文及可重放的真实证据；禁止用“已封装 RPC”“方法已列全”或一条聊天演示替代。不能因为手机/Watch 不适合某个复杂操作就无声丢弃：应提供合适的系统交互、渐进展开或明确的设备接续路径，并验收用户是否仍能完成任务。

Codex app-server 的版本化协议范围不等于 Codex Desktop 所有 UI、云端服务或任意现有桌面会话；原生产品若存在清单之外的能力，单列缺口、官方接口与可行性证据，未验证前保留未实现状态。未来其他 Harness 也需自己的官方来源、固定版本、原生能力清单、许可和一致性测试，不能拿 Codex 字段或聊天协议推断它们的完整能力。

## 官方依据与使用边界

2026-11-17 核对 [Codex app-server](https://learn.chatgpt.com/docs/app-server)的协议导出、初始化、实验协商与双向消息规则；真实方法范围来自本机 CLI 生成物。文档只保存链接、API 标识与本项目规范，不复制官方正文或第三方实现。协议来源与现有连接机制研究见[入口研究](../../references/entry-point-research.md)；新增运行时依赖仍须按[引用登记](../../references/README.md)复核。本轮增加仅供本机研究的固定版本 adapter 子集；未引入第三方运行时 SDK 或账号凭据。
