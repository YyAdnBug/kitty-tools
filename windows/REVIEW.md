# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## v9 剪贴板分工（2026-10-28，用户拍板 PLAN-v9-clipboard D1–D8 全部按推荐）

剪贴板历史对齐 mac（`PLAN-v9-clipboard.md`，PLAN-v9 第 2 批拆成 6a–6g，C1–C3 并在里面）由 **Claude 在自己的 worktree 里做**（D8），做完一小批推一次。

**归 Claude 的文件**（这一轮别的 agent 先别改；真要改先在这里写一句再动）：`KittyTools/Clipboard/**`、`KittyTools.Core/PanelMetrics.cs`、这一轮新加的 Core 文件和它们的测试（`ClipList*`、`ClipLens*`、`SyntaxHighlight`、`ColorFormats` 之类，加了就写在下面）、`Settings/SettingsWindow.cs` 的 `BuildClipboard`、`Settings/ShortcutsSheet.cs` 剪贴板那一组、`App/Settings.cs` 里剪贴板的新字段。

- 6a（数据底子）：见 `git log --grep "6a"`。另动了 `Core/BackupPlan.cs`（备份留「留下的」= 收藏 ∨ 片段）、`Core/Retention.cs`、`Storage/ArchiveService.cs`（导出带片段、导入带收藏夹名单）。新 Core 文件：`ContentForm.cs`、`ClipLens.cs`、`ClipListLayout.cs`、`ClipOrder.cs`，测试 `ClipboardAlignTests.cs`。
- 6b（列表）：见 `git log --grep "6b"`。新文件 `Clipboard/ClipListView.cs`、`ClipRowView.cs`、`ClipIcons.cs`，删了 `ClipRow.cs`；另动了 `Shell/Ui/SearchLine.cs`（加 `ExtendHairline`，启动器不受影响）、`Shell/Glyphs.cs`（RichText / Snippet / StarFilled）、`Launcher/ShellIcons.cs`（`LoadPng` 加 dip 参数，默认 32 不变）、`Storage/Database.cs`（读「带格式」标记；改正文时清掉 HTML / RTF）、`App/UiSnapshotProbe.cs`（clip-search / snippets / favorites / scrolled 四张，`KITTY_CLIP_PERF=1` 量 5000 条按 ↓）、`Core/PanelMetrics.cs`（剪贴板高度照 mac，删了不用的 `ClipboardHeight`）。
- 6c（透镜）：见 `git log --grep "6c"`。新文件 `Clipboard/ClipLensView.cs`、`Core/ClipPreviewRules.cs`；删了 `Core/PreviewRules.cs` 和它的测试（换成 ContentForm / ClipPreviewRules）；`LinkPreviewService` 多取网站图标、加 `Peek`。
- 6d（键盘和菜单）：见 `git log --grep "6d"`。新文件 `Clipboard/ClipPalette.cs`（面板里的筛选 / 操作菜单）；`ClipEntry` 加形态缓存 `Form`；另动了 `Settings/ShortcutsSheet.cs` 剪贴板那一组。

## v9 标注分工（2026-10-27，用户拍板 PLAN-v9-annotate D1–D7 全部按推荐）

截图标注编辑器对齐 mac（`PLAN-v9-annotate.md`，PLAN-v9 第 5 批拆成 5a–5e）由 **Claude 在自己的 worktree 里做**（D7），做完一小批推一次。

**归 Claude 的文件**（这一轮别的 agent 先别改；真要改先在这里写一句再动）：`KittyTools.Core/AnnotationGeometry.cs`、`KittyTools.Core/AnnotationDocument.cs`、`KittyTools.Tests/AnnotationGeometryTests.cs`、`KittyTools/Screenshot/Annotation.cs`、`KittyTools/Screenshot/SelectionOverlayWindow.cs`；`ShotHistoryRules.cs` 里标注 JSON 那几段、`ShotHistory.cs` 的 `ShotAnnotations`。5e 再加尺寸胶囊和工具栏用到的文件，到时写在这里。

- 5a（底子和 B1–B9）：见 `git log --grep "5a"`。
- 5b（十种工具、mac 的画法、样式托盘、每个工具记住样式）：见 `git log --grep "5b"`。另动了 `Shell/Glyphs.cs`（五个工具图标、删掉 ToolSelect）、`Shell/Theme.cs`（托盘选项分段两色）、`App/Settings.cs`（`ScreenshotToolStyles`）、`Settings/ShortcutsSheet.cs`（标注那一组的键）。
- 5c（选中样子、拖手柄 / 拖弯 / 双击拉直、Shift 锁轴、Alt 拖复制、Ctrl+D、方向键、双击文字重新编辑、光标）：见 `git log --grep "5c"`。
- 5d（文字：三档字号、无底 / 描边 / 底色、所见即所得的多行输入框）：见 `git log --grep "5d"`。
- 5e（选区和工具栏：尺寸胶囊输宽高 / 比例锁、Ctrl / Alt + 方向键推收边、空格平移、Ctrl 十字准线、工具栏放哪 / 长出来 / 让位、底块滑动、长截图和录屏按钮、拷贝圆钮、D 上次区域、R 切到录屏、双击拷贝、读屏播报）：见 `git log --grep "5e"`。新文件 `KittyTools/Screenshot/SelectionOverlayWindow.Chrome.cs`、`KittyTools.Core/SelectionChrome.cs`、`KittyTools.Tests/SelectionChromeTests.cs`；另动了 `Screenshot/ScreenshotSession.cs`（Mode 可切、LockedRatio、SelectLastRegion、SwitchToRecording）、`Shell/Motion.cs`（Entrance 加 rise 参数，默认不变）、`Shell/Glyphs.cs`（LongScreenshot）、`KittyTools.Core/RegionMath.cs`（ApplyingRatio 改成顶边不动，以前没人用、移植时上下弄反了）、`Settings/ShortcutsSheet.cs`、`App/UiSnapshotProbe.cs`。另动了 `Settings/ShortcutsSheet.cs`（文字框 Ctrl+Enter / Esc 收下）、`App/UiSnapshotProbe.cs`（shot-text*.png）。
- 录制条的四个开关换成图标（2026-10-28，用户要的）：`SelectionOverlayWindow.cs` 的 BuildRecordBar，`Shell/Glyphs.cs` 加了关着时的五个图形。

## v8 分工（2026-10-26 深夜，用户定：审查方接着把 mac 新功能搬过来）

方案在 `PLAN-v8.md`（截图历史、标注遮罩、速查表）。审查方在 Mac 上写、**不编译**，推上来由你们编译、截图、手测；编译错直接修，在这一节下面记一句。v7 照常归你们。

**归审查方的文件**（新文件你们不用管；下面这些现有文件只是加几行挂钩，你们照常改，rebase 撞了以你们的为准、把挂钩那几行补回去）：

- 新文件：`Core/ShotHistoryRules.cs`、`Tests/ShotHistoryTests.cs`、`Screenshot/ShotHistory.cs`、`Screenshot/ShotHistoryWindow.cs`、`Screenshot/AnnotateOverlay*.cs`、`Settings/ShortcutsSheet.cs`。
- 挂钩：`Core/Schema.cs`（第 8 步）、`App/Settings.cs`（`ShotHistory`）、`App/HotKeyDefaults.cs`（默认表最后加一项）、`Shell/ShellRuntime.cs`（启动 + 动作分发）、`Shell/TrayMenu.cs`（一项）、启动器的命令表（一项）、`Screenshot/ScreenshotSession.cs` / `SelectionOverlayWindow.cs` / `ScreenshotCard.cs`（记录和「在历史里看」）、录制的几处出口、设置 › 截图页（一个开关）。

**v8 进展（审查方，都没编译过；你们编过后在下面记一句）**：

- 第 1 批 `8d43b40`：存储和记录（你们 `7eff53c` 已在它之上跑过 333 个单测、0 警告）。
- 第 2 批 `e79620d`：历史窗口和入口。顺手把启动器里一直是「第 5 批接上」占位的截图 / 截图翻译 / 识字接上了（先收起启动器 200 ms 再开，不然冻结帧会拍到启动器），另加「录屏」「截图历史」两项。
- 第 3 批上 `036f8b8`：历史里「改标注」——原图 1:1 摆在鼠标所在屏正中当冻结帧（四周深灰），用截图遮罩那一套接着改，拷贝 / 存储 / 钉图时选区没动就回写同一条。比屏幕还大的（长截图）提示不支持。
- **第 5 批（提示带按钮、悬停展开）已交还**（提交见 `git log --grep "v8 第 5 批"`，没编译过）：`Notice.cs` 照常归你们。
  - `NoticeHost.Show(..., params NoticeAction[] actions)` / `ShowProgress(..., actions)`；`NoticeAction(Title, Run, Opens)`，`NoticeActions.Reveal / Open / SystemSettings / AppSettings` 几个现成的。
  - 窗口高度定死在展开卡片的最大高（124 + 上下 8），平时整扇点得穿；提示开着时 33 ms 看一次指针（`_pointerTimer`），指针动过、落在形状上才去掉 `WS_EX_TRANSPARENT`。悬停：停计时、`MeasureCard(expanded: true)` 排一次版、形体弹到卡片大小；离开合回、`max(剩下的, 1.5 s)` 再收。鼠标在上面时别处来的提示排着（`_pending`），按钮自己弹的不排。
  - 加了按钮的地方：截图存储 / 另存为、钉图存储、录屏 / 录音存好（**不再自己弹资源管理器**）、闪退恢复的录屏 / 录音、GIF 好了 + 转的时候「取消」、压缩完成 + 压的时候「取消」、更新失败「重试」、已更新「看更新了什么」、有新版本「更新」、没装识字组件「打开设置」（截图那两处**不再自己弹系统设置**）、复制即译 / 暂停剪贴板「撤销」、剪贴板已关闭「打开设置」、翻译历史删除「撤销」。
  - 调试参数 `--notice-buttons`；`--ui-snapshots` 多 `island-buttons`、`island-expanded`。
  - **最可能要改的**：按钮的轻量样式资源键（`ButtonBackgroundPointerOver` 等）在 WinUI 2.x 里叫不叫这个；`WS_EX_NOACTIVATE` 的窗口里按钮点不点得动（录制条那边是点得动的）；`--notice-anim-test` 的窗口高度变了，量宽度的那段可能要跟着改。验收看 `HANDTEST` 339–345。
- 第 4 批：速查表（`Settings/ShortcutsSheet.cs`），设置的剪贴板 / 启动器 / 截图 / 翻译 / 快捷键五页标题下面加了「查看全部快捷键…」。里面的面板按键是逐个对着现在的按键处理抄的（每组注明了文件），**改了面板按键要同步这里**；R39–R41 修完后跟着改。历史窗口加了 Delete 删选中的那条。
- **第 3 批下（长图标注）先不做**：长图比屏幕高，截图遮罩那一套用不上，要另写一个能滚的长图画布、把标注交互再做一遍（约等于 `SelectionOverlayWindow` 的一半）。mac 那边的用户数据里长截图是 0 次，等用户要了再做。
- **和方案不一样**：画了标注的另存一张成品 `<id>-c.png`（Windows 的 `AnnotationRenderer` 画马赛克要冻结帧，离开遮罩合成不了）；来源程序先不记；角落缩略图卡没有右键菜单，「在历史里看」没加。
- **要验**：`ShotHistoryTests`；截图拷贝 / 存储 / 钉图 / 长截图 / 录屏 / 录音 / GIF 各来一次，`%LOCALAPPDATA%\KittyTools\shots\` 和 `shots` 表对得上；历史窗口每个操作；改标注后缩略图跟着变、再打开看到改过的标注；`Annotation` 以后加了字段（比如空心 / 实心）要在 `ShotAnnotations` 里一起存。

## v7 分工（2026-10-26 深夜，用户定）

用户让审查方（Claude，在 Mac 上，**不编译**）分着做 PLAN-v7 里你们还没动的两块。写完推上来，编译、截图、录屏由你们验；有编译错误直接修，在这一节下面记一句。

**归审查方的文件**（这一轮你们先别改；真要改先在这里写一句再动）：

1. **轻提示（§2.3、§3.4）**：`KittyTools/Shell/Notice.cs` 整个文件。另加 `NoticeHost.ShowProgress`（56 × 4 细进度条），只改三处调用里报进度的那几行：`Recording/GifService.cs`、`Recording/CompressionService.cs`、`App/AutoUpdater.cs` 的 `OnProgress`。
2. **界面对齐手测（§5 第 6 批）**：`HANDTEST.md` 里新加的「界面对齐手测」那一节（只追加这一节；你们别的手测照常往文件后面加）。

**归你们**：v7 其余的全部（剪贴板、启动器、翻译浮窗、截图与录制、设置窗、`Motion.cs`、`Styles.xaml`、changelog、STATUS）。

审查方做完会在这里写「已交还」，之后这些文件照常归你们。

**已交还（审查方，2026-10-26 深夜，提交见 `git log --grep "v7 轻提示"`；没编译过）**：上面这些文件从现在起照常归你们，编译错直接修。

- `Notice.cs` 重写：窗口一次定死在最大宽（左右透明边 24：island 弹簧冲过头约 8% 加抖动 7），黑底是 `ShapeVisual` 里的 `CompositionRoundedRectangleGeometry`，内容层用同一组尺寸的 `CompositionGeometricClip` 裁；宽度动画是 `SpringEase` 采样成 20 个表达式关键帧（`Lerp(this.StartingValue, target, k)`），中途换内容从当前大小接着走，主线程每帧不排版（原来 16 ms 定时器改 XAML `Width` 删掉了）。出现：36 的圆 → 实际宽度，内容晚 60 ms 淡入 + 0.9 → 1（顶边锚点）；原地换内容只动宽度；错误抖 [0, −7, 6, −4, 2, 0] 0.4 s（`Motion.Shake` 现在没人用了，要删随你们）；收起：内容 0.12 s 退场，0.08 s 后形体 retract 缩成圆、最后 0.12 s 淡掉，`CompositionScopedBatch` 走完才 `Hide`。胶囊顶边离工作区顶边 8（原来是 22），white 0.12 发丝线；信息的符号用 `OnAccent`。原来 `_shown` 收起后不复位、第二次出现不再从圆长出来，一起改了。
- `NoticeHost.ShowProgress(title, detail, fraction)`：标题后面 56 × 4 细进度条（填充按比例横向缩放，0.2 s 线性），同标题原地改、不重新出场、不播报，60 s 兜底。接了三处：转 GIF、压缩、下载更新（后两处的回调在线程池，切回 UI 线程，结束后才到的回调丢掉）。
- **压缩进度的单位**：`TranscodeAsync` 报的是 0–100 的百分数（learn.microsoft.com「Transcode media files」的示例参数就叫 percent），原来 `Progress = progress` 存进去、托盘按 `Progress * 100` 显示，会出「压缩中 4300%」。改成存 0–1。压一次看日志 `video.compress-progress` 是不是 0–100 往上走；要是本来就是 0–1，把 `/ 100` 去掉。
- `HANDTEST.md` 加了「第七版：界面对齐手测（细项，302–329）」，逐条是 PLAN-v7 §2–§4 的数值；轻提示是 316–320。
- **要验**：编译；`--notice` / `--notice-error` 录 3–5 秒（PLAN-v7 第 3 批的验收：长出 / 换内容 / 抖动 / 缩回）；`--ui-snapshots` 的 `island-notice`、`island-error`；HANDTEST 316–320。最可能要改的：表达式关键帧的写法（报错就看 `this.StartingValue` 和 `Lerp` 的参数类型）、`Translation.X` 动画（`SetIsTranslationEnabled` 已在构造里开）。

**Windows 这边验过（2026-10-26 深夜，Claude 的 worktree）**：`Notice.cs` 原样编过（Debug、AOT x64 / ARM64 都 0 警告），没有编译错。新加 `--notice-anim-test=<目录>`（`App/NoticeAnimationProbe.cs`）：WGC 只抓提示窗口，逐帧量胶囊宽度，依次放长出 → 原地换长内容 → 出错 → 停留到点缩回。结果：形状和顺序都对，四段动画期间 XAML 排版 0 次；**改了一处**——表达式的 `Lerp(this.StartingValue, target, p)` 在 Composition 里把 p 夹在 [0, 1]，island 的回弹冲不过头（量到最大宽 = 最后宽：36 → 104、104 → 372）。`PillAnimation` 改用共用的 `Motion.CurveTo`（`start + (target − start) × p`），之后 36 → 112 → 104、143 → 402 → 372。另外 `Notice.cs` 只加了一个给探针数排版次数的 `LayoutPassesForProbe`。帧图见 `windows-shots/0.7.0-v7/island-anim-*.png` 和 `island-anim-report.md`，`--ui-snapshots` 的 `island-notice` / `island-error` 也用合并后的构建重出了（`12b0d71`）。

## 待修

（2026-10-26 晚复查到 `3fe1725e`：R22、R25、R26、R28、R29 认可；R23 认可，60 s 和 10 分钟的重封装耗时并进 R24 一起量；R30 认可，托盘和 HUD 的截图见 R33。新加 R31–R35。R24 一直没动，排在最前面。）

（2026-10-26 夜：安装程序写完了（`616840b`，没编译过），新加 R36–R38。R36 排在 R24 前面先做：没编过的 Setup 不进 slnx，但 Core 单测里已经有它的测试。）

（2026-10-27：审查方在 Mac 上把代码过了一遍，找还能优化、没优化的地方，新加 R42–R52，行号都对着 `e82715d2`。每一条都读过代码确认过，只是没在 Windows 上量过：**改之前先量一次、改完再量一次**，两个数都写进报告；量出来不值得改的，写上数挪到「有异议」。顺序：R41 修完先做 R42–R44（P1），再做 R24；P2、P3 照常一条一条来。功能缺口另写在 `PLAN-v9.md`，那是拍板页，用户拍板之前别动。）

（2026-10-27 晚：用户定 Windows 第一个对外版本叫 0.1.0、主打剪贴板 / 截图 / 翻译，新加 R53（发版清单）和 R54–R64（这三样里的 bug，行号对着 `0533b3ae`）。**R53 排在所有待修前面**，R42–R52 里不挡发版的照旧往后排。）

### R53（P0）0.1.0 发版：先修下面这些，再打包

用户 2026-10-27：「你找出来，然后我 windows 上打包，并且 windows 就是 0.1.0 版本，没有现在那么多个版本」。Windows 的第一个对外版本叫 **0.1.0**，主打**剪贴板历史、截图、翻译**。

**0.1.0 分工（2026-10-27 中午，用户：「要不你来接手」，随后「我的 agent 本地修改的代码我都回退了，都交给你」）**：
- **代码全部归审查方**（在 Mac 上写、不编译）。R54–R63 是你们推的（`cc019fcc`…`589511c4`），审查方复查过，都认可。
- **你们只做这些**：
  - `git fetch && git rebase origin/windows-wip`，编译，编译错、单测红直接修，在这一节下面记一句；
  - 装 Inno Setup 7，照第 6、7 步打包、跑 `setup-e2e.ps1`、手测（`HANDTEST.md` 351–366 是这一轮新加的），写报告。
  - 行为不对的，先在这里写一句，再改。
- **审查方的进度**：
  - `53d609e9` 第 4 步：R41 第一条、R44、R46、R47、R48 第一条、PLAN-v9 V2；
  - `9efc8da9` R64 五条：都按建议写了，**没在 Windows 上验过**，手测 358–362；
  - R66 托盘菜单换成系统的 Win32 菜单、安装程序加桌面快捷方式（`git log --grep R66`，用户真机反馈），手测 367–370；
  - R67 用过一次右键菜单后点图标打不开（`git log --grep R67`），手测 371；
  - R65 Inno 安装程序（`git log --grep R65`）：`installer/KittyTools.iss`、App 的 `--quit` / `--uninstall-cleanup`、`SetupRecord` 改认 Inno 的登记、删掉 `KittyTools.Setup` 和 `Core/SetupPayload.cs`、`build-release.ps1` 调 ISCC、`setup-e2e.ps1` 重写。
- **最可能要改的**：
  - `.iss` 的 Pascal 没用 ISCC 编过；
  - `CheckForMutexes` 认不认 `Local\` 前缀；
  - `{param:...}` 在卸载程序里能不能用；
  - `DisableReadyPage=yes` 时更新会不会照样出准备页（按钮文字设在 `wpReady` 上）；
  - `Recovery.AskAndRepairAsync` 里 `Window.Activate()` 之后 `Loaded` 来不来。

审查方已经提交了（在 Mac 上改的，**没编译**）：
- `Directory.Build.props` 版本改成 0.1.0；`changelog.json` 的七条内部版本合成一条对外的 0.1.0。
- `Shell/Feature.cs`：启动器和录屏没存过时默认关（`DefaultOn`，带 ponytail 注释）。启动器读浏览历史、默认值还没对齐 mac（R42、PLAN-v9 V1），录屏真机没走完（R24）。欢迎页的快捷键说明跟着改了（`Settings/SettingsWindow.cs` 的 `BuildWelcome`）。
- `AGENTS.md`「版本和发布」、`STATUS.md` 开头、PLAN-v9 的最后一批改成新编号。

**顺序**：

1. 编过审查方这次的改动。`--smoke` 里还直接开启动器面板和录音条，功能关着也该能开；开不了就把 smoke 里那两步跳过，别为了 smoke 把默认值改回去。
2. 修 R54–R63（这三样里的 bug，审查方读代码找的，都核过代码）。
3. 在 Windows 上验 R64 的五条，是真的就修。
4. 修已有待修里影响这三样的：
   - R41 第一条（剪贴板 Ctrl+K 里按 Enter 不执行）；
   - R44（每截一次图，设置窗就在后台重建一页）；
   - R46（剪贴板后台识字大图不缩、失败了每次启动重来）；
   - R47（每日备份跨线程读数据）；
   - R48 第一条（钉图「复制」卡界面）；
   - PLAN-v9 的 V2（识字默认不接行，截图翻译照旧接）。这一条用户还没拍板，审查方替用户定先做：只是改默认值、加一个开关。
5. **不挡 0.1.0**：R42、R24（启动器、录屏默认关了）；R43（长截图拼长了会卡）、R45（长译文流式会卡）能顺手修就修，修不完写进下面的「已知问题」；R49–R52、PLAN-v9 的其余项照旧往后排。
6. 先做 R65（安装程序换成 Inno Setup 7），再打包：`dotnet test` 全过 → `pwsh windows/build-release.ps1`（AOT x64 / ARM64、零警告、`--smoke`、zip、Inno 编的 setup.exe）→ `pwsh windows/tools/setup-e2e.ps1` 五步全过 → 产物在 `windows/build/release/0.1.0/`。
7. 手测，用 `KittyTools-0.1.0-windows-x64-setup.exe` 装一次。开发机上用旧安装程序装过的，先用它的 `Uninstall.exe` 卸掉（PLAN-setup-inno I14，不做迁移）：
   - `HANDTEST.md`「发版冒烟清单」的 1、2、3、5、6、8、9、15、16、17，第 7 条里除了启动器的部分；
   - 截图历史（333–338）、长截图（216–224 里长截图那几条）、提示带按钮（339–345）；
   - R54–R64 每条修完的那个场景再走一遍。

   没走的写「没测」，别打勾。
8. 报告：做了哪些、量到的数、产物路径和大小、没修的写成「已知问题」（一条一句）。**不发布**；用户要发时，tag 用 `windows-v0.1.0`、`--latest=false`、别标预发布（`App/UpdateService.cs` 只认非预发布的 `windows-v*`）。

**Windows 侧编译 / 打包时改的（2026-10-27）**：
- rebase 到 `2efae4cc` 后 Debug、Release AOT x64 / ARM64 都直接编过，零警告，325 个单测全过；`KittyTools.iss` 用 ISCC 7.1.0 直接编过，没改。
- Inno 7 的 winget id 是 `JRSoftware.InnoSetup.7`（`JRSoftware.InnoSetup` 装的是 6.7.3）：`build-release.ps1`、`setup-e2e.ps1` 的报错提示改了。
- `setup-e2e.ps1` 第 3 步没过（exit 7，程序没被叫退）：`--quit` 送到了（日志有 `instance.quit` / `app.exit`），但 `Application.Current.Exit()` 之后总剩一扇窗没关（预建的浮层；显式关了浮层就剩 `_keeper`），消息循环不结束，进程留着互斥量。去掉 R64 A 的 Closing 也一样，不是它。托盘「退出」、更新后退出走的是同一个 `ShellRuntime.Exit`，也受影响。改：`Exit()` 收尾做完后起一个后台线程，2 秒后还在就 `Environment.Exit(0)`（日志 `app.exit-forced`，带 ponytail 注释）。根因没找到。

### R54（P1）「截取上次区域」裁的是屏幕左上角那一块 → 已修（`d07959f`）

- `Screenshot/ScreenshotSession.cs:370`：`new PixelBounds(0, 0, global.Width, global.Height)` 从屏幕的 (0, 0) 开始裁，上一行算好的 `local`（减掉了 `screen.Bounds`）没用上。`Crop`（`Screenshot/ScreenCapture.cs:38`）吃的是这块屏里的像素坐标。
- 触发：在屏幕中间截一次图，再按 Ctrl+Alt+Z。复制出去的、飞入卡、截图历史里，都是屏幕左上角同样大小的一块。
- 改：`new PixelBounds((int)local.X, (int)local.Y, (int)local.X + global.Width, (int)local.Y + global.Height)`；加一条副屏上的手测。

### R55（P1）标注的撤销差一步：画完第一条按 Ctrl+Z 没反应 → 已修（`a86db3c`）

- `Screenshot/SelectionOverlayWindow.cs:1089`：矩形、箭头、画笔、马赛克一按下就加进 `_annotations`；松手时（:1258）才 `PushUndo()`，存进撤销栈的那份已经带着这一条，`Undo`（:435）还原出来的和现在一模一样。
- 触发：画一个矩形，按 Ctrl+Z 或点工具栏的撤销，没反应；画几条再撤，永远差一步。
- 改：按下、加进列表**之前** `PushUndo()`；松手时太小被丢掉的，把刚压进去的那份弹出来（不然要空撤一步）。文字工具、拖着挪标注那两条路（:289、:1052）也对一遍有没有同样的毛病。

### R56（P2）从托盘、设置窗打开面板，会粘进上一次的旧窗口 → 已修（`8ff846a`）

- `Shell/OverlayWindow.cs:129–133`：呼出时前台如果是本 App 自己的窗口（托盘菜单、设置窗、截图历史、钉图），就不更新 `_previousForeground`，留着上一次的。
- 触发：先往记事本粘过一次；之后点托盘「剪贴板历史」，选一条按 Enter，记事本被拉到前台、内容粘了进去。
- `Translate/TranslateWindow.cs:451–457` 的 `_replaceTarget` 同样：在剪贴板面板里 Ctrl+T 打开浮窗，点「替换原文」，粘进上一次翻译时的那个窗口。
- 改：前台是自己的窗口时，把目标清成 `default`，只复制、不粘贴，提示说「已复制」。Windows 的托盘菜单会抢前台，拿不准要粘到哪就别粘。

### R57（P2）复制即译：翻译关了照样弹；剪贴板关了它也跟着停 → 已修（`3203948`）

- `Translate/TranslateHost.cs:139` 的 `OnTextCopied` 不看翻译功能开没开。设置里关掉「翻译」后，复制文字照样弹浮窗；托盘里「复制即译」的开关又因为翻译关了被藏起来，关不掉。
- `Clipboard/ClipboardService.cs:65`：复制即译挂在剪贴板采集后面（:125 `TextCopied`）。关掉「剪贴板」功能、或者托盘里暂停记录以后，这里直接 return，复制即译就悄悄不工作了。
- mac 的做法（`App/AppDelegate.swift:2377`，以及 `applyFeatures` 里「剪贴板关着时只为复制即译跑、不入库」）：翻译开着才译；剪贴板关着时照样监听，只是不入库。
- 改：
  - `OnTextCopied` 先查 `Features.IsOn(Feature.Translate)`；
  - `Suspended` 时照样读文本、发 `TextCopied`，只是不入库；
  - 隐私标记、排除的 App、敏感文本、`_selectionPaused`（划词自己发的 Ctrl+C）这几道照样挡；
  - 「暂停记录」时复制即译停不停，照 mac 的 `isUserPaused` 那一处定。

### R58（P2）划词超过 2048 个字符，后面的直接丢掉 → 已修（`0e32e02`）

- `Translate/SelectionReader.cs:111`：UIA 取词用的是 `GetText(2048)`。
- 触发：在浏览器或 Word 里选 3000 字划词翻译，只翻了前 2048 个字符，没有任何提示（输入翻译的上限是 32 KB）。
- 改：`GetText(-1)`，长度交给后面那道 32 KB 的检查；超了照输入翻译那样提示。

### R59（P2）超过 2 MB 的 HTML / RTF 被截了一半存下来，不是丢掉 → 已修（`da9a6ca`）

- `Clipboard/ClipboardFormats.cs:495` 的 `ReadRich` 调 `ReadBlob(format, MaxRichBytes)`，`:523` 的 `Math.Min` 把超长的截断；`MaxRichBytes`（:46）的注释说的是「超过就只留纯文本」。
- 触发：复制几千行的 Excel 区域、带内嵌图片的网页，再从历史里粘回 Word / Outlook，格式是坏的，或者只出来一部分。
- 划词走 Ctrl+C 兜底时，`CaptureSnapshot`（:128 起）还原回去的也是截断版，等于把用户剪贴板里原来的富文本弄坏了。
- 改：`ReadRich` 改用 `ReadBlobWithin`（超了返回 null），和图片那几处一样。

### R60（P2）多选粘贴、替换原文：失败了还显示成功 → 已修（`8ea0d48`）

- `Clipboard/ClipboardPanel.xaml.cs`：
  - 依次粘贴失败时，`break`（:1419–1420）只跳出循环，接着 :1429 照样显示「已依次粘贴 N 条」，把刚报的错盖掉（`NoticeHost.Show` 是原地换内容）；
  - 一起粘文件时（:1395–1399）不看 `Paster.Paste` 的返回值，`Paster` 自己弹的「没能切回原窗口，请手动粘贴」「目标是管理员窗口」会被马上换成「已一起粘贴」。
- `Translate/TranslateWindow.cs` 的 `ReplaceWith`（:885 起）也一样：失败时把 `Paster` 给的具体原因换成「没能切回原窗口」。
- 改：失败就 return，看返回值再报成功；`ReplaceWith` 失败时不再另报一遍。

### R61（P3）片段里的 `{uuid}` 每次都一样 → 已修（`70e5814`）

- `Clipboard/Expander.cs:25`：传进去的是片段自己的 `Uid`，每次粘贴、同一片段里的几处都是同一个值；mac 是每处各生成一个新的。
- 改：`SnippetRules.Expand` 的 uuid 参数改成一个生成函数，每处现生成一个 `Guid`；单测补「同一片段两处不一样、两次粘贴不一样」。

### R62（P3）长截图进剪贴板历史，记的是选区的尺寸 → 已修（`7ab0e01`）

- `Screenshot/ScreenshotSession.cs:440` → `ScreenshotOutput.CopyPngAsync`（:33）按选区算宽高。
- 触发：拼出一张 1440 × 12000 的长图，剪贴板列表、预览角标、「已复制截图」提示都写着选区的大小（比如 1440 × 800）。
- 改：`CopyPngAsync` 加宽高参数，长截图传拼好的那张的。

### R63（P3）钉图、飞入卡的「复制」失败了没提示 → 已修（`774a6c8`）

- `Screenshot/PinWindow.cs:311`、`Screenshot/ScreenshotCard.cs:431`：剪贴板被别的程序占着、写不进去时，什么都不显示。
- 改：照 `ShotHistoryWindow.CopyAsync` 补一句「没能复制」（错误语气）。

### R64（P1，先在 Windows 上验）五处读代码看着有问题的 → 五条都已按建议写（`9efc8da9`，审查方，没在 Windows 上验）

验出来是真的就按建议修，都挡 0.1.0；不成立的写一句怎么验的，挪到「有异议」。

- **A. Alt+F4 关掉浮层以后，整块功能失灵到重启**：剪贴板面板（`Shell/OverlayWindow.cs`）、翻译浮窗（`Translate/TranslateWindow.cs`）、截图遮罩都没接 `AppWindow.Closing`，只有设置窗接了（`Settings/SettingsWindow.cs:151`）。
  - Alt+F4 之后，`OverlayHost._window`、`TranslateHost._window` 还指着已经关掉的窗口，下次按热键调它会抛异常。
  - 截图遮罩被关时只调 `Release()`（`SelectionOverlayWindow.cs:142`），不走 `Finish()`：`_current` 不清，开截图时注销掉的全局热键（`ScreenshotSession.cs:72`）不再注册；多屏时别的屏上的遮罩还盖着。
  - 验：在剪贴板面板、翻译浮窗、截图遮罩上各按一次 Alt+F4，再按它自己的热键和别的热键。
  - 改：`Closing` 里 `Cancel = true`，改走各自的 Hide / Finish。
- **B. 数据库打不开时，选择框可能出不来**：`Storage/Recovery.cs:138` 在 UI 线程上 `ShowAsync().AsTask().GetAwaiter().GetResult()` 同步等 ContentDialog，`XamlRoot` 是 `Activate()` 之后立刻取的、可能还是 null。结果要么卡死，要么异常被当成「退出」，App 一声不响地退了（HANDTEST 170 没走过）。
  - 验：在测试数据目录里把 `kitty.db` 写成乱码再启动。
  - 改：改成 await；`XamlRoot` 等内容 `Loaded` 以后再取。
- **C. 从剪贴板面板拖出去，可能变成「移动」**：`Clipboard/ClipboardPanel.xaml.cs:406–453` 没设 `RequestedOperation = Copy`（`ScreenshotCard.cs:483` 设了）。图片条目给的是 `images\<id>.png` 本体，文件条目给的是用户的原文件；资源管理器在同一个盘上按默认的「移动」处理时，图片被挪出数据目录（历史里变成图片丢了），用户的原文件被搬走。
  - 验：把图片条目拖到桌面（和 `%LOCALAPPDATA%` 同一个盘），看 `images` 目录和预览；文件条目同样试一次。
  - 改：设成 Copy；图片给一份临时副本。
- **D. 多屏时，在另一块屏上框选后按键可能没反应**：只有一开始光标所在那块屏的遮罩会把焦点给画布（`SelectionOverlayWindow.cs:476–486`、`:503–509`），按下鼠标时也不给。
  - 验：两块屏，光标在 A 屏按截图热键，到 B 屏框一块，按 Enter、Esc、Ctrl+C、1–5。
  - 改：按下鼠标时给画布焦点，激活不只限起始那块屏。
- **E. 输入法组字时按 Enter，可能直接粘贴或翻译**：剪贴板面板的 Enter / Esc / ↑↓（`ClipboardPanel.xaml.cs:1152–1183`，`handledEventsToo`）没看 `_composing`（:47）；翻译浮窗的 `OnSourceKeyDown`（`TranslateWindow.cs:521`）也一样。
  - 验：用微软拼音在剪贴板搜索框里打几个字母，按 Enter 上屏，看是不是直接粘贴了选中的条目；翻译浮窗同样试一次。
  - 改：组字中这几个键直接 return。

### R65（P1）安装程序换成 Inno Setup 7（0.1.0 打包之前做） → 已写（审查方，`git log --grep R65`，没编译、没用 ISCC 编过）

用户 2026-10-27：「安装 exe 的界面太简陋了，市面上没有现成的工具能使用吗，期望优化」，看过几种做法以后定了：「安装程序换成 Inno Setup 7」。现在的安装程序全是系统的任务对话框（PLAN-setup S2），几页白底弹框。

- **方案**：`PLAN-setup-inno.md`，照它做，一批做完。
  - 用户能看到的行为（装到哪、不许装到哪、装过就更新、开着先叫它退出、只问「开机时自动打开」、卸载时问删不删数据）和现在一样，改用 Inno 实现；
  - 长相换成 `WizardStyle=modern dynamic windows11`，跟着系统深浅色；
  - 两组安装图审查方已经出好、提交在 `windows/installer/`。
- **红线例外**：用户同意打包用 Inno Setup 7（只在 `build-release.ps1` 里用，不进 App）。`AGENTS.md` 红线那一条已经写上。装 Inno 用 `winget install --id JRSoftware.InnoSetup.7 -e`，要 7.x。
- **AppId 定死**：`{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}`，以后永远不改。
- **删**：`KittyTools.Setup/` 整个项目、`Core/SetupPayload.cs`、`Core/SetupRules.cs` 的大半、`SetupTests.cs` 跟着删到只剩留下来的函数（PLAN-setup-inno §5）。**加**：`installer/KittyTools.iss`；App 的 `--quit`、`--uninstall-cleanup [--remove-data]`；`SetupRecord` 改成认 Inno 的登记（§4）。
- **R37 / R38 的口子跟着改**：「从这台电脑移除」启动 `unins000.exe`；程序内更新后改 `{AppId}_is1` 里的 `DisplayVersion` / `EstimatedSize`。
- **最可能踩的坑**（PLAN-setup-inno §2 末尾）：
  - `CheckForMutexes` 认不认 `Local\` 前缀；
  - 静默安装时 `NextButtonClick` 调不调（所以位置检查在 `PrepareToInstall` 里再做一遍）；
  - `[UninstallDelete]` 整个删 `{app}` 之前，位置规则一定要先保证这个文件夹整个是我们的；
  - `--uninstall-cleanup` 不能开数据库、不能往数据目录写日志（R25）。
- **验收**：PLAN-setup-inno §7。`setup-e2e.ps1` 五步全过；浅 / 深色四张截图推到 `windows-shots`；报告写两个 setup.exe 的大小、装一次和卸载一次的耗时。

### R67（P1）用户真机反馈：用过一次右键菜单，再点托盘图标打不开 → 已写（审查方，`git log --grep R67`，待编译）

用户 2026-10-27：「右键菜单点击后会导致左键菜单也打不开」。审查方这边复现不了。旧菜单（WinUI 那一版）缺了托盘菜单收尾的两步，都没做：

- 收起后 `PostMessage(WM_NULL)`；
- `Shell_NotifyIcon(NIM_SETFOCUS)` 把焦点还给通知区域（NOTIFYICON_VERSION_4 的规矩）。

缺了这两步，下次点图标常常没反应。

- 新菜单（R66）已经有 `WM_NULL`，这次补上 `Tray.ReturnFocus()`（NIM_SETFOCUS），选了、Esc、点外面都调。
- 选中的那一项不再在 `WM_CONTEXTMENU` 的回调里当场做，改成 `DispatcherQueue.TryEnqueue` 出来再做。截图 / 截图翻译 / 识字 / 录屏再等 300 ms：系统菜单选中项有淡出，免得拍进冻结帧。
- **要验**：手测 371。还能复现的话，日志里看第二次点击有没有 `tray` 相关的行。没有就是系统没把 NIN_SELECT / WM_CONTEXTMENU 发过来，报告里写一句。

### R66（P1）用户真机反馈：没有桌面快捷方式；托盘菜单位置不对 → 已写（审查方，`git log --grep R66`，待编译）

用户 2026-10-27：「1、没有桌面快捷方式 2、系统托盘图标右键弹出的窗口怎么位置不对，没有使用官方的吗」。

- **桌面快捷方式**：`installer/KittyTools.iss` 选位置那一页多一个勾选框「在桌面上建快捷方式」，默认勾上；`[Icons]` 加 `{userdesktop}`，更新时不再建，卸载时 Inno 删掉。静默安装用 `/DESKTOPICON=0` 关掉；`setup-e2e.ps1` 跟着查。
- **托盘菜单**：以前是 WinUI 的 MenuFlyout 弹在一块 360 × 480 的透明窗口里，窗口右下角对准鼠标，位置全靠自己算。托盘回调 `wParam` 里系统给的位置没用（键盘选中时菜单跑到鼠标那儿）。
  - 换成系统的 Win32 弹出菜单，照微软 NotificationIcon 示例写：
    - 位置用 v4 回调的 `wParam`；
    - `SetForegroundWindow(托盘隐藏窗口)` → `TrackPopupMenuEx`（`SM_MENUDROPALIGNMENT` 定左 / 右对齐、`TPM_RETURNCMD`）→ `PostMessage(WM_NULL)`；
    - 位置、翻转、多屏、DPI、键盘、读屏都由系统管。
  - 分节、勾选（暂停记录、复制即译）、灰掉、快捷键（`\t` 右对齐）都保留；**菜单项前的彩色图标没了**（系统菜单是纯文字），这一处和 PLAN-v7 §3.5 不一样。
  - 深色用 uxtheme 没写进文档的序号 135 / 136（SetPreferredAppMode + FlushMenuThemes，资源管理器同一套），跟着设置 › 外观；拿不到就是浅色菜单。
  - `--ui-snapshots` 不再截托盘菜单（TrackPopupMenuEx 会一直占着界面线程），改成手测 368。
- **要验**：编译（`Shell/TrayMenu.cs` 整个重写了，`LibraryImport` 声明和函数指针调用最可能要改）；手测 367–370。
- **Windows 侧编译时改的（2026-10-27）**：`TrayMenu` 整个类标着 `unsafe`，`Show` 里 async lambda 的 `await Task.Delay` 编不过（CS4004）→ `unsafe` 只留在 `ApplyMenuTheme` 上；`(IntPtr)HiddenWindow.Hwnd.Value` 是指针转换、出了 unsafe 就编不过 → 改成 `(IntPtr)HiddenWindow.Hwnd`。之后 Debug、Release AOT x64 / ARM64 零警告，325 个单测过，`--smoke` 过，`setup-e2e.ps1` 18 项全过（含桌面快捷方式和 `/DESKTOPICON=0`）。
- **Windows 侧验的（2026-10-27，脚本，不是真点）**：测试档的 Release 版，往托盘隐藏窗口直接发 v4 回调（`WM_CONTEXTMENU` / `NIN_KEYSELECT`，wParam 带位置），截图在 `windows-shots/0.1.0-r66/`。
  - 位置：两种回调都弹在 wParam 给的那一点上，左下角对齐它往上展开（贴着屏幕底，系统自己翻的）；右键给的是鼠标处，键盘给的是图标中心（2560 × 1440、单屏、100%）。
  - 深色：设置 › 外观「一直深色」时菜单是深色（背景 44,44,44），浅色 249,249,249。系统是浅色，「跟随系统 + 系统深色」那条没验（不改系统设置）。
  - 「复制即译」打开时前面有勾；快捷键右对齐；Esc 能收；同一进程里连开两次都能弹。
  - 367「删掉桌面快捷方式后更新」：测试名静默装 0.0.1 → 删桌面那个 → 装 0.0.2 → 没再冒出来；卸载后目录、登记、快捷方式都没了。
  - 没测：真的鼠标右键 / Win+B（369 的真实路径）、多屏和 150%（370，这台只有一块屏）、371 里点菜单外面收起和「截图」不拍进残影。

### R39（P2）截图遮罩的按键：A、T 和工具栏对不上，换工具不刷新 → 已修（`901d4e3`）

- `SelectionOverlayWindow.OnKeyDown`（L1338 起）里 `case A when !control` 排在 `case A when !control && HasSelection` 前面，**A 永远选箭头**：「A 向下、Shift+A 向上自动滚动长截图」走不到，长截图里「被鼠标打断后按 A 继续」也就没机会用。
- 工具栏悬停提示写「文字（T）」，但 T 是截图翻译；**文字工具没有键**。
- R / A / B / M / V 只改了 `_tool`，没调 `UpdateToolbarChrome()` / `Invalidate()`：按键换了工具，工具栏上高亮的还是原来那个（点按钮的那条路是对的）。
- `P` 不看修饰键，Ctrl+P 也会钉图；方向键不能挪选区（mac 有：1 点 / Shift 10 点）。
- **建议**：工具键照 mac 改成数字（1 矩形、2 箭头、3 画笔、4 文字、5 马赛克……），把 A 还给自动滚动、T 还给截图翻译；按键换工具和点按钮走同一个方法；P 只认不带修饰键的；方向键挪选区。改完同步 `Settings/ShortcutsSheet.cs` 的「截图 · 标注」「截图 · 出图」两组和 `HANDTEST`。

### R40（P3）翻译历史里的键

- `TranslateWindow`：Ctrl+H 只挂在原文框上，历史打开后焦点在历史的搜索框里，**按 Ctrl+H 回不去**（L596 的注释说「再按一次回来」）；Ctrl+W、Ctrl+P、Ctrl+1–9 在历史里也不响应。
- `RefreshHistory` 里读 `Shift + Tab` 来筛收藏（L633），但没有哪个按键处理会在 Shift+Tab 时调它，等于走不到（mac 是 ⇧Tab 在 全部 / 收藏 之间切）。
- 历史里的 Delete 只看光标在不在末尾，没看有没有选中文字（剪贴板那边两样都看）。

### R41（P3）几处按键和说明对不上 → 第一条已写（`53d609e9`，审查方，待编译）；其余三条不挡 0.1.0

- 剪贴板的 Ctrl+K 操作面板里按 Enter 只是把焦点挪到第一个匹配的按钮，**不执行**（L1862）；mac 是直接执行第一项。
- 钉图文件头说「右键菜单同这些」，菜单里少了快速保存和恢复 100%。
- `OverlayWindow.cs` 文件头说浮层按 Esc、Ctrl+W 收起，启动器不认 Ctrl+W。
- 设置窗没有返回（mac 有 ⌘[），也不能 Esc 关；要不要做你们定，做了同步速查表的「设置窗」一组。

### R42（P1）启动器第一次搜索时，在 UI 线程上把浏览器的库整个拷一遍

- `Launcher/LauncherModel.cs:56,70`：每次搜索都调 `BookmarkIndex.Load()` / `HistoryIndex.Load()`。第一次是真读：`Launcher/LookupServices.cs:425` 起，每个浏览器的每个配置都 `CopyWithWal`（:379），把 `History` / `places.sqlite` 整个拷到临时目录，再开库查，全在 UI 线程上。用久了的 Chrome `History` 有几十到几百 MB，拷完之前启动器是卡住的。
- 读过一次 `_loaded` 就一直是 true：新加的书签、新的浏览记录要等重启才搜得到。
- `HistoryIndex` 和 `BookmarkIndex` 的浏览器表、`Search` 方法是一字不差的两份。
- **建议**：
  - 第一次打开启动器时（或者启动后空闲时）在线程池里读，读完换成一份不可变的快照，回 UI 线程刷新当前结果；没读完之前其它结果照常出。
  - 之后按文件的修改时间在后台重读（隔 10 分钟看一次就够）。
  - 两份浏览器表收成一份。PLAN-v9 的 V1 要给每家浏览器加开关、加 Firefox 书签，一份好改。
  - 默认读不读浏览历史、读哪几家是 V1 的事。这一条只管两件：别卡住，能刷新。
- **验收**：日志记读库的耗时和线程（`history.load ms= thread=`），本机 `History` 有多大写进报告；打开启动器后第一次输入到列表出来，前后各量一次。

### R43（P1）长截图：每 600 ms 在 UI 线程上抓所有屏，再把整张长图重新分配、重算一遍

- `Screenshot/ScrollingCapture.cs:141`：每一拍都 `ScreenCapture.CaptureAll()` 抓全部显示器的整屏，只用选区那一块。
- `KittyTools.Core/ScrollStitcher.cs:53` 的 `Append(_current, frame)`：`Skip`、`Combine`、`Prepend`（:189 起）各新分配一份**整张**长图，再 `new ScrollFrame`；构造函数（:11）把整张图每一行重新哈希一遍。
  - 长到 1440 × 30000 时一份 172 MB。有吸顶栏时一拍要分配三份、哈希三遍，全在 UI 线程上。
  - 拷贝量随长度平方涨，峰值是成品的 2–3 倍，还会反复撑大大对象堆。STATUS「长截图内存峰值没测」说的就是这里。
- **建议**：
  - 只抓选区所在的那块屏，或者只 BitBlt 选区那一块。
  - 拼接改成条带：已经拼好的部分存成一串条带，外加最后一帧（带行哈希）。每拍只拿最后一帧和新帧找重叠、追加一条；`Complete` 时合一次。吸顶栏照现在的规则，最后放回一次。
  - 找重叠放到线程池，结果回 UI 线程。
  - `Stitch`（:237）的接口和现有单测（`PlanV3Batch6Tests`）的期望值不变；加一个单测：条带拼出来的和现在逐帧拼的逐像素一样。
- **验收**：Core 单测里 200 帧、1440 宽的合成样本，新旧两种拼法结果一致，两种的分配量（`GC.GetAllocatedBytesForCurrentThread`）写进报告；真机拍一张 20000 px 的长图（测试窗口，别拍用户的内容），拍的过程中专用工作集的峰值、每拍 UI 线程的耗时，前后各量一次。

### R44（P1）每保存一次设置，设置窗就在后台整页重建一次 → 已写（`53d609e9`，审查方，待编译）

- `Shell/ShellRuntime.cs:1021` 的 `OnSettingsChanged`：热键比过签名，但后面 :1036–1039 不管改了什么，每次都 `Theme.ApplyAccent()`（新建强调色那一组资源），再 `_settingsWindow?.RefreshTheme()`。`Settings/SettingsWindow.cs:202` 的 `RefreshTheme` 无条件 `BuildPage(_currentPage)`。
- `SettingsService.Save()` 全仓 72 处调用，很多和设置窗无关：
  - 每次截图记上次区域（`Screenshot/ScreenshotSession.cs:513`）；
  - 翻译浮窗收起时记位置和宽（`Translate/TranslateWindow.cs` 里 7 处）；
  - 录音（`Recording/AudioHost.cs:121,177`）、录制条的开关、同步写网页搜索……
- 设置窗关掉只是隐藏（R34），所以打开过一次以后，后台每存一次设置就重建一整页。当前页是「关于」时，还要在 UI 线程上 `iconTask.Wait(500)`（:1973）。
- **建议**：
  - 照热键那样比签名：外观、强调色、功能开关真的变了，才 `ApplyAccent` / `RefreshTheme`。
  - 设置窗不可见时只记一个「脏」，下次显示再建。
  - `ApplyFeatures`、`TranslateHost.ApplyCopyTranslate` 也看一下：没比过的照这个办。
- **验收**：打开设置窗再关掉，截 10 次图，`BuildPage` 次数是 0（加一行 Debug 日志数）；在设置里换强调色、换外观、关一个功能，照样立刻生效。

### R45（P2）流式翻译：每来一段，UI 线程就把所有卡片和窗口高度重算一遍

- `Translate/TranslateCoordinator.cs:206–213`：每个流式片段都 `card.Text = piece` → `Changed?.Invoke()`。全仓没有一处 `ConfigureAwait(false)`，读流、解析 JSON 的续延全回到 UI 线程。
- `Translate/TranslateWindow.cs:936` 的 `OnCoordinatorChanged`：**所有**卡片 `Update`、`RebuildFooter`、`RefreshTranslateButton`，再 `ResizeToContent` 两次（一次当场、一次排队）。
- `KittyTools.Core/StreamingText.cs:17` 的 `Visible`：每次都 `_raw.ToString()` 拼整段，再 `Trim`。
- 长译文是平方级的；同时开几个大模型服务时，每秒几百次。
- **建议**：读流、累积放线程池，UI 合并成 33 ms 刷一次，只刷变了的那张卡；高度只在这一拍里文字行数变了时才重量。
- **验收**：一个大模型服务译 2000 字，生成期间进程 CPU（% 单核）和 UI 线程每拍耗时，前后各量一次；PLAN-v7 第 4 批「生成中 < 3% 单核」的那个数一起报。

### R46（P2）剪贴板后台识字：大图不缩、失败不记、跨线程读列表 → 已写（`53d609e9`，审查方，待编译）

- `Clipboard/OcrQueue.cs:107`：`GetSoftwareBitmapAsync` 整张解码、不缩放，一张 1440 × 30000 的长截图约 172 MB。截图那边的 `Screenshot/OcrService.cs:55` 已经按 `OcrEngine.MaxImageDimension` 先 `Fit` 了，这里没有。
- 失败的只记在内存的 `Failed`（:15），下次启动又整张解一遍、又失败。
- `PumpAsync` 是 `Task.Run` 起的（:25、:29），在线程池上调 `store.PendingOcr()`（:50），遍历的是 UI 线程正在改的 `_items`。
- **建议**：解码时用 `BitmapTransform` 缩到上限以内（或者走 `OcrService` 那个 `Fit`）；失败的落库成空串，不再重识；待识的那一条回 UI 线程去取（`_dispatcher.TryEnqueue` + `TaskCompletionSource`）。
- **验收**：复制一张 1440 × 20000 的图，识字期间专用工作集的峰值前后各量一次；重启后日志里同一张不再出现 `ocr.image-failed`。

### R47（P2）每日备份在线程池上读 UI 线程的列表和数据库连接 → 已写（`53d609e9`，审查方，待编译）

- `Shell/ShellRuntime.cs:852` 的 `ScheduleBackup` 在 `Task.Run` 里调 `ArchiveService.BackupDaily()`。它在 `Storage/ArchiveService.cs:111` 读 `ClipboardStore.Items`（UI 线程在改的 `List`），又调 `TranslationHistory.Search`（:134），用的是只许 UI 线程用的 `Database.Connection`。
- 碰上那一刻在复制东西，枚举会抛「集合已修改」，当天那份就没备成；数据库连接跨线程用，是没定义的行为。
- **建议**：要备份的数据（收藏的片段、收藏夹、生词本、设置）在 UI 线程上取成快照，序列化、加密、写文件放线程池。
- **验收**：单测或者 `--backup-now` 调试参数：一边每 10 ms 往剪贴板库里加一条，一边备份 20 次，全部成功。

### R48（P2）UI 线程上几处同步的图片活 → 第一条已写（`53d609e9`，审查方，待编译）；另外两条不挡 0.1.0

- `Screenshot/PinWindow.cs:313`：钉图「复制」直接 `WriteImagePng(_png)`，没带转好的 DIB，于是走到 `Clipboard/ClipboardWriter.cs:121` 的 `Task.Run(...).GetAwaiter().GetResult()`，在 UI 线程上干等 PNG → DIB（那里的注释自己写了大图要几百毫秒）。别的入口都先 `await PrepareImageAsync`。
- `Clipboard/ClipboardStore.cs:389` 的 `RecordImage` 算一次 SHA-256，`:426` 的 `Images.Save` → `Clipboard/ImageStore.cs:22` 同步 `File.WriteAllBytes` 整张 PNG（单张上限 128 MB），再算一次 SHA-256（返回值没人用）。复制大图、截图、钉图、从历史复制都会走到。
- `Clipboard/ClipboardPanel.xaml.cs:247`：选中的还是同一条、同一个位置，也调 `ShowPreview` 整个重建（:737），图片重新从盘上解码。搜索时第一条不变的每一次按键都会这样，OCR、同步带来的 `Store.Changed` 也会。
- **建议**：钉图复制改成先 `await PrepareImageAsync`；`ImageStore.Save` 不再算哈希，哈希和写盘挪进 `ClipboardService.SaveImageAsync` 已有的那个 `Task.Run`；`ShowPreview` 记住上次显示的那一条和它的版本，一样就直接返回。
- **验收**：钉一张 4K 截图，按复制，UI 线程卡多久前后各量一次；复制一张 20 MB 的图，`RecordImage` 在 UI 线程上的耗时前后各量一次。

### R49（P2）同步每 20 秒全量跑一轮，什么都没变也照跑

- `Storage/SyncFolder.cs:218` 的定时器每 20 秒 `RoundAsync`，`KittyTools.Core/Sync/SyncRunner.cs:64` 起：把文件夹里所有设备、所有类别的文件读进来，整份解码、合并，再编回去比较，没有「上一轮以来什么都没变」的短路。
- UI 线程上每轮还有两件事：
  - `Clipboard/ClipboardStore.cs:65` 的 `SyncRows()` 给全部文本条目各建一个 `SyncClipRow`，到 Core 里才按「留着的」过滤；
  - 账本先解码一次，再 `SyncLedgerText.Encode` 编回去比较一次。
- **建议**：记下每个文件的修改时间和大小，再给本机四类数据各记一个修订号（改一次加一）；都没变就跳过这一轮。`SyncRows` 先按 `IsRetained` 过滤。只改 Windows 的执行层，文件格式不动。
- **验收**：开着同步静置 10 分钟，进程 CPU 和每轮耗时前后各量一次；R26 的集成测试照样全过。

### R50（P3）日志：每写一行开关一次文件，跨天不换文件

- `App/Log.cs:58`：每行都 `File.AppendAllText`，在调用方的线程上开、写、关一次文件（大多是 UI 线程；装了杀毒软件的机器上每次几毫秒）。
- 文件名在 `Initialize`（:18）时就定死了，7 天清理也只在启动时跑：常驻托盘的进程几周不重启，就是一个越写越大的文件，清理也不跑。
- **建议**：一个后台队列 + 常驻的 `StreamWriter`（退出、崩溃记录时 flush）；写之前看一眼日期，变了就换文件，顺手清理。
- **验收**：单测或调试参数：把钟拨过午夜，新的一行进新文件；连写 1 万行的耗时前后各量一次。

### R51（P3）几处小的

- `Shell/OverlayWindow.cs:96`：每固定一次面板，都给复用的 `_foregroundTimer` 再挂一个 `Tick`，从不摘。固定 N 次以后，每 400 ms 跑 N 遍。只在建计时器时挂一次。
- `Shell/Paster.cs:151` 的 `SendLeft`：片段里 `{cursor}` 往回挪时，每挪一格就一次 `SendInput` + `Thread.Sleep(8)`，上限 500 格，最多在 UI 线程上冻 4 秒（`Clipboard/ClipboardPanel.xaml.cs:1333` 调）。一次 `SendInput` 把 2 × N 个按键发完；真有程序吃不住，再分成 50 个一组。
- `Clipboard/LinkPreviewService.cs`：
  - 最多 12 条连同头图字节（单张上限 4 MB）一直留在内存里，文件头说空闲时会丢，其实没注册 `IdleReclaimer`；
  - 每取一个网页都新分配 512 KB（:46）；
  - 找 `</head` 时每读一块都从头扫（:57）。
  
  建议：注册空闲回收，缓冲用 `ArrayPool`，只扫新读进来的那一段（往回多看 5 个字节）。
- `Storage/TranslationHistory.cs:357` 的 `Find` 按 `source, target_lang` 查，但只有 `WHERE favorite = 1` 的部分唯一索引（`KittyTools.Core/Schema.cs:79`），非收藏的要全表扫。`Add`、`SetFavorite`、`AdoptFavorites` 都调它。Schema 加一步，建普通索引 `(source, target_lang)`。
- `Recording/RecordingHost.cs:247` 和 `Recording/AudioHost.cs:194` 的闪退恢复：跑在启动路径的 UI 线程上，`Mp4Remux.TryRemuxWithTimeout` 同步等重封装。挪到线程池，做完回 UI 线程弹提示。
- `Clipboard/ClipboardPanel.xaml.cs:1091`：文件条目的预览在 UI 线程上，对最多 50 个路径各调一次 `File.Exists`、两次 `Directory.Exists`；路径在断开的网络位置上时，每个都能卡好几秒。先画出来，存在性放后台查，查完回来改图标和透明度。
- `Clipboard/ClipboardStore.cs:697–705`：每复制一次，都给全部条目建 `RetentionItem`，每条一个 `Id.ToString()`，后面 `doomed.Contains(item.Id.ToString())` 又转一遍。保留规则直接用 long。
- `Clipboard/ClipboardStore.cs:752`：第一次搜索后每条都缓存一份 UTF-8 折叠副本 `Folded`，等于全部文本再存一遍；空闲回收（`ClipboardPanel.xaml.cs:109 ReleaseCaches`）不清它。空闲回收时一起置空（重建只是一次冷搜，0.5.0 量过 5.7 ms）。

### R52（P3）死代码和重复代码

- 全仓（含测试）只剩声明、没有调用的：
  - `Shell/Motion.cs:156 HeightChange`；
  - `Screenshot/ScreenshotOutput.cs` 的 `PngAsync`、`CopyAsync`、`QuickSaveAsync`、`SaveAsAsync`（:19 / 26 / 53 / 91，都被带 Png 的版本取代了，只剩互相调）；
  - `Storage/Sqlite.cs` 的 `BindBlob`、`GetBlob`；
  - `Shell/Ui/ListHighlight.cs` 的 `GlideTo`、`HideHighlight`，`Shell/Ui/SearchLine.cs` 的 `FocusBox`；
  - `Translate/TranslateServices.cs IsBuiltin`、`Shell/Theme.cs KindTint`、`Storage/SyncDevice.cs NextCounter`、`App/HotKeyDefaults.cs ResetBinding`、`Shell/Paster.cs SendHotkey`、`Shell/Speech.cs TagFor`、`Storage/ArchiveService.cs BackupFiles`；
  - `KittyTools.Core/AudioRules.cs WritePcm16`、`KittyTools.Core/RegionMath.cs ApplyingRatio`；
  - 整个 `Shell/MicaBackdrop.cs`（`MicaThemeBackdrop` 没人用，设置窗是 `SystemBackdrop = null`）；
  - `KittyTools.Core/LauncherCommands.cs:133 NetstatOutput`：R18 之后只剩 `PlanV3Batch5Tests.cs:88–95` 在测它，连测试一起删。
  - `App/Settings.cs:81 TranslateReplaceHotKeySeen`：第三版 §3.2「划词翻译并替换」的热键动作一直没做，这个字段也没人读。PLAN-v9 的 F1 要是做了，就留着用。
- 重复：
  - 「`byte[]` → `BitmapImage`」写了 6 份：`PinWindow.cs:94`、`ScreenshotCard.cs:380`、`LauncherPanel.xaml.cs:845`、`SettingsWindow.cs:2458`、`ClipboardPanel.xaml.cs:1074` 和 `:1518`（这一份还在 UI 线程上 `GetResult()`，流也没 Dispose）。`Clipboard/ImageCodec.cs:193` 已经有一个私有的 `ToStreamAsync`，放开它，收成一个 `ImageCodec.ToBitmapAsync(bytes, decodeWidth)`。
  - 「留着的条目」的规则 `IsRetained` 写了三处：`ClipboardStore.cs:151`、`KittyTools.Core/Sync/ClipSync.cs:25` 和 `:159`，留 Core 那一份。
- 截图飞入卡（`Screenshot/ScreenshotCard.cs:380`）整张解码：卡片最后只有 200 × 140 DIP，一张 1440p 截图解出来约 14.7 MB，和 STATUS 里「截图后 +18 MB」量级接近。上面那个公用方法加了 `decodeWidth` 以后，先量一下按卡片大小解码能省多少、飞入开头几帧会不会发糊，再决定用不用。

### R24（P1）第 2 批的音画同步是对着一张不动的画面量的，要重做 → 探针已重写（`f07feaa`，审查方），等 Windows 上重测

**复查（2026-10-26 晚）**：这一条还没动。重做的时候，顺手把 R23 的重封装耗时（60 s、10 分钟的文件各一次）一起量了，写进同一份报告。

- 报告里写了：「测试图案窗口在 HUD 起来后被这台机器限帧（WGC 只收到 1 帧），视频靠补帧」。60 s 的文件只有 1.6 MB，也说明画面没动。这样「提示音的起点和闪白那一帧差 < 50 ms」根本没法验。CPU 9.2% 也不能算数，因为编码器一直在编同一帧。
- **先查为什么只收到 1 帧**。日志里有 `_arrivedFrames`，对比 HUD 出来之前和之后。怀疑方向：
  - HUD `Activate()` 抢了焦点，测试窗口的动画停了（R22 修好后再看）；
  - 测试窗口被 HUD 盖住的部分 DWM 不更新。
  
  测试窗口要保证一直在画：用 `CompositionTarget.Rendering` 驱动，并在日志里记它自己画了多少帧。
- **录制时的内存**：第 1 批 142 MB、第 2 批 192 MB，用的是 `Process.WorkingSet64`（总工作集，包括映射进来的显存和共享页），不是 §0 规定的专用工作集。
  - 换成专用工作集重新量。
  - 还超过「比录之前多 40 MB」，就把帧池从 4 张改成 2 张（PLAN 写的是 2），再列出剩下的是谁占的。
- **重做第 2 批的验收**，画面要一直在动：
  - 第 1 s 和第 60 s 的音画差都 < 50 ms；
  - 中间静音 20 s 后照样同步；
  - 抽第 1、30、60 s 的帧，测试窗口上的帧号是连续的；
  - CPU 按 Release AOT 量。

**进展（--sync-probe）**：测试图案 10 秒带系统声音，第一次样本闪白 0.417 s / 提示音 0.430 s（差约 13 ms），但 10 秒重测时 AudioWavProbe 仍把系统声音里的其它声音当成提示音（0.333 s 对 0.180 s，差 153 ms），**还不能据此下 < 50 ms 的结论**；试过 Goertzel 1 kHz 频段能量，系统声音里的峰值只有 0.094，仍分不干净，实验代码已回退（不影响产品）。60 秒无音轨文件 1812 帧 / 13.1 MB / 重封装 78 ms，专用工作集约 192 MB。还没做第 60 秒的逐帧差、20 秒静音后同步、10 分钟重封装。

**审查方在 Mac 上改了探针（没编译过）**：13 ms 和 153 ms 两个数都不能用——测试图案的闪白按渲染计数走（`_frameCount % 60`，而且计数是 30 Hz 加一，实际两秒才闪一次），提示音是另一个 MediaPlayer 循环放的 7 秒文件，**两边没有共用的钟**，量出来的差只是两个钟碰巧差多少。改成：

- `TestPatternWindow`：闪白每一拍（60 Hz）看提示音的 `PlaybackSession.Position`，落在每秒前 100 ms 就亮，暂停时不亮；右上角加 16 格条码（更新计数，按画布宽高的比例摆，读的时候不用知道 DPI）；时钟文字改用 Stopwatch；日志 `test-pattern.second` 记 updates / renders 两个数。
- `--sync-silence`（配 `--record-test` ≥ 45）：第 20–40 秒暂停提示音，这 20 秒系统声音回环一个包都不出。
- 提示音只认 1 kHz：`Core/AvSync.ToneOnsets`（Goertzel，10 ms 窗、2.5 ms 一跳，起点误差几毫秒）。和你们回退掉的那版不一样的地方：不看绝对峰值（系统音量低时提示音只有 0.094），看「1 kHz 的能量占这个窗口总能量的比例」，超过 0.3 就算响，起点按比例除以后面 10 ms 里的平台值往回推，所以底下一直有别的声音也不偏。单测三条：很响的 440 Hz 不算；提示音峰值 0.094、底下一直有 rms 0.045 的几个音加噪声，三声都找到、误差 < 4 ms（同样的算法先在 Python 里对过，误差约 1 ms）；配对 / 静音段 / 条码。量的时候照样把别的放声音的程序关掉。`AudioWavProbe` 改用它，`Result.Onsets` 给出每一声的起点。
- `VideoFlashProbe` 换成 `SyncProbe`：扫整个文件的每一次闪白（1/15 s 粗扫、1/60 s 往回找起点），和每一声逐个配对（`AvSync.PairUp` / `Summarize`），日志 `sync.pair`、`sync.summary`（第一对 / 最后一对 / 静音后第一对 / 平均 / 最大）；再在第 1、30、最后一秒连着抽 10 帧读条码（`sync.frames … continuous=`）。视频按帧取样，单个差带着最多一帧的误差，所以**量的时候录 60 fps**。
- 录制中的内存改成专用工作集（`MemoryProbe.PrivateWorkingSetMb`，日志 `wgc.mem private=`、`wgc.stats privateDelta=`）；192 MB 已经是专用工作集、比录之前多一百多 MB，按本条的规矩帧池 4 → 2。
- `Mp4Remux.TryRemuxWithTimeout` 不给秒数时按文件大小放宽（5 s 起、每 100 MB 加 1 s、最多 60 s），10 分钟的文件不会因为固定 5 s 误判超时、退回分段 MP4。

**要做（Windows 上）**：先编译、跑 `AvSyncTests`；然后

```powershell
KittyTools.exe --record-test=65 --record-fps=60 --sync-silence     # Release AOT
KittyTools.exe --sync-probe=<上一步的 mp4>
KittyTools.exe --record-test=600 --record-fps=30                     # 看 record.remux 的耗时
```

报告写 `sync.summary` 整行（验收：第一对、最后一对、静音后第一对都 < 50 ms，`passed=True`）、三行 `sync.frames`（都 `continuous=True`）、`wgc.stats` 的 CPU 和 `privateDelta`（目标 ≤ 40 MB）、60 秒和 10 分钟两次的重封装耗时。`passed=False` 时把 `sync.pair` 贴出来，看是固定偏移还是越走越偏。

### R31（P1）0.7.0 的包是在「设置窗一打开就崩」修好之前打的，要重打；打包时加启动冒烟 → 已修（`5db1e8f`）

**进展（`b10cbce`）**：新增 `--smoke`（设置六页、剪贴板 / 启动器、翻译、截图遮罩、录音待录条），
`build-release.ps1` 解压 x64 zip 后跑，非 0 就失败；0.7.0 已重打（x64 `dd9652c0…` / arm64 `96af0e90…`），
x64 包冒烟通过。设置窗的 Mica 在 Release AOT 下会抛 `ArgumentException`，已改成不透明卡片底；
关于页卡住的原因是 `ShellIcons.LoadPng` 在 Release AOT 下不返回；改成后台线程 + 500 ms 超时后，**七页冒烟全过**。

- `cea27773` 16:21 打的 0.7.0。设置窗崩溃 16:22（`7ec18c5e`）、16:45（`d1c697c8`）才修好，`d1c697c8` 里也写了「0.7.0 包里……真机已复现」。所以 `windows/build/release/0.7.0/` 里的 zip 一打开设置就退出。之后没看到重打。
- 更要紧的是这个崩溃怎么漏过去的：从 `877cdf17` 到 `7ec18c5e`，中间八九个提交，每个都写着「测试全过、AOT 零警告」，可是设置窗根本打不开。单测和编译管不到「界面能不能打开」。

**修**：
1. 加一个 `--smoke` 参数：依次打开设置窗（七页都切一遍）、剪贴板面板、启动器、翻译浮窗、截图遮罩（打开后马上取消）、录音控制条（待录状态，不真录），每个停 1 s。全部没崩就退出码 0；有崩溃记录或者异常就非 0，并打印是哪一步。
   - 用 `KITTY_PROBE_PROFILE` 那一套独立数据，不碰真实数据、开始菜单和托盘名。
2. `build-release.ps1` 打完 zip 后，解压到临时目录，用 `--smoke` 跑解压出来的 exe。不是 0 就打包失败、删掉产物。
3. 每批的自查清单（`AGENTS.md` 第 2 条）加一句：Release 发布物跑一次 `--smoke`。
4. 用当前代码重打 0.7.0，`STATUS.md` 写新的 sha256。

**验收**：故意把 `Kitty.CardStyle` 改回同名，`build-release.ps1` 要失败，并指出是设置窗那一步；改回来再过。

### R32（P1）翻译服务同步：mac 会写 `"usesDeepLX": false`，Windows 读到会把整类停住 → 已修（`8ce539d`）

- `6ebe6041` 报告里的疑问：「mac TranslateService 的编码没有源码可对：usesDeepLX 只在 true 时写」。审查方查了 mac 源码：
  - 翻译服务同步的就是 `TranslateService` 这个结构本身，用的是合成的 `Codable`：可选字段是 nil 才不写，`false` 和 `""` 照写。
  - mac 设置页里 DeepL 的「接口」切换用的是 `Binding(service.usesDeepLX, default: false)`，写回去的是值本身。用户切到 DeepLX 再切回「官方 API」，存下来的就是 `usesDeepLX: false`，`baseURL` 可能是 `""`。
  - 新建的 AI 服务，`model` 和 `baseURL` 都是 `""`。
- 所以 Windows 落地时对每个可选字段都要分清三种情况：没写（nil）/ `false` 或 `""` / 有值，再编回去要一模一样，不然 decodeExact 不过，整类停在「读不懂」。
- **审查方补了**：
  - `reference/mac-sync/TranslateService.swift`（结构原文）；
  - `sync-golden.json` 里 8 个 `kind: "service"` 的样本（用 mac 真正的结构编出来核对过，逐字节一致）：智谱、Google、DeepL 官方（`usesDeepLX:false`）、DeepLX、DeepL 切回官方且地址为 `""`、微软带区域、新建的 AI 服务（`model:""`、`baseURL:""`）、Anthropic。另外加了一个服务顺序的 `order` 样本。
- **要做**：
  - `SyncSourceTests.GoldenSamplesRoundTripThroughTheWindowsEncoders` 加 `case "service"`：用 `ServiceSync` 落下去再编回来，和 `json` 一字不差；
  - Windows 的服务模型里，`usesDeepLX` 改成 `bool?`，`model` / `baseURL` / `region` / `aiProtocol` 都保留 null 和 `""` 的区别（PLAN-v3 §1.5 的互通约定里补一句）。
- 审查方还改了片段样本：之前有「在收藏夹里但没收藏」的组合，mac 的不变式是在收藏夹里的一定是收藏，所以已经不会出现了。`SyncSourceTests` 里为它写的那句特殊处理可以删掉。

**修（`8ce539d`）**：`SyncService.UsesDeepLX` 改 `bool?`，encode 三态（没写 / false / true），decode 用 `FlagOrNull`；App 的 `TranslateServiceConfig` 同步改 `bool?`，DeepLProvider / 设置页按 `== true`。golden 加 service case，8 个 mac 样本全过。

### R33（P2）第七版的截图一张都没推；透明窗口用 WGC 只抓自己的窗口 → 大部分已修（`f6af9bd` / `6918be7`）

- 第七版改的全是界面（剪贴板透镜、启动器 40、轻提示、翻译浮窗、截图工具栏两段、设置侧栏色块、外观缩略图、强调色圆点），`windows-shots` 上只有 R30 那 8 张设置窗。审查方没法看效果。
- 托盘菜单、录制条、轻提示这种透明宿主窗口，`PrintWindow` 拍不到。项目里已经有 WGC 了：`GraphicsCaptureItem.CreateForWindow(自己窗口的 HWND)` 只抓这一个窗口（带透明），不会拍到后面别的程序。抓一帧存成 PNG，透明的地方铺棋盘格或纯色。
- **要做**：把 `--ui-snapshots` 扩展到所有面板和这几个透明窗口，浅色 / 深色各一套，推到 `windows-shots` 的 `0.7.0-v7/`，`STATUS.md` 里列文件名。推之前照旧逐张看，不能有别的程序。
**进展（`e5100bd`）**：`--ui-snapshots` 的启动器 / 剪贴板 / 设置窗浅深 + 翻译输入态共 7 张已推到 `windows-shots/0.7.0-v7/`；`--clip-scroll-test` 5000 条实测中位 **0.8 ms**、p95 **1.3 ms**，远低于 16 ms，不做 ItemsRepeater。12 张已交：启动器 / 剪贴板 / 设置浅深、翻译、轻提示两态、录制 HUD / 录音待录 / 截图工具栏（WGC 只抓自己窗口）；托盘菜单两态截出来是空的，还没接。

**审查方在 Mac 上补了透明窗口和截图工具栏（没编译过）**：新文件 `App/WindowShot.cs`——WGC `CreateForWindow` 只抓一扇窗口，`SoftwareBitmap.CreateCopyFromSurfaceAsync` 拿像素，裁到不透明的部分、垫 10 px 棋盘格存 PNG。`--ui-snapshots` 在翻译窗之后多出 7 张：`island-notice`、`island-error`、`shot-record-hud`（进程里临时设 `KITTY_HUD_CAPTURE=1`）、`shot-audio-pending`、`tray-menu-light` / `-dark`、`shot-toolbar`。截图遮罩用 `ScreenshotSession.StartSynthetic()`：冻结帧是 `ScreenCapture.Synthetic()` 画的深灰底加三块色块，**不抓桌面、不列窗口**，选区固定在主屏中间，图裁到选区加下面的工具栏。各窗口加了只给自检用的 `HandleForProbe`。

**要做（Windows 上）**：编译、跑一遍 `--ui-snapshots`，逐张看（尤其 `shot-toolbar` 里只有合成的底），推到 `windows-shots/0.7.0-v7/`，`STATUS.md` 列文件名。拍不到的（日志 `ui-snapshots <名字> wgc-timeout / no-item / empty`）写原因。托盘菜单的浅 / 深两张要是一样，说明宿主窗口不跟设置里的外观，记下来，第 3 批一起看。高对比度要改系统设置，不在自检里切，手测时截。

- 第七版第 2 批没做 `ItemsRepeater` + 自定义虚拟化布局，现在是 `ListView` 加变高的行。照 PLAN-v7 量一次：5000 条剪贴板按住 ↓ 连发 3 s，每次按键到画面更新的耗时，取中位数和最慢的 5%。超过 16 ms 再做虚拟化布局。

### R34（P2）截图后 +18 MB、设置窗关掉后 +10 MB：先确认会不会越积越多 → 已修（`1f03f72`）

- 报告说剩下的是 WinUI 合成层和 XAML 模板缓存的原生内存，`GC` 回收不掉。只要是「第一次用了之后多出来一块、之后不再涨」，就可以当已知上限接受。
- **要做**：内存探针加两步——截图 5 次、设置窗开关 5 次，每次之后空闲 30 s 记一个数。
  - 平的：在 `STATUS.md`「已知风险」里写清上限，代码里留 `// ponytail:`，写明升级路径（遮罩常驻复用，或者放到单独进程）。
  - 每次都涨：是泄漏，按录屏那次 D3D 设备的查法找出来。

**修（`1f03f72`）**：设置窗全进程只建一次，关闭移到屏幕外、同一页不重建 XAML 树。5 次开关实测 93.2 / 93.2 / 89.9 / 89.8 / 89.6 MB（平）；截图 5 次 86.3 → 88.6 MB（+2.3，模板缓存一次，可接受）。

### R35（P3）别按进程名结束进程 → 已修（审查方复查 `ab78ce7`：`.ps1` 和代码里只剩按 PID 结束的，`setup-e2e.ps1` 用 `Stop-Process -Id`）

- `bcd3eb7f` 报告里写了：探针被「主工作区另一个 agent 重编时按进程名结束了」。按进程名结束，会把用户正在用的那份 Kitty Tools、或者别的 agent 正在跑的测试一起杀掉。
- `AGENTS.md` 红线里已经加了一条：只结束自己起的那个 PID。两个 agent 各自查一下脚本里的 `taskkill /im`、`Stop-Process -Name`，都改掉。

### R36（P1）安装程序真机验收 → 大部分已修（`2bb2186`；截图 / 真实安装未走）

**进展（`2bb2186`）**：`SetupTests` 320 个全过；Setup 编进 slnx、零警告；x64/ARM64 AOT 零 trim/AOT，本体 2.5 MB；`build-release.ps1` 出 setup.exe（x64 31.5 MB / arm64 30.7 MB）；`setup-e2e.ps1` 七步全过。**未走**：七张对话框截图、真实安装 / 自动更新 / 设置应用的卸载。

- PLAN-setup 的代码都写完了，但 Mac 上没装 .NET SDK（用户定的），Core 单测、Setup 编译、AOT 发布、端到端一个都没跑。`KittyTools.Setup` 还**没加进** `KittyTools.slnx`，免得没编过的代码让你们每批的 slnx 构建红掉。
- **要做**（按顺序）：
  1. `dotnet test windows/KittyTools.Tests`：新加的 `SetupTests.cs`（`SetupPayloadTests`、`SetupRulesTests`）全过。
  2. `dotnet build windows/KittyTools.Setup` 编过、零警告，再把它加进 `KittyTools.slnx`（和 Core 一样，`*|x64`、`*|ARM64` 都映射到 `Any CPU`）。
  3. `dotnet publish windows/KittyTools.Setup/KittyTools.Setup.csproj -c Release -r win-x64`，再来一遍 `-r win-arm64`：**零 trim / AOT 警告**，记下 exe 大小。
  4. `pwsh windows/build-release.ps1`：每个架构多出 `KittyTools-<版本>-windows-<x64|arm64>-setup.exe` 和 `.sha256`，发布说明先讲安装包。
  5. `pwsh windows/tools/setup-e2e.ps1 -Zip <上一步的 x64 zip>`：PLAN-setup §5 的七步全过（zip 要从 `616840b` 之后打，App 才认 `quit`）。ARM64 真机没有就写「没测」。
  6. 截图，只截对话框本身（按 HWND 裁），推 `windows-shots` 的 `setup/`：安装页、选文件夹框、进度、完成、「已经装了 / 重新安装」、程序开着时的「重试」、卸载确认、已卸载（文件夹里留了别的文件那种）。用测试名跑（`$env:KITTY_SETUP_TEST_KEY = "shots"`），默认位置会落到 `%TEMP%`，不碰真实的。
  7. 不用测试名手动走一遍真的：装 →「设置 › 应用」里图标、名字、版本、大小对 → 开始菜单能打开 → 程序里自动更新（R38 修完后）→ 从「设置 › 应用」卸载。做完把机器恢复原样。
- **没编译过、最可能要改的地方**：
  - `SetupUi.cs` 的 `TaskDialogConfig` 照 commctrl.h 手写（pack(1)，64 位下 160 字节）：`TaskDialogIndirect` 返回 `E_INVALIDARG`（日志 `ui.taskdialog 0x80070057`）就是布局错了，先对 `sizeof`。
  - CsWin32 生成的名字和重载：`IFileOpenDialog` 的 `SetOptions` / `SetTitle` / `SetOkButtonLabel` / `SetFolder` / `Show` / `GetResult`，`IShellItem.GetDisplayName`，`SHCreateItemFromParsingName` 的指针重载，`CoInitializeEx(null, COINIT)`。照编译器报的改，不要换成手数 vtable。
  - AOT 下清单有没有嵌进 exe：没嵌的话找不到 `TaskDialogIndirect`（日志 `ui.taskdialog missing`），文件名带 setup 还会被系统当成要管理员权限。
  - 回调里换页（`TDM_NAVIGATE_PAGE`）后返回 `S_FALSE`；要是一点按钮对话框就关了，看 `SetupUi.Callback`。
- **和方案不一样的地方**（审查方认可，验收按这个来）：
  - `.kitty-install` 多了 `files` 数组（这次装的文件并上次记的）。§5 第 6 步要求「安装目录里多一个别的文件就不整个删」，§2.3 那四条做不到，所以「没有不认得的文件」算第五条。
  - 测试名不只换注册表键：开机启动值、互斥量、管道、凭据前缀、数据目录都和 App 的 `KITTY_PROBE_PROFILE=<同一个名字>` 对齐（`.Probe.<名字>`），端到端才能真开一个 App 再叫它退出。注册表键照方案是 `KittyTools.Test.<名字>`，快捷方式是 `Kitty Tools.Test.<名字>.lnk`；测试名下默认安装位置在 `%TEMP%`。
  - `MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)` 只有管理员能登记，普通权限下必失败：照样调（只记日志），%TEMP% 里那份卸载程序留到下次安装 / 卸载时清（`Uninstaller.CleanStaleCopies`）。
  - 静默卸载：安装目录里那份复制到 %TEMP% 就退出（退出码 0），真正的结果写进日志 `uninstall.exit <退出码>`；`setup-e2e.ps1` 等的是这一行。
  - 不整个删的时候 `Uninstall.exe` 也删掉（那时它已经退了）。开机启动值和登记只在指向这个安装目录时才删，另一份解压版的不动。
  - 已经装过（更新）时不显示「开机时自动打开」，也不动开机启动值：用户可能在程序里关掉了。
  - 任务对话框的结构体手写、没用 CsWin32（它不是 COM；在 Mac 上没法确认 CsWin32 生成的联合体和回调签名）。选文件夹、快捷方式照旧用 CsWin32。
- 日志在 `%TEMP%\KittyTools-setup.log`（测试名下是 `KittyTools-setup.Test.<名字>.log`）。修完挪到「已修」，写提交号、两个架构的安装包大小、七步结果。

### R37（P2）设置里「从这台电脑移除」交给 Uninstall.exe（PLAN-setup §4.2 / S10）→ 审查方写了，待编译验证


- `Settings/SettingsWindow.cs` 的 `UninstallAsync` 现在自己删快捷方式、开机启动和凭据，程序文件让用户自己删。安装程序装的（exe 旁边有 `.kitty-install`）改成：
  - `SetupRules.ReadMarker(<exe 所在目录>)` 不是 null，且同目录有 `SetupRules.UninstallerName`：启动它（不带参数，它会自己弹确认，含「同时删除我的数据」），然后走 `ShellRuntime.Exit`，不再弹自己的 ContentDialog。卸载程序会先通过管道发 `quit`，程序没退也会等。
  - 没有标记（zip 解压的）：照现在的做法。
- 顺带：第一次运行的欢迎页里「登录时自动打开」取的是设置的默认值（true），点「开始使用」会把安装时没勾的开机启动又写回去。有标记时改成取 `Autostart.IsEnabled()`，并同步到 `SettingsService.Current.StartWithWindows`。
- 设置窗第七版还在改，所以这条交给你们。

### R38（P2）程序内更新之后改「设置 › 应用」里的登记（PLAN-setup §4.3 / S11）→ 已编译 / 补测，真机更新待走

**进展（`76f94b4`）**：`SetupRules.WithInstalledFiles` 抽成纯函数（旧文件保留原大小写、新文件大小写不敏感去重、版本更新），`SetupRecord.AfterUpdate` 改用它；新增单测，325 个全过。登记写入仍要真机更新验一次。

- 在 `App/AutoUpdater.cs` 的 `update.installed` 之后（这时有 `result.Installed` 和 `version`），安装目录有 `.kitty-install` 就：
  - 改 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<UninstallKey>` 的 `DisplayVersion`（新版本）和 `EstimatedSize`（`SetupRules.DirectorySizeKb(安装目录)`）。登记的 `InstallLocation` 不是这个目录就不动。
  - `.kitty-install` 的 `version` 改成新版本，`files` 并上这次装进去的文件（相对路径，`SetupRules.WriteMarker`）。不然更新带进来的新文件，卸载时会被当成「不认得的」，安装目录就不会整个删。
- 名字用 `SetupRules.NamesFor(null)`；Release 探针档（`KITTY_PROBE_PROFILE=<名字>`）下用 `SetupRules.NamesFor(<名字>)`，和安装程序的测试名是同一套。

**R37 / R38 的代码（审查方在 Mac 上写的，没编译过）**：新文件 `App/SetupRecord.cs`。
- R37：`UninstallAsync` 开头先看 `SetupRecord.Uninstaller()`，有就启动 Uninstall.exe、走 `ShellRuntime.Exit`；启动失败才退回原来的对话框。欢迎页有标记时取 `Autostart.IsEnabled()` 写回 `StartWithWindows`。
- R38：`AutoUpdater` 在 `update.installed` 后调 `SetupRecord.AfterUpdate`（标记的 version / files，登记的 DisplayVersion / EstimatedSize）；`HandleUpdatedLaunch` 删掉 `*.old` 后调 `RefreshSize` 再量一次大小（刚装完时旧文件还在，大小会翻倍）。登记的 InstallLocation 不是这个目录就只改标记。
- **验收**并进 R36 第 7 步：装 → 程序里更新 →「设置 › 应用」版本号变了、大小没翻倍 → 从设置里「从这台电脑移除」弹的是 Uninstall.exe 的确认 → 卸完安装目录整个没了。


## 转入 PLAN-v6

### R14（P1）录屏换成 H.264 MP4，补系统声音 → 转入 PLAN-v6 第 1–3 批

现在是 GDI 抓屏 → CPU 编 JPEG → 自己写 AVI：

- 大：`0.4.0-batch-1` 那段 12.5 MB 才几秒，约 2.5 MB/s，10 分钟 1.5 GB；
- 坏：`AviWriter` 的大小字段是 32 位，过 4 GB 就写坏；没有 OpenDML，很多播放器打不开 1 GB 以上的 AVI 1.0；
- 占内存：`AviReader` 压缩、转 GIF 时 `File.ReadAllBytes` 把整个文件读进来；
- 费 CPU：1440p 30 fps 的 JPEG 编码全在 CPU 上；
- 没有系统声音。

**做法（全走 WinRT，项目里已经在用 WinRT 投影，AOT 能用，不用手写 Media Foundation 的 COM）**，参考 robmikh/SimpleRecorder（MIT）：

1. **抓屏**：`GraphicsCaptureItem`（整屏用 `IGraphicsCaptureItemInterop.CreateForMonitor`、选区先抓整屏再裁，这一个接口用 CsWin32 / 函数指针）+ `Direct3D11CaptureFramePool.CreateFreeThreaded` + `GraphicsCaptureSession`（`IsCursorCaptureEnabled` 按设置；Win11 上能关就把 `IsBorderRequired` 关掉）。
2. **编码**：`MediaStreamSource`（`VideoStreamDescriptor`，BGRA8，选区尺寸取偶数），`SampleRequested` 里交 `MediaStreamSample.CreateFromDirect3D11Surface(frame.Surface, 时间戳)`；`MediaTranscoder.PrepareMediaStreamSourceTranscodeAsync(source, 输出流, MediaEncodingProfile.CreateMp4(...))` → `TranscodeAsync()`。码率按像素数算（1080p30 约 8 Mbps）。没有硬件编码器的机器系统会自己换软件编码，不用管。
3. **系统声音**：WASAPI 回环。CsWin32 在 `allowMarshaling=false` 下生成的 `IAudioClient` / `IAudioCaptureClient` 是带函数指针的结构体，AOT 能用。用**轮询**（每 10 ms `GetNextPacketSize`），**不要用事件模式**（回环 + 事件模式在没有声音播放时不来事件）；包上带 `AUDCLNT_BUFFERFLAGS_SILENT`、或中间断了，按时间戳补静音，不然音画会越录越不同步。PCM 作为同一个 `MediaStreamSource` 的 `AudioStreamDescriptor` 交进去，输出 AAC。
4. **麦克风**：一样走 WASAPI 采集，和回环在 PCM 层混（相加 + 限幅），重采样到同一个采样率。录音功能（现在是 `MediaCapture` 出 M4A）可以留着，也可以换成同一套，自己定。
5. **点按圈、按键胶囊**：改成画在 D3D 纹理上（Win2D：`CanvasDevice.CreateFromDirect3D11Device` + 在拷出来的纹理上画）。
6. **压缩**：同一个 `MediaTranscoder` 降码率再转一遍。**转 GIF**：`MediaComposition` / `MediaPlayer` 的帧服务器逐帧取。不用自己解 AVI 了，`AviWriter / AviReader / JpegEncoder / JpegDecoder` 删掉。

**在换完之前**：AVI 录到 1 GB 自动停止并提示（`// ponytail:` 写上 R14），免得写出打不开的文件。

**验收**：1440p 30 fps 录 60 s，文件 < 60 MB、录制期间本进程 CPU < 15%、内存不随时长涨；放系统声音 + 对着麦克风拍手，音画同步；资源管理器能出缩略图、「媒体播放器」能放；录满 10 分钟一次。

**进展（`50ecd87`、`7edbd92`）**：
- 已改成**直接录 H.264 MP4**：`Mp4Recorder` 用 Media Foundation SinkWriter（GDI 抓屏 → RGB32 → H.264，
  硬件编码），默认开，设置里可退回 AVI；点按圈 / 按键胶囊仍画进画面。
- 实测 2560×1440@30 录 10 秒：**2.75 MB**、MediaPlayer 认 10.0 秒、H.264；录制期间本进程 CPU **2.4%**。
- 停止后另存 MP4 / 托盘手动转 MP4 仍在（AVI 文件可用）。
- **还没做**：系统声音 / 麦克风混音（MP4 目前只有画面）、真实 60 秒 / 10 分钟长录制的内存曲线、
  压缩 / GIF 对 MP4 的支持（现在只对 AVI 显示）。

**审查（`1bdfde8`）**：MP4 能录了，但还是 GDI 抓屏，SinkWriter 没开 `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`，所以用不上硬件编码器。系统声音没做成，原因是用了事件模式：回环流在没有声音播放时根本不出包。这些连同删 AVI、录音补齐，都写进了 PLAN-v6 第 1–3 批。

### R12（P2）第 4、5 批欠的验证 → 剩下的转入 PLAN-v6 第 6 批

报告里写了，这里列出来免得漏。系统自带的截图工具就能录屏（Win+Shift+R），不需要额外装工具。

- **剪贴板面板、启动器的高度动画**：窗口每 16 ms 改一次尺寸，Windows 上这样做常见的问题是边缘闪黑或闪白。录一段 3–5 秒的视频看；有闪就改成不做动画，直接设到新高度。
- **截图**：选区贴着屏幕下边时，工具栏要放到上方或选区里面，不能出屏；中文输入法下的原位文字；飞入卡片拖到资源管理器。
- **数字**：翻译等待动画期间的 CPU、截一次图之后的内存（按 D8）。
- **截图**：截图翻译的浮窗贴着选区出现；飞入卡片的深色版。

**进展（2026-10-25，`4b7e0c1` 之后）**：

- 已验：选区贴着屏幕下边时工具栏在屏内（`windows\build\shots\r4\shot-bottom-toolbar.png`）；
  飞入卡片的深色版正常（`shot-card-dark2-crop.png`，顺手修了深色下卡片黑底黑字和白边）；
  截图翻译贴选区有纯函数单测（`ScreenshotLayoutTests` 的四个用例），真机 OCR + 翻译链路没走。
- 没做：高度动画的录屏（要人工开录屏工具、再逐帧看，自动化里没法可靠完成）、中文输入法的原位文字、
  把卡片拖到资源管理器、等待动画期间的 CPU（手上没有可用的 key / 服务能停在「思考中」）、
  第二次截图的内存（内存探针只截一次，下一轮看要不要给探针加第二步）。
  这些按 `AGENTS.md` 记「没测」，继续做 `PLAN-v3.md`；`HANDTEST.md` §144–161 里已经标了「待走」。

## 已修

### R22（P1）录屏 HUD 没按 DPI 算尺寸，还写死了屏幕高 1440 → 已修（`82a5a07`）

- HUD 尺寸按目标显示器 `Displays.AtPoint(...).Scale` 换算成物理像素；位置由 Core `HudPlacement.Compute` 限在工作区，下方放不下放上方、再放不下贴选区里面下边。
- `AppWindow.Show(false)` + `WS_EX_NOACTIVATE`，不再 `Activate()` 抢焦点。
- 单测 `HudPlacementTests` 4 条：150%、贴底、整屏、负坐标副屏。
- 还没做：`--fake-dpi=150` 真机截图和“开录后焦点还在原程序”的手测（见 HANDTEST）。

### R23（P1）去掉分段 MP4 以后，闪退会丢掉整段录屏 → 已修（`266a485`；长文件的重封装耗时并进 R24）

**进展（`266a485` / `d4b0c10`）**：
- 录制重新写 FMPEG4（`MFTranscodeContainerType_FMPEG4`），moov 及时落盘。
- 新增 `Mp4Remux`：SourceReader + SinkWriter 按原生压缩样本逐个搬，不重编码；每路时间戳从 0 开始；
  没有音频流按只有画面处理；失败退回「分段 MP4 原样改名」。
- 正常停止和 `RecoverOnStartup` 都走重封装；实测 2 秒 / 3 秒 / 5 秒文件重封装 16–47 ms，
  最终文件 `ftyp=mp42`、`moov` 在尾部、Shell 读出 2 秒 / 3 秒 / 5 秒；崩溃恢复的 5 秒文件也能读时长。
- 10 秒带音轨改成单个 SourceReader + ReadSample(ANY_STREAM) 后不再卡：31 ms / 789 样本，成品 10 秒。仍然差验收里的 **60 秒 / 10 分钟两种重封装耗时**，以及真实系统声音 / 麦克风两路设备
  （开发机只验了无声和系统回环空数据）。

- 第 3 批改回了普通 MP4（`MFTranscodeContainerType_MPEG4`）。普通 MP4 的索引（moov）要到 `Finalize` 才写，闪退、断电、被任务管理器结束时，临时文件里一个字节都放不出来。「启动时找回」挪过去的是一个打不开的文件。
- PLAN-v6 第 1 批第 6 条写的是：录分段 MP4，停止时如果缩略图、拖动有问题，就**无损重封装**成普通 MP4，不是改回普通 MP4。你遇到的「MediaComposition 在分段 MP4 上 seek 不准」，正好是重封装要解决的问题。

**修**：
1. 录制写分段 MP4（`MFTranscodeContainerType_FMPEG4`）。
2. 正常停止时重封装：`MFCreateSourceReaderFromURL` 读临时文件，两路都**不设输出类型**（默认就是原生的压缩样本）。第二个 SinkWriter 每一路用 `GetNativeMediaType` 拿到的类型 `AddStream`，`SetInputMediaType` 也传**同一个类型**（输入输出一样就不会插编码器，等于直接搬），逐个 `ReadSample` → `WriteSample`（时间戳减去第一个样本的，从 0 开始），最后 `Finalize`。不重编码，60 s 的录屏应该在一秒以内。
3. 启动时找到临时的分段 MP4，同样重封装后挪进保存目录。重封装失败就原样挪过去，分段 MP4 也能放。
4. 压缩、转 GIF、抽缩略图都只对重封装之后的普通 MP4 做。

**验收**：
- 录 30 s 时用任务管理器结束进程，下次启动找回的文件能放、时长约 30 s；
- 正常停止的文件，资源管理器缩略图、「媒体播放器」拖进度条都正常；
- 报告写 60 s 和 10 分钟两种文件的重封装耗时。

### R25（P1）卸载并删除数据时，数据库和日志还开着 → 已修（`61152c0`）

- 删除前 `ShellRuntime.PrepareForUninstall()`：提交剪贴板删除 → `ClipboardService.Stop()` 关 SQLite →
  停同步定时器 / 更新检查 / 热键 / 托盘 → `Log.Shutdown()`。
- 回收站改用内置 `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(..., SendToRecycleBin)`，
  删完检查目录是否真的不在；失败弹「数据目录没删干净」并可打开文件夹。
- 和审查要求的 `IFileOperation` 不同：CsWin32 的 `IFileOperation` 在当前 NativeMethods 里生成不出来，
  先用 VisualBasic 的内置实现；行为一致（回收站 + 失败提示 + 不静默）。
- 验收还差：`.Dev` 数据目录真机点一次、故意占用一个文件看提示。

### R26（P1）同步执行层的 8 处修复没有任何自动化测试 → 已修（`6ebe604`）

**修了什么（`6ebe604`）**：
- 四类的编出去 / 落回来在 Core：`ClipSync`、`VocabularySync`、`EngineSync`、`ServiceSync`（一类一个文件，照 mac 的 SyncSource / applySync，按合出来的改动落）；一整轮在 Core 的 `SyncRunner`（+ `SyncDisk`、`SyncLedgerText`、`ISyncSource` / `ISyncDevice`）。App 的 `SyncFolder.cs` 只剩定时器、状态和四个薄适配（规划落进库，和账本同一个事务）。
- 单测 `SyncSourceTests` 19 个，§2 每一条都有；集成测试 `SyncIntegrationTests` 走真的 `SyncRunner`：两台 Windows + 假 Mac（golden 样本），3 个种子 × 24 步，最后三边一样、再合一轮谁都不写；坏文件、换回旧备份照旧验。`SyncGoldenTests` 照过。全量 306 个。
- 「两个临时数据库」没用真 SQLite（测试工程只引 Core）：仓库在内存里，落规划的几步和 `ClipboardStore.ApplySyncPlan` / `TranslationHistory.ApplySyncOps` 一一对应；SQL 那几行用真 App 冒烟验了（两份临时 `.Dev` 数据 + 临时同步文件夹，片段落进另一台的库，之后安静的轮次不重写文件）。
- 顺手照 mac 改的（提交正文里有全单）：刹车的「至少 5 条」按要删的条数算（之前按总数，删 5 条里的 2 条也刹），「照样同步」只放行不超过当时那么多条；没东西要写就不重写文件、epoch 只在写了东西时 +1 且先记库；账本读不出来这一类停下；每一类跟着功能开关；面板里有能撤销的删除时先不合。
- 没连真 Mac（用户要求 R26 做完前不连）。

- `275ea952` 修的都是「会删到每一台」级别的问题，而且全在 App 项目的 `SyncFolder.cs` 里：仓库没起来时交空表、收藏夹没落地、`group` 的写法、只交收藏、落地失败照存账本、再编不稳定、抢别人的 uid、刹车。
- 报告里也写了：「这次的改动没有自动化测试覆盖」。`PlanV5IntegrationTests` 测的是 Core 的引擎加手写的值，没经过这些代码。

**修**：
1. 把四类数据各自的「编出去」和「落回来」，从 `SyncFolder.cs` 抽成 Core 里的纯函数：输入本机的记录列表，输出 value 字典；输入合出来的改动，输出要落的改动和失败原因。照 mac 各个 `SyncSource` 的写法，一类一个文件。`SyncFolder` 只管读写文件夹、事务和状态。
2. 单测，每一条对应 `275ea952` 修的一处：
   - 仓库没起来 → 这一类不合；
   - 收藏夹同名 → 编号小的留下、条目归过去；
   - 只是片段的条目要交出去；
   - 有一条解不开 → 整类不落、不存账本；
   - 编 → 落 → 再编，字节一样（备注空白、生词前后有空格、服务缺协议，各一条）；
   - 正文撞上已经留着的条目时不抢它的 uid；
   - 本机删一大批（erasing）也要刹车，等确认的状态不被盖掉。
3. 集成测试改成走真的执行层：两个临时数据库加一个临时同步文件夹，再加一台假 Mac（值用 `sync-golden.json` 里的样本），跑几轮，最后三边一样。
4. `sync-golden.json` 审查方已经改过：之前片段的 `group` 写成了带 `group:` 前缀的，是审查方的错。mac 条目里只写收藏夹的编号，前缀只在收藏夹那条记录自己的编号上，你在 `275ea952` 里改对了。样本已经按 mac 重新生成，跑一遍单测确认还都过。

### R27（P2）第 5 批的内存回落没做 → 已修（`bacd1a6`、`bcd3eb7`；剩下的转 R34）

**补完（`bcd3eb7`，Release AOT 全量探针，专用工作集，探针用独立数据 `KITTY_PROBE_PROFILE`）**：

| 步骤 | 之前（`bacd1a6` 的探针） | 之后 |
|---|---|---|
| 截图后 / 第二次 / 空闲两分钟 | 65.4 / 68.2 / 68.2 | 66.8 / 69.6 / 69.6 |
| 设置窗关掉 30 秒 / 两分钟 | 79.8 / 79.7 | 80.9 / 80.7 |
| 录屏 5 秒，停止后两分钟 | 103.3（+23.5） | 83.9（+3.2） |
| 再录一次，两分钟后 | 每次再 +24 | 84.2（+0.3） |

- **录屏修好了**：每录一次留下一整个 D3D 设备（约 24 MB）。WinRT 的 `IDirect3DDevice` 和每帧的 `frame.Surface` 包装都拿着设备、要等 GC 终结才放；关掉 / `using` 之后设备真的销毁（`d3d.still-referenced` 会记还有人拿着的情况）。NVENC 第一次加载多 20–30 MB 是驱动，之后每次 < 1 MB。
- **冷启动**：10 次中位数 0.5.0 79 ms、第六版第 5 批 76 ms、修之前 107 ms、之后 77 ms。之前报的 64 / 90 是单次读数（这台机器单次 61–118 ms）；真正变慢的是第 7 批把开始菜单快捷方式放在启动路径上（每次 COM 解析 .lnk），挪到启动 3 秒后。
- 设置窗点 × 关掉时放掉引用；截图、录屏、录音结束和设置窗关掉之后都排空闲回收。`GCConserveMemory=5` A/B 各步差不到 0.5 MB（`d1c697c` 已开，没撤）。发布目录前 20 个看过：删 WebView2 两个 DLL（0.91 MB），`Microsoft.UI.Xaml.Phone.dll` 设置窗要用不能删，`.winmd` 先留着。
- **没做成**：截图后 +18 MB、设置窗关掉后 +10 MB，两分钟后都不降。托管堆只剩 2.5–4 MB、GDI 位图已删，剩下的是 WinUI 合成层 / XAML 模板缓存的原生内存；给截图遮罩单独建 Win2D 设备再放掉也省不下（撤了）。再往下要换做法（遮罩常驻复用或单独进程）。录音的回落没量。

`9a836e49` 的数字：

| 场景 | 内存 |
|---|---|
| 启动器 | 57.8 MB |
| 截图 | 74.0 MB（+16） |
| 设置窗打开 | 83.6 MB |
| 设置窗关掉之后稳定 | 83.5 MB（没降） |

- PLAN-v6 第 5 批第 1–3 条（截图、设置窗、录屏之后回落）和第 4 条里的 `System.GC.ConserveMemory` 都没做；「发布目录前 20 个文件逐个看」也没做。照 PLAN 做完，报告列「之前 / 之后」。
- 冷启动从 64 ms 变成了 90 ms，查一下是哪一批加的、为什么。

**复查（`3fe1725e`）**：录屏每次漏一个 D3D 设备的问题找出来修了（+23.5 MB → +3.2 MB），冷启动 107 → 77 ms，发布目录看过、去掉了 WebView2。剩下截图后 +18 MB、设置窗关掉后 +10 MB 不降，转到 R34。

### R28（P2）录音控制条 / 直接写 AAC / 断开提示 → 已修（`3df5058`）

**进展（AudioHud，`0fc69bd`、`a64a8af`）**：新增录音控制条：屏幕上方的深色胶囊，红点 / 计时 / 电平条 / 暂停继续 / 停止，
显示不抢焦点；`--audio-rec-ui=3` 实测 3.2 秒 / 79.7 KB 的 m4a。待录模式已接：设置里关掉
「按快捷键后立即开始录音」后先出条、点 ● 才开始，托盘 / 快捷键再按一次取消。麦克风 / 系统声音断开的
橙字也接了（`132b806`，录音条和录屏 HUD 都读 `LiveNote`）。直接写 AAC 也接了（`c7c4ce4`）：
PCM16 进 SinkWriter 编 AAC，容器先写分段 MP4，停止时无损重封装成 .m4a；实测 3.16 秒 / 64.9 KB。
闪退恢复也接了（`3df5058`）：录到一半强杀，临时 121.8 KB，下次启动重封装 32 ms，恢复出 5 秒 .m4a。
还没测：1 小时长录的真机稳定性和内存曲线。

- PLAN-v6 第 3 批第 4 条没接界面：待录（按快捷键先出控制条、点 ● 才开始）、电平条、「没听到声音」的提示、「按快捷键后立即开始录音」的设置。照 mac `AudioRecorder.swift` 文件头做，界面按 PLAN-v7 的轻提示 / HUD 样式。
- 第 2 批：HUD 计时后面的橙字「麦克风断开了」还没接。
- 录音现在先写临时 WAV、停止后再转 M4A：1 小时就是 690 MB 的临时文件，转码还要等。改成录的时候直接用 SinkWriter 写 AAC。闪退恢复照 R23 的办法：写分段 MP4 容器，停止时重封装成 `.m4a`。

### R29（P2）窗口录制：窗口一改大小，录制就停了 → 已修（WgcScaler）

**修（WgcScaler）**：录单个窗口时 ContentSize 变化不再停止，输出尺寸不变；WgcScaler 用 Win2D 把新画面等比缩放、居中画进输出纹理，四周补黑。同尺寸仍走 CopySubresourceRegion，缩放器起不来退回居中裁。自检 --record-resize：录 900x600 → 回全屏，日志 wgc.scaled 900x600->2560x1440，5 秒 156 帧 / 1.4 MB。还没走：真机手拖窗口边、最小化恢复。

- `OnFrameArrived` 里 `ContentSize` 一变就 `_stop.Set()`，提示「屏幕尺寸变了」。录整屏时这样处理可以；录单个窗口时，用户拖一下窗口边就停了。
- **修**：录窗口时 `ContentSize` 变了就 `Recreate` 帧池，输出尺寸不变，把新的画面按比例缩放、居中画进输出纹理（已经有 Win2D 的画布，`DrawImage` 带缩放就行），四周补黑。窗口最小化时补上一帧，窗口关掉时停止并保存。
- **验收**：录测试窗口，录的过程中拖大、拖小、最小化再恢复，文件能放、画面不变形。

### R30（P3）几处小问题

**进展（`82a5a07`、`356bb30`）**：文件搜索的 LIKE 已把 `%` / `_` / `[` 用字符类转义；`System.ItemUrl` 实测不按百分号编码（空格就是空格），不再 `Uri.UnescapeDataString`，补了 `%20` 保持原样的单测；根目录过滤改成 `SCOPE='file:C:/…'`，`--file-search=jpg` 100 条从 62 ms 降到 31 ms。第六版截图补了（`97c8e7e`，`windows-shots` 的 `0.7.0-review-r30/` 8 张：设置窗 4 处浅深各一；顺手修了深色下对话框是浅色的问题，11 处 ContentDialog 跟着设置的深浅色走）；托盘菜单和录制条是透明宿主窗口，PrintWindow / BitBlt 都截不到，没交。提交格式、各用各的 worktree 照做了。另外 `7ec18c5` 修了 `877cdf1` 起设置窗一打开就崩（`Kitty.Card` 样式键和主题画刷同名）。

- **文件搜索的 SQL**（`Core/FileSearchSql.cs`）：
  - 只转义了 `'`。`%`、`_`、`[` 在 LIKE 里是通配符，搜「[草稿]」会搜不到。改成放进方括号转义：`[%]`、`[_]`、`[[]`。
  - `LocalPathFromItemUrl` 对路径做了 `Uri.UnescapeDataString`，文件名里本来就有「%20」的会被改成空格。先确认 `System.ItemUrl` 到底是不是百分号编码的，不是就别解码，补一个单测。
  - 根目录过滤改用 `SCOPE='file:…'`，比 `System.ItemUrl LIKE` 更能用上索引（Command Palette 也这么写）。
- **提交格式**：第六版有十几个提交的标题没有 `<type>(win):`，比如「PLAN-v6 第 6 批（续）：…」。旧提交不改，以后照格式写。
- **截图**：第六版改了托盘分节、录制条开关、卸载对话框、设置里的新选项，`windows-shots` 上一张都没有。补一套：只截窗口，浅色、深色各一张。
- **几个 agent 别共用同一个检出**：`275ea952` 的报告里说「另一个 agent 在主工作区 stash 了一份」。几个 agent 同时在一个目录里改，会互相覆盖、互相 pop 错 stash。每个 agent 用自己的 `git worktree`，做完 rebase 到 `origin/windows-wip` 再推。

### R13（P0）同步的合并规则和 mac 不一样 → 已修（`f29f437`、`2728574`、`a381cbe`）

**先说审查方的错**：PLAN-v5 让你照搬的 `SyncRecords.swift` 等文件，写方案时只在 Mac 本地、没推到 `origin`，你那边拿不到，只能按文字重写。现在原样拷在 `windows/reference/mac-sync/`（README 里有对照表）。

- **差在哪**：你写的是「`modified` 大的赢，一样再看钟」；mac 是**先比钟**——一版的钟每一格都不小于另一版（盖过它）就直接赢，跟改于无关；只有两版谁也盖不住谁（真的并发改）才比改于，再一样比内容哈希（`SyncRecords.swift` 文件头「合（C1）」）。
- **会出什么事**：Windows 的系统时间比 Mac 快 5 分钟。Windows 改了一条 → Mac 读到、在它上面又改了一次（Mac 这版的钟盖过 Windows 那版，但改于比 Windows 的小）→ Windows 这一轮按改于判自己赢、把 Mac 的改动丢掉，再把钟并起来写出去 → Mac 下一轮看到的钟盖过自己的，跟着退回旧值。两台的时钟差几分钟很常见，这个不是小概率。
- 别的没对上的（都在文件头里写着）：改于不晚于现在、取 changed 时刻；账本被退回去时只追自己那一格（你现在是换编号，那是 device.json epoch 的规矩，两件事都要有）；第一次合的规则（同一编号的不算改动、内容一样的只留文件夹那条、丢的不留墓碑不进刹车）；墓碑不过期。
- **要做**：
  1. 照 `SyncRecords.swift` **逐行**搬成 `KittyTools.Core` 里的纯函数：`round`、`Join.union`、`orderID`、`arranged`、`decodeExact`、`buried`、`standing`，文件头那几段原样保留成注释。你现在的 `SyncClock`、`SyncJson`、`SyncFile` 能对上 golden 的部分留着用。
  2. `SyncRecordsTests.swift` 的 17 个用例全部移植、期望值原样；`SyncRecordsFuzzTests.swift` 照着移植（三台随机加改删合、读到旧文件、钟快慢、退回、丢账本，查三台最后一样），默认 20 个种子随全量跑，`KITTY_SYNC_FUZZ=2000` 跑 2000 个。
  3. PLAN-v5 第 3 批的集成测试：临时文件夹里两台 Windows（两个数据目录）+ 一台用 golden 样本手写的假 Mac，随机改几轮，最后三份一样。
  4. 执行层挪出 UI 线程：同步文件夹多半在云盘里，读一个还没下载的文件会卡几秒。照 `NoteSyncer.swift`：后台读写、合，回 UI 线程落地（落地和账本同一个事务）。
- **修好之前**：设置 › 通用 ›「同步」这一节先藏起来（`// ponytail:` 写上 R13），0.5.0 的产物不能给用户装来同步。
- **验收**：上面 2、3 全过；报告里写 fuzz 2000 个种子的耗时。

**进展（2026-10-25，`2728574` / `a381cbe`）：**
- 引擎已接执行层：`SyncKind` 用 `SyncEngine.Round`，旧账本 `clock|hash` 迁成新格式；设置里的「同步」重新打开。
- 17 个移植用例 + 20 个种子的 fuzz 随全量跑；`KITTY_SYNC_RECORDS_FUZZ=2000` 实测 2000 个种子 34.9 秒；
  两台 Windows + 假 Mac 的临时目录集成测试（8 轮，三份一样）也过了。
- 文件读 / 解码 / 合并已放到线程池（`Task.Run`），回 UI 线程落地和写账本。
- 还差：旧账本迁移只把 modified 记 0；真机 / 真 Mac 的长期同步没测。

**审查（2026-10-25，`1bdfde8`）**：`SyncEngine.Round` 逐段对过 `SyncRecords.round`，账本、墓碑、退回只追自己那一格、第一次合的 union / adopt、`standing`、改于取 `min(changed, now)`、赢家按（改于，哈希）都对得上。旧的 `SyncMerge` 和它的测试还在，PLAN-v6 第 0 批删掉。

### R16（P1）截图拍到了用户的隐私 → 已修（审查方：`windows-shots` 已改写并强推，`d2d38b6`；规矩在 `AGENTS.md`）

- `0.4.0-batch-1/record-saved.png`、`0.4.0-batch-2/record-select.png`、`0.4.0-batch-3/hud.png` 都是 2560×1440 的整个桌面，拍进了用户别的窗口：代理配置、局域网和代理服务器的 IP、别的对话的内容。`0.4.0-batch-4/effects-frame.jpg`、`0.4.0-batch-5/gif-frame.png` 这两张录屏帧里也有。
- **以后的规矩**（已写进 `AGENTS.md`）：
  - 截图只截我们自己的窗口：按窗口矩形裁，或者只抓我们的 HWND。
  - 录屏的验证先开一个自己的测试窗口（满屏测试图案），只录它的范围。
  - 整屏的图一律不推。推之前自己看一遍，不能有别的 App 的内容。
- 已经推上去的那几张怎么处理，由用户定（要改写 `windows-shots` 的历史），agent **不要动**。

### R17（P1）启动器文件搜索是自己扫目录 → 已修（`ed4428d`）

- 改成 `StorageFolder.CreateFileQueryWithOptions` + `IndexerOption.OnlyUseIndexer` + `System.FileName:*词*`；
  失败才退回扫目录，退路 6 层 / 2000 候选 / 300 ms。
- 怎么验的：`--file-search=jpg` 索引 **880 ms / 20 条**，`KITTY_FS_FORCE_FALLBACK=1` 退路 **33 ms / 20 条**
  （退路被 300 ms 截断；这台机器 Downloads 只有 500 多个文件，索引本身约 0.9 s）。

**审查**：改成走索引了，但 WinRT 的查询一次要 880 ms，打字时等不起。转入 PLAN-v6 第 4 批，换成 OLE DB 查索引。

### R18（P2）端口靠解析 `netstat` 的输出 → 已修（`a381cbe`）

- `Launcher/PortTable.cs` 改用 `GetExtendedTcpTable` / `GetExtendedUdpTable`（IPv4 + IPv6，TCP 只要 LISTEN，
  UDP 全部）；纯函数 `PortMath.PortOf/FormatV4` 在 Core；`PortSearch` 不再起进程。
- 怎么验的：`--ports` 实测 129 行（TCP/UDP、IPv4/IPv6、pid 都对）；`PortMath` 2 个单测（字节序、格式）。

### R21（P3）几处小问题 → 已修（`a381cbe`）

- 剪贴板预览时间改 `HH:mm` + 最小宽度，来源名超长省略；
- HUD 加 `TransparentBackdrop`，胶囊外不再有浅色方框（本地截图确认）；
- 按键胶囊加小写字形，显示 `Ctrl + Shift + S`；
- 灰格子确认是测试图本身透明（`0.3.0-batch-4/ocr-search.png` 里预览就是透明棋盘格），不是没画出来。

### R20（P2）第三版报告里记的「没做成」→ 已修（`3e978d9`、`fb0aa36`）

- 浏览器历史：`HistoryIndex` 拷 `History` + `-wal`/`-shm` 到临时文件；本机 Chrome 等载入 217 条，
  Edge 的库拷出来 malformed（正在写），跳过并记日志。
- Firefox 书签：`places.sqlite` 的 `moz_bookmarks`（type=1）并入，书签 404 条。
- Ctrl+K：自建 Flyout（过滤框 + 按钮列表，Enter / Esc），条目和右键菜单同名同顺序。
- 长截图：`S` 向下、`Shift+S` 向上、`A` 自动向下、`Shift+A` 自动向上；自动每 600 ms `SendInput` 滚一格。
- 链接头图 `DecodePixelWidth=1200`；有道 / 火山 / 腾讯签名换成 mac 固定向量（3 个全过）。
- 没测：自动滚动的真机效果（会滚当前窗口，没自动化）；Edge 历史（库正在写时拷不出来）。

### R15（P1）R4 没修好：深色下设置卡还是浅底白字 → 已修（`2728574`）

- `Theme.CardBackground/SecondaryText` 不再从 XamlControlsResources 的主题字典取（实测 Default/Light
  解出来都是 `#B3FFFFFF`，深色用错），改成跟 `EffectiveTheme` 给具体颜色；`ThemeKey` 深色先找
  `Default`，`FindTheme` 只认里面真有这个 key 的字典；启动自检日志 `theme.check` 记实际颜色。
- 怎么验的：系统浅色 + 设置深色，只截设置窗口（`0.5.0-review-r15/settings-dark-system-light.png`，
  卡片深底白字、功能卡有图标）。系统深色 + 设置浅色的组合没测（要改系统主题）；
  XAML 里能写 `ThemeResource` 的地方还没全换，留给 R4 的后续。

### R19（P2）编码：一个文件的注释是乱码、提交信息带 BOM → 已修（`2728574`）

- `Shell/OverlayWindow.cs` 文件头 4 行和第 146 行按原意重写；DeepL / Google / Microsoft 三个
  Provider 去掉 BOM；新增 `windows/.editorconfig`（`charset = utf-8`）；
  本地设了 `git config i18n.commitEncoding utf-8`，提交信息用 Python / write 工具写不带 BOM 的 UTF-8。
- 怎么验的：读文件头是正常中文；`python` 检查 Providers 下没有 BOM；本次提交标题无 U+FEFF。

### R4（P1）设置里选的外观和系统不一样时，代码里设的颜色全是错的那一套 → 已修（`4b7e0c1`）

- `Theme.Brush` 改成按设置里选的那套深浅色去 `XamlControlsResources.ThemeDictionaries[Dark / Light /
  HighContrast]` 取；`SecondaryText / CardBackground / CardColor` 用 `EffectiveTheme`；
  设置窗标题栏用 `AppWindow.TitleBar.PreferredTheme`。
- 怎么验的：系统浅色 + 设置里深色，设置窗卡片深底浅字、翻译卡深底、计算结果说明可见
  （`windows\build\shots\r4\`）；运行中切换外观时设置页会重建、取到新的那一套。

### R5（P1）轻提示和托盘菜单的宿主窗口不是透明的 → 已修（`4b7e0c1`）

- 新增 `Shell/TransparentBackdrop.cs`，轻提示和托盘菜单的宿主窗口都用它；`OnTargetConnected` 里给
  `connectedTarget.SystemBackdrop` 设一个全透明的 `Windows.UI.Composition` 颜色画刷。
- 怎么验的：整屏截图里胶囊外面没有白框；托盘菜单打开时 360×480 的宿主窗口看不见。

### R6（P1）剪贴板列表的标题被挤成三个字，来源显示成 WebView2 → 已修（`4b7e0c1`）

- 行右栏只放短时间（刚刚 / N 分钟前 / N 小时前 / 昨天 / MM-dd / yyyy-MM-dd），来源只在预览卡卡头显示；
  `Core/ProcessTree.cs` 顺着 `th32ParentProcessID` 跳过 `msedgewebview2.exe` 这类宿主，
  `ClipboardFormats.Source` 用 Toolhelp 快照查表。
- 怎么验的：截图里标题能显示到六成以上；`ProcessTreeTests` 覆盖三层 WebView2、普通进程、环、大小写。

### R7（P1）启动器的计算结果那一行溢出了 → 已修（`4b7e0c1`）

- 结果行 64 DIP、普通行 48；`PanelMetrics.LauncherHeightFor` 按实际行高算，选中高亮用容器高度。
- 怎么验的：`PanelMetricsMixedRowsTests`；深色截图里结果和说明都在行内。

### R8（P1）翻译浮窗的高度没算对，最后一张卡被底栏盖住 → 已修（`4b7e0c1`）

- `NeededHeightDip` 改成 Measure + DesiredSize；设置类错误只给「打开设置」，网络 / 服务类给「重试」。
- 怎么验的：截图里错误卡完整显示（`translate-dark2.png`），按钮只有「打开设置」。

### R9（P2）界面文字里不该出现给开发者看的话 → 已修（`4b7e0c1`）

- 通用页和关于页的文案、0.1.0 更新日志只留功能；全项目查过没有「...」占位。

### R10（P2）设置窗的几处细节 → 已修（`4b7e0c1`）

- 每项一个图标、数据目录改成卡片、关于页加应用图标、导航 / 菜单项不画焦点框（焦点给内容区）。
- 怎么验的：截图（`settings-dark-system-light.png`）里图标各不相同、数据目录是卡片；
  托盘菜单第一项没有焦点框。

### R11（P3）截图卡片和更新下载的小问题 → 已修（`4b7e0c1`）

- 拖出用 deferral + await；启动时清空 `%TEMP%\kitty-shots`；下载把 `Content-Length` 当 `knownTotal` 传进去。
- 怎么验的：`UpdateDownloadTotalTests`（不可 seek 的流也能报总大小）。

### R1（第二版第 2 批，`da8cc1a9`）自动更新只认 GitHub 的 https 地址 → 已修（`58e62c2`）

- `Core/UpdateTrust.cs`：发布列表 / 下载地址的白名单纯函数；`App/UpdateHttp.cs` 自己逐跳处理跳转、
  每一跳都过白名单。`KITTY_UPDATE_FEED`、`file://`、本地路径、`http://` 只在 Debug 或 `--update-test` 下认。
- 怎么验的：`UpdateTrustTests` 8 种地址（含大小写、端口、账号密码、`github.com.evil.com`、别的仓库）全过；
  Release AOT 正常启动设 `KITTY_UPDATE_FEED` → 日志 `update.feed-ignored` + `localFeed=False`；
  带 `--update-test` → `newer=True localFeed=True` 并下载成功。

### R2（同上）更新完退出要走正常的退出流程 → 已修（`58e62c2`）

- `AutoUpdater.ExitApplication()` 调 `ShellRuntime.Instance.Exit()`（提交剪贴板删除、注销热键、删托盘图标），
  没有壳时才退回 `Application.Exit()`。
- 怎么验的：自动更新成功路径（同 `HANDTEST.md` §135）看托盘只剩一个图标；`ShellRuntime.Exit` 的
  `clipboard.ready` / `tray.added` / 热键注册在更新前后一致。

### R3（同上）下载直接写文件，不整个读进内存 → 已修（`58e62c2`）

- `Core/UpdateDownload.cs`：80 KB 一块流式写 `updates\<文件名>.partial`，写完才改名；失败 / 取消删半成品。
  托盘那一项在下载中显示「正在下载 37%」。
- 怎么验的：`UpdateDownloadTests`（成功改名、失败不留半成品、取消不留半成品、旧 .partial 被替换）；
  400 MB 假 zip 实测私有提交 91.9 → 100.6 MB（+8.7 MB，不随文件大小涨），校验失败后 `updates\` 里没有残留。

### R68（P1）0.1.0 用户真机反馈的四条 → 已修

- 截图工具栏没有保存、没有打勾：右边那段改成和 mac 一样的 识字 · 翻译 · 钉图 ｜ 保存 ▾（快速保存 / 另存为…）｜ ✕ ✓（✓ = 复制，Enter）。
- 截图瞬间整屏闪白：遮罩每次新建，Win2D 第一帧之前 WinUI 先合成一帧白底。`ShowOverlay` 先 DWM cloak，冻结帧画完再过两次合成才露出来，最多藏 300 ms。
- 截图翻译的浮窗从别处飘到选区旁：以前先在上次收起的位置 `Show()` 再挪。`TranslateWindow.ShowCore` 多一个 `place`，所有入口都先挪好再显示。
- 剪贴板透镜带滚动条：短文字的正文高 36，卡头（来源 + 三个按钮）就占满了，正文溢出。滚动条改成 Hidden（滚轮照样滚），一行放得下的普通文字不在透镜里再画一遍（同 mac `Lens.bodyHeight`）。
- 怎么验的：Debug 零警告；`--ui-snapshots` 的 shot-toolbar 和 clip 两张图；`--screenshot` 实机：cloak 之后遮罩正常露出、Esc 能关。闪白、浮窗位置没逐帧录，要真机再看一眼。

## 有异议

（还没有）
