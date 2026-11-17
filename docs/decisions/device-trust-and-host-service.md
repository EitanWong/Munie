# 设备信任、主机服务与知情审批

日期：2026-11-17。状态：**下一原型的工程设计与准入条件**；尚未实现配对、产品主机服务、跨设备授权或移动审批。关联 R01/R02/R03/R06/R07/R08/R09/R16/R18/R19。任务状态唯一见[远程决策](remote-agent-foundation.md#task-state-contract)，实际结果唯一见[项目状态](../project-status.md)，API、成熟组件与许可依据见[网络研究](../../references/authenticated-network-research.md)。本页固定这些机制的设计，不再维护另一份能力完成表。

## 方向与适用边界

原型采用标准 TLS 客户端证书认证，Apple 客户端通过 `URLSession` 发 HTTPS 短请求；Mac 自己终止 TLS、授权并驱动本机 Codex stdio。设备各有私钥，Codex 账号凭据留在执行主机。本地生成密钥→回签证书→原生 `SecIdentity`→mTLS 的内存组合已有独立 Mac 研究夹具，结果只见[项目状态](../project-status.md)；正式实现库、持久凭据策略和产品 wire schema 仍未冻结。先前临时 PKCS#12 导入与新的本地密钥组合是不同证据。

网络寻址与设备信任分开。研发 listener 默认只绑定 loopback；增加 LAN/外网入口须显式配置和验证路由。首个蜂窝候选必须让普通 Watch 直接访问 HTTPS，不能要求 Watch 继承 iPhone VPN、运行 SSH 或保持低层长连接。私有网络/受限隧道可作 iPhone 工程对照；公网端点、DNS、TLS 透传或 relay 的部署/成本尚未选择。TLS 若在 relay 终止，它就是内容接收方；未通过现成端到端机制评审前不能接受该部署，更不能称两段 TLS 为端到端保护。不安装服务、不注册域名、不改系统信任/电源/远程登录来实现本设计。

首个原型保留一个 active task，明确拒绝容量不足的新任务；这不是完整 Codex 多任务支持的产品上限。完整能力仍逐项按[Harness 清单](../standards/harness-integration.md)实施。所有 numeric limits 下文均为项目的**候选研究界限**，需根据原型结果调整，不是 Apple 规范或性能通过记录。

## 一次配对：可信 Mac 确认精确设备

用户在选定的 Mac 前台主动打开配对，手机扫描 Mac 显示的 QR。QR 是短期敏感邀请，不进入 URL/query、剪贴板、诊断、通知、分析或截图夹具；设备先验证服务再发送邀请。没有相机的设备需在自己的公钥和授权范围可被 Mac 确认的系统接续路径中独立登记；不能从 iPhone 复制私钥或默认给 Watch/TV 同等权限。具体 Watch 接续原型单独验收。

| 阶段 | 权威状态、输入与接受事件 |
|---|---|
| 本机创建邀请 | Mac 生成 `invitationID`、至少 256-bit 系统随机 secret、120 秒期限；仅保存 secret 的安全摘要。QR 绑定 `protocolVersion`、`hostID`、精确 HTTPS endpoint、服务端信任锚 DER 与其 SPKI SHA-256 pin、邀请。host/endpoint/信任锚的改变不能沿用旧邀请；客户端 issuer 的信任配置由 Mac 管理，不能由 CSR 选择 |
| 设备建立 bootstrap TLS | 验证固定 CA/信任锚、hostname/SAN、有效期、用途及预期 pin，挑战仅限所选 host/port；全部通过后才以请求 body 发送邀请。拒绝重定向、自动发现的陌生端点和信任失败；不设 ATS 全局例外 |
| 生成并提交 CSR | 私钥在设备生成并留在本设备安全存储；仅发 PKCS#10 CSR/public key。服务验证签名、算法/大小与邀请，原子地将邀请绑定一个不可变 CSR。设备名称是未可信标签；CSR 不能选择 deviceID、CA 能力、owner 或 grants |
| Mac 明确确认 | 展示确切邀请/候选设备、公钥摘要、选定项目及 read/control 的后果。设备端可核对同一配对上下文；不能只凭自报名称确认。不同 CSR 竞争/替换时拒绝并允许用户取消重建邀请；邀请被偷拍/抢占不自动成为已配对设备 |
| 签发但未激活 | issuer 设定 serial、clientAuth、受限用途及期限。顺序为持久化 approved（固定 CSR/公钥、serial/TBS 与 grants revision）→签名→持久化确切证书 DER→才返回证书；签发不授予任务访问。签名或 DER 未落盘不得发送，不能跨 DB/Keychain 假装一个事务。同一次未重启的 enrollment 丢响应只能返回已存的同一 DER，不能重新签名、再 grant 或造第二个身份；重启失效规则见下行 |
| 设备安装与激活 | 设备保存回签证书并与原私钥形成 identity。专用 activation route 接受链验证通过但仍 pending 的实际 TLS peer leaf，精确匹配其 CSR/credential/enrollment；无证书 bootstrap、自报 body 中的证书/ID、同 CA 的另一张 active 或未知 leaf 均不能代为激活。最终 CAS 再核对实际 peer、固定 CSR、Mac 确认 revision、未取消/未过期、device 无 tombstone 与当前 grants；只在全部仍有效时原子激活。减权/撤销先提交则迟到激活拒绝，不安装历史权限。已提交 active 但丢回执时，只能由同一 mTLS identity 查询确认，不自动再配设备。未完成激活、超时或被取消的记录没有任务权限 |
| 终止与重启 | 邀请只允许一个 pending enrollment；服务重启一律终止全部未 active enrollment，旧 QR、已安装的 pending cert 或已存 DER 均不能恢复激活。pending 记录仅保留最少拒绝/清理/审计材料，不用于续接签发；只有重启前已提交 active、仅 ACK 丢失者可凭原 mTLS identity 确认 active。安全恢复路径是 Mac 确认的新邀请，不能删账本或复活已撤销 deviceID |

bootstrap 必须是独立的短期 TLS listener/严格 route allowlist，不含任务、项目管理、撤销、进程启动或任意 RPC。未持 client cert 的连接只能到达这个受限入口；业务 listener 要求 mTLS。有效但未激活的已登记证书只可调用绑定自身 enrollment 的激活/状态 route，不能访问任务；未知证书没有这个例外。签发结果只送到绑定同一邀请/CSR 的受限会话，不能公开按 enrollment ID 下载。等待 Mac 确认采用有界、可取消的状态查询；5 分钟未完成激活即失效，不永久占用连接或队列。初始最多一个邀请、一个 pending enrollment、每邀请五次失败尝试；按设备/连接及全局设共同界限，不能只依赖可伪造的来源 IP。

以上是标准 TLS/X.509/CSR 的应用状态设计，不引入自创密钥交换、挑战签名或短码认证协议。缩短显示的公钥摘要只辅助识别，不独立替代可信 QR、端点验证、CSR 绑定与 Mac 确认。正式采用前须针对 QR 替换/泄露、确认诱导、重放、CSR 抢占、签发/落盘/激活丢回执和配对洪泛进行独立评审。

## 密钥、续期与撤销

| 对象 | 保存与生命周期 |
|---|---|
| 设备私钥 | 本地生成；默认评估 `WhenUnlockedThisDeviceOnly`、不启用同步、不导出为 PKCS#12。`ThisDeviceOnly` 约束迁移，不单独证明私钥不可提取或硬件保护。锁屏/重启后不可用时明确要求解锁，已在 Mac 执行的任务继续；不能因后台需求静默放宽保护。Secure Enclave 是按设备/算法验证的候选，不能假定 Apple 全系列都有同样硬件能力 |
| 设备 identity | 证书是公开材料，私钥不离开本机。公开 `SecIdentityCreate(nil, certificate, privateKey)` 可直接匹配证书与原 key；当前五平台 SDK 声明/编译不等于各 OS 运行验收，不能误称该 API 为 macOS 专有。各目标 OS 实测关联/查询、签名和 URLSession challenge；Keychain access group、签名、Data Protection Keychain 与安装/删除/备份语义分别验证。内存 identity 成功不证明持久化、硬件保护或锁屏可用 |
| Mac issuer/TLS key | 与 Codex 账号及任务工作区分开；Keychain/签名访问要求只放行所需 helper，CA 私钥不通过 remote API、普通文件或 native 子进程环境交接。server 库必须实证可使用所选 key，不因方便导出私钥或假定 NIO 与 `SecKey` 自动兼容 |
| 正常续期 | 候选 leaf 7 天、到期前 24 小时续期；由仍有效且未撤销的旧 mTLS credential 认证新的 CSR。新 credential 映射原逻辑 deviceID，保留 origin/任务身份，权限只取当前有效 grants。新 credential 最终激活也核对原认证、当前 policy revision/tombstone，不能用旧快照恢复权限；激活后旧 credential 最长重叠 10 分钟，再拒绝。单张 leaf 到期/退役只影响该 credential，不能禁掉已激活的新证书或逻辑 device。期限、重叠与 key/certificate 更新均待原型验证 |
| 独立 credential 状态 | 记录 serial/fingerprint、deviceID、validity、激活/退役/撤销；每请求检查实际证书和 live device/project grants。TLS 1.3 会话恢复、连接复用、URLSession 缓存与跨 await 撤销分别覆盖，不能只在新握手检查；无法保证恢复会话绑定当前 credential 时先禁用该恢复机制 |
| 设备丢失或撤销 | Mac 明确撤销后失效该设备所有 credential、会话和审批句柄，持久 tombstone 保留。全部凭据过期/丢钥且无有效旧 credential 时走 Mac 明确重新配对的新 deviceID；替换旧设备的撤销动作单独确认。不能靠同名、同公钥、续期或新证书复活被撤销 UUID；任务可见性按独立 owner/project 授权决定 |
| issuer/host 身份变化 | 与普通 leaf 续期分开。受验证的旧信任下轮换及完全丢钥恢复分别设计、实测；旧信任不可用时回到可信 Mac 明确重新信任，不自动接受网络发送的新 pin/CA。restore/import 不能让回滚备份重新启用撤销设备；没有独立可信 epoch 时不宣称能检测任意 DB 回滚。产品恢复路径须先停止服务、建立新 trust epoch/issuer 并重新配对，或先证明等效抗回滚机制；不能静默恢复旧 grants/tombstone 快照后继续服务 |

移动默认前台使用私钥不会自动满足锁屏 Siri/后台发送。通知只携带必要不敏感任务 ID；打开后认证查询。任何后台身份保护调整必须说明用户价值、权限范围和锁屏泄露风险，再按平台验收；不能把 `URLCredential` 的 persistence 参数当 Keychain 持久化/同步控制。Mac helper 的 Keychain 可用性也不能用手机 accessibility 属性类推。

## 同一所有者的设备接续

当前 schema 1 把请求的 `deviceID` 作为不可变 origin，并只允许原设备读控；相同 project grant 的另一设备仍拒绝。它证明隔离，**不满足 R19 的跨设备接续**。下一版在保留原 identity 字节/精确重试归属的基础上增加 host 本地稳定 `ownerScope` 与独立 project/task read/control 授权；不是远程自报 owner，也不是新增云账号。

Mac 配对确认分别说明此设备能否查看、控制选定项目的**既有及未来任务**。跨设备 read/control 走新授权判定，保留真实答复设备用于审计，不通过 `accept` 假扮 origin，不共享设备私钥，也不把打开原任务变成再提交。查询、审批或取消既有 turn 沿用原 `requestID`；精确提交重试仍检查原 origin 和不可变 payload。另一设备发送后续内容时使用新 `requestID`、其真实 origin，在同一已授权 thread 创建新 turn，接续同一用户可见会话；不得覆盖原 request→turn 映射或重发旧 turn。

`read` 仅查看授权范围内状态/内容；`control` 包含 read，并允许提交新请求、在授权 thread 发后续 turn、回答已完整展示的单次审批及请求中断，仍受 Codex sandbox/决定范围约束。read-only 设备不能 submit/continue/approve/interrupt，更不能内部 claim。所有 accept/claim/控制路径复核新能力与 policy revision；旧 project grant 表不得成为能力旁路。配对、证书或 owner 相同本身均不授予项目控制权。

旧 project grants 只授权原 origin 的现有行为，增加 `ownerScope` 不得自动扩成该项目全部既有/未来任务的跨 origin read/control。新增可见范围和控制权必须有 Mac 明确确认记录；未确认的旧设备保留原范围或拒绝新增能力，不能通过旧表获得新权限。

迁移需独占 owner、显式 schema 版本与短事务，保留旧 identity、host/project 关联、撤销 tombstone、上游映射和不确定阶段。签名凭据库/授权库/账本若无法原子更新，以未完成状态默认拒绝并恢复；不得通过重建 DB 修复。必须验证中途失败、重开、备份回滚、未知版本拒绝及原请求不重发；回滚程序不能把新 schema 交给旧 executable 强开。现有合成 schema 1 不能被无提示当真实用户数据迁移；产品迁移先实现和验收。

## 一项主机权威的知情审批

host 保留完整 native 审批对象，向有 control 权限的设备提供版本化、不可变展示描述。描述至少关联 host、harness/固定版本、project、request/thread/turn、approval ID、会话代际及展示版本；内容包括完整 command、cwd、reason、当前 sandbox/权限后果、实际可选决定和原有效期。host 以完整 native 对象校验，而不是只比摘要或客户端重建的 command。reason/模型解释是未可信内容，不能替代真实动作。

命令保持原 UTF-8 语义，控制字符、换行和双向文本必须可辨识，长内容可展开滚动；不能截掉后果后保留批准按钮。未知审批类型、未支持选项或超过完整呈现界限时禁用批准并提供解释、查看/拒绝或安全转交路径。手机/平板/Mac 可承担完整审阅；Watch、锁屏、通知、AirPods/Siri 不因简化而提供缺乏上下文的快捷批准。它们直达本人设备上的同一 pending task，不能把“打开详情”当已同意。

所有获授权设备的视图索引同一权威 pending approval。回答只提交 handle/展示版本/决定；host 在同一串行状态机中验证 live 授权 revision、会话代际、完整对象、原期限、取消及终态，再在 native await **之前一次消费**。一次消费后其他设备/连接立即失效；UI 查询权威状态，丢回执不重放批准。若审批消费先提交，动作可能继续执行；若撤销先提交，回答拒绝。撤销不倒转已发出的动作，也不表示任务已取消；审计只记必要 ID、答复设备、次序和结果。

设备断连后重新查询同一审批、同一期限；host/native 重启使旧 handle 失效，原请求 reconcile，不重建审批或延长倒计时。撤销只移除该设备权限；其他已明确授权设备可在原期限内查询同一审批。现有 coordinator 默认 60 秒、可配置上限 300 秒，且到期仅失去回答资格，**不会自动取消 native 工作**；产品超时后的提示/显式中断与可信终态必须单独验证。客户端时间只提示，host 单调时钟负责有效性。

当前 adapter 仅实现单次 `accept/cancel`，`cancel` 可能终止 turn，不能标成“跳过后继续”；session/execpolicy/persistent grant 不映射成单次同意。完整 Codex 的其他审批类型逐项实现展示、决定及回归，不能用 opaque token 的固定命令夹具替代产品知情审批。

## 每用户 Mac 服务与资源所有权

下一原型选择受用户控制的 per-user `SMAppService.agent(plistName:)` helper 方向，不采用 root LaunchDaemon。注册/撤销需明确操作并观察系统批准状态；`enabled` 只说明有资格运行，必须分别观察 helper、listener、账本 owner、Codex 登录/进程与任务健康。Mac 前台通过经过签名/对端身份验证的本地控制通道管理服务，不能把 fixture stdin pipe 当产品 IPC；此通道与远程业务 HTTP 权限不同。

| 所有者 / 阶段 | 具体责任与失败语义 |
|---|---|
| helper 唯一 owner | 在接受业务前取得 trust/grants/账本 owner、完成 schema/host 验证、恢复 reconciling；另一实例明确拒绝启动，不删锁、不双写。仅 helper 持 native reader、任务/审批状态与 event journal；UI/HTTP 不直接消费 native 流 |
| 授权与容量预留 | 先认证/live 授权与识别既有 request 重试，再串行预留运行容量；无队列原型对新任务 busy 时不新增 accepted。当前 probe 先 accept 再 busy 不是可靠队列，schema 1 不存待执行正文；若产品引入队列，先实现有界持久 payload、取消、保留与崩溃恢复 |
| 主机持续读事件 | 设备断连、撤销或不轮询不停止 native reader。host 观察/持久化真实阶段后，网络只读经授权投影；不能直接把研究 `/events`→`nextEvent(from:device)` 当产品 reader。`streamID/sequence`、快照边界与 gaps 明确，多个设备不竞争取走事件 |
| 恢复完整结果 | schema 1 只存 identity/阶段/上游 ID，没有输入或结果正文。先验证从绑定的 native thread/turn 历史取出受限结果投影及其保留/删除边界；原生历史缺失时状态与内容可用性分开，不能伪造回答。产品若承诺重启后找回完整结果，必须先通过对应历史/内容恢复验收，metadata snapshot 本身不够 |
| graceful stop / 更新 | 先拒绝新任务、关闭远程审批入口。已有待审批任务显式请求中断，不选择一个没有审批推进路径的“等待”；其他运行任务可按用户明确选择在有界期限内等待。中断意图先持久化，再发 native RPC，继续读取可信终态并落盘。截止仍未知则记 reconciling，回收 owned native/process group 并记录 EOF/leader/group 结果，再 unregister/update。`unregister()` 可能终止 helper，不能代替前面的 drain |
| crash / 重启 | 新 owner 只核对已知 IDs，丢映射不盲发；旧审批不复活。产品取消意图需在 RPC 前持久化，重启后显示“已请求停止，正在核对”，由可信终态覆盖；当前内存 `cancellationRequested` 不提供此保证。SMAppService/launchd 不提供业务恢复或所有孙进程回收保证：现有 transport 为 native 建立独立 PGID，不能靠 launchd 默认清理相同进程组或 KeepAlive 声称已处理孤儿。需实测启动登记前/后、helper SIGKILL/注销、native 退出/后代再分组、安装路径变化及升级清理；持久 PID 不能规避 PID 重用。选定覆盖这些窗口的受支持监督方案是产品接入硬门禁，研究 Python guardian 不升格为产品 daemon。用户关闭后台项时明确不可达；不自动重新注册 |
| 睡眠 / 退出登录 / 开机未登录 | 明确不可服务；不承诺自动唤醒、不修改系统电源。已注册、Mac 在线、Codex 可执行和任务运行分别显示；诊断不展示账号 token、内部路径或原始 payload |

资源候选：业务连接 8（每设备 2）、并发 handler 4、active task 1、无任务队列；TLS 握手及 HTTP 完整头/body 分别设总 deadline 5/5/10 秒。文本 32 KiB、HTTP body 256 KiB，分别在编码前与解码前计限，覆盖 JSON 转义放大；单响应/页 256 KiB、最多 100 事件。帧、字段、连接、全局内存与磁盘须共同计限；约束触发明确返回 busy/too-large/cursor-expired，不能无限缓冲。事件 journal 候选仅存必要 metadata、每 host 最多 10,000 条/32 MiB/24 小时，任一超界推进 replay floor 并要求快照；内存 event buffer 最多 512 条/2 MiB/10 分钟，HTTP 写入也有总 deadline 与有界队列，慢读者不能卡住 native reader。内容、审批正文和媒体不随诊断落盘，持久正文另做保留/导出/删除方案。这些界限不限制未来全量 Codex 能力以截断来假成功；大结果须有受控分页/分块或明确未支持路径。

Watch 用短请求/分页状态，前台刷新、通知与退避由设备生命周期决定，不以常驻轮询保持“在线”。业务 event cursor 过期、epoch 重置或权限变化后从授权快照恢复，同一 snapshot 要带一致的序号边界；不能用新 sequence 掩盖已丢事件。无客户端时主机依然处理终态；静置不应新增业务网络轮询。

持久阶段/终态先在 ledger commit，再 append journal，最后才发布。若 ledger 与 journal 不在同一事务，跨两者的崩溃不能被解释成没有终态：重启先以 ledger 为权威核对，修复为显式 gap/reset 和一致 snapshot，不能把未提交事件发给设备。stream epoch、已提交 high-water 与 snapshot 边界共同定义恢复位置；epoch 重置时旧 cursor 明确失效，不默默从零接成旧流。journal 保留清理不删除请求去重记录、上游映射或撤销 tombstone；后几者的数据生命周期/导出删除单独设计。

现有 stdio 的 2 ms cooperative polling 与 60 秒 read / 300 秒 session 是研究边界，不直接升格为长期服务性能规范。下一 transport 原型评估事件就绪等待，保留 flood/slow-reader/取消/EOF/descendant 语义；长任务的总期限、静默等待与真实终态分开。超时进入未知/核对，不能假报 failed/cancelled；不得无测量无限放大界限或声称换库必然更快。准入测量按[性能规范](../standards/performance.md)保存 Release 原始分布、并发/内存/能耗条件，锁/磁盘/签名不得阻塞 UI 或网络 event loop。

## 后续切片的接受事件

按依赖推进，每片在状态中记录真实证据；设计、编译和模拟器不能代替设备行为。

| 次序 / 切片 | 必须一起观察的接受事件 |
|---|---|
| 身份组合原型 | 临时合成 issuer，设备本地 key/CSR/证书关联→实际 mTLS；审查无私钥导出调用，验证 CSR 签名/篡改、key/cert 匹配/错配及错 CA/hostname/EKU/过期/未知证书拒绝。软件内存 key 不等于不可提取或 Secure Enclave。Mac 与每个目标 OS 的 identity/Keychain API 分别编译和运行，独立 Watch 另验；任何不可用组合先调整设计 |
| enrollment 持久状态 | Mac 精确确认后才激活；无证书 bootstrap、另一实际 peer leaf（同 CA active/未知）均不能激活候选。邀请过期/替换/重放/CSR 竞争/洪泛拒绝；固定签发输入/签名/DER 落盘/发送/安装/激活各中断窗口无第二身份或隐式 grant。重启后 pending 一律失效、已 active 丢 ACK 可确认；减权/撤销先提交则迟到激活拒绝。全部临时 identity/服务器/进程清理；不碰个人 Keychain |
| credential/授权迁移 | 续期同 device 保留原任务，旧 leaf 到期不禁用新 leaf；退役、撤销、重配新 UUID、已有 TLS/恢复会话及备份恢复不复活权限。read-only 的提交/继续/审批/中断与 claim 均拒绝；旧 B 迁移后仍不能读 A，直到 Mac 明确授权。新 owner/read/control schema 事务失败可重开，原 identity/tombstone 保留、不重发未知任务 |
| 多设备审批/接续 | A 提交→获准的 B 查询/控制既有 turn→A 重连，仍为原 request/turn；B 发送后续内容则新 request/new turn 接续原 thread，旧映射不变。未授权 B 拒绝。双端完整展示同一审批，一端回答另一端失效；并发撤销/回答的实际提交顺序与 native 答复对应，丢回执、过期/重启不再批准 |
| 主机服务/资源 | 注册与批准状态、listener/owner/reader 真实可区分；设备断连仍有终态；单 owner、busy 无假队列、cursor gap/快照、完整历史结果与停止/升级/崩溃清理有 evidence。header drip、body flood、slow-reader、长静默与磁盘满仍有界且不假成功；Release 负载/静置资源测量通过后才扩容量 |
| 实际外网与产品体验 | 选定并批准路由/服务后，真实蜂窝→清醒 Mac→Codex→结果；再做 Watch 独立网络、短语音/硬件入口及反馈。按[平台验收](../standards/platform-acceptance.md)分别记录型号/最低与当前 OS/权限/双语/无障碍；首次上手与常用路径动作数实际测量 |

原型通过后才更新接受状态、抽出真实共享逻辑或添加依赖；host service 与移动 UI 仍需实现。真实模型/账号、公网部署、签名/分发与外部通知通道使用各自授权和验收，不从本设计推断已开通。
