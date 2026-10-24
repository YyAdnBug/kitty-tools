# Kitty Tools Windows 版：第五版（和 Mac 互通的同步）

2026-10-24 写。第四版做完接着做（全程自主，流程和自查清单见 `AGENTS.md`），做完是 **0.5.0**，然后写「全部完成报告」。

**目标**：Windows 版加入 mac 版（0.7.0 起）的「全局同步」，和 Mac 用同一个同步文件夹（用户放在 OneDrive、Dropbox、iCloud for Windows 之类的同步盘里），互通四类数据：

| 类别（文件名） | 内容 |
|---|---|
| `clips.json` | 片段、文字的收藏、收藏夹（图片和文件的收藏不同步） |
| `vocabulary.json` | 生词本（收藏的翻译） |
| `engines.json` | 网页搜索与快捷链接 |
| `services.json` | 翻译服务列表（**密钥不同步**，每台自己填） |

mac 还有 `settings.json`（设置与快捷键）、`launcher.json`（启动器收藏）、`statuses.json`（状态屏的状态）和便签：两边的含义不一样或者 Windows 没有这个功能，**Windows 不读、不写这几样**。

## 0. 安全规矩（这一版最重要的部分）

同步文件夹里放着用户在 Mac 上的真实数据。Windows 版写坏一个文件、删错一条，Mac 那边也会跟着丢。所以：

1. **只写自己的子文件夹** `devices/<本机编号>/`。别的电脑的子文件夹、`images/`、便签文件，一个字节都不碰（不写、不删、不改名）。唯一的例外是在**空文件夹**里第一次开同步时写一个标记文件（§2.1）。
2. **读得严**：文件写坏了、格式更新了、编号重复、钟写坏了，都当「读不出来」，照 mac 的规矩跳过那一版或者整类停下（§2.3）。宁可不合，不可合错。
3. **刹车照 mac**：一轮要删本机没删的条目超过 20 条，或者（至少 5 条时）超过三成，就停下来问用户（§4）。
4. **编码一个字节都不能差**：Windows 编出来的 JSON 和 Swift 的不一样，两边就会互相当成对方改过，没完没了地来回改（§2.4）。以 `KittyTools.Tests/Fixtures/sync-golden.json` 为准。
5. **测试只用临时文件夹**：agent 永远不把同步指向用户真实的同步盘。和真 Mac 一起测是用户最后的手测（`HANDTEST.md`）。
6. **看不懂的就不动**：mac 以后升级了格式（读到更大的 `format`），这一类整轮不合，设置页写「同步文件夹是新版本写的，请更新 Kitty Tools」。

## 1. 要读的 mac 源码（全部只当规格读）

| 内容 | 文件（`macos/KittyTools/` 下） | 单测（`macos/KittyToolsTests/` 下） |
|---|---|---|
| 一条一条的合并规则、文件格式、读写校验 | `Storage/SyncRecords.swift`（**整份照搬成 Core 里的纯函数**） | `SyncRecordsTests.swift`、`SyncRecordsFuzzTests.swift` |
| 账本、`SyncSource` 协议 | `Storage/SyncLedger.swift` | — |
| 版本钟的比法和写法 | `Notes/NoteSync.swift` 的 `precedes` / `joined` / `text(of:)` / `clock(text:)` | — |
| 文件夹结构、标记、`device.json`、上限、刹车、「是不是那个文件夹」 | `Notes/NoteSyncFolder.swift` | — |
| 读写文件夹（云盘还没下载的文件、大小上限、原子写） | `Notes/NoteSyncDisk.swift` | — |
| 执行层：什么时候合一轮、一轮怎么走、状态、停下的原因 | `Notes/NoteSyncer.swift`（只取非便签的那部分） | — |
| 四类数据各自的内容、第一次合时的去重、落地规则 | `Clipboard/ClipboardStore.swift`（`extension ClipboardStore: SyncSource`）、`Translate/HistoryStore.swift`（同）、`Launcher/WebSearchSync.swift`、`Translate/TranslateServiceSync.swift` | `SyncRecordsTests.swift` 里接仓库的那几个 |
| 设置页的样子和说法 | `Settings/SyncSection.swift` | — |
| 拍板和每批摘要 | `macos/PLAN.md` §10「全局同步」 | — |

## 2. 格式（必须和 mac 一字不差）

### 2.1 文件夹

```
<用户选的文件夹>/
  kitty-notes-sync.json            标记：{"format":1,"kind":"kitty-notes-sync","library":"<库编号>"}
  devices/<电脑编号>/device.json     {"epoch":<第几轮>,"format":1,"name":"<电脑名>"}
  devices/<电脑编号>/clips.json      （以及 vocabulary / engines / services）
  devices/<Mac 的编号>/notes/…       便签：Windows 不碰
  images/…                          便签的图片：Windows 不碰
```

- 标记和 `device.json` 不参与哈希，mac 写的是带缩进、键排好序的 JSON（`NoteSyncFolder.encoder`）；读的时候按字段名取，Windows 写的时候也用缩进 + 键排序，不要求逐字节一样。
- **库编号、电脑编号**：都是大写、带连字符的 UUID（和 Swift 的 `UUID().uuidString` 一样）。
  - 本机的电脑编号存在 `kitty.sqlite3` 的一张小表里，同时记下这台机器的 `MachineGuid`（`HKLM\SOFTWARE\Microsoft\Cryptography`）。数据目录被拷到另一台电脑上时 `MachineGuid` 对不上，就换一个新编号（同 mac 按硬件编号判断）。
  - 编号只能是字母、数字和减号，1–64 个字符（mac `NoteSyncDisk.isDeviceName`）。
- **开同步时**（照 mac `NoteSyncer` 的 enable）：
  - 有标记、读得出来：记下它的库编号，加入；
  - 没有标记，但已经有 `devices/` 子文件夹：**不开**，提示「这个文件夹里已经有别的东西了」（新写一个标记会把别的电脑全挡在外面）；
  - 文件夹是空的：新建标记（新的库编号），开；
  - 文件夹不空、又不是同步文件夹：不开，提示「请新建一个空文件夹来同步」。
- **`device.json`** 的 `name` 用电脑名（`Environment.MachineName`），`epoch` 照 mac：每一轮要写文件之前先在本机 +1，`device.json` 最后写。下一轮发现文件夹里记的 `epoch` 比本机记的大，说明本机的库被退回去了（从备份恢复过）：先换一个新电脑编号，再接着合（同 mac「认出库被退回去了」）。

### 2.2 一类数据的文件

照 `SyncRecords.data(of:kind:)` 和 `file(from:kind:)`：

```json
{"erased":[{"clock":"WIN-ID:4","id":"…"}],"format":1,"kind":"clips","records":[{"clock":"MAC-ID:2,WIN-ID:1","id":"…","modified":1761300000123,"value":"{\"favorite\":true,…}"}]}
```

- 顶层和每一条的键都按字母排好；`records`、`erased` 都按 `id` 排（用序数比较，全是 ASCII，和 Swift 的结果一样）。
- `value` 是那一条内容的 JSON **文本**（字符串），原样存、原样比，合并时不解开。
- 版本钟写成 `编号:次数`，按编号排、逗号隔开，空钟是空串（`NoteSync.text(of:)`）。
- **读的时候从严**（照 `file(from:)`，任何一条不合格就整份算读不出来）：
  - 编号长度 1–256、没有控制字符、不重复；
  - 钟的每一格都读得出来，不超过 1024 格、64 KB；
  - `modified` 在 0 到 2^53 之间；
  - `kind` 对得上；
  - `format` 比 1 大、结构又对得上的，算「更新版本写的」（`newer`）。
- 文件先看大小再读，超过 32 MB 不读（mac `NoteSyncDisk.maxErasedBytes`）。

### 2.3 读不出来、云盘还没下载怎么办（照 mac）

- 别的电脑的某一类文件读不出来：只扔这一版，这一类照合（不然一台不用了的电脑留下一个坏文件，就永远合不了）。
- 读到 `newer`：这一类整轮不合，状态写「同步文件夹是新版本写的，请更新」。
- 标记、本机自己的 `device.json` 读不出来：整轮不合，状态写「正在等文件下载」。
- **云盘占位文件**：文件属性带 `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` 或 `FILE_ATTRIBUTE_OFFLINE` 的，说明还没下载到本机。这一轮当它「还没到」，不去读（读会触发下载、卡住线程）。同 mac 的 `notHere`。
- **写文件**：先写同一个文件夹里的临时文件，再 `File.Replace` / `File.Move` 换上去。不留半截文件，也不先删后写。

### 2.4 每条内容怎么编（`value`）

**编码规矩**（Swift `JSONEncoder` 带 `.sortedKeys` + `.withoutEscapingSlashes` 的行为，`sync-golden.json` 里有 40 个样本印证）：

- 键按字母排；**值是空（nil）的键整个不写**（不写 `"note":null`）；
- 字符串里只转义 `"`、`\` 和控制字符：`\b` `\f` `\n` `\r` `\t` 用短写法，其余 U+0000–U+001F 写成 `\u00XX`（小写十六进制）；
- **不转义**：`/`、`<`、`>`、`&`、`'`、U+007F、所有非 ASCII（中文、emoji、U+2028、BOM 都原样写成 UTF-8）；
- 不做 Unicode 规范化（「é」的两种写法各是各的）；
- 整数原样写；布尔是 `true` / `false`；没有多余的空格和换行。

用 `System.Text.Json` 的默认设置做不到这些（它会转义 `<>&'` 和非 ASCII）。**自己写一个小的 JSON 写出器**（Core 里，几十行），单测逐个跑 `sync-golden.json` 里的样本：`clip`、`word`、`group`、`engine`、`order` 比 `json` 和 `hash`，`clock` 比 `text`，`file` 比整份文件。

**哈希**：内容的 UTF-8 字节做 SHA-256，取前 16 字节，小写十六进制（32 个字符）。

**四类的内容**（字段名、类型都照 mac，下面按字母序列出）：

| 类别 | 编号 | 内容 |
|---|---|---|
| clips：一条片段 / 收藏 | 条目的 UUID（大写） | `favorite`（布尔）、`group`（收藏夹编号，可空）、`note`（可空）、`snippet`（布尔）、`text` |
| clips：一个收藏夹 | `group:` + 收藏夹的 UUID | `created`（毫秒）、`name` |
| clips：收藏夹的顺序 | `~order` | 收藏夹编号的数组 |
| vocabulary：一个生词 | 这条翻译的 UUID | `created`（毫秒）、`result`、`service`（服务编号）、`source`、`target`（语言代码，见 `PLAN-v3.md` §1.5） |
| engines：一个搜索 | 预设的编号或自建的编号 | `fallback`、`keyword`、`name`、`url` |
| engines：顺序 | `~order` | 编号数组 |
| services：一个服务 | 服务编号 | mac `TranslateService` 的全部字段：`aiProtocol`（可空：openai / azure / anthropic）、`baseURL`（可空）、`id`、`isEnabled`、`kind`（zhipu / baidu / youdao / google / deepl / microsoft / volcengine / tencent / ai）、`model`（可空）、`name`、`region`（可空）、`usesDeepLX`（可空） |
| services：顺序 | `~order` | 编号数组 |

- **不同步的**：带 NUL 字符的正文、备注（同 mac）；clips 只同步文字条目里「留下的」（收藏或片段）。
- **`decodeExact`**：解开一条内容后再编回去，要和原来的字节一样，才算解得开。不一样（比如 mac 更新后多了 Windows 不认识的字段），这一类就停在「没存上」，等更新，**不能落地**——落下去再发出去，就把 mac 多出来的字段删了。
- **翻译服务的 Windows 专有设置**：如果 Windows 的服务配置里有 mac 没有的字段，那些字段只存在本机，不进 `value`。

## 3. 合并引擎（第 1 批）

- 把 `SyncRecords.round(...)` **逐行**照搬成 Core 里的纯函数，连同 `Join.union` / `Join.adopt`（Windows 只用 `union`）、`orderID`、`arranged`、`decodeExact`、`buried`、`standing`。文件头注释里写的每一条（本机改了什么靠账本比、合的规则、墓碑、账本被退回去、第一次合、执行层必须守住的）都要在代码注释里保留。
- 单测：
  - `SyncRecordsTests.swift` 的 17 个用例全部移植，期望值原样；
  - 随机测试移植 `SyncRecordsFuzzTests.swift`：三台随机加改删合、读到旧文件、钟快慢、退回、丢账本，每一步查「三台最终收敛到同样的内容」；默认 20 个种子随全量单测跑，环境变量 `KITTY_SYNC_FUZZ=2000` 时跑 2000 个；
  - `sync-golden.json` 的全部样本。
- 测试工程里加 `<None Include="Fixtures\**" CopyToOutputDirectory="PreserveNewest" />`。

## 4. 接入四类数据和执行层（第 2、3 批）

### 4.1 账本（照 `SyncLedger.swift`）

- clips、vocabulary 的账本放 `kitty.sqlite3` 的新表 `sync_ledger(kind TEXT PRIMARY KEY, library TEXT NOT NULL, ledger TEXT NOT NULL)`（逐版本迁移加），**和落地的数据在同一个事务里提交**。
- engines、services 存在 `settings.json`：账本存在旁边的 `sync-ledger.json`，先写设置、紧接着写账本（两个都用「临时文件 + 替换」）。
- 账本记着是哪个库的：换了同步文件夹就当第一次合。关掉某一类时不清它的账本（清了等于重新加入，关着的时候本机改的会被盖回去）。
- 每日备份（第三版第 1 批）整张带上 `sync_ledger`。

### 4.2 四类的落地规则（照 mac 各自的 `applySync`）

- **clips**：
  - 别处不再留着的条目，本机只取消收藏、移出片段和收藏夹，不直接删行（还在历史里，按保留天数清理）；
  - 新来的条目和本机历史里同样正文的普通条目合成一条；
  - 剪贴板面板里有还能撤销的删除时，这一类这一轮先不合（`syncBusy`）；
  - 收藏夹的顺序按 `~order` 排。
- **vocabulary**：别处不再收藏的，本机取消收藏（还在历史里）；「原文 + 目标语言」和本机另一条收藏撞上时，**编号小的留下**（几台挑出来的一样）。
- **engines**：改了的换掉、新来的加上、别处删了的拿掉，按 `~order` 排；有一条解不出来就整类不落。
- **services**：
  - 同 engines；别处删了的服务从列表拿掉，**凭据管理器里的密钥不删**；
  - 第一次合时，「协议 + 地址 + 模型」一样的自建 AI 服务只留文件夹里那个，本机那个的密钥搬给它（它在本机还没有密钥时）；
  - 别的电脑上来的、本机没填密钥的服务，卡片照常提示「还没填密钥」，不悄悄跳过。

### 4.3 执行层（照 `NoteSyncer.swift`，去掉便签那部分）

- **什么时候合**：开同步的时候一轮，之后每 20 秒一轮，从睡眠唤醒时一轮，设置里点「立即同步」一轮。一轮没完时再要的排在它后面。
- **一轮怎么走**：
  1. 先把本机还没落盘的改动落下去；
  2. 后台线程读文件夹（只读四类文件、标记、各台的 `device.json`）；
  3. 确认是不是那个文件夹（标记、格式、库编号）；
  4. 认出库被退回去了就先换编号；
  5. 每一类：`syncBusy` 时跳过 → 合 → 刹车 → 落地（事务）→ 写自己的文件；
  6. 最后写 `device.json`。

  某一类出了问题只跳过那一类，别的照常。
- **刹车**：一轮里某一类要删掉本机没删的条目超过 20 条，或者（至少 5 条时）超过三成，这一类停下来。轻提示「同步要删掉 N 条，等你确认」，设置页的同步那一节显示同样的话和「继续」按钮；「继续」只放行不超过当时那么多条的删除。本机自己一次删了一大批（`erasing`）时也一样先问，再写出去。
- **状态**（设置页的状态行）：关着 / 正在同步 / 好了（上次同步的时间）/ 停了（文件夹不在、不是那个文件夹、新版本写的、哪台的文件读不出来、读写出错）/ 等你确认。别的电脑列出名字和最后一次看到它的文件变化的时间。

### 4.4 设置页

设置 › 通用加一节「同步」（说法照 mac `Settings/SyncSection.swift`）：

- 选择文件夹（`FolderPicker`）、状态行、四个类别的勾选（默认都勾上）；
- 别的电脑列表、「立即同步」「停止同步」；
- 页脚说明：密钥不同步；设置、快捷键、启动器收藏不在 Windows 和 Mac 之间同步。

每一类跟着各自的功能开关：clips 跟剪贴板，vocabulary 和 services 跟翻译，engines 跟启动器。

## 5. 分批

### 第 1 批：格式和引擎

- §2 的 JSON 写出器、哈希、钟的写法和读法、文件的读写和校验；§3 的引擎和全部单测。
- 验收：`sync-golden.json` 全过；17 个移植用例全过；随机测试 2000 个种子跑一次全过（报告里写耗时）。

### 第 2 批：接入四类数据

- §4.1 账本、§4.2 四类的 `syncValues` / `applySync` / 第一次合的去重；本机的电脑编号和 `MachineGuid`；数据库迁移。
- 验收：在内存里模拟「本机 + 一台假 Mac」——假 Mac 的文件用 §2 的格式写——跑这些场景，每个都有单测：
  - 第一次加入时同样正文不重复；
  - 两边各改一条，后改的赢；
  - 一边删、另一边没改：删掉；
  - 一边删、另一边改了：改的回来；
  - 生词撞车留编号小的；
  - 服务被删了、密钥还在；
  - 读到 `newer` 那一类停下。

### 第 3 批：执行层、设置页、第五版收尾

- §4.3 执行层（20 秒一轮、唤醒、立即同步、刹车、状态、认出库被退回去）、§4.4 设置页、云盘占位文件的处理。
- **集成测试**：两个临时数据目录当两台 Windows，加一个按 §2 格式写文件的「假 Mac」，共用一个临时同步文件夹，跑一串操作，最后三方内容一致；中途把一台的数据目录换成旧备份，验证它会换编号、不把旧内容翻回来；在假 Mac 的子文件夹里放一个写坏的文件，验证只跳过那一版。
- **给用户的真机手测**（写进 `HANDTEST.md`，agent 不做）：Mac（0.7.0 或更新）和 Windows 选同一个同步盘里的空文件夹；两边各加片段、收藏夹、生词、网页搜索、AI 服务，改、删、改顺序，看两边是否一致；拔网线各自改一条再连上，后改的赢；Mac 上的便签和设置不受影响。
- **第五版收尾**：版本号改 0.5.0，更新日志加 0.5.0 的条目，跑 `build-release.ps1`（不发布）；然后写 `AGENTS.md` 文末的「全部完成报告」。
