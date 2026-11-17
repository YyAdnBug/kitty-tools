# TRANSLATION.md：多语言的做法、口径和术语表

2026-11-15 立项，先支持英文（拍板页 https://claude.ai/artifact/6AKf54goosrR568Gs1smAj「全部按推荐」，PLAN §10「多语言」）。
改界面文字、翻英文之前先读这一份；红线在 `.claude/rules/mac-native.md` §2「多语言」。mac 和 Windows 两边共用这里的口径和术语表。

## 一、底子

- 一张 String Catalog：`KittyTools/Resources/Localizable.xcstrings`，开发语言 zh-Hans，**中文原文就是 key**（代码读起来和以前一样）。
  Info.plist 的权限说明在 `KittyTools/Resources/InfoPlist.xcstrings`（中文改 `Config/Info.plist`，两边一起改）；访达扩展另有一份
  （`KittyToolsFinder/Localizable.xcstrings`，第 8 批建）。
- 编译时把能本地化的字面量抽成 `.stringsdata`（`SWIFT_EMIT_LOC_STRINGS`），**`macos/sync-strings.sh [derivedDataPath]`** 构建一遍、
  用 Xcode 自带的 `xcstringstool sync` 并进目录（Xcode 打开工程时自己做）。新 key 没有英文；代码里不用了的标 stale（`LocalizationTests`
  要求删掉）。构建不看工程的 knownRegions：**目录里有哪种语言就编哪种**。
- 语言：跟系统；设置 › 通用「语言」能选（`Shell/InterfaceLanguage.swift`）；繁体系统落回简体（Info.plist 列了 zh-Hant、没有它的字）；
  升级上来的保持中文。单测宿主固定 zh-Hans（共享 scheme 的测试语言），英文截图加 `-testLanguage en -testRegion US`。
- **`Locale.current` 跟着界面语言走**（定成中文时 zh_CN、跟英文系统时 en_CN，实测）：日期、数字、货币名、星期一律用它和 FormatStyle
  的默认，不写死 `zh-Hans`、不手拼「年月日」「星期」。

## 二、代码怎么写

| 情况 | 写法 |
|---|---|
| SwiftUI 的 `Text` / `Button` / `Toggle` / `Label` / `Section` / `Picker` / `TextField` / `.help` 等直接给字面量 | 不用改，会自动抽出来 |
| 自家组件收标题、说明的参数（`SectionFootnote`、`EmptyState`、`island.show`、`SettingsPushRow`……） | 参数类型 `String` → `LocalizedStringResource`，调用处的字面量不动；显示用 `Text(resource)`，AppKit 用 `String(localized: resource)` |
| 上面那种参数要传用户的数据（便签标题、App 名） | 传 `"\(name)"`：key 是 `%@`（目录里标了不翻），原样显示。**别**用 `LocalizedStringResource(stringLiteral: name)`：用户的字碰巧等于某个 key 就会被翻掉 |
| 组件里显示收进来的 `LocalizedStringResource` | 写 `Text(plain: title)`（`Shell/InterfaceLanguage.swift`），**别**直接 `Text(title)`：`Text(LocalizedStringResource)` 连 `"\(x)"` 插进去的用户的字一起当 Markdown 解析（文件名里的 `*`、反引号会变成斜体、代码样式，实测）。组件以前收 String、原样显示，`plain` 保持这个样子；真要 Markdown 样式的只在视图里直接写字面量 `Text("…")` |
| 模型、逻辑里的 `String`（错误信息、菜单项、刘海岛文字） | `String(localized: "…")` |
| 枚举的标题 | `var titleResource: LocalizedStringResource { switch self { case .a: "…" } }` + `var title: String { String(localized: titleResource) }` |
| 同一个中文、英文不同（动作「截图」Take Screenshot / 页名「截图」Screenshot；外观的「跟随系统」Auto / 语言的 System Language） | 显式 key：`String(localized: "action.screenshot", defaultValue: "截图")`、`LocalizedStringResource("general.language", defaultValue: "语言")`；key 写成 `<族>.<名>`，小写英文、点分 |
| 带数字、名字的句子 | **整句插值**：`String(localized: "已拷贝 \(count) 条")`；不拼接（`"设置，" + x` 改成 `String(localized: "设置，\(x)")`）；英文语序不同时用位置参数 `%1$@ %2$@` |
| 插进句子的数字 | 插 Int 会按语言加千分位（「1,234 条」，中英都是）：数量照常插；**不是数量的数**（宽高、端口、年份、版本号、编号）插成 `String(x)`，免得出「图片 1,200×240」「端口 8,080」 |
| 单复数 | 照常插值（`"\(n) 个功能关着"`），目录里给英文 one / other 两种 |
| 意思靠上下文的短词 | 加 `comment:` 写在哪、指什么（给翻译的人看） |
| 不翻的（App 名、品牌、示例网址、只有符号和格式符的） | `Text(verbatim:)`；已经抽进目录的只有格式符的 key 标 `shouldTranslate: false` |
| AppKit（`NSMenuItem`、`NSAlert`、`toolTip`、读屏的标签和播报） | `String(localized:)` |
| 刘海岛（第 1 批改好）：`show` / `progress` / `dismiss(ifShowing:)` / `showIfSlow`、`Island.Action`、`Island.announce` 收 `LocalizedStringResource` | 进行中那一条按 `Content.source`（传进来的 resource，key + 插的值）认：`progress`、`dismiss(ifShowing:)` 给和 `show` 同一个 resource（存成 `static let x: LocalizedStringResource`）；已经取好的字播报用 `Island.post` |
| 自家组件（第 1 批改好）：`ActionMenu.Item(title:detail:)`、`emptyText`、`EmptyState`、`BarNotice.message/warning/undo`、`NSMenu.addAction`、`NewTitle`、`WhatsNew.touch(section:)` | 同上，字面量直接写；`ActionMenu.Item.original` 是中文原文（`resource.chinese`），过滤时和标题一起认 |
| 设置页的零件（第 2 批改好）：`SectionFootnote`、`DetailHeader(title:status:)`、`PermissionRow(title:detail:button:)`、`PermissionStatus`、`ListEditBar(removeTitle:)`、`SettingsPushRow(title:detail:)`、`PanelSizeRow(detail:)`、`AppListRow.chooseApps(prompt:message:)`、`DangerButton`（第 3 批） | 同上；用户起的名字、别处算好的一句摘要传 `"\(x)"`。原来拿 `+` 拼的说明（`SectionFootnote("a" + (x ? "b" : ""))`）编不过：拆成整句的三目，或者暂时整段 `"\(text)"` 传过去、留给那一族拆 |
| 并列的几个名字连成一串（「剪贴板、启动器」） | `names.joinedAsList()`（显式 key `list.enumeration`：中文「、」，英文「, 」），别写死 `joined(separator: "、")` |
| 某种语言里是空的（中文「」「」之间什么都不加、英文要「, 」） | 别让哪种语言的值是空串：查不到译文、默认值又是空的时候系统显示 key 本身（实测）。把空的那段并进旁边的字里（`list.quoted` 的中文是「」「」，外面再包一层「%@」），`LocalizationTests` 查空串 |
| switch / 三目的各个分支是元组（`case .url: ("打开", "safari")`），或者 switch 表达式赋给一个可选值的 `let` | 编得过，但**只有第一个分支的字被抽进目录**，写成 `LocalizedStringResource("…")` 也一样（第 6 批实测，其余的英文界面显示中文）：经一个收 `LocalizedStringResource` 参数的小函数传进去（`LauncherModel.act`），或者让函数直接 `return` 那个 switch。不是元组的 switch / 三目、`String(localized:)` 都没事——**例外：三目直接写在可选的 `LocalizedStringResource?` 参数里**（`detail: x ? "a" : "b"`，第 8b 批实测）同样只抽到第一个分支，先赋给一个不是可选的 `let detail: LocalizedStringResource = x ? "a" : "b"` 再传；`if` / `switch` 表达式赋给可选值的 `let` 同样（第 9 批：先给一个不是可选的 `let`）。漏了的 `LocalizationTests.sourceStringsAreInCatalog` 会报（源码里的中文字面量目录里没有） |
| 文件里的内容（新建脚本的模板、例子、给 AI 的写法说明） | 不进目录：按 `InterfaceLanguage.isEnglish` 写两份，建的那一刻用当时的语言（写进文件就是用户自己的） |
| 固定宽的格子里英文放不下（主界面格子、刘海岛那一张的快捷动作） | `Style.fitsOneLine` 量：放不下的才折两行、居中，放得下的修饰符和原来一模一样（中文截图逐像素不变）。折两行还放不下的只在格子里用短说法（主界面的「划词翻译并替换」→ Translate & Replace，`Home.shortTitle`；悬停提示、读屏照旧全称） |
| 刘海岛收着那一行（标题 + 详情 + 按钮） | 不用管长短：`Island.rowRoom` 量好，整行放不下时先压详情（最窄 120、中间截断）、再截标题的尾巴，不超过岛的最宽 460（第 9 批；英文的长标题原来会撑出岛被裁掉）。岛上的句子照样写短 |

**存下来的字：存原文、显示时翻**（拍板 D6）。写进偏好、数据库、同步文件夹、导出文件、文件名，而且之后还要读回来比对的中文，
不能因为换语言就认不出来：

- 拿来认东西的一律用 id 或固定常量：自动备份的文件名「Kitty Tools 自动备份 …」、录屏的「 压缩版」后缀、WebDAV 默认文件夹
  「Kitty Tools 同步」、新建文件模板的文件夹名「新建文件模板」**永远不翻**；「新」标记、设置侧栏收起的组、启动器别名替换、
  岛上认哪一条，改成按 id 比，不拿显示出来的文字比。
- 访达右键「新建文件」的五个自带模板（第 8b 批）：内部认 ASCII id（txt、md、docx、xlsx、pptx，网址里交的、包里资源 `new-file.<id>`），
  建出来的文件名跟建的那一刻的语言（「文本文件.txt」「Text File.txt」）；0.9.0 的扩展交的中文文件名照认（`NewFile.legacyNames`）。
- 自带的东西（状态屏的三个状态、提醒的示例）：存着的还是中文，按 id 认出「没改过的自带项」、显示时翻；用户改过的原样显示。
- 存进去就是用户数据的（翻译服务的预设名、启动台的「未命名」、示例便签、起的文件名）：按存的那一刻的语言写。
  导出的文件名、文件夹名（设置导出「Kitty Tools 设置 日期.json」、便签 Markdown 导出「Kitty Tools 便签 日期」）同样跟导出那一刻的
  语言；导入一律按文件内容（标记、编号）认，不看名字（第 7 批）。记进偏好再显示的一句话（自动备份没备成的原因）是写下那一刻的语言，
  下一次备份时换掉。
- 网页搜索的预设（第 6 批）：默认列表全 App 一套、存的照旧是中文名；名字没改过的按 id 认出来、显示时翻（`SearchEngine.displayName`）。
- 给大模型的提示词、词典词条里朗读要认的标记（「美 /…/」「例：」）不翻。
- 自带脚本（`Resources/scripts/`）：头部另写 `@kitty.title.en` / `description.en` / `argument1.en`…（英文界面用它，没写的用原来的，
  另一种语言的标题进搜索名）；输出的话按 `$KITTY_LANGUAGE`（`zh-Hans` / `en`）挑。复制一份到我的脚本时只留复制那一刻的语言
  （`ScriptLibrary.localizedCopy`）。

**搜索中英都认**（拍板 D7）：启动器、设置搜索里，当前语言的标题 + 中文原文（`resource.key`）+ 拼音 + 英文都进可匹配的名字；
解析中文输入的（提醒的一句话、计算器单位、汇率、系统命令）中文照旧认，补英文关键词。
**别的 App 的名字跟系统语言、不跟本 App 的界面语言**（2026-11-16 手测反馈）：显示的是访达里那个名字（`AppCatalog.systemName`；
系统第一语言是简体中文时中文名优先，同 0.9.0），中文名、拼音、英文名都进搜索名。别用 `FileManager.displayName` 取 App 名：
LaunchServices 按调用方 App 自己的语言给，界面定成中文时英文系统上也是「备忘录」（`NSRunningApplication.localizedName` 不受影响）。

## 三、每一批的流程

1. 读这一份和要动的那一族的 `mac-*` 规则；先改这一族「存下来的字」里列到的项（结构改动，单独看清楚）。
2. 改写法（上面的表）。
3. `macos/sync-strings.sh macos/build/dd-i18n` 把新 key 并进目录。
4. 填英文：直接改 `Localizable.xcstrings`（JSON；普通一条是 `localizations.en.stringUnit = {state: translated, value}`，单复数是
   `localizations.en.variations.plural.{one,other}.stringUnit`），改完再跑一次 sync 把格式收拾成 Xcode 的样子。
5. `LocalizationTests`：每一条中文都有英文（第 9 批起 `requiresEnglish`）、状态 translated、占位符和中文一样、没有汉字、术语照下表、
   没有直撇号；没有 stale；**漏网检查**（`sourceStringsAreInCatalog`）：App 和访达扩展源码里带汉字的字面量都在目录里（key 或显式 key 的
   中文默认值，去掉插值后对得上格式也算），故意不翻的（解析中文输入的词、存下来要认的固定名字、日志外的内部字、文件内容）写进
   `notTranslated` 白名单、每条写理由；日志、断言、`comment:` 自己跳过。速查表、启动器提示里提醒和汇率的例子（中英）要真能解析（`examplesParse`）。
6. 截图：这一族的屏外截图自检中文跑一遍、和改之前逐像素比（中文界面不该变）；`-testLanguage en -testRegion US` 再跑一遍，逐张看
   截断、换行、对齐。放不下的先用下表的短说法，再考虑两行、缩字、加宽。
7. 单测全量（中文）过、`swift-format lint` 无输出，一个提交。

## 四、英文口径（对着 macOS 自带 App 写，拍板 D3）

- 菜单项、按钮、窗口 / 设置页 / 分节标题用 Title Case（Check for Updates…）；开关、复选框、设置里一行的行名（照系统设置：Accent color、
  Icon style、Panel size）、说明、提示用句子写法（Check for updates automatically）。
- 还要再问一步的动作带「…」（一个省略号字符）；「」换成 “ ”；路径照用 ›（Settings › General）。
- 用 you，不写 please，短句；出错写「出了什么事 + 怎么办」，不道歉；不用感叹号。
- 数字用阿拉伯数字，单位走单复数；按键写符号（⌥Space、⌘⇧A）。
- 界面不提其他 App / 产品（mac-native §8，英文同样）；功能本身要用的名字照写。
- 语言名写它自己的文字（简体中文、English），不翻。
- 撇号用弯的 ’（don’t、it’s、Kitty Tools’），不用直撇号 '（`LocalizationTests` 查字母之间的）。
- 功能名（下表里首字母大写的：Launcher、Clipboard History、Status Screen、Screenshot History、Word List、Finder Menu、Keep Awake、Notch……）在句子中间
  也首字母大写：the Launcher、in Finder Menu、Turn on “Keep Screenshot History”。刘海岛 = the Notch，硬件的刘海照常小写（click the notch）；
  指一条条东西的复数照常小写（scrolling captures、floating notes、translation services、web searches）。

## 五、术语表

右边是英文；括号里是放不下时的短说法。`LocalizationTests.glossary` 查其中不会被别的说法替代的那些（右边写成大写的按大小写查，第 9 批），
改这里要一起改。
用短说法的地方写显式 key、comment 里带「短说法」（测试不查它的术语），悬停提示、读屏照旧写全称。

| 中文 | English | 说明 |
|---|---|---|
| 剪贴板 / 剪贴板历史 | Clipboard / Clipboard History | |
| 片段 | Snippets | |
| 收藏 / 收藏夹 | Favorites / Collections | |
| 透镜 | Lens | |
| 启动器 | Launcher | |
| 脚本命令 / 别名 / 快捷链接 / 网页搜索 | Script Commands / Alias / Quicklinks / Web Search | |
| 翻译（功能 / 页） | Translate | 句子里的名词用 translation |
| 划词翻译 / 输入翻译 / 截图翻译 | Translate Selection / Type to Translate / Translate Screenshot | 动词在前 |
| 划词翻译并替换 | Translate and Replace Selection（Translate & Replace） | |
| 复制即译 | Translate on Copy（On Copy） | 顶栏状态胶囊用短说法 `translate.copyBadge` |
| 生词本 | Word List | |
| 翻译服务 | Translation Services | |
| 截图（页 / 功能）· 截图（动作） | Screenshot · Take Screenshot | 显式 key `action.screenshot` |
| 截取上次区域 | Capture Previous Area（Previous Area） | |
| 识字 | Capture Text | |
| 钉图 | Pin（Pinned Screenshot） | |
| 长截图 | Scrolling Capture | |
| 截图历史 | Screenshot History（History） | |
| 标注 / 打码 | Annotate / Blur | |
| 晾衣绳 | Clothesline | |
| 录制 / 录屏 / 录音 | Recording / Record Screen / Record Audio | |
| 便签 / 快速记一条 / 便签墙 / 浮动便签 | Notes / Quick Note / Note Wall / Floating Note | |
| 最近删除 / 归档 | Recently Deleted / Archive | |
| 提醒 / 稍后 | Reminders / Snooze | |
| 状态屏 / 状态 | Status Screen / Status | |
| 启动台 | Launchpad | |
| 程序坞预览 | Dock Preview | |
| 访达右键 | Finder Menu | |
| 保持唤醒 | Keep Awake | 插件；动词用法也写功能名（保持唤醒中 Keep Awake is on、停止保持唤醒 Turn Off Keep Awake） |
| 睡眠关蓝牙 | Bluetooth Sleep | 插件 |
| 平滑滚动 | Smooth Scrolling | 插件 |
| App 快捷键 / 显示 App 快捷键 | App Shortcuts / Show App Shortcuts | 插件（2026-11-17）；句子里说「当前 App 的快捷键」时照常写 the app’s shortcuts |
| 键盘与鼠标（全部插件的分组） | Keyboard and Mouse | 同「记录与提醒」Notes and Reminders |
| 刘海岛 / 打开刘海岛 | Notch / Open Notch | 不用 Dynamic Island |
| 提示 / 活动（刘海岛上） | Notices / Activities | |
| 主界面 | Home | |
| 功能 / 插件 | Features / Plugins | |
| 同步 / 同步文件夹 | Sync / Sync Folder | |
| 设置 / 通用 / 快捷键 / 速查表 | Settings / General / Shortcuts / Keyboard Shortcuts | |
| 更新日志 / 新（标记） | Release Notes / New | |
| 跟随系统（外观 / 强调色 / 语言） | Auto / Multicolor / System Language | 三处各用显式 key |

## 六、不翻的

- App 名 Kitty Tools、作者名、其他产品和服务的名字（翻译服务名、浏览器名）、文件格式名。
- 上面「存下来的字」里列的那些固定常量和标记。
- 日志（`Log`）、`fatalError` / `precondition` 的说明、给开发者看的注释。
