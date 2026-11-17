# F1 认证网络与本机 mTLS 研究

核对日期：2026-11-17。关联 R01/R02/R06/R07/R08/R09/R16。本文延续[协议研究](codex-protocol-research.md)；产品信任边界和网络候选顺序仍由[远程决策](../docs/decisions/remote-agent-foundation.md)维护。当前研究对象是**本机 loopback、临时证书、合成身份的 HTTPS 短请求夹具**，以及将连接身份接入真实 `HostSubmissionLedger` 的隔离实验设计；账本只使用新建的临时合成数据，不接生产 ledger/Codex，不选服务、账号或公网域名。夹具通过不等于远程产品认证、F1/F2 完成或 Watch 可用；执行结果由[项目状态](../docs/project-status.md)记录。

## 官方依据与 Apple 客户端边界

| 已重开核对的官方来源 | 对本次研究的约束 |
|---|---|
| Apple [TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) | HTTP/HTTPS 优先使用异步 `URLSession`；后台 transfer 能力不等于任意 Agent 会话可常驻 |
| Apple [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos) | Watch 的 HTTPS 属高层网络；WebSocket/StreamTask、通用 TCP/SSH 属受限低层网络。普通 Agent 不能借音频/VoIP 例外常驻。模拟器放行不能代替真机；iPhone 在场和不可达分别验收 |
| Apple [authentication challenge](https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge)、[client certificate credential](https://developer.apple.com/documentation/foundation/urlcredential/init(identity:certificates:persistence:)) | `URLSession` 有客户端证书挑战与 `SecIdentity` 凭据 API，后者列出 watchOS 可用性；这只证明 API 入口，未验证本项目证书分发、Keychain、续期或 Watch 真机行为 |
| Apple [server trust](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication) | 默认系统信任验证优先；自定义判断需真正验证预期服务。开发 CA 不能变成无条件接受 server trust，也不通过全局 ATS 例外掩盖失败 |
| Python [ssl](https://docs.python.org/3.15/library/ssl.html) | 服务端显式 `CERT_REQUIRED`，不能仅凭 `PROTOCOL_TLS_SERVER` 假定已启用客户端认证；客户端另验证 CA 和 hostname。使用 `TLSVersion` 限制版本；成功握手后从实际连接 `getpeercert(binary_form=True)` 取对端 DER，再以指纹查身份。未完成握手会报错，无 peer 时为 `None`；取得 DER 不证明已开启验证。默认不验证 CRL，不能假定证书或已有连接会自动撤销 |
| OpenSSL [证书验证](https://docs.openssl.org/3.6/man1/openssl-verification-options/)、[X.509 扩展](https://docs.openssl.org/4.0/man5/x509v3_config/) | 临时 CA 与 leaf 分离；server SAN 匹配实际 loopback 地址/主机名；server/client 分别限定 `serverAuth`/`clientAuth` 用途。CA 签名有效与业务项目授权是两层检查 |
| Python [http.server](https://docs.python.org/3.15/library/http.server.html) | 官方明确不推荐生产使用；本轮 stdlib HTTP/TLS 实现仅作有界实验，不由此选定产品 HTTP server |

资料版本是核对时的网页版本，不是 runtime pin。每次实验记录 `sys.executable`、Python 版本、`ssl.OPENSSL_VERSION`、TLS 实际协商版本及证书生成工具版本。不同 shell 的 `python3` 可能指向不同实现；缺少 TLS 1.3 时 preflight 明确失败，不能静默降到 TLS 1.2。不得开启 TLS key log、加载个人 CA/客户端身份或修改系统信任库。

Apple 客户端研究先做原生 `URLSession` HTTPS 小请求和有界状态读取，再测流式输出；下一张 Mac-only 身份实验卡见下文。本机 Python keepalive 只是撤销检查的测试条件，不要求 Watch 保持连接。仍缺真实配对、硬件安全存储、后台调度、断网恢复、蜂窝延迟/功耗和独立 Watch 路由证据。

## 最小威胁模型

资产包括设备私钥、执行主机身份、项目 grants、任务输入/结果和请求状态。网络对端、JSON 字段、证书名称及重放请求均不自动可信；fixture 的 CA/映射由本次实验创建者预置，**没有实现所有者确认的配对**。

| 威胁 / 入口 | 本机探针必须观察的拒绝或不变量 | 尚未解决的产品问题 |
|---|---|---|
| 未认证或错误 CA 的客户端；伪服务端 | 无客户端证书、不受信证书、错误服务端 hostname/CA 均不能取得成功响应 | CA bootstrap、所有者确认、私钥存储与丢失设备恢复 |
| 同 CA 的未知身份；payload 自报 `deviceID` | TLS leaf DER 指纹只映射到 host 预置的合成设备；未登记指纹拒绝。自报身份不能选择其他设备或扩大 grants | 真实配对、证书轮换、设备和所有者账户的关联 |
| 撤销后复用已认证连接 | 已建 keepalive 连接先成功，撤销后下一请求拒绝；握手缓存身份不能绕过逐请求授权。返回内容前亦须避免跨 await 撤销窗口 | 多进程/多端撤销传播、待决审批和在途任务的处置；撤销不证明执行已取消 |
| 跨项目、任意路径或配置注入 | 第一张夹具只接受固定 route、project 与 `requestID/projectID/payload` 三字段；拒绝任意 cwd、config、自报身份和其他未知字段 | 第一张夹具不集成真实 ledger；下面的桥接卡另验账本 host、grants、项目目录与请求身份，不由此冻结完整产品协议或证明 harness 能力 |
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

**证据与清理：**报告只保留 runtime/脚本指纹、合成场景 ID、TLS/HTTP 结构、次数与限制结果；不写 PEM、私钥、原始输入或 TLS session secrets。接受须包含 `serverStopped`、`certificateFilesPrivate` 与 `temporaryCredentialsRemoved`：退出时先主动关闭活动连接（包括未完成 header），再等待 server 线程结束、关闭 listener/客户端连接，临时文件权限均为 0600，并移除临时证书目录；清理失败令实验失败。报告保留为 ignored `build/` 下的本机证据，失败和缺少 runtime 都保留明确状态。

**解释边界：**即使全部通过，也只验证当前 Python/OpenSSL 与夹具实现下的本机加密短请求、预置身份和负向拒绝；未集成生产 ledger、native Codex、原生 Apple 客户端、真实凭据/模型、互联网/蜂窝、持久配对/撤销或生产可用服务。下一步先评审身份如何接入真实 ledger，再单独选择并授权实际网络/设备实验。

## Mac-only URLSession 原生身份研究卡

本卡核对日期同页首。它补充上一张 Python 对 Python 的通道实验：以独立 macOS Swift executable、系统 Foundation/Security 和临时 PKCS#12 身份研究真实 `URLSession` 挑战/信任/取消行为。本机观察环境为 macOS 27.2.1、Xcode 27.2、Swift 6.4.2；下文区分官方约束、已观察限制与研究对照，**不预填整轮通过结果**。实际实现、命令、完整场景和结果以代码及[项目状态](../docs/project-status.md)为准。不连接 shipping apps、真实 ledger/Codex、账号、外网或系统证书配置。

### 临时身份、可用性与 Keychain 边界

2026-11-17 实际读取 Xcode 27.2（27B52）的 macOS/iPhoneOS 27.2 SDK `Security.framework/Headers/SecImportExport.h`。两份 header SHA-256 均为 `2353b5bf09b3bec8c61cd488a5b647dba6b3e0b63d7b9c8af0c11757eaae57b1`；同时重开 Apple [SecPKCS12Import](https://developer.apple.com/documentation/security/secpkcs12import(_:_:_:))、[导入 identity](https://developer.apple.com/documentation/security/importing-an-identity)与 [kSecImportToMemoryOnly](https://developer.apple.com/documentation/security/ksecimporttomemoryonly)。SDK 明确区分：默认 iOS 导入进程内存，macOS 则导入默认 Keychain；`ephemeral` URLSession 不能改变这个 Security API 副作用。

本机实验导入必须显式传 `kSecImportToMemoryOnly: kCFBooleanTrue` 与合成 PKCS#12 passphrase，检查 `OSStatus`、identity 数量和类型；失败不得回退到默认导入、个人身份查找或系统信任修改。该 key 自 **macOS 15 / iOS 18** 可用，与当前最低版本相符；在线 availability 还列出 watchOS 11，但本卡只验证 macOS，不能据此宣称已构建或运行其他平台。SDK 说明 memory-only 选项会忽略 Keychain 相关导入选项；不是创建临时 Keychain 后再删文件的替代说法。

本机已观察 OpenSSL 4 默认导出的 PKCS#12 可被上述 memory-only 导入，未通过降低 PBE 或 legacy export 取得结果。这不证明其他系统或算法组合均兼容。当前 native importer 只核对导入结果、数量和类型，**尚未独立提取并比对导入 identity 的 leaf DER 指纹**；runner 生成材料、server 实际 TLS peer 指纹与合成设备接受记录是另一层证据，不能写成 native 已做此项校验。

PKCS#12、私钥及密码只来自本轮临时合成材料，不记录到报告，不借读取个人 Keychain 来选 identity。源码选项与文件清理证据只能支持相应实现声明；本研究**没有枚举、前后比对或审计个人 Keychain**，不能声称已证明系统内不存在残留，也不承诺已对内存密钥作可靠擦除。真正产品配对、硬件保护、续期/轮换和持久保存仍需独立设计。

### 挑战作用域与服务端信任

| 官方依据 | 本次原生探针的约束 |
|---|---|
| [session challenge delegate](https://developer.apple.com/documentation/foundation/urlsessiondelegate/urlsession(_:didreceive:completionhandler:))、[URLProtectionSpace](https://developer.apple.com/documentation/foundation/urlprotectionspace) | 客户端证书和 server trust 是 session-level 挑战；每次回答前精确核对固定 HTTPS host、port、非 proxy 与 authenticationMethod，只向此 session 的预定 endpoint 提供预定 identity。不能用子串匹配 host、证书 display name 或 payload 的 deviceID 代替身份约束；不让未知挑战自动找到个人凭据 |
| [URLCredential identity initializer](https://developer.apple.com/documentation/foundation/urlcredential/init(identity:certificates:persistence:)) | 官方明确 `persistence` 参数会被忽略，建议 `.forSession` 反映实际行为。传 `.none` 不能证明 identity 不被会话缓存或不进 Keychain；Keychain 行为由上面的导入选项控制。root 直接签 leaf 的 fixture 通常不需携带 intermediate 数组 |
| [SecPolicyCreateSSL](https://developer.apple.com/documentation/security/secpolicycreatessl(_:_:))、[anchor-only](https://developer.apple.com/documentation/security/sectrustsetanchorcertificatesonly(_:_:))、[network fetch](https://developer.apple.com/documentation/security/sectrustsetnetworkfetchallowed(_:_:)) | 对该 challenge 的 trust 设置 SSL **server** policy 与预定 hostname，临时 CA 为唯一 anchor，显式 anchor-only `true`、network-fetch `false`，检查每次配置结果并在 trust 成功后才接受。不能仅把拿到 `serverTrust` 当验证通过。关闭 fetch 的官方语义是限制本次 trust 获取缺失 intermediate，不能泛化成整个操作系统无外联的审计结论 |
| [手动 trust](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication)、[ATS](https://developer.apple.com/documentation/security/preventing-insecure-network-connections) | 私有 CA 仅限 fixture 的显式信任配置；不增加 ATS 例外、不无条件接受自签或不匹配 hostname，也不以降低 TLS 版本让实验变绿。独立 Mac executable 的通过不证明 shipping app 的 bundle/ATS/签名、沙箱或移动设备网络验收 |

未知或已撤销设备可以先通过 CA 层的 TLS，再在应用层被拒绝；原生客户端必须保留这一区别。session/TLS 可能复用认证状态，不能要求每个 HTTP 请求都再次出现证书挑战；撤销必须由 server 每请求重查并用接受记录验证，不以“重新握手成功”代替。

### 会话、代理、重定向与资源

采用专用 [ephemeral configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)，与其他 endpoint/identity 分开；不用 `.shared` 或 background session。ephemeral 默认仍有 RAM 中的私有 [cookie store](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpcookiestorage)和 [credential store](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/urlcredentialstorage)，不等于没有状态。实验显式关 cookie 自动发送、置空 cookie/credential/cache store，不手工补 Cookie/Authorization；结束时使 session 失效并等待相应完成证据。它不会擦除独立写出的 PKCS#12/报告文件。

代理单独处理：[connectionProxyDictionary](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary) 默认 `nil`、较新的 [proxyConfigurations](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations) 默认空数组，官方均说明会使用系统设置；空数组不能被写成“已关闭代理”。记录实验实际的显式代理策略及 [`isProxyConnection`](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/isproxyconnection) 指标，拒绝 proxy 身份挑战；不改用户系统/VPN/PAC。单个本机指标也不是所有网络出口的证明。

用 [redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)) 返回 `nil` 拒绝重定向，测试 server 的 Location 未被跟随、目标接受数未增加；不依赖 HTTP 自动删敏感 header 的细节保护 identity。该回调只适用于 default/ephemeral，官方说明 background 会自动跟随，故不用于本轮。无身份、错误 endpoint、错误 CA/hostname 都需有负向对照；客户端预检拒绝与真实 TLS/trust 拒绝在报告中分别标识。

TLS min/max 限定为 1.3，同时以 [`negotiatedTLSProtocolVersion`](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/negotiatedtlsprotocolversion) 及 server 实际协商值作证，不能把配置值写成协商结果；无指标或无加密连接保持未知/失败。超大响应应在 header 和增量数据边界有界处理，在整包下载后才数 bytes 不能证明内存有界。[request timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest) 随新数据重置，[resource timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource) 才约束整个资源；另有 runner 总期限与清理期限。[task.cancel](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel()) 立即返回且之后仍可能有 delegate 回调，需核对完成错误与清理，不能把调用取消等同上游任务已停。

### 本机观察与协议对照

| 输入 / 对照 | 已观察事实或必须满足的接受条件 | 解释边界 |
|---|---|---|
| 同一原生 session 的首次提交、相同重试与冲突 | 首次 202、相同重试 200、冲突 409 的 HTTP 状态和 body 均可读；接受数保持 1 | 重试未新增合成接受，不代表已实现持久 ledger 或上游 exactly-once |
| 应用层 403 | 未登记设备及越项目、撤销拒绝在本机 native 侧表现为 `URLError -1206`，无 HTTP 状态、body 为 0；server 记录实际 403 | 同连接越项目和撤销两例没有新 challenge；新连接拒绝有初始 challenge。独立 keepalive 对照也观察到 -1206；原因未经证明，不归因为重复 challenge，也不推断所有系统行为 |
| 不受信客户端 CA | native 为 `-1005`，server 同时记录 `SSLCertVerificationError.verify_code = 20`，接受数为 0 | 必须关联双侧拒绝和接受数；任意网络错误本身不能证明证书验证有效 |
| 在途取消 | server 已收到请求并发送 headers 后暂缓 body；native 在 response delegate 返回 `.cancel`，接受条件为 `-999`、HTTP 200、`cancelledOnResponse`、body 为 0 和接受数不增 | 这些字段需由实际报告共同确认；不是先取消尚未发出的 task，也不等于已取消远程模型或工具 |
| slow timeout | 独立 slow 场景由 server 已收到请求、真实等待后 `-1001` 及接受数不增作证 | 不以取消场景代替 timeout，也不由一次超时推断所有慢头/drip-feed 时序已覆盖 |

诊断记录 `isolated-persistent-policy-05.json`、`isolated-policy-keepalive-04.json` 与早期失败的 `failed-attempt-02.json` 保留上述局部观察，不能作为整轮通过记录。完整正式结果由项目状态引用实际报告，不在本研究卡另维护完成数量。

为继续对照应用授权与传输行为，native runner 保留独立 `legacy-http403-control`，主 native fixture 另试 **HTTP 200 + 固定 error envelope** 表达 `device-denied` / `project-denied`。它们仍是业务拒绝：不能产生 `fixture-accepted`/ordinal，不能增加 server 合成接受数；冲突继续为 409。原 Python 23-case fixture 的 403 语义不变。这只是明确标识的研究候选，**未选定为生产协议**；不能因 wire HTTP 200 声称授权成功，也不能由绕过本机限制的对照结果声称已解释其原因。

### 接受事件与解释限度

计划负向输入为同 CA 未登记身份、撤销后请求、无 identity、endpoint/信任不匹配、redirect、超大响应、超时和主动取消；实际运行清单不得从本卡推定。正向结果需关联真实 native client-certificate/server-trust challenge、任务 metrics 与 Python server 的 TLS peer identity/合成接受次数；负向结果需说明拒绝发生在本机预检、TLS、HTTP 授权还是响应读取，且没有新增不应有的接受记录。challenge/metrics 只记必要结构和计数，不输出证书、私钥、密码、完整 URL/header/body 或系统 trust 详情。

清理核对 native process/session/tasks、Python server/listener、活动连接和临时材料，错误保留明确阶段及结构化原因。即使观察全部接受事件，也仅补 macOS Foundation/Security 到本机 fixture 的证据；不实现生产设备配对/Keychain 生命周期、持久网络授权或真实 ledger/harness 接入，不证明 iOS/watchOS、蜂窝、独立 Watch、后台、功耗或端到端产品流程。

## TLS 连接身份到真实账本的桥接研究卡

**问题与范围：**用临时 CA、合成设备、临时项目和真实 `HostSubmissionLedger` / SQLite，验证 `CERT_REQUIRED` 成功握手的实际 `SSLSocket` → `getpeercert(binary_form=True)` → leaf DER 的 SHA-256 → 本机预置映射 → `AuthenticatedDevice` → 每请求 ledger 授权。这是下一片隔离 loopback 实验的设计与接受事件，**不是已通过结果**。Python TLS/HTTP server 与 Swift stdio ledger driver 都是研究执行器，不是已选生产 gateway；不链接 shipping app，不调用 Codex/model/WAN，不执行请求正文。

**可信边界：**DER 必须来自正在处理该 HTTP 请求的 TLS socket；不能从 body、header、URL、证书 display name 或对端自报 `deviceID` / fingerprint 生成可信 principal。CA 链验证及 TLS 私钥持有证明在前，本机 fingerprint→UUID 映射只负责选择已登记身份；证书 DER、pin 或其摘要本身不构成独立 TLS 认证。未知 fingerprint 拒绝，不按相同 subject、同 CA 或 payload 兜底。临时 registry 不实现所有者确认、持久配对、轮换、密钥恢复或证书撤销服务。

bridge、私有 pipe、driver 和本机 registry 都属于此实验的可信主机边界。网络输入只进入固定业务操作及严格字段；driver 中的本地 `registerProject`、`authorizeDevice`、`revokeDevice`、`claimForDispatch` 和可信上游观察不能成为 HTTP route，也不能由 HTTP 的 operation 字段选择。pipe 上的身份是受信 bridge 根据连接生成的研究输入，不是可传给远端的 bearer token；本实验不证明能防同 UID 恶意进程、受损 bridge 或 root。

**真实 ledger 不变量：**已重开[账本实现](../apps/MunieHost/Execution/HostSubmissionLedger.swift)及[存储研究](submission-ledger-research.md)：`accept`、`snapshot`、`claimForDispatch` 均复查 live `devices.enabled=1`、project grant、host 以及 canonical path/device/inode；`AuthenticatedDevice` 值不是永久授权。TLS identity 可随连接缓存，grants/revocation 不能由握手成功或 registry 缓存替代。重启必须重开同一临时 DB、保留 host/请求/撤销记录；bootstrap 与 reopen 分开，不能重新 seed 授权或删除 DB 来让试验通过。`revokeDevice` 对已知及未知 UUID 写持久 tombstone，`authorizeDevice` 拒绝重新启用同 UUID；未来重新配对需另设身份。

[Swift actor 隔离](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors)不使多个 `await` 自动成为一个事务；[SQLite 事务](https://sqlite.org/lang_transaction.html)也不覆盖 HTTP 响应或外部执行。当前 ledger 在同步 actor 方法内使用短事务，单连接和 cooperating-process owner 锁、schema/host 验证及存储上限仍按存储研究约束。接受只表示真实账本存在 `accepted` 记录；本地 claim 只返回一次发送资格，不能据此称为已执行或 exactly-once。新增等待/队列后的授权变化、返回敏感结果前的撤销窗口需要单独屏障对照；未执行的交错保持未覆盖。

| 实际输入 / 对照 | 必须观察的接受或拒绝证据 |
|---|---|
| 已登记 client、正确 host/project、精确重试与冲突 | TLS peer fingerprint 与本机映射关联真实 DB 请求；同一 request 的精确重试仍为同一记录，内容/目标冲突拒绝。记录 ledger phase/row count，不能只看 HTTP 2xx |
| 无 client cert / 错误 CA；同 CA 未登记 cert | 前两者关联 TLS 双侧失败且无 ledger 接受；后者可通过 TLS，但映射拒绝且无新行。任意网络异常不单独算拒绝验收 |
| 已登记设备自报另一 deviceID/fingerprint，伪造 header；越项目/host、任意 cwd/config | 网络 schema 或真实 ledger 拒绝；实际连接身份不变，没有越权 snapshot 或新接受记录。不得把客户端请求中的身份字段原样透传为可信 pipe 身份 |
| 同一已建连接撤销；未知 UUID 先撤销后登记 | 已成功接受/读取后，由本地 admin 撤销，再经同一连接重试与读取均拒绝；本地 claim 亦拒绝。未知 UUID 的 tombstone 阻止后来登记；不声称此前执行已停止 |
| 关闭并重启 driver，沿用同一 DB/registry | 原请求可被仍授权的原设备核对；撤销设备的新连接与原请求读取仍拒绝，重新 authorize 同 UUID 仍失败。既有 dispatching/running 保持 reconciling，无发送/副作用 |
| HTTP 尝试 revoke、claim、登记项目/设备或报告上游终态；持久化/stdio 故障 | 固定网络 allowlist 拒绝所有管理/可信观察入口；driver 失败、超时或 DB 错误不能包装成成功接受，也不能自动重发未知提交 |

**资源、记录与清理：**仅监听 `127.0.0.1` 临时端口，固定 TLS 1.3 和合成请求；握手/body、HTTP/stdio 帧、请求/连接/队列/总运行时间分别有界。报告记录实际工具/运行库版本与源码指纹、连接身份关联、业务拒绝、账本 phase/行数、重启前后状态与退出码；不保存正文、PEM、私钥、密码、原始 DER 或个人路径。fingerprint 与 ID 也是敏感关联元数据，本轮仅记录合成值。若复用上张 native 的 HTTP 200 error envelope，对拒绝仍核对无接受记录；协议候选及 legacy403 对照不变。

接受还需观察关闭 HTTP 客户端及活动 TLS socket、停止 listener/server worker、关闭 driver stdin 并取得 stdout/stderr EOF、进程退出/组消失和 owner 锁释放，最后删除临时 CA/identity/registry/project/SQLite 及 journal/owner 文件；检查目录私有权限和临时路径确已移除。清理失败则实验失败，失败报告保留必要阶段且不删诊断依据。不由清理成功推断 Keychain 审计、可靠内存擦除或物理断电持久性；本卡不新增配对、生产服务、真实 harness、移动设备或蜂窝验收。

## 成熟替代与许可复查

| 候选 | 用途与代价 | 当前决定 / 许可 |
|---|---|---|
| 标准 HTTPS mTLS | 直接使用成熟 TLS/X.509；适合把通道身份与每请求应用授权分开测。代价是证书分发、轮换、撤销和 Apple identity 生命周期 | 仅选为本机研究机制，未选生产 PKI/server。Python 软件/文档为 [PSF License v2](https://docs.python.org/3.15/license.html)，文档示例另有 0BSD 双许可；本次不复制示例。OpenSSL 3.0 及后继主线为 [Apache-2.0](https://openssl-library.org/source/license/index.html)，历史版本/其他 TLS 实现另核对 |
| 受限 OpenSSH 隧道 | 可给 iPhone 工程探针提供已有主机认证/加密转发；仍需 pin 主机身份、最小账号/转发范围和应用授权。建隧道不证明服务健康；不能作为普通 Watch 通道 | [官方 portable](https://www.openssh.org/portable.html)、[转发选项](https://man.openbsd.org/ssh_config#ExitOnForwardFailure)及上游 [LICENCE](https://github.com/openssh/openssh-portable/blob/master/LICENCE)已核对：按组件列 BSD 或更宽松许可，不能简写为统一某一 BSD。未启用 Remote Login、未装依赖或复制代码 |
| 私有网络，例如 Tailscale | [官方连接类型](https://tailscale.com/docs/reference/connection-types)区分 direct/DERP/peer relay，均使用 WireGuard 端到端加密；路由可达不等于业务授权。需分别测中继性能与撤销；[平台列表](https://tailscale.com/docs/install)不能推出独立 Watch 或继承 iPhone VPN | 仅比较，没有选服务/账号。上游 client [LICENSE](https://github.com/tailscale/tailscale/blob/main/LICENSE)为 BSD-3-Clause；托管服务条款、各平台客户端及传递依赖须独立审查。正式复用前按引用规则固定 commit/许可 |
| SwiftNIO / NIOSSL | [SwiftNIO](https://github.com/apple/swift-nio)提供低层异步协议构件，[NIOSSL](https://github.com/apple/swift-nio-ssl)以 BoringSSL 提供 TLS。核对 [TLSConfiguration](https://github.com/apple/swift-nio-ssl/blob/2a439aff650ba63077cf7bed86677c739f76d782/Sources/NIOSSL/TLSConfiguration.swift)：普通 server 默认不验证 client；显式 `makeServerConfigurationWithMTLS` 接收 trust roots、验证 client 链且不做 server 角色不适用的 hostname 检查。连接侧 [SSLConnection](https://github.com/apple/swift-nio-ssl/blob/2a439aff650ba63077cf7bed86677c739f76d782/Sources/NIOSSL/SSLConnection.swift)读取实际 peer leaf；内部实现不是本项目已采用的公共 API。它仍需单独映射身份并查询 live ledger 授权，不自动提供配对或撤销；不能替代 Foundation 的 Apple HTTP 生命周期或绕过 Watch 限制 | 本轮 Apple client 优先 URLSession，Python bridge 仅用于研究；不加 NIO 依赖或复制代码。两仓库 root [NIO LICENSE](https://github.com/apple/swift-nio/blob/main/LICENSE.txt)/[NIOSSL LICENSE](https://github.com/apple/swift-nio-ssl/blob/2a439aff650ba63077cf7bed86677c739f76d782/LICENSE.txt)为 Apache-2.0；NIOSSL 的 [NOTICE](https://github.com/apple/swift-nio-ssl/blob/2a439aff650ba63077cf7bed86677c739f76d782/NOTICE.txt)另列 BoringSSL 及组件许可。此处为日期化只读比较，正式复用须固定 commit、审阅 vendored license/notice 与传递依赖，不能只记 root 许可 |

本轮 NIOSSL 连接认证只读快照为 `2a439aff650ba63077cf7bed86677c739f76d782`；已读取该提交的上述两份源文件、LICENSE 和 NOTICE。根 LICENSE 为 11,358 bytes、SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`；NOTICE 为 1,984 bytes、SHA-256 `03e8ca5c65a3df21fe1ab48eef91bca7d370db56c290d8ef16eaaa09ba322abe`。这是研究来源，不是已采用依赖或安全认证。

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
