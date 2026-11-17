# F1 认证网络与本机 mTLS 研究

核对日期：2026-11-17。关联 R01/R02/R06/R07/R08/R09/R16。本文延续[协议研究](codex-protocol-research.md)；产品信任边界和网络候选顺序仍由[远程决策](../docs/decisions/remote-agent-foundation.md)维护。当前研究对象是**本机 loopback、临时证书、合成身份的 HTTPS 短请求夹具**，不接生产 ledger/Codex，不选服务、账号或公网域名。夹具通过不等于远程产品认证、F1/F2 完成或 Watch 可用；执行结果由[项目状态](../docs/project-status.md)记录。

## 官方依据与 Apple 客户端边界

| 已重开核对的官方来源 | 对本次研究的约束 |
|---|---|
| Apple [TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) | HTTP/HTTPS 优先使用异步 `URLSession`；后台 transfer 能力不等于任意 Agent 会话可常驻 |
| Apple [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos) | Watch 的 HTTPS 属高层网络；WebSocket/StreamTask、通用 TCP/SSH 属受限低层网络。普通 Agent 不能借音频/VoIP 例外常驻。模拟器放行不能代替真机；iPhone 在场和不可达分别验收 |
| Apple [authentication challenge](https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge)、[client certificate credential](https://developer.apple.com/documentation/foundation/urlcredential/init(identity:certificates:persistence:)) | `URLSession` 有客户端证书挑战与 `SecIdentity` 凭据 API，后者列出 watchOS 可用性；这只证明 API 入口，未验证本项目证书分发、Keychain、续期或 Watch 真机行为 |
| Apple [server trust](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication) | 默认系统信任验证优先；自定义判断需真正验证预期服务。开发 CA 不能变成无条件接受 server trust，也不通过全局 ATS 例外掩盖失败 |
| Python [ssl](https://docs.python.org/3.15/library/ssl.html) | 服务端显式 `CERT_REQUIRED`；客户端验证 CA 和 hostname；使用 `TLSVersion` 限制版本。`getpeercert(binary_form=True)` 提供对端 DER；CA 验证通过后才以其指纹查身份。默认不验证 CRL，不能假定证书或已有连接会自动撤销 |
| OpenSSL [证书验证](https://docs.openssl.org/3.6/man1/openssl-verification-options/)、[X.509 扩展](https://docs.openssl.org/4.0/man5/x509v3_config/) | 临时 CA 与 leaf 分离；server SAN 匹配实际 loopback 地址/主机名；server/client 分别限定 `serverAuth`/`clientAuth` 用途。CA 签名有效与业务项目授权是两层检查 |
| Python [http.server](https://docs.python.org/3.15/library/http.server.html) | 官方明确不推荐生产使用；本轮 stdlib HTTP/TLS 实现仅作有界实验，不由此选定产品 HTTP server |

资料版本是核对时的网页版本，不是 runtime pin。每次实验记录 `sys.executable`、Python 版本、`ssl.OPENSSL_VERSION`、TLS 实际协商版本及证书生成工具版本。不同 shell 的 `python3` 可能指向不同实现；缺少 TLS 1.3 时 preflight 明确失败，不能静默降到 TLS 1.2。不得开启 TLS key log、加载个人 CA/客户端身份或修改系统信任库。

Apple 后续探针应先做原生 `URLSession` HTTPS 小请求和有界状态读取，再测流式输出；本机 Python keepalive 只是撤销检查的测试条件，不要求 Watch 保持连接。仍缺真实配对、硬件安全存储、后台调度、断网恢复、蜂窝延迟/功耗和独立 Watch 路由证据。

## 最小威胁模型

资产包括设备私钥、执行主机身份、项目 grants、任务输入/结果和请求状态。网络对端、JSON 字段、证书名称及重放请求均不自动可信；fixture 的 CA/映射由本次实验创建者预置，**没有实现所有者确认的配对**。

| 威胁 / 入口 | 本机探针必须观察的拒绝或不变量 | 尚未解决的产品问题 |
|---|---|---|
| 未认证或错误 CA 的客户端；伪服务端 | 无客户端证书、不受信证书、错误服务端 hostname/CA 均不能取得成功响应 | CA bootstrap、所有者确认、私钥存储与丢失设备恢复 |
| 同 CA 的未知身份；payload 自报 `deviceID` | TLS leaf DER 指纹只映射到 host 预置的合成设备；未登记指纹拒绝。自报身份不能选择其他设备或扩大 grants | 真实配对、证书轮换、设备和所有者账户的关联 |
| 撤销后复用已认证连接 | 已建 keepalive 连接先成功，撤销后下一请求拒绝；握手缓存身份不能绕过逐请求授权。返回内容前亦须避免跨 await 撤销窗口 | 多进程/多端撤销传播、待决审批和在途任务的处置；撤销不证明执行已取消 |
| 跨项目、任意路径或配置注入 | 夹具只接受固定 route、project 与 `requestID/projectID/payload` 三字段；拒绝任意 cwd、config、自报身份和其他未知字段 | 尚无产品 protocolVersion/host/harness/operation 校验，也未集成真实 ledger、规范路径和 harness 能力 |
| 重复或冲突请求 | 同 ID/设备/项目/内容返回已有合成接受记录，不增次数；跨设备/内容冲突拒绝，记录容量有界 | 夹具内存记录不跨重启，无有效期/nonce 协议；不能替代持久提交阶段、丢响应核对或上游 exactly-once |
| 慢连接、超长帧、含糊 HTTP/JSON | TLS 握手与 body 总读取预算各 3 秒；HTTP 头仅有 stdlib parser 限制和 socket inactivity timeout。拒绝超长 body、歧义 framing、重复 JSON key 和无效类型；拒绝后不新增合成接受记录 | 尚无慢头/整次请求总 deadline；公网 DoS、生产解析器、速率/并发/存储策略、迁移和真实负载仍未解决 |

TLS 提供认证加密记录，不自动阻止合法客户端再次发送相同业务请求。证书 fingerprint 是身份映射 key，不能单靠一个自报指纹替代 TLS 私钥持有证明。mTLS 会在 TLS 终止处暴露明文；若未来 relay 在中间终止 TLS，它进入内容信任边界，两段 TLS 不能被称为设备到 Mac 的端到端内容保护。

## 第一张 loopback mTLS 短请求研究卡

**问题与假设：**在无外部服务的本机 TLS 1.3 通道上，能否把验证过的证书身份绑定到合成设备，并在每个短请求重新检查 project/revocation 与重复请求身份；即使连接保持，也不能沿用已撤销授权。

**隔离输入：**一次性临时目录、独立 CA/server/client 私钥和证书、仅 `127.0.0.1` 临时端口、固定合成 project/device/request 与文本；另造同 CA 未登记客户端和错误 CA。材料不进入系统 Keychain、个人 `CODEX_HOME`、实际 ledger 或 Codex；不做外部 DNS、端口映射、SSH 登录或真实模型调用。所有值和 HTTP 形状都是 fixture 协议，不是已冻结的 Munie 产品 schema。

**执行与接受事件：**[探针](../scripts/probe-authenticated-network.py)实际启动 TLS server/client；正向短请求必须有 TLS 1.3 协商与合成成功响应。逐项运行无证书/错误 CA、同 CA 未登记、自报身份、跨项目、重复/冲突、新连接与同连接撤销、超限和主动超时对照。新接受为 202，同请求重试为 200 且次数不增，冲突为 409，未知/撤销/越项目为 403；无证书/错误 CA 在 TLS 层拒绝。记录合成接受次数，不能仅看客户端异常。当前体/响应上限各 2,048 bytes、接受记录最多 4 条、I/O 预算 3 秒；这不是产品性能预算，已执行场景以实际报告为准，不预填“通过”。

本机显式运行命令：

```sh
/opt/homebrew/bin/python3 scripts/probe-authenticated-network.py \
  --openssl /opt/homebrew/bin/openssl \
  --output build/authenticated-network-probe.json
```

主动超时场景分别为不发送 TLS 握手、声明 body 后不补齐，之后用正常客户端确认 worker 恢复；它们不覆盖慢头或所有 drip-feed 时序。请求过期、nonce、host/version/harness/operation 字段和 durable replay 均未实现、未覆盖，不能因本轮场景通过而声称完整协议验收。

**证据与清理：**报告只保留 runtime/脚本指纹、合成场景 ID、TLS/HTTP 结构、次数/耗时与限制结果；不写 PEM、私钥、原始输入或 TLS session secrets。接受须包含 `serverStopped`、`certificateFilesPrivate` 与 `temporaryCredentialsRemoved`：退出时先主动关闭活动连接（包括未完成 header），再等待 server 线程结束、关闭 listener/客户端连接，临时文件权限均为 0600，并移除临时证书目录；清理失败令实验失败。报告保留为 ignored `build/` 下的本机证据，失败和缺少 runtime 都保留明确状态。

**解释边界：**即使全部通过，也只验证当前 Python/OpenSSL 与夹具实现下的本机加密短请求、预置身份和负向拒绝；未集成生产 ledger、native Codex、原生 Apple 客户端、真实凭据/模型、互联网/蜂窝、持久配对/撤销或生产可用服务。下一步先评审身份如何接入真实 ledger，再单独选择并授权实际网络/设备实验。

## 成熟替代与许可复查

| 候选 | 用途与代价 | 当前决定 / 许可 |
|---|---|---|
| 标准 HTTPS mTLS | 直接使用成熟 TLS/X.509；适合把通道身份与每请求应用授权分开测。代价是证书分发、轮换、撤销和 Apple identity 生命周期 | 仅选为本机研究机制，未选生产 PKI/server。Python 软件/文档为 [PSF License v2](https://docs.python.org/3.15/license.html)，文档示例另有 0BSD 双许可；本次不复制示例。OpenSSL 3.0 及后继主线为 [Apache-2.0](https://openssl-library.org/source/license/index.html)，历史版本/其他 TLS 实现另核对 |
| 受限 OpenSSH 隧道 | 可给 iPhone 工程探针提供已有主机认证/加密转发；仍需 pin 主机身份、最小账号/转发范围和应用授权。建隧道不证明服务健康；不能作为普通 Watch 通道 | [官方 portable](https://www.openssh.org/portable.html)、[转发选项](https://man.openbsd.org/ssh_config#ExitOnForwardFailure)及上游 [LICENCE](https://github.com/openssh/openssh-portable/blob/master/LICENCE)已核对：按组件列 BSD 或更宽松许可，不能简写为统一某一 BSD。未启用 Remote Login、未装依赖或复制代码 |
| 私有网络，例如 Tailscale | [官方连接类型](https://tailscale.com/docs/reference/connection-types)区分 direct/DERP/peer relay，均使用 WireGuard 端到端加密；路由可达不等于业务授权。需分别测中继性能与撤销；[平台列表](https://tailscale.com/docs/install)不能推出独立 Watch 或继承 iPhone VPN | 仅比较，没有选服务/账号。上游 client [LICENSE](https://github.com/tailscale/tailscale/blob/main/LICENSE)为 BSD-3-Clause；托管服务条款、各平台客户端及传递依赖须独立审查。正式复用前按引用规则固定 commit/许可 |

上述在线资料均在本页日期重开；未采用或复制上游产品实现，未新增移动端 runtime。Apple 文档为其版权资料，按[网站条款](https://www.apple.com/legal/internet-services/terms/site.html)引用链接和本项目摘要；不得套用 Munie 的开源许可证。未来源码复用先更新[引用清单](README.md)和固定版本许可快照。

## 真实模型实验的单独授权卡（未发起）

本机合成夹具授权不包含真实账户调用。开始前将下列槽位填写为可审阅的具体一次实验；登录状态或本机存在 token 不代表同意消费或向外发送数据。

| 授权字段 | 必须明确的边界 |
|---|---|
| 账户与 provider | `ACCOUNT` 的所有者、登录/API 模式和凭据读取路径；凭据只留执行主机，不能抄入源码、报告、手机或 relay |
| 模型与费用 | 精确 `MODEL`/版本、provider、可计费请求数、token/输出上限、`COST_CAP` 及超限停止条件；免费/订阅可用性不能由夹具推断 |
| 域名与数据路径 | `ENDPOINT` 的 HTTPS 域名/端口、全部允许外联（含认证/工具所需域名）、代理/relay 与内容接收方；不允许任意外网或由返回内容扩大名单 |
| 输入与权限 | 可公开合成 `INPUT`、临时 `PROJECT`、固定 CLI/adapter、`on-request/read-only` 和允许工具清单；是否允许写 marker/执行命令逐项注明，不含真实仓库、个人目录、任意 shell 或自动批准 |
| 时间与次数 | `TIME_WINDOW`、总 wall time、turn/RPC/重试上限；断连后的未知提交不盲重发，取消回执仍等匹配终态 |
| 清理与报告 | `CLEANUP` 列出主机/native/tool 子进程、监听端口、临时项目/凭据副本及保留报告的去向/期限；删除副本不承诺删除 provider 侧历史，按其实际政策确认 |

授权后先运行一个最小合成文本 turn，以真实 thread/turn/终态和费用证据验收；未授权项保持未执行，不用现有账号登录或合成 provider 成功代替。
