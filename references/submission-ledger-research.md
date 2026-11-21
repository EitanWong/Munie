# 执行主机授权与提交账本

核对日期：2026-11-17。关联 R01/R02/R06/R07/R08/R16；范围为 F1 主机端协议安全基础。本页维护存储/重试的依据和实验边界；已实现结构见[架构](../docs/architecture.md)，产品信任规则唯一维护在[远程决策](../docs/decisions/remote-agent-foundation.md)，实际结果在[项目状态](../docs/project-status.md)。不包含网络认证、手机连接、真实 Codex adapter 或模型执行。

## 方案选择与许可

本轮用系统 `SQLite3`，一个 Mac actor、一条连接及生命周期独占 `flock`。主机模块位于 `apps/MunieHost/Execution`，实际调用者是同目录的故障实验 executable；暂不新增共享 package 或通用 ORM。现有捕获 JSON 文件保持自己的简单本地存储职责。

Apple 的[结构化数据指引](https://developer.apple.com/documentation/technologyoverviews/structured-data-models#Store-data-using-SQLite)说明 SQLite 包含在 Apple SDK；本机 SDK 的 `SQLite3.modulemap` 直接链接系统 `sqlite3`。SDK header 版本不能代替运行库版本，实验记录 `sqlite3_libversion()`；最低 macOS 15 的实机验收仍需执行。SQLite 核心为 [public domain](https://sqlite.org/copyright.html)；这不改变 Apple SDK 或商业扩展许可，也不把源码复制到 Munie。

成熟候选 [GRDB v7.12.0](https://github.com/groue/GRDB.swift/tree/92a554cd0d5e8d67cb18993c6054e73fe42c066c) 的固定提交为 `92a554cd0d5e8d67cb18993c6054e73fe42c066c`；[根 LICENSE](https://github.com/groue/GRDB.swift/blob/92a554cd0d5e8d67cb18993c6054e73fe42c066c/LICENSE) 为 MIT、1,062 bytes、SHA-256 `9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87`。其默认 system library 仍使用 OS SQLite，并不固定引擎版本；固定源码的 [WAL setup](https://github.com/groue/GRDB.swift/blob/92a554cd0d5e8d67cb18993c6054e73fe42c066c/GRDB/Core/Database.swift#L534) 使用 NORMAL，不能因采用包装层就推断断电持久性。当前手工处理少量固定 SQL，未采用/复制 GRDB；若演变成迁移框架、连接池或通用数据层，优先重新评估它。

## SQLite 的真实保证

| 官方依据 | 本项目采用 / 限制 |
|---|---|
| [Atomic commit](https://sqlite.org/atomiccommit.html)、[transactions](https://sqlite.org/lang_transaction.html) | 本地修改在短 `BEGIN IMMEDIATE` 事务内完成，成功 COMMIT 后才返回发送资格。本地事务不能同时提交外部 Codex 副作用 |
| [Synchronous](https://sqlite.org/pragma.html#pragma_synchronous) | 选 DELETE rollback journal、EXTRA，额外同步删除 journal 后的目录；没有当前吞吐需求要求 WAL。所有关键 PRAGMA 读回确认 |
| [Fullfsync](https://sqlite.org/pragma.html#pragma_fullfsync)与 [Apple 固定 fcntl 说明](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/fcntl.2#L230) | 启用 fullfsync 请求设备缓存落盘；设备/文件系统仍影响物理断电结果。进程 SIGKILL 不模拟断电 |
| [Autocommit](https://sqlite.org/c3ref/get_autocommit.html)与 [COMMIT 错误](https://sqlite.org/lang_transaction.html) | 检查事务状态、prepare/bind/step/commit 返回码；失败尝试 rollback，无法清理则关闭连接，保留原错误。不能把 SQLITE_BUSY 视为已提交 |
| [WAL 及 WAL-reset bug](https://sqlite.org/wal.html) | 未来改用 WAL 前核对运行库、并发 writer/checkpoint 和 sidecar 备份。官方列出的多连接 race 影响 3.7.0–3.51.2，修复/回移版本见原文；当前 rollback 模式不依赖 WAL |

单 actor 不代替跨进程所有权：私有 canonical 目录、owner/perms/nofollow/inode 检查和非阻塞 owner 锁限定一个 cooperating host。它不声称抵御同 UID 的恶意进程、root、设备失陷或路径在最终检查后被恶意换走。项目授权在接受与领取时复查 canonical path/device/inode，但这不是传给 Codex 的原子目录 capability；真实 adapter 仍必须维持执行沙箱，并另验最终交接期间的路径变化。

## 提交与核对

请求 ID 绑定认证边界提供的设备、主机、固定 Codex/startTextTurn、项目、可选已知 thread 与精确 UTF-8 内容摘要；账本不存正文或凭据。摘要仍属敏感元数据，私有文件不是应用层加密。`AuthenticatedDevice` 在实验中由可信 fixture 直接创建，不是已实现的认证协议。

同 ID 同内容返回原记录；目标或内容冲突拒绝。领取时再次检查设备撤销、项目身份和 thread 归属，并在事务内从 accepted 改为 dispatching；只有成功提交的一次调用得到本地发送资格。此资格是可信 adapter 的 API 返回值，不是可发给客户端的 token，也不防止恶意 adapter 自行重复发送。

重启将 dispatching/running 改为 reconciling：即使尚未真正发送，也不盲目重发。已有 thread/turn 映射保留；只有可信上游的匹配证据才能更新运行/终态。无证据时继续未知；取消请求回执不提供终态。设备撤销拒绝后续读取/领取，包括既有身份对象；已撤销 UUID 不重新启用，未来重新配对使用新身份。撤销不证明先前任务已停机。

Schema 1 绑定单一 host，未知版本/foreign schema 拒绝，SQL 值均绑定，SQL 错误只公开 code。32 KiB 文本、10,000 请求和 64 MiB 主数据库为本轮内部资源上限；满额拒绝，不删除去重记录来腾空间。journal 的短暂额外空间单独受文件检查限制。只为合成数据使用；真实持久任务前仍需保留/导出/删除、备份恢复、版本迁移及灾后身份/去重语义，不能将删除账本作为恢复步骤。

## 故障实验与参考实现边界

[实际 Swift executable](../apps/MunieHost/Probe/MunieSubmissionProbe.swift)通过 pipe 屏障停在未提交更新、accepted commit 后、dispatching commit 后、模拟副作用后、映射后，以及终态。Python driver 核对 owner 锁仍持有，再对进程组 SIGKILL；重启同一账本重试两次，检查状态和逐条追加的副作用计数。未提交更新回滚、尚未领取的 accepted 可安全执行一次；已经领取而结果未知的请求保持 reconciling。fixture 上游的独立证据可用于核对已发生的单次副作用，不再执行一次。输入/效果均为合成内容，没有真实 Codex、网络或模型调用。

既有 pin 的 [Remodex replay buffer](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/phodex-bridge/src/secure-transport.js#L33)是有界内存队列与每进程 epoch；[恢复](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/phodex-bridge/src/secure-transport.js#L425)处理游标/gap，[入站 counter](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/phodex-bridge/src/secure-transport.js#L481)防当前会话密文重放，最后仍单独[转发 Codex](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/phodex-bridge/src/bridge.js#L1470)。[展示去重](https://github.com/Emanuele-web04/remodex/blob/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d/CodexMobile/CodexMobile/Services/AssistantReplayDeduper.swift#L13)也不等于执行去重。上述仅为固定源码只读研究，不构成 exactly-once 证明；本项目没有复制其实现。
