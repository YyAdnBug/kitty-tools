# AGENTS.md

`main` 分支（原生版主线，2026-09-27 由 `macos-native` 改名）的 agent 项目指引（Cursor / Codex 直接读；Claude Code 经 `CLAUDE.md` 导入）。常驻红线在 `.cursor/rules/mac-native.mdc`。

## 项目概述

**kitty-tools 原生 macOS 版**：用 Swift 6 + SwiftUI / AppKit 重写的纯原生菜单栏工具，替代 Tauri 版的 macOS 端。基本自用：只支持 Apple 芯片（arm64），最低 macOS 15.0。

- **功能**：剪贴板历史、翻译（划词 / 输入 / 复制即译 / 截图翻译，全部翻译服务）、启动器（`Launcher/`，⌥Space 的搜索框）、启动台（`Launchpad/`，第八族，0.6.0，复刻 macOS 15 的全屏图标网格，只在 macOS 26 起出现：分页、搜索、拖动排序、文件夹、抖动删 App、触控板捏合、触发角、导入系统旧布局）、截图（`Screenshot/`：框选、标注、识字、钉图、长截图）、录屏与录音（`Screenshot/ScreenRecorder.swift`、`AudioRecorder.swift`）都已做完。状态屏（`StatusScreen/`：一键把所有屏幕盖上告示、拦住键盘鼠标，状态可自定义；2026-10-10 立项，0.4.0，代码已做完、待真机手测，PLAN §10「状态屏」；告示上的图标是 Microsoft Fluent Emoji 的动画表情，MIT，素材随包）。每个功能都能在 设置 › 通用 › 功能 里整个关掉（2026-10-22，`Shell/Feature.swift`，PLAN §10「功能开关」）。
- **版本**：已发布 0.1.0、0.2.0、0.3.0（录屏录音）、0.3.1（第二轮体检）、0.3.2（设置的导出与导入、每天自动备份、启动器 port、长列表性能和常驻内存）、0.4.0（状态屏和全 App 的视觉对齐）、0.5.0（2026-10-19；便签）、0.6.0（latest，2026-10-24；启动台、功能开关、便签的四个新功能和同步。这几版都是用户要求发布的，真机手测都还没走完，`macos/HANDTEST.md`「状态屏手测」「视觉对齐手测」「便签手测」「启动台手测」「功能开关手测」照旧待做）。**便签**（屏幕边缘的便签，第七族，0.5.0）2026-10-12 立项、2026-10-18 八批全部做完，2026-10-19 随 0.5.0 发布：⌥N 快速记一条、全部便签窗口（便签墙 / 列表）、屏幕边缘那叠、浮动便签；正文是纯文本 + Markdown 显示样式、任务五种状态、文字颜色、行内图片、查找和撤销，能整个或单条导出成 Markdown 再导回，和剪贴板 / 启动器 / 划词翻译打通；便签有单独的库和每日备份、删除留 30 天。代码在 `Notes/`（39 个文件，§4 文件表），拍板和每批摘要看 PLAN §10「便签」（详细记录在 `docs/archive/PLAN-notes.md`），规矩在 mac-overlay-panel §3 §5 §12、mac-whisker-notes、mac-translate §5、mac-clipboard §1；手测 `HANDTEST.md`「便签手测」1–264，发版前先走冒烟清单「便签」15 步（用户试过几轮、报的问题都修了，清单还没逐条打勾）。**启动台**（第八族，0.6.0）2026-10-18 立项，四批、两轮审查和六轮真机反馈都做完，2026-10-19（0.5.0 发布后）并进 main，2026-10-24 随 0.6.0 发布：拍板和做法在 PLAN §10「启动台」，代码在 `Launchpad/`，规矩在 `mac-launchpad.mdc` + `mac-whisker-launchpad.mdc`，手测在 `macos/HANDTEST.md`「启动台手测」1–66（真机都还没走）。哪些待手测、下一步做什么看 PLAN §12「现状」；手测条目和发版冒烟清单在 `macos/HANDTEST.md`；里程碑 M7–M13、已拍板的 D1–D5 与不迁清单见 PLAN §10。
- Bundle ID `com.yy.kitty-tools.native`（Debug `com.yy.kitty-tools.native.dev`），不再改（改了会丢偏好、钥匙串和授权）；产品名 / .app 名 `Kitty Tools`（Debug `Kitty Tools Dev`，2026-09-26 起，之前叫 Kitty Tools Native）。和 Tauri 旧版同名：安装前先删掉 /Applications 里旧版的 `Kitty Tools.app`。
- **规格**：各 `mac-*` 规则（界面与动效按 `mac-whisker`）+ 对标产品（启动器 Alfred / Raycast、翻译 Bob、截图 iShot / CleanShot、录屏 CleanShot / ⌘⇧5、录音 QuickTime / iShot、剪贴板 Paste）。`macos/PLAN.md` 只留仍有效的：§2 技术栈白名单、§4 架构与文件表、§8 打包、§10 约束与已拍板决定、§11 旧逻辑问题与语言规则、§12 现状与下一步；迁移期历史（§5 的 Tauri 映射、§6 数据迁移等）和已完成批次的实现记录原样归档在 `macos/docs/archive/`（PLAN 原位置写了去处）。
- **Windows 原生版**在 `windows/`（C# + WinUI 3，2026-10-23 立项，第一版剪贴板 / 翻译 / 启动器 / 截图，用户的 agent 分批实现、Claude 审查）：规矩和方案在 `windows/AGENTS.md`、`windows/PLAN.md`。本文件其余部分和 `.cursor/rules/mac-*.mdc` 只管 `macos/`；Windows 的提交写成 `<type>(win): …`，release 不标 latest。

## 技术栈

- Swift 6.2，Swift 6 语言模式，默认 `MainActor` 隔离 + approachable concurrency。
- SwiftUI（`MenuBarExtra`、`Form`、`@Observable`）+ AppKit（`NSPanel` 浮层、设置窗）。
- 系统 libsqlite3、钥匙串、Carbon 热键、AX、Vision、NaturalLanguage 等 Apple 框架，完整清单见 PLAN §2。
- 第三方依赖：运行时 0 个，开发期 0 个。
- Xcode 26.3 工程，构建设置全在 xcconfig；`hdiutil` 打 DMG；Apple Development 签名（Team `HTX9F4KG39`），不公证。

## 目录结构

```
macos/                       # 本分支唯一开发区
├── KittyTools.xcodeproj/    # 共享 scheme：KittyTools
├── KittyTools/              # 同步文件夹：App/ Shell/ Storage/ Clipboard/ Translate/ Launcher/ Launchpad/ Screenshot/ StatusScreen/ Notes/ Settings/ Resources/
├── KittyToolsTests/         # 纯函数单测（Swift Testing），M2 起建
├── Config/                  # Base/Debug/Release.xcconfig、Info.plist（局部）、Secrets.xcconfig（不入库）
├── build-dmg.sh             # 打包：archive → 自检 → DMG + App 内更新用的 zip → notes
├── status-emoji.swift       # 状态屏的动画表情：下载好的动画 PNG → Resources/status-emoji-*.heics（只用 ImageIO）
├── brand-icons.swift        # 品牌图标：角色「探头」的 AppIcon 10 张 + 菜单栏剪影 StatusIcon + DMG 背景（CoreGraphics 生成）
├── .swift-format
├── PLAN.md                  # 仍有效的方案：§2 技术栈、§4 架构与文件表、§8 打包、§10 约束与决定、§11 实现原则、§12 现状与下一步
├── HANDTEST.md              # 发版冒烟清单 + 各批手测条目（原 PLAN §12，编号不变；新的手测加在这里）
└── docs/archive/            # PLAN 挪出去的迁移期历史和已完成批次的实现记录（原样，只查不改）
.cursor/rules/               # mac-native.mdc（常驻）、ponytail.mdc（只给 Cursor）、各 mac-* 规则（mac-whisker 拆成核心 + mac-whisker-<界面>.mdc）
.claude/skills/mac-*/        # 按需技能，里程碑结束后补
```

新文件放哪、叫什么，照 PLAN §4 的文件表；一个概念一个文件，不预建空目录。

## 常用命令（仓库根目录执行）

```bash
# 构建 / 单测（联网冒烟：前面加 TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，会真请求内置智谱；
# 菜单开着时热键自检：TEST_RUNNER_KITTY_LIVE_HOTKEY=1 跑 HotKeyMenuTests，会弹真菜单、发合成按键（还有录屏倒数的临时 Esc：屏外面板短暂当 key；
# 录屏显示按键靠的两条系统行为：热键 keyDown 监听收不到、本进程发的合成按键不进胶囊，会向前台 App 发一次没人用的 ⌃⌥⇧⌘F19）；
# 应用内更新整条链路：TEST_RUNNER_KITTY_UPDATE_ZIP=<build-dmg.sh 出的 _arm64.zip 绝对路径> 跑 UpdaterTests，只替换临时目录里的假 App）
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools build
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools test

# 录屏 / 录音实录自检（要「屏幕录制」授权；会录下当前屏幕、闪色块窗口、铺一块滚动大面板约 30 秒、放几声提示音；目录写绝对路径，
# 整屏原始视频留在里面，看完删；报告在 <目录>/report.md）。麦克风几项另加 TEST_RUNNER_KITTY_LIVE_RECORD_MIC=1，闪退两步走 _KILL=1 / _INSPECT=1。
# 只验某块产品代码就 -only-testing 到单个函数，如 'KittyToolsTests/RecordingProbeTests/screenRecorderTake()'：各函数验什么、要不要 _MIC
# 见 RecordingProbeTests.swift 文件头；文件头没写的 formatTake(_:)（清晰度 / 编码各录约 2 s、再各压缩一遍，第二轮体检第 5 批）不用 _MIC
TEST_RUNNER_KITTY_LIVE_RECORD_DIR=/tmp/kitty-record xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:KittyToolsTests/RecordingProbeTests

# 核对关键构建设置（期望 6.0 / 15.0 / NO / MainActor）
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools -configuration Release -showBuildSettings \
  | grep -E '^ *(SWIFT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_APP_SANDBOX|SWIFT_DEFAULT_ACTOR_ISOLATION) ='

# 格式：lint 无输出才算通过；format 就地改写
xcrun swift-format lint --strict -r macos/KittyTools
xcrun swift-format format -i -r macos/KittyTools

# 界面截图自检：屏幕外渲染各状态（含深色）为 PNG，不弹窗、不抢键盘（整套约 8 分钟、CPU 占用高，用户在用电脑时别反复跑；
# 只改了一族界面就再加 TEST_RUNNER_KITTY_SNAPSHOT_ONLY=clip-,launcher-（只出文件名以这些前缀开头的图，一两分钟）；
# 只改了状态屏就只跑它那一个函数，几秒钟：-only-testing:'KittyToolsTests/SnapshotProbeTests/statusScreen()'；
# 设置 › 状态屏、快捷键页和速查表页头是 statusScreenSettings()，十几秒；选状态的面板是 statusPicker()；
# 便签（快速记一条、全部便签窗口连工具栏（列表视图 notes-window-*、便签墙 notes-wall-*）、正文里的任务和 Markdown、行距三档和代码块、纸色表、设置 › 便签、快捷键页 / 速查表 / 启动器里的三项）是 notes()，
# 不到一分钟，图都以 notes- 开头：-only-testing:'KittyToolsTests/SnapshotProbeTests/notes()'；
# 便签屏幕边缘那叠（药丸、标签列、预览卡、打开的便签、设置 › 便签「屏幕边缘」）是 notesDeck()，约一分钟，图以 notes-deck- 开头：-only-testing:'KittyToolsTests/SnapshotProbeTests/notesDeck()'；
# 浮动便签（浅深、固定 / 没固定、8 种纸色、最小尺寸、操作菜单、那叠里浮着那条的标签）是 notesFloat()，约半分钟，图以 notes-float- 开头：-only-testing:'KittyToolsTests/SnapshotProbeTests/notesFloat()'；
# 设置 › 通用「同步」那一节（没开、第一轮、好了、等确认、停了、便签关着、它在通用页里的位置）是 sync()，几秒，图以 sync- 开头）
TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/kitty-shots xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:KittyToolsTests/SnapshotProbeTests

# 状态屏的事件拦截实机自检（按需，要「辅助功能」授权；**拦截是全吞的：建着的那约半秒里真实的键盘鼠标也会被吞**，跑之前
# 手离开键鼠，别反复跑。状态屏本身任何自动化都不许真的进入，见 mac-overlay-panel §11）
TEST_RUNNER_KITTY_LIVE_INPUT_BLOCK=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test '-only-testing:KittyToolsTests/StatusScreenTests/liveBlockSwallowsKeys()'

# 面板关闭淡出的屏上实录自检（按需，要「屏幕录制」授权；屏幕右下角闪两次小面板，逐帧看关闭时亮度不冒尖——改了 OverlayPanel.dismiss、
# 面板材质，或上 macOS 26 的玻璃分支后跑）
TEST_RUNNER_KITTY_LIVE_PANEL_FADE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/PanelFadeTests/closingNeverBrightens(appearance:)'

# 启动台（第八族）：屏外渲染各状态，图以 launchpad- 开头（第一页、第二页、搜索、文件夹打开、抖动、拖动、设置页），
# 不到一分钟：-only-testing:'KittyToolsTests/SnapshotProbeTests/launchpad()'
# 启动台动画的屏上实录自检（按需，要「屏幕录制」授权；**屏幕左下角会出现一块 640 × 400 的窗口约 5 秒**，放在所有窗口后面、不当 key，
# 跑之前先跟用户说一声）：录文件夹开 / 关、进出抖动、让位的每一帧（PNG + report.md），查开关有中间帧、进出抖动不闪。
# 屏外截图画不出动画中途和离场视图的层次，改了启动台的动画后跑它
TEST_RUNNER_KITTY_LIVE_LAUNCHPAD_ANIM=/tmp/kitty-launchpad-anim xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/LaunchpadAnimationLiveTests/recordAnimations()'

# 内存探针（按需，约 7 分钟，屏外量缓存 / 识字 / 各面板 / 回收接口各占多少；报告追加在 <目录>/report.md，用法和四个坑见测试文件头；
# 量面板的图层要再加 TEST_RUNNER_KITTY_MEMORY_PROBE_ONSCREEN=1：屏外的窗口系统不画图层，开了之后屏幕右上角有一块几乎透明的面板）
TEST_RUNNER_KITTY_MEMORY_PROBE_DIR=/tmp/kitty-memory xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/MemoryProbeTests/measure()'

# 便签「点另一条」的屏外量测（按需，约两分钟；300 条便签在屏外的全部便签窗口和屏幕边缘那叠里来回切，量到正文框排好的时间和
# 主线程 CPU，结果 grep「notes-probe」；用法和拿 sample 看主线程的循环模式见测试文件头。前后对比用同一种构建）
TEST_RUNNER_KITTY_NOTES_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/NotesProbeTests/switching()'

# 便签第 8 批的量测（按需；1 MB 每行带颜色的正文 vs 没颜色，打一个字 / 挪光标；300 条便签 50 张图导出再导回；
# 结果 grep「notes-probe batch8」；和上面那个探针分开开关）
TEST_RUNNER_KITTY_NOTES_COLOR_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/NoteBatch8ProbeTests/measure()'

# 便签正文编辑器的随机探针（按需；改了正文的排法——NoteStyles.apply、NoteTextView.restyleEdited / syncMarkers、roleChanges、
# 加跨行的语法——先跑：屏外一个真的 NoteTextView 随机打字、加标记、改围栏、撤销重做、组字、换设置、外面换正文，每步和整篇排一遍
# 逐字比；步数随便给，2 万步 Debug 约半分钟，差异写在失败信息里；另可加 TEST_RUNNER_KITTY_NOTES_FUZZ_SEED=<起始种子> 换一批）
TEST_RUNNER_KITTY_NOTES_FUZZ=20000 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/NoteEditorFuzzTests/randomEditsMatchWholeText()'

# 启动台的性能 / 内存探针（按需，屏外，几秒；grep「launchpad-probe」：扫目录、第一帧、翻页布局、footprint）
TEST_RUNNER_KITTY_LAUNCHPAD_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/LaunchpadProbeTests/measure()'

# 启动台布局的随机操作测试：随机挪 / 建文件夹 / 拖出 / 删 / 装新 App / 卸 App / 改行列数，每步查不变式；
# 步数随手给（默认 1500，2 万步几秒钟），换种子加 TEST_RUNNER_KITTY_LAUNCHPAD_FUZZ_SEED=<种子>
TEST_RUNNER_KITTY_LAUNCHPAD_FUZZ=20000 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:'KittyToolsTests/LaunchpadFuzzTests/randomOperationsKeepInvariants()'

# 打 Release DMG + App 内更新用的 zip（产物在 macos/build/）
macos/build-dmg.sh

# 重新生成 App 图标、菜单栏剪影和 DMG 背景（改角色或产品名只改这个脚本；加一个目录参数另存放大预览）
swift macos/brand-icons.swift

# 状态屏的动画表情：把下载好的 Microsoft Fluent Emoji Animated 动画 PNG 转成包里用的 HEICS（要加表情时才跑；
# 原文件不进仓库，本机留在 macos/build/status-emoji/src/；清单在脚本和 StatusScreen/StatusEmoji.swift 两处）
swift macos/status-emoji.swift macos/build/status-emoji/src

# 签名自检；辅助功能授权卡住时重置（按 bundle id，.app 改名不影响）
codesign -d -r- <App 路径>
tccutil reset Accessibility com.yy.kitty-tools.native.dev
# 要重测第一次开麦克风的授权流程时（实录自检会给 Dev 版要到麦克风授权）
tccutil reset Microphone com.yy.kitty-tools.native.dev
# 重置了文件夹授权（SystemPolicyDownloadsFolder 等）时，把「问过」的标记也清掉，免得启动器文件搜索按旧状态读目录弹框
defaults delete com.yy.kitty-tools.native.dev folderAccessRequested
```

## 规则与技能

| 名称 | 类型 | 状态 | 何时加载 / 触发范围 |
|---|---|---|---|
| `mac-native` | 常驻规则 `.cursor/rules/mac-native.mdc` | 已有 | 始终加载 |
| `ponytail` | 常驻规则 `.cursor/rules/ponytail.mdc` | 已有 | 只给 Cursor；Claude 侧由用户级插件生效 |
| `mac-overlay-panel` | 技能 | 已有（M1，M9 补截图与钉图，2026-10-10 补状态屏，2026-10-13 补便签的边缘那叠、便签编辑器和撤销 / 重做、正文里的 Markdown，2026-10-14 补浮动便签，2026-10-16 补便签墙和行内图片，2026-10-17 补导出导入、任务五态、文字颜色，2026-10-18 补快速记一条和全部便签窗口、整包覆盖，2026-10-22 补图片的宽度档位和裁切、取色面板、同时浮几张） | `Shell/**`、`Screenshot/**`、`StatusScreen/**`、`Translate/SelectionReader.swift`、`Translate/SourceTextView.swift`、`Notes/` 里除 `Note.swift`、`NoteStore.swift`、`NotesBackup.swift`、`NoteSample.swift` 之外的全部（`NoteCapture*`、`NotesWindow*`、`NoteWall*`、`NoteEdge`、`NoteDeck*`、`NoteFloat*`、`NoteSheet*`、`NotePanel`、`NoteFields`、`NoteTextView*`、`NoteStyles`、`NoteMarkdown*`、`NoteTasks`、`NoteTaskBox`、`NotePaper`、`NoteImages`、`NoteImageStore`、`NoteImageAttachment`、`NoteImageCrop`、`NoteColorPicker`）；NSPanel、热键、前台快照、粘贴回原 App、划词时序、设置窗激活、截图框选遮罩、钉图、状态屏的全屏面板和事件拦截、便签屏幕边缘的药丸和那叠、浮动便签、便签正文的编辑器（TextKit 1、Markdown、行距 / 代码块、行内图片和裁切、五种任务状态、文字颜色）、Markdown 导出导入、从剪贴板 / 启动器粘贴落进便签、输入框里的撤销 / 重做 |
| `mac-launchpad` | 技能 | 已有（2026-10-18，第八族） | `Launchpad/**`、`Settings/LaunchpadTab.swift`；启动台的模型与不变式、App 目录、布局存法、全屏面板、入口与互斥、触控板捏合、触发角、旧库导入、删 App、测试口径 |
| `mac-clipboard` | 技能 | 已有（M3） | `Clipboard/**`、`Storage/Database.swift`、`Storage/Backup.swift`（每日备份、打不开时的恢复）、`Notes/NotesBackup.swift`（便签库平行的那一份，2026-10-12） |
| `mac-translate` | 技能 | 已有（M4） | `Translate/**` |
| `mac-whisker` | 技能 | 已有（2026-09-25；2026-10-03 拆成核心 + 5 个界面文件，2026-10-10 加状态屏一个，2026-10-12 加便签一个，2026-10-18 加启动台一个） | 任何界面、动效、图标改动：先读核心 `rule.mdc`（三种皮肤、刻度、七条弹簧曲线、五个招牌时刻、无障碍、验收），再读那个界面的文件（`launcher` / `clipboard` / `translate` / `capture` / `settings` / `status-screen` / `notes` / `launchpad`.mdc，Cursor 按路径自动带上）；**用户要求以后都按它执行** |

- 规则正文只写在 `.cursor/rules/mac-*.mdc`。技能目录 `.claude/skills/mac-<name>/` 里 `SKILL.md` 只写触发描述和红线速查，`rule.mdc` 是符号链接：`ln -s ../../../.cursor/rules/mac-<name>.mdc .claude/skills/mac-<name>/rule.mdc`。mac-whisker 另有按界面拆出的 `mac-whisker-<界面>.mdc`，技能目录里各一个链接：`ln -s ../../../.cursor/rules/mac-whisker-<界面>.mdc .claude/skills/mac-whisker/<界面>.mdc`。
- 动手前先读对应技能的 `rule.mdc` 全文。没有对应技能的地方按 `mac-native.mdc` 和 `mac-whisker` 执行，文件归属看 PLAN §4。
- 不另建 `mac-ui`、`mac-release`：视觉与动效在 `mac-whisker`，其余 UI 约定在 `mac-native.mdc`，发布约束在 `build-dmg.sh` 头部注释。

## Tauri 版不作参考

- 分支：原生版在 `main`（2026-09-27 由 `macos-native` 改名）；`master` 仍是 Tauri 版，两条线互不合并。
- Tauri 快照（`src/`、`src-tauri/` 等）2026-09-27 按用户要求从本分支删除，仓库里只剩原生工程；要翻旧代码去 master `ee615b3` 或 git 历史。本分支不 merge master，也不以合回 master 为目标。
- **不作行为、界面、默认值、文案的参考**（用户 2026-09-26）：原生版有自己的样式和逻辑，不兼容 Tauri 版的数据和设置（它已不再运行）；以各 `mac-*` 规则、Whisker 和对标产品为准。
- PLAN §5 / §6（已归档到 `macos/docs/archive/PLAN-migration.md`）的 path:line 指的是 master 上的文件，只是迁移期的历史记录，不再是规格。

## 开发约定

- 用中文回答用户；文档写中文，代码注释可以写中文。
- 每个入口文件头部写注释说明用途。
- 禁止新增任何第三方依赖（SPM 包、构建 / 格式化工具都算）。
- 刻意的简化写 `ponytail:` 注释，写明上限和升级路径。
- commit 格式 `<type>: <description>`，type 取 feat / fix / ui / refactor / docs / perf / build / chore。**标题一行、70 字以内，空一行再写正文**：为什么改、改了什么、怎么验的都写进正文（会话开头会自动带上最近几条提交的标题，写长了每个会话都白读一遍）。旧提交不改。
- **更新日志（必遵）**：改 `MARKETING_VERSION` 必须在 `macos/KittyTools/Resources/changelog.json` 追加该版本条目，`type` 只允许 feat / fix / perf / ui（refactor / build / chore 不进用户日志）；缺条目时 `build-dmg.sh` 直接中止。
- 发布：本仓库 github.com/YyAdnBug/kitty-tools（不碰 Tauri 版的仓库），tag `macos-v*`，正式 release、标 latest，附 DMG 和 `_arm64.zip`（App 内更新用）；不公证，发布说明固定附「系统设置 › 隐私与安全 › 仍要打开」步骤（只有第一次安装要，之后 App 内更新）。

## 给 agent 的工具

- **Apple API 文档**：任意 `https://developer.apple.com/documentation/<path>` 后面加 `.md` 就能拿到 Markdown，直接 WebFetch（HIG 没有 `.md` 版）。
- **Xcode 自带的 Apple agent 文档**：路径和篇目见 `mac-native.mdc` 文末，只按绝对路径读，不拷进仓库。
- **sosumi MCP**（已接入）：查 Apple 文档、HIG、WWDC 字幕。Claude 读 `.mcp.json`，Cursor 读 `.cursor/mcp.json`，两边同一个 URL `https://sosumi.ai/mcp`。
- **swiftui-expert-skill**（avdlee，已装在用户级 `~/.agents/skills/`，不进仓库）：写 / 审 SwiftUI 代码时加载；macOS 相关看它的 `references/macos-*.md`。它偏 iOS，和本仓库规则冲突时以 `mac-native.mdc` 为准。重装：`npx skills add avdlee/swiftui-agent-skill -s swiftui-expert-skill -g -a claude-code -a cursor`。
- 不用：XcodeBuildMCP、swift-lsp、社区 concurrency 技能。编译诊断以 `xcodebuild` 为准，并发以 Xcode 自带的 `Swift-Concurrency-Updates.md` 为准。
- Claude 的自动记忆按路径隔离，本 worktree 从空记忆开始；仍适用的旧结论已写进 `mac-native.mdc`。
