# 语音、多模态与主动回报调研

核对日期：2026-11-17。产品方向是个人助理前端：手机、Watch 等设备以语音为主入口，文字为兜底，图片/拍摄/视频补充真实场景；Mac 上的 Codex 执行任务。当前 Munie 仍只有本机文本记录；本文全部远程、语音、媒体、通知链路均未实现或实测。本文记录候选与实施门槛，不能作为能力宣传。

## 首条可执行路线

按住说话或系统听写 → 完成一次有边界的录音/转写 → 结构化任务意图与附件引用 → 已配对 Mac 接收 → Codex 真实执行事件 → 手机/Watch 进度摘要与完成回报。输入预览允许快速修正；在已授权范围内直接执行低风险请求，不为每一步增加确认。必要信息缺失时合并澄清；破坏性动作、敏感外发或权限扩展保留真实审批。语音模型、识别置信度与媒体内容都不能代替用户授权。

“停止说话/打断播报”“取消录音”“取消后台任务”分别建模。断开语音会话不自动取消 Mac 工作；重新连接后按任务 ID 取回状态。完成回报必须关联实际终态和结果，不能由语音前台根据等待时长猜测。远程协议与主机安全另见[入口调研](entry-point-research.md)及[安全边界](../SECURITY.md)。

## Apple 原生能力与适用边界

| 能力与官方依据 | 对 Munie 的实施决定 |
|---|---|
| [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer) / [语音权限](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition) | iOS 18 兼容候选：按用户触发录音并转写；检查授权、语言、服务可用性与 `supportsOnDeviceRecognition`。某些语言依赖网络，不能统一声称离线。短会话处理服务限制、超时和失败；原生转写不是任务理解或执行器 |
| [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) / [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) | 当前 symbol 标为 iOS/iPadOS/macOS 等 26+，无 watchOS 支持项；需要硬件、语言与已安装模型检查。现有最低 iOS 18/macOS 15 必须有旧系统路径，不能直接全平台采用。设备可用后评估本地转写延迟与能耗 |
| [Watch 系统文本输入](https://developer.apple.com/documentation/watchkit/wkinterfacecontroller/presenttextinputcontroller(withsuggestions:allowedinputmode:completion:)) / [Watch 音频录制](https://developer.apple.com/documentation/watchkit/audio-recording-options) | 系统输入可提供听写；定制语音会话另评估受控录音后上传至手机/Mac/语音服务。Watch 首屏突出说话、停止和任务状态，文字编辑是替代路径。不能把 iPhone Speech API 默认移植到 Watch；独立蜂窝与经手机转发分开验收 |
| [AVCaptureDevice 权限](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)) / [音频中断](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions) | 相机、麦克风只在使用时申请，提供双语用途说明；来电、蓝牙切换、锁屏和撤权要停止/恢复到明确状态。新旧系统的中断 API 按 availability 适配；不能因已获权限而长期采集 |
| [PhotosUI](https://developer.apple.com/documentation/photosui) / [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker) | 优先系统选择器，仅获取用户选择的素材；图片和视频按类型加载，处理 iCloud 素材离线/加载失败。不要为“选一张图”要求整个相册权限。Watch 的可选素材与可用交互单独验证；不假定手机相机流程可照搬 |
| [AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator) | 在手机或 Mac 有界抽取视频时间点的图像，记录实际时间戳、方向与尺寸；语音轨另转写/处理。异步执行并支持取消，避免整段逐帧解码到内存 |
| [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) | 手机/Watch 可评估系统 TTS 播报短结果；尊重当前音频路由、静音/隐私偏好与停止操作。API 存在不等于系统允许后台任意时刻自动开口 |

原生方案的首轮优势是短路径、依赖少、可保留本地转写选项；需另补任务理解、会话与回报。先测中英文噪声、口音、首字延迟、识别错误恢复和电量，再决定是否引入连续双向语音前台。系统听写也属于语音入口，不把产品默认设计成 Watch 打字工具。

## Qwen 候选、固定版本与许可

找到名称一致的上游 [QwenAudio/qwen-audio-agent](https://github.com/QwenAudio/qwen-audio-agent)，其 README 链接 [Qwen-Audio-Agent 技术报告](https://arxiv.org/abs/2609.25195)。它与 `QwenLM/Qwen-Agent`、`QwenLM/Qwen3-Omni` 是不同仓库；用户尚未提供链接，名称匹配不等于已确认选型。以下只读取上游文本，未安装、运行或下载模型权重。

| 候选 / 已核对版本 | 可借鉴机制 / 决定 |
|---|---|
| `QwenAudio/qwen-audio-agent`：`9408dac627952e036626ea96ff6779bd8482cab5`；[README](https://github.com/QwenAudio/qwen-audio-agent/blob/9408dac627952e036626ea96ff6779bd8482cab5/README.md)、[架构](https://github.com/QwenAudio/qwen-audio-agent/blob/9408dac627952e036626ea96ff6779bd8482cab5/docs/architecture/deep-dive.md)、[后端](https://github.com/QwenAudio/qwen-audio-agent/blob/9408dac627952e036626ea96ff6779bd8482cab5/docs/backends/overview.md) | 对话前台与异步任务后台分层；可打断对话，任务持续并返回结果。README 的 Codex 接入使用外部 ACP adapter，不能当成官方 app-server 的直接兼容证明。作为未来语音前台候选，暂不整体移植其 Electron/Web UI 或安装栈 |
| 同版本[权限配置](https://github.com/QwenAudio/qwen-audio-agent/blob/9408dac627952e036626ea96ff6779bd8482cab5/docs/configuration/backend.md)、[隐私声明](https://github.com/QwenAudio/qwen-audio-agent/blob/9408dac627952e036626ea96ff6779bd8482cab5/PRIVACY.md) | 其云语音默认涉及音频/上下文外发，本地记忆与卸载后的保留需要独立管理。Munie 不能沿用最大权限自动批准模式；语音前台只发结构化意图，Codex 凭据与审批策略归可信 Mac。任何上游权限转发都须重新评审 |
| `QwenLM/Qwen3-Omni`：`e4235853125589c789f06a2dd83e9f4126df5e9d`；[README](https://github.com/QwenLM/Qwen3-Omni/blob/e4235853125589c789f06a2dd83e9f4126df5e9d/README.md)、[音频调用示例](https://github.com/QwenLM/Qwen3-Omni/blob/e4235853125589c789f06a2dd83e9f4126df5e9d/cookbooks/audio_function_call.ipynb) | 官方模型方案支持音频/图像/视频理解与部分型号语音输出；模型能力不等于完整任务运行时。作为受控模型服务候选，先测所用硬件/模型/API 的实时性、内存和账单；未验证本机 Mac 能以目标延迟运行，也不部署到 Watch |

`git ls-remote … HEAD` 固定上述 Git 提交。许可分层记录如下；没有新增运行时依赖或复制源码，未来采用仍需进入[引用清单](README.md)并保存适用许可与 NOTICE。

| 层 | 核对结果与限制 |
|---|---|
| qwen-audio-agent 源码 | [根 LICENSE](https://github.com/QwenAudio/qwen-audio-agent/blob/9408dac627952e036626ea96ff6779bd8482cab5/LICENSE)：Apache-2.0，11,359 bytes，SHA-256 `1b53e5436e8d362c67ee40f717db5ddb658559067f2ba341baf12a86c714d383`。不代替依赖、语音服务、唤醒模型和素材各自的许可 |
| Qwen3-Omni 源码 | [根 LICENSE](https://github.com/QwenLM/Qwen3-Omni/blob/e4235853125589c789f06a2dd83e9f4126df5e9d/LICENSE)：Apache-2.0，11,343 bytes，SHA-256 `8d5eb5f806d01e8f5ea2c5a52f7d68ebc54b196b1cfbe1cd5dfa4b94e482a9c6` |
| 模型权重 | [Qwen3-Omni-30B-A3B-Instruct 模型卡](https://huggingface.co/Qwen/Qwen3-Omni-30B-A3B-Instruct/blob/26291f793822fb6be9555850f06dfe95f2d7e695/README.md) 固定模型 revision `26291f793822fb6be9555850f06dfe95f2d7e695`，元数据为 `license: other`、`license_name: apache-2.0`；该快照文件列表未发现独立 LICENSE。仅记录发布者声明，不据根源码许可推导全部权重/其他型号的权利；采用前补齐准确权重包的完整条款 |
| 云服务 | qwen-audio-agent 许可不授予 DashScope/其他供应商配额、数据处理权或服务承诺。服务地区、费用、日志保留、训练使用与删除条款在选型时分别核对；密钥留在可信服务端或安全存储 |

首轮采用方向：Apple 短会话入口 + 可替换语音 adapter + 可信 Mac Codex；Qwen 作为后续持续对话候选。比较相同任务的端到端延迟、打断正确性、任务不丢失、中英文完成率、内存/电量/网络字节、外发数据与单位成功任务成本，不能用上游演示或论文分数当 Munie 结果。

## Codex 输入协议与视频预处理

本机 `codex-cli 0.162.1` 的 `codex app-server generate-json-schema --out <TEMP>` 于核对日退出 0。生成的 `v2/TurnStartParams.json` SHA-256 为 `583aff13e7a2da43fbb0150e0edc3c73171f374f0aa745dddba256166988a005`。`input` 的 `UserInput` 声明 `text`、`image`（`url` 或 `fileId`）、`localImage`（`path`），也声明 `audio`（`url`）和 `localAudio`（`path`），另有 `skill`、`mention`；未声明 `video` variant。与[官方 app-server 文档](https://developers.openai.com/codex/app-server)一起用于后续兼容夹具。

这些是 schema 观察，没有向模型提交媒体；所选模型/账户/运行时是否接受并正确处理须实际验证。`localImage`/`localAudio` 的路径指 Mac 可访问的文件，不能直接传手机路径，也不能接受客户端任意指定主机路径。由可信附件上传和允许目录映射产生引用，内容校验后再提交。URL 同样需防止读取内网或非预期地址。

视频首轮候选：经用户选择的短视频 → 有界帧及时间戳 + 有界音轨/转写 → 意图与证据附件。按场景保留时间顺序，抽帧可能漏掉短事件，摘要必须说明采样范围；需要实时连续理解时另用受测多模态前台，不能把 MP4 路径塞入图片字段并宣称原生视频支持。

## 媒体隐私、容量与背压

以下是待实现的初始内部上限，需测量后再批准，不是 Apple 或模型厂商规定：语音单次 30 秒；图片最多 4 张、每张长边最多 2,048 像素；视频单次 30 秒、最多 12 帧。所有路径还须有压缩后字节、解码像素、待处理总字节、并发及超时硬限制，不能仅靠文件扩展名或数量。超限提示用户缩小范围；不静默截断离线附件。直播只保留有限缓冲，处理跟不上时降采样或丢弃过时帧并报告采样缺口，不能无限堆积。

原始媒体、转写、缩略图、派生帧和结果分别声明保留期与删除责任；默认不长期保留原始录音/视频，不把媒体放入日志、通知或普通记录 JSON。上传前检查 MIME、字节/像素、方向与元数据，默认去除不必要的位置等敏感信息。以任务/附件 ID、摘要校验和短期授权引用传输，支持取消清理、失败重试、离线暂存与恢复后去重；设备、Mac、relay、语音供应商的数据去向必须可解释。媒体内容与转写是输入数据，不授予文件或网络操作权限。

## 进度、通知与主动回报

| 渠道 / 官方依据 | 正确的产品承诺 |
|---|---|
| 前台连接 + 任务查询 | Mac 保存任务事件与最新状态，按 revision/cursor 恢复；进度合并为简短阶段摘要。区分执行完成、摘要生成、回报排队、已取回，通知送达不能充当任务终态 |
| [UserNotifications](https://developer.apple.com/documentation/usernotifications) / [APNs 服务端](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server) | 对完成、失败、待批准发送用户允许的提示，默认锁屏不含私人内容；用户可调频率、静音和私密预览。APNs 提交成功、显示成功、用户读到/听到是不同事实；仍保留打开 app 拉取结果路径 |
| [后台通知](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app) / [后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) / [Watch 生命周期](https://developer.apple.com/documentation/watchkit/working-with-the-watchos-app-life-cycle) | 后台通知可能延迟、合并或不送达，后台时间受系统管理；不能保证唤醒后立即播报，也不能用无声推送维持常驻。先通知提示，再按当前会话与用户偏好播报；Watch 独立接收、手机镜像及离线恢复分别实测 |
| 语音回报 | 活跃且允许播报的会话读出简短结论，可随时打断并查看依据；后台采用系统允许的通知/声音路径。说“完成了”必须来自持久任务结果；播报中断只改变回报状态，不回滚已完成任务 |
| [Message UI](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller) | 系统短信编辑界面由用户选择发送，不提供任意后台静默 SMS 保证。若以后采用服务端短信，需另选供应商、验证号码与费用/同意/敏感内容策略；短信只作为可选回报渠道，当前不接入 |

## 实施验收与远期眼镜

首个后续功能切片验收：手机与 Watch 各用一句中/英文语音启动同一类 Mac 任务 → 真实运行摘要 → 手机/Watch 取得真实完成结果 → 继续一句追问。加入文字兜底和一次错误转写修正；分别验证冷启动/锁屏、拒绝或撤回权限、来电/耳机切换、网络切换、Mac 睡眠、重复提交、取消、重连与通知关闭。记录麦克风首响应、最终转写、主机接收、首进度、完成、回报可见的时间点与失败分母；无运行证据保持未验收。

第二切片再加入单张照片及拍摄，第三切片才加入有界视频；持续双向语音与智能眼镜作为独立技术调查。目标是用户显式开启的一段实时视听上下文，提供清楚采集标志、立即停止、保留控制和旁观者隐私边界；不默认 always-on。Meta 等眼镜的 SDK 能力、音频路由、后台限制及分发权仍按[现有引用](README.md)逐项核对，不从“Jarvis”愿景推导硬件已经开放或能全天运行。
