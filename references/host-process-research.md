# Mac 主机进程原语研究

核对日期：2026-11-17。范围为有界本机 Codex 研究，非长期 daemon 选型结论。当前执行结果唯一记录在[项目状态](../docs/project-status.md)，命令与资源限制见[测试](../docs/testing.md#ledger-integrated-native-codex-experiment)。未复制、构建或执行第三方源码，也未新增运行时依赖。

| 来源 | 核实的能力 / 约束 |
|---|---|
| [Apple Process](https://developer.apple.com/documentation/foundation/process)、[Pipe](https://developer.apple.com/documentation/foundation/pipe) | 提供显式 executable/arguments/environment/cwd、进程及标准流；framing、背压、stderr并行消费、deadline与后代清理仍由调用方负责 |
| [terminate](https://developer.apple.com/documentation/foundation/process/terminate())、[waitUntilExit](https://developer.apple.com/documentation/foundation/process/waituntilexit()) | TERM可被忽略；同步wait会阻塞，返回不保证termination handler已完成。exit、EOF、进程组消失是不同观察 |
| [swiftlang/swift-subprocess 1.0.2](https://github.com/swiftlang/swift-subprocess/tree/dbe21bd7dfd4ffef8c32588918542a8abfa1b54c) | 固定提交 `dbe21bd7dfd4ffef8c32588918542a8abfa1b54c`；Swift 6.2、macOS 13；async输入/输出、有界收集/行缓冲、显式环境/cwd、processGroup/session及teardown。不能声称它缺少流式或组信号能力；iOS 99占位不代表可在手机spawn |
| [固定 LICENSE](https://github.com/swiftlang/swift-subprocess/blob/dbe21bd7dfd4ffef8c32588918542a8abfa1b54c/LICENSE) | Apache-2.0，11,357 bytes，SHA-256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`；未采用代码，正式采用时另评传递依赖/notice |

本片保留现有 POSIX actor：它明确拥有 CLOEXEC/nonblocking FD、独立进程组、JSONL与全流/队列上限、取消/超时，以及leader/EOF/group的分离证据。此刻替换底层原语会扩大依赖和验收范围，并不能替代协议与ledger不变量。这是范围取舍，非声称自写比成熟包性能更好。

代价：Darwin-only、自维护FD/PID/error路径、2ms cooperative polling；尚无idle CPU、wakeups或长期能耗实测。进程组不是安全边界，逃逸组/session的后代须由外层OS限制约束。fixture guardian只负责当前实验host死亡窗口，不能直接当产品常驻服务。

长期host或第二个host OS实现前，评估package-backed transport，复用相同malformed/partial/flood、slow reader、并发、取消、leader先退出及ignoredTERM后代夹具；比较内存上限、idle功耗、清理延迟，复核工具链、license与传递依赖，再决定替换。此次只读源码比较未执行等效性能测试。
