# 随身 Agent 前台与自有 Codex 执行端

日期：2026-11-17。状态：接受产品方向与设计边界；远程协议和 adapter 尚未实现。产品范围以[需求](../requirements.md)为准；工程结构选择见[原生工程决策](native-apple-foundation.md)。

## 背景与依据

所有者明确需要离家后仍通过手机/手表操控自己的 Mac Codex，并逐步以语音、多模态和主动汇报形成个人助理。[需求基线](../requirements.md)是后续范围依据。现有捕获模型不能作为远程执行账本。

2026-11-17 核对 [Codex app-server](https://learn.chatgpt.com/docs/app-server)：存在结构化 thread/turn、事件、审批和取消接口，可由所选 CLI 生成同版本 schema；默认本机 stdio，WebSocket 仍标为实验能力。具体方法、许可及源码证据见[研究](../../references/entry-point-research.md)。[Agent 安全机制](https://learn.chatgpt.com/docs/agent-approvals-security)区分执行沙箱与审批；远程客户端不能提升执行端原有权限。

## 决定与边界

```text
iPhone / Watch 原生入口（语音、文字；后续图片/视频）
  → 输入/素材适配与意图整理 → 任务展示与必要授权
  → 已认证加密通道（网络方案在首个探针时明确）
  → 自己 Mac 的 gateway（身份、项目范围、请求/事件账本）
  → Mac 本机 Codex app-server（stdio，凭据留在主机）
  → 实际执行事件/结果 → 原任务摘要/系统通知
```

这是目标数据流，不是已连接的运行结构。后端设计面向不同 harness，首个实现以 Codex 完整原生能力为基准；公共语义、capability 协商与原生扩展契约唯一维护在[Harness 规范](../standards/harness-integration.md)。自己的服务器是部署位置，Claude Code/Pi/Hermes/OpenClaw 等是执行器，两者独立；不能用 hostID 代替 harness 身份。只在实际实现共享行为时抽 package，避免先造空框架。保留自己的原生前台，不整仓 fork 第三方客户端；来源由[引用登记](../../references/README.md)维护，当前没有采用第三方运行时代码。

app 负责交互、权限请求、可恢复输入和设备凭据的安全保存；未来 gateway 负责授权、执行主机与项目映射、持久请求状态和受限事件流；Codex adapter 负责上游版本/schema 与错误映射。语音理解/视觉预处理是输入层，不能代替真实执行、伪造工具结果或绕过审批。原始音视频默认不进入执行日志。

## 协议契约（实现前的验收要求）

每个请求至少带 `protocolVersion`、`requestID`、`hostID`、`harnessID`、允许的 `projectID`、操作及受限 payload；建立会话后保存带 harness 命名空间的上游 `threadID`/`turnID` 映射。事件携带 gateway 的 `streamID`、单调 `sequence` 和 `requestID`；身份来自认证会话，不能相信 payload 自报的设备身份。具体 schema 由 F1 探针确认后实现，不能凭本文编造上游字段。

| 本项目状态 | 进入条件 / UI 语义 |
|---|---|
| `draft` | 仅本机输入，尚未发送 |
| `submitting` | 等待执行主机确认，不能显示运行中 |
| `accepted` | gateway 持久接受请求，仍非上游开始 |
| `running` | 上游确认真实任务开始；按事件呈现 |
| `awaitingApproval` | 与确切主机、thread、turn、approval request 绑定的待决动作 |
| `cancellationRequested` | 已请求中断，仍待终态 |
| `completed` / `failed` / `cancelled` | 对应任务的可信终态；结果有来源与时间 |
| `reconciling` | 发送后失联或崩溃造成结果未知，先核对，禁止猜测成功或重发副作用 |

连接的 `offline/connecting/online` 与任务状态正交：断网不证明 Mac 上任务停止。同一 `requestID` 的主机、harness、项目、操作与 payload 必须不可变，冲突请求明确拒绝并测试；按 ID 去重并返回已接受的任务，重连按事件游标恢复；游标缺口/流重置请求快照。gateway 去重不是上游 exactly-once 保证；在提交上游后、映射落盘前崩溃必须进入不确定状态，不能自动再次执行。协议测试覆盖这个窗口。

批准只影响当前有效请求，展示的动作与权限范围不可变；动作变化生成新的审批请求。双设备并发回答、过期、撤销或重连后先与主机核对；无响应不等于同意。取消回执不等于取消完成。未知事件/版本明确降级或拒绝；不能将无法理解的状态当完成。事件历史分页，流式输出有背压/大小上限，重试有时限与抖动退避；内存和上传不可随任务无限增长。

## 网络候选与首个探针

2026-11-17 的[固定版本与网络研究](../../references/codex-protocol-research.md)确认本机 0.162.1 有可选 WS Bearer 认证，但默认非 loopback 监听仍可能未认证，WS 传输也仍标实验。继续采用 Mac 本机 stdio adapter 边界；不把“CLI 有认证选项”当成可以直接开放公网。优先顺序为本机无模型协议探针 → 私有网络或受限 SSH 的 iPhone 工程探针 → Watch HTTPS 真机路径；公开 HTTPS/WSS gateway 或出站 relay 保留候选，当前未选服务、未配置网络。

私有网络/SSH 需要端点信任、最小设备/端口授权及 NAT 可达性证据，不能因隧道建立就显示任务可执行。普通 Watch app 的 WebSocket/低层连接受平台限制，因此网关应评估 HTTPS 短请求与有界状态读取；不能要求 Watch 套用 iPhone VPN 或长流。iPhone 在场与 Watch 独立 Wi-Fi/蜂窝分别验收。网络选择须同时满足设备能力、撤销、延迟/功耗和部署成本，缺证据时保持未决定。

若 relay 终止 TLS，它属于内容信任边界；两段 TLS 不等于设备到 Mac 的端到端加密。非可信 relay 必须使用经评审的现成 E2E 机制，并明确密钥确认、轮换、设备撤销和重放保护；模型/账号凭据始终留执行主机。首个蜂窝探针以前提“Mac 清醒在线”为准，不承诺网络唤醒；睡眠、合盖、重启未登录和服务中断另验，不自动更改系统电源/远程登录设置。

## 信任与数据

配对需在可信主机确认设备身份、短期一次性凭据、过期与撤销；每次执行校验主机和项目范围。网络层须提供端点认证和传输机密性；若引入非可信 relay，还需经评审的端到端保护及密钥轮换，不自创密码协议。禁止裸露 app-server 到公网，禁止把 Codex 登录或模型凭据复制到手机/relay，首版不提供任意 shell 透传或由输入指定任意工作目录。

项目授权由 gateway 的规范路径和 thread 归属映射决定，不能相信 payload 自报的 `cwd`。固定 schema 允许 `turn/start` 覆盖工作目录、审批和 sandbox，并影响后续 turn；每次执行均校验允许范围，拒绝移动端提升权限或注入任意 `config`。路径检查还须覆盖符号链接与授权后目标变化；项目范围不替代执行沙箱。设备撤销不仅拒绝新握手，还须终止或重新授权已连会话及待决审批；撤销本身不证明上游任务已取消。

项目范围不是完整执行沙箱；保留 Codex 权限策略，显式审批额外后果。任务输入、文档、网页和模型总结都是数据，不能扩展授权。日志只保留必要 ID、状态、时间和脱敏错误，明确保留期限；内容、媒体、token 默认不记录。新账本/共享容器在实现前决定单写者、版本迁移、备份恢复和导出/删除；不能让 extension 并发写当前 JSON 文件。

## 替代、代价与复查点

- 网络候选、探针顺序与未决证据见上文；具体官方来源和版本差异只在[协议研究](../../references/codex-protocol-research.md)维护。
- 解析终端文本难以可靠绑定审批与任务；结构化协议优先。任意 Codex Desktop 已有会话是否可继续必须实测，不承诺默认共享。
- 持续语音/视频及任何环境主动感知单独 opt-in，先验证单次会话。APNs/Watch 后台执行和语音播报受平台限制，不承诺持续在线或瞬时必达。

开始 F2 前完成真实版本探针、认证/撤销、异常窗口与有界资源测试；对外可用前做蜂窝→Mac、设备体验、数据控制验收。Mac 休眠、重启后未登录、服务停止和凭据过期均需明确提示。当前没有这些验证结果。
