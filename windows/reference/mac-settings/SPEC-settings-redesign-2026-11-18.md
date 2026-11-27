<!-- 原样拷贝自 mac 主检出 macos/build/research/settings-redesign-2026-11-18/SPEC.md（mac 的 build/ 不进仓库），2026-11-27 给 Windows PLAN-v28 当参考。
     这是 mac 动手前的规格，写的是 mac 0.10.0 的代码和行号；最后做成什么样以 origin/macos 的代码为准（Settings/SettingsIndex.swift 登记了每一行在哪一页、外面 / 子页 / 高级），两边对不上时照代码。 -->

# 设置改版 · 规格（阶段一，2026-11-18）

用户 2026-11-18 回复「两页都按推荐」：S1–S11 全部选推荐，附表照初稿（条目原文在同目录 `build-decisions.py`）。
这份把附表细化到每一行，阶段二照它分 6 批做。代码对照 `origin/macos` a1c1b553（0.10.0）读的，文中行号指那一版。
和初稿不一样的地方集中在最后 §12；用户 2026-11-18 已定：Q1 四项、Q2 Q3 按推荐（§12）。
**版本（用户 2026-11-18 定，会话「整理 0.10.1」转达）：设置改版是 0.10.2**；0.10.0 之后别的修复、新功能和第五轮体检全部进 0.10.1。

## 0. 先说清楚的三件事

1. **基线会变。** 阶段二等 0.10.1 收齐（集成分支 `claude/v0101-cc84e7`：第五轮体检全部批次 + 翻译讲解、妙控鼠标、访达新建文件 / 剪切移动、
   提醒按钮这些修复），从它收齐时的最新提交切（会话「整理 0.10.1」发消息告诉提交号），不再从体检分支切。体检改到的设置相关代码：同步（E1「更新密码…」、U1 岛上「打开同步设置」、U2 四处）、
   刘海岛（U6 音量亮度接不住时的橙字、U14）、提醒（U10）、主界面「管理…」（U12）、快捷键「全部恢复默认」给撤销（U5）、
   截图（N2 延时截图、P2 文件夹名字、U11 授权）、关于（E10）。**阶段二开工第一件事**：
   `git diff a1c1b553..<0.10.1 收齐的提交> -- macos/KittyTools/Settings macos/KittyTools/App/AppDelegate.swift macos/KittyTools/Shell/HomePanel.swift macos/KittyTools/Shell/WhatsNew.swift`，
   新加的行按 §1.1 归类（同主题跟着走、冷门进「高级…」），在第 1 批报告里列出来，本文件的表以那时的代码为准改。
   已知会加设置行的：翻译讲解（issue #35：附加要求、朗读速度——朗读速度跟着发音进「查词与发音」子页，子页名到时候看要不要改成「查词与朗读」）。
2. **偏好键一个不改**：不改名、不迁移、不改默认值，**也不新加键**（「高级…」开没开、悬停预览、恢复默认都不存东西）。
   三个合并的选单（§3）照旧读写原来那两个键。导出导入、同步、每日备份、旧版本都不受影响。
3. **不动结构的**：侧栏分组和「已关闭」组、快捷键页、速查表、全部插件页（介绍页、权限组、关于这个插件）、关于页、欢迎引导。
   小插件页（提醒、状态屏、启动台、程序坞预览、访达右键、保持唤醒、睡眠关蓝牙、平滑滚动、App 快捷键）只按 S5 S11 收文字、
   挂搜索登记，不重排。

### 0.4 版本改了：设置改版进 0.10.1，现在就开工（2026-11-18 22 点，会话「整理 0.10.1」转达用户原话）

- 上面 §0.1 的「等收齐」「升 0.10.2」「另起 0.10.2 日志」作废。从 `claude/v0101-cc84e7` 的 **9ef09943** 切（5 个分支 + 体检第 1–4 批，版本已是 0.10.1），
  分支 `claude/settings-redesign-3e749a`。`MARKETING_VERSION` 不动，用户看得见的改动写进 `changelog.json` 现有的 0.10.1 那一条。
- 每批提交前先 merge `claude/v0101-cc84e7` 最新的提交进来；体检第 5–9 批新加的设置行（U5、U12、U4、E10、N2、N3）由这边按 §1.1 放；
  每批做完把提交号发给会话「整理 0.10.1」。不打包、不 push。第 2 批做完照旧停下来给用户看截图。

**a1c1b553..9ef09943 对过的设置改动，放法：**

| 改动 | 来自 | 放到 |
|---|---|---|
| 翻译「朗读速度」四档（`translateSpeechSpeed`，注册了） | issue #35 | 和发音一起进子页，子页改名 **「查词与朗读」**（`sub:translate.lookup` 不变）；它管所有喇叭，不只单词。恢复默认加上这个键 |
| 翻译服务详情的「讲解」「附加要求」 | issue #35 | 服务详情页，不动 |
| 刘海岛「音量和亮度」接不住时的橙字（`IslandTab(mediaKeys:keyStatus:)`、`keyWarning`） | 体检 U6 | 跟着进子页「音量与亮度」；推进行的橙字 value 读同一个 `keyWarning != nil` |
| 通用页滚到「同步」（`navigation.revealsSync`、`SyncSection.anchor`、AppDelegate「打开同步设置」） | 体检 U1 | 第 2 批换成推进 子:同步，`revealsSync` 删掉；主界面「设置」的橙点悬停提示路径改成 设置 › 通用 › 同步 |
| 同步一节的「更新密码…」、停止确认等 | 体检 E1 U2 | 原样跟着 SyncSection 进子页 |
| 截图「快速保存到」只读存下的名字（`screenshotSaveDirectoryName`，不注册） | 体检 P2 | 行不动 |
| 访达右键「在访达里用 ⌘X 剪切、⌘V 移动」+ 授权橙字（`finderMenuKeys`，不注册） | issue #33 | 小插件页，不重排；登记搜索 |
| 平滑滚动、提醒详情的小改 | 修复分支 | 不动 |

## 1. 通用件（第 1 批「地基」做）

### 1.1 一行去哪（S1 的规矩，以后加设置也照这个）

- **外面**：每页第一行的功能开关（「启用 X」）；天天会碰的；要授权的（权限行跟着它管的那一项走）；管数据的（清空、导出导入）。
- **子页**：同一主题 4 项以上（含它的总开关），或者本身是一张列表 / 一组状态（权限、同步、备份）。外面留一行推进行。
- **「高级…」**：零散的、一年改一次的、不牵连别的行的。不放功能开关、要授权的、会删数据的上限。
- **按键行**（「…的按键」+「查看全部快捷键…」，N11）留在外面。
- **页面里的先后**：功能开关 → 常用的组 → 推进行的组 → 按键行 → 「高级…」 →（插件页）「关于这个插件」。

### 1.2 推进行 `SettingsPushRow`（ScriptsSection.swift:302，扩展，不另建）

- 加两个可选参数：`value: LocalizedStringResource?`（行尾状态：secondary、在 › 左边、间距 6、`lineLimit(1)`）和
  `valueIsProblem: Bool`（换成 systemOrange，同 `OrderedList.statusStyle`）。`detail`（副标题）改成可选。
- 新子页的推进行只写行尾状态，不写副标题；已有的六处（功能、插件、应用别名、网页搜索与快捷链接、命令和别名、怎么写脚本）照旧写副标题。
- 行尾状态要短：中文 ≤ 10 个字、英文 ≤ 18 个字符；长的写成副标题。每个都是纯函数（`static func value(…)`），单测锁住。
- 读屏：label 标题、`accessibilityValue` 状态，hint 照旧「打开「X」」。
- 子页或表单里有新功能（§1.10）时，标题后挂 `NewTag`。

### 1.3 子页

- 有子页的页面套 `NavigationStack(path: navigation.path)`、页头画在栈里（同通用、翻译、启动器现在的写法）。这次新要栈的三页：
  **截图、便签、刘海岛**——`SettingsRoot` 那张「自己画页头」的单子补上 `.screenshot, .notes, .island`（SettingsWindow.swift:626）。
- 子页一律登记在新文件 `Settings/SettingsSubpage.swift` 的 `enum SettingsSubpage`（case = 子页；带所属页、标题、路由、读屏名）。
  路由统一 `"sub:<page>.<name>"`，如 `sub:screenshot.history`。翻译服务、网页搜索的 id 不会以 `sub:` 开头；启动器的
  `navigationDestination` 在 `default: SearchEngineDetail(id:)` 之前先认 `sub:`。子页里还能再推（启动器 › 脚本命令 › 怎么写脚本）：path 两项。
- 子页 = `VStack(spacing: 0) { DetailHeader(title: 子页名, status: 一句现在的状态) { 40 pt 页的色块 }; Form {…}.formStyle(.grouped) }`，
  工具栏声明 `SettingsBackButton(action: dismiss)`（同 TranslateServiceDetail）。状态句和推进行的 value 同一个纯函数，可以长一点。
- 最后一组的页脚右对齐「恢复默认」（§1.5）。没有偏好键的子页（权限、同步、备份与导出导入）不放。
- 已有的推进页（功能、应用别名、网页搜索、命令和别名、怎么写脚本、翻译服务详情、网页搜索详情、状态详情、提醒详情）结构不动；列表类不加「恢复默认」。

### 1.4 「高级…」按钮和表单

- **按钮** `AdvancedButton(page:)`：页面最后（按键行之后、「关于这个插件」之前）一个空 `Section` 的页脚里，右对齐系统按钮「高级…」；
  表单里有新功能时按钮左边挂 `NewTag`。读屏 label「高级设置」。
- **状态**：`SettingsNavigation.advanced: SettingsPage?`（不存偏好）。每页自己 `.sheet(isPresented: navigation.advanced == 本页)`
  出自己的表单（表单要页里的 store / services，所以不在 SettingsRoot 统一出）。
- **骨架** `AdvancedSheet`（新文件 `Settings/AdvancedSheet.swift`，样子同导出表单 `TransferForm`）：宽 480、高随内容
  （最高 = 设置窗内容高 − 60，再多里面的 Form 滚）；页头 40 pt 页的色块 + title2「<页名> · 高级」+ callout 一句（§5 表里给了）；
  发丝线下是分组表单；底栏 52 高：左「恢复默认」（普通按钮，§1.5）、右「完成」（`BrandButtonStyle`，↩、Esc 都关）。
  根上挂 `.appAccent()`、`.symbolEffectsRemoved(reduceMotion)`，同 SettingsRoot 里另外几张 sheet。
- **换页时**：现在设置窗挂着 sheet 就不换页（SettingsWindow.swift:432，护着速查表、确认框里没存的输入）。改成：挂着的是「高级」表单
  （判断用 `navigation.advanced != nil`，别用 `attachedSheet`：收起有动画，那一刻还挂着）就照样换页；别的 sheet 照旧不换。
  `advanced` 在 `SettingsNavigation.page` 的 `didSet` 里和 `path` 一起**同步**清掉——别放进 SettingsRoot 的 `onChange(of: page)`：
  `open(item)` 先换页再设 `advanced`，onChange 晚一拍会把刚设的清掉。换页时旧页的表单跟着旧页一起拆掉、新页的表单再出来，
  阶段二实测这一下（从 A 页的高级表单直接搜到 B 页高级表单里的一行）。
- 表单里的行同样登记搜索（§1.7，place = `.advanced`），搜到时打开表单、滚到那一行、描边。功能关着时表单内容整块 `gated(by:)`，同页面。

### 1.5 恢复默认 + 撤销（S9）

- **管哪些键**：这个子页 / 表单里登记的行（§1.7）的 `keys` 合起来，**只取 `Prefs.defaults` 里有的**——面板大小、文件夹路径、
  `islandNextEvent` / `islandKeyLevels` 这类这台电脑自己的键（不注册默认值）天然不在里面。另外**显式排除**会当场删数据的上限：
  `clipboardRetentionDays`、`clipboardImageBudgetMB`、`shotHistoryDays`、`shotHistoryMegabytes`、`translateHistoryLimit`
  （改回默认可能马上删掉历史，撤销也回不来；它们自己有 E4 / E24 的确认），和功能开关（`Feature.prefsKey`）。
- **做法**：纯函数（新文件 `Settings/SettingsReset.swift`，收 `UserDefaults` 和持久域名字，单测用临时偏好域）：
  `snapshot` = 这些键里**持久域现有**的值；对它们 `removeObject`（= 回到注册的默认值；同步那边「改回默认 = 删掉这一条」，
  别的 Mac 也回到默认，见 SettingsSync.swift 文件头）。持久域里没有的键不碰（不然同步会当成刚改的发出去，ClipboardTab.swift:185 同一条）。
- **按钮**：持久域里一个都没有时置灰；偏好变了跟着重算（`UserDefaults.didChangeNotification`）。点了不先问（能撤销）。
- **结果**：刘海岛 `"已恢复默认"`，详情「<位置>改回了 N 项」（位置 = 「截图 · 高级」「刘海岛 › 正在播放」），按钮「撤销」= 把 snapshot
  原样写回。阶段二逐个核这些键：读它的地方是现读偏好、或看着偏好变化跟上的；有「启动时读一次就缓存」的要补（同 mac-native §2 导入那条）。
- 快捷键页的「全部恢复默认」不改（体检 U5 已给撤销）。

### 1.6 行尾 ⓘ 和一行的写法（S5 用的零件）

- `InfoButton(_ text: LocalizedStringResource)`（放 SettingsWindow.swift、挨着 `SectionFootnote`，都是说明文字的零件）：
  `info.circle` 13 pt secondary、borderless；点开 popover（箭头朝下），里面 callout、宽 280、内边距 12、多行靠左、能选字。
  读屏：label「「<行名>」的说明」，hint 就是全文（不点开也听得到）。不另挂 `.help`。
- 摆法：行尾、控件左边、间距 8（同系统设置 › 通用 › 共享 每行的 ⓘ）。包一个 `SettingRow(title:subtitle:info:isNew:) { 控件 }`
  = `LabeledContent { HStack(spacing: 8) { InfoButton; 控件.labelsHidden() } } label: { 标题（可挂 NewTag）; 副标题 }`；
  `labelsHidden` 只藏字、读屏标签照旧是标题。不带 ⓘ 的行不用改写法。
- 解释一整组的（原来的页脚）放分组标题右边的 ⓘ：`SectionHeader(title, info:)`。页脚只留三种：要授权、会删数据 / 不能撤销、文件不加密。
- `PermissionRow` 加可选 `info:`（引导里不用）。

### 1.7 设置项登记表（S7 的底子；恢复默认、新功能标记也用）

- 新文件 `Settings/SettingsIndex.swift`：`enum SettingsItem: String, CaseIterable`，一行一个 case（rawValue 是 id，如 `clipboard.pastePlain`；
  不存偏好，但别重复）；`var info: Info { switch self {…} }`，`Info` = 所属页、`Place`（`.page` / `.subpage(SettingsSubpage)` / `.advanced`）、
  标题、关键词、`keys: [String]`。
  - 标题用页面上**同一个字面量**（同一个目录 key，英文现成）。
  - 关键词：中文逗号串，同 `SettingsPage.keywords` 的写法（当前语言和中文原文两份都认）；英文给英文界面里的叫法，不逐词直译（多语言 D7）。
    第 2–3 批的表里给了中文的，小插件页的照页里的说法写。
  - `keys`：这一行读写的偏好键，只给恢复默认用；按钮、状态行，和用户自己攒的列表（不记录的 App、应用别名、网页搜索、命令和别名）空着。
    单测要求 `keys` ⊂ `Prefs.defaults` ∪ 测试里写明的那几个不注册的键（`screenshotSaveDirectory`、`screenRecordMicrophoneDevice`、
    `islandNextEvent`、`islandKeyLevels`、`islandHiddenCalendars`、`notesDeckChosenDisplay`）。
- 视图上每一行挂 `.settingsAnchor(.clipboardPastePlain)`（= `.id(item)` + §1.8 的描边），小插件页的行也挂。
- 页的关键词（`SettingsPage.keywords`）留着：侧栏筛页照旧用，快捷键页另加的动作名照旧。

### 1.8 搜索落到行（S7）

- **匹配**：`SettingsItem.matches(query)` = 标题（当前语言 + 中文原文）或关键词含 query（同 `SettingsPage.matches`）。
  `SettingsPage.matches` 改成「页的词对上，或者这页的任一行对上」；没添加的插件的行不算（同页，落到「全部插件」那一行照旧）。
- **侧栏**：搜索框有字时最上面多一组「设置项（N）」，列对上的行，最多 12 条。排序：标题以 query 开头 > 标题含 > 只有关键词含；
  同一档按侧栏的页序、页内按登记顺序。一行 = 20 pt 页的色块 + 标题，下面一行 caption secondary 写位置（「剪贴板 · 高级」
  「截图 › 截图历史」；在外面的只写页名）。下面照旧是筛出来的页。
- List 的选中值从 `SettingsPage` 换成 `enum SidebarItem: Hashable { case page(SettingsPage), item(SettingsItem) }`。选了 `.item`：
  `navigation.open(item)`，侧栏选中落回那一页（结果行只是入口，选中块不停在它上面，同系统设置）。搜索词留着。
- 打字时照旧自动停到最合适的页（`SettingsPage.page(for:)`），**不**自动开子页 / 表单、不描边——选了结果才落到行。
- `navigation.open(item)`：先 page（换页会清 path）→ path = 子页路由或 [] → `advanced` = 表单所在页或 nil → `highlighted = item`。
- **描边**：把 PluginsPage.swift:195–201 那一段抽成修饰符 `settingsHighlight(_ on: Bool)`（外面一圈 2 pt `Style.brand`、圆角 card、往外 6、
  0.3 s easeOut 淡入淡出；减弱动态效果时直接出现 / 消失），`PluginRow` 改用它。`.settingsAnchor` 里看 `navigation.highlighted == item`。
- **滚过去、两秒收**：每个容器（页 / 子页 / 表单）的 Form 外面 `.settingsScrollTarget(place)`：`ScrollViewReader` 包住，
  `onChange(of: navigation.highlighted, initial: true)` 是本容器的行时，晚 150 ms `scrollTo(item, anchor: .center)`（同 PluginsPage.swift:96：
  刚换页时表单还没排好），2 s 后还是它就清成 nil。
- 「全部插件」的 `focusedPlugin` 照旧（插件那一行不是 SettingsItem），只换成同一个描边。
- 体检 N11（「以后」）就是这件事，那边不另做。

### 1.9 从别处打开设置直达（S8 + 已有的入口）

`AppDelegate` 加 `showSettings(_ item: SettingsItem)`（showSettings(page:) + 页到了再 `navigation.open(item)`；挂着别的 sheet 没换成页时不 open，
同 `openReminder` / `showPlugin` 的写法）和 `showSettings(_ subpage: SettingsSubpage)`（推进子页、不描边）。入口改成：

| 入口（代码位置） | 现在 | 改成 |
|---|---|---|
| 剪贴板面板 ⌘, / 底栏齿轮（AppDelegate.swift:683） | 剪贴板页顶上 | 剪贴板页，描「单击条目直接粘贴」（面板怎么用那一组的头一行） |
| 翻译浮窗「⋯ › 设置…」、空状态「打开翻译设置」（:762） | 翻译页顶上 | 翻译页，描「翻译服务」列表那一组；带服务 id 的照旧推进详情页 |
| 启动器 ⌘, / 内置「设置」（:538） | 启动器页顶上 | 启动器页，描「空搜索框里列出常用」 |
| 截图历史窗口「打开设置」（:2965）、历史为空时那句（ShotHistoryView.swift:190） | 截图页顶上 | 推进 截图 › 截图历史，描「保留截图历史」 |
| 全部便签窗口 ⌘, / 工具栏「便签设置」（:1849）、浮动便签「便签设置…」 | 便签页 | 便签页，描「正文字号」 |
| 便签那叠右键「设置」（NoteEdge，:1528） | 便签页 | 推进 便签 › 屏幕边缘 |
| 岛「屏幕边缘的便签关着」→「打开设置」（:1828） | 便签页 | 推进 便签 › 屏幕边缘，描「在屏幕边缘显示便签」 |
| 岛「勾选同步」（:2155）、体检 U1 的「打开同步设置」 | 通用页 | 推进 通用 › 同步 |
| 岛「更改保存位置」（:3676） | 截图页 | 截图页，描「快速保存到」 |
| 主界面「N 个功能关着 · 管理…」（:303，体检 U12 改过） | 通用页 | 推进 通用 › 功能（照 U12 的做法，体检已做就不动） |
| 岛「已复制脚本写法说明」→「打开设置」（:1879）、启动器「新建脚本」（:1865） | 启动器页 | 推进 启动器 › 脚本命令（新建脚本的表单照旧挂在窗口根上） |
| 菜单「保持唤醒设置…」「管理提醒…」「管理状态…」、快捷键岛、关于 | 各自的页 | 不变 |

### 1.10 新功能标记跟着挪（`Shell/WhatsNew.swift`）

- 条目按 `section`（行的标题 key）认行，id 不变。挪进子页 / 表单的行照旧挂 `NewTitle`；**它所在的推进行 / 「高级…」按钮也挂**：
  用登记表反查——这个子页 / 表单里有哪一行的标题 key 在 `fresh` 里。
- 要改 section 的只有一条：`screenshot-web-elements`（0.10.0）的 section 从「也认网页里的元素」改成合并后的「悬停时识别」，
  `WhatsNew.touch(section:)` 的调用跟着改。别的条目标题不变：「同步」「正在播放」「脚本命令」变成推进行，标题还是那几个字。
- 单测：`WhatsNew.entries` 里每个带 section 的条目，都对得上登记表里同页的一行标题。

## 2. 逐页：每一行去哪（S2 S3 S4）

表里「外 / 子:<名> / 高」= 外面 / 那个子页 / 「高级…」表单。id 省略页名前缀（剪贴板表里的 `pastePlain` 就是 `clipboard.pastePlain`）。
关键词只写中文，英文照多语言 D7 另写。没列的行照旧（不动）。

### 2.1 通用（GeneralTab.swift）——第 2 批

外面分三组：①「功能 ›」「插件 ›」②语言、外观、强调色、登录时自动打开 ③「权限 ›」「同步 ›」「备份与导出导入 ›」；然后「高级…」。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 功能 › | features | — | 外 | 功能,模块,关闭,停用,启用 | 照旧，副标题 `FeaturesPage.summary` |
| 插件 › | plugins | — | 外 | 插件,扩展 | 照旧 |
| 语言 | language | （AppleLanguages，不注册） | 外 | 语言,英文,中文 | 照旧（NewTitle 0.10.0） |
| 外观 | appearance | appearance | 外 | 浅色,深色,暗黑,主题 | |
| 强调色 | accent | accent | 外 | 主题色,颜色 | |
| 登录时自动打开 | login | （SMAppService） | 外 | 开机,登录,自启 | 连同「要批准」那一行、从磁盘映像运行的页脚 |
| 权限 › | permissions | — | 外，推进 子:权限 | 权限,授权,隐私 | value：都给了「都已允许」；缺 n 项橙字「缺 n 项」，**这时这一组挪到页面最上面**（「功能 ›」之前）。缺 = 开着的功能用得着而没给的辅助功能、屏幕录制（`OnboardingView.permissions(for: Feature.enabled)` 同口径），加上剪贴板开着、剪贴板访问是「询问 / 拒绝」；麦克风用到时再问，不算缺 |
| 同步 › | sync | — | 外，推进 子:同步 | 同步,iCloud,云盘,WebDAV,多台 | value：关「关」/ 正在同步「正在同步…」/ 好「x 分钟前」（`lastSync`，相对时间）/ 停了（`.stopped`）橙「停了」/ 等确认（`.waiting`）橙「等你确认」。NewTag：0.9.0 `sync-server`。`sync == nil`（便签这次用不了）时照旧不出这一行 |
| 备份与导出导入 › | backup | — | 外，推进 子:备份 | 导出,导入,备份,恢复,迁移,换电脑 | value：自动备份开着「<最近一份的时刻>」（`SettingsBackup` 那行说明的取法，短格式：今天 09:12 / 昨天 / 11月3日）；关着「自动备份关着」；本机没备成橙「没备成」。`transfer == nil` 时照旧不出 |
| 呼出面板时挤压弹开 | squeeze | panelSqueezeEntrance | 高 | 挤压,弹开,动画,动效 | 表单顶上放 S10 的舞台（§6） |
| 在菜单栏显示图标 | menuBarIcon | statusItemVisible | 高 | 菜单栏,状态栏,图标,隐藏 | |
| 图标样式 | menuBarStyle | statusItemStyle | 高 | 彩色,单色 | 照旧带 1:1 预览 |
| 在程序坞显示图标（只 26） | dockIcon | dockIconOnTahoe | 高 | 程序坞,Dock | |
| 数据目录 | dataFolder | — | 高 | 数据,数据目录,访达,文件夹 | |

- **子:权限**（`sub:general.permissions`，状态句 = value）：辅助功能、屏幕录制、麦克风、剪贴板访问（15.4 起）四行 `PermissionRow`，
  照旧每次设置窗当 key 时刷新（那几个 `@State` 和 `onSettingsBecameKey` 从 GeneralTab 挪进来；推进行的 value 由 GeneralTab 在
  出现 / 当 key 时另算一次）。id：`permissions.accessibility` / `.screenRecording` / `.microphone` / `.clipboardAccess`。
- **子:同步**（`sub:general.sync`）：`Form { SyncSection(syncer:) }` 原样搬进去（体检改过的版本），页头状态 = value 的长说法。
  SyncSection 里那几行登记 id：`sync.folder`、`sync.parts`、`sync.peers`。
- **子:备份**（`sub:general.backup`）：`Form { TransferSection(transfer:) }` 原样搬进去。id：`backup.transfer`（导出 / 导入）、
  `backup.daily`、`backup.restore`、`backup.mirror`。表单、存储 / 打开面板照旧挂在设置窗上（阶段二验证在推进页里照样弹得出来）。
- 高级表单恢复默认管：panelSqueezeEntrance、statusItemVisible、statusItemStyle、dockIconOnTahoe。

### 2.2 剪贴板（ClipboardTab.swift）——第 2 批

外面：启用剪贴板 → 历史 → 粘贴（新的组名）→ 隐私 → 不记录这些 App → 「高级…」。没有子页。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 启用剪贴板 | enabled | （功能开关） | 外 | 启用,关闭 | |
| 保留普通历史 | retention | clipboardRetentionDays | 外 | 历史,天数,保留,永久 | E4 确认照旧 |
| 图片最多占用 | imageBudget | clipboardImageBudgetMB | 外 | 图片,占用,空间 | E4 确认照旧 |
| 图片当前占用 | imageUsage | — | 外 | 占用 | |
| 单击条目直接粘贴 | pasteOnClick | clipboardPasteOnClick | 外 | 单击,双击,点击,粘贴 | S8 剪贴板入口描它 |
| 默认粘贴为纯文本 | pastePlain | clipboardPastePlain | 外 | 纯文本,格式 | |
| 不记录疑似密钥和银行卡号 | blockSensitive | clipboardBlockSensitive | 外 | 密钥,银行卡,密码,敏感 | |
| 自动清空普通历史（S6） | autoClear | clipboardClearOnQuit, clipboardClearOnLock | 外 | 清空,退出,锁屏 | 合并选单，§3；不 gated（管数据） |
| 立即清空普通历史… | clearNow | — | 外 | 清空 | |
| 不记录这些 App 里的复制 | excludedApps | —（列表） | 外 | 排除,App,不记录 | 列表照旧 |
| 面板示意 + 显示透镜 | lens | clipboardShowPreview | 高 | 透镜,预览 | 示意图 `ClipboardPanelSketch` 跟着进表单、放在这一行上面 |
| 链接显示网页标题和图片 | linkPreview | clipboardLinkPreview | 高 | 链接,网页,标题 | |
| 面板位置 | panelPosition | clipboardPanelPosition | 高 | 位置,面板位置,跟随鼠标,上次位置 | |
| 面板大小 | panelSize | （宽高是这台电脑的） | 高 | 面板大小,宽度 | 自己的「恢复默认大小」照旧；表单的恢复默认不动它 |
| 识别图片中的文字，用于搜索 | imageOCR | clipboardImageOCR | 高 | 识别,文字,OCR | `onChange` 里的 `store.recognizePendingImages()` 跟着挪 |

- 高级表单恢复默认管：clipboardShowPreview、clipboardLinkPreview、clipboardPanelPosition、clipboardImageOCR。

### 2.3 截图（ScreenshotTab.swift）——第 2 批

外面：启用截图 → 快速保存到 → 截图拷贝为 → 截完图放哪（S10 舞台在这一组顶上）→ 快门声 → 「截图历史 ›」→ 按键两行 → 「高级…」。
这一页改成 `NavigationStack`。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 启用截图 | enabled | （功能开关） | 外 | | |
| 快速保存到 | saveFolder | screenshotSaveDirectory（不注册） | 外 | 保存,存储,目录,文件夹 | S8「更改保存位置」描它 |
| 截图拷贝为 | copyAs | screenshotCopyAs | 外 | 拷贝,复制,文件,PNG,对拷线 | NewTitle 0.7.3 照旧 |
| 截完图放哪 | placement | screenshotPlacement | 外 | 缩略图,晾衣绳,角落 | 选晾衣绳而历史关着时，下面橙字改成「晾衣绳挂的是截图历史，先打开截图历史」+ `brandInk` 文字按钮「去打开」→ 推进 子:截图历史、描 `history.keep` |
| 截图时播放快门声 | shutter | screenshotShutterSound | 外 | 快门,声音 | 试听照旧 |
| 截图历史 › | history | — | 外，推进 子:截图历史 | 历史,截图历史 | value：开「30 天 · 2 GB」（不限写「一直留着」「不限」）/ 关「关」 |
| 框选、标注、长截图和录屏的按键 | keys | — | 外 | 按键,速查 | |
| 改按键（截图里的快捷键…） | editKeys | — | 外 | 快捷键,改键 | |
| 截图带上鼠标指针 | cursor | screenshotCursor | 高 | 指针,鼠标指针 | |
| 截图、录屏时隐藏桌面图标 | hideDesktop | captureHideDesktopIcons | 高 | 桌面图标,隐藏 | |
| 框选时显示操作提示 | hint | screenshotShowsHint | 高 | 提示 | |
| 框选时的放大镜 | loupe | screenshotLoupe | 高 | 放大镜,取色,色值 | |
| 工具栏位置 | toolbar | screenshotToolbarAlign | 高 | 工具栏,靠右,居中,录制条 | |
| 框选时保持屏幕原色 | keepsColors | screenshotKeepsColors | 高 | 原色,压暗,遮罩 | NewTitle 0.7.3 照旧 |
| 悬停时识别（S6） | findsElements | screenshotFindsElements, screenshotFindsWebElements | 高 | 元素,识别,悬停,网页,浏览器 | 合并选单，§3；NewTitle 0.10.0（section 改名，§1.10）；开着又没授权时下面照旧出辅助功能那一行 |
| 钉图上的字可以直接选 | pinText | pinSelectsText | 高 | 钉图,选字 | |
| 识字后把同一段里的换行接起来 | joinLines | ocrJoinLines | 高 | 识字,换行,二维码 | 前后对照的示意跟着进表单 |

- **子:截图历史**（`sub:screenshot.history`）：保留截图历史（`history.keep`，shotHistory）、保留（`history.days`）、最多占用
  （`history.size`）、打开截图历史…（`history.open`）、现在清空…（`history.clear`）。两个上限的 E24 确认照旧。页脚留一句（会删数据）。
  恢复默认只管 shotHistory。
- 高级表单恢复默认管：screenshotCursor、captureHideDesktopIcons、screenshotShowsHint、screenshotLoupe、screenshotToolbarAlign、
  screenshotKeepsColors、screenshotFindsElements、screenshotFindsWebElements、pinSelectsText、ocrJoinLines。
- 体检 N2（延时截图）要是加了设置：一般人会碰的放外面，否则进高级。

### 2.4 录制（RecordTab.swift）——第 2 批

外面：启用录制 → 保存到 → 录屏（清晰度、开始前倒数、显示光标、麦克风）→ 录音（来源）→ 按键行 → 「高级…」。

| 行 | id | 键 | 去哪 | 关键词 |
|---|---|---|---|---|
| 启用录制 | enabled | （功能开关） | 外 | |
| 保存到 | saveFolder | screenshotSaveDirectory | 外 | 保存,文件夹 |
| 清晰度 | sharpness | screenRecordSharpness | 外 | 清晰度,分辨率,画质,文件大小 |
| 开始前倒数 | countdown | screenRecordCountdown | 外 | 倒数 |
| 显示光标 | cursor | screenRecordShowsCursor | 外 | 光标 |
| 麦克风 | microphone | screenRecordMicrophoneDevice（不注册） | 外 | 麦克风,输入 |
| 来源 | audioSource | audioRecordSource | 外 | 录音,系统声音,麦克风,来源 |
| 录屏和录音的按键 | keys | — | 外 | 按键,速查 |
| 帧率 | frameRate | screenRecordFrameRate | 高 | 帧率,fps |
| 编码 | codec | screenRecordCodec | 高 | 编码,H.264,HEVC,体积 |
| 显示按键时 | keysShown | screenRecordKeysShortcutsOnly | 高 | 按键,只显示快捷键 |
| 按快捷键后立即开始录音 | startsImmediately | audioRecordStartsImmediately | 高 | 立即开始,控制条 |

- 高级表单恢复默认管：screenRecordFrameRate、screenRecordCodec、screenRecordKeysShortcutsOnly、audioRecordStartsImmediately。

### 2.5 翻译（TranslateTab.swift）——第 3 批

外面：启用翻译 → 语言 → 翻译服务（列表）→ 行为（复制即译、自动复制译文、浮窗位置）→「查词与发音 ›」「翻译历史 ›」→ 按键行 → 「高级…」。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 启用翻译 | enabled | （功能开关） | 外 | | |
| 第一语言 / 第二语言 | first / second | translateFirst / translateSecond | 外 | 语言,第一语言,第二语言 | 互换逻辑照旧 |
| 翻译服务 | services | （服务列表） | 外 | 服务,密钥,智谱,OpenAI,DeepL,Google,AI,模型 | S8 翻译入口描它（组标题那一块） |
| 复制即译 | copyToTranslate | translateCopyToTranslate | 外 | 复制即译 | |
| 自动复制译文 | autoCopy | translateAutoCopy | 外 | 自动复制 | |
| 浮窗位置 | panelPosition | translatePanelPosition | 外 | 位置,浮窗位置 | |
| 查词与朗读 › | lookup | — | 外，推进 子:查词与朗读 | 查词,词典,单词,发音,朗读 | value：「词典 · 美音」类：系统词典开着写「词典」、发音写选单当前那一项的短名 |
| 翻译历史 › | history | — | 外，推进 子:翻译历史 | 历史,导出,CSV,Anki,清空 | value：开「最多 5000 条」/「不限」/ 关「关」 |
| 翻译浮窗里的按键 | keys | — | 外 | 按键,速查 | |
| 译文字号 | fontScale | translateFontScale | 高 | 字号,大小 | 真卡片预览跟着进表单 |
| 面板大小 | panelSize | （这台电脑的） | 高 | 面板大小 | |
| 翻译前把同一段里的换行接起来 | joinLines | translateRemoveNewlines | 高 | 换行,PDF | |
| 截图翻译时把译文直接盖回截图上 | overlay | translateScreenshotOverlay | 高 | 截图翻译,盖回 | NewTitle 0.7.2 照旧 |
| 截图翻译时复制识别出的原文 | copyRecognized | translateCopyRecognized | 高 | 截图翻译,原文 | |

- **子:查词与朗读**（`sub:translate.lookup`，原「朗读」组的「朗读速度」也在这里）：查单个词时显示系统词典的释义（`lookup.systemDictionary`）、
  查单个词时大模型按词典回答（`lookup.wordMode`）、系统词典的中文释义 / 打开「词典」（`lookup.openDictionary`）、
  英文单词发音（S6，`lookup.pronunciation`）。恢复默认管：translateSystemDictionary、translateWordMode、translateWordRecording、translateWordAccent。
- **子:翻译历史**（`sub:translate.history`）：记录翻译历史（`history.enabled`）、历史最多保留（`history.limit`）、导出…（`history.export`）、
  清空翻译历史…（`history.clear`）。照旧：关着翻译也能导出、清空，保留条数不套 gated。恢复默认只管 translateHistoryEnabled。
- 高级表单恢复默认管：translateFontScale、translateRemoveNewlines、translateScreenshotOverlay、translateCopyRecognized。
- 路由：服务 id 照旧推 `TranslateServiceDetail`；`sub:` 开头的推子页。

### 2.6 启动器（LauncherTab.swift、ScriptsSection.swift）——第 3 批

外面：启用启动器 → 搜索（列出常用、搜快捷指令）→ 浏览器书签与历史 → 文件搜索（授权行）→
「应用别名 ›」「网页搜索与快捷链接 ›」「脚本命令 ›」「命令和别名 ›」→ 按键行 → 「高级…」。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 启用启动器 | enabled | （功能开关） | 外 | | |
| 空搜索框里列出常用 | frequent | launcherShowsFrequent | 外 | 常用,最近,使用记录,收藏 | NewTitle 0.7.2；S8 启动器入口描它 |
| 搜索快捷指令 | shortcuts | launcherShortcuts | 外 | 快捷指令,Shortcuts | |
| 浏览器书签与历史 | browsers | launcherBrowserBookmarks, launcherBrowserHistory | 外 | 书签,浏览历史,浏览器,Safari,Chrome,Edge,Arc,Brave,Firefox,完全磁盘访问 | 每家一行照旧，登记成一项（锚在这一组的第一行） |
| 桌面、文稿、下载、iCloud 云盘（文件搜索） | fileSearch | — | 外 | 文件,open,find,Spotlight,文件夹授权 | |
| 应用别名 › | appAliases | —（列表） | 外 | 别名,应用别名 | 照旧（副标题） |
| 网页搜索与快捷链接 › | webSearch | —（列表） | 外 | 搜索,引擎,快捷链接,关键词,兜底 | 照旧 |
| 脚本命令 › | scripts | — | 外，推进 子:脚本命令 | 脚本,脚本命令,AI,新建脚本 | **初稿是留在外面，这里改成推进**（§12）；value：开「n 个脚本」，有读不成的橙「n 个有问题」；关「关」。NewTag 0.8.0 `launcher-scripts` |
| 命令和别名 › | commands | —（列表） | 外 | 命令,别名,系统命令 | 照旧 |
| 启动器里的按键 | keys | — | 外 | 按键,速查 | |
| 呼出时切到英文输入法 | romanInput | launcherRomanInput | 高 | 英文,输入法 | |
| 面板位置 | panelPosition | launcherPanelPosition | 高 | 位置,面板位置 | |
| 面板大小 | panelSize | （这台电脑的） | 高 | 面板大小 | |
| 清空使用记录… | clearUsage | — | 高 | 使用记录,清空 | 不 gated |

- **子:脚本命令**（`sub:launcher.scripts`）：`ScriptsSection` 第一节整段搬进去（启用脚本命令、怎么写脚本 ›、让 AI 来写、脚本文件夹、
  用例子新建、其他文件夹、拖进来导入、读不成的脚本）；「命令」那一节（命令和别名 ›）留在外面，拆成 `ScriptsSection` 之外的一行。
  拖进来导入的那块、导入前看全文的 sheet 照旧。id：`scripts.enabled`、`scripts.guide`、`scripts.ai`、`scripts.folder`、`scripts.example`、
  `scripts.otherFolders`、`scripts.import`。恢复默认只管 launcherScripts。
- 高级表单恢复默认管：launcherRomanInput、launcherPanelPosition。

### 2.7 便签（NotesTab.swift）——第 3 批

外面：便签（正文字号、行距、Markdown 样式）→ 打开全部便签… → 「屏幕边缘 ›」→ 数据（导出、导入）→ 按键行 →「关于这个插件」。
**没有「高级…」**（初稿就是「—」）。这一页改成 `NavigationStack`。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 正文字号 | fontSize | notesFontSize | 外 | 字号,字体大小 | 初稿没写，留外面（§12）；S8 便签窗口入口描它 |
| 行距 | lineSpacing | notesLineSpacing | 外 | 行距,行高,间距 | 同上 |
| Markdown 样式 | markdown | notesMarkdown | 外 | Markdown,粗体,斜体,链接,代码块 | |
| 打开全部便签… | openAll | — | 外 | 全部便签,归档,最近删除 | |
| 屏幕边缘 › | deck | — | 外，推进 子:屏幕边缘 | 屏幕边缘,边缘,药丸,标签 | 初稿外面的「在屏幕边缘显示便签（行尾写开着 · 右边）」和子页合成这一行：value「开着 · 右边」/「开着 · 左边」/「关」；总开关是子页第一行 |
| 导出为 Markdown | export | — | 外 | 导出,Markdown,备份 | 不 gated |
| 从 Markdown 导入 | import | — | 外 | 导入 | 不 gated |
| 便签的按键 | keys | — | 外 | 按键,速查 | |

- **子:屏幕边缘**（`sub:notes.deck`）：在屏幕边缘显示便签（`deck.enabled`）、位置、显示器（多屏才有）、样式、大小、感应范围、一直展开、
  不显示药丸、悬停预览、悬停即打开、盖在全屏 App 上、便签大小；id 照键名（`deck.edge`、`deck.display`、`deck.style`、`deck.size`、`deck.sense`、
  `deck.alwaysFanned`、`deck.hidesPill`、`deck.preview`、`deck.opensOnHover`、`deck.overFullScreen`、`deck.noteSize`）。依赖关系照旧
  （总开关关着下面停用、一直展开时「不显示药丸」停用、悬停即打开时「悬停预览」停用）。恢复默认管这 12 个键里注册了的
  （notesDeckChosenDisplay 不注册，不动）。

### 2.8 刘海岛（IslandTab.swift → 拆出 Settings/IslandPages.swift）——第 3 批

外面：S10 舞台 → 点刘海（点刘海打开、停在刘海上自动展开、停多久展开、列出最近的提示）→「快捷动作 ›」→
活动（「正在播放 ›」「日程与月历 ›」「音量与亮度 ›」「专注模式 ›」「系统提示 ›」）→「高级…」→「关于这个插件」。
这一页改成 `NavigationStack`；子页太多，挪进新文件 `Settings/IslandPages.swift`（一个文件放刘海岛的子页）。

| 行 | id | 键 | 去哪 | 关键词 | 备注 |
|---|---|---|---|---|---|
| 点刘海打开 | notchClicks | islandNotchClicks | 外 | 点刘海,那一张 | S10 场景 |
| 停在刘海上自动展开 | hoverExpands | islandHoverExpands | 外 | 自动展开,悬停 | S10 场景 |
| 停多久展开 | hoverDelay | islandHoverDelay | 外 | 多久 | 跟着上一行停用 |
| 列出最近的提示 | history | islandShowsHistory | 外 | 最近的提示,通知 | |
| 快捷动作 › | actions | islandActionOrder, islandActionsOff | 外，推进 子:快捷动作 | 快捷动作,排序 | 初稿写留外面，拍板页示意里是推进行，照示意（§12）；value「开着 n 个」 |
| 正在播放 › | media | — | 外，推进 子:正在播放 | 正在播放,音乐,封面,切歌 | value 开着 / 关；NewTag 0.9.0 `island-now-playing`；S10 场景 |
| 日程与月历 › | calendar | — | 外，推进 子:日程与月历 | 日程,日历,月历,会议,整点 | value「开着 n 样」/「关」（数 下一个日程、月历、整点报时） |
| 音量与亮度 › | levels | — | 外，推进 子:音量与亮度 | 音量,亮度,静音 | value 开着 / 关；开着却接不住（体检 U6 的状态）橙「接不住按键」；S10 场景 |
| 专注模式 › | focus | — | 外，推进 子:专注模式 | 专注模式,勿扰,睡眠 | value 开着 / 关 |
| 系统提示 › | notices | — | 外，推进 子:系统提示 | 电源,电量,耳机,断网,低电量 | value「开着 n 样」/「关」 |
| 提示停多久 | noticeLength | islandNoticeLength | 高 | 提示,多久 | 初稿没写，进高级（§12） |
| 触感反馈 | haptics | islandHaptics | 高 | 触感 | |
| 展开时模糊四周 | blur | islandBlur | 高 | 模糊 | |
| 描一圈细边 | outlined | islandOutlined | 高 | 细边,轮廓 | |
| 全屏时藏起来 | hidesInFullScreen | islandHidesInFullScreen | 高 | 全屏 | |
| 截图、录屏时不显示刘海岛 | hidesFromCapture | islandHidesFromCapture | 高 | 截图,录屏 | |

- **子:快捷动作**（`sub:island.actions`）：那张有序列表原样搬进去。恢复默认管 islandActionOrder、islandActionsOff。
- **子:正在播放**（`sub:island.media`）：在刘海上显示正在播放、换歌时显示歌名、跳动条和进度条的颜色、播放卡片上显示收藏按钮、
  正在用放歌的 App 时不显示。恢复默认管 islandNowPlaying、islandTrackPeek、islandMediaColor、islandMusicFavorite、islandNowPlayingHidesWhenActive。
- **子:日程与月历**（`sub:island.calendar`）：下一个日程（授权流程、橙字照旧）、日程开始时响一声、整点报时、显示月历、
  月历上标出有日程的日子、用日历的颜色、显示已拒绝的日程、选择日历。`didBecomeActive` 时重查授权那段跟着挪进来。
  恢复默认管 islandEventChime、islandHourlyChime、islandCalendar、islandCalendarDots、islandCalendarColors、islandShowDeclined
  （islandNextEvent、islandHiddenCalendars 不注册，不动）。
- **子:音量与亮度**（`sub:island.levels`）：显示在刘海上、停多久、细条用强调色、细条旁边显示百分比、授权橙字（+ 体检 U6 的状态行）。
  恢复默认管 islandLevelStay、islandLevelAccent、islandLevelPercent（islandKeyLevels 不注册，不动）。
- **子:专注模式**（`sub:island.focus`）：五个开关原样。恢复默认管 islandFocus、islandFocusPinned、islandFocusSleepSound、islandFocusWaveform、islandFocusQuiet。
- **子:系统提示**（`sub:island.notices`）：五个开关原样。恢复默认管这五个键。
- 高级表单恢复默认管：islandNoticeLength、islandHaptics、islandBlur、islandOutlined、islandHidesInFullScreen、islandHidesFromCapture。

### 2.9 不重排的页（第 1 批挂登记，第 4 批收文字）

全部插件、提醒、状态屏、启动台、程序坞预览、访达右键、保持唤醒、睡眠关蓝牙、平滑滚动、App 快捷键、快捷键、关于：行不动，
每行挂 `.settingsAnchor`、登记（place 都是 `.page`，或者它们已有的推进页里的就挂在那一页，如提醒详情不登记——那是一条条数据）。
id 用 `<页>.<键名去掉页前缀>`。快捷键页登记组（剪贴板与启动器 / 翻译 / 截图与录制 / 截图时 / 在这些 App 里停用），不登记每个动作
（动作名已经进了页的搜索词）。

## 3. S6：三个合并的选单（偏好键不动）

三个都是纯函数：`init(a, b)` 从两个键读出选项、`func writes(from old) -> [(key, value)]` 只给出**变了的那个键**（没变的不写进持久域，
同步不会把它当成刚改的；ClipboardTab.swift:185 同一条）。各放在自己那一页的文件里（`ClipboardTab.AutoClear`、
`ScreenshotTab.ElementDetection`、`TranslateTab.WordVoice`），单测把两个键的全部组合读一遍、每对「旧 → 新」写一遍。
选项文字都长，英文横排放不下：三个都用弹出菜单（mac-whisker「3–5 项用单选」那条补一句例外，§8）。

**① 自动清空普通历史**（剪贴板，ClipboardTab.swift:96–97 两行合一）

| 选项 | 英文 | clipboardClearOnQuit | clipboardClearOnLock |
|---|---|---|---|
| 从不（默认） | Never | false | false |
| 退出 App 时 | When Quitting | true | false |
| 锁屏时 | When Locked | false | true |
| 退出或锁屏时 | Quitting or Locked | true | true |

不套 `gated`（管数据，同现在）。`SettingsArchive.privacyLosses`（SettingsArchive.swift:861）读的还是这两个键，不用动。

**② 悬停时识别**（截图，ScreenshotTab.swift:143–160 两行合一）

| 选项 | 英文 | screenshotFindsElements | screenshotFindsWebElements |
|---|---|---|---|
| 关（默认） | Off | false | 不写（读的时候 false 才算「关」：finds 为 false 一律显示「关」） |
| 窗口里的元素 | Elements in Windows | true | false |
| 连网页里的也认 | Web Pages Too | true | true |

开着（不是「关」）又没辅助功能授权时，下面照旧一行 `PermissionRow`（ScreenshotTab.swift:147）。
`RegionSelector.elementsAllowed / webElementsAllowed` 读的还是这两个键，不用动。

**③ 英文单词发音**（翻译，TranslateTab.swift:138–142 两行合一）——**用户 11-18 定了四项**（和拍板的三项不一样，§12 Q1）

原来的「美音 / 英音」不只管真人录音，也管取不到录音、或关了真人发音时用的系统声音（Speaker.swift:53 `voice(for: "en-GB" / "en-US")`）。
拍板写的「系统 / 真人美音 / 真人英音」三项里，「系统」读不出也改不了是美式还是英式（选「系统」时 accent 不写，留着上次的）。所以做成四项：

| 选项 | 英文 | translateWordRecording | translateWordAccent |
|---|---|---|---|
| 真人 · 美音（默认） | Human · US | true | us |
| 真人 · 英音 | Human · UK | true | uk |
| 系统声音 · 美音 | System · US | false | us |
| 系统声音 · 英音 | System · UK | false | uk |


## 4. S11：页头那一句（第 2 批全部换，中英）

不罗列，一句话说这页管什么；找某一项交给搜索。改的是 `SettingsPage.summary`（SettingsWindow.swift:193–215）。

| 页 | 新的一句 | English |
|---|---|---|
| 通用 | 这台 Mac 上 Kitty Tools 的样子、启动和授权 | How Kitty Tools looks, starts, and what it can access |
| 全部插件 | 不变（用得上的再添加；移除了，设置和数据也留着） | unchanged |
| 刘海岛 | 点刘海叫出什么，刘海两边挂什么 | What the notch opens, and what shows beside it |
| 剪贴板 | 剪贴板历史留多久、怎么粘贴、哪些不记 | How long Clipboard History keeps items, how it pastes, what it skips |
| 启动器 | 一个搜索框打开 App、文件、网页和命令 | Open apps, files, web pages, and commands from one search field |
| 启动台 | 全屏的图标网格怎么排、怎么打开 | How the full-screen app grid is laid out and opened |
| 截图 | 截完的图放哪、怎么拷、留不留历史 | Where screenshots go, how they’re copied, and the history |
| 录制 | 录屏的画质和声音，录音录什么 | Screen recording quality and sound, and what audio recordings capture |
| 便签 | 便签长什么样、放在屏幕哪里 | How notes look and where they sit on screen |
| 状态屏 | 拦住键盘鼠标的全屏告示 | A full-screen notice that blocks the keyboard and mouse |
| 提醒 | 到点提醒你，时间和方式你来定 | Reminders at the times and in the ways you choose |
| 程序坞预览 | 停在程序坞图标上时弹出窗口缩略图 | Window thumbnails when you hover over a Dock icon |
| 访达右键 | 在访达里右键多出来的几项 | Extra items when you right-click in Finder |
| 保持唤醒 | 不让电脑睡、不让屏幕熄（去掉开头的「插件 · 」） | Keeps your Mac and display awake |
| 睡眠关蓝牙 | 电脑睡下去时关蓝牙，醒来再打开 | Turns Bluetooth off while your Mac sleeps |
| 平滑滚动 | 让鼠标滚轮滑着滚 | Makes the mouse wheel glide |
| App 快捷键 | 按住一个键，看当前 App 的全部快捷键 | Hold a key to see the current app’s shortcuts |
| 翻译 | 翻成什么语言、用哪些服务、怎么弹出来 | Which languages and services, and how translations appear |
| 快捷键 | 不变（所有全局快捷键） | unchanged |
| 关于 | 不变（版本与更新内容） | unchanged |

子页和「高级…」表单的页头说明：子页是一句现在的状态（同推进行的 value）；表单的那句见 §5 各页「高级 页头」。

## 5. S5：说明文字（第 4 批，所有页中英）

**写法**（第 4 批先改进 mac-whisker/settings.md「设置页的说明文字」，再照着改页面）：

- 行副标题只留一句：中文 ≤ 20 个字、英文在 11 pt 下一行放得下（约 55 个字符），不加句号；**不写原理**。行名已经说清楚的不写副标题。
- 原理、隐私、耗电、具体规则、举例挪进行尾 ⓘ（§1.6）：句子照原文、可以合并几处，每句加句号；英文照现有英文同样删改，不另起炉灶。
- 解释一整组的挪进组标题的 ⓘ。页脚只留三种：要授权、会删数据 / 不能撤销、文件不加密；留下的也压成一句。
- 状态类的字（「已读到 N 条书签」「还没允许…」橙字、「最多 N 条，已经满了」）不是说明，照旧。
- 设置里的位置写成路径：子页写「设置 › 通用 › 同步」，「高级…」里的写「设置 › 截图 › 高级」（§7 的表同一个口径）。

下表：「—」= 不写副标题；ⓘ 一栏写中文要点（句子大多就是原文那几句），英文照现有译文改。表里没列的行副标题照旧。

### 5.1 通用

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 语言 | —（要重开时照旧「重新打开 Kitty Tools 后换成新的语言」） | — | 也可以在 系统设置 › 通用 › 语言与地区 › 应用程序 里选。 |
| 强调色（选了颜色时） | 菜单高亮和焦点环仍跟系统 | Menus and focus rings follow the system | 菜单高亮和焦点环由系统绘制，仍使用系统强调色。（跟随系统时那句照旧） |
| 高级 页头 | 不常改的外观和图标 | Appearance and icons you rarely change | |
| 呼出面板时挤压弹开 | 面板从小一点弹到原尺寸 | Panels spring open from slightly smaller | 剪贴板、启动器和翻译浮窗都这样；减弱动态效果时不弹。 |
| 在菜单栏显示图标 | 隐藏后快捷键照常能用 | Shortcuts still work when it’s hidden | 隐藏后，再打开一次 Kitty Tools（在启动器或访达里）会打开主界面。 |
| 在程序坞显示图标 | 关掉后面板可能接不到键盘 | Turning it off can stop panels getting keys | 原副标题全文。 |
| 数据目录 | 数据库、图片和每日备份都在这里 | Databases, images, and daily backups | — |
| 辅助功能（子:权限） | 粘贴回原 App、划词翻译这些要它 | Needed to paste back, translate selections, and more | 完整清单（原副标题）。 |
| 屏幕录制（子:权限） | 截图、录屏、识字要它 | Needed for screenshots, recordings, and text capture | 完整清单；授权后可能要重新打开本 App 才生效。 |
| 剪贴板访问（子:权限） | 后台记录剪贴板历史要它 / 被拒：已被拒绝，剪贴板历史不再记新的 | Needed to record Clipboard History / Denied: Clipboard History stops recording | 到 系统设置 › 隐私与安全性 › 从其他 App 粘贴 里改成「始终允许」。 |
| 子:同步 | 页脚只留「同步文件夹里是不加密的文本文件和图片，能打开它的人都看得到。」，其余进「同步」组标题的 ⓘ；「设置」一类 → 各页的设置、快捷键和功能开关（ⓘ：启动台、录音的麦克风、菜单栏图标这些跟着这台 Mac 的不同步）；「翻译服务」→ 服务、顺序和设置，密钥不同步；「提醒」→ 提醒和各自的时间，几台都会响；「启动器收藏」→ 空搜索框里收藏的那几个（ⓘ：这台没装的 App 不显示，装上就回来）。体检改完 SyncSection 再收，以那时的字为准 | | |
| 设置与数据（子:备份） | 存成一个文件，换电脑、重装后导回来 | Save to one file to bring back later | 七类清单 + 原页脚（普通历史、图片和文件类的收藏不在文件里；截图的存储文件夹、登录时打开和系统权限要在新电脑上重新设）。 |
| 每天自动备份 | 每天在这台 Mac 上存一份，留 7 份 | Saves a copy on this Mac daily, keeping 7 | 导入前也会先存一份，设置和快捷键导错了能换回去。不含密钥。 |
| 另存一份到 | 没选：再存一份到别处，文件不加密；选了：每天那份也存到这里，文件不加密 | Also save a copy elsewhere; not encrypted / Today’s copy is saved here too; not encrypted | 选了时：文件名末尾的 3F9A 是这台 Mac 的编号，几台 Mac 可以共用一个文件夹。「不加密」留在副标题里（S5 页脚的例外：它就是那句必须先知道的） |

### 5.2 剪贴板

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 保留普通历史 | — | — | 收藏和片段一直留着，不算在里面。（原页脚） |
| 图片最多占用 | — | — | 只算普通历史里的图片，收藏的不算。 |
| 单击条目直接粘贴 | 点一下就粘贴，不用双击 | One click pastes, no double-click | 想先看内容用 ↑↓；⌘ 单击、⇧ 单击照常多选。 |
| 默认粘贴为纯文本 | ↩ 粘贴纯文本，⌥↩ 保留格式 | ↩ pastes plain text, ⌥↩ keeps formatting | 文字的格式总是记下来。 |
| 自动清空普通历史 | 收藏和片段不清 | Favorites and snippets are kept | — |
| 不记录这些 App（组标题） | 页脚删 | | 密码管理器通常会自己标记「不要记录」，这里只是兜底。 |
| 高级 页头 | 面板的样子和图片里的字 | How the panel looks, and text in images | |
| 显示透镜 | 选中的条目在原地展开预览 | The selected item expands into a preview | 关掉就是纯列表，一屏多露出几行。 |
| 链接显示网页标题和图片 | 选中链接时联网读取 | Loads from the web when you select a link | 本机、内网和带登录令牌的网址不读。 |
| 面板位置 | — | — | 屏幕上方是鼠标所在屏幕的上方正中，跟随鼠标是光标旁边，上次位置是上次拖到的地方。 |
| 面板大小 | 拖面板的边改大小 | Drag the panel’s edges to resize | 拖左右两边改宽度，拖下边改最多显示几行。 |

### 5.3 截图

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 快速保存到 | 录屏、录音也存这里 | Recordings are saved here too | 原页脚前三句（⌘S、文件名、没选过时跟随系统）。 |
| 截图拷贝为 | 选 PNG 文件能粘进聊天和文件夹 | PNG File pastes into chats and folders | 原副标题其余（和拷贝一个文件一样…只收图像的程序粘不进去）。 |
| 截完图放哪 | 按选项：角落留一张缩略图 / 挂到屏幕顶上的绳子上，最多 8 张 / 只在右下角闪一下，照样进历史 | A thumbnail stays in the corner / Hangs on a line at the top, up to 8 / Just flashes; still saved to history | 角落能拖出、钉图、存储；晾衣绳那段原页脚（滑下来、单击拷贝…取下不删历史）。页脚删。 |
| 截图时播放快门声 | — | — | 原页脚全文。 |
| 保留截图历史（子:截图历史） | 能回头改标注、再钉一次 | Edit annotations or pin again later | 截图、长截图、录屏录音都留在这里；打码会直接打进存下的图。历史只在这台 Mac 上，不跟着同步。 |
| 子:截图历史 页脚 | 超过保留期或占用时先删最旧的；存到文件夹里的不动。 | When over the limit, the oldest go first; files saved to folders stay. | （会删数据：留） |
| 改按键 | 截图时的按键能自己改 | You can change keys used while capturing | — |
| 高级 页头 | 框选和识别的细节 | Details for selecting and detecting | |
| 截图带上鼠标指针 | — | — | 带上的是按快捷键那一刻的指针；识字、截图翻译不带。 |
| 截图、录屏时隐藏桌面图标 | — | — | 桌面上的文件不进截图和录屏，桌面本身照常；录屏中访达新弹出的菜单、窗口最多晚 1 秒才录进去。 |
| 框选时显示操作提示 | 开始框选时屏幕上方的一行提示 | A hint line at the top as you start | 拖动框选、单击选中、双击直接拷贝这些，3 秒后自己淡出。 |
| 框选时的放大镜 | 按 C 拷贝放大镜下的色值 | Press C to copy the color below it | 不显示色值时 C 不取色，标注里的吸管照常能取。 |
| 工具栏位置 | 框选完工具栏贴在选区下方 | The toolbar sits below the selection | 放不下时在上方。靠右时从左上往右下拖完，✓ 就在鼠标旁边；录屏的录制条也这样摆。 |
| 框选时保持屏幕原色 | 不压暗、不染色，取色时打开 | No dimming or tint, for picking colors | 悬停的窗口只描边、不染色，放大镜正中的像素也不染色。 |
| 悬停时识别 | 停在侧栏、按钮上就框出那一块 | Outlines sidebars, buttons, and more | 单击截下；滚轮往上换大一块、往下换小一块，Tab 只认整扇窗口；游戏这类自己画界面的认不出来。选「连网页里的也认」时，第一次停到浏览器上会请它打开辅助功能（只有位置和名字的那一档），一直开到它退出，可能让它稍慢一点。 |
| 钉图上的字可以直接选 | 在钉图的字上拖动就是选字 | Drag over text on a pin to select it | ⌘C 拷贝。空白处照旧拖着挪，按住 ⌥ 在哪都能挪。 |
| 识字后把同一段里的换行接起来 | — | — | 原页脚全文。 |

### 5.4 录制

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 保存到 | 和截图的「快速保存到」是同一个 | Same folder as Screenshot’s Quick Save | 文件名是「录屏 日期 时间.mp4」「录音 日期 时间.m4a」。（原页脚） |
| 清晰度 | 标准：文件小一半，小字糊一些 | Standard: half the size, softer small text | 标准清晰度在高分屏上宽高各减半。录好的也可以在角落的缩略图上点「压缩」另存一份小的。 |
| 麦克风 | 录制条上的麦克风开着时用哪个 | Which mic the recording bar uses | 选的那个没接着时这次用系统默认的；录音照旧用系统默认的输入。 |
| 来源 | — | — | 录系统声音时菜单栏会出现屏幕录制指示；锁屏会停止；不能暂停。 |
| 录屏和录音的按键 | ↩ 开始，再按一次快捷键停止 | ↩ starts; press the shortcut again to stop | 框选和截图一样，双击选区也开始，Esc 取消。 |
| 高级 页头 | 文件大小和录音怎么开始 | File size, and how audio recording starts | |
| 帧率 | — | — | 60 fps 更顺，文件大约大一半；大屏上可能录不满 60。 |
| 编码 | — | — | HEVC 同样的画面小三分之一左右，部分 App 和旧设备可能放不了。 |
| 显示按键时 | — | — | 只显示快捷键：带 ⌘ ⌃ ⌥ 的组合键、Esc 和 F 键才进画面，打字不显示。 |
| 按快捷键后立即开始录音 | 关着时先出录音控制条 | When off, the audio bar opens first | 按快捷键（或点菜单栏、启动器里的「录音」）先在屏幕底部打开录音控制条，点 ● 或再按一次才开始录。 |

录屏、录音两段页脚都拆完、删掉。

### 5.5 翻译

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 语言（组标题） | 页脚删 | | 原页脚全文（「自动」怎么选、在浮窗顶部切换）。 |
| 翻译服务（组标题） | 页脚删 | | 原页脚全文（拖动排序、排最前的写历史、删掉的能加回）。 |
| 复制即译 | 复制文字就弹出翻译 | Copying text pops up a translation | 网址、路径和数字不翻。 |
| 自动复制译文 | — | — | 复制即译弹出的翻译不会自动复制，免得覆盖你刚复制的原文。（原来是悬停提示） |
| 浮窗位置 | — | — | 原副标题全文。 |
| 翻译浮窗里的按键 | ↩ 翻译，⌘1–9 复制结果，⌘Y 看历史 | ↩ translates, ⌘1–9 copies, ⌘Y history | ⌘R 重新翻译；划词来的翻译可以「替换原文」。 |
| 系统词典的释义（子:查词与发音） | — | — | 查单个词时不自动复制、不给「替换原文」。（原「查词」页脚） |
| 系统词典的中文释义 | 想看中文释义，在「词典」里换词典 | Change dictionaries in Dictionary for Chinese | 原副标题全文。 |
| 英文单词发音 | 真人发音会把单词发给有道 | Human voices send the word to Youdao | 取不到时用系统声音。句子用系统声音，可以在 系统设置 › 辅助功能 › 朗读内容 里下载音质更好的声音。 |
| 历史最多保留（子:翻译历史） | — | — | 收藏的记录不算在保留条数里、永不清理。 |
| 高级 页头 | 字号、换行和截图翻译 | Text size, line breaks, and screenshot translation | |
| 面板大小 | 拖浮窗的边改大小 | Drag the panel’s edges to resize | 原副标题全文。 |
| 截图翻译时把译文直接盖回截图上 | 译文盖回原处，能接着标注 | Translations go back onto the image | 原副标题其余。 |
| 截图翻译时复制识别出的原文 | 识别出的原文放进剪贴板 | Recognized text goes on the clipboard | 跟着「自动复制译文」的两种说法照旧，挪进 ⓘ。 |

### 5.6 启动器

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 空搜索框里列出常用 | 关掉后只有搜索框和收藏 | When off, just the search field and favorites | 原「使用记录」页脚（怎么排、⌘D、⌘⌫、⌘Z）+ 关掉后排序照样按用过的学。 |
| 搜索快捷指令 | 打快捷指令的名字就能运行 | Type a shortcut’s name to run it | 不带输入；改了快捷指令，下次打开启动器时跟上。 |
| 浏览器书签与历史（组标题） | 页脚删 | | 只列这台 Mac 上装了的浏览器。 |
| 文件搜索授权行 | 状态照旧 | | 原「文件搜索」页脚全文。 |
| 网页搜索（页脚） | 删，那句挪到 WebSearchPage 的页头说明里 | | |
| 子:脚本命令 页脚 | 脚本以你的身份运行、能用 Kitty Tools 已有的授权，只放信得过的。 | Scripts run as you with Kitty Tools’ permissions; only add ones you trust. | 组标题 ⓘ：从网上下载的，第一次运行前先给你看一眼全文；Kitty Tools 自带的大功能是插件，在 设置 › 全部插件 里添加。 |
| 启用脚本命令 | 每个脚本是启动器里的一条命令 | Each script becomes a Launcher command | — |
| 让 AI 来写 | 把写法说明给 AI，再从剪贴板新建 | Give the guide to an AI, then create from the clipboard | 原副标题其余。 |
| 用例子新建 | 用查天气的例子新建一个 | Create one from the weather example | 原副标题其余。 |
| 其他文件夹 | 几台 Mac 共用的脚本文件夹，只读 | A shared scripts folder, read only | 比如放在 iCloud 云盘里的；不往里写。 |
| 命令（页脚） | 删（推进页里有） | | |
| 启动器里的按键 | ↩ 打开，⌘K 看全部操作 | ↩ opens, ⌘K shows all actions | 能搜什么（原副标题前半）。 |
| 高级 页头 | 输入法、面板和使用记录 | Input source, panel, and usage history | |
| 呼出时切到英文输入法 | 只在搜索框里，离开后恢复 | Only in the search field, then switched back | 要搜中文时先关掉。 |
| 面板位置 / 面板大小 | 同剪贴板 | | |

### 5.7 便签

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 正文字号 | 所有便签里正文的大小 | Size of note text everywhere | — |
| 行距 | 所有便签里正文的行距 | Line spacing of note text everywhere | — |
| Markdown 样式 | 写法显示成样式，光标那行露出标记 | Markdown shows as styles; marks show on the cursor’s line | 认哪些写法（原副标题，verbatim 照旧）。 |
| 在屏幕边缘显示便签（子:屏幕边缘） | 有了第一条便签才出现 | Appears once you have a note | 关掉后便签照样能从快捷键、启动器和全部便签窗口打开。 |
| 屏幕边缘（组标题） | 页脚删 | | 原页脚全文（药丸、⌥ 拖、右键、固定、拖出来浮着）。 |
| 悬停预览 | 停在标签上时显示开头几行 | Shows the first lines when you rest on a tab | — |
| 导出为 Markdown | 每条一个 .md 文件，图片放在旁边 | One .md file per note, images alongside | — |
| 从 Markdown 导入 | 导回导出过的不会重复 | Re-importing an export won’t duplicate | 别处的 .md 文件每个变成一条新便签。 |
| 数据（组标题） | 页脚删 | | 原页脚，路径改成 设置 › 通用 › 备份与导出导入、设置 › 通用 › 同步。 |
| 便签的按键 | 快速记一条和便签窗口里的按键 | Keys for Quick Note and note windows | — |

### 5.8 刘海岛

| 行 | 新副标题 | English | ⓘ |
|---|---|---|---|
| 点刘海打开 | 停上去鼓起一点，点一下打开 | Hover to bulge, click to open | 两指往下滑也行；挂着东西时打开它的卡片，没有时是快捷动作。装了别的刘海 App 时可以关掉（原第四组页脚）。 |
| 停在刘海上自动展开 | 停一下就展开，不用点 | A brief hover expands it | 原副标题全文。 |
| 列出最近的提示 | 快捷动作下面列最近 10 条 | The last 10, below the quick actions | 本次启动以来的，新的在前；不列也不影响提示照常弹出。 |
| 快捷动作（子页组标题） | 页脚删 | | 原页脚全文。 |
| 在刘海上显示正在播放 | 刘海两边显示封面和跳动条 | Artwork and a waveform beside the notch | 音乐、播客、浏览器里的视频都认，点开能暂停、切歌、拖进度；原页脚（约 4 MB 的小进程、暂停 30 秒收起）。 |
| 播放卡片上显示收藏按钮 | 放「音乐」时卡片上一颗心 | A heart on the card while Music plays | 点了收藏这首；第一次点会问能不能控制「音乐」。 |
| 正在用放歌的 App 时不显示 | 切到放歌的 App 时收起 | Hides while you’re in the playing app | 原副标题其余。 |
| 子:日程与月历 页脚 | 要「日历」授权，打开「下一个日程」时会问一次。 | Needs Calendar access; you’re asked when you turn on the next event. | 组标题 ⓘ：原页脚其余（全天的、已拒绝的不算；只留在这台 Mac；月历不用授权）。 |
| 在刘海上显示下一个日程 | 开始前 10 分钟在刘海两边倒数 | Counts down beside the notch from 10 minutes before | 点开能加入会议、打开日历。 |
| 点刘海打开时显示月历 | 快捷动作下面一块这个月的日历 | This month’s calendar below the quick actions | 原副标题其余。 |
| 用日历的颜色 | 日程图标用它所在日历的颜色 | Event icons use their calendar’s color | — |
| 按音量键、亮度键时显示在刘海上 | 换掉系统自己的音量、亮度提示 | Replaces the system volume and brightness indicator | 按着 ⌥ 时照旧打开系统设置；原页脚其余（五个键、锁屏和外接显示器照旧）。 |
| 子:音量与亮度 页脚 | 要「辅助功能」授权。 | Needs Accessibility permission. | |
| 在刘海上显示专注模式 | 换模式时在刘海两边显示 2 秒 | Shows for 2 seconds when a Focus changes | 原页脚全文（都认哪些、读系统日志、约 4 MB 小进程）。 |
| 开着时一直挂在刘海上 | 开着时刘海左边一直有它的图标 | Its icon stays on the left while on | 放歌、倒数时先让给它们；点开能去专注模式设置。 |
| 专注模式时不弹系统提示 | 电源、电量、耳机、断网这几样不弹 | No power, battery, headphone, or network notices | 10% 和音量、亮度照常。 |
| 系统提示（子页组标题） | 页脚删 | | 原页脚全文。 |
| 高级 页头 | 刘海岛的手感和样子 | How the notch feels and looks | |
| 提示停多久 | 「已复制」这类提示停多久 | How long notices like “Copied” stay | 带按钮的、出错的跟着变长变短，进行中的不算。 |
| 触感反馈 | 切歌、展开时触控板轻轻一下 | A light trackpad tap when you skip or expand | — |
| 展开时模糊四周 | 卡片背后越靠近越模糊 | Blurs what’s behind the card | 系统设置里开着「降低透明度」时不模糊。 |
| 描一圈细边 | 深色桌面上也看得清轮廓 | Keeps the outline visible on dark desktops | — |
| 全屏时藏起来 | 刘海那块屏全屏时不出现 | Hidden when the notched screen is full screen | 看视频、玩游戏时，刘海岛和它的提示都不出现。 |

### 5.9 不重排的页（只收文字）

| 页 | 怎么收 |
|---|---|
| 提醒 | 列表、「稍后」、专注模式三段页脚 → 各自组标题的 ⓘ；「最多 N 条，已经满了…」留页脚（状态）。 |
| 状态屏 | 列表页脚 → ⓘ（满了那句留）；「直接进入」页脚 → ⓘ；「告示上的动画」副标题 → 关掉后表情不动、不做出场 / Emoji stay still, no entrance，其余和动画页脚 → ⓘ；「怎么退出」那一行照旧（就是要看的）；安全那段页脚只留「状态屏是告示加防误触，不是安全措施。」，其余 → ⓘ。 |
| 启动台 | 「启动器和启动台是两个东西」页脚、排法页脚、捏合页脚 → ⓘ；系统捏合开着、触发角被占的橙字照旧。 |
| 程序坞预览 | 页脚 → 「停多久再弹出」的 ⓘ。 |
| 访达右键 | 各组页脚 → 组标题 ⓘ；15.0 / 15.1 的命令橙字、iCloud 桌面的橙字照旧。 |
| 保持唤醒 | 两段页脚 → ⓘ。 |
| 睡眠关蓝牙 | 第一段页脚 → 组标题 ⓘ；第二段只留后果那句「睡着时蓝牙关着，用手表解锁、靠蓝牙的「查找」都用不了。」 |
| 平滑滚动 | 两段页脚 → ⓘ；和别的 App 冲突的橙字照旧。 |
| App 快捷键 | 页脚 → ⓘ。 |
| 快捷键、关于、全部插件 | 不动。 |

## 6. S10：悬停预览（第 5 批：框架 + 三个场景）

### 6.1 框架（新文件 `Settings/SettingsPreview.swift`；场景多了再拆 `Settings/PreviewScenes.swift`）

- **舞台** `PreviewStage(scene:)`：一块 16:7 左右的「小桌面」（宽跟着表单、高 120），放在**那一组的第一行之上、跟着表单一起滚**
  （不钉在页顶：页面短了以后舞台本来就在第一屏；钉住要占掉最小窗口 460 高里的 120）。桌面 = 外观缩略图那张渐变壁纸
  （`AppearanceThumbnail.desktop` 的配色，跟着当前深浅色）+ 顶上一条 7 pt 的菜单栏，圆角 card、0.5 pt 发丝线；里面放缩小的真界面。
  没停在任何一行上时画**这一页的静止帧**（当前设置下那个场景的最后一帧），不动。
- **认行**：有场景的行挂 `.previews(.placement)`：`onHover` 进来就把舞台换成它的场景、出去 0.3 s 后回到静止帧
  （行和行之间滑过不闪）；键盘焦点落在这一行的控件上时同样（`@FocusState` 跟着控件）。设置窗是普通窗口，`onHover` 可靠，不用 HoverTracker。
- **跟着设置走**：场景按这一行**现在的值**演（截完图放哪选的是晾衣绳就演晾衣绳）；值一改当场重演一遍。
- **只在看得见时动**：只在有行被停着 / 选着时用 `TimelineView(.animation)` 跑，别的时候是静止的一帧——设置窗在后台、
  被挡住、页面滚走了，鼠标都不会停在行上，自然不动；不另起定时器。一轮 1.6–2.4 s，演完停 0.6 s 再来。
- **减弱动态效果**：只给静止的一帧（演完的样子），不循环。**读屏**：整块 `accessibilityHidden(true)`（装饰，行的副标题已经说了效果）。
- **不碰真东西**：舞台里的一切是摆出来的——刘海岛用「摆出来的岛」`Island(showing:geometry:…)`（Island.swift:360：不建窗口、
  不给触感、不读本机状态，`isStaged`）；不放声音、不写偏好、不进最近的提示、不接点击（`.allowsHitTesting(false)`）。
- **几何跟着这台 Mac**：有刘海的屏（任一块 `safeAreaInsets.top > 0`）演刘海形体，没有的演浮着的胶囊（`.capsule(menuBar: 24)`）。

### 6.2 首批三个场景

1. **截完图放哪**（截图页外面，`screenshot.placement`；舞台在这一组顶上）。小桌面中间先闪一下选区框（品牌粉 1 pt），然后：
   - 角落的缩略图：一张卡（`Style.shotCard()` 那一套圆角、发丝线、阴影，里面一块渐变当截图）从选区飞到右下角缩小落定（`island` 弹簧），停 1 s；
   - 挂到晾衣绳上：菜单栏下面一根静止的悬链线（同 `clothesline-reduced` 的样子，不跑物理）、两张已挂着的卡，新的一张从上面落下挂上（`pop`），品牌粉夹子；
   - 都不要：右下角一块白闪 0.12 s 淡掉。
   不用真的 `ClotheslineView`（要截图历史的库和缩略图），线宽、夹子色、卡片圆角取 `ClotheslineLayout` / `Style` 里的常量。
2. **面板弹开**（通用 › 高级，`general.squeeze`；舞台在表单顶上）。小桌面上方正中一块缩小的剪贴板面板（把 `ClipboardPanelSketch`
   改成 internal 拿来用）：开着时照 `OverlayPanel.squeezeIn`（OverlayPanel.swift:276）——从宽 0.9、高 0.75、顶边不动弹到原尺寸，
   `Spring(duration: 0.42, bounce: 0.22)`，同时 0.12 s 淡入；关着时照普通入场：淡入 + 从上方 6 pt 落下。停 1 s、收起、再来。
3. **刘海岛的活动**（刘海岛页外面那几行；舞台在页面最上面一组顶上）。一个摆出来的 `Island` 放进 `IslandView`，缩到约 0.5、
   只露刘海那一截，按停着的行演：
   - 点刘海打开：先鼓起（`peeking: true`），再打开那一张（`board:` 两条提示 + 快捷动作，照 `island-board` 截图自检的摆法）；
   - 停在刘海上自动展开：鼓起 → 停 `islandHoverDelay` → 刘海两边的活动展开成卡片（`tapped()`）；
   - 正在播放：两边封面 + 跳动条（`island-wings-media` 的摆法，封面是一块渐变，不读用户的东西）；
   - 日程与月历：两边日程图标 + 倒数；
   - 音量与亮度：`showLevel(Island.Level(kind: .volume, fraction: 0.625))`——刘海往两边长开，左边喇叭和「音量」、右边细条；
     细条用强调色 / 显示百分比照这台的设置（同 `island-level-volume-options`）。没刘海的屏是浮着的胶囊。
   **样子照现在的代码和屏外截图**（island-level-*、island-wings-*、island-board-*），不照拍板页里的 HTML 示意。
   专注模式、系统提示、快捷动作的场景留到下一轮（补到 8–10 个时）。

### 6.3 风险和先验的

- `IslandView` 里有 `NSViewRepresentable`（跳动条 `IslandBars` 是图层动画）：缩放后屏外截图能不能画对，第 5 批先单独出一张验。
  画不对就只把那一小块换成静止的三根条（ponytail 写明）。
- 摆出来的岛的计时（停一会儿收回）会自己走：循环时每轮新建一个 `Island`，不复用。
- CPU：停着时跑的是一个 0.5 倍的岛 + 一个弹簧，量一下（`top -l` 采样，停在行上 10 s），超过 5% 就降到 30 Hz。
- 截图自检出三个场景的关键帧（中英、浅深、刘海 / 胶囊各一张），给用户看几帧再定手感。

## 7. 界面里写到设置位置的字（跟着改，第 2–3 批谁挪的谁改）

| 位置 | 现在 | 改成 |
|---|---|---|
| AppDelegate.swift:1469、:3980 | 到 设置 › 通用「同步」里勾上 | 到 设置 › 通用 › 同步 里勾上 |
| AppDelegate.swift:1827 | 到 设置 › 便签 打开「屏幕边缘」 | 到 设置 › 便签 › 屏幕边缘 里打开 |
| AppDelegate.swift:1877、ScriptLibrary.swift:262 | 设置 › 启动器「从剪贴板新建」/「怎么写脚本」 | 设置 › 启动器 › 脚本命令「…」 |
| ShotHistoryView.swift:190 | 在 设置 › 截图 里打开「保留截图历史」 | 在 设置 › 截图 › 截图历史 里打开「保留截图历史」（旁边按钮推进那一页，§1.9） |
| NotesBackup.swift:355、Backup.swift:362 | 到 设置 › 通用 点「从备份恢复」 | 到 设置 › 通用 › 备份与导出导入 点「从备份恢复」 |
| SyncSection.swift:356–357 | 在另一台电脑的 设置 › 通用 里… | 在另一台电脑的 设置 › 通用 › 同步 里… |
| NotesTab.swift:111（挪进 ⓘ 时一起改） | 设置 › 通用 里的导出与导入 / 设置 › 通用「同步」 | 设置 › 通用 › 备份与导出导入 / 设置 › 通用 › 同步 |
| HomePanel.swift:401 | 打开 设置 › 通用，打开或关掉功能 | 体检 U12 改过就照它；没改就「打开 设置 › 通用 › 功能」 |
| 引导、Updater、快捷键岛、截图「截完图放哪」岛、录制麦克风、语言岛 | 写的位置还在外面 | 不变 |

英文同样改（目录里对应的条目）。阶段二再 `grep -rn '设置 › '` 一遍：体检加的新字也算。

## 8. 规则和文档（第 6 批收尾；第 4 批先改说明文字那一段）

- **mac-whisker/settings.md**：
  - 「设置」那一段：页头一句话的规矩（S11）替换掉「通用页头『功能、外观、…』」那句罗列；补「推进行和子页」（§1.2 §1.3）、
    「高级…表单」（§1.4）、「恢复默认和撤销」（§1.5）、「搜索落到行」（§1.8，侧栏「设置项」那一组、描边两秒）、
    「从别处打开直达」（§1.9 那张表的规矩）、「悬停预览」（§6.1，含不碰真东西、只在停着时动）。
  - 控件分工那句补一条例外：选项文字长、英文横排放不下时，3–5 项也用弹出菜单（S6 那三个）。
  - 「实时预览」那句：剪贴板面板示意挪进「高级…」、截图「接换行」对照挪进「高级…」、翻译字号预览挪进「高级…」。
  - 「设置页的说明文字」整段照 §5 开头的写法重写（一句副标题、行尾 ⓘ、组标题 ⓘ、页脚只留三种）。
  - 「设置 › 刘海岛」那段照 §2.8 重写（五个子页 + 快捷动作子页 + 高级）。
- **mac-native.md**：§1「功能开关」那句「在 设置 › 通用 ›「功能」和各页第一行」照旧对；§2 导出导入那段不用改（键没变）。
  加一句「设置的新行先照 mac-whisker/settings.md 的归类放（外面 / 子页 / 高级），并在 `SettingsIndex` 登记，不登记的单测会报」。
- **PLAN.md**：§4 文件表加 `SettingsIndex`、`SettingsSubpage`、`AdvancedSheet`、`SettingsReset`、`SettingsPreview`、`IslandPages`；
  §10 加「设置改版（2026-11-18）」（拍板链接、S1–S11 结果、§12 用户定了的）；§12 写进度。
- **HANDTEST.md** 新一节「设置改版手测」（§11）。**版本号和更新日志**：Base.xcconfig 的 `MARKETING_VERSION` 升到 0.10.2，`changelog.json` 另起一条 0.10.2（中英，type 只用 feat / fix / perf / ui；缺条目 build-dmg.sh 会中止）：ui「设置重新排过：常用的在外面，
  成组的推进下一页，不常改的在「高级…」里」；feat「设置搜索直接落到那一项」「面板里的「设置…」直接到相关那一项」
  「子页和「高级…」里能恢复默认、能撤销」「设置里停在几项上能看到效果预览」（第 5 批做了才写）。
- **新功能标记**：0.10.2 挑哪几个（WhatsNew 每版最多 3 个、写 `version: "0.10.2"`）收尾时问用户；建议标「设置搜索落到行」不标——没有单独的入口（同多语言 0.10.0 的取舍）。

## 9. 单测和截图自检

**单测**（都只碰临时偏好域，不写 Dev 版的偏好；跑前跑后对 plist 做 md5）：

| 文件 | 锁住什么 | 批 |
|---|---|---|
| `SettingsIndexTests`（新） | id 不重复；每页至少一行、每个子页至少一行；`keys` ⊂ `Prefs.defaults` ∪ 已知的这台电脑自己的键；排除名单（§1.5）不进任何恢复默认的集合；源码里每个 `.settingsAnchor(.x)` 的 case 都在、每个 case 恰好挂一次（读源码文本，同 LocalizationTests 的扫法）；`WhatsNew.entries` 带 section 的都对得上一行；中英文关键词都能搜到（「强调色」「accent color」→ `general.accent`） | 1 |
| `SettingsSearchTests`（新，或并进 SettingsListTests） | 「设置项」那组的排序和 12 条上限；页的匹配包括它的行；没添加的插件的行不出；`navigation.open` 之后 page / path / advanced / highlighted 四样 | 1 |
| `SettingsResetTests`（新） | 只删持久域里有的键；snapshot 写回后持久域和原来逐键一样；排除名单不动 | 1 |
| `SettingsListTests`（改） | 侧栏选中换成 `SidebarItem` 后原来那几条照旧（原生高亮关着、选中跟着页走、侧栏顺序）；挂着「高级」表单时 `show(page:)` 能换页、挂着速查表时不换 | 1 |
| 推进行状态（并进各页已有的测试或 `SettingsIndexTests`） | 通用权限 / 同步 / 备份，截图历史，翻译两页，启动器脚本，便签屏幕边缘，刘海岛六个的 value 纯函数 | 2、3 |
| S6 三个选单 | 两个键的全部组合读一遍、每对旧 → 新只写变了的键 | 2、3 |
| `LocalizationTests` | 新字都有英文、没有 stale | 每批 |
| `WhatsNew` 已有的测试 | section 改名后照过 | 2 |

**截图自检**（`SnapshotProbeTests`；中文和 `-testLanguage en -testRegion US` 各一遍，浅深；只出相关前缀）：

- 第 1 批：`settings-search-items`（侧栏「设置项」那组）、`settings-highlight`（描边那一刻）、`settings-pushrow-value`（行尾状态、橙字）。
- 第 2 批：`settings-general`（新的外面）、`settings-general-permissions`（子页；缺授权时推进行在最上面的一张）、`settings-general-sync`、
  `settings-general-backup`、`settings-general-advanced`；`settings-clipboard` + `-advanced`；`settings-screenshot` + `-history` + `-advanced`
  （原来的 `settings-screenshot-custom` 拆到这几张里）；`settings-record` + `-advanced`（`settings-record-custom/-default` 同样拆）；
  `settings-general-min`（最小窗口）照旧出。
- 第 3 批：`settings-translate` + `-lookup` + `-history` + `-advanced`；`settings-launcher` + `-scripts` + `-advanced`；
  `settings-notes` + `-deck`；`settings-island` + 六个子页 + `-advanced`（原来 2200 高的 `settings-island-custom` 拆开）。
- 第 5 批：`settings-preview-placement-{corner,clothesline,none}`、`settings-preview-squeeze-{on,off}`（中间一帧 + 最后一帧）、
  `settings-preview-island-{notch,capsule}-{click,hover,media,calendar,volume}`、`-reduced`（减弱动态效果的静止帧）。
- `whatsNew()` 那几张：推进行 / 「高级…」上的 `NewTag`。

## 10. 分批（串行；每批一个提交、一名独立评审；规矩同体检交接「每批的规矩」）

| 批 | 做什么 | 改哪些文件 | 风险 | 验收 |
|---|---|---|---|---|
| 1 地基（S1 S7 S8 S9） | §1 全部零件；所有页的行挂 `.settingsAnchor` 并登记（place 都是现在的位置）；侧栏「设置项」；§1.9 的入口里目标已经存在的那几条（子页的等第 2–3 批） | 新：SettingsIndex、SettingsSubpage、AdvancedSheet、SettingsReset；改：SettingsWindow（导航状态、侧栏、InfoButton / SettingRow / SectionHeader、描边、show）、ScriptsSection（SettingsPushRow）、PluginsPage（描边）、GeneralTab（PermissionRow info）、AppDelegate（showSettings(item/subpage)）、所有设置页（挂锚，机械改） | 侧栏 List 的选中值换类型：键盘 ↑↓、读屏「已选中」、自绘高亮、`NativeHighlightOff` 都要再验；挂锚是机械改但碰的文件多 | 单测全过；三张截图；手点一遍搜索 → 落到行 |
| 2 通用、剪贴板、截图、录制（S2 S4 S6 S11） | §2.1–2.4、S6 ①②、S11 全部、§7 里这几页的字、WhatsNew section 改名 | GeneralTab（三个子页 + 高级）、ClipboardTab、ScreenshotTab（改成栈）、RecordTab、SettingsWindow（summary、自己画页头的单子）、WhatsNew、AppDelegate、ShotHistoryView、NotesBackup、Backup、SyncSection 两句 | 同步、备份两段搬进推进页后，它们的确认框、存储 / 打开面板、表单还弹得出来（推进页里 `.sheet`）；E4 / E24 确认流程跟着挪；晾衣绳那句的链接 | **做完停下来**：给用户看中英、浅深截图，点头再往下 |
| 3 翻译、启动器、便签、刘海岛（S3 S4 S6） | §2.5–2.8、S6 ③（四项）、§7 里这几页的字 | TranslateTab、LauncherTab、ScriptsSection、NotesTab（改成栈）、IslandTab + 新 IslandPages（改成栈）、AppDelegate | 翻译路由和服务 id、启动器路由和网页搜索 id 不撞；脚本命令子页里的拖放导入、两层推进；日程授权的 `didBecomeActive` 跟着挪进子页；体检 U6 的状态行 | 单测全过、截图自己看一遍 |
| 4 说明文字（S5） | §5 全部，先改 mac-whisker「设置页的说明文字」那段 | 所有设置页、SyncSection、SettingsTransfer、Localizable.xcstrings | 量大：英文要和中文一起改；ⓘ 的读屏 | 主会话逐页对着截图审 |
| 5 悬停预览（S10） | §6 框架 + 三个场景 | 新 SettingsPreview；改 ScreenshotTab、GeneralTab（高级表单）、IslandTab、ClipboardTab（示意改 internal） | §6.3 | 给用户看几帧截图、说手感 |
| 6 收尾 | §8、§11、测试包 | 规则、PLAN、HANDTEST、Base.xcconfig（0.10.2）、changelog.json | — | 报告同体检 |

## 11. 手测（HANDTEST「设置改版手测」，自动验不了的）

1. 每页外面那一屏：常用的设置一眼找得到（剪贴板保留多久、截完图放哪、翻译服务、启动器常用、便签字号、点刘海打开）→ 不用滚就看到。
2. 「高级…」：点开是表单，↩ / Esc 关；表单开着时从菜单栏点「设置…」跳别的页 → 表单收起、换到那一页。
3. 恢复默认：在截图「高级…」里改三项 → 恢复默认 → 岛上「已恢复默认 · 截图 · 高级改回了 3 项」→ 撤销 → 三项回来；同步开着时另一台 Mac 跟着回到默认、撤销后又跟着回来。
4. 搜索：「强调色」「accent」「透镜」「晾衣绳」「整点」→ 侧栏最上面「设置项」里有那一行 → 点它 → 打开所在页 / 子页 / 表单，那一行描一圈、两秒收。
5. 面板直达：剪贴板面板齿轮、翻译浮窗「⋯ › 设置…」、启动器 ⌘,、截图历史「打开设置」、全部便签窗口 ⌘, → 各自落到 §1.9 那一行。
6. 推进行行尾：权限缺一项时橙字、这一组排到最上面；同步停了橙字；便签屏幕边缘「开着 · 右边」换边后跟着变。
7. ⓘ：点开气泡、能选字；读屏停在 ⓘ 上听得到全文。
8. S6 三个选单：每一项切过去，功能照着变（退出 / 锁屏清空、认元素 / 认网页元素、真人 / 系统发音）；导出一份设置再导回，选单显示不变。
9. 悬停预览：停在「截完图放哪」「挤压弹开」「点刘海打开」「音量与亮度」上看演示；开减弱动态效果只给一帧；停着 10 秒看活动监视器的 CPU。
10. 英文界面走一遍 1–9；最小窗口（700 × 460）下表单和子页不挤。
11. 读屏：推进行读出名字和状态；「高级…」读「高级设置」；悬停预览不读。

## 12. 和拍板页初稿不一样的地方、用户定了的

**和初稿不一样（按规矩补的；用户 11-18 看过，Q2 Q3 按推荐）：**

1. **启动器「脚本命令」改成推进行 + 子页**（初稿写留在外面）。那一节现在有 8 行（总开关、怎么写、让 AI 写、文件夹、例子、其他文件夹、
   拖进来导入、读不成的），按 S1「同一主题 4 项以上推进子页」应该推进；外面一行写「n 个脚本」。
2. **刘海岛「快捷动作」是推进行**（初稿写留外面，拍板页的示意里画的就是「快捷动作 6 个 ›」）：那张列表 7 行，推进子页。
3. **便签「在屏幕边缘显示便签」和「屏幕边缘 ›」合成一行**：推进行「屏幕边缘」行尾写「开着 · 右边」，总开关是子页第一行
   （初稿两样都列在外面）。**正文字号、行距**初稿没写，留在外面（和 Markdown 样式一组）。
4. 初稿没提到的几行：三个「面板大小」进高级（跟着「面板位置」）；刘海岛「提示停多久」进高级；剪贴板面板示意跟着「显示透镜」进高级；
   截图的两行按键、录制「保存到」、启动器的浏览器书签和文件搜索授权、各页按键行留外面；截图「截完图放哪」选晾衣绳而历史关着时，
   那句橙字带一个「去打开」推进截图历史。
5. **恢复默认不碰**会当场删数据的上限（剪贴板保留天数、图片占用，截图历史保留、占用，翻译历史条数）和功能开关——这几样改回默认可能
   马上删掉东西，撤销也回不来。
6. **「权限」的「缺几项」只数开着的功能用得着、却没给的**辅助功能、屏幕录制，和被拒绝的剪贴板访问；麦克风用到时才问，不算缺
   （不然新装的人一直挂着「缺 1 项」）。
7. 组的说明（原来的页脚）放在**组标题右边的 ⓘ**（S5 只说了行尾 ⓘ）。
8. 悬停预览的舞台**放在那一组顶上、跟着表单滚**，不钉在页顶；通用的「挤压弹开」在「高级…」里，舞台跟着进表单顶上。
9. S6 的三个选单都用**弹出菜单**（选项字长，英文横排放不下），mac-whisker「3–5 项用单选」补一句例外。
10. 搜索结果放在侧栏最上面一组「设置项」，打字时不自动开子页 / 表单，选了才落到行（初稿没说怎么展示）。

**用户 2026-11-18 定了（「四项，其余两个也按推荐」）：**

- **Q1 英文单词发音合成几项** → **四项**（真人 · 美音 / 真人 · 英音 / 系统声音 · 美音 / 系统声音 · 英音）：原来的「美音 / 英音」也管系统声音
  （Speaker.swift:53），拍板的三项（系统 / 真人美音 / 真人英音）里「系统」分不出美英，选了「系统」时美英停在上次的、看不到也改不了。
- **Q2 启动器「脚本命令」推进子页**（上面第 1 条）→ **按推荐，推进子页**。
- **Q3 恢复默认不碰那几个会删数据的上限**（上面第 5 条）→ **按推荐，不碰**。
