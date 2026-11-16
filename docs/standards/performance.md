# 性能与可靠性 / Performance

性能是架构输入。先测量当前行为，定位一处瓶颈，改动后用同样输入复测；数据正确、失败可恢复优先于一份好看的耗时报告。下列数值是 Munie 的初始内部预算，不是 Apple 要求、行业基准或已通过的真机承诺。

## 现在执行的核心存储门禁

```sh
./scripts/benchmark-core.sh
python3 scripts/check-performance.py build/core-performance.json config/performance-budgets.json
```

Release 的 `MunieCoreBenchmark` 通过真实 `FileCaptureStore` 公共 API 测量；每个规模一次生成合成 JSON，避免用反复保存构造数据带来的平方级准备成本。100 / 1,000 条记录，每条固定 248 UTF-8 bytes 的中英合成文本；各运行 3 次预热与 20 次采样。每轮在同一规模读取、保存一条、删除刚保存的记录，计时不含 fixture 生成和校验。保存后与删除后均重新建 store 读取并核对 ID、正文和记录数量；读取还检查排序。预热与测量都必须正确。

| 记录数 | list p95 | save p95 | delete p95 |
|---|---|---|---|
| 100 | ≤100 ms | ≤150 ms | ≤150 ms |
| 1,000 | ≤500 ms | ≤750 ms | ≤750 ms |

这些宽预算在不同 CI 主机上拦截严重退化，不能替代更严格的产品体验预算。保留全部样本，使用 nearest-rank p50 / p95（20 个样本的第 10 / 19 项）；判断基于原始样本重算，不能用伪造的汇总数放行。缺少规模/操作、样本不足、无正确性证据、Debug、NaN/Infinity、无 provenance 或超预算均退出非零。调整预算须说明原因与前后数据，不得仅为消除失败而放宽。

`build/core-performance.raw.json` 保留原始结果；`build/core-performance.json` 增补 Git revision/dirty 状态、核心源码聚合 SHA-256、runner SHA-256、预算与可执行文件 SHA-256、Swift toolchain、CPU 架构、OS/核数和实际 fixture bytes。构建及执行日志为 `build/core-performance-build.log`、`build/core-performance-run.log`。执行最多 180 秒；失败先移除旧报告，保留新失败的输出，避免把上次结果误作本次。宿主机温度、后台负载和文件缓存影响结果，比较时固定机器/toolchain/电源条件；本基准不是冷磁盘、CPU、峰值内存或能耗测试。

## 真机产品准入（待执行）

| 体验 | 初始内部目标与执行条件 | 工具 / 证据 |
|---|---|---|
| 快速拿来用 | 支持范围内最老的可测试 iPhone，Release，无 debugger；20 次冷启动到可编辑输入 p95 ≤1 s，暖启动另记 | XCTest launch metric + 时间标记；设备/OS/电量/温度与原始结果 |
| 即时反馈 | 本地主要动作反馈 p95 ≤100 ms；1,000 条记录时保存完成 p95 ≤300 ms；失败仍保留输入 | UI 事件到实际完成计时，20 次与错误路径 |
| 搜索与输入 | `CaptureModel.filteredRecords` 当前在 MainActor 扫描；1,000 条、短文与 10,000 字上限混合时搜索反馈 p95 ≤100 ms，输入/滚动无丢失或明显卡顿 | Time Profiler / SwiftUI instruments 与录屏；测量正文长度及语言 |
| 内存 | 固定 fixture 完成 100 次记录/搜索/删除循环；静置后 retained memory 不持续线性上升，前后增量 ≤max(10 MB, 10%)；峰值独立记录后定设备预算 | Allocations / Leaks，基线、峰值及结束值，不能用 CLI RSS 推断 app |
| 主线程 | 不在 MainActor 执行同步磁盘/网络或大规模 decode；actor 隔离与 async 声明不代表不存在 UI 阻塞 | Thread Performance Checker、Time Profiler、主线程栈和问题修复复测 |
| 能耗与后台 | 10 分钟静置无项目新增轮询/录音/网络；前后台、锁屏与音频中断分别记录；新增 voice 先 opt-in，Watch 单独测量 | Energy / Power 工具，任务、唤醒、网络/音频活动记录 |

若目标不达标，先确认场景与测量，再优化；不要预先引入缓存、数据库或额外任务调度层。当前文件存储每次全量读写，增长不是无限可扩展；接近预算、需要索引/迁移或多进程写入时，先评估原生存储与成熟组件并记录 ADR。所有目标均须与[平台体验验收](platform-acceptance.md)、数据可靠性和权限控制一起通过。

自有 Mac 上 Codex 远程执行是后续主链路。必须分别记录手机入口→Mac 已接受、已接受→首个真实事件、已接受→完成、取消→停止的延迟及超时/离线比例；保持同一任务 ID，并区分网络、排队、唤醒和执行。模型完成时间受任务影响，不能把一次本地 JSON save 或模拟回复当作远程链路性能。场景、身份与协议确定后再为这些指标设真实端到端预算。

## 官方依据与复核

2026-11-17 核对 Apple 的 [performance improvement cycle](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)、[repeatable performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)、[launch analysis](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) 与 [early diagnosis](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)。Apple 建议结合性能测试、Instruments 与真实使用诊断；本项目自行选择核心 CLI 门禁和上述预算。未来考虑 [MetricKit](https://developer.apple.com/documentation/metrickit) 前，单独评审平台可用性、数据内容、用户控制和隐私；当前不增加遥测或第三方运行时依赖。
