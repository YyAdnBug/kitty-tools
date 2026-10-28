# 启动器对齐 mac——拍板页

2026-10-28。剪贴板（`PLAN-v9-clipboard.md`）、截图标注（`PLAN-v9-annotate.md`）、设置之后，用户：「检查启动器的样式和功能有没有和 macos 保持一致，没有的话就开始对齐 macos；你只管实现功能和对齐 UI，我会让 windows 的去检查」。

**状态：用户说「没有的话就开始对齐」，D1–D9 按推荐直接做（想改哪一条说一声，再回头改）。7a–7d 审查方在 Mac 上都写完了（2026-10-28，`git log --grep "启动器"`），一个字都没编译过：Windows 那边先编译、跑单测和 `--ui-snapshots`，编译错直接修；手测见 HANDTEST 529–575（都没走）。** 先列 Windows 现在的毛病（§1），再按结果（§2）、视觉（§3）、按键和 Ctrl+K（§4）、设置页（§5）逐项对 mac，最后是替用户定的几件事（§6）和分批（§7）。

- **对的是谁**：mac 的路径相对 `macos/KittyTools/`：`Launcher/LauncherModel.swift`（结果顺序、执行、按键、Ctrl+K 动作表）、`LauncherPanelView.swift`（行、分组标题、高度、底栏）、`LauncherItem.swift`（内置动作）、`SystemCommands.swift`、`WebSearch.swift`、`Calculator.swift`、`LauncherUsage.swift`（收藏、常用、移除）、`Settings/LauncherTab.swift`；规格 `.cursor/rules/mac-whisker-launcher.mdc`（写成「wl」）。Windows 对着 `024d0e3`，路径相对 `windows/KittyTools/`：`Launcher/**`、`KittyTools.Core/{LauncherItem,LauncherMatch,LauncherCommands,DirectItems,WebSearch,Calculator,PanelFooterText,PanelMetrics}.cs`、`Shell/Ui/KindTile.cs`、`Settings/SettingsWindow.cs` 的 `BuildLauncher`。
- **规矩照旧**：功能、行为、数值、文案跟 mac；窗口外壳、字体、图标字形、快捷键写法跟 Windows（⌘ → Ctrl，⌥ → Alt，⌫ → Delete）。mac 的 pt 是 DIP；mac 13 号的副标题在 Windows 上是 14（PLAN-v7 §2.1 字号表）。全 App 不做「从小放大」。
- **和 PLAN-v9 的关系**：PLAN-v9 §4 的 L1、L3–L8，§1 的 V1（浏览器书签 / 历史开关）和 REVIEW R42（首搜在 UI 线程拷浏览器库）都并进这一页；PLAN-v7 §3.2 定了没做到的（「收藏」「常用」分组标题）也在这里收尾。PLAN-v7 §3.2 写的计算卡「上下两行」改成 mac 的一行（D3）。

## 1. 先修：Windows 现在的毛病

| # | 毛病 | 在哪 | 修法（照 mac） |
|---|---|---|---|
| B1 | **第一次搜索卡一下**：每次搜索都在 UI 线程上 `BookmarkIndex.Load()` / `HistoryIndex.Load()`，第一次把每个浏览器的 `History` 整个拷到临时目录再开库；读过一次就再也不重读（R42） | `LauncherModel.Results`、`LookupServices.cs:425` | 呼出时在线程池里读，读完换上不可变的快照、回 UI 线程按新快照重搜；之后按文件修改时间重读。两份浏览器表收成一份 |
| B2 | **浏览历史一直在读、书签读四家**，没有开关（PLAN-v9 V1） | 同上 | 照 mac：只列装了的浏览器，每家「书签」「也搜浏览历史」两个开关；默认书签开 Edge 和 Chrome、历史全关（V1 推荐） |
| B3 | **端口那一行 Enter 是「复制 localhost:端口」**，mac 是结束占着端口的进程（有窗口的程序是退出） | `LauncherModel.Execute` 的 `port:` | 照 mac（D5） |
| B4 | **kill 的副标题一直写「再按 Enter 结束」**，没上膛也这么写 | `LauncherModel.ProcessItems` | 副标题「PID 4321 · 312 MB · 监听 :3000」，上膛了才换成确认提示（危险色） |
| B5 | **上膛后挪选中、按 Esc 都不撤**，下一次按 Enter 直接执行 | `LauncherModel._armed` | 打字、↑↓、点别的行、Esc（先于清空搜索）、收起都撤掉 |
| B6 | **兜底搜索只认一个**：设置里勾一个就把别的都取消；明写了 `https://` 的也出兜底 | `SettingsWindow.BuildLauncher`、`LauncherModel.Results` | mac：每条搜索各自一个「兜底」开关，可以多个；有直达网址 / 路径、或开头是 http(s):// 时不兜底 |
| B7 | **Ctrl+C 复制了面板还开着**，提示在底栏 | `CopyTarget` | mac：复制后收起面板，用轻提示说「已复制路径」+ 复制的内容 |
| B8 | **种类名对不上**：内置动作写「动作」（mac「命令」）、文件写「路径」（mac 写扩展名大写或「文件夹」）、端口写「端口」（mac「进程」） | `PanelFooterText.LauncherKindName` | 照 mac |
| B9 | **应用的副标题写「桌面应用」「商店应用」**，和右边的「应用」重复 | `AppCatalog.cs:205`、`:290` | 照 mac A25：显示名是中文时写 exe 的英文名，开始菜单子文件夹里的写文件夹名，其余留空 |

## 2. 结果和数据

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| R1 | 结果顺序 | cb / fy 行 → 直达网址 / 路径 → 计算 → 关键词搜索 → 正好是关键词的补全提示 → 本地结果（App + 设置页 + 内置动作 + 系统命令 + 快捷链接 + 书签 + 用过的网址 / 文件，一起按匹配分排）→ 浏览历史 → 拼到一半的补全提示 → 兜底搜索（`LauncherModel.swift:356–412`） | 书签、历史不参与排序，一律排在应用后面；没有补全提示、快捷链接、用过的网址 / 文件 | 照 mac |
| R2 | cb / fy | 「cb 词」只有一行「在剪贴板历史里搜索「词」」；单输 cb 时「打开剪贴板历史」排第一、后面照常接；「fy 文本」只有一行；单输 fy 出「翻译…」补全提示（`:358–381`） | 「cb 词」「fy 词」混在别的结果里；单输 cb / fy 没有 | 照 mac；剪贴板 / 翻译功能关着时没有这两行 |
| R3 | 补全提示 | 有关键词的搜索：输入正好是关键词时出「用 Google 搜索…」，是名字开头（≥ 2 字）排在本地结果后面；open / find、quit / hide / forcequit / kill / port 同样出提示；↩ / Tab 把「关键词 」补进框（`WebSearch.promptItems`、`SystemCommands.promptItems`） | 没有 | 照 mac；Windows 没有 eject（D4），提示里不出 |
| R4 | 快捷链接 | 网址里没有 `{query}` 的是快捷链接，和 App 一起排，↩ 打开、记使用；路径也行（`WebSearch.quicklinkItems`） | 没有 | 照 mac |
| R5 | 兜底 | 只在没有本地结果时（设置可改成「总是」，L4），各家开着兜底的都列；短于 2 字不兜底；有直达项不兜底（`:396–406`） | 只在什么都没有时、只一个 | 照 mac（B6、L4） |
| R6 | 书签 / 历史 | 书签至少 2 个字才搜、先粗筛再排；历史至少 2 个字、最多 5 行、和书签 / 用过的网址不重复，副标题「历史 · 主机 · 3 天前」，不算本地结果（`:386–395,417–435`） | 历史每次最多 5 行、不去重，副标题是「Chrome 历史」 | 照 mac；Windows 读 Chromium 的 `History`（`visit_count >= 2 OR typed_count > 0`，同 mac）和 Firefox 的 `places.sqlite` |
| R7 | 用过的网址 / 文件 | 不在任何目录里，靠使用记录找回来，和 App 一起排（`usedLocations`） | 只出现在「常用」里 | 照 mac |
| R8 | 收藏 | ⌘D 加 / 取消，最多 8 个，满了「收藏最多 8 个，先取消一个」；还原不出来的（应用卸了、文件删了）藏起来不删、不占名额；⌥⌘↑↓ 只和看得见的邻居换（`LauncherUsage`） | 不限个数；还原不出来的照样显示 | 照 mac；Ctrl+Alt+↑↓ |
| R9 | 常用 | 收藏后面用常用补足 8 行；「常用」里 ⌘⌫ 移除一项（忘掉它的使用记录），底栏「已从常用中移除 · 撤销 Ctrl+Z」，⌘Z 放回（`forget` / `undoForget`） | 没有移除 | 照 mac：Ctrl+Delete 移除、Ctrl+Z 撤销（打字、移动、Esc、收起后不能撤） |
| R10 | 系统命令 | 14 个；标题是系统里的叫法，副标题是英文关键词（lock、sleep…），英文名、口语叫法（锁屏、重启）和拼音只进匹配（`SystemCommands.swift:11–100`） | 6 个；副标题都是「系统命令」 | 加关闭显示器、屏幕保护程序、打开回收站、调高音量、调低音量、切换静音（L5）；副标题写关键词；不做全部退出、推出全部磁盘（L5 已定） |
| R11 | 带对象的命令 | quit / hide / forcequit / eject 空格列正在运行的 App / 可推出的磁盘；kill 列后台进程（监听端口的排前、再按内存）；port 一个在监听的 TCP 端口一行（`SystemCommands.swift:180–331`、wl「系统命令」） | 只有 kill（按内存排，含有窗口的程序）、port（TCP + UDP） | 做 quit（退出）/ hide（最小化）/ forcequit（强制退出），不做 eject（D4）；kill 照 mac 不列有窗口的程序（它们在 quit 里）；port 只列 TCP，一个端口一行，标题「:3000」、副标题「node · PID 4321」 |
| R12 | 内置动作 | 和菜单栏同名同序：快捷动作（启动器自己除外）、每节末尾接「暂停记录剪贴板」（副标题正在记录 / 已暂停）「复制即译」（已开启 / 已关闭），最后设置、快捷键速查表、关于、检查更新、退出；关着的功能不列（`LauncherItem.swift:82–107`） | 9 项写死 | 照 mac = L8：内置动作表从快捷动作表 + 托盘那几项生成；划词翻译不进（同托盘 G1：点了启动器，原来的程序就不在前台了） |
| R13 | Tab 补全 | 选中项的补全：App / 动作 / 网址 / 系统命令补标题，文件夹补「路径\」（`completion(for:)`） | 只有带 `Completion` 的几种 | 照 mac |
| R14 | 60 秒内再呼出 | 留着查询和选中项，字全选着（直接打字就替换）（`prepareForShow`） | 留着，但光标在末尾 | 补「全选」 |
| R16 | fy 单词的释义 | 「fy 单个英文词」时副标题异步换成系统词典的第一条释义（体检 D10，`lookUpDefinition`） | 没有 | Windows 没有系统词典：取本机翻译历史 / 生词本里这个词上一次的译文第一行（生词本优先，不分大小写），只给「一个词」（`WordLookup.IsWord`）查，没翻过的空着；不联网（2026-10-28 补） |
| R17 | ip | 「ip」（「ip 地址」「内网 ip」这类）排在最前列本机每块网卡的 IPv4（默认路由那块第一，VPN 写「内网」）和外网地址（问 myip.ipip.net、api.ipify.org，两家不一样各一行）；↩ 粘贴、⌘↩ 只复制；输到 ip 等 0.3 s 再问（mac 2026-10-28 新加的 `IPAddresses.swift`，当时还没提交） | 没有 | 照 mac：网卡用 `NetworkInterface` 读、默认路由用 `GetBestInterface`，VPN 按 PPP / 隧道类型或说明里的 VPN / WireGuard / TAP 认；拼行在 Core 的 `LauncherIp`（2026-10-28 补） |
| R15 | 计算器 | mod、函数、pi / e、0x / 0b / 0o、单位换算、进制，大字千分位、⌘K 多「复制原始数字」「复制十六进制」…（`Calculator.swift`） | 四则、括号、乘方、百分号 | 照 mac 原样移植 = L6，mac 的单测期望值一起搬 |

## 3. 视觉

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| V1 | 高度 | 56 + 0.5 + 列表（上下内缩 6 + 28 × 分组数 + min(n, 8.5) 行）+ 36；没结果时一行字 52；Ctrl+K 菜单开着时至少放得下它（`LauncherPanelView.height`） | 外框 116，最少三行、最多八行 | 照 mac 的数，写成 Core 的纯函数 + 单测 |
| V2 | 列表 | 一块 `LazyVStack`：分组标题、行按前缀和摆，高亮按前缀和定位、在行间滑动（`offset(ofRow:)`） | `ListView`，高亮量容器位置（滚出去的行拿不到容器，高亮消失） | D1：照剪贴板 `ClipListView` 的做法自己画 |
| V3 | 分组标题 | 空查询「收藏」「常用」，open 只输关键词「最近打开和下载的文件」，quit / kill / port「正在运行的 App」「后台进程」「在监听的端口」；28 高、12 semibold tertiary、缩进 10、贴底留 2 | 没有 | 照 mac（PLAN-v7 §3.2 也定过） |
| V4 | 行 | 40 高、左右 10；图标 24；标题 14 medium + 副标题同一行、secondary、从中间截；右边种类 12 tertiary（wl） | 左右 6；副标题从末尾截 | 照 mac；副标题从中间截写成 Core 的纯函数（按字数，ponytail） |
| V5 | 悬停 | 没选中的行铺 `Fill.Hover`（0.10 s），不移动选中 | `ListView` 自带的悬停底 | 照 mac |
| V6 | 计算卡 | 64 高，一行：算式 13 等宽 secondary → 箭头 → 结果 28 semibold 等宽数字（`LauncherRow` 计算分支） | 上下两行，结果用 Consolas | 照 mac（D3）：算式用 Cascadia Mono 14，结果 Segoe UI Variable Display 28 semibold |
| V7 | 图标 | App / 文件是系统图标；网址 / 书签 / 搜索是网站图标（没有才是种类色块）；系统设置面板是「设置」应用的图标；种类色块按家族色（wl） | App 有图标；设置页、网址都是色块 | 设置页用「设置」应用的图标（开始菜单里那一个）；网站图标先读本机 Chromium 的 `Favicons` 库、再用剪贴板链接预览取到的（`LinkPreviewService.IconFor`，链接预览关着时不用），都没有才是色块（同 mac，不联网） |
| V8 | 家族色 | App / 文件灰（只在取不到图标时露出来）、内置动作跟它那一节（剪贴板蓝、翻译绿、截图粉）、系统命令和进程紫、网址青、搜索和提示靛、计算橙 | App 紫、文件橙、内置动作一律粉 | 照 mac |
| V9 | 按住 Ctrl | 150 ms 后右边的种类依次换成 ⌘1–9 键帽（每行错开 15 ms），松开换回（`kind`） | 种类旁边多一个数字键帽 | 照 mac：换成「Ctrl+1」…，种类淡出 |
| V10 | 选中的内置动作 | 种类前多一组它的全局快捷键键帽（没设不显示） | 没有 | 照 mac |
| V11 | 按住修饰键 | 选中行的副标题换成替代动作「⌘↩ 在访达中显示」「⌥↩ 在访达里搜索「词」」「⌃↩ 用 Google 搜索「词」」（`alternateSubtitle`） | 没有 | 照 mac：Ctrl / Alt / Shift（D6） |
| V12 | 底栏 | 左：16 色块 + 种类名；右：「主动作 ↩」（名字随种类：打开 / 运行 / 打开网址 / 粘贴 / 结束…）·「操作 Ctrl+K」；有新版本时种类后面「更新到 x」 | 左右都有；没有「更新到 x」 | 补「更新到 x」（点了先收起面板再走自动更新，同托盘那一项）；主动作的名字照 mac 的表 |
| V13 | 空结果 | 一行字「没有匹配的结果」，带对象模式各自的说法（「没有后台进程」「没有找到监听这个端口的进程」…），还在读时「正在读取进程…」 | 图标 + 两行字 | 照 mac |
| V14 | 搜索线 | 占位「搜索 App、网址、命令或文件」；Ctrl+K 开着时换成「搜索操作」、放大镜换成命令符号 | 占位「搜索应用、设置、命令…」 | 「搜索应用、网址、命令或文件」；菜单开着照 mac |

## 4. 按键和 Ctrl+K

| # | 键 | mac | Windows 现在 | 推荐 |
|---|---|---|---|---|
| K1 | ↩ | 执行（计算是粘贴，find 的文件是在访达中显示） | 有 | 不动；find 的文件照 mac |
| K2 | ⌘↩ | App / 文件在访达中显示（find 反过来是打开）、计算只复制、网址用第二个浏览器打开（没有就提示音）；quit / hide 里强制退出（上膛） | App 打开文件位置、计算复制 | 照 mac；第二个浏览器从注册表 `StartMenuInternet` 列装了的、去掉默认的 |
| K3 | ⌥↩ / ⌃↩ | 在访达里搜索当前词 / 用第一个兜底搜索搜 | 没有 | D6：Alt+Enter 在资源管理器里搜索（`search-ms:`），Shift+Enter 网页搜索；Ctrl+Shift+Enter「以管理员身份运行」留着 |
| K4 | ⌘C / ⇧⌘C | 复制路径 / 网址 / 结果；网址另有 Markdown 链接（收起面板，轻提示） | 只有 Ctrl+C，不收起 | 照 mac（B7） |
| K5 | ⌘D / ⌥⌘↑↓ / ⌘⌫ / ⌘Z | 收藏 / 调顺序 / 从常用中移除 / 撤销移除 | 前两个 | 照 mac（R8、R9） |
| K6 | ⌘1–9 / ⌘, / Tab / → | 执行第 N 项（不可撤销的先上膛）/ 设置 › 启动器 / 补全 / 光标在末尾时开 Ctrl+K | 前三个 | 补 →；Ctrl+1–9 遇到要确认的先选中再上膛 |
| K7 | Esc | 先撤上膛 → 清空搜索 → 收起（⌘K 开着时先关它） | 清空 → 收起 | 照 mac |
| K8 | 单击 / 双击 / 右键 | 单击选中、双击执行；右键 = ⌘K 同一份动作（对着被点的那行） | 单击选中、双击执行；右键是另写的一份 | 右键继续用系统菜单（跟 Windows 走），条目从 Ctrl+K 那一份生成，分节是分隔线 |
| K9 | ⌘K 菜单 | 面板里浮起的 `ActionMenu`，锚在右下、右缘对着底栏的 ⌘K；开着时搜索框过滤动作；五节：打开（↩、⌘↩）｜用别的 App 打开｜复制（⌘C、Markdown 链接、复制标题；计算的「复制原始数字」等）｜搜索框（补全 ⇥、⌥↩、⌃↩）｜收藏 ⌘D、从常用中移除 ⌘⌫、移到废纸篓（`actions(for:)`） | 系统 `MenuFlyout`，没有分节和过滤 | D2：用剪贴板的面板菜单（`ClipPalette`）；「用别的 App 打开」：网址列别的浏览器，文件是一项「打开方式…」（系统的打开方式对话框，D7）；「移到回收站」能从回收站放回，不二次确认 |
| K10 | 读屏 | 每行有主动作、⌘↩、复制、收藏、从常用中移除几个动作 | 没有 | 行的名字带种类和副标题；动作照 mac 放进右键菜单（读屏用 Shift+F10 打开）——WinUI 的自定义 peer 动作这一轮不做 |

## 5. 设置页

mac 的分节（`Settings/LauncherTab.swift:71–141`）：功能开关 ｜（无标题）呼出时切到英文输入法、启动器里的按键（速查表）｜ 文件搜索（授权、说明）｜ 浏览器书签与历史（只列装了的）｜ 网页搜索与快捷链接（列表、增删、编辑、有本地结果时也显示兜底搜索）｜ 使用记录（清空…）。

| # | 项 | mac | Windows 现在 | 推荐 |
|---|---|---|---|---|
| P1 | 分节 | 上面那几节 | 网页搜索、使用记录两节 | 照 mac；「文件搜索」一节写说明「open 文件名」「find 文件名」和「搜的是 Windows 搜索建了索引的位置」，按钮「索引位置…」打开 `ms-settings:cortana-windowssearch` |
| P2 | 呼出时切到英文输入法 | 开关，默认关，说明「只在搜索框里生效，离开后恢复；要搜中文时先关掉」 | 没有 | = L1：开着时搜索框的 `InputScope` 设成半角字母数字（输入法在这个框里默认英文，不动系统设置）；不灵写进「没做成」 |
| P3 | 浏览器书签与历史 | 每家一行：图标 + 名字 + 书签开关，开着时下一行「已读到 N 条书签」/ 橙字「没找到书签文件」；书签开着时缩进一行「也搜浏览历史」（默认关）+ 说明 | 没有 | = V1，照 mac；Windows 的浏览器表：Edge、Chrome、Firefox、Brave、Vivaldi、Opera、Arc，只列装了的（看用户数据目录在不在） |
| P4 | 网页搜索与快捷链接 | 行 = 网站图标 / 色块、名字 + 种类、关键词键帽、兜底开关（快捷链接没有）；拖动排序；「+」：预置的、「自定义搜索或快捷链接…」；点一行编辑名称 / 关键词 / 网址（`SearchEngineDetail`：网址要 http(s) 或路径、关键词不能和 cb / fy / open / find / quit / hide / forcequit / kill / port 重复）；自定义的删除先确认 | 只能加预置的、不能编辑、兜底只能一个 | = L3：编辑用 `ContentDialog`（设置窗是普通窗口）；排序用 ↑ ↓（同现在）；字段照现有的 `SearchEngine`，同步格式不动 |
| P5 | 有本地结果时也显示兜底搜索 | 开关，默认关 | 没有 | = L4 |
| P6 | 清空使用记录 | 危险按钮 + 确认框「「常用」和按使用习惯的排序会从头开始学，收藏不动。」；脚注写收藏、常用、⌘⌫ 移除 | 「再点一次」 | 照 mac，确认用 `ContentDialog` |

## 6. 替用户定的（说「全部按推荐」等于照这些做）

| # | 问题 | 推荐（已按它做） | 备选 |
|---|---|---|---|
| D1 | 列表怎么做 | **换成自己画的列表**（照剪贴板 `ClipListView`：`ScrollViewer` + `Canvas`，每项的 y 用 Core 的 `LauncherListLayout` 算、配单测）；分组标题是独立的项；高亮按前缀和定位 | 留 `ListView`：分组标题塞进行里，高亮照旧量容器 |
| D2 | Ctrl+K 菜单 | **用剪贴板那块面板里的菜单**（`Clipboard/ClipPalette.cs`），焦点留在搜索框、搜索框过滤动作；右键继续是系统菜单，条目同一份 | 留系统 `MenuFlyout` |
| D3 | 计算卡 | **照 mac 一行「算式 → 结果」**（PLAN-v7 §3.2 写成了上下两行，那是照第一版改的，不是 mac） | 保持上下两行 |
| D4 | 带对象的命令 | **做 quit（关窗口）/ hide（最小化）/ forcequit（结束进程，上膛）**；**不做 eject**：推出 U 盘要按盘符找到设备再请求弹出，找错了会把别的盘弹掉，Windows 托盘里有系统自己的「安全删除硬件」 | 一个都不做，只留 kill / port |
| D5 | 结束进程 | Windows 没有 mac 那种「先礼后兵」的结束（SIGTERM）：控制台程序只能硬结束。**kill / port 的后台进程 Enter = 上膛、再按一次结束**，不另设 Ctrl+Enter；port 里有窗口的程序 Enter = 退出（关窗，不上膛）、Ctrl+Enter = 强制退出（上膛） | 照现在：port 的 Enter 复制地址 |
| D6 | ⌥↩ / ⌃↩ 换成什么 | **Alt+Enter 在资源管理器里搜索、Shift+Enter 网页搜索**（Windows 只有 Ctrl 一个对应 ⌘ / ⌃ 的键，Ctrl+Enter 已经是 ⌘↩） | Ctrl+Alt+Enter 网页搜索 |
| D7 | 文件的「用别的应用打开」 | **一项「打开方式…」**，开系统的打开方式对话框（`SHOpenWithDialog`）；不像 mac 那样列 5 个应用（Windows 要走 `IAssocHandler` 一套 COM，又只是少点一下）。**快速查看 Ctrl+Y 不做**（L7 已定：Windows 没有系统自带的那一套） | 照 mac 列应用 |
| D8 | 网站图标 | **读本机 Chromium 系浏览器的 `Favicons` 库**（书签开关开着的那几家，拷到临时目录只读、按主机缓存），再用剪贴板链接预览取到的；不联网 | 只用种类色块 |
| D9 | 谁做 | **审查方（Claude）在 Mac 上写、不编译**，7a–7d 一批一推；Windows 那边编译、跑单测和 `--ui-snapshots`、手测，编译错直接修、在 `REVIEW.md`「v9 启动器分工」记一句 | 交给 Windows 的 agent |

## 7. 分批和验收

每一小批推上去后，Windows 那边照 `AGENTS.md` 的自查清单过一遍（Debug 零警告、`dotnet test`、Release AOT 零警告、`--ui-snapshots` 浅深高对比度、内存探针）。批号接着剪贴板叫 7a–7d。

| 小批 | 内容 | 验收（除了自查清单） |
|---|---|---|
| 7a 结果和数据 | §1 B1–B6、B8、B9；§2 R1–R15（R15 的计算器移植）；Core 加 `LauncherListLayout`（高度、分组、行的 y）、`LauncherResults`（cb / fy / 补全提示 / 兜底规则）、`LauncherFavoritesRules`（8 个上限、藏起来的不占名额）、`MiddleEllipsis`；mac 的单测期望值搬过来 | 单测；新装（`.Dev` 空数据）：启动器搜不到浏览历史、书签只出 Edge / Chrome；单输 cb / fy / g / kill 出补全提示；「https://x」不出兜底 |
| 7b 列表和面板 | D1 列表重写；§3 V1–V14；D3 计算卡 | 截图：空查询的收藏 + 常用两组、按住 Ctrl 的键帽、计算卡、kill / port / quit 列表、空结果、浅深高对比度 |
| 7c 按键和 Ctrl+K | §4 K1–K10；D2、D4–D7；速查表启动器那一组 | Ctrl+K 每一项走一遍；右键和 Ctrl+K 条目一样；Ctrl+Delete 移除常用、Ctrl+Z 撤销；上膛后按 ↓ 再按 Enter 不执行 |
| 7d 设置页 | §5 P1–P6；L1、L3、L4 | 设置页浅深各一张；改一条自定义搜索的关键词后启动器里按新关键词直达；兜底两家都开着时两行都出 |

做完 7a–7d 就是 PLAN-v9 第 4 批（L1、L3–L8）+ 第 1 批的 V1 + REVIEW R42。版本号照 PLAN-v9 §10 到最后一批再改。
