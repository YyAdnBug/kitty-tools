# Kitty Tools Windows 版：第二十五版方案（启动器搜不到文件）

2026-11-23。外部用户反馈：「我用 Windows 搜索文件，搜不到文件，我也不清楚我的 Windows 是不是设置了搜索文件的什么配置。
是不是自己做一套索引，或者借用 Everything 等工具会好点。」说的是启动器里的文件搜索（`open 词` / `find 词` / 空格开头）。

**拍板：2026-11-23 用户「可以，就按推荐来，做完了我用 windows 测试一下」**，§4 F1–F16 全部按推荐。拍板页：https://claude.ai/artifact/BKs4h3CJ4C7QFbnVkt7SKE （附给反馈人的回复稿，只起草没发）。

**分工（拍板时改了）**：用户要做完直接在 Windows 上测，所以 §5 三批**审查方在 Mac 上全写了**（Core 纯函数 + 单测、COM、服务、窗口消息、启动器、设置页、自检），
**都没编译**。Windows 这边编译、跑单测、照 `REVIEW.md`「PLAN-v25」的交接先核对几处（vtable 序号、Everything 的项标志），再在真机上测；
编不过、对不上直接改，交接里写一句改了什么。手测 `HANDTEST.md` 1800–1829（1778–1799 留给 PLAN-v24 跨屏框选，那条分支已经用到 1777）。

## 1. 现在怎么搜的（`windows` = `563a9c3b`）

- **触发**：只有 `open 词`、`find 词`、空格开头才搜文件（`Core/LauncherCommands.cs` `Classify`）；直接输文件名只搜应用、设置、书签，
  没有本地结果时出网页搜索兜底，**不会出文件**。同 mac（mac 也要前缀，对标 Alfred）。
- **范围**：写死七个根 `%USERPROFILE%\Desktop`、`Documents`、`Downloads`、`Pictures`、`Videos`、`Music`、`OneDrive`
  （`Launcher/LookupServices.cs:30–36`），拼成 `SCOPE='file:C:/Users/…/Desktop' OR …`（`Core/FileSearchSql.cs:65`）。
  用的是 `%USERPROFILE%` 下的固定名字，不是已知文件夹的真实位置：**桌面 / 文档挪到 D 盘的，这一个根直接没了**（`Directory.Exists` 不过就跳过）。
- **怎么查**：OLE DB 直连 `Search.CollatorDSO` 查 `SYSTEMINDEX`（`Launcher/OleDbFileSearch.cs`），
  每个词一个 `System.FileName LIKE '%词%'`（子串、不分大小写），`SELECT TOP 100 … ORDER BY System.DateModified DESC`，
  再用 `LauncherCommands.ScoreFileName`（开头命中 100 分、包含 40 分、名字越短越前）排、取前 20 条（`LookupServices.cs:163`）。
- **上限 / 超时**：SQL 只取**最近修改的 100 条**再按名字排——词常见时（「报告」「2024」「合同」），名字最像的那个文件只要不在最新的 100 条里就排不进来。
  OLE DB 本身没有超时（查询在毫秒级）。
- **索引服务关着时**：OLE DB 返回 null → 走 WinRT `StorageFolder` 查询（`OnlyUseIndexer`，每个根 900 ms）→ 抛异常才扫目录。
  扫目录这段**实际上搜不到东西**（`LookupServices.cs:131–151`、`218–270`）：
  - `Walk` 不是边走边返回，而是把这个根下 6 层**全部走完**才返回（6000 个的上限只截断当前文件夹的文件，目录照样一层层往下推，之后每个文件夹还要再加一个）；
  - 调用方在拿到结果**之后**才看「300 ms、2000 个候选」——第一个根（桌面）只要超过 2000 个文件，或者走了超过 300 ms，一条都不比就 break；
    后面每个根同样先全部走完、再立刻 break。结果：服务关着时最多只比到桌面，多数机器上是**零条**，而且要等好几秒。
  - WinRT 那条路在服务关着时会不会抛异常没验过（STATUS「索引服务被关掉时的 WinRT / 扫目录退路只有代码路径，没在真机停过服务验证」）：
    要是不抛、只返回空，连扫目录都不会走。
- **索引在、但位置没进索引时**：OLE DB 正常返回 0 行，**不退路、不提示**。PLAN-v6 第 4 批第 7 条写了「某个根不在索引里，才退回扫目录…结果后面标（没有索引）」，没做。
- **给用户的提示**：只有设置 › 启动器 ›「文件搜索」一张「建了索引的位置」卡（打开 `ms-settings:cortana-windowssearch`）和一句脚注
  「搜的是 Windows 搜索建了索引的位置」——**这句话不对**：用户把 D 盘加进索引、或者打开「增强」模式，我们照样搜不到 D 盘（只查七个根）。
  启动器里搜不到时只写「没有匹配的文件」。
- **顺手看到的**：`OleDbFileSearch.ReleaseRows`（`:366`）把 `&rows`（本地变量的地址）当 HROW 数组传，应当传 `rows`；读的是栈上的几百字节、放的是错的句柄，
  到 rowset 释放时才一起放掉。没出过事，一起修（R114 第 7 条）。

**mac 对照**（`macos/KittyTools/Launcher/FileSearch.swift`）：Spotlight 查**整个主目录**（`~/Library` 除外），词首匹配，
拿到最多 2 万条再按匹配分 × 使用加成排、列 50 条；去掉 `node_modules`、`build` 这类目录；授权不够时结果最后一行出提示，↩ 去授权。
Windows 少了：整个范围、足够多的候选、最后一行的提示。

## 2. 用户搜不到，可能是哪几种（按可能性排）

| # | 原因 | 用户怎么自己确认 |
|---|---|---|
| 1 | **文件不在那七个文件夹里**（D、E 盘；`C:\Users\名字\` 下自己建的文件夹；桌面 / 文档挪到了 D 盘；`OneDrive - 公司名`）。这是**我们代码的范围**，和 Windows 设置无关：把 D 盘加进索引、开「增强」也搜不到。国内用户习惯把文件放 D 盘，最可能是这条。 | 资源管理器里右键那个文件 › 属性，看「位置」是不是 `C:\Users\你的名字\` 下的 桌面 / 文档 / 下载 / 图片 / 视频 / 音乐 / OneDrive |
| 2 | **没加前缀**：直接输文件名只搜应用，不搜文件。 | 在启动器里先打一个空格再输文件名（或 `open 文件名`），看能不能出来 |
| 3 | **Windows Search 服务被关了**（一些系统优化、清理类软件会把它设成「禁用」来「提速」）。这时我们的退路是坏的（§1），基本是零条。 | Win + R 输 `services.msc`，找「Windows Search」：状态应该是「正在运行」，启动类型「自动（延迟启动）」；或者任务管理器 › 服务 里找 `WSearch` |
| 4 | **索引没建完 / 暂停了 / 坏了**：刚装系统、刚重建索引（几十万个文件要几小时）、笔记本用电池时暂停、索引数据库坏了。 | Win11：设置 › 隐私和安全性 › 搜索 Windows，看「索引状态」（已编入索引的项数、还剩多少）；Win10：设置 › 搜索 › 搜索 Windows。按 Win 键直接输同一个文件名，系统自己的搜索也搜不到 = 索引的问题 |
| 5 | **位置没进索引**：经典模式默认只收「开始菜单」和「用户」文件夹（`C:\Users`）；用户在「索引选项」里去掉过某个文件夹。（目前只影响七个根里被去掉的；§4 F1 放开范围后，没进索引的 D 盘也算这一条） | 搜索 Windows 页里「查找我的文件」是「经典」还是「增强」；点「高级索引选项」›「修改」，看勾了哪些位置 |
| 6 | **词太常见**：先取最近修改的 100 条再按名字排，老文件排不进来（§1）。 | 换一个更完整、更特别的文件名再搜，能出来 = 这一条 |
| 7 | **用拼音 / 首字母搜中文文件名**：应用名能拼音，文件名不行（索引里没有拼音）。mac 的 Spotlight 能。 | 改用汉字搜 |
| 8 | 网络盘、移动硬盘：Windows 搜索默认不收网络位置；移动硬盘要手动加。 | 看文件所在的盘 |
| 9 | 那种扩展名在「索引选项 › 高级 › 文件类型」里被取消勾选（少见，默认每种都至少收文件名）。 | 同上看文件类型那一页 |

## 3. 同类怎么做（公开资料和源码，2026-11-23 查的，没在真机上逐个试）

| 产品 | 默认用什么 | Everything | 没索引 / 服务关着时 |
|---|---|---|---|
| PowerToys Run「Windows 搜索」插件 | 系统索引，动作词 `?`；只按文件名、按修改时间排 | 官方不带；社区插件 EverythingPowerToys 带 SDK 的 DLL（`Everything2_x64.dll`），要用户自己装好 Everything 并运行着 | 多块盘、又不是增强模式时出一条「驱动器检测」提示（读 `HKLM\SOFTWARE\Microsoft\Windows Search\Gather\Windows\SystemIndex` 的 `EnableFindMyFiles`），点了打开 `ms-settings:cortana-windowssearch`，能在设置里关掉这条提示；服务出错时不提示（看代码推的） |
| PowerToys 命令面板（CmdPal） | 系统索引；根搜索里有一行「在文件里找」的兜底；查询是 `CONTAINS(System.ItemNameDisplay…) OR System.FileName LIKE …` | 不带 | 读索引目录的状态，出一条说明 + 「打开索引设置」（`ms-settings:search`） |
| Flow Launcher（Explorer 插件） | 三处都默认 Windows Index；范围是整个索引（`scope='file:'`），文件结果进全局搜索（看设置的默认值推的） | 可选；带 SDK 的 `Everything.dll`（P/Invoke），选了 Everything 但没运行时提示「Everything service is not running」+「点这里启动或安装 Everything」，可以替用户下载安装；1.5 单独一个开关 | 服务没开时提示一行「Windows Index Search 需要的服务好像没在运行」，点了只是关掉这条提示；之后静默返回空 |
| Wox 2.x | 自己的本地索引（用户指定一小串根目录） | 未见 | 可选装「NTFS 服务」读 MFT 和 USN 日志，**要管理员** |
| Listary | 自己的磁盘索引，默认收所有本地 NTFS 分区，实时跟文件变化 | 不用 | 非 NTFS 要手动加 |
| uTools、Raycast for Windows | 官网文档没写怎么做的（未确认） | — | — |

**Everything 本身**（voidtools 官网和 SDK 仓库）：

- 必须装好并在后台运行；查询只能本机。IPC 有三种：窗口消息 `WM_COPYDATA`（1.4 起）、命名管道（1.5 的 SDK3）、ETP / HTTP（HTTP「默认关」）。`es.exe` 要另外下载。
- **协议是公开的**：SDK 的 `everything_ipc.h` 随 SDK 发；1.5 的 SDK3 在 GitHub `voidtools/everything_sdk3`，**MIT**。1.4 SDK zip 里的许可没读到
  （下载包没打开），所以**不带它的 DLL、不抄它的源码**，只照协议自己发消息（常量和结构布局是协议本身）。
- 1.5 在 2026-05 进了 beta（论坛更新日志 1412b），还在出新版（1424b，10 月）；1.5 alpha 跑在名叫 `1.5a` 的实例里，窗口类名后面多 `_(1.5a)`。
  1.5 的 SDK3 说「之前版本的 SDK 和 1.5 兼容」，第三方的 Rust 实现也说窗口消息那条路在 1.5 上能用——**都没在真机上验**，第 3 批核验。
- 窗口消息协议（照 SDK 的结构，第三方 MIT 实现 `everything-ipc` 交叉核对过）：
  - 找窗口：类名 `EVERYTHING_TASKBAR_NOTIFICATION`（1.5 alpha：`EVERYTHING_TASKBAR_NOTIFICATION_(1.5a)`）。
  - 版本 / 数据库：`SendMessage(窗口, WM_USER, 命令, 0)`，命令 0–3 = 主 / 次 / 修订 / 构建号，401 = 数据库载完没有（1 = 载完；没载完时查询看起来就是零条）。
  - 查询：`WM_COPYDATA`，`dwData = 18`（`EVERYTHING_IPC_COPYDATA_QUERY2W`），数据 = 7 个 DWORD（`reply_hwnd`、`reply_copydata_message`、`search_flags`、
    `offset`、`max_results`、`request_flags`、`sort_type`）+ UTF-16 查询串 + NUL。`search_flags` 0x1 区分大小写、0x2 全词、0x4 匹配路径、0x8 正则；
    `request_flags` 0x1 文件名、0x2 路径、0x40 修改时间；`sort_type` 14 = 修改时间从新到旧。
  - 回包：Everything 往 `reply_hwnd` 发 `WM_COPYDATA`（`dwData` = 我们给的 `reply_copydata_message`）：头 5 个 DWORD（`totitems`、`numitems`、`offset`、
    `request_flags`、`sort_type`），接 `numitems` 个 8 字节的项（`flags`、`data_offset`，偏移从整个缓冲区开头算），每项的数据按请求位的固定顺序排：
    字符串是 DWORD 长度 + 那么多个 UTF-16 + NUL，日期是 8 字节 FILETIME。项的 `flags` 0x1 = 文件夹（**照 SDK 头文件核对**，第三方实现没写）。

**自己建索引**（C）的代价：读 MFT / USN 日志要打开卷句柄，**要管理员**——得装一个常驻的提权服务（Wox、Listary、Everything 都是这么做的），
安装程序、升级、卸载、安全面全跟着变；不提权就只能递归遍历：一块装满的盘几十万到上百万个条目，冷缓存要几十秒到几分钟、内存几十到上百 MB，
还要 `ReadDirectoryChangesW` 一个个根盯着变化（或定时重扫），笔记本上费电。Everything 已经把这件事做到了极致、而且免费，
愿意要全盘文件名搜索的用户多半已经装了它。

## 4. 拍板题（带推荐）

| # | 问题 | 推荐 |
|---|---|---|
| F1 | 走哪几条路 | **A + B**：A = 继续用系统索引，把范围、上限、退路修好，补诊断提示；B = 检测到 Everything 在运行就用它。**C（自建索引）不做**（F14）。理由：一般用户默认开着 Windows 搜索、文件多在用户文件夹里，A 修好就能搜到；文件在 D 盘、又不想动索引设置的，装了 Everything 的人能直接用上；自建索引的代价见 §3。 |
| F2 | 搜索范围 | **整个系统索引**（`SCOPE='file:'`，不再只查七个根），去掉 F3 那些路径。和设置页那句「搜的是 Windows 搜索建了索引的位置」对上；用户加进索引的 D 盘、开了增强模式的整台电脑都能搜到。同 Flow Launcher、mac（整个主目录）。 |
| F3 | 去掉哪些路径 | 路径里有 `AppData`、`$Recycle.Bin`、`System Volume Information`，系统盘根下的 `Windows`、`ProgramData`，任何盘根下的 `Program Files`、`Program Files (x86)`，以点开头的文件夹（`.git` 这类），和 mac 那一串（`node_modules`、`bower_components`、`DerivedData`、`build`、`dist`、`target`、`out`、`Pods`、`Carthage`、`vendor`、`venv`、`__pycache__`、`coverage`）。开始菜单里的快捷方式在 `ProgramData` / `AppData` 下，一起去掉（应用本来就在启动器里）。索引和 Everything 两条路共用一份（`Core/FileSearchFilter.IsExcluded`）。 |
| F4 | 先取多少条再排 | **500 条**（现在 100）。量：整个索引范围下 `--file-search=jpg`、`报告`、一个只有一两个文件的生僻词各跑 5 次，P50 < 150 ms 就定 500；超了降到 300，再超就把 SQL 换成 CmdPal 那种 `CONTAINS(…"词*") OR LIKE`，数写进交接。Everything 那条也取 500。 |
| F5 | 已知文件夹的真实位置 | **用 `SHGetKnownFolderPath`**（桌面、文档、下载、图片、视频、音乐）+ 环境变量 `OneDrive`、`OneDriveConsumer`、`OneDriveCommercial`，不再拼 `%USERPROFILE%\Desktop`。F6、F8 和 F9 的提示都用它。 |
| F6 | 索引服务关着时怎么退 | **扫上面那几个已知文件夹，边扫边比**：`Directory.EnumerateFileSystemEntries` + `EnumerationOptions`（递归、最多 8 层、跳过隐藏 / 系统 / 重解析点、忽略没权限的），F3 的目录不进；总共 1 秒、5 万个条目、找到 200 条就停，每个文件夹一个 `CancellationToken` 的检查。WinRT 那条路删掉（PLAN-v6 第 4 批本来就说删）。结果最后一行写「没走索引，只找了桌面、文档这几个文件夹」（F9）。 |
| F7 | 位置没进索引时 | **已知文件夹里没进索引的**（典型：桌面挪到了 `D:\桌面`、没加进索引）：照 F6 扫它、和索引的结果并起来。**别的盘**（D、E 整个盘）不扫（每打一个字扫一整块盘不现实），只出 F9 的提示。 |
| F8 | 怎么知道「没进索引 / 服务关着 / 正在建」 | 服务：`OpenSCManager` + `OpenService("WSearch")` 读状态和启动类型（普通用户能读；没有这个服务的系统当关着）。索引：`ISearchManager` → `GetCatalog("SystemIndex")` → `GetCatalogStatus`（空闲 / 暂停 + 原因 / 正在全量建 / 恢复中）、`NumberOfItemsToIndex`；`GetCrawlScopeManager` → `IncludedInCrawlScope`（每个已知文件夹、每块本地固定盘的根；根不在但 `HasChildScopeRule` 有，算「部分在」，不提示）。增强模式另读 `EnableFindMyFiles` 当旁证。打开启动器时在线程池里查一次、缓存 60 秒，不在打字时查。 |
| F9 | 提示放哪、什么时候出 | **文件结果的最后一行**（同 mac 的授权提示，一行 Prompt），按优先级只出一条：① 服务没开（一直出）：「Windows 搜索服务没开，只找了桌面、文档这几个文件夹」，↩ 见 F10；② 正在建 / 暂停（一直出）：「Windows 还在建索引（还剩约 N 项），结果可能不全」/「索引暂停了（用电池或正在忙）」，↩ 打开搜索设置；③ 有本地盘或已知文件夹不在索引里，**结果少于 5 条时才出**：「D:、E: 不在 Windows 搜索的索引里，里面的文件搜不到」，↩ 打开 `ms-settings:cortana-windowssearch`（那一页有「增强」和「高级索引选项」）。用着 Everything 时②③不出。结果多的时候不出③：用户故意不收 D 盘的，不该每次都看到它。 |
| F10 | 服务关着时 ↩ 做什么 | **↩ 启用 Windows 搜索（要管理员确认）**：以管理员身份跑 `sc.exe config WSearch start= delayed-auto` 和 `sc.exe start WSearch`（系统弹 UAC，用户点「是」才改；点「否」什么都不变，提示行照旧），成功后清掉 F8 的缓存重查一次。Ctrl+K 里另有「打开服务管理器」（`services.msc`）。不偷偷改：只在用户按 ↩ 时做，提示里写明要管理员确认。 |
| F11 | Everything 默认用不用 | **自动**：设置 › 启动器 › 文件搜索 一个开关「装了 Everything 并且它在运行时用它搜」，默认开；检测不到（没装、没运行、数据库没载完、查询 1.5 秒没回包）时静默用系统索引。开关跟着设置导出导入（Windows 自己的键，mac 不认）。 |
| F12 | Everything 怎么接 | **自己按它公开的窗口消息协议发 `WM_COPYDATA`**（§3），不带 SDK 的 DLL（硬规矩：不加第三方依赖；1.4 SDK 的许可也没读到）、不调 `es.exe`（要另外下载，每次起进程）、不用 HTTP（默认关、明文）。回包收在现成的 `HiddenWindow`（UI 线程本来就在转消息）。1.5：先试同一套窗口消息（两个类名都找）；1.5 真不回窗口消息，就当没在运行、退回系统索引、日志记一句，命名管道（SDK3，MIT）以后单独一版。 |
| F13 | 没装 Everything 时提不提它 | **只在设置页脚注提一句**（「装了 Everything 并且它在运行时，改用它搜：所有本地硬盘、更快」），启动器里的提示行不提、不替用户下载安装（Flow Launcher 会装，我们不装任何东西）。 |
| F14 | 自建索引 | **不做**。代价见 §3：提权服务或常驻遍历 + 盯变化，安装、升级、安全面都要跟着变；Everything 已经做到了，F11 用上它。以后真有大量用户要「不装 Everything 也能全盘搜」再立项。 |
| F15 | 普通搜索里要不要能直接找到文件 | **兜底那一组的第一行加「在文件里找「词」」**（只在出兜底搜索的时候——默认就是没有本地结果时——且输入 ≥ 2 个字）：↩ 把输入框换成「空格 + 词」进文件搜索。同 CmdPal 的兜底、Flow Launcher 的全局文件结果。不把文件直接混进普通结果（每打一个字查一次索引，和 mac 的规矩不一样，排序也会乱）。mac 跟不跟另议，先记进 `MAC-DIFF.md`。 |
| F16 | 拼音搜文件名 | **不做**：索引和 Everything 1.4 都没有拼音，要做只能把候选全拿回来自己转拼音再比，候选又被 F4 截着，搜不全。设置页脚注写一句「文件名要用汉字搜」。 |

## 5. 分批（照推荐）

**第 1 批：范围、上限、退路（A 的主体）**

1. Core `FileSearchSql.Build`：不再收 `roots`，范围固定 `SCOPE='file:'`；`TOP` 按 F4。`RootFilter` 留给 F7 那几个根用不用另说（扫目录不用 SQL），用不上就删。
2. Core 新 `FileSearchFilter`：`IsExcluded(string path, string systemDrive)`（F3，按路径分段比、不分大小写）；`Tokens(string query)`（按空白切、去掉文件名里不可能有的 `\ / : * ? " < > |`、去空、最多 4 个，SQL 和 Everything 共用）。配单测（审查方写）。
3. App `FileSearch.Roots()` → `KnownFolders()`（F5）。
4. `FileSearch.SearchAsync`：索引 → `IsExcluded` 过滤 → 打分；索引不可用 → F6 扫目录（重写 `Walk`：边枚举边比，预算在循环里查）；F7 把没进索引的已知文件夹也扫了并进来（F8 的结果没出来之前先不扫，第 2 批接上）。删 WinRT 那条路。
5. F15 兜底行（`LauncherModel` 兜底那一段，`Kind = Prompt`，↩ 填「空格 + 词」）。
6. `OleDbFileSearch.ReleaseRows` 传 `rows`（R114 第 7 条）。
7. 设置页脚注改成照实说（第 3 批加 Everything 那一句）。
8. 自检：`--file-search=<词>` 照旧记耗时和条数，另记 `source=oledb|walk`、`excluded=<去掉了几条>`。

**第 2 批：诊断和提示**

1. App 新 `Launcher/SearchIndexStatus.cs`：F8 的服务状态、目录状态、`IncludedInCrawlScope`。COM 照 `OleDbFileSearch` 的写法：优先让 CsWin32 生成
   `CSearchManager`、`ISearchManager`、`ISearchCatalogManager`、`ISearchCrawlScopeManager`（`NativeMethods.txt`，`allowMarshaling: false`），生成不了就按
   Windows SDK `searchapi.h` 的 vtable 顺序用函数指针调（照 `OleDbFileSearch` 文件头那两个坑的写法，索引号对着头文件数、别凭记忆）。
   URL 写法 `file:///D:\`（带结尾反斜杠）。查不出来（COM 失败）就当「不知道」，什么都不提示，不能当成「没进索引」。
2. Core `FileSearchHints.Pick(状态, 结果条数, 用不用 Everything)` → 该出哪一条（F9 的优先级和「少于 5 条」），配单测。
3. 启动器：文件结果最后一行出那条提示；↩ 按 F9 / F10；F10 用 `ShellExecuteEx` + `runas` 跑 `sc.exe`，`ERROR_CANCELLED`（用户点了「否」）不算失败、不弹错。
4. 设置 › 启动器 ›「文件搜索」：「建了索引的位置」那张卡的副标题换成现在的状态（「正常 · 已编入约 N 项」「服务没开」「正在建，还剩约 N 项」「D:、E: 不在索引里」）。
5. 自检：`--file-search-status` 把 F8 读到的东西记一行日志（服务状态、启动类型、目录状态和暂停原因、待建项数、每个已知文件夹和本地盘 in / partial / out），不弹界面。

**第 3 批：Everything（B）**

1. Core 新 `EverythingIpc`：`Query(string search, uint replyHwnd, uint replyId, uint maxResults)` → `byte[]`（F12 的 28 字节头 + UTF-16 + NUL，
   `search_flags = 0`，`request_flags = 0x1 | 0x2 | 0x40`，`sort_type = 14`）；`SearchText(IReadOnlyList<string> tokens)` → 每个词去掉 `"` 后加引号、空格连
   （Everything 的空格是「并且」，引号让 `| ! < >` 这些当普通字）；`Parse(ReadOnlySpan<byte> reply, uint requestFlags)` → `(Name, Folder, Modified, IsFolder)` 的列表，
   **每个偏移和长度都检查边界**，越界、长度对不上、条数超过 10000 的整包丢掉（回包是别的进程发来的，见下面第 3 条）。配单测（审查方写：拼好的字节逐个比、
   手工拼的回包、截断和偏移越界的坏包）。
2. App 新 `Launcher/EverythingSearch.cs`：`FindWindow` 两个类名 → `SendMessageTimeout(WM_USER, 0/1, …)` 拿版本（1.4 以上）、401 看数据库载完 →
   `SendMessageTimeout(WM_COPYDATA, …, SMTO_ABORTIFHUNG, 500 ms)` 发查询 → 等回包（`TaskCompletionSource`，1.5 秒超时）→ 线程池里 `Parse` → `IsExcluded` → 打分。
   任何一步不成就退回系统索引，日志只记步骤名和错误码（不记查询词、不记路径）。
3. `HiddenWindow` 收 `WM_COPYDATA`：**只认**正在等的那一次（`dwData` = 这次的 id、`wParam` = 刚才发查询的那个 Everything 窗口），大小不超过 8 MB，
   在窗口过程里只把字节拷出来、交给等着的那个任务，返回 TRUE；别的 `WM_COPYDATA` 一律返回 FALSE、不碰数据。
4. 设置页：F11 的开关；下面一行状态（「在用 Everything 1.4.1.1026」「没找到正在运行的 Everything，用 Windows 搜索」）；脚注 F13。
5. 用着 Everything 时 F9 的②③不出；Everything 查询失败退回索引的那一次照常出。
6. 自检：`--file-search=<词>` 日志多记 `source=everything` 和版本号；`--everything-probe` 记找没找到窗口、版本、数据库、一次查询的耗时和条数。

## 6. 验收

- 单测：`FileSearchSqlTests`（改范围后的 SQL）、`FileSearchFilterTests`、`FileSearchHintsTests`、`EverythingIpcTests` 全过；原来的文件搜索单测照改范围后的样子改断言（范围变了是这次的本意，不是为了让测试变绿）。
- 量：§5 第 1 批第 8 条、第 3 批第 6 条的数写进交接（整个索引范围 P50、Everything P50、扫目录在服务关着时多久出第一批结果）。
- 手测：`HANDTEST.md` 1800–1829。
- 内存：没有常驻的缓存，内存探针和上一版比不该涨。
- `MAC-DIFF.md`：启动器那一条改成「文件搜索走 Windows 搜索的索引（整个索引），装了 Everything 并在运行时用它；最后一行有索引状态的提示；普通搜索的兜底里有『在文件里找』（mac 没有）」。
- 更新日志（这一版）：
  - fix「启动器搜不到 D 盘、自己建的文件夹里的文件：现在搜 Windows 搜索建了索引的所有位置」/ "The launcher now finds files in every location Windows Search indexes, not just a few user folders"
  - fix「Windows 搜索服务关着时也能在桌面、文档这几个文件夹里找到文件」/ "File search works in your main folders even when Windows Search is turned off"
  - feat「装了 Everything 并且它在运行时，启动器用它搜文件」/ "File search uses Everything when it's installed and running"
  - feat「搜不到时最后一行说明原因：索引服务没开、还在建、哪些盘没进索引」/ "When files can't be found, the last row explains why"
