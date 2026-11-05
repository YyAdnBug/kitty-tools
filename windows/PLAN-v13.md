# Kitty Tools Windows 版：第十三版方案（便签）

2026-11-05。接 PLAN-v12（N7「便签太大，单独出 PLAN-v13」）。用户：「继续新会话剩下的，现在不检查，最后一次性检查」。

**这一版不是拍板页**：行为、默认值、文案照 mac 0.6.0 起的便签（`macos` 分支 `b7a55e33`，`macos/KittyTools/Notes/` 39 个文件）；
只有 Windows 自己要定的写在 §3「替用户定的」，不同意的直接说。分工同 PLAN-v12：**全部在 Mac 上写、一行都不编译**，中间不交给 Windows 核验，
全部写完后统一给一份核验指令（`REVIEW.md` 顶上）。每批的交接写在 `REVIEW.md`「PLAN-v13」。

对照的 mac 规格（只读这些）：`macos/PLAN.md` §10「便签」「便签的四个新功能」，`macos/docs/archive/PLAN-notes.md`，
`.claude/skills/mac-overlay-panel/rule.md` §3 §5 §12、`.claude/skills/mac-whisker/notes.md`、`.claude/skills/mac-translate/rule.md` §5、
`.claude/skills/mac-clipboard/rule.md` §1，`.claude/rules/mac-native.md` 的「便签同步」「设置的导出与导入」两段，`macos/HANDTEST.md`「便签手测」。

## 1. 范围（照 mac 0.6.0 的便签）

| 块 | 内容 |
|---|---|
| 记和看 | 快速记一条（全局快捷键）；全部便签窗口（便签墙 / 列表、搜索、归档、最近删除）；屏幕边缘那叠（药丸、标签列、预览卡）；浮动便签（置顶、拉大小、最多 5 张、固定后重启回原处） |
| 正文 | 纯文本存、显示时加样式：Markdown（标题、粗斜体、删除线、行内代码、链接、引用、列表、代码块）、任务五种状态（☐ ◧ ▣ ☑ ☒）、文字颜色 `[字]{red}`、行内图片（宽度五档、裁切）、查找、撤销 / 重做、行距三档 |
| 数据 | 单独的库 `notes.sqlite3`（winsqlite3）、图片目录 `notes-images/`、每日备份 `notes-backups/`（7 份）；删除进「最近删除」留 30 天；没人引用的图片满 30 天才删 |
| 出入 | 整个 / 单条导出成 Markdown 文件夹再导回；设置的导出导入第七类「便签」（`NoteEntry`，合并规则同 mac）；每日 JSON 备份带便签 |
| 打通 | 剪贴板 / 启动器粘贴落进开着的便签；划词翻译读便签自己的选区（替换回便签）；启动器三个动作 |
| 同步 | 和 mac 同一个同步文件夹：`devices/<本机>/notes/<编号>.md`、`erased.json`、共用的 `images/`；合并规则、版本钟、墓碑、文件格式和 mac `NoteSync.swift`、`NoteSyncFolder.swift` 一字不差（在 Mac 上用 mac 的源码编出 golden，单测逐字比） |
| 入口 | `Feature.Notes`、设置 › 便签、快捷键页 / 速查表「便签」一节、托盘「便签 ›」、主界面一节 |

**不做**（mac 也不做或用户去掉过的照旧不做）：启动器 `note` 关键词、剪贴板 Ctrl+K「存成便签」、钉图「存成便签」、表格 / 斜杠菜单 / 语法高亮、
txt / PDF 导出、CloudKit。

## 2. 分批

| 批 | 内容 | 主要文件 |
|---|---|---|
| 1 | **核心模型（Core）**：`Note`（收拾、上限、毫秒、标题 / 摘要）、`NoteTasks`（五种状态、Ctrl+T、回车续行、Tab、自动转换、和 Markdown 互转、进度）、`NoteImages`（令牌）、`NotePaper`（8 种纸色 + 自定义纸色推导）、`NoteMarkdown`（不用正则的扫描器、代码块、plain、加标记、粘贴网址成链接） | `KittyTools.Core/Notes/*.cs`，单测照 mac 的 `NoteTasksTests`、`NoteMarkdownTests`、`NoteImagesTests`、`NoteCustomPaperTests` |
| 2 | **仓库与备份**：`NoteStore`（落盘节流 / 重试、最近删除、墓碑、钟、`written_revision`、搜索、空白便签）、`NoteImageStore`（图片目录、孤儿 30 天）、`NotesBackup`（每日 7 份、打不开时恢复）、示例便签、设置导出导入第七类、每日 JSON 备份带便签、`Feature.Notes` 和设置键 | `KittyTools/Notes/`、`KittyTools.Core/Notes/NoteRules.cs`、`ArchiveService`、`SettingsArchive` |
| 3 | **同步**：`NoteSync`（合并）、`NoteSyncFolder`（文件格式、一轮、刹车、写出去）、golden（`tools/notes-sync-golden.swift`）、执行层接进 `SyncRunner`（便签一步、认出退回去了换编号、正在编辑的先不换）、设置 › 通用 › 同步「便签」一行 | `KittyTools.Core/Notes/NoteSync*.cs`、`Core/Sync/SyncRunner.cs` |
| 4 | **正文编辑器**：`NoteStyles`（一行 → 样式区间、叠层、行距、代码块角色，Core）、`NoteUndo`（自己的撤销栈，Core）、`NoteEditor`（RichEditBox 包装：藏 / 露标记、方框、续行、Tab、Ctrl+T / B / I / Shift+X / E、颜色、查找条、字节上限、组字中不重排） | `KittyTools/Notes/NoteEditor*.cs` |
| 5 | **窗口和入口**：快速记一条、全部便签窗口（墙 / 列表、搜索、归档、最近删除、右键、拖动排序）、打开的便签（标题、正文、Ctrl+K 操作菜单、颜色菜单 + 其他颜色）、热键、托盘、主界面、速查表、设置 › 便签 | `KittyTools/Notes/`、`Settings/SettingsWindow.Notes.cs` |
| 6 | **屏幕边缘那叠和浮动便签**：药丸、标签列、预览卡、设置（左右 / 哪块屏 / 样式 / 大小 / 全屏时）、拖出来浮着、截图 / 状态屏 / 空闲回收里算什么 | `KittyTools/Notes/NoteDeck*.cs`、`NoteFloat*.cs` |
| 7 | **行内图片和 Markdown 出入**：插 / 粘 / 拖图片、宽度五档、裁切、拷贝；整个 / 单条导出 Markdown 和导回 | `NoteEditor.Images.cs`、`Core/Notes/NoteMarkdownFiles.cs` |
| 8 | **打通和收尾**：剪贴板 / 启动器粘贴落进便签、划词翻译读便签选区、启动器动作、HANDTEST、MAC-DIFF、STATUS | 各处的接线 |

版本号：便签整族是 **0.4.0**（PLAN-v12 第 3–7 批是 0.3.0）；版本号、更新日志等核验完和 0.2.0、0.3.0 一起定，**不发布、不打 tag**。
手测从 HANDTEST 1043 起，每批一节。

## 3. Windows 自己要定的（替用户定的）

照 `AGENTS.md`「和 mac 版统一什么」：行为、文案、默认值、数据格式跟 mac；窗口外壳、系统画的控件、快捷键写法跟 Windows。

### 3.1 编辑器：RichEditBox，不自己画

- **用 WinUI 的 `RichEditBox`**（RichEdit / TOM）：输入法、读屏、拼写、选区、拖放、滚动都是系统的；自己画一个文本控件要重写输入法（CoreTextEditContext）
  和无障碍，量太大、错了用户最先碰到。mac 的 TextKit 1 那一套（藏字形、自己画方框）在 RichEdit 上换成：
  - **存的永远是纯文本**（同 mac）：`Document.GetText(UseLf)` 读、`SetText` 写；样式只改格式（`CharacterFormat` / `ParagraphFormat`），**不进撤销栈**（下一条）。
  - **撤销 / 重做自己管**（`Core/Notes/NoteUndo.cs`）：RichEdit 把改格式也记进它的撤销栈，Ctrl+Z 会先撤掉样式。`UndoLimit = 0` 关掉它的，
    Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z 在 `PreviewKeyDown` 里走自己的栈（打字按 1 秒、空白、换行、跳光标分组，同 mac 的分组口径）。
  - **Markdown 的标记**：光标不在的行上 `CharacterFormat.Hidden = On`（RichEdit 的隐藏文字：不画、不占宽、光标跳过），光标在的行上淡色露出来（同 mac 的藏 / 露）。
  - **任务方框**：正文里存的就是 ☐ ◧ ▣ ☑ ☒ 这五个字（mac 也是），直接显示成字（Segoe UI Symbol），按状态上色（紧急红、完成 / 取消灰、内容划线）；
    点方框（指针按下时 `GetRangeFromPoint` 落在方框那个字上）切换。mac 是自己画圆角方框（字形不画），Windows 用字形本身——MAC-DIFF 记一条。
  - **行内图片**：`Range.InsertImage`（正文里是 U+FFFC），令牌按出现顺序对应（编辑器自己记一张表）；存盘时换回令牌。
  - **行距三档**：`ParagraphFormat.SetLineSpacing(Multiple, 1.2 / 1.45 / 1.7)`；代码块：Cascadia Mono + 淡底色（`CharacterFormat.BackgroundColor`）。
  - **组字中不重排、不落盘**：`TextCompositionStarted` / `Ended` 之间只记下改过的范围，确认后一次补上（同 mac）。
  - 风险（写进核验指令）：`Hidden` 在 WinUI 的 RichEditBox 里画不画、光标会不会停在隐藏的字中间；`GetText` 带不带隐藏的字（要带：`TextGetOptions.None` 不去掉隐藏文字）；
    `InsertImage` 的图在 `GetText` 里是不是一个 U+FFFC。核验时任何一条不对，退路写在 REVIEW 第 4 批下面。

### 3.2 屏幕边缘那叠：贴在工作区的边上

- 贴在**那块屏的工作区**（`MONITORINFO.rcWork`，去掉任务栏的那块）的左 / 右边，所以**永远不挡任务栏**；任务栏放在右边时，那叠贴在任务栏的内侧。默认右边、只在主显示器（同 mac）。
- 透明的 WinUI 窗口在用户机器上是白的（0cc29cf7），所以不做 mac 那种整块透明的面板：**药丸**是一扇小的不透明窗（DWM 圆角、不拿前台、置顶、不进 Alt+Tab），
  **扇出的标签列**是一扇贴边的亚克力窗（同剪贴板面板的底），4 秒不碰收回；**打开的便签**是一扇贴着标签列的窗口——要打字，所以拿前台（Windows 没有「当键盘焦点又不激活」）。
  点别处（失去前台）收起，固定后不收（同 mac）。
- 别的程序全屏时（前台窗口盖满整块屏）默认不出来（同 mac「默认不盖在全屏 App 上」），设置里可开。
- 按住 Alt 拖药丸换边 / 换高度 / 换屏（mac 是 ⌥）；两块屏相接的那条边不放，自动换到外侧（同 mac）。

### 3.3 快捷键

- **快速记一条默认 `Alt + N`**（mac ⌥N；和 Windows 版别的默认键一样是 Alt + 字母）。查过的占用：Windows 自己没有；Office 的 Alt+N 是「插入」功能区（按住 Alt 再按 N 是一样的，
  Alt+X / Alt+S 已经有同样的代价）；对话框里「否(N)」不按 Alt 单按 N 也能点。「新建便签」「全部便签」不设默认键（同 mac）。
- 便签里的按键固定（同 mac 的 ⌘ 换成 Ctrl）：Ctrl+K 操作、Ctrl+P 固定、Ctrl+T 任务、Ctrl+F 查找、Ctrl+Shift+Delete 删除（mac ⌘⌫；Windows 的 Ctrl+Backspace / Ctrl+Delete 是删一个词，不能占）、
  Esc / Ctrl+W 关、Ctrl+B / Ctrl+I / Ctrl+Shift+X / Ctrl+E 加标记、Ctrl+. 换颜色。

### 3.4 其他

- **窗口外壳**跟 Windows：全部便签窗口是普通窗口（进任务栏和 Alt+Tab，同设置窗）；浮动便签、那叠、快速记一条不进 Alt+Tab。
- **自定义纸色的取色**：WinUI 的 `ColorPicker` 放在一个小浮层里（mac 用系统取色面板）；最近用过 8 个记在这台电脑（不导出）。
- **图片裁切**：在这条便签的窗口里盖一层（同 mac「同一扇窗口，不另开」），Windows 用一个铺满编辑区的 Canvas。
- **示例便签、「便签在屏幕右边缘」那句提示**：只放 / 说一次，记在设置里这台电脑的状态（不导出）。
- **同步**：便签走现有的同步执行层（`SyncRunner` 多一步「便签」）；设置 › 通用 › 同步多一行「便签」（默认开、跟着便签功能开关）。PLAN-v5 §0 第 1 条「便签文件、`images/` 一个字节都不碰」
  改成：**只写自己子文件夹里的 `notes/`、`erased.json`，`images/` 里只加不改不删**（同 mac：存了不改、同名同内容），别的电脑的照旧一个字节都不碰。
- **电脑编号**：mac 的便签钟用便签库里记的编号；Windows 只有一个编号（`kitty.sqlite3` 里的 `SyncDevice`），便签的钟也用它。便签库从备份恢复时换编号
  （mac `forgetDevice`），同步时认出文件夹里本机那一格比库里大（mac `regressed`）也换（`switchDevice`）。
- **库**：winsqlite3（同 `kitty.sqlite3`），表结构照 mac 的 `notes` / `note_erased` / `note_meta`，列名一样（两边不互读库，但照抄省得出错）。
  图片孤儿的账 mac 是 `.orphans.plist`，Windows 写 `.orphans.json`（只在本机、跟着备份走）。
