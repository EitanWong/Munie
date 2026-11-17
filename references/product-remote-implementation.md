# iPhone–Mac 产品实现依据

核对日期：2026-11-18。用途：首个可用产品切片中已经需要的网络、主机生命周期、原生输入与通知机制。当前实现唯一见[架构](../docs/architecture.md)，安全选择唯一见[信任与服务决策](../docs/decisions/device-trust-and-host-service.md)，执行结果唯一见[项目状态](../docs/project-status.md)。本页记录来源和采用理由，不将文档/API 声明当作系统运行验收。

## 已核对的官方机制

| 官方来源 | 本次采用与限制 |
|---|---|
| Apple [Network](https://developer.apple.com/documentation/network) / [NWParameters.requiredLocalEndpoint](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint) | Apple 明确该属性指定连接/listener 的本地 IP/port；`HostHTTPServer` 直接设 IPv4 loopback，不靠防火墙或 advertised URL 假装只监听本机。iPhone HTTP 客户端继续用 URLSession；Network.framework 本身不替产品实现 HTTP framing、权限或任务恢复 |
| Apple [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) / [register](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) / [unregister](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()) | `mainApp` 是主 app 的登录项服务对象，Mac companion 显式提供注册操作；它不是 native 孙进程监督器。注册受用户/系统批准，运行状态与业务 listener/账号就绪分别观察；本次不因可编译而声称已接受登录、退出、升级或签名生命周期 |
| Tailscale [Serve](https://tailscale.com/docs/features/tailscale-serve) / [Serve CLI](https://tailscale.com/docs/reference/tailscale-cli/serve) | Serve 将私有 tailnet 请求送到本机服务，其 daemon 默认终止 HTTPS；HTTP reverse proxy 的目标为 loopback。产品配置为 HTTPS→同 Mac 的 `http://127.0.0.1:9274`，不配置公网 Funnel，不信任转发身份头代替应用 token。需要实际登录、tailnet HTTPS 与访问规则；没有凭空获得蜂窝可达性 |
| Tailscale [Userspace networking](https://tailscale.com/docs/concepts/userspace-networking) / [tailscaled](https://tailscale.com/docs/reference/tailscaled) | 文档给出 `--tun=userspace-networking` 的 daemon 模式及代理用法，可作为不创建 TUN 的明确部署选择。它不是普通 Watch 继承 iPhone VPN 的证据，也不说明 iPhone 上任意 app 已经具备该路径。运行/退出、凭据与设备授权须单独记录 |
| Apple [WhenUnlockedThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly) | 手机 bearer 凭据使用非同步 Keychain 项，并在锁定无法读取时提示解锁；该属性不证明 Secure Enclave、已载入 token 的即时内存清零或后台任意可用性 |
| Apple [Speech audio-buffer request](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest) / [supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition) / [requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition) | iOS 只在 recognizer 支持时要求 on-device recognition；显式开始、最长 30 秒、停止后至多三秒等待最终转写。未支持语言/模型、不可用或拒权时保留可编辑文字回退，不静默改用云端识别，不保存录音 |
| Apple [record permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)) / [interruption](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification) / [route change](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification) | 仅在用户触发语音时请求权限。中断、音频路由变化和离开 active scene 停止采集，不自动恢复；具体电话/蓝牙/锁屏行为仍需实机 |
| Apple [Scanning data with the camera](https://developer.apple.com/documentation/visionkit/scanning-data-with-the-camera) | QR 走受支持且可用的 native DataScanner，邀请 JSON 有界；相机不支持、不可用或拒权时可手动输入同一邀请，不把扫描失败变成已配对 |
| Apple [App Intents](https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework) / [openAppWhenRun](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun) / [API updates](https://developer.apple.com/documentation/updates/appintents) | Shortcut 打开输入或任务界面；用户可自行给支持的 Action button 配置 Shortcut。入口不在锁屏直接审批、启动麦克风或提交 shell；旧/新 API 编译边界不替代 Siri/硬件验收 |
| Apple [Notification actions](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions) / [APNs provider connection](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns) | generic 通知通过不敏感任务 ID 路由，打开后重新认证查询。客户端本地通知依赖已观察状态；主机 APNs sender 是可选集成，需要真实签名、密钥与 device token。权限、Focus、延迟及拒绝不改变任务权威状态，尚未执行的背景投递不称作已支持证据 |

以上 Apple 文档仅保存链接与本项目实施摘要，适用 [Apple 网站条款](https://www.apple.com/legal/internet-services/terms/site.html)。Tailscale 文档与服务另受其[服务条款](https://tailscale.com/terms)及[隐私政策](https://tailscale.com/privacy-policy)约束；开源 CLI 的许可证不自动覆盖托管账号、商业二进制、商标或服务条件。

## 成熟组件与最小采用决定

| 选择 | 评估与本次决定 |
|---|---|
| Apple Network.framework + 窄范围本机 HTTP | 当前只需一个 loopback listener、单个固定 JSON route、短请求、固定 Content-Length 和明确总 deadline，因此采用项目内小型实现。拒绝歧义、扩展和多请求，不声称一般 HTTP server 能力。若增加公网监听、通用代理、流式/HTTP2 或更多 HTTP 行为，应先复评成熟协议实现，不能不断扩张手写 parser |
| [SwiftNIO](https://github.com/apple/swift-nio) / [NIOHTTP1](https://github.com/apple/swift-nio/tree/main/Sources/NIOHTTP1) | 成熟的事件驱动网络框架与 HTTP/1 codec，官方仓库 Apache-2.0；可承担更一般的协议/背压需求。当前范围不足以支持引入其 event-loop/多包依赖；本次不链接、不复制源码，也不因未采用而推断其不适合未来服务 |
| 私有 Tailscale Serve | 复用现成设备网络与 Mac HTTPS 终止，不新建公有 relay、issuer 或密钥交换基础设施。手机额外持有独立应用 bearer grant。部署受 tailnet、设备登录和 Mac 睡眠条件约束；当前实现不承诺独立 Watch 网络 |
| 原生 mTLS/CSR identity | 已有[独立认证网络研究](authenticated-network-research.md)及[固定 fixture 依赖/许可](licenses/device-identity/README.md)，保留证据。正式跨平台私钥持久化、续期、激活与 issuer 运维尚有独立门槛；当前产品不引入这些研究依赖，也不要求先合并未完成的身份研究 |
| `SMAppService.mainApp` 与 C guardian | 主 app 直接管理 actors，避免先增加 helper/IPC；独立小型 guardian 负责 transport 进程组与 owner-death 窗口。它不是完整 launchd/设备签名/脱离进程组后代验收。若需要无 UI helper，再以实际需求设计 `agent(plistName:)` 和经验证的本地控制通道 |

根和产品 Swift packages 仍仅链接 Apple 框架/系统 SQLite 及项目自己的模块。Tailscale 是用户另外安装的网络服务，不嵌入 app、不从其代码复制组件。SwiftNIO 仅为比较来源；未产生第三方 checkout、源码采用或链接依赖，故不新增伪造的 dependency pin。

## Tailscale 版本与许可来源

本切片选择的外部 CLI 为 **1.104.7**，与 app 分别安装和维护。2026-11-18 通过 GitHub API 验证的上游来源：

- [v1.104.7 tag](https://github.com/tailscale/tailscale/releases/tag/v1.104.7) 的 annotated tag object 为 `fb3b9b2964ace04490fbd65d4f26a0eaf362131f`，指向 [commit `cbc74fe48ef1b1649f69a4d9a602319427e25102`](https://github.com/tailscale/tailscale/commit/cbc74fe48ef1b1649f69a4d9a602319427e25102)。
- 该 commit 的 [root LICENSE](https://github.com/tailscale/tailscale/blob/cbc74fe48ef1b1649f69a4d9a602319427e25102/LICENSE) 为 BSD-3-Clause；记录的是上游 root 许可，不是所有依赖/二进制/服务的完整许可审计。
- 没有将 CLI、daemon、文档全文或上游源码打包进 Munie；若以后分发 Tailscale 组件，需另行审查实际分发物与保留 notices，不能只引用此登记。

版本/源码对应不证明已登录、Serve 已启用、当前用户批准了所有 tailnet 权限、iPhone 已安装网络客户端或蜂窝请求成功。实际执行记录及复现命令由[测试说明](../docs/testing.md)与[项目状态](../docs/project-status.md)维护。
