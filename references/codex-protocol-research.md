# Codex F1 协议与认证路径研究

核对日期：2026-11-17；关联 R01/R02/R06/R07/R08/R09/R16。本文记录官方接口、固定版本 schema 和网络候选的证据；设计决定及信任边界唯一维护在[远程执行决策](../docs/decisions/remote-agent-foundation.md)，运行结果统一见[项目状态](../docs/project-status.md)。已执行隔离 stdio 与本机确定性 provider 驱动的原生生命周期实验；没有配置远程网络、账号、端口转发或付费服务，没有使用真实模型或执行真机/蜂窝测试。研究及本机夹具不是 F1/F2 通过。

## 本机版本与协议证据

本轮只读命令 `codex --version` 输出 `codex-cli 0.162.1`；`codex app-server --help` 与 `generate-json-schema --help` 均退出 0。复用本轮生成的默认/实验 schema，以[清单工具](../scripts/catalog-codex.py)运行 `--check`：四种方向合计 266 个方法、实现 0，退出 0。完整导出指纹与默认导出范围由[清单](codex-capabilities.json)保存，不在本文另维护一份方法列表。

| 证据 | 与首条探针相关的事实 / 限制 |
|---|---|
| 本机 CLI help；[app-server](https://learn.chatgpt.com/docs/app-server) | 默认 `stdio://`，另有 `unix://`、`ws://IP:PORT`、`off`；stdio 是 JSONL，WS 每个 text frame 一个消息。Unix transport 也是经 HTTP Upgrade 的 WebSocket，不是裸 JSONL |
| 同上 | 已有 `--ws-auth capability-token`（token file 或 SHA-256 verifier）、`signed-bearer-token`（shared secret file），可设 issuer/audience/clock skew；客户端在 WS handshake 用 Bearer，认证先于 `initialize`。有认证选项不表示默认已开启；文档仍标 WS experimental/unsupported、非 loopback 默认可未认证。非本机连接需 TLS 或安全隧道 |
| 固定 schema `ThreadStartParams` / `ThreadResumeParams` | 含 `cwd`、`approvalPolicy`、`sandbox`、任意配置对象 `config`；不能把移动端 payload 直接转交。Mac 根据已授权 project ID 解析路径、建立/恢复 thread 并验证其归属 |
| 固定 schema `TurnStartParams` | `cwd`、`approvalPolicy`、`sandboxPolicy` 可覆盖当前及后续 turn；每次调用都须重新限制，不能只在新建 thread 时检查。`clientUserMessageId` 仅有可空字符串定义，未见可据此承诺幂等的语义；JSON-RPC `id` 也不能当提交去重证明 |
| 固定 schema `TurnInterruptParams` / `TurnCompletedNotification` | interrupt 要求 `threadId` 和 `turnId`；最终通知携带对应 thread 与 turn。`TurnStatus` 包含 `completed/interrupted/failed/inProgress`；网关不能把收到了回执或某条通知直接映射成成功，必须核对终态与所属 turn |

[官方初始化](https://learn.chatgpt.com/docs/app-server#initialization)要求每连接一次 `initialize` → `initialized`；未初始化和重复初始化有独立错误。stdio stdout 只消费协议、stderr 单独有界收集；断连后的新连接重新握手，不能把 RPC response 当 turn 结束。`/readyz`/`healthz` 仅为 listener 健康信息，不证明模型已登录、特定项目被授权或任务可执行。

[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)与[高级配置](https://learn.chatgpt.com/docs/config-file/config-advanced)区分用户、系统及受信项目配置；独立 `CODEX_HOME` 不是完整隔离，仍须控制环境、项目资源、系统配置与可读凭据。当前在线文档称 `approval_policy="untrusted"` 已退役，而 0.162.1 schema 仍列此枚举；固定 binary、schema、在线文档的差异必须显式记录，不能用较新的网页推断旧 binary 已删除字段，也不能因枚举存在就选用该策略。

## 确定性 provider 与原生生命周期

官方 tag `rust-v0.162.1` 的 annotated tag 指向提交 `092d3acd6bec3e3a14bdc7e7a2810ab628ab759d`，通过 GitHub ref/tag API 核对。其[本机 Responses fixture](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server-test-client/src/loopback_responses_server.rs)及[工具响应测试辅助](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/tests/common/responses.rs)证明用固定 SSE 数据隔离模型的测试路径可行。本项目独立编写 Python 测试工具，只参考协议形状，未复制 Rust 实现或加入依赖。上游[根许可证](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/LICENSE)为 Apache-2.0；核对文件 10,926 bytes，SHA-256 `d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc`，不据此推断其他 SDK/模型许可。

新[生命周期探针](../scripts/probe-codex-turns.py)运行真实 native app-server、真实线程/turn/工具与持久化；模型端只返回固定合成内容。隔离限制沿用 no-turn 探针，仅对一个临时 loopback provider 端口放行 outbound；Codex 本身仍不能监听、访问其他端口/外部网络、读取个人目录/Keychain，或写入 fixture 外。`on-request/read-only` 下，`exec_command` 显式请求 escalation 后才出现反向审批；即使批准，子进程仍继承外层 OS 限制。

实际观察：

- `turn/start` 回应 `inProgress`，之后匹配 thread/turn 的 `turn/completed` 才提供终态；固定文本 turn 为 `completed`。
- 审批带原始 request/thread/turn/item、实际 command/cwd 与 `availableDecisions`。本机返回 accept、policy amendment、cancel；不能因 schema 包含 decline 就假定本次菜单提供它。探针仅单次回复 accept 或 cancel，绝不采用 session/persistent grant。
- cancel 拒绝使 turn 为 `interrupted`，标记文件未产生；accept 后真实 `/usr/bin/touch` 创建 fixture 文件、command item 为 `completed` / exit 0，随后合成 assistant item 和 turn 完成。两条审批均观察到匹配 `serverRequest/resolved`。
- 原生 turn 在等待 fixture provider 数据时接受 `turn/interrupt`，并最终为 `interrupted`。这证明等待模型响应时的中断，**没有验证运行中 shell/后台子进程的取消**。
- 旧进程优雅关闭，新进程重新初始化后读回四个 thread 的原 turn ID 和终态，再显式 `thread/resume` 重申 `on-request/read-only`，原 thread 新一轮合成 turn 成功。它不是崩溃恢复、未知提交去重或 pending approval 重放的证据。

恢复设计还需保留固定源码的边界：[尚未首条消息的 thread](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/tests/suite/v2/thread_resume.rs#L445)可能没有 materialized rollout；[并发 writer](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/tests/suite/v2/thread_resume.rs#L323)被拒绝；[恢复权限](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/tests/suite/v2/thread_resume.rs#L1051)可能来自历史，不能假定修改全局默认即可覆盖。上述三点为源码研究，尚未逐项运行负向实验。

本轮通过 metadata-only `thread/read` 加 `thread/turns/list(itemsView:"full")` 读取持久历史。直接 `thread/read(includeTurns:true)` 在运行时触发 deprecation notice；full/summary/notLoaded 及 `thread/items/list` 支持须按实际 history backing store 判断，不能把空摘要解释为丢失，或将某个 Unsupported 分支泛化为全版本不支持。参见[固定历史测试](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/tests/suite/v2/thread_read.rs#L457)。

### 官方 Key 与自定义 provider

2026-11-20 核对 Codex 0.162.1 的[固定版本配置 schema](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/core/config.schema.json)、[原生 account 协议](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server-protocol/src/protocol/v2/account.rs)和[历史恢复实现](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/src/request_processors/thread_processor.rs)。官方 Key 可用 `account/login/start(type: apiKey)`；成功回应不证明 Key 能调用模型。自定义描述符的 `base_url`、`env_key` 和 `wire_api: responses` 通过本地回环探针验证；官方内置 ID 不用自定义项覆写。冷恢复会读取保存的 provider 与 model；将同一个 ID 静默绑定至另一个服务不是安全的切换方式。[产品边界](../docs/decisions/remote-agent-foundation.md#codex-provider-与设备配对)单独维护。

## 账本集成与观察到的协议差异

固定 0.162.1 实际 notification envelope 附带整数 `emittedAtMs`，但生成 schema 未描述该 envelope 扩展。第一次 strict Swift 握手因未知字段拒绝；只读隔离握手核对后，client 显式接受该字段类型，未知 envelope 字段仍拒绝。不能把这个特例扩展成忽略任意消息差异。

`HostCodexSession` 现通过 `CodexAppServer` 接入真实 ledger、thread/turn 与 bounded stdio。启动/恢复强制 canonical project cwd、`on-request`、`read-only` 和 user reviewer；移动端不能提供配置/路径。原生参数与事件保留在授权 host 内，日志仅记录结构。POSIX `realpath` 用于比较原始 UTF-8，避免 Foundation 路径标准化将 `/private/var` 改为 `/var` 后破坏 NOFOLLOW 目录访问。

[八项本机集成实验](../docs/testing.md#ledger-integrated-native-codex-experiment)已执行合成 provider 下的真实工具、审批、执行中取消和特定故障窗口。pending approval 被杀后新进程读到同一 turn 为 interrupted；已持久 completed turn 可在 ledger 未提交终态时恢复；主机丢失上游映射时保留未知、不重发。它不证明恢复旧审批、任意中断点、真实模型或蜂窝路径。启动前登记的 fixture guardian 补上 host 在 native group frame 前死亡的清理窗口；具体进程原语与成熟替代见[进程研究](host-process-research.md)。当前观察结果由项目状态维护，能力清单仍全部为产品未实现。

## 第一条远程路径比较

以下均是候选，未部署。共同执行端保留 Mac 本机 stdio adapter 和 Munie 的项目/设备授权；网络只解决到达与通道认证，不能替代应用授权。

| 候选 | 能解决什么 | 首次接受前缺少的证据 |
|---|---|---|
| 私有网络 → Mac gateway → stdio | iPhone/macOS 可评估现成私有网络，避免裸 app-server 公网入口。[Tailscale 连接说明](https://tailscale.com/docs/reference/connection-types)将 direct、DERP、peer-relay 均列为 WireGuard 端到端加密；困难 NAT/受限 UDP 可能转中继，性能应分别测量 | 本人实际网络/账号选择、端点信任、设备与端口 grants、撤销后现有会话处理；iPhone 蜂窝可达性及中继延迟。其[官方平台表](https://tailscale.com/docs/install)列 iOS/macOS，不能据此承诺 watchOS 独立客户端或手表继承 iPhone VPN。未采用该服务或 SDK |
| SSH tunnel → Mac loopback gateway → stdio | [OpenSSH](https://man.openbsd.org/ssh)可加密转发到受限本地 endpoint，适合工程验证；[Mac Remote Login](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)是需显式开启的系统服务，本轮未开启 | SSH 主机指纹和最小权限账号/密钥、仅 loopback 绑定；NAT/CGNAT 下直接入站可能不可达，跳板或反向隧道另增可信边界。[ExitOnForwardFailure](https://man.openbsd.org/ssh_config#ExitOnForwardFailure)只检查转发建立，不证明最终服务健康。iPhone 内嵌 SSH 的依赖/前后台生命周期尚未评估，不把终端隧道当产品安装体验 |
| 公网 HTTPS/WSS gateway 或双向出站 relay → Mac stdio | 受控公共 endpoint 有利于独立 Watch 的 HTTPS 请求；Mac 主动出站可避开家庭入站端口映射 | 证书/域名、配对、速率和大小上限、防重放、可撤销设备身份、服务运维与内容信任方。WSS 在 relay 终止只保护两段链路，不等于设备到 Mac 的端到端内容保护；非可信 relay 需另选经评审的现成 E2E 机制及密钥轮换，不能临时自创密码协议。原生 app-server WS 认证不提供 Munie 项目授权 |

推荐先验证本机 stdio，再以私有网络或受限 SSH 通道隔离 iPhone 的认证/可达性问题；这只是工程探针顺序，最终网络方案尚未选定。未知项包括所有者现有网络条件、Watch 独立路由、真机功耗/延迟、撤销和常驻服务体验，缺少证据时不把其中一项写成已采用。公开 relay 只有在直接路径不满足设备需求且信任/部署成本明确后进入实测。

## Watch、睡眠与服务存活

[Apple TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)明确将 `URLSessionWebSocketTask` 也归为 low-level networking；普通 watchOS app 不能将它或 SSH/TCP 当作通用联网通道。特定音频/VoIP 等例外不能用来包装普通 Agent 请求，模拟器的放行也不证明真机可用。为 Watch 评估 `URLSession` HTTPS 的短请求、分页状态和恢复查询；iPhone 的实时流不必成为 Watch 的传输约束。

[独立 watchOS app 指引](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)要求能自行获取数据；WatchConnectivity 在 iPhone 可用时可辅助，不能作为唯一数据源。验收须分别记录 iPhone 在场、iPhone 设置中关闭 Wi-Fi/蓝牙后不可达、Watch 自己 Wi-Fi/蜂窝三类环境，并单独验证配对/撤销；手机蜂窝成功不能代替 Watch 独立成功。

[Mac 睡眠资源共享](https://support.apple.com/en-al/guide/mac-help/mh27905/mac)描述 Wake for network access，但没有承诺任意公网/VPN/relay 请求都可唤醒任意 Mac。F2 首轮前提保持为清醒在线主机；睡眠、合盖、断电、重启后未登录、服务退出和凭据过期分别呈现不可用或待核对，不猜测任务停止。未来唤醒/常驻方案需针对设备、电源、网络和登录状态实测，本轮不修改系统设置。

## 推荐探针顺序与证据卡

1. 固定 binary/schema；先用临时合成项目、独立状态目录、精简环境和可验证的操作系统限制做 no-turn stdio 探针。记录握手元数据、错误请求、有界脱敏 stdout/stderr 证据与退出状态；这一步不能证明模型、审批、取消或网络可用。可执行命令与隔离/清理契约见[测试](../docs/testing.md#opt-in-local-codex-protocol-experiment)。
2. 用离线故障夹具验证 gateway 项目授权、双设备审批、撤销、去重、事件缺口及未知提交窗口；夹具输出必须标为模拟，不能算真实 Codex 行为。
3. 本机确定性 provider 的原生生命周期、运行中工具取消及账本集成的特定崩溃窗口已运行；接着在合成项目中补真实模型、其他断连/异常窗口及审批重新核对策略。先明确模型/网络和费用范围，固定 thread/turn、输入、权限和终态证据，不从合成模型推断真实模型可用。
4. 对选定的首个认证通道做 iPhone 蜂窝→清醒 Mac 测试：拒绝未知/已撤销设备、限制项目、切网恢复、响应丢失、不确定提交核对；记录 transport、直连/中继、耗时、状态与失败。
5. 在 Watch 真机验证 HTTPS 独立路径、后台/通知与语音短交互，再决定是否需要公网 relay。每项失败有下一动作，未经验证不扩大可用性声明。

请求账本须在发往上游前持久记录本地 request ID、不可变目标/输入及提交阶段。若 `turn/start` 已写出但上游 ID 尚未落盘就崩溃，仍可能已经开始执行；schema 中没有已证实能消除该窗口的幂等保证。进入 `reconciling` 并读取可用会话/事件证据，无法确认时保持未知，禁止自动重发副作用。账本集成已实际执行这一映射丢失窗口并保持 reconciling；它未提供上游 exactly-once 保证或未知 ID 的自动恢复。
