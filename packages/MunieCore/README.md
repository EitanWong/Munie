# MunieCore

Foundation-only domain and local capture persistence for Munie. Swift 6, iOS 18+,
macOS 15+, watchOS 11+, tvOS 18+, visionOS 2+. No third-party runtime dependencies.
The caller must respect platform storage limits; tvOS local files are purgeable.

```swift
let store = FileCaptureStore(fileURL: applicationSupportURL.appendingPathComponent("captures.json"))
let capture = try await store.save(text: "Remember this idea")
let captures = try await store.list()
try await store.delete(id: capture.id)
```

- Share **one store instance per file**. An actor serializes operations within
  one process. This is not a cross-process or multi-device database.
- Save trims edge whitespace; blank text and text above 10,000 Swift `Character`
  values are rejected. Interior whitespace and Unicode are preserved.
- JSON schema version 1 uses Foundation's default date encoding. Writes use
  `Data.write(options: .atomic)`. Read errors, corrupt data and unsupported schema
  versions are surfaced; damaged files are never silently reset.
- `list()` returns newest first, with UUID string order as a deterministic tie
  breaker. Deleting an unknown UUID throws `CaptureError.recordNotFound`.
- File I/O errors propagate to the caller. The caller chooses storage location,
  data protection, retention and user-facing error presentation. JSON is plaintext;
  this package makes no application-level encryption claim.
- This local capture library does not submit or execute AI tasks.

Run `swift test` and `swift run MunieCoreSmoke` from this directory.

## 中文

Munie 的可复用本地记录组件，负责校验、原子写入、重载和删除。每个文件只由一个
`FileCaptureStore` 实例管理；不支持跨进程并发写入。损坏或未知版本的数据会报错，
不会自动覆盖。数据为明文 JSON，保存不代表已发送给 AI。测试命令见上。
