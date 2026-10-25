# mac 全局同步的源码（只读参考）

`PLAN-v5.md` §1 点名要照搬的 mac 文件。它们属于 mac 0.7.0，写 PLAN-v5 时还只在 Mac 本地的 `main` 上、没推到 `origin`，
Windows 这边拿不到（REVIEW R13）。这里是从 Mac 本地 `main` 的 `09e17f21` 原样拷来的，**只读、不改、不参与构建**。

| 文件 | 原位置 | 看什么 |
|---|---|---|
| `SyncRecords.swift` | `macos/KittyTools/Storage/` | 合并规则（文件头的每一条）、`round`、文件格式、读写校验、`decodeExact` |
| `SyncLedger.swift` | `macos/KittyTools/Storage/` | 账本、`SyncSource` 协议 |
| `NoteSync.swift` | `macos/KittyTools/Notes/` | 版本钟：`precedes` / `joined` / `text(of:)` / `clock(text:)` |
| `NoteSyncFolder.swift` | `macos/KittyTools/Notes/` | 文件夹结构、标记、`device.json`、上限、刹车 |
| `NoteSyncDisk.swift` | `macos/KittyTools/Notes/` | 读写文件夹：云盘没下载的文件、大小上限、原子写 |
| `NoteSyncer.swift` | `macos/KittyTools/Notes/` | 执行层（只看非便签的部分）：什么时候合、一轮怎么走、状态、停下的原因 |
| `ClipboardStore.swift` | `macos/KittyTools/Clipboard/` | 只看文件末尾的 `extension ClipboardStore: SyncSource` |
| `HistoryStore.swift` | `macos/KittyTools/Translate/` | 只看 `extension HistoryStore: SyncSource` |
| `WebSearchSync.swift` | `macos/KittyTools/Launcher/` | 网页搜索与快捷链接 |
| `TranslateServiceSync.swift` | `macos/KittyTools/Translate/` | 翻译服务（第一次合的去重、密钥不进文件） |
| `SyncSection.swift` | `macos/KittyTools/Settings/` | 设置页的样子和说法 |
| `SyncRecordsTests.swift` | `macos/KittyToolsTests/` | 17 个用例，期望值原样移植 |
| `SyncRecordsFuzzTests.swift` | `macos/KittyToolsTests/` | 随机测试，照着移植 |

等 `origin/main` 上有了这些文件，审查方会删掉这个目录。
