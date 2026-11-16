# 产品验证与实验 / Product learning

## 需求与验证职责

产品范围只维护在[需求基线](requirements.md)：随身个人 Agent 前台，首个执行后端为自己的 Mac Codex，语音及设备特性优先。本页只维护如何验证价值，不另立产品定位。当前能力和结果只看[项目状态](project-status.md)。

首位用户是所有者，再考虑小规模邀请。当前主假设：离开电脑后，用语音、手机或手表继续自己的 Codex 工作，比等待回到 Mac 或使用传统远程桌面更快、更少步骤，且不损失对任务和权限的理解。生活多模态场景单独验证，不能用开发者场景成功推断全部助理价值。

已有原生前台和记录底座可以复用；记事验证不再是当前主线。过往调研保留为有出处的历史证据，不能覆盖所有者最新需求。开源采用由[引用登记](../references/README.md)维护。

## Build–Measure–Learn

Keep at most one main learning objective and one time-boxed technical investigation active. Fix the hypothesis, counter-evidence, measurement, threshold and time/cost budget before starting. Record observations separately from interpretation. Results can justify continuing, narrowing, changing the scenario, stopping, or keeping only a personal tool.

| Experiment | Method / provisional decision rule | Status |
|---|---|---|
| E1 Problem discovery | 12 qualified interviews; ≥8 repeated recent problems and ≥5 existing workarounds | Planned |
| E2 Transparent service prototype | 5 people × 7 days; ≥3 return on two later days and each uses a result | Planned |
| E3 Entry comparison | 8 paired users; median per-user time improvement ≥30%, without worse completion/quality | Planned |
| E4 First technical path | At most two developer days; cold start, lock, permission, interruption and network results | Planned |
| E5 Trust controls | 6 people; ≥5 can explain and operate relevant data/recording controls | Planned |
| E6 Invited activation/return | Rolling cohorts; define independent activation and full week-2 window before launch | Planned |
| E7 Payment | Real delivered value, one offer, actual purchases and refunds | Planned |
| E8 One acquisition channel | Contact → response → activation → return → payment, including founder time | Planned |

These are suggested internal rules from prior research, not market benchmarks. Founder use is a separate sample. Praise, downloads, simulated payment and AI-declared completion are not evidence of retained value. Invitations have not been sent by this project.

## Immediate execution

1. 按[基础准入](foundation-readiness.md)先完成前期规范与工程门禁；真实连接采用受控合成项目探针。
2. 记录所有者 3–7 天“人在外面却需要 Mac Agent”的真实触发、当前解决方法与成本，不声称已采集。
3. 在真实远程闭环就绪后，比较同类任务的完成率、操作/纠错步骤、入口到接受及首进度延迟、结果是否被使用；语音与文字分别记录。
4. 周期复核证据，记录失败和提示使用，按真实障碍决定下一片；邀请用户、付费实验和持续环境感知各有独立门槛。

The current app does not implement analytics. A redacted local diary is sufficient initially. Show numerator/denominator, preserve failures and prompted use, and report immature cohorts separately. Value means a real task result was understood and used, rather than merely that the app opened or a draft was saved.

## 后续实验边界

实验 E1–E8 是此前提出的学习工具，均未执行；实施时围绕当前需求重写场景，不机械沿用“丢失想法”的样本。技术准入不在此重复维护，见[基础顺序](foundation-readiness.md)、[平台验收](standards/platform-acceptance.md)和[多模态研究](../references/multimodal-research.md)。

Use [original experiment cards](research/个人AI前台_首轮实验与访谈模板.md). Recheck official platform rules at implementation time; archived SDK observations can become stale.
