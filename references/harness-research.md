# Harness 官方接口与适配研究

核对日期：2026-11-17。范围：Codex、Claude Code、Pi、Hermes Agent、OpenClaw、WorkBuddy、Qoder。仅核对官方文档与下列固定版本的接口/许可证文件；没有安装新的运行时、执行模型任务、引入依赖或复制上游实现。公开接口的存在不代表 Munie 已实现，也不代表账号、地区、所有平台和所有版本均可用。

产品优先级来自[需求基线](../docs/requirements.md)：先完整覆盖 Codex 的可用原生能力，再按真实需求增加 harness；未来候选不能降低 Codex 的能力上限。架构和执行状态见[远程执行决策](../docs/decisions/remote-agent-foundation.md)。本文记录证据与取舍，不充当已验证的远程连接结果。

## 接口与执行位置比较

| Harness | 已确认官方集成面 | 适配候选与必须保留的差异 |
|---|---|---|
| Codex | [app-server](https://learn.chatgpt.com/docs/app-server)：双向 JSON-RPC，stdio；文档另列实验 WebSocket transport。CLI 可生成对应版本的 JSON Schema | 自有 Mac 本机 app-server 为首个候选；保留 thread/turn、事件、审批、输入、配置、工具与原生扩展。不能用一条 prompt/completion 替代完整控制面。具体版本和方向清单见 [Codex inventory](codex-capabilities.json) |
| Claude Code | [非交互 CLI](https://code.claude.com/docs/en/headless)：`claude -p`，JSON/stream-json；[Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview)：Python、TypeScript | 本机 SDK/CLI adapter；保留原生消息、会话恢复、工具、权限回调与上下文配置。本轮未确认 Claude Code 自身提供官方 ACP server；第三方 ACP bridge 是独立依赖 |
| Pi | 固定源码的 [RPC](https://github.com/earendil-works/pi/blob/e03dca7a38431b9c4e228868d52047030b26eae8/packages/coding-agent/docs/rpc.md)：`pi --mode rpc --no-session`，stdin/stdout JSONL；[TS SDK](https://github.com/earendil-works/pi/blob/e03dca7a38431b9c4e228868d52047030b26eae8/packages/coding-agent/docs/sdk.md)：`@earendil-works/pi-coding-agent` | 自有 RPC/SDK adapter；保留 session branch、compaction、extension UI、abort 与事件语义。旧地址 `badlogic/pi-mono` 当前重定向到 `earendil-works/pi`，接入前重新固定仓库身份和版本 |
| Hermes Agent | [官方三种接口](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration)：`hermes acp` 的 stdio ACP、TUI gateway 的 JSON-RPC stdio/WS、API server 的 HTTP/SSE | 三个面暴露能力不同。完整自定义前台优先评估 TUI gateway；现成 ACP 客户端可评估 ACP；HTTP 会话不能假设接管 CLI/TUI/Desktop/ACP 的已有会话 |
| OpenClaw | [Gateway 自有 WebSocket 协议](https://docs.openclaw.ai/gateway/protocol)，包含请求、响应和事件 | 独立 gateway adapter；保留配对、设备身份、roles/scopes、会话和其原生方法，不默认归类为 ACP 或单次 completion |
| WorkBuddy | [Open API](https://open.workbuddy.cn/docs/openapi)：OAuth、PC 本地助理 HTTP API、云任务 HTTP API、云会话 ACP；[connector](https://open.workbuddy.cn/docs/connector) 是另一方向的工具集成 | 本地助理与云任务分开登记执行位置和能力。云 ACP 是 SSE 接收加 POST 发送的双通道，不能套用 stdio 生命周期。官方本地控制 API 确实存在，不能只研究 connector 后断言无法控制 |
| Qoder | [脚本运行](https://docs.qoder.com/cli/run-in-scripts)：`qoder --print`，JSON/stream-json；[SDK](https://docs.qoder.com/cli/sdk/overview)：TS/Python/Java；[ACP](https://docs.qoder.com/cli/acp)：`qoder --acp` stdio | 根据原生控制覆盖选 SDK 或 ACP。保留 stream、session/resume/fork、权限、interrupt、background task 等；SDK 语言间存在功能差异，不把一门语言的支持推给全部语言 |

MCP 用于向 harness 提供工具/资源，ACP 用于客户端驱动支持该协议的 agent；Codex app-server、Pi RPC、Hermes gateway 与 OpenClaw Gateway 各有自己的方法和生命周期。JSON-RPC、stdio、WebSocket 或“支持 MCP”都不能证明它们协议兼容。WorkBuddy 官方所称 ACP 还包含 `_codebuddy.ai/` 私有通知，须独立处理。

## 认证、审批和终态证据

### Codex

[app-server 文档](https://learn.chatgpt.com/docs/app-server)要求每连接初始化，再选择 thread 并开始 turn；消费事件到 `turn/completed`，中断请求的回执不能作为取消终态。反向审批请求须与对应动作和会话关联。模型账号认证与 Munie 设备配对是两层边界；账号凭据留在执行主机，不能复制给手机或 relay。

首轮考虑本机 stdio。[审批与安全](https://learn.chatgpt.com/docs/agent-approvals-security)的沙箱和审批不能被远程入口提升。当前文档将 WebSocket 标为 experimental/unsupported，非 loopback 默认可能未认证；不直接暴露公网。`thread/shellCommand` 不继承 thread sandbox，不能因完整枚举方法就默认向移动端开放任意 shell。覆盖清单、授权策略与用户入口分别记录。

### Claude Code

[SDK quickstart](https://code.claude.com/docs/en/agent-sdk/quickstart)以 API key/provider 凭据认证，并明确未经批准的第三方产品不能提供 claude.ai 登录或订阅额度。不能把个人 CLI 登录可用推成可公开集成的授权。SDK 可能随包带原生 Claude Code binary，SDK 源码许可不自动覆盖该 binary。

[审批回调](https://code.claude.com/docs/en/agent-sdk/user-input)中的 `canUseTool` / `can_use_tool` 处理未被前置权限规则决定的请求和用户问题；不能声称拦截一切动作。[headless 文档](https://code.claude.com/docs/en/headless)说明普通 `-p` 会发现 hooks/MCP 等项目资源且没有交互式信任提示；`--bare` 可减少发现，但改变功能并要求其文档支持的 API/provider 凭据，不能当完整隔离或订阅登录替代品。适配器必须明确加载策略，不能无声关闭用户需要的原生能力。

### Pi

[安全文档](https://github.com/earendil-works/pi/blob/e03dca7a38431b9c4e228868d52047030b26eae8/packages/coding-agent/docs/security.md)说明 Pi 以启动账号的系统权限读写/执行，不会逐次要求所有工具审批；project trust 控制资源发现，不能隔离工具执行。非交互 RPC 的信任选择须显式确定，扩展也是宿主代码；工作目录不等于文件系统沙箱。认证由宿主配置的模型 provider、API key/OAuth 决定；需要独立的最小凭据和执行隔离设计。

[RPC 文档](https://github.com/earendil-works/pi/blob/e03dca7a38431b9c4e228868d52047030b26eae8/packages/coding-agent/docs/rpc.md)区分请求 `response`、`agent_end` 与 `agent_settled`；最终静止以相应运行的 `agent_settled` 为准。`prompt` disposition 为 `handled` 时没有新 run，不能盲等结束事件。持续读取 stdout、关联请求 ID、处理背压；stderr 是诊断，不能混入协议流。

### Hermes Agent

[ACP](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp)提供会话、流、审批、fork、cancel/auth，但使用 curated `hermes-acp` toolset，不能宣称覆盖所有 messaging/cron 能力。客户端必须真正呈现权限请求，不能以自动批准补齐流程。

[TUI gateway](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration)当前 shared `/api/ws` 使用 `hermes-gateway-v1` 和每连接一次性 ticket，`hermes gateway attach --json` 返回连接信息；重连需新 ticket 并核对 runtime 能力。[API server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)使用 `API_SERVER_KEY` Bearer、默认 loopback；其 canonical/legacy API 的幂等语义有差异。模型认证、gateway 认证、Munie 配对分别处理，不能给所有接口统一承诺 exactly-once 或会话互通。

### OpenClaw

[握手](https://docs.openclaw.ai/gateway/protocol/handshake)为 challenge → `connect` → `hello-ok`；示例协议当前为 v4，实施时固定具体版本。接受认证握手后才显示已连接状态。`hello-ok.features.methods` 是保守发现信息，不是完整方法枚举，覆盖研究另查[方法文档](https://docs.openclaw.ai/gateway/protocol/rpc-methods)和固定 schema。

[认证](https://docs.openclaw.ai/gateway/protocol/auth)涉及 token/password、设备签名与配对、角色及 scope、设备角色 token 的轮换/撤销；端点信任、TLS pinning 和失败重试边界需要按部署方式核对。不能把“有 gateway token”当成对所有项目和所有动作的授权，也不能把其设备身份直接复用为 Munie 的身份。

### WorkBuddy

[Open API](https://open.workbuddy.cn/docs/openapi)将认证称为 OAuth 2.1 授权码流程，要求注册第三方应用和 `client_secret`，返回 access/refresh token。本文核对页面未见 PKCE 参数或公开原生客户端方案；不能自行假定支持。密钥交换应留可信服务端/主机，必须校验回调 state、限制 scopes，不能把应用密钥放入 iPhone/Watch。

| 执行面 | 已确认调用/授权 | 不能推断的保证 |
|---|---|---|
| 已连接的 PC 本地助理 | `GET /openapi/v2/localassistant` 查在线；`POST /openapi/v2/localassistant/message` 发消息；`GET` 同路径分页/增量读历史。scope 为 `user.localassistant.readable` / `user.localassistant.invokable`；`permission_response` 用 `requestId` 关联下行请求 | 返回 `message_id` 只证明消息创建，不能作为工具完成。尚未实际验证 Mac 上的助理选择、工作区选择、取消、重复提交、终态和多设备冲突 |
| 云任务 | `POST /openapi/v2/tasks` 创建，`user.task.invokable`；列表/详情用 `user.task.readable`。详情获取新的 ACP link/token；SSE GET 和 JSON-RPC POST 以 `Acp-Connection-Id` 关联 | 云沙箱不等于用户自己的 Mac。列表不返回 ACP token；REST 接受不是本轮完成。ACP 的 `session/prompt` response 和 `stopReason` 才说明对应轮结束，不能把任意流增量视为完成 |

本地消息接口与云 ACP 的审批编码不同，按实际接口解析。云 ACP 另有产物私有通知与 REST 快照，保留 native 数据并控制权限；不要把其扩展当标准 ACP。相邻 [CodeBuddy CLI ACP](https://www.codebuddy.ai/docs/cli/acp)、[headless](https://www.codebuddy.ai/docs/cli/headless)与[认证](https://www.codebuddy.ai/docs/cli/iam)是另一个产品/运行时的证据，不能证明可控制 WorkBuddy 桌面现有会话。此处 WorkBuddy 指[腾讯官方产品](https://cloud.tencent.com/product/workbuddy)，未替换为其他同名服务。

### Qoder

[认证](https://docs.qoder.com/cli/authentication)支持浏览器交互或 `QODER_PERSONAL_ACCESS_TOKEN`；[ACP](https://docs.qoder.com/cli/acp)复用 CLI 登录状态。默认 permission mode 与 `--yolo` bypass 是不同路径，Munie 不能默认 bypass。工具/terminal 由客户端提供的情形须额外限制 host 能力，不能认为 stdio 自动隔离。

[SDK 文档](https://docs.qoder.com/cli/sdk/overview)区分本机 runtime 与模型服务；TS/Python 包含兼容 CLI，Java 首次下载对应 release 固定 CLI。接入前锁定 SDK/runtime、审核下载验证及更新策略，逐语言检查能力。保留原生事件、结果和中断语义；[服务条款](https://qoder.com/product-service)不能被“SDK 官方开放”替换为开源许可。

## 固定源码与许可边界

以下是本轮只读核对的版本，尚未加入运行时依赖或源码复用清单；正式采用须按[复用决策](reuse-decisions.md)另登记取得方式、notice、依赖和实际使用范围。仓库根许可不自动覆盖模型、第三方 SDK、资产、托管服务与商业 binary。

| 官方仓库/对象 | 固定版本 | 已读取的许可与采用边界 |
|---|---|---|
| OpenAI Codex CLI | `rust-v0.162.1` → `092d3acd6bec3e3a14bdc7e7a2810ab628ab759d` | [LICENSE](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/LICENSE)：Apache-2.0。tag 来源核对不等于本机 binary 可复现构建证明 |
| Claude Agent SDK Python | `4720d367f7db9d5df8a166c74d7f36a538ac8c34` | [LICENSE](https://github.com/anthropics/claude-agent-sdk-python/blob/4720d367f7db9d5df8a166c74d7f36a538ac8c34/LICENSE)：MIT；不覆盖随包 Claude Code binary 或 Claude 服务 |
| Claude Agent SDK TypeScript | `7befb6ff11dc33172a6db25b890b90a39889f311` | [LICENSE.md](https://github.com/anthropics/claude-agent-sdk-typescript/blob/7befb6ff11dc33172a6db25b890b90a39889f311/LICENSE.md)：保留所有权利，适用 Anthropic Commercial Terms；不能与 Python SDK 一并标为 MIT |
| Pi | `e03dca7a38431b9c4e228868d52047030b26eae8` | [LICENSE](https://github.com/earendil-works/pi/blob/e03dca7a38431b9c4e228868d52047030b26eae8/LICENSE)：MIT |
| Nous Research Hermes Agent | `dff103e05878bfa321301f6ab74ce766a29f1345` | [LICENSE](https://github.com/NousResearch/hermes-agent/blob/dff103e05878bfa321301f6ab74ce766a29f1345/LICENSE)：MIT |
| OpenClaw | `bd25e9ef60cc886dc6c0512927bf1cf425e364df` | [LICENSE](https://github.com/openclaw/openclaw/blob/bd25e9ef60cc886dc6c0512927bf1cf425e364df/LICENSE)：MIT |
| WorkBuddy / Qoder 商业产品 | 本轮依据上文官方在线文档，未固定可分发 runtime | 未取得可据此复制商业客户端/运行时的开源许可；只采用接口研究。实施前分别核对账号、平台/API 使用与分发条款，不能以其他同名仓库许可替代 |

## 对 Munie 架构的推论与后续验证

以下是项目推论，不是上游承诺。公共层统一主机、harness、项目、请求身份、受信事件、设备授权和展示状态；每个 adapter 同时保留 provider-native namespace、能力声明、原始方法/字段方向和终态证据。`hostID` 表示执行位置，`harnessID` 表示运行时，二者独立；自己的服务器不等于一个新的 harness。

能力声明应覆盖版本、请求/响应、事件、反向调用、输入类型、会话控制、工具、权限、配置及原生扩展；逐项标注已实现、待实现、版本/账号受限或明确禁用的原因。Codex 从[生成清单](codex-capabilities.json)逐项建立覆盖证据，不因其他 provider 缺少某能力而删去它。方法数量不证明字段/事件变体覆盖，更不证明 Codex Desktop 全部 UI 已被公开 API 暴露。

保留 native 信息不代表开放任意 RPC 透传：gateway 仍按方法、项目、设备和当前审批校验；未知方法默认拒绝，未知事件保留脱敏诊断并明确状态未确定。敏感 wire payload 不能默认持久化；需要重放的状态采用有界、最小必要、受保护的数据。不能借保留原生数据建立绕过授权的后门。

先完成 Codex 真实蜂窝闭环：配对/撤销、限定项目、流事件、审批、重连/游标缺口、去重、崩溃不确定窗口、取消终态、主机睡眠与结果通知。随后每增加一个 harness，先固定协议/runtime/许可证，再建立本机合同夹具和真实运行验收；不可用能力在客户端明确体现，不静默切换 provider 或重开任务。当前七类均没有 Munie adapter 运行结果，不承诺完成日期或把文档核对计入功能验收。
