# 设备信任、主机服务与知情审批

日期：2026-11-18。状态：**首个 iPhone–Mac 产品切片的实现决策；实际设备、网络与分发验收分别记录**。关联 R01/R02/R03/R06/R07/R08/R09/R16/R18/R19。任务状态唯一见[远程决策](remote-agent-foundation.md#task-state-contract)，实现边界见[架构](../architecture.md)，执行证据见[项目状态](../project-status.md)，官方来源、替代方案和许可证见[产品实现依据](../../references/product-remote-implementation.md)。本页取代“必须先完成持久 mTLS 身份才能接入产品”的实施顺序；既有身份研究与失败证据保留，不作为整个产品的合并前置条件。

## 当前选择与可信边界

当前产品选择 **iPhone 原生 HTTPS → 同一执行 Mac 上的 Tailscale Serve → `127.0.0.1:9274` 的 Swift HTTP listener → 本机 Codex**。两端需要已授权的私有 tailnet 连接，Tailscale 是单独安装、登录和配置的可信主机服务。Serve 在这台 Mac 终止 TLS；其后的同机 loopback hop 是 HTTP，不能称为一直加密到 Swift actor 的 TLS 或经过其他终止代理的端到端加密。不使用公网 Funnel，不开明文 LAN listener，不把 `Tailscale-*`/forwarded headers 当成应用设备身份。尾网访问规则限制网络到达范围；应用仍要求每设备独立的高熵 bearer grant。

选择现有私有 HTTPS 服务是为了让完整 iPhone 路径先成为可运行产品，避免先实现 issuer、CSR、跨平台证书续期和自建 relay。它并不证明 Watch 能独立使用这条网络；Watch 不继承 iPhone VPN 的假设仍有效，其短任务/反馈和独立网络保持后续单独范围。Mac 睡眠、退出登录或服务停止时明确不可达，不改电源设置，不承诺自动唤醒。

正常客户端只接受 HTTPS、系统服务器证书验证及固定 `/v1` 请求，不跟随重定向，不自动向其他认证挑战交付凭据。Debug 测试有独立命名、显式选择的 loopback HTTP 初始化器；它不是 iPhone 配对或外网验收路径。配对二维码来自用户面前可信的 Mac 界面，手机提交前先建立该 HTTPS 连接。

## 一次配对与凭据生命周期

| 阶段 | 已实现的权威动作与边界 |
|---|---|
| Mac 发起 | 用户先在 Mac 选定项目并创建邀请。系统随机生成 256-bit secret，120 秒有效；服务仅保留其 SHA-256 摘要和临时上下文。QR/手动 JSON 包含 endpoint、hostID、secret，属于敏感短期材料，不放进 URL、通知或诊断 |
| iPhone 提交候选 | 手机本地生成随机 256-bit pairing secret 和 UUID，仅在 HTTPS body 中提交邀请、候选 ID、secret 与设备标签。Mac 将邀请绑定一个不可变候选；其他候选竞争/替换拒绝。每邀请最多五次失败；每次只允许一个待确认候选 |
| Mac 明确确认 | 双端显示 pairing secret 的 SHA-256 前 16 个十六进制字符用于核对，Mac 展示设备标签与明确选中的项目控制范围。此摘要是配对上下文的辅助指纹，不是公钥指纹、TLS 客户端证书或硬件身份声明。手机自报名称不授予权限 |
| 签发 grant | 只有 Mac 本地确认后，主机才创建新 deviceID、登记项目 grants 并生成独立 256-bit bearer token。持久文件只存 token 的 SHA-256 与设备/项目授权；原 token 仅留在当前临时配对会话，用匹配邀请、候选 ID 和 secret 的轮询返回。重复轮询只返回同一 token，不重复授权 |
| 手机保存与确认 | 手机先用 token 查询并核对 hostID，再保存到非同步 `WhenUnlockedThisDeviceOnly` Keychain。首次成功认证清除主机临时签发材料；服务重启或邀请过期也清除它们。确认回执丢失且无法取回 token 时重新在 Mac 明确配对，不从摘要还原或自动再签发 |
| 日常认证与撤销 | 每项业务请求验证 bearer 摘要、live device enabled 与项目 scope；任务还受 origin-device 隔离。Mac 撤销持久生效，旧 token 不能通过新请求或既有 HTTP 连接恢复权限。重新配对使用新 deviceID；手机“忘记连接”仅删本机 Keychain，不能当作 Mac 已撤销 |

这是 TLS 上的 bearer 授权，不是自创密钥交换或自签名认证协议。持有 token 的一方在可达私有网络内拥有该 grant；不声称 token 与不可导出的设备私钥、Secure Enclave 或 TLS peer leaf 绑定。当前 token 没有自动续期/轮换机制，丢失设备需在 Mac 撤销并重新配对。Keychain 的存储访问保护不证明已经载入内存的 token 会在锁屏瞬间清零；产品不通过放宽保护实现持续后台请求。

Codex 账号仅在执行 Mac：本地明确启动服务时，从已有登录初始化专用、私有的 Codex home，不向手机提供账号、环境、原始初始化 payload 或个人 MCP 配置。APNs 的可选签名配置也仅由主机所有者放在主机私有配置中。常规诊断只记录必要 ID/结构化状态，用户输入、审批命令和结果正文属于私有业务内容。

## 项目授权与持久状态

当前 `HostSubmissionLedger` schema 1 的 origin-device 限制保留；grant 允许设备在选定 canonical 项目中提交/读取/继续自己的任务并回答支持的审批、请求中断。第二台设备即使获准同一项目，也不能读取或接管第一台设备的既有会话。owner 级跨设备共享、独立 read/control 权限和桌面任意会话接管尚未实现，不能通过“同一主人”的标签绕过现有授权。

主机只接收固定版本业务操作：`status`、`submit`、`approve`、`cancel`、`registerNotifications`，以及无任务权限的短期 `pair`/`pairStatus`。项目注册、配对批准、撤销和数据管理只在 Mac 本地组合入口执行；HTTP 没有任意 RPC、路径选择或管理接口。项目 grant 固定执行 working directory 与任务访问 scope；支持的 native read-only/on-request sandbox 和完整命令审批仍是工具权限边界，不额外宣称任意获准 shell 都只能访问项目文件。

`ProductPersistence` 的私有历史文件与 SQLite ledger 各持独占 owner，显式校验版本、hostID、文件类型/权限及有界内容，不以重建存储修复损坏或未知版本。持久化正文与任务结果是此次产品新增能力，不复用本地 capture JSON，也不将研究夹具目录无提示变成个人产品数据。两份存储不假装成一个事务：product accepted 早于 ledger accept 的窗口，只有完整 ledger 的 unknown/accepted 证据才可记 failed/not-started；dispatching/running 或丢映射必须保持 reconciling，不能盲发。

每轮有独立稳定 requestID，继续会话保持 conversation ID，并由主机从既有授权映射取得 native thread。取消意图在 interrupt RPC 前落盘；审批与取消都必须匹配当前 requestID，旧屏幕不能控制较新的 turn。Mac 可删除已终结的对话正文，但保留请求去重记录、native 映射和撤销记录。任意旧备份回滚、跨存储导入/迁移、完整导出与抗回滚 trust epoch 尚未建立，不能声称恢复旧备份仍保持所有新撤销。

## 主机权威的知情审批与取消

主机保留完整 `CodexCommandApproval`，手机取得绑定当前任务/request、native 会话与短有效期的 UUID handle，并完整显示 command、cwd、reason。command 是被批准的真实动作；模型 reason 是未可信解释。当前只实现 native 单次 `accept/cancel`，不将 session、execpolicy、持久 grant 或未知审批类型映射成同意。超过完整呈现上限的审批失败关闭批准路径，不截掉动作后继续显示批准按钮。

回答前主机重查 live grant、当前 request、native 完整对象、期限和取消/终态；在 native await 前一次消费 handle，重复点击、重放和旧会话答案拒绝。设备断线后在原期限内仍可查询同一 pending handle；主机/native 重启不会复活审批。产品 60 秒超时会请求 native interrupt；仅过期、回答拒绝、interrupt acknowledgement、HTTP 断开和进程关闭都不能自行宣称 cancelled，必须观察匹配 native terminal。

锁屏通知、Siri、Action button 和 Shortcuts 只导航，不提供缺少上下文的快速批准。当前前台 UI 承担完整动作审阅；其双语、长命令、双向/控制字符、VoiceOver 与大字行为须按实际设备分别验收，不能由 synthetic token/固定命令测试推断。

## 每用户 Mac 服务与资源所有权

首片采用原生 `MunieHost` 前台/菜单栏伴随 app，直接拥有相同 runtime actors，用户显式选择 `SMAppService.mainApp` 登录启动。没有另建 root daemon 或将研究 stdin 升格成可信产品 IPC。窗口关闭不停止服务；用户停止服务或退出 app 会停止接收请求并清理 native transport，未知工作保持 reconciling。注册成功只表示登录项配置，不证明已开机登录、listener 就绪、账号可用或 Mac 可从蜂窝到达。

`ProductHost` 独立拥有单一 native event pump，手机断开或停止轮询不取走 reader。无任务队列、最多一项 active task；容量不足的新请求明确 busy。native 终态先经 ledger 落盘，再更新业务历史与对外状态；中间崩溃由已知 ID 正证据核对，缺历史不伪造结果。native assistant-history 恢复只投影受限 `agentMessage.text`，不返回原始 command/stdout/account/path payload。

C guardian 与 native leader 在 transport 已建立的进程组中启动，避免依赖稍后发布 PID 的清理窗口。它观察真实 parent 关系并清理该组剩余成员，正常 transport 另外验证 EOF、leader 和 group disappearance。该机制不等于 signed login/update/logout 全生命周期验收，也不自动覆盖有意脱离进程组的后代。主机存储失败与进程清理独立尝试，不能因落盘失败跳过关闭 native。

| 已实现界限 | 具体行为 |
|---|---|
| HTTP listener | 只绑定 `127.0.0.1`，默认端口 9274；最多 16 个连接、每连接一个请求；8 KiB header、64 KiB encoded body、2 MiB response、30 秒整体连接 deadline；拒绝歧义长度、transfer encoding、origin 和多余请求字节 |
| 任务/历史 | active 1、conversation 1,000、request identities 10,000、projects/devices 各 100；product history 文件 16 MiB；文本输入 32 KiB。状态列表仅返回轻量摘要，选中任务才返回正文，避免历史令重连响应永久超限 |
| 正文/审批 | 当前对话消息编码最多 768 KiB；新 turn 要为结果保留空间。assistant text 编码超过 256 KiB 明确显示 truncated；审批 command/cwd/reason 分别受限，完整内容不能呈现则不允许批准 |
| native transport | 固定帧/字节/队列界限保留；产品将 read/session deadline 设为 300/900 秒。超时是未知/核对，不能假报任务成功或已取消；不称作无限长任务服务 |
| 通知/移动 | 有界独立通知 delivery queue，不阻塞 native reader；APNs 请求 deadline 由 transport 限制。手机只在 active scene 且有 nonterminal task 时每两秒查询；无 idle/background 常驻业务轮询 |

这些是代码界限，不是 Apple 指标或 Release 性能通过记录。主机单用户文件权限、Keychain、native sandbox、HTTPS、tailnet rules 分别承担不同保护；不凭一个 synthetic 通过就宣称所有边界均接受。通知可选 APNs 需要主机密钥、签名 entitlement 和实际 device token；目前的本地 generic notice 仅提示已观察到的完成/失败/待审批，权限、Focus 与背景投递仍受系统约束。

## Deferred mTLS alternative

2026-11-17 的本地密钥/CSR/证书/mTLS 设计继续作为暂缓备选，具体证据、固定依赖与许可保留在[认证网络研究](../../references/authenticated-network-research.md#设备本地密钥续期与每用户-host-服务的可行性依据)和[独立 identity 夹具说明](../testing.md#opt-in-local-key-identity-experiment)。内存 SecKey/CSR/证书组合和各 SDK 声明不证明持久 Keychain、Secure Enclave、锁屏、iOS/Watch 实机行为；未完成的身份研究 PR 不成为当前 bearer/HTTPS 切片的前置合并条件。

若后续选择此方案，仍须共同满足原设计的接受事件：可信 Mac 邀请绑定确切 endpoint/trust anchor 和不可替换 CSR；先固定批准输入、签名与确切 DER 落盘，再由匹配的实际 peer leaf 激活；重启终止全部 pending enrollment，丢 ACK 只确认既有 active identity，不重复签发或 grant。设备私钥本机生成、不导出，证书用途/期限/公私钥匹配、Keychain access group、锁定/重启/删除/备份语义及实际 URLSession challenge 分平台验证。不能把普通 PKCS#12 导入或内存 identity 当作等价证据。

正常续期须维持原 deviceID 和当前 scope，证书独立退役/撤销不复活 device tombstone；原候选的七天 leaf、提前一天续期、十分钟重叠是待验证参数，当前 bearer 产品没有这些生命周期。issuer/trust 变化、旧备份恢复和无钥恢复需要独立可信 epoch 或重新配对方案。owner/project read/control schema、跨设备共享审批和接续必须显式迁移，旧 B 不能因同一项目/owner 标签自动读 A。

另行采用 per-user `SMAppService.agent(plistName:)` helper、经过签名对端验证的本地控制 IPC、分页 event journal/cursor/epoch、流量与磁盘生命周期时，应针对具体实现需要重新评审，不从当前 main-app 登录项或静态设计推断已存在。普通 Watch 的独立 HTTPS、蜂窝连接、硬件入口和反馈在单独里程碑验证，不扩大本次完成声明。

## 接受事件与剩余验收

Synthetic 产品/历史与既有 native client/coordinator 回归验证软件状态边界，不能替代实际账号、系统签名或硬件；具体命令与结果仅在[测试](../testing.md)和[项目状态](../project-status.md)维护。真实模型服务、iPhone/蜂窝、登录项运行、麦克风/中断、双语无障碍与通知须分别按[平台验收](../standards/platform-acceptance.md)记录。用户对临时项目真实模型/标记读写/受控等待与取消的授权，仅适用于该有界验收；Tailscale 账号登录、签名与外部通知凭据仍取实际可用条件。完成一个 loopback 检查不把这些未执行分支标成通过。
