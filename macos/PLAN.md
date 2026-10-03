# kitty-tools 原生 macOS 分支迁移方案（Phase 1：剪贴板历史 + 翻译）

> 2026-10-03（第二轮体检第 8 批）：本文只留仍有效的部分——§2 技术栈白名单、§4 架构与文件表、§8 打包、§10 约束 / 已拍板决定的结论 / 不做清单、§11 实现原则与语言规则、§12 现状与下一步。迁移期历史（开头的基线、§0 §1 §3 §5–§7 §9、两个附录）和已完成批次的实现记录（§10 原文、§11½、§12 的进度记录）原样挪到 `docs/archive/`，手测清单挪到 `HANDTEST.md`（条目和编号不变）。挪走的章节在原位置留着标题和去处，「PLAN §N…」这类旧引用按编号照样找得到。
> 2026-09-27：Tauri 快照已从本分支删除，下文的 `src/`、`src-tauri/` 路径指 master `ee615b3` 上的文件。
> 2026-09-26 起：本文是迁移期的历史方案。原生版不再参考 Tauri：§5 的「照搬 / 一致」只代表当时的实现；行为、界面、默认值、文案以各 mac-* 规则、Whisker 和对标产品为准。旧版导入（§6）已删除，强调色改为品牌粉（D13 作废）。

开头的「基线」（2026-09-24 的 master、Tauri 版、开发机、本机旧配置）和「一句话方案」已归档到 `docs/archive/PLAN-migration.md`。

---

## 0. 需要你拍板的决策点

已归档到 `docs/archive/PLAN-migration.md` §0（D1–D15 全表：推荐、理由、备选）。仍有效的结论：D5 Bundle ID 以后不再改；D7 长期不公证，只走路径 B（§8.3）；D8 应用内更新（`App/Updater.swift`，读本仓库的 latest release）；D10 只支持 Apple 芯片；D15 不设「默认服务」，翻译历史和自动复制取列表里第一个启用的服务。

---

## 1. 分支与仓库布局

已归档到 `docs/archive/PLAN-migration.md` §1（建 worktree、`.gitignore` 放行规则的由来）。现状：分支 `main`，开发区 `macos/`，目录见 AGENTS.md「目录结构」。

---

## 2. Apple 官方技术栈

| 框架 / API | 最低 macOS | 用途 |
|---|---|---|
| Swift 6.2，Swift 6 语言模式；`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`、`SWIFT_APPROACHABLE_CONCURRENCY=YES`（写在 xcconfig，M0 用 `-showBuildSettings` 验证生效） | 工具链 | 严格并发检查，默认跑在主线程 |
| SwiftUI：`App`、`MenuBarExtra(.menu)`、`Form`、`ContentUnavailableView` | 13 / 14 | 菜单栏和全部视图 |
| Observation `@Observable` | 14 | store 和 view model |
| AppKit：`NSPanel`、`NSHostingView`、`NSWindow` + `NSHostingController`（设置窗装 SwiftUI `NavigationSplitView`）、`NSStatusItem`（菜单栏图标与菜单）、`NSTextField`/`NSTextView`、`NSEvent` 监听、`NSWorkspace`、`NSRunningApplication` | 10.x | 不激活前台的浮层、设置窗、兼容输入法的输入框、来源 App、单实例检查 |
| Carbon HIToolbox `RegisterEventHotKey`；`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` | 10.0（26.2 SDK 中未废弃） | 全局热键；录制快捷键时显示键名 |
| ApplicationServices：`AXIsProcessTrustedWithOptions`、`AXUIElement`、`AXUIElementSetMessagingTimeout` | 10.x | 辅助功能授权、读取选中文本 |
| CoreGraphics `CGEvent` | 10.x | 模拟 ⌘V / ⌘C；长截图自动滚动发像素级滚轮事件（`CGWarpMouseCursorPosition` 先把光标挪进选区） |
| `NSPasteboard`（`changeCount`、`accessBehavior`） | 10.0 / 15.4 | 剪贴板采集、剪贴板隐私状态 |
| ImageIO + UniformTypeIdentifiers | 10.x / 11 | PNG 编码、读取尺寸、按需生成缩略图；录屏转 GIF（`CGImageDestination` 逐帧写 GIF，录屏录音第 7 批 `Screenshot/VideoExport.swift`） |
| QuickLookThumbnailing `QLThumbnailGenerator` | 10.15 | 剪贴板检查器里文件的真实缩略图（PDF 首页、图片、视频帧） |
| QuickLookUI `QLPreviewView` | 10.6 | 剪贴板 ⌘Y 放大预览里的文件（嵌在自己的浮层里；不用 `QLPreviewPanel`，见 D3） |
| Vision `RecognizeTextRequest` | 15.0 | 剪贴板图片 OCR、截图翻译识字 |
| ScreenCaptureKit `SCShareableContent` + `SCScreenshotManager` | 14.0 | 截图翻译的冻结帧（逐屏截图）；长截图用 `SCStreamConfiguration.sourceRect`（12.3+）反复截选区 |
| NaturalLanguage `NLLanguageRecognizer` | 10.14 | 语种检测（替代 Lingua，能识别繁体） |
| ScreenCaptureKit `SCStream` + `SCRecordingOutput`；AVFoundation `AVAudioRecorder`、`AVCaptureDevice`（麦克风授权与设备）、`AVURLAsset` / `AVAssetImageGenerator` / `AVAssetExportSession` / `AVMutableComposition`；Synchronization `Mutex` | 15.0 | 录屏与录音（2026-09-30 立项，PLAN §10「录屏与录音」）：系统录制管线直接写文件、录音、闪退恢复读文件、最后一帧、音轨导出；录制委托的可变状态（`Mutex` 翻译服务已在用）。第 1 批起在用：`SCStream` + `SCRecordingOutput`（`Screenshot/ScreenRecorder.swift` 录屏）、`AVURLAsset`（启动时读上次闪退留下的文件 `isPlayable`）；第 3 批起 `AVAssetImageGenerator`（停止后取最后一帧，飞入和视频卡用）；第 4 批起 `AVCaptureDevice`（麦克风授权、默认输入的设备名 / 蓝牙、断开通知）；第 5 批起 `AVAudioRecorder`（`Screenshot/AudioRecorder.swift` 录音：m4a、暂停续写、`updateMeters` / `averagePower` 电平，主线程直接用、不挂委托）；第 6 批起 `AVMutableComposition` + `AVAssetExportSession`（录系统声音：录屏管线的 mp4 只取音轨无损导出成 m4a，`ScreenRecorder.extractAudio`）和 `CMSampleBuffer` 的格式描述 / 数据块（样本回调里读 Float32 声音样本算电平）；第 7 批 `AVAssetImageGenerator` 还用来逐帧取 GIF 的帧（`VideoExport`） |
| AVFoundation `AVSpeechSynthesizer` | 10.14 | 朗读 |
| Foundation `URLSession.bytes(for:)`、`AttributedString(markdown:)` | 12 | SSE 流式输出、行内 Markdown |
| CryptoKit：`Insecure.MD5`、`SHA256` | 10.15 | 百度 / 有道签名、图片去重 hash |
| Security `SecItem*` | — | API Key 存钥匙串 |
| Foundation `URLSession.download`、`Process`（调系统的 `/usr/bin/ditto`、`/usr/bin/codesign`、`/bin/chmod`；启动器 kill 列进程的 `/bin/ps`、`/usr/sbin/lsof`；浏览历史 / Firefox 书签的 `/usr/bin/sqlite3 -readonly -json -init /dev/null`；共用 `Shell/Subprocess.swift`，要的输出写临时文件） | — | 应用内更新：下载更新包、解包、验签（D8）；kill 列后台进程和监听端口（体检 D12）；导出各家浏览器的浏览历史和 Firefox 书签（体检 D8、第 12 批） |
| 启动器系统命令（D2，2026-09-27）：`Process` 调 `/usr/bin/pmset`（睡眠、关闭显示器）和 `/usr/bin/osascript`（访达清倒废纸篓、loginwindow 的退出登录 / 重新启动 / 关机 Apple Event、`set volume`）；`NSRunningApplication` 的 `terminate` / `forceTerminate` / `hide`；`FileManager.unmountVolume`；`dlopen` / `dlsym` 系统私有 `login.framework` 的 `SACLockScreenImmediate`（锁屏，用户拍板的唯一私有 API，找不到退回 `CGEvent` 模拟 ⌃⌘Q）；entitlement `com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`；`kill(2)` 给 kill 列的进程发 SIGTERM / SIGKILL（体检 D12） | 10.x | 锁屏、睡眠、屏保、废纸篓、退出登录 / 重启 / 关机、退出 / 隐藏 / 强制退出 App、推出磁盘、音量、结束进程 |
| 系统 libsqlite3（`import SQLite3`；本机 3.43.2，带 FTS5） | — | 剪贴板历史和翻译历史 |
| ServiceManagement `SMAppService.mainApp` | 13 | 开机自启 |
| `os.Logger`、Swift Testing | 11 / Xcode 16 | 日志、单元测试 |
| 本地化：不建 String Catalog；开发语言设为 zh-Hans，Info.plist 声明 `CFBundleLocalizations = [zh-Hans]`，SwiftUI 里直接写中文字面量 | — | 让系统自带的菜单、弹窗、关于面板显示中文 |
| `xcodebuild`、`hdiutil`、`codesign`、`spctl`、`swift-format`、`jq`（macOS 15 自带）；拿到证书后加 `notarytool`、`stapler` | — | 构建、打包、签名、格式化、changelog 校验 |
| 以后可选：Translation（15，需依附视图）、FoundationModels（26）、`glassEffect`/`NSGlassEffectView`（26，届时就地写 `#available`） | 15 / 26 | 不在 Phase 1 范围 |

**非 Apple 依赖：运行时 0 个，开发期 0 个。**
- nspasteboard.org 的 `ConcealedType` / `TransientType` / `AutoGeneratedType` 只是几个字符串常量，不是依赖。
- changelog 校验和发布说明用系统自带的 `jq`，不依赖 Node，也不改 `scripts/release-notes.mjs`。
- 明确不用：Sparkle（见 D8）、GRDB、KeyboardShortcuts、swift-markdown-ui、XcodeGen、Tuist、create-dmg、SwiftLint、nicklockwood/SwiftFormat。

**持久化选 libsqlite3，不选 SwiftData**：
- 旧库本来就是 SQLite，导入不用做格式转换。
- SwiftData 在 Swift 6 下跨隔离使用 `ModelContext` 很麻烦，而且没有全文索引。
- 搜索在内存里做（保留上限最多 5000 条）。
- 一个约 150 行的 `Database` 封装就够用。

---

## 3. 规范 rules 与 skills

已归档到 `docs/archive/PLAN-migration.md` §3（M0 时的规则与技能计划）。现行的规则、技能和触发范围见 AGENTS.md「规则与技能」。

---

## 4. 原生架构

**工程划分**
- 1 个 App target `KittyTools`，加 1 个测试 target `KittyToolsTests`（只测纯函数）。
- 不建 SPM 包、framework、extension，也没有辅助进程。

**文件结构**（一个概念一个文件，不预先建空目录）

| 目录 | 文件 |
|---|---|
| `App/` | `KittyToolsApp.swift`（入口 `@main enum Main`：带 `--ocr` 起的是剪贴板后台识字的子进程，只识字不启动 App；否则启动 `KittyToolsApp`，唯一的 scene 是不插入菜单栏的 MenuBarExtra，菜单栏图标在 `Shell/StatusItem.swift`）、`AppDelegate.swift`（单实例检查、组装对象、生命周期、退出和锁屏清理）、`Updater.swift`（应用内更新，D8）、`Log.swift`（统一日志 os.Logger，不记密钥、URL、剪贴板正文） |
| `Shell/` | `OverlayPanel.swift`、`TransientPanel.swift`（用时再建、收起后放掉的浮层：两张 ⌘Y 大卡由它拿着，第二轮体检 M3）、`Memory.swift`（让分配器把空页还给系统，M4）、`HotKeyCenter.swift`、`HotKeyRecorder.swift`、`Permissions.swift`（辅助功能、屏幕录制、文件和文件夹授权、麦克风（录屏第 4 批）；自动化被拒时打开系统设置）、`Paster.swift`（自家写剪贴板的唯一出口；`write(string:record:)` 把本 App 生成的新文字同时记进剪贴板历史）、`Subprocess.swift`（进程外跑系统命令行工具：更新的 ditto / codesign、系统命令的 pmset / osascript、kill 的 ps / lsof、浏览历史的 sqlite3，还有剪贴板后台识字的子进程（本 App 带 `--ocr`）；要的输出写临时文件，不受 64 KB 管道缓冲限制；可给环境变量、超时、优先级）、`Style.swift`（Whisker 刻度：圆角、七条弹簧曲线、中性色 / 家族色、输入框 `InputBox`、复制对勾停留、卡片表面 `CardSurface`、增强对比度的选中描边 `contrastSelectionBorder`、发丝线 `Hairline` / `hairlineBorder`、主按钮 `BrandButtonStyle`、种类色块、键帽、面板描边）、`HoverTracker.swift`（列表行悬停：`.activeAlways` 追踪区，非激活浮层里代替 `onHover`；剪贴板、翻译历史、启动器行共用）、`ListReveal.swift`（列表选中跟随滚动：`ListReveal.target` 纯函数按前缀和给目标 y，`RevealsSelection` 接管 `.scrollPosition`、按上次滚动的终点判断、停下没到补滚一次；剪贴板、启动器、翻译历史共用，第 10 批）、`CommandTextField.swift`（单行输入框：方向键 / 回车 / Tab / Esc 走 doCommandBy，对话框输入框、`maxLength`）、`BarNotice.swift`（剪贴板面板、启动器底栏左边的就地提示）、`Accent.swift`（强调色：跟随系统 + 8 色、配色计算、根视图的 `.appAccent()`）、`Island.swift`（刘海岛：全局轻提示，替换原来的 Toast；`Island.announce` 是 VoiceOver 主动播报的唯一入口）、`StatusItem.swift`（菜单栏图标与菜单，NSStatusItem，Whisker D 的呼吸 / 弹一下；`MenuExtra`：菜单栏和启动器内置动作共用的非热键项）、`ActionMenu.swift`（剪贴板 ⌘K、剪贴板筛选面板、剪贴板多选的收藏夹列表、启动器 ⌘K、翻译历史 ⌘K 共用的动作菜单：分节、一级子列表、共用过滤 `filter`（子串 + 拼音前缀），体检 C3 C4） |
| `Storage/` | `Database.swift`、`Backup.swift`（数据库的每日备份 `Backup` + 打不开时的恢复 `Recovery`，第二轮体检 S2）、`Keychain.swift`、`Prefs.swift`（~~`LegacyImport.swift`~~ 2026-09-26 随旧版导入删掉） |
| `Clipboard/` | `ClipboardWatcher.swift`、`ClipboardStore.swift`、`ClipItem.swift`、`ClipboardFilter.swift`、`ContentForm.swift`、`Search.swift`、`ImageStore.swift`、`OCR.swift`、`ClipboardPanelModel.swift`（面板状态与操作：筛选标签、选中 / 多选、键盘命令、粘贴 / 复制 / 删除撤销栈、⌘K）、`ClipboardPanelView.swift`、`ClipRowView.swift`、`LensView.swift`（透镜：选中行原地展开的预览）、`PreviewView.swift`、`Dialogs.swift`、`Snippet.swift`（片段占位符展开）、`LinkPreview.swift`（链接富预览：按块读网页 og 标签、isFetchable、内存缓存）、`QuickLookView.swift`（⌘Y 放大预览）、`ClipDrag.swift`（行拖到别的 App：AppKit 拖放会话 + 行首图标块和标题的预览，体检 D3） |
| `Translate/` | `TranslateCoordinator.swift`、`TranslateService.swift`（服务列表与配置：内置 8 家可删可加回、自建 AI 实例、厂商预设）、`Language.swift`（应用内语言、语种检测、源 / 目标解析）、`SelectionReader.swift`、`SourceTextView.swift`（多行输入框：翻译原文、剪贴板编辑正文 / 新建片段）、`HTTP.swift`（JSON POST、SSE 读取、中文错误信息）、`SSE.swift`、`Providers/`（`Zhipu.swift`、`AIService.swift`（OpenAI 兼容 / Azure / Anthropic，也给智谱复用流式请求；按地址认厂商的表 `AIVendor`，第 13 批）、`RESTProviders.swift`（百度、有道、Google、DeepL / DeepLX、微软）、`CloudProviders.swift`（火山、腾讯，请求签名）、`Signing.swift`（摘要工具、非流式请求包装））、`TranslatePanelView.swift`、`ProviderCardView.swift`（含服务身份 `ServiceTile`：官方 logo、官网图标或品牌色块，彗星边框、骨架扫光）、`ServiceIcons.swift`（自建 AI 服务的官网图标：推官网、经 `LinkPreview.siteIcon` 取、磁盘缓存，第 13 批）、`ResultText.swift`（结果卡片的正文：普通 Text + 生成中的光标；原 RevealText 的显影第二轮体检第 1c 批拿掉）、`HistoryStore.swift`、`HistoryView.swift`（含历史 ⌘K 的动作和 `HistoryMenu`：导出、清空，浮窗「⋯」菜单 / 历史 ⌘K / 设置 › 翻译共用）、`Speaker.swift`（朗读：收起即停、挑高音质声线）、`WordLookup.swift`（查词：是不是一个词、系统词典查询与解析、单词模式示例，D4）、`DictionaryCardView.swift`（系统词典卡） |
| `Settings/` | `GeneralTab.swift`、`HotkeysTab.swift`、`ClipboardTab.swift`、`TranslateTab.swift`、`AboutTab.swift`、`LauncherTab.swift`、`ScreenshotTab.swift`、`SettingsWindow.swift`（D 阶段从 Shell 搬来：NavigationSplitView 侧栏 + 搜索 + 页头）、`OnboardingView.swift`（首次安装的欢迎引导：欢迎 + 按一下试试）、`ShortcutsSheet.swift`（快捷键速查表 + `ShortcutsButton`）、`OrderedList.swift`（可拖动排序列表共用的「+ −」按钮条、行高、详情页页头）、`TranslateServiceDetail.swift`（翻译服务详情页）、`SearchEngineDetail.swift`（网页搜索 / 快捷链接详情页） |
| `Launcher/` | `LauncherItem.swift`（结果项与内置动作）、`AppCatalog.swift`（App 目录 + 中文名 + 拼音）、`LauncherMatch.swift`（匹配与排序纯函数）、`LauncherUsage.swift`（使用记录表 + 收藏表 launcher_favorites，体检 D13）、`LauncherModel.swift`、`LauncherPanelView.swift`、`FileSearch.swift`（文件搜索：open / find / 空格开头，NSMetadataQuery 查询、排除、排序、最近的文件、授权提示，M13）、`SystemCommands.swift`（系统命令目录、quit / hide / forcequit / eject / kill 解析与只读列举，D2）、`SystemControl.swift`（系统命令的执行：锁屏、pmset、osascript、退出 App、推出、给进程发信号）、`Processes.swift`（kill 列的后台进程：ps / lsof 输出解析与排序，体检 D12）、`SiteIcons.swift`（网址行的网站图标：读本机 Chromium 系浏览器的 Favicons 库 + 链接预览，按主机缓存，体检 D6）、`BrowserHistory.swift`（各家浏览历史 + Firefox 书签：克隆后 sqlite3 导出、解析、行，体检 D8、第 12 批）、`Bookmarks.swift`（浏览器书签：Chromium 系 JSON、Safari plist，Firefox 取 BrowserHistory 读好的）、`Browsers.swift`（第 12 批：浏览器表、装没装、数据目录与多配置、偏好里开着的、克隆别人的库、读失败分「没授权 / 没有文件」）、`DirectItems.swift`（网址 / 路径直达，纯函数）、`WebSearch.swift`（网页搜索与快捷链接列表）；`AppCatalog.swift` 顺带扫系统设置面板（体检 D9），`Calculator.swift` 含单位换算表和进制（体检 D11） |
| `Screenshot/` | `ScreenCapture.swift`（逐屏冻结帧 + 同一刻的窗口 Z 序快照）、`RegionSelector.swift`（框选会话、每屏一个遮罩、选区几何纯函数）、`SelectionView.swift`（遮罩画面与交互：图层绘制、窗口悬停、手柄、放大镜、工具栏）、`ScreenshotOutput.swift`（PNG、快速保存、另存为）、`PinPanel.swift`（钉图；第二轮体检 F1 起还有「钉住剪贴板里的图」的取图、解码、找位置）、`Annotation.swift`（标注模型，显示与导出共用 draw，M10）、`EditorToolbar.swift`（HUD 主工具栏 + 样式托盘，M10，Whisker 重做）、`FlyCard.swift`（截图飞入右下角 + 快门声，Whisker S1；录屏第 3 批起录屏的最后一帧也从这里飞，落地多播放符号和时长 `VideoMarks`）、`ScrollCapture.swift`（长截图会话：边框、侧边面板、抓帧循环、自动滚动）、`ScrollStitcher.swift`（长截图拼接，纯逻辑）、`ShotShelf.swift`（CleanShot 式常驻缩略图，Whisker D；录屏第 3 批加视频卡 `ShelfCard.Kind.video`，右键菜单 / 旁白动作同一份 `ShelfCard.menu`）、`SizeField.swift`（遮罩里的尺寸胶囊：就地输入宽高、比例菜单）、`ScreenRecorder.swift`（录屏会话：SCRecordingOutput 先写到同卷、系统不清理的地方再挪进快速保存目录、白名单面板的例外过滤器、选区边框、菜单栏停止项、中断与闪退恢复，录屏第 1 批；第 2 批加倒数、放弃、帧率 / 倒数 / 光标设置；第 3 批挪好后取最后一帧 `poster`；第 4 批按录制条开关配声音 / 麦克风 / 点按（`Options`、`configure`）、开录前问麦克风授权、麦克风断开；录制条（四个开关：系统声音、麦克风、显示点按、显示按键） `RecordBar` 在 `EditorToolbar.swift`、框选是 `SelectionView` 的 `.record` 模式；手测反馈第 1 批起点按圈由 `InputOverlay` 画，`configure` 只管声音，过滤器例外多并一个它的窗口号 `exceptedOwnWindows`）、`InputOverlay.swift`（录屏里显示用户的输入，手测反馈第 1 批 2026-10-01：显示点按开着时盖在被录区域上的透明 NSPanel（普通实例、不接鼠标、层级 popUpMenu + 2），global / local 鼠标监听，按下圆盘 / 右键空心环 / 拖动跟随 / 松开涟漪都是 CALayer 动画；坐标换算、形状、哪些自家窗口上不画是纯函数；手测反馈第 2 批加按键提示：录制条「显示按键」开着时同一块窗口底部居中的 HUD 胶囊，global / local 的 keyDown 监听（global 要辅助功能授权），键名复用 `HotKey.display`，内容和停手清空是纯状态 `Keys`，位置是纯函数；显示点按 / 显示按键任一开着就建窗口）、`RecordingHUD.swift`（录制 HUD：倒数 / 录制中两态、红点呼吸、计时、放弃两下、停止，普通 NSPanel 状态栏层级、能拖，录屏第 2 批；第 4 批录制态加只读声音状态（系统声音 / 麦克风，开录时的麦克风断开变橙）；录音第 5 批加录音形态 `medium = .audio`：电平 `LevelMeter`、暂停 / 继续、「没听到声音」、底部居中从底边长出来；手测反馈第 3 批加录音的待录态 `State.ready`：[系统声音][麦克风] ｜ [✕][●]，来源开关读写 `Prefs.audioRecordSource`，开始后原地换成录制态）、`VideoExport.swift`（录屏转成 GIF，录屏录音第 7 批：15 fps、宽 ≤ 960、最长前 60 s，`AVAssetImageGenerator` 逐帧取、`CGImageDestination` 逐帧编（关全局调色板）、`@concurrent`；帧时刻 / 输出尺寸 / 存盘名是纯函数；常驻缩略图的 GIF 卡是 `ShelfCard.Kind.gif`，入口是视频卡的「转成 GIF」`ShelfCard.convertToGIF`）、`AudioRecorder.swift`（录音会话，录音第 5 批：AVAudioRecorder 录 m4a、授权、暂停续写、20 Hz 电平与 `Levels` 历史、「没听到声音」、中断（系统睡眠 / 输入设备断开 / 磁盘）、停止后画波形 poster；收尾挪文件、闪退恢复、结果岛、菜单栏停止项和录屏共用 `ScreenRecorder` 的 `settle` / `recover` / `summary` / `makeStopItem`（`ScreenRecorder.Medium`），常驻缩略图的录音卡是 `ShelfCard.Kind.audio`；第 6 批加来源 `Source`（麦克风 / 系统声音 / 两者），后两种用 `ScreenRecorder` 的只录声音模式 `audioOnly` 当引擎，电平由它的样本回调算好投过来；手测反馈第 3 批分成两个阶段：`open()` 待录只出控制条，`start()` 才读来源、问 `allowsStart`、开录） |

各 provider 函数签名统一，由 coordinator 里的一个 `switch` 分发。不建 registry 或 factory。

**文档**（`macos/` 下，2026-10-03 第二轮体检第 8 批）：`PLAN.md`（本文，仍有效的方案）、`HANDTEST.md`（发版冒烟清单 + 各批手测条目，新的手测往里加）、`docs/archive/`（PLAN 挪出去的迁移期历史和已完成批次的实现记录，原样、只查不改：`PLAN-migration.md`、`PLAN-10.md`、`PLAN-12.md`）。

**并发模型（Swift 6 strict concurrency）**
- **默认全部跑在 `@MainActor`**，包括：UI、各个 store、`Database`（单连接，每次写一行小于 1ms）、watcher 的 0.3s `Timer`、热键、所有 `NSPasteboard` 读写、剪贴板搜索、旧数据导入。剪贴板访问因此天然串行，替代了 `R/mac_access.rs` 里的锁。
- **只有下面 3 类工作用 `@concurrent`**，参数和返回值都是 `Sendable` 值类型：
  1. 图片编码、hash、缩略图；
  2. Vision OCR；
  3. AX 读选中文本（先设 `AXUIElementSetMessagingTimeout(0.5)`，防止目标 App 卡死时拖住主线程）。
- 搜索留在主线程：M2 用 5000 条压测，测出卡顿再挪出去（`ponytail:` 注释写明上限）。
- **网络**：provider 写成 `nonisolated` async 函数。开启 `NonisolatedNonsendingByDefault`（approachable concurrency 自带）后，它在调用方所在的 actor 上执行；`URLSession` 本身是异步的，不需要额外的 actor。
- **会话取消**：`TranslateCoordinator` 持有 `currentTask`，新会话开始时 `cancel()` 旧的；各服务在 `withTaskGroup` 里并行执行，每张卡片可以单独重试。这一套替代了 Tauri 版的会话代数、fanOutKey、pending 重放和前端超时计时器。
- **C 回调**：Carbon 热键的回调本来就在主线程投递，回调里用 `MainActor.assumeIsolated {}`。

**单实例**：`applicationDidFinishLaunching` 最开始检查 `NSRunningApplication.runningApplications(withBundleIdentifier:)`。如果有更早启动的实例，就对它所在的包再 `NSWorkspace.open` 一次（LaunchServices 给它发 reopen → 进设置；只 activate 的话没窗口的菜单栏 App 什么也不显示，第 9 批评审改），然后自己 `NSApp.terminate(nil)`。LaunchServices 不保证同一 bundle id 只跑一份，比如从挂载的 DMG 里运行一份、/Applications 里又启动一份。约 5 行。

**窗口体系**
- **App 入口与菜单栏**：
  - `@main struct KittyToolsApp: App` 用 `@NSApplicationDelegateAdaptor` 挂 AppDelegate，~~唯一的 scene 是 `MenuBarExtra(.menu)`~~（D 阶段：菜单栏图标和菜单改成 AppKit `NSStatusItem`（`Shell/StatusItem.swift`，图标要做动效），这里只留一个不插入菜单栏的 MenuBarExtra 当 scene）。
  - `LSUIElement=YES`：不显示 Dock 图标，启动时不闪。
  - ~~菜单项：剪贴板历史 / 划词翻译 / 输入翻译 / 复制即译（Toggle）/ 设置… / 退出。快捷键用 `.keyboardShortcut` 显示；热键为空时显示「未设置」。~~ 现状（N15、体检 A26）：按 `HotKeyAction.sections` 分三节，和快捷键页同名同序，每节末尾接那一节的 `MenuExtra`（暂停记录剪贴板、复制即译、有钉图时的两项）；右边是当前生效的快捷键，没设 / 注册失败的留空；最后 设置… / 关于 / 检查更新…（正式版）/ 退出，启动器的内置动作读同一份。
  - 菜单栏图标默认用单色模板图（2026-09-29 第 9 批起设置 › 通用可改成彩色 App 图标或隐藏，见 §12「菜单栏图标手测」）。左键点击直接弹菜单（HIG 做法），去掉 Tauri 版「左键打开主界面」。
- **`OverlayPanel: NSPanel`**，~~建两个实例~~（现在 5 个：剪贴板面板、剪贴板 ⌘Y 大卡、启动器、启动器 ⌘Y 快速查看、翻译浮窗；细节见 mac-overlay-panel §1）：
  - 剪贴板面板：~~680×520，固定大小~~（透镜指令条：720 宽，和启动器同位置、顶边锚定在可见区 20%，高度按条数伸缩，见 mac-whisker §6）。
  - 翻译浮窗：420×560，最小 360×400，~~用 `setFrameAutosaveName` 记住位置~~（2026-09-28 体检 A13：默认跟随鼠标出现在光标右下，只记用户拖过的位置，`present(anchor:)` + `frameName`，见 mac-overlay-panel §1）。
  - `styleMask` 在 `init` 里一次写全，包含 `.nonactivatingPanel`（初始化后再改不会生效，这正是 Tauri 版不得不 swizzle 的原因）。`canBecomeKey=true`，`canBecomeMain=false`，`isFloatingPanel`，`level=.floating`，`hidesOnDeactivate=false`，`becomesKeyOnlyIfNeeded=false`，`collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary]`，`isMovableByWindowBackground=true`。
  - 显示只调 `orderFrontRegardless()` + `makeKey()`，**永远不调** `NSApp.activate`。
  - **点外关闭**（剪贴板面板）：显示时装一个 global 和一个 local 的左右键按下监听，隐藏时在主线程成对卸载。点中的窗口如果是任意一个 `OverlayPanel`，不关闭（点击时实时判断）；固定（pin）状态下也不关闭。
  - **翻译浮窗失焦隐藏**：`windowDidResignKey`，未固定才隐藏。
  - **固定只管「点别处 / 失焦不收起」**（2026-09-28 体检 A9 用户拍板，推翻下面原来照搬 Tauri 的「翻译浮窗固定时 Esc 不关」）：Esc、⌘W（`OverlayPanel.performKeyEquivalent` 统一处理，三块浮层都认）、再按热键一律收起；剪贴板面板 ⌘P / 底栏图钉切换固定，设置页不再有「点击面板外部时关闭」。
  - **Esc**：通过响应链的 `cancelOperation(_:)` 交给 SwiftUI 状态逐层处理。
    - 剪贴板面板：对话框 > 多选 > 关闭（固定时也关闭）。
    - 翻译浮窗：对话框 > 历史面板 > 关闭（固定时也关闭，2026-09-28 起）。
    - 顺带修掉 Tauri 版原生 Esc 监听抢先关闭面板的问题（`src-tauri/src/plugins/mac_overlay_panel.rs:365-370`）。
- **设置窗**：`SettingsWindow` 用 `NSWindow` + ~~`NSTabViewController(tabStyle: .toolbar)`，每个 Tab 一个 `NSHostingController`~~ 一个 `NSHostingController` 装 SwiftUI `NavigationSplitView`（侧栏 + 搜索 + 页头，D 阶段，见 mac-whisker §6 设置）。
  - 不用 SwiftUI `Settings` scene：在 LSUIElement 应用里它会被压到其它 App 后面，而且 `openSettings` 只能在 SwiftUI scene 环境里调用，浮层上的齿轮按钮调不到。
  - `show()` 的顺序：先把三块浮层（剪贴板、启动器、翻译浮窗）按正常隐藏路径收起（包括作废翻译会话，对应 `src-tauri/src/windows/mod.rs:3683-3685`），再 `setActivationPolicy(.regular)` + `NSApp.activate()` + `makeKeyAndOrderFront`；关闭时切回 `.accessory`。
  - macOS 14 起 `activate()` 是协作式的，不保证一定成功。M3 实测三个入口，到不了最前面就退回 `NSApp.activate(ignoringOtherApps: true)`（已废弃但可用），并写进 `mac-overlay-panel` 技能。
  - 首次安装打开通用页并盖欢迎引导（N14）；~~版本更新后自动打开关于页~~（2026-09-28 体检 A29：更新后不开设置窗、不抢前台，刘海岛「已更新到 x」+ 本版摘要，全文在「关于」）。
- **依赖注入**：
  - 在 `AppDelegate.applicationDidFinishLaunching` 里按顺序创建：`Database` → `ClipboardStore`、`HistoryStore` → `ClipboardWatcher` → `TranslateCoordinator` → 两个面板 → `HotKeyCenter`，通过 init 传递。
  - 根视图用 `.environment(store)` 注入。
  - 偏好用 `@AppStorage`，键名集中写在 `Prefs.swift`，**沿用旧的 camelCase 键名**，默认值用 `UserDefaults.register(defaults:)` 注册；旧偏好换语义时在 `Prefs.migrate()`（启动时紧跟 registerDefaults，幂等）里升级一次，比如 2026-09-28 的排除 App 关键词 → bundle ID 列表。
  - （2026-09-26：默认值以 `Prefs.swift` 为准，不再对齐 Tauri）默认值基本照搬 Tauri，只有一处不同：`translateServiceEnabled` 默认只开 builtin。Tauri 默认还开了有道，全新安装没有密钥，浮窗里会一直挂着一张有道的错误卡。
  - 热键在模型里用 Optional 表示，nil 就是不注册。
  - 不用 DI 容器，也不为了测试去抽 protocol。

---

## 5. 功能迁移映射

已归档到 `docs/archive/PLAN-migration.md` §5（5.1 剪贴板历史、5.2 翻译、5.3 共享外壳：Tauri 行为到原生实现的逐项映射，path:line 指 master `ee615b3`）。只是迁移期的记录，不是规格；§11 里「PLAN §5.x …行」这类引用去那里找。

---

## 6. 数据与配置迁移

已归档到 `docs/archive/PLAN-migration.md` §6（新存储位置、钥匙串条目、旧数据导入；旧版导入 2026-09-26 已删）。现在的库和每日备份见 `Storage/Database.swift`、`Storage/Backup.swift` 和 mac-clipboard 规则。

---

## 7. 里程碑

已归档到 `docs/archive/PLAN-migration.md` §7（M0–M6 的交付物和验收标准；`HANDTEST.md` 里「M1 #1–#5、M2 #2…」指这里的验收条目）。M7 起的里程碑见 §10。

---

## 8. DMG 打包、签名、发布流水线

### 8.1 配置文件

下面是 M0 时的骨架，完整的值以 `macos/Config/*.xcconfig` 为准。

**`macos/Config/Base.xcconfig`**
```
// 版本号唯一数据源；build-dmg.sh 从产物的 Info.plist 读回
MARKETING_VERSION = 0.0.1
CURRENT_PROJECT_VERSION = 1
APP_BUNDLE_ID = com.yy.kitty-tools.native
PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID)$(BUNDLE_ID_SUFFIX)
// .app 名、可执行文件名和显示名（N16，之前叫 Kitty Tools Native）；Tests.xcconfig 的 TEST_HOST 也读它
APP_PRODUCT_NAME = Kitty Tools
PRODUCT_NAME = $(APP_PRODUCT_NAME)
PRODUCT_MODULE_NAME = KittyTools
MACOSX_DEPLOYMENT_TARGET = 15.0
ARCHS = arm64
SWIFT_VERSION = 6.0
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
SWIFT_APPROACHABLE_CONCURRENCY = YES
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = HTX9F4KG39
ENABLE_APP_SANDBOX = NO
ENABLE_HARDENED_RUNTIME = YES
GENERATE_INFOPLIST_FILE = YES
INFOPLIST_FILE = Config/Info.plist
INFOPLIST_KEY_LSUIElement = YES
INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.productivity
// 下面是从模板 target 层搬来的其余设置（ASSETCATALOG_*、LD_RUNPATH_SEARCH_PATHS、ENABLE_PREVIEWS 等），值照抄
#include? "Secrets.xcconfig"
```

**`Debug.xcconfig`**
```
#include "Base.xcconfig"
BUNDLE_ID_SUFFIX = .dev
APP_PRODUCT_NAME = Kitty Tools Dev
```

**`Release.xcconfig`**
```
#include "Base.xcconfig"
BUNDLE_ID_SUFFIX =
CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO
```
最后一行的作用：不让 `get-task-allow` 进入发布包，否则以后公证会被拒。

**`Config/Info.plist`**（局部文件，会和自动生成的 Info.plist 合并）
- `NSAppTransportSecurity` › `NSAllowsArbitraryLoads = YES`：AI 服务端点由用户填写（可能是 http 的自建服务），和 Tauri 版（reqwest）的行为一致。
- `NSLocalNetworkUsageDescription`：「用于连接局域网内的大模型翻译服务」。
- `CFBundleLocalizations = [zh-Hans]`：让系统菜单、弹窗、关于面板显示中文。
- `KittyBuiltinZhipuKey = $(ZHIPU_BUILTIN_KEY)`：值来自不入库的 `Secrets.xcconfig`（把 `.env` 里 `KITTY_BUILTIN_ZHIPU_API_KEY` 的值抄过去）。
  - 安全性和 Tauri 版把 key 编进二进制相同：两种都能被提取出来，接受。
  - 仓库是公开的，但这个值不会进 git。

### 8.2 `macos/build-dmg.sh`（只有路径 B）

以脚本本身为准（发布约束写在它头部注释里），这里不再贴全文。流程：archive → 校验 changelog 有本版条目 → `codesign --verify` → 查 `get-task-allow` → `lipo -archs` → 拷进暂存目录并放 Applications 链接 → 出 DMG（产物名跟 `PRODUCT_NAME` 走：`Kitty Tools_<版本>_arm64.dmg`，卷名 `Kitty Tools`）→ `hdiutil verify` → `ditto -c -k --sequesterRsrc --keepParent` 出 App 内更新用的 `<名字>_<版本>_arm64.zip`，当场解开按 `Updater.requirement` 验签 → 生成 `notes.txt`。

几个选择：
- DMG 格式用 UDZO，这是 Apple DTS 的建议。
- 默认带窗口背景和访达摆位：背景 `Config/dmg-background.tiff`（设计区 600×400 在左上角、整张 2560×1600 pt 防窗口拉大露白，@1x + @2x，由 `swift macos/brand-icons.swift` 生成，改产品名或文案时改脚本重跑），先做可写映像、AppleScript 让访达摆好图标再压成只读；摆位是尽力而为，没有控制访达的权限或 `DMG_LAYOUT=0` 时照样出包，只是没有背景。
- 路径 B 的 DMG 不签名。用 Apple Development 签 DMG 也过不了 Gatekeeper，只会多一次评估。
- entitlements 检查先存进变量再判断，避免 `pipefail` 下 `grep -q` 提前退出导致漏报。
- 如果 archive 时报 `No Account for Team`，加 `-allowProvisioningUpdates`。
- `changelog.json` 格式和 Tauri 版相同（`[{version, date, summary, changes:[{type, scope, text}]}]`），校验和生成 notes 都用系统自带的 `jq`。

### 8.3 路径 B：没有 Developer ID（D7：长期采用）

- 签名：Apple Development，开 Hardened Runtime，不公证。
- 用户安装步骤：
  1. 打开 DMG，把 App 拖进 Applications。和 Tauri 旧版同名：先删掉（或让访达替换）/Applications 里旧版的 `Kitty Tools.app`；从 Kitty Tools Native 升上来的，把旧的 `Kitty Tools Native.app` 也删掉，开机自启可能要在 设置 › 通用 重新打开一次。
  2. 双击时被系统拦下，提示「未打开」。签名是有效的，所以提示不是「已损坏」。
  3. 到「系统设置 › 隐私与安全性」点「仍要打开」（尝试打开后约 1 小时内有效），然后输入密码。也可以直接执行 `xattr -dr com.apple.quarantine "/Applications/Kitty Tools.app"`。
- **只有第一次安装要做上面的步骤**；之后走 App 内更新（D8），下载的包不带隔离标记，不用再放行。
- 比现在的 adhoc 签名好的一点：签名要求绑定在证书上，所以更新后辅助功能授权不会丢。

### 8.4 路径 A：有 Developer ID（D7 已定不做；仅留作将来入会时的步骤备忘，不写任何文件）

1. Account Holder 在 developer.apple.com 的 Certificates 页面，或 Xcode › Settings › Accounts › Manage Certificates 里，创建 Developer ID Application 证书。
2. 执行 `xcrun notarytool store-credentials kitty-notary --apple-id <Apple ID> --team-id <TEAM_ID>`，交互输入 App 专用密码。凭据存在钥匙串里，不进仓库。
3. 新建 `macos/ExportOptions.plist`（`method = developer-id`，`teamID = <TEAM_ID>`）。
4. 在 `build-dmg.sh` 里做两处改动：
   - 把取 `APP` 的那一行换成 `xcodebuild -exportArchive -exportOptionsPlist … -exportPath "$OUT/export"`，再从导出目录取 App。
   - 在 `hdiutil verify` 之后追加：`codesign --sign "Developer ID Application" --timestamp "$DMG"` → `xcrun notarytool submit "$DMG" --keychain-profile kitty-notary --wait` → `xcrun stapler staple "$DMG" && xcrun stapler validate "$DMG"` → `spctl -a -vvv -t open --context context:primary-signature "$DMG"`（期望输出 `source=Notarized Developer ID`）。
5. 当场跑通并验证。公证失败时用 `xcrun notarytool log <submission-id> --keychain-profile kitty-notary` 查原因。
6. 只公证 DMG 这一层。极端情况下（用户把 App 拷出来、卸载 DMG、再离线首次打开）会找不到公证票据，暂不处理。
7. 从路径 B 切到 A 时签名要求会变：用户需要重新授权一次辅助功能，钥匙串条目也会弹一次访问确认。

### 8.5 发布

1. 版本和 tag：Phase 1 发布版为 `0.1.0`，tag 是 `macos-v0.1.0`（打在 `main` 分支上，原名 `macos-native`）。原生版的版本号与 Tauri 版的 0.1.x 各自独立。
2. （2026-09-27 起）在本仓库 github.com/YyAdnBug/kitty-tools 的网页上发**正式 Release**（标 latest，本机没装 `gh`）：tag `macos-v<版本>`，附 `build-dmg.sh` 出的 DMG（首次安装）和 `_arm64.zip`（App 内更新下载它）。和 Tauri 版的仓库无关。~~旧：勾选 pre-release，不要勾 Set as latest release。~~Tauri 的 updater 读的是 `releases/latest/.../latest.json`，一旦被原生版顶成 latest，Tauri 全平台的更新都会 404。
3. ~~GitCode：在确认它的 `releases/latest` 会排除预发布版本之前，不在 GitCode 上发布。~~（2026-09-27 废止，同下）
4. ~~发布后，在 master 工作区执行 `pnpm release:verify`。不修改 `releases/latest.json`。~~（2026-09-27 废止：那是 Tauri 仓库的约束，原生版发在本仓库）
5. CI：Phase 1 不做。以后需要时用 `macos-15` runner，并 `xcode-select` 到 `Xcode_26.3`，保持和本机同一版本。

---

## 9. 风险与已知坑

已归档到 `docs/archive/PLAN-migration.md` §9（迁移期的风险表）。还有效的坑大多写进了规则：TCC 授权跟着签名走（mac-native §6）；浮层焦点、中文输入法、粘贴时序、热键非独占（mac-overlay-panel）；macOS 26 没实测（mac-whisker §2「26 分支」）。15.4 起的剪贴板访问隐私（`accessBehavior`）由设置 › 通用「权限」里「剪贴板访问」一行处理。

---

## 10. 以后迁移启动器和截图时要提前知道的约束

这里只列约束，现在不写任何脚手架。

> 2026-10-03 瘦身：每块只留约束、已拍板决定的结论和不做清单；各批的实现要点、实测数字、评审记录原样挪到 `docs/archive/PLAN-10.md`，按下面同名的粗体小节找。现行的实现约束在各 `mac-*` 规则里，界面规格在 `mac-whisker-<界面>.mdc`。以后的新批次照这个写法：这里只补一两行结论，实现要点和实测数字写进提交说明的正文。

**启动器与截图工具的迁移计划（2026-09-24 定，按用户真实使用数据排优先级）**

用户数据：启动器 3 个月 834 次，网址 82%（书签 / 手输）、App 次之，文件 8 次、kill 7 次、系统命令 0 次；截图历史 24 条里 5 条有标注、全是矩形，美化 / 水印 / 长截图 / 整屏 0 次，钉图 24 次（至 09-17），08-13 后没存过文件；热键 ⌥Space / ⌥A。

- 里程碑：M7 启动器核心、M8 启动器补全、M9 截图框选 + 输出、M10 标注 + 识字、M11 启动器网址线 + 键盘（对标 Alfred）、M12 翻译补强（对标 Bob）已完成；长截图（2026-09-25 插入）、M13 动作面板 + 文件 + 进程（文件搜索、→ / ⌘K 动作面板、⌘Y、kill）代码完成待手测，M13 没有剩下的。各里程碑的内容表原文在归档。

**已拍板（2026-09-24，对标调研后用户选定）**：
- D1 长截图、录屏：都做了。长截图 2026-09-25 改为做（按 macOS 原生方式、不参考旧版），录屏和录音 2026-09-30 立项（见下方「录屏与录音」）。框完收起遮罩、在实时画面上截：用 14.0 的 `captureImage(contentFilter:configuration:)` + `sourceRect`，不用 15.2 的 `captureImage(in:)`。
- D2 系统命令：2026-09-27 改为做——Alfred 的 18 个全做；锁屏用系统私有函数 `SACLockScreenImmediate`（找不到退回模拟 ⌃⌘Q）；只确认不可撤销的（清倒废纸篓、全部退出、强制退出再按一次 ↩，退出登录 / 重启 / 关机弹系统的确认框）；标题用中文、Alfred 关键词做副标题。unlock 做不了，切深浅色不做；kill 在 2026-09-28 体检 D12 做了。见下方「系统命令（D2）」。
- D3 文件动作面板与 Quick Look：动作面板只放零授权动作；⌘Y 嵌 `QLPreviewView`（`QLPreviewPanel` 会激活本 App）；不做目录导航和多文件缓冲。2026-09-28 体检 C7 已做。
- D4 查词 / 生词本：只用系统能力（`DCSCopyTextDefinition` + 单词模式提示词），生词本 = 收藏筛选 + CSV / TSV 导出，不引入 ECDICT；已完成，规则见 mac-translate §5.2。
- D5 系统翻译（离线、免费；2026-09-28 体检 D16「先验证」）：文档不足以确认可行，**先不做，不加 `Kind.apple`**——macOS 15 上会话只能经 SwiftUI 的 `.translationTask` 拿到，视图藏着时跑不跑、下载语言包的许可框在不激活本 App 的浮层里弹不弹得出，文档都没写；26 的 `init(installedSource:target:)` 可行但只能用已装的语言。等有 26 测试机再排期，验证清单在归档。

**开源参考（只借鉴思路，不拷代码）**：
- macshot（github.com/sw33tLie/macshot）：**GPL-3.0**，任何代码 / 文案 / 逐行改写都不能进仓库。约 6 万行 AppKit，截图 / 标注 / 钉图 / 识字 / 长截图 / 录屏都有，可看交互细节。
- Snapzy（github.com/duongductrong/Snapzy）：BSD-3-Clause，同样只借鉴思路。
- 可借鉴：多屏冻结帧用 TaskGroup 并发截（我们已排除自家窗口，比它们先藏窗口更稳）；`CGWindowListCreateImage` 在 15 SDK 已标废弃、不能用；标注用值类型 + 显示与导出共用一个 draw；文字工具叠一个 NSTextView 编辑完再提交；钉图用不激活的 NSPanel、以鼠标为锚点缩放。
- 本机调研原始记录（不入库）：`macos/build/research/`（对标路线 benchmark-roadmap.md、Alfred / iShot / Bob 明细、macshot / Snapzy 源码研究、旧版启动器 / 截图行为清单）。

**不迁**：ts / b64 / url / case / uuid / ip 小工具、~~网站图标~~（2026-09-28 体检 D6 改为做：不联网，只读本机 Chrome 的库 + 剪贴板链接预览取到的，旧版联网抓取仍不迁）、~~Safari / Firefox 书签~~（2026-09-29 第 12 批改为做：用户「浏览器书签与历史缺少 Safari」，拍板加 Safari + 只列装了的，顺带 Firefox 和其它 Chromium 系，见下方「浏览器书签与历史（第 12 批）」）、汇率换算（要联网，体检 D11 不做）；延时、美化 / 水印、比例条、Enter 全屏、焦点窗口截图、窗口置顶、屏幕清洁、WebP；截图历史与钉图历史（复制的截图进剪贴板历史，作为唯一的历史；要再钉出来，剪贴板里的图片 ⌘K / 右键 / ⌘Y「钉到屏幕」，2026-09-28 体检 D1）。
- 热键：启动器 ⌥Space、截图 ⌥A（用户实际用的键）；编辑器工具键不带修饰的 1–4、钉图 T（沿用用户改键），不做编辑器内改键。⌥Space 只在 15.0–15.1 上注册失败，录制器已提示。

**启动器网址线（M11，2026-09-25）**
- 网页搜索和快捷链接是**同一张列表**（`SearchEngine`）：网址里有 `{query}` 的是搜索（「关键词 空格 内容」直达，勾「兜底」的按列表顺序兜底），没有的是快捷链接；cb、fy、open、find 和 quit / hide / forcequit / eject / kill 是保留关键词（`WebSearch.reservedKeywords`）。预置 13 个，新装只有第 1 个（Google）兜底（体检 A24）；兜底默认只在没有本地结果时出现（`launcherFallbackAlways` 可改成总附在最后）。
- 键盘：↩ 计算结果粘贴回原 App（没有辅助功能授权时只复制并提示），cb ↩ 交给剪贴板面板搜；⌘↩ 在访达中显示 / 只复制；⌥↩ 访达搜索、⌃↩ 用第一个兜底搜索，按住修饰键时选中行的副标题换成替代动作；Tab 补全。↩ / ⌥↩ / ⌃↩ 先确认是回车键（别的键绑定也会发这几个选择器）。
- 「常用」（体检 A22 由「最近使用」改名）里 ⌘⌫ 忘掉一项、⌘Z 放回；收藏 ⌘D（体检 D13，`launcher_favorites`，最多 8 个，空查询先列收藏、再用常用补足到 8 行）；呼出时切英文输入法（`launcherRomanInput`）默认关。

**文件搜索（M13，2026-09-26）**
- `open 词` 打开、`find 词` 在访达中选中（⌘↩ 互换），空格开头 = open；普通搜索不混排文件（打开过的文件靠使用记录搜到）；不做 in（内容）/ tags、目录导航、自定义关键词、可编辑排除目录。
- 查询（`Launcher/FileSearch.swift`）：每个词一个 `kMDItemFSName == "词*"cdw`（拼音也能命中），范围只用主目录，路径在客户端滤（~/Library、node_modules、build 这类）；子串写法要几秒，所以 1 个拉丁字母不查。
- **授权（实测，用户选「按需申请」）**：Spotlight 按调用方的「文件和文件夹」授权过滤结果、也不弹框，所以文件结果最后一行是授权提示（↩ 逐个 `opendir` 让系统弹框）；问过之前一律不碰这些目录（`Prefs.folderAccessRequested`）。

**系统命令（D2，2026-09-27）**
- 关键词照抄 Alfred、默认全开，不做改关键词 / 逐个开关 / 排除名单；规格在 `mac-whisker-launcher.mdc`「系统命令」。带对象的 quit / hide / forcequit / eject 是「关键词 空格」模式（同文件搜索：列一次对象、打字只过滤、不记使用）。
- 执行在 `SystemControl`（面板先收起；单测、截图自检从不真执行）。要 apple-events entitlement + `NSAppleEventsUsageDescription`（强化运行时下没有它，发给别的 App 的 Apple Event 会被静默拒绝），被拒时刘海岛说明并打开 系统设置 › 自动化；其余命令不要新授权。
- 确认：清倒废纸篓、全部退出、强制退出第一下只上膛，同一行同一个键再按一次才执行。

**启动器新功能（体检第 6 批，2026-09-28，D6 D8 D9 D11 D12）**
- 读浏览器的库一律先克隆到临时目录再读、读完删（Chrome 开着时库被它锁着）；小查询在主线程，整表这类大读交给 `/usr/bin/sqlite3` 进程外（mac-native §3）。
- 网站图标（D6）只用本机浏览器里已有的图标，不联网；浏览历史（D8）默认关，排在本地结果后面、最多 5 行，不算本地结果；系统设置面板（D9）按 .appex 的 Info.plist 认，**还没在真机上逐个核对 45 个能跳到**（`HANDTEST.md`「体检第 6 批」第 3 条）；计算器加单位换算 / 进制（D11），汇率要联网、不做；kill（D12）↩ SIGTERM、⌘↩ SIGKILL（上膛），挡掉 loginwindow 和本 App。

**浏览器书签与历史（第 12 批，2026-09-29，用户「浏览器书签与历史缺少 Safari……还没安装」，拍板加 Safari + 只列装了的）**
- 浏览器表一处定义（`Launcher/Browsers.swift`），设置里只列装了的；偏好两个键 `launcherBrowserBookmarks` / `launcherBrowserHistory`，默认书签只开 Chrome、历史都关。
- Safari 受完全磁盘访问权限保护，又没有请求授权的 API：读失败按 `Browsers.failure` 分「需要授权 / 没有文件」，不弹框、不缓存，设置里给「去授权…」。Safari、Firefox 的库是 WAL，克隆要连 -wal。Arc 侧栏里的书签、Safari / Firefox 的图标库不读（ponytail）。

**翻译服务 logo（第 13 批，2026-09-30，用户 2026-09-29「期望内置一些常用的 logo icon……我的 DeepSeek，OpenCode」，拍板「内置常见厂商 + 自动取官网图标」）**
- 不用 logo.dev 或任何第三方图标聚合站（要注册拿 token，运行时取图还会把用户用了哪些服务透露出去）；内置图只取各家官网 / 官方站点自己声明的图标（来源表在归档）。厂商按可注册域名认（`AIVendor`，关思考分档也读它），认不出的取官网图标存在本地，都没有就是品牌色块首字母。

**录屏与录音（2026-09-30 立项，用户「需要开始实现录屏和录音功能……风格要保持和我们系统风格一致」）**
- 拍板：方案页 https://claude.ai/artifact/5zCumGF6N4SwNMBBgwyn3k 的 27 项（R1–R12 录屏、A1–A6 录音、C1–C9 共用）+ 13 条默认细节，用户「全部按推荐」；原文和调研出处在归档。
- 定下的要点：录制管线用系统的 `SCRecordingOutput`（不能暂停、不能调码率，录制中改配置会停录；ponytail，升级路径是自己用 AVAssetWriter 写）；录屏复用截图框选；**本 App 的窗口**：过滤器排除整个本 App，再把剪贴板面板、启动器、翻译浮窗、设置窗、钉图这几类窗口列进例外，刘海岛、飞行卡片、常驻缩略图、遮罩、录制边框 / HUD / 停止项永远不进；系统声音默认开、麦克风默认关、混成一条音轨；mp4 + H.264（第二轮体检起可选 HEVC），超过编码上限的等比缩；录音先麦克风（`AVAudioRecorder`，m4a，能暂停），系统声音复用录屏管线、导出 m4a；新增授权只有麦克风；中断统一收尾、保住已录的部分（C6）；录制不占截图的忙碌标记，录屏和录音互斥。
- **第 0 批实测结论**（2026-09-30，`RecordingProbeTests`）：样本输出要挂（录什么挂什么空输出，不挂时系统日志每帧刷一条）；委托和样本回调在后台线程（→ nonisolated，mac-native §3）；色彩设 sRGB 最准；H.264 硬件编码卡的是边长 4096；大屏 60 fps 不保证满帧；闪退时 replayd 会把文件收好（C7 闪退恢复照做）；录制中截图照常；安静房间电平约 −41 dB（「没听到声音」的门槛要远低于底噪）。12 条原文和数字在归档。
- 分批：0 实测探针 → 1 录屏最小闭环 → 2 录制条、倒数、HUD → 3 飞入和视频卡 → 4 声音和点按 → 5 独立录音 → 6 录音加系统声音 → 7 转成 GIF、0.3.0 更新日志，**全部代码完成，待真机手测**（`HANDTEST.md`「录屏 / 录音手测」1–52）。各批实现要点在归档；现行约束在 mac-overlay-panel §8–§10，界面在 `mac-whisker-capture.mdc`。
- **手测反馈**（2026-10-01，0.3.0 发布前，用户三条，分三批，都代码完成待手测，同一节 53–67）：1 点按圈自己画（`Screenshot/InputOverlay.swift`，不用系统的 `showMouseClicks`）；2 录屏显示按键（录制条第四个开关，同一个 `InputOverlay`，全局键盘监听要辅助功能授权）；3 录音快捷键先出控制条（待录态，设置 › 截图「按快捷键后立即开始录音」默认关）。不改版本号，更新日志只改 0.3.0 那一条。

**剪贴板手测反馈（2026-10-01，0.3.0 发布前）**
- 行标题已原样显示全的短文本，透镜不再画第二遍（`ClipRowView.showsWholeText`，纯函数、只看条目自己的数据：透镜高度在两处各算一遍，读当前时间、修饰键、系统设置就会对不上）；⌘Y 大卡的图片居中，屏幕放不下时窗口按图片比例缩（`QuickLookView.idealSize`）。不改版本号，更新日志 0.3.0 加了两条；代码完成待手测（`HANDTEST.md`「剪贴板手测反馈」1–8）。业界做法的调研、布局实测和已知上限在归档。

**截图（体检第 7 批，2026-09-28，A28 B40–B43 B45–B47 C9 D17 D18）**
- 「另存为」不改 ⌘S 快速保存的目录（A28，§11 #96）；长截图时和选区相交的钉图变淡让开、常驻缩略图收走（B40）；截图家族叫法统一「拷贝（↩）/ 存储到「桌面」（⌘S，访达显示名）/ 另存为…（⇧⌘S）」（B41）；长截图状态行分正常 / 警告 / 对不上（B42）；选区太矮不进长截图（B43）；钉图的按键同截图出图、能识字和翻译（C9 D17）；多屏冻结帧同时截（B47）；常驻缩略图可关（D18）。

**翻译补强（M12，2026-09-25）**
- 浮窗快捷键在 `TranslateCoordinator.handleKeyEquivalent`：⌘R 重新翻译、⌘D 收藏（体检 A31 前是 ⌘S）、⌘W、⌘P、⌘+ / ⌘- / ⌘0 字号、⌘1–9 复制第 N 张卡；收藏 = 生词本，能导出 CSV / Anki TSV；替换原文：**前台已不是取词的 App、或自家浮层成了 key 时只复制不粘**；浮窗高度随内容、只让拖宽度，卡片折叠按服务存。

**长截图（2026-09-25）**
- 截图框选后按 S 进入（选区至少 60 点高）；遮罩收起、在实时画面上截（过滤器滤掉本 App）。拼接只用逐行哈希投票（`ScrollStitcher`，单测锁住），**不用 Vision 配准**（有吸顶栏时 50%–90% 算错、置信度却恒为 1）；页脚宁大勿小。自动滚动要辅助功能授权，先把光标挪进选区，移出选区即停。

**截图（Phase 3）**
- 屏幕录制权限（TCC）：用 `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 检查和申请，同样绑定签名。授权提示由系统提供，App 不能自定义文案（没有对应的 Info.plist 键）。macOS 15 会周期性地再次询问屏幕录制授权。
- 保留冻结底图的铁律：按下热键后先截整屏（ScreenCaptureKit `SCScreenshotManager`，macOS 14+），框选、取色、裁剪都只读这一帧；禁止改回「框选之后再截屏」。
- 遮罩窗口：每块屏幕一个无边框窗口，层级要高于菜单栏；注意 AppKit（原点在左下）和 CG（原点在左上）的坐标换算，以及多屏拼接。全屏透明窗口的 backing store 是内存大头，不要让它常驻。
- 热键：截图 ⌥A、截取上次区域 ⌥X（iShot 的默认键，可连按）、截图翻译 ⌥S（都是只带 ⌥ 的组合，15.0–15.1 注册不了时快捷键页会提示）。
- 截图翻译（2026-09-24 提前到 Phase 1：只用 Vision、原文写剪贴板历史、默认 ⌥S）、截图（M9）、标注与识字（M10）、钉图都已实现，实现要点在归档。
- **截图重设计（2026-09-26）**：方案页 https://claude.ai/artifact/WQFQonH4urad3hmnceBiko 的 D1–D15 全部按推荐，控件换品牌粉（`Style.Shot.accent`）；M9 / M10 里的「8 手柄」「1–4 四种工具」「6 色」已被取代。规格只看 `mac-whisker-capture.mdc`「截图」，实现约束在 mac-overlay-panel §8–§10。

**第二轮体检（2026-10-02）**
- 背景：0.3.0 打包后的第二轮体检，拍板页 https://claude.ai/artifact/YVtyGn4aKb61AFNHjpbFp8 ，20 项全部按推荐，8 批串行、每批一个提交；改动进 0.3.1（0.3.0 等手测后单独发，不往里加）。手测见 `HANDTEST.md`「第二轮体检手测」。
- 第 1 / 1b / 1c 批 翻译卡片省电：循环动效的渐变只画一次、只动变换（规矩在 mac-whisker §8）；可选中的文字系统不调 `TextRenderer`，显示不出来的「显影」按用户定的 A 拿掉、只留光标（以后要恢复得单独立项、先出原型，前提见 mac-whisker §5 S3）。两张等待卡约 30% → 6%，出字中约 40% → 17%。
- 第 2 批 内存探针（`MemoryProbeTests`，按需）的结论：M1 缩略图缓存要设上限（画过之后每张在缓存里留 2 份「宽 × 高 × 4」）；图标缓存不用管；M3 只有两张 ⌘Y 大卡值得收起后放掉（三块主面板、设置窗都不到 10 MB，不动）；M4 回收接口只在丢完大图之后调，截图 / 转 GIF 之后不用调。
- 第 3 批：行图标缓存按张数封顶 300、透镜 + 大卡按 cost 封顶 48 MB；两张 ⌘Y 大卡用时再建、收起 2 秒后放掉（`Shell/TransientPanel.swift`），剪贴板大卡放掉后调一次 `Shell/Memory.swift`。12 张整屏截图三档都画过：389–392 MB → 43–46 MB。
- 第 4 批：剪贴板的后台识字放到子进程（本 App 带 `--ocr` 再起一次，不成退回进程内）；⌥O 识字、截图翻译、钉图识字仍在进程内（已知取舍）。
- 第 5 批 录屏：清晰度（原始 / 标准）和编码（H.264 / HEVC），默认不变——系统录制输出没有码率开关；录完「压缩」另存一份；显示按键可只显示快捷键；转 GIF / 压缩的进度带百分比；识字慢时先出「识别中…」。不做：录音待录时的电平预览（要在开录前开麦克风）。
- 第 6 批 数据保险：每天备份、留 3 份，只备用户留下的（收藏 / 片段 / 收藏夹里的条目、收藏夹、生词本、启动器收藏）；打不开时可选用备份 / 重新开始 / 退出，出问题的库连 -wal、-shm 挪进 `damaged-…/`，不删、不循环。不做：图片备份、`damaged-…/` 自动清理。规矩在 mac-clipboard §1。
- 第 7 批 一键钉住剪贴板里的图（F1，`HotKeyAction.pinClipboard`，默认不设键）：只读剪贴板、不记历史，连按从中央往右下错开。不做：文字 / 色值贴成图、恢复关掉的钉图、钉图分组、鼠标穿透。
- 第 8 批（2026-10-03）文档瘦身：PLAN 只留仍有效的部分（其余原样归档到 `docs/archive/`），手测挪到 `HANDTEST.md` 并在最前面加发版冒烟清单，mac-whisker 按界面拆成核心 + 5 个文件，提交说明的标题只写一行。

---

## 11½. Whisker 设计语言改造（2026-09-25 起）

已归档到 `docs/archive/PLAN-12.md` §11½（A–E 各阶段的内容、状态和 2026-09-26 的交接）。现状：A 基础与招牌时刻、B 界面重做、C 品牌、E 截图重设计都已完成（待手测）；D 深度只剩「macOS 26 玻璃 + `.icon`」——玻璃分支第 11 批已写好，等 26 测试机按 `HANDTEST.md`「macOS 26 手测」实测，`.icon` 也等 26。规范正文在 `.cursor/rules/mac-whisker.mdc`（核心）和各 `mac-whisker-<界面>.mdc`。

## 12. 进度与交接（2026-09-24，新会话从这里接着做）

> 2026-10-03 瘦身：原来的完成记录和整段的「下一步」「暂不发版」「发布」「接手须知」原样挪到 `docs/archive/PLAN-12.md`；**手测清单**（原「待用户手测」那一大段）原样挪到 `HANDTEST.md`，条目和编号不变——代码注释里的「PLAN §12 第 N 条」「§12「录屏 / 录音手测」N」「§12「macOS 26 手测」第 1 条」都去那里按小节名找。新的手测条目加在 `HANDTEST.md` 里。

**现状（2026-10-03）**：`MARKETING_VERSION` 是 0.3.1；已发布 0.1.0、0.2.0（tag `macos-v0.2.0`），0.3.0 的包已打好（`macos/build/`，2026-10-01）没发，0.3.1 没打包。
- 代码完成、待真机手测：录屏 / 录音 0–7 批和三批手测反馈（`HANDTEST.md`「录屏 / 录音手测」1–67）、剪贴板手测反馈（「剪贴板手测反馈」1–8），这些是 0.3.0；第二轮体检 1–7 批（「第二轮体检手测」1–34，23–28 只在 Dev 版上演练），这些进 0.3.1；第 8 批只动文档。
- 更早代码完成、还没手测完的（长截图、M13、2026-09-28 体检各批、第 9–13 批）在 `HANDTEST.md` 各自的小节；系统设置面板还要逐个核对能跳到（「体检第 6 批」第 3 条）。
- 等 macOS 26 测试机：液态玻璃分支（第 11 批，15 上逐像素不变）按「macOS 26 手测」实测、微调、再补更新日志；D5 系统翻译的验证（§10）。

**下一步**：按 `HANDTEST.md` 最前面的「发版冒烟清单」和上面这几节真机走一遍，修完发现的问题、经用户确认后跑 `macos/build-dmg.sh` 打包发布（原计划 0.3.0 单独发、0.3.1 随后，怎么发由用户定）。之后的新功能先按对标规则给用户「差距 + 推荐范围」，拍板后再分批做。

**发布**：`macos/build-dmg.sh` 出 arm64 DMG 和 `_arm64.zip` → 本仓库 github.com/YyAdnBug/kitty-tools 发**正式 release、标 latest**（App 内更新读 `releases/latest`），两个文件都附上，tag `macos-v<版本>` 打在 `main`；**发布前须经用户确认**。细节见 §8.5、`build-dmg.sh` 头部注释和 AGENTS.md「开发约定」。

**接手须知**：先读 `AGENTS.md`、`.cursor/rules/mac-native.mdc`，改哪块读哪块的技能（mac-overlay-panel / mac-clipboard / mac-translate；界面先读 mac-whisker 核心，再读那个界面的 `mac-whisker-<界面>.mdc`）。界面改动用 SnapshotProbeTests 屏幕外渲染自检，**不要**为截图弹出浮层（会抢用户键盘）；按需开关（默认都不跑；用法在 AGENTS.md「常用命令」和各测试文件头）：联网冒烟 `TEST_RUNNER_KITTY_LIVE_TRANSLATE=1`、链接预览 `TEST_RUNNER_KITTY_LIVE_LINK=1`、文件搜索 `TEST_RUNNER_KITTY_LIVE_FILES=1`、菜单开着时热键 `TEST_RUNNER_KITTY_LIVE_HOTKEY=1`、应用内更新整条链路 `TEST_RUNNER_KITTY_UPDATE_ZIP=<zip 路径>`、截图自检 `TEST_RUNNER_KITTY_SNAPSHOT_DIR=<目录>`、录屏 / 录音实录 `TEST_RUNNER_KITTY_LIVE_RECORD_DIR=<目录>`、内存探针 `TEST_RUNNER_KITTY_MEMORY_PROBE_DIR=<目录>`。用户要求：只兼容 macOS、不照搬 Tauri 实现、样式与交互可按 macOS 习惯重新设计、照搬行为前先核对旧逻辑有没有 bug（记入 §11）。

## 11. 实现原则与旧逻辑问题

**对标成熟产品（用户要求，2026-09-24）**：功能与交互对标 Alfred（启动器）、Bob（翻译）、iShot Pro（截图）等成熟 App，不对标自家 Tauri 旧版；旧版只提供用户真实使用数据（排优先级）、旧数据导入和旧 bug 核对。

**实现原则（用户要求，2026-09-24）**：只需兼容 macOS，**不照搬 Tauri 实现**。§5 的 Tauri path:line 只当「用户可见行为清单」；算法、数据结构、表结构、时序 hack 全部按原生方式重新设计。§6 的旧库只在 M6 导入时做一次格式转换，不约束新表结构。

**界面与交互（用户要求，2026-09-24）**：样式和交互逻辑都不沿用旧版，按 macOS 习惯重新设计。§5.1 里「点击语义」「键盘」「删除确认」「粘贴开关」等行以 `mac-clipboard` 技能 §4 为准：单击选中、双击或 ↩ 粘贴、⌥↩ 纯文本、⌘↩ 仅复制、⌘1–9 直接粘贴、删除不确认可撤销（⌘Z）、Esc 逐级退出；`clipboardPasteOnEnter` 设置取消。

**翻译语言（用户反馈「自动 - 自动」「英文 - 日语」混乱后重做，2026-09-24）**：参照 Bob / Easydict / Pot / DeepL / Google 的调研，M4 的「母语 / 常用外语 + 智能」模型改为：
- 浮窗顶部：源 =「自动检测」或固定语言；目标 =「自动（第一语言 ⇄ 第二语言）」或固定语言。在浮窗里改、全局记住（用户选定）；设置页只剩第一 / 第二语言，二者不能同属一种语言（选成同一种就互换）。
- 目标自动：原文是第一语言译成第二语言，否则译成第一语言。源自动时发给服务的源语言为空，让服务自己识别；本地检测只用来定目标和显示。
- 源自动、固定目标正好是原文语言：改按「自动」译，并在方向标签写「（原文已是 X）」（用户选定，Pot / DeepL / Raycast 的做法）。固定源与检测不符：照所选发出，标签提示「· 检测到 X」。两侧选成同一种固定语言：自动互换，不会出现「英 → 英」。
- 交换按钮原样互换（「自动」也照换，Bob 的做法），两侧都自动时禁用；不再把检测结果写成固定语言（旧做法会让之后的日文被当成中文发出）。
- 检测：`NLLanguageRecognizer` 加第一 / 第二语言先验、不设置信度门槛（实测不加先验时「你好」判成繁体、「API」判成意大利语，单字「猫」检测不出导致中译中）；中日韩文夹英文词时只看 CJK 部分（「请帮我 review 一下这个 PR」原先判成英语）；只有纯数字 / 符号返回 nil。方向标签只读本次会话的值（不看浮窗上此刻的选择）；一次交换只重译一次。

**旧逻辑问题**（核对行为时发现，原生版已按正确方式实现；Tauri 版是否修由用户决定）：

| # | 位置（Tauri） | 问题 | 原生版做法 |
|---|---|---|---|
| 1 | `src-tauri/src/clipboard/filter.rs` `looks_like_sensitive_text` | `sk-` 后要求紧跟 20 个字母数字，`sk-proj-…`、`sk-ant-api03-…` 等现行密钥格式全部漏拦 | 允许 `-` `_`；另要求 prefix 前是词边界、token 含数字，防连字符英文误伤 |
| 2 | 同上 | `bearer ` 之后量的是**整段剩余文字**长度，任何提到 bearer token 的长文本都被当成密钥、整段不进历史 | 只量紧跟的 token（`[A-Za-z0-9-_.~+/=]`），≥24 且含数字 |
| 3 | `src/features/clipboard/lib/clipboard-snippet.ts` | 片段 `{cursor}` 只是被删掉，光标不会定位过去（功能缺失） | 原生版暂保持同样行为并在代码里标 `ponytail:`；要做需在粘贴完成后按左方向键，时序难保证 |
| 4 | `src-tauri/src/translate/api.rs` 微软翻译（未填 key） | 依赖 `edge.microsoft.com/translate/auth` 换 token，该地址 2026-08 起返回 404，**旧版微软免费翻译已失效** | 改调免登录的 `edge.microsoft.com/translate/translatetext`（字符串数组请求体，返回结构与认知服务相同）；填了 key 仍走 Azure 认知服务 |
| 5 | `src-tauri/src/translate/api.rs` DeepL 语言码 | 源 / 目标共用一张映射：简繁都映射成 `ZH`（繁体丢失），目标 `EN` / `PT` 已被 DeepL 弃用 | 源用基础码，目标用 `ZH-HANS` / `ZH-HANT` / `EN-US` / `PT-BR`，配单测 |
| 6 | `src-tauri/src/translate/history_db.rs` `record_blocking`、`FloatingResult` 写历史处 | 翻译历史的 `target_lang` 记的是**设置值**（常为 `auto`；双向互译时也不是实际方向），去重键 `(source_text, target_lang)` 因此让同一原文在「自动」和固定语言下各存一条，应用历史时也还原不出实际目标语言 | 记实际译成的语言；M6 导入时以译文的语种检测为准还原（本机 500 条里 5 条因此合并） |
| 7 | `src-tauri/src/translate/api.rs:175-191,707-708`、`translate/pipeline.rs:300-310` | 百度图片翻译把目标语言 `auto` 原样发出，译文与原文相同（旧库 24 条 auto→auto 的百度截图记录全是原文） | 不接百度图片翻译，截图原文交给各服务按统一的语言规则翻译 |
| 8 | `src-tauri/src/ocr.rs:304-329` | Google Vision 响应按 `text_annotations` 解析，实际字段是 `textAnnotations`，结果永远为空，这条路径从没工作过 | 不接云端 OCR |
| 9 | `src-tauri/src/translate/api.rs:1679-1691,1726-1732` | 智谱识图把「没有可见文字」之类说明句当原文发给各服务翻译，之后才判失败 | Vision 识别为空时只提示「没有识别到文字」，不开翻译 |
| 10 | `FloatingResult/index.tsx:779-788,632-647` | 识图失败只清掉截图服务那张卡，其余卡一直「翻译中」、翻译按钮被锁 | 识别完成后才开翻译会话 |
| 11 | `FloatingResult/index.tsx:916-923` | 识图失败后点「重试」拿到空原文，没反应 | 同上 |
| 12 | `FloatingResult/index.tsx:278-288,550-558` | 截图时写历史取截图服务、自动复制取列表第一个，可能不是同一个服务 | 都只认列表第一个服务（`finished()`） |
| 13 | `translate/pipeline.rs:300-310` 对比 `FloatingResult:722` | 百度用按热键时的语言设置，其它卡用浮窗当前设置 | 一个会话只在 `start()` 读一次语言 |
| 14 | `screenshot/desktop_capture/platform_capture.rs:106-128`、`frozen.rs:493-501` | 混合缩放多屏时只截鼠标所在屏、拉伸铺满整块桌面，框的和截的不是同一处 | 每块屏幕单独截、按各自像素尺寸换算 |
| 15 | `screenshot_macos_permission.rs:36-47`、`RegionSelectApp/index.tsx:532-548` | 缺权限的报错发给停在屏外的遮罩，用户看不见；系统设置被打开两次、和系统授权框同时弹 | 只弹一次系统框，同时打开一次系统设置的「屏幕录制」（同设置 › 通用、引导的授权按钮），刘海岛说原因（2026-09-27 前是翻译浮窗提示 + 按钮） |
| 16 | `screenshot/pipeline.rs:576-582` | 翻译模式下单击截窗仍会激活目标 App 并同步等 120ms | 不做单击截窗 |
| 17 | `RegionSelect/index.tsx:912-938`、`screenshot/commands.rs:290-298` | 翻译模式下仍响应 P 钉图（直接结束会话）、H 截图历史、C 取色 | 不做 |
| 18 | `RegionSelect/index.tsx:569-584,725-747` | 延时倒计时期间遮罩仍拦着键鼠，达不到「摆好界面」的目的 | 不做延时 |
| 19 | `window_hit_test.rs:221,276-288` | 窗口识别读的是实时窗口列表而不是冻结那一刻的；非主屏的程序坞 / 菜单栏条带坐标算错 | 不做窗口吸附 |
| 20 | `RegionSelect/index.tsx:898-910` | Enter 截全部屏幕后缩到 2560，小字识别不出 | 不做 Enter 全屏 |
| 21 | `clipboard/ocr_local.rs:14`（原生 M2 照搬到 `Clipboard/OCR.swift`） | Vision 语言写死简中 / 繁中 / 英文：日文假名丢失、韩文为空、俄文变拉丁乱码 | 只开自动识别语种、不给提示（实测给第一 / 第二语言作提示时，中日韩混排图里日文、韩文整行丢失），配单测 |
| 22 | `translate/api.rs:1640` | 智谱识图 max_tokens 1024 且不看 finish_reason，长截图被静默截断 | 不接智谱识图 |
| 23 | `src/features/settings/lib/translate-provider-settings.tsx:127,197-201` | 设置说明与实际不符（「由划词默认引擎翻译」「百度 OCR 兜底」） | 这些设置项不迁 |
| 24 | `launcher/mod.rs:1059-1065` | 锁屏调用的 CGSession 在 15.7 上已不存在，命令必失败 | 锁屏改用私有 `SACLockScreenImmediate`，找不到退回 ⌃⌘Q（D2，2026-09-27） |
| 25 | `system_apps.rs:468-540` + `installed_apps.rs:529-535` | 9 个系统 App 各出现两行，使用次数也被拆开 | 只有一个 App 目录，不写死系统 App（M7） |
| 26 | `installed_apps.rs:602-619` | 标题用文件名，中文名和拼音搜不到（本机 7/50 个 App 显示名与文件名不同） | 索引显示名、文件名、zh loctable / strings 里的中文名及其拼音（M7） |
| 27 | `mod.rs:634-648,1283-1312` | `~` 不展开，`./` 按 GUI 进程目录解析 | 展开 `~`，不认相对路径（M8） |
| 28 | `files.rs:901-913` | find 回车打开父目录、文件没被选中 | `activateFileViewerSelecting`（M13） |
| 29 | `recency.rs:143-153,247,356` | 另起线程非原子整份写 JSON，可能乱序覆盖；key 用 `::` 拼接有歧义 | SQLite 表，每个字段一列（M7） |
| 30 | `recency.rs:157-164`、`mod.rs:832-856` | 网址被转成小写再打开 | 存原始网址；导入时用书签还原大小写（M8） |
| 31 | `recency.rs:171-175` | 次数永不衰减；注释里的「半衰期」其实是时间常数 | 每用一次：衰减后的分 + 1（M7） |
| 32 | `mod.rs:1516-1541`、`kill.rs:795-805` | 搜索结果页、reveal_path、kill_port 也记进频率，挤占「最近使用」 | 只记能还原的类型；导入时丢掉搜索结果页（M7） |
| 33 | `mod.rs:1394-1399` | 先隐藏再执行，失败提示显示在看不见的窗口里 | 先执行，成功才收起；失败在面板里显示（M7）。例外（2026-09-27 用户要求）：打开 App / 文件 / 网址 / 搜索页 ↩ 当下就收起、系统在后台打开（同步的 `NSWorkspace.open` 要等 App 启动完才返回，面板一直挂着），打开成功才记使用，打不开用刘海岛说 |
| 34 | `windows/mod.rs:1249-1287` | 启动器总在上次那块屏幕上弹出 | 鼠标所在屏（M7） |
| 35 | `launcherCommandToken.ts:158-167` | 刚打全的指令词要按两次 ↩ | 不做 chip，↩ 直接执行首项（M8） |
| 36 | `mod.rs:1339-1346` | `Safari.app` 被当成网址，`localhost:3000` 反而不认 | 去掉 .app 后缀判断，识别 localhost[:端口]（M8） |
| 37 | `launcherCalculator.ts:32-47` | `2024-01-01` 被算成 2022 并置顶，还吞掉网页搜索 | 日期形式不算式；计算结果不压掉网页搜索（M8） |
| 38 | `launcherFilePrefix.ts:12-29` | 「find my」被文件搜索截走 | 指令模式的列表末尾仍附整句的 App 匹配（M13） |
| 39 | `kill.rs:1678-1696` | 普通结束 400ms 后自动升级 SIGKILL | GUI App 用 `terminate()`，其它进程只发 SIGTERM；⌘↩ 才强杀（M13） |
| 40 | `bookmarks.rs:139-147` | 30 秒缓存期内不看开关变化 | 按文件修改时间和开关失效（M8） |
| 41 | `useWindowHitTest.ts:41-50`、`window_hit_test.rs:221` | 窗口候选按面积排而不是 Z 序，会选中被遮挡的小窗；读的是实时窗口列表 | 冻结时拍窗口快照，按 Z 序命中（M9） |
| 42 | `capture.rs:119-122` | 长边硬压到 4096px，5K / 6K 屏截图变糊 | 保持原生像素（M9） |
| 43 | `RegionSelectApp:870-915`、`history_db.rs:274` | 调整选区会静默清空全部标注 | 标注存整屏坐标，导出时才裁剪（M10 已做） |
| 44 | `ScreenshotEditor:797`、`commands.rs:533-558` | 识字把未打码的原图上传智谱 | 本机 Vision，识别打码后的合成图（M10 已做，单测锁住） |
| 45 | `export.rs:115-137` | JPEG 透明区域变黑；WebP 无视质量设置 | 首版只出 PNG（M9） |
| 46 | `export.rs:245-252,349-362` | 同一秒快速保存两次，前一张被覆盖 | 重名追加序号（M9） |
| 47 | `excalidraw-layer.tsx:104-108,455-489`、`ScreenshotEditor:1186-1189` | 高亮颜色选择不生效；所有工具共用线宽；改样式不作用于选中的标注 | 样式改动作用于选中的标注（M10 已做） |
| 48 | `pin_click_through.rs:24-33`、`windows/mod.rs:4457-4461` | 钉图穿透时全局抢走 ⇧⌘P；钉图显示时抢焦点 | 不做穿透；钉图窗口不激活 App（M9） |
| 49 | `history_db.rs:234-313`、`pin_history_db.rs:206-230` | 缩略图泄漏（本机 351 个孤儿、目录 43MB）；淘汰时删掉仍开着的钉图的 PNG | 不做这两个历史 |
| 50 | `focused_window.rs:120-144` | 窗口置顶在 macOS 上是空实现，却提示「已切换」 | 不迁 |
| 51 | `files.rs`（find / open） | 文件搜索起 `mdfind` 子进程用子串 `*词*`，短词要几秒、靠看门狗强杀；每条结果 stat 判断是不是目录，碰到受保护文件夹会弹授权框 | 进程内 `NSMetadataQuery` + 词首谓词，只读 Spotlight 属性、图标按类型取（M13） |
| 52 | `file_search_filter.rs` | 排除目录默认值靠 serde default，老用户收不到新增的默认项（本机缺 8 项） | 排除规则写死在代码里，想再排除用系统 Spotlight 隐私（M13） |
| 53 | `FloatingResult/index.tsx:859-873`（PLAN 附录评审 #34 照搬） | 翻译浮窗固定时 Esc 不关，剪贴板固定时 Esc 照样关，两个图钉语义不同 | 固定只管点别处 / 失焦不收起，Esc、⌘W、再按热键一律收起；剪贴板和启动器也认 ⌘W，剪贴板 ⌘P 切换固定（2026-09-28 体检 A9） |
| 54 | `SettingsClipboardTab/index.tsx:60-68` | 「失焦时自动关闭」开关和浮层图钉是同一个值，两个入口 | 删掉设置页那一行，只留底栏图钉 / ⌘P，偏好键保留（体检 A9） |
| 55 | `config.rs:315-317` | 输入翻译默认 ⌘⇧I，别的默认键都是单 ⌥；⌘⇧ 组合常被各 App 占用 | 默认 ⌥T，只影响没改过的人（体检 A15） |
| 56 | `app_update.rs:177-227`、`WhatsNewDialog` | 更新后第一次启动自动弹设置窗（切 .regular、抢前台，开机由登录项拉起时也弹） | 刘海岛「已更新到 x」+ 摘要，不开窗（体检 A29） |
| 57 | `clipboard/suppress.rs`、`paste.rs:33-41` | 自家写剪贴板一律抑制，复制的译文、计算结果在剪贴板历史里找不到 | 本 App 生成的新文字经 `Paster.write(string:record: true)` 记进历史，历史里取出的、划词还原、面板里的色值块不记（体检 A30，mac-native §5） |
| 58 | `tray.rs:522`、`SettingsGeneralTab/index.tsx:46` | 托盘「退出」、页头「开机自启」 | 「退出 Kitty Tools」、「登录时打开」（同系统设置的叫法，体检 B50 / B51） |
| 59 | `useClipboard.ts` favorited + snippet + groupId、`ClipboardGroupManageDialog`、`clipboard-groups-db.ts:13,33` | 收藏 / 片段 / 分组三套保留并存；删分组只解除归属，组里的旧条目随后被天数上限静默删光；管理分组铅笔 + 垃圾桶 + 兼用输入框、按创建时间排、名字悄悄截到 24 字 | 分组并进收藏（命名收藏夹，归进去就是收藏），删收藏夹条目留在收藏、可 ⌘Z；键盘列表管理、拖动排序存 `position`；超过 24 字拦住不截断；取消收藏后超期的先提示、收起面板才清（体检 A1） |
| 60 | `clipboard-delete.tsx:10` | 撤销删除只有 5 秒、只能撤一层；中途弹别的提示后 ⌘Z 又一直有效；退出时不提交；待删期间再复制会多出一条 | 撤销栈，⌘Z 连撤，面板收起 / 退出时才提交；再复制同内容拿回原条目（体检 A2） |
| 61 | `useClipboard.ts:784-791,1011-1014`、`clipboard-item-note.ts` | 备注只给收藏 / 片段，取消收藏清备注；对话框说「Enter 保存，Shift+Enter 换行」 | 所有条目能写，取消收藏不清，单行 ↩ 保存（体检 A3） |
| 62 | `SettingsClipboardTab`、`clipboard-history-settings.ts`、`config.rs:828-839` | 条数 / 天数 / MB 三个旋钮；「保留文本格式」关掉就不再采集格式 | 只留「保留普通历史」时间档位 + 图片兜底；格式总是采集，改「默认粘贴为纯文本」（体检 A4 A5） |
| 63 | `clipboard-keyword-search.ts:8,105-121` | 按字段权重排序、有搜索词改平铺（分组 ↔ 平铺整批换行身份是透镜错位 bug 的根源） | 只过滤、始终按天分组（体检 A6） |
| 64 | `clipboard-snippet.ts` | 占位符只有 date / clipboard / cursor；多选合并粘贴时原生版没展开占位符（回归） | 加 time / datetime / weekday / uuid / clipboard:N；合并时展开（体检 A7 B1） |
| 65 | `useClipboard.ts:692` | ⌘C 不置顶，下次打开第一条和剪贴板对不上 | 面板开着不动，收起时置顶（体检 A8） |
| 66 | `filter.rs:7-22`、`config.rs:671-679`、`privacy_markers.rs`、`source.rs:23-66` | 排除 App 关键词子串匹配（「Code」连 Xcode 一起排除）；隐私标记只有 3 种；敏感文本只认 sk- / bearer / 卡号；来源靠轮询时的前台 App 猜 | bundle ID 精确匹配 + App 列表（旧列表迁一次）；补 5 种标记、7 种密钥格式；先读来源标记、通用剪贴板记「其他设备」（体检 A11 B4 B5 B6） |
| 67 | `image_budget.rs`、`paste.rs:209-211` | 图片预算把收藏图片也算进去，新截图一进来就被删；多选文件 ⌘C 只写第一个、粘贴逐个等 250 ms、依次粘贴顺序反、文本间没换行 | 只算普通图片、保住最新一张；全是文件一次写、一次 ⌘V，其余按复制先后、文本间补换行（体检 B2 B3） |
| 68 | `clipboard-preview-actions.ts:27`（套到了 JSON 美化上） | 「切换条目时重置」让压缩 JSON 每换一条都得再点一次「美化」 | 默认美化，一次呼出里看原文就一直原文，收起面板复位；美化结果按条目缓存（体检 A10） |
| 69 | `ClipboardItemCard/index.tsx:254-327`（原生照搬后又单写了一份 ⌘K） | 右键菜单和 ⌘K 各写一份：名字、条件对不上（带格式才有纯文本粘贴、当前分组置灰），右键缺复制为纯文本 / 打开链接 / 美化；右键「复制」复制的是全部勾选项 | 同一个 `actions(for:targets:)`，右键传被点的那条（体检 B9 B12） |
| 70 | `useClipboard.ts:589-591,605-608`（原生没带过来） | 原生按 id 选中：删除、收藏范围取消收藏、移出收藏夹后跳回第一条，连按 ⌘⌫ 删错；勾选不随搜索裁剪，批量删到看不见的条目 | `changingList`：选中挪到下一条；勾选裁成看得见的，底栏计数和批量操作只对它们（体检 B7 B8） |
| 71 | `ClipboardItemEditDialog`、`ClipboardSnippetCreateDialog` | 编辑对话框空白 / 没改动也能保存、不分情况提示丢格式；新建片段没有名称 | 空白或没改动时保存置灰；只在带格式时提示；新建片段加可选名称（存成备注）（体检 C2） |
| 72 | `clipboard_monitor.rs:43-58`、PLAN §5.2 复制即译行 | 复制即译不挑内容：网址、路径、数字、自己写的中文都弹浮窗、每个服务请求一遍；超过 32 KB 弹一个只有「原文太长」的浮窗；「与上次翻译过的文本指纹相同不触发」原生漏了；自家浮窗里 ⌘C 半句译文也被当成新原文 | 静默跳过网址、路径、纯数字 / 符号、超长、目标自动时的第一语言、刚翻过的同一段（`worthTranslating`）；自家浮层里复制的来源记本 App、不触发（体检 A12 B20） |
| 73 | `config.rs:466-467` floating_window_x/y、PLAN §5.2 浮窗行 | 浮窗总在上次的位置（双屏时要转头找） | 设置「浮窗位置」跟随鼠标（默认，光标右下 12 pt、放不下翻边）/ 上次位置；输入翻译总在上次拖到的位置；只记用户拖过的位置（体检 A13） |
| 74 | `pipeline.rs:103-125` | 输入翻译每次清空原文和结果、再按热键不收起 | 热键是开关，再打开保留上次的、原文全选，中断的卡片重跑（体检 A14） |
| 75 | PLAN §5.2 划词行「选区为空时打开空白输入面板」 | 没取到选中文字时和平时的输入翻译一模一样，看不出是没取到 | 占位换成「没取到选中的文字，可以直接输入或粘贴」+ VoiceOver 播报（体检 A16） |
| 76 | `translate-services.ts:27-36` | 智谱第二档是识图用的 glm-4.6v-flash | 换成免费纯文本的 glm-4.7-flash，读到旧值回落 glm-4-flash（体检 A17） |
| 77 | `history_db.rs:19,22`、`config.rs` default 500 | 历史保留 100–2000 五档、默认 500，列表只显示最近 200 条 | 1000 / 5000 / 不限（默认 5000），列表每页 500 条、滚到底取下一页，查询按 (revision, 搜索词, 范围, 页数) 缓存（体检 A18 B22） |
| 78 | `FloatingResult:246-249` | 开了复制即译，划词、输入、截图翻译都不再自动复制（理由「免得自己触发自己」在原生已不成立） | 只有复制即译带来、没改过的原文不自动复制（体检 A19） |
| 79 | `text_preprocess.rs` strip_translate_newlines | 「合成一段」把中日文行间插空格、两段并成一段、「State-\nOf」接成「StateOf」；截图翻译按视觉行断开送去翻，一句被拆成几截 | 翻译和识字共用 `OCR.joiningLines` / `OCR.paragraphs`：按行框间距和句末短行切段，段内按中日文 / 其它接、连字符只在小写前去掉；截图翻译总是按段、段间空一行（体检 A32） |
| 80 | `validation.rs:5`、内置智谱 max_tokens 1024 | 输出到上限被截断时按完成处理：半截写历史、自动复制、能替换原文 | 认 finish_reason = length / stop_reason = max_tokens，卡片 `.truncated`：正文照常 + 一行说明，不写历史、不自动复制、不给收藏和替换（体检 B19） |
| 81 | PLAN §5.2 翻译设置 Tab「服务列表」 | 8 个内置服务常驻列表、只能关不能删；新建 AI 服务没有厂商预设（PLAN 写了「预设照搬」但没做） | 列表只放加进来的，「+」加回内置 / 新建 AI（9 家预设 + 自定义 / Azure），删内置不确认、密钥留着（体检 B21 D15） |
| 82 | `speak-text.ts` | 收起浮窗不停朗读；声线只按语言取默认 | 收起时停；按品质挑已下载的高音质声线（体检 B23） |
| 83 | `api.rs` 百度 / 有道错误 | 错误只给码或英文原文；错误卡不分配置 / 网络，「打开设置」只到列表页 | 错误码译成中文；配置类橙卡只给「打开设置」直达服务详情页，网络 / 服务类红卡给「重试」（体检 B24 C5） |
| 84 | `launcher/mod.rs:53-56,790-822` | 空查询叫「最近使用」，其实按频率 × 新近取前 8；顺序跟着使用变，⌘1–9 对的不固定 | 改名「常用」；上面加用户自己排的「收藏」（⌘D、⌥⌘↑↓、最多 8 个），⌘1–N 固定（体检 A22 D13） |
| 85 | `launcherCalculator.ts:169,187` | % 是取模，「200*15%」「100+10%」算不出来、落到网页搜索 | % 是百分号（a ± b% = a ×（1 ± b/100）），取模用 mod（体检 A23） |
| 86 | `launcherCalculator.ts:9` | 只认 ASCII：中文输入法的全角括号、× ÷、千分位、全角数字都不算算式 | 先归一（widthInsensitive、× ✕ ÷、去千分位逗号），算式那一栏照常显示原文（体检 B32） |
| 87 | `config.rs:712-728` | 新装默认 Google、Bing、百度三个都兜底，三行做同一件事 | 只让 Google 兜底，另两个只走关键词（体检 A24） |
| 88 | `installed_apps.rs:613` | App 副标题写「应用程序」，和右侧类型「应用」重复；同名两份分不清 | 标准目录里的留空，别处的写所在位置（体检 A25） |
| 89 | `launcher/mod.rs:927-976` | 内置动作只有旧版那 6 个，截取上次区域、划词翻译并替换、暂停记录剪贴板、复制即译、钉图、关于、检查更新都搜不到；菜单和启动器各写一份 switch | 按 `HotKeyAction.sections` 生成、和菜单栏同名同序，`AppDelegate.run(_:)` 共用（体检 A26） |
| 90 | `LauncherSearchBody/index.tsx:506-509` | 一收起就清空查询，点到外面要重打 | 没执行就收起的 60 秒内再呼出保留查询和选中项、全选（体检 A27） |
| 91 | `catalog.rs:59,108` | App 目录 5 分钟过期才重扫，刚装的 App 第一次呼出搜不到 | 呼出前比较应用程序目录的修改时间，变了先重扫；5 分钟兜底保留（体检 B31） |
| 92 | `launcherClipboardCommand.ts:21-40` | 单输 cb 独占列表，以 cb 开头的 App、书签被挤掉（原生另把大小写判断弄丢了） | 单输 cb 时 cb 那一行排第一、后面照常；不分大小写（体检 B33） |
| 93 | `launcherSupplements.ts:7-30,44-60` | 网址靠顶级域白名单，docs.rs/serde、bun.sh/docs 这类不认 | 裸域名仍用白名单，后面跟 / 或 :端口 时 2–13 个字母的后缀都认（体检 B34） |
| 94 | `launcherCalculator.ts:1-30` | 计算器只出十进制、不分组，没有单位换算和进制 | 单位换算（`Measurement`，中英文单位名）、进制、千分位分组，⌘K 复制原始数字 / 别的进制；汇率不做（体检 D11） |
| 95 | `launcher/favicon.rs:1-30` | 网址行的网站图标联网抓取第三方服务 | 不联网：只读本机 Chrome 的 Favicons 库 + 剪贴板链接预览取到的（体检 D6） |
| 96 | `screenshot/export.rs:229,320,349` | 「另存为」存完把目录记成快速保存目录，之后 ⌘S、常驻缩略图的存储、双击打开都改存到那里；设置里选过就回不到系统截屏位置 | 另存为不改快速保存目录（存储面板自己记住上次的文件夹，同 ⌘⇧5 / CleanShot），设置 › 截图「快速保存到」显示文件夹图标 + 名字、能恢复默认（体检 A28） |

## 附录：评审处理记录

已归档到 `docs/archive/PLAN-migration.md`（方案评审的 41 条处理记录，全部采纳）。

## 附录：用户决策记录（2026-09-24）

已归档到 `docs/archive/PLAN-migration.md`（签名、公证、架构、翻译服务这些迁移期的决定，以及 2026-09-28 体检各批、第 9–13 批拍板时的用户原话和范围）。仍有效的已写进规则：Apple Development 签名、Team `HTX9F4KG39`、长期不公证（mac-native §6）；只支持 Apple 芯片（mac-native §2）。
