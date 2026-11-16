# 远程 Codex 与轻量入口调研

核对日期：2026-11-17。核心场景是手机/Watch 随时访问自己 Mac 上的 Codex，Watch 优先原生语音输入，手机保留文字；离线记录只辅助保留需求。照片/视频/相机及长期语音协调器/眼镜上下文须分阶段验证；当前 app 仍为本地文本能力。用于[入口设计](../docs/standards/entry-points.md)，不代表远程已实现。官方文档只保存链接与摘要，上游源码只读，未复制、构建或执行。

## 官方协议与系统入口

| 来源 | 核对事实 / 本项目决定 |
|---|---|
| [Codex app-server](https://developers.openai.com/codex/app-server) | 每连接 `initialize` → `initialized`；`thread/start` / `thread/resume` 选择会话，`turn/start` 开始工作。消费事件至 `turn/completed`，中断也要确认终态。审批是反向 RPC，必须关联其请求。用固定 CLI 生成 JSON Schema 做兼容夹具。首轮优先本机 stdio adapter；文档当前标记 WebSocket experimental/unsupported，非 loopback 默认可能未认证，不直接暴露公网。`thread/shellCommand` 不继承 thread sandbox，v1 不暴露通用 shell 方法 |
| [AppIntent](https://developer.apple.com/documentation/appintents/appintent) / [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider) | 系统动作与预配置快捷指令。采用方向为新任务输入、任务状态和后续受控提交；不把 Codex 登录或模型配置加入日常主流程 |
| [authenticationPolicy](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy) | 默认 `alwaysAllowed` 允许锁屏执行。远程动作显式评审认证、数据保护和结果遮盖，锁屏不能自动批准特权执行 |
| [Creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system) | Controls 可执行动作或打开特定界面；打开 app 的 intent 须纳入 app 与 widget extension。先导航，真实执行经已审查协议；逐平台检查 availability |
| [Accessory widgets and watch complications](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications) | WidgetKit 提供锁屏、Watch complication / Smart Stack 入口，需相应 extension。用于短任务和可扫视状态，不复制桌面工具面板 |
| [HIG Action button](https://developer.apple.com/design/human-interface-guidelines/action-button) | 用户在支持设备上选择动作；iPhone/Watch Ultra 快捷指令与 Watch 运动/潜水直接集成分别考虑。不把训练/潜水 API 伪装成通用 Agent 按键，不新增只做“打开 app”的冗余 shortcut |
| [Recording permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)) / [Audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions) | 录音须明确权限及用途，响应会话中断。系统输入优先；自建语音单独验证拒绝、停止、路由与耗电 |
| [Background notifications](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app) / [Notification permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) | 背景推送低优先级且不保证投递，提醒/声音依赖授权与设置。Mac 侧生成事件摘要、手机/Watch 接收提醒，再打开时补齐真实状态；不承诺即时投递、后台任意播报或以轮询替代系统限制 |
| [App Review 2.5.4 / 2.5.14](https://developer.apple.com/app-store/review/guidelines/#software-requirements) | 后台服务限预期用途，采集须同意并可感知。audio 声明不证明永久自定义唤醒可行，不承诺随时监听 |

Apple 正文经其 Markdown 入口核对。实现时按 `project.yml` 最低系统和具体 symbol availability 再验证；Siri 的语言、地区、设备与锁屏行为单独实测。Codex 协议页面持续演进，实施前固定本机 CLI 版本、schema 和已用 stable 方法；网页不替代运行证据。官方使用权边界见[来源登记](apple-platform-guidance.md)。

## 固定版本源码与采用决定

本地三份 checkout 的 HEAD 与[清单](manifest.json)一致且工作区 clean。固定 commit 链接及源码符号如下；根许可证快照保留在清单中，传递依赖/模型/资产/SDK 仍需独立复核。

| 项目 / pin / 根许可 | 实际检查的代码 | 可借鉴点 / 取舍 |
|---|---|---|
| Remodex `c06dcb16a705` / Apache-2.0 | [codex-transport.js](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/phodex-bridge/src/codex-transport.js)：`createCodexTransport`、`createSpawnTransport`；[SELF_HOSTING_MODEL.md](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/SELF_HOSTING_MODEL.md) | Mac 运行 Codex，手机为配对客户端，relay 仅传输；spawn 本机 app-server 的边界适合首轮候选。公开源码不提供私有 relay/签名等部署条件，不能拿源码存在当公网可用证据 |
| Remodex 同上 | [secure-transport.js](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/phodex-bridge/src/secure-transport.js)：`handleClientHello`、`handleClientAuth`、`handleEncryptedEnvelope`、`handleResumeState` | 已见 QR 过期、trusted public key 校验、签名握手、加密 envelope 的 epoch/counter 防重放、有界事件回放及 gap 标记。借鉴机制与失败夹具；加密计数器不等于业务提交幂等，仍需 Munie request ID/执行台账与撤销设计。不是密码学安全认证，不直接移植自制协议 |
| Remodex 同上 | [CodexService+Notifications.swift](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/CodexMobile/CodexMobile/Services/CodexService%2BNotifications.swift)：`routePendingNotificationOpenIfPossible` | 保留待打开目标，重连确认真实 thread 后路由；适合冷启动任务恢复参考。通知不是执行结果证据，权限拒绝应保留手动查询 |
| Chums `6821bd6e1aa3` / Apache-2.0 | [runtimes.mjs](https://github.com/lcoutodemos/chums/blob/6821bd6e1aa3d3fb41ca77bd0cc4de0dbbb8097a/hub/runtimes.mjs)：Codex runner 的 `run`、`order`、`request`；[HubClient.swift](https://github.com/lcoutodemos/chums/blob/6821bd6e1aa3d3fb41ca77bd0cc4de0dbbb8097a/app/ChumsWatch/HubClient.swift)：`pollLoop`、`apply` | 直接初始化/恢复 Codex thread，运行中 steer，审批映射到 Watch 卡片；Watch 以 Bearer 请求带 revision 的状态。借鉴短任务 UI 与增量状态；不能继承其失败后新建 thread 的策略而静默改变用户任务 |
| Chums 同上 | [hub.mjs](https://github.com/lcoutodemos/chums/blob/6821bd6e1aa3d3fb41ca77bd0cc4de0dbbb8097a/hub/hub.mjs)：`publicServer`；[Intents.swift](https://github.com/lcoutodemos/chums/blob/6821bd6e1aa3d3fb41ca77bd0cc4de0dbbb8097a/app/ChumsPhoneShared/Intents.swift)：`TalkToAgent`、`AnswerApproval`；[ChumsWidget.swift](https://github.com/lcoutodemos/chums/blob/6821bd6e1aa3d3fb41ca77bd0cc4de0dbbb8097a/app/ChumsWidget/ChumsWidget.swift)：`ChumsWidget` | 对外入口限制 `/v1/`、校验 Watch token，经隧道访问；这是观察到的实现，不是 Munie 认证/撤销方案。参考导航型 complication 和复用 intent；其 `AnswerApproval` 忽略 verdict 返回值后成功，Munie 必须等真实确认，不能照搬 |
| OpenVision `1d5d9203a36f` / MIT | [AudioSessionManager.swift](https://github.com/rayl15/OpenVision/blob/1d5d9203a36f76040947425a603eba57757eac75/OpenVision/Services/Audio/AudioSessionManager.swift)：`configureForGlasses`、`configureForPhone`；[AudioCaptureService.swift](https://github.com/rayl15/OpenVision/blob/1d5d9203a36f76040947425a603eba57757eac75/OpenVision/Services/Audio/AudioCaptureService.swift)：`startCapture`、`stopCapture` | 参考实际 HFP 路由选择、无眼镜输入时降级和停止。注释不是硬件验证，音频模式不能证明唤醒/相机共存。眼镜暂缓；MIT 根许可不覆盖 Meta SDK、模型与资产 |

本轮仅研究，不引入源码或运行时依赖。采用代码前保留 notice 并更新[复用决策](reuse-decisions.md)。其他已登记方案按[现有引用入口](README.md)检索，不重复下载。

## 关键源码读取指纹

以下 SHA-256 标识本次阅读内容，不代表审计结论。路径与固定版本见上表。

```text
Remodex / codex-transport.js
93abfedd14ac41557a298c87b1d655ace8719305c966b43f4e616ce644db4787
Remodex / secure-transport.js
76dc535f92881b7240b55052c190d28c195bf7a30d5ae8cae2f89befd6210947
Remodex / CodexService+Notifications.swift
73ee8b45ae27df4c965e02f336dbec884fd2e5146158768d0b97964fd3d17cc2
Chums / hub/runtimes.mjs
60422603d506a8eed5162944f80cbbb46488d8a3e2c98efaad8884e6029295e6
Chums / hub/hub.mjs
05be34be0465ff8920c7fd227ffd2f0ef0a40cbbda5ab10c750877b353009b4f
Chums / HubClient.swift
2d5e0937cd659ea84b8c4d86dda9f178d5957bbcf29e8593da595fe56beabc30
OpenVision / AudioSessionManager.swift
d921187db12486726a23754101d84ac14bd9fab5479424d07e393275fa477320
OpenVision / AudioCaptureService.swift
094ab71e5ca624f6f14a97fb6cd17d90e6547101c99144b2fba25841c1306337
```

下一步依次固定远程需求/威胁模型、Mac adapter 与最小协议、真实蜂窝闭环，再增加设备入口。配对/撤销、认证、工作区授权、审批关联、断连恢复、重复提交、取消、主机睡眠、进程崩溃是首条闭环的验收条件；上线何种 relay 或私有网络是待证据比较的部署决定，不由上游默认值替用户决定。

## Apple 硬件入口与反馈复核

2026-11-17 补查官方正文，修正“Watch 按键只能用于活动”的过度概括：[Apple Watch Ultra Action button](https://developer.apple.com/documentation/appintents/actionbuttonarticle)明确系统可选择运行 Shortcuts；workout/dive App Intents 直接注册与其会话内 next action 是另一条专用机制。Munie 采用用户选择的任务 Shortcut 候选，不为捕获按键启动虚假运动/潜水会话。普通 Watch 可用系统 Siri、表盘/Smart Stack 与 app 入口，不能承诺任意重映射 Digital Crown/侧键。

[AirPods Siri 指引](https://support.apple.com/en-ie/guide/airpods/devc2c0f438a/web)说明支持的耳机可语音或硬件控制唤起 Siri，用户可选择通知播报；具体机型/OS/设置分别验证。[App Intents snippets](https://developer.apple.com/documentation/appintents/displaying-static-and-interactive-snippets)提供 dialog，让系统可在 AirPods 或无屏设备上朗读 intent 结果。它适合接收/短查询反馈，不证明 app 能在后台任意时刻自启动录音或朗读。

[WWDC25 Capture Controls](https://developer.apple.com/videos/play/wwdc2025/253/)确认 iOS 26/H2 AirPods 可触发相机捕获；这依赖活跃相机 capture session，后台不接收这些事件。可用于未来真正拍摄素材，不可拿相机会话当通用后台语音按键监听。本文未发现可将所有耳机硬件按键任意全局映射到 Agent 的依据，首轮采用 Siri/Shortcut 替代路径并实机验证。

[语音会话 app 的 iPhone side button](https://developer.apple.com/documentation/appintents/launching-your-voice-based-conversational-app-from-the-side-button-of-iphone)另有地区/entitlement 限制，官方当前限定日本条件；不能当作所有地区普遍入口。一般 iPhone Action button 仍按已支持的硬件与用户 Shortcuts 配置设计。

上述是机制与适用范围研究，没有新增 entitlement、后台模式、录音、通知或硬件运行结果。产品的反馈路由、隐私及验收只在[入口规范](../docs/standards/entry-points.md#硬件触发与掌控感)维护。

## Apple 生态兼容范围补查

2026-11-17 核对 [Siri 运行 Shortcuts](https://support.apple.com/guide/shortcuts/run-shortcuts-with-siri-apd07c25bb38/ios)及 [HomePod Personal Requests](https://support.apple.com/guide/homepod/make-personal-content-requests-apde0a4edb55/homepod)：HomePod 可作为已有个人快捷指令的系统入口候选，需配置、身份与依赖设备条件；未验证 Munie 可在其上独立常驻执行。[Apple Pencil squeeze](https://developer.apple.com/documentation/applepencil/handling-squeezes-from-apple-pencil)提供 Pencil Pro 的 view 交互；它是适合特定前台场景的快捷手势，不是通用后台按键。

[CarPlay 官方分类](https://developer.apple.com/carplay/)与 [Developer Guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)当前包含 voice-based conversational app 类别，指南标注 iOS 26.4 与 `com.apple.developer.carplay-voice-based-conversation` entitlement。因此可以单独研究语音助理入口，不能沿用“所有第三方助理均不能接入”的旧假设；类别、模板、安全交互与批准条件仍须验收，本项目未申请/获批。Mac/iPad/TV/Vision 的输入与界面按[平台矩阵](../docs/standards/platform-acceptance.md)展开，不复制手机布局。
