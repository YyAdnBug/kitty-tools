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
| CoreText（`CTFontCreateWithName`、`CTFontGetBoundingRectsForGlyphs`、`CTFontGetAdvancesForGlyphs`） | 10.x | 便签正文里的任务方框：按 ☐ 量前进宽，让五种方框字一样宽（2026-10-13 第 5 批起，`Notes/NoteStyles.swift`；2026-10-18 起方框自己画，只用它占宽度） |
| Carbon HIToolbox `RegisterEventHotKey`；`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` | 10.0（26.2 SDK 中未废弃） | 全局热键；录制快捷键时显示键名 |
| ApplicationServices：`AXIsProcessTrustedWithOptions`、`AXUIElement`、`AXUIElementSetMessagingTimeout`、`AXObserver` | 10.x | 辅助功能授权、读取选中文本；程序坞预览（第九族，2026-10-22）听程序坞图标列表的选中变化、读别的 App 的 `kAXWindows`、还原 / 抬起 / 按关闭钮 |
| CoreGraphics `CGEvent` | 10.x | 模拟 ⌘V / ⌘C；长截图自动滚动发像素级滚轮事件（`CGWarpMouseCursorPosition` 先把光标挪进选区） |
| CoreGraphics `CGEvent.tapCreate`（会话层、会吞事件的事件拦截）、`CGShieldingWindowLevel`、`CGSessionCopyCurrentDictionary` | 10.4 | 状态屏（2026-10-10，§10「状态屏」）：拦住键盘鼠标和媒体键（只要辅助功能授权，实测）、全屏面板的层级、解锁通知没到时的兜底；事件拦截只许在 `StatusScreen/InputBlock.swift` |
| `NSPasteboard`（`changeCount`、`accessBehavior`） | 10.0 / 15.4 | 剪贴板采集、剪贴板隐私状态 |
| ImageIO + UniformTypeIdentifiers | 10.x / 11 | PNG 编码、读取尺寸、按需生成缩略图；录屏转 GIF（`CGImageDestination` 逐帧写 GIF，录屏录音第 7 批 `Screenshot/VideoExport.swift`）；状态屏的动画表情：读 HEICS（HEVC 图像序列，带透明通道）的每一帧和时长，转换脚本用它把动画 PNG 写成 HEICS（2026-10-10） |
| QuickLookThumbnailing `QLThumbnailGenerator` | 10.15 | 剪贴板检查器里文件的真实缩略图（PDF 首页、图片、视频帧） |
| QuickLookUI `QLPreviewView` | 10.6 | 剪贴板 ⌘Y 放大预览里的文件（嵌在自己的浮层里；不用 `QLPreviewPanel`，见 D3） |
| Vision `RecognizeTextRequest` | 15.0 | 剪贴板图片 OCR、截图翻译识字；空闲时放掉识字模型用它的私有 `VNSession.globalSession.releaseCachedResources`（2026-10-07 用户同意，接口不在就不放，mac-clipboard §1） |
| ScreenCaptureKit `SCShareableContent` + `SCScreenshotManager` | 14.0 | 截图翻译的冻结帧（逐屏截图）；长截图用 `SCStreamConfiguration.sourceRect`（12.3+）反复截选区 |
| NaturalLanguage `NLLanguageRecognizer` | 10.14 | 语种检测（替代 Lingua，能识别繁体） |
| ScreenCaptureKit `SCStream` + `SCRecordingOutput`；AVFoundation `AVAudioRecorder`、`AVCaptureDevice`（麦克风授权与设备）、`AVURLAsset` / `AVAssetImageGenerator` / `AVAssetExportSession` / `AVMutableComposition`；Synchronization `Mutex` | 15.0 | 录屏与录音（2026-09-30 立项，PLAN §10「录屏与录音」）：系统录制管线直接写文件、录音、闪退恢复读文件、最后一帧、音轨导出；录制委托的可变状态（`Mutex` 翻译服务已在用）。第 1 批起在用：`SCStream` + `SCRecordingOutput`（`Screenshot/ScreenRecorder.swift` 录屏）、`AVURLAsset`（启动时读上次闪退留下的文件 `isPlayable`）；第 3 批起 `AVAssetImageGenerator`（停止后取最后一帧，飞入和视频卡用）；第 4 批起 `AVCaptureDevice`（麦克风授权、默认输入的设备名 / 蓝牙、断开通知）；第 5 批起 `AVAudioRecorder`（`Screenshot/AudioRecorder.swift` 录音：m4a、暂停续写、`updateMeters` / `averagePower` 电平，主线程直接用、不挂委托）；第 6 批起 `AVMutableComposition` + `AVAssetExportSession`（录系统声音：录屏管线的 mp4 只取音轨无损导出成 m4a，`ScreenRecorder.extractAudio`）和 `CMSampleBuffer` 的格式描述 / 数据块（样本回调里读 Float32 声音样本算电平）；第 7 批 `AVAssetImageGenerator` 还用来逐帧取 GIF 的帧（`VideoExport`） |
| AVFoundation `AVSpeechSynthesizer` | 10.14 | 朗读 |
| Foundation `URLSession.bytes(for:)`、`AttributedString(markdown:)` | 12 | SSE 流式输出、行内 Markdown |
| CryptoKit：`Insecure.MD5`、`SHA256`、`AES.GCM` | 10.15 | 百度 / 有道签名、图片去重 hash；设置导出里加密翻译服务的密钥（2026-10-07，`Storage/SettingsArchive.swift`）；便签同步的内容哈希和冲突另存那条的编号（2026-10-22，`Notes/NoteSync.swift`） |
| Darwin `gethostuuid` | 10.5 | 便签同步认「这台 Mac」：电脑编号跟着库走，硬件编号对不上（库被搬到了另一台）就换新的（2026-10-22，`NoteStore.hostID`） |
| CommonCrypto `CCKeyDerivationPBKDF` | 10.7 | 设置导出：按用户设的密码算加密密钥（PBKDF2-HMAC-SHA256；CryptoKit 没有按密码算密钥的函数） |
| Security `SecItem*` | — | API Key 存钥匙串 |
| Foundation `URLSession.download`、`Process`（调系统的 `/usr/bin/ditto`、`/usr/bin/codesign`、`/bin/chmod`；启动器 kill / port 列进程的 `/bin/ps`、`/usr/sbin/lsof`；浏览历史 / Firefox 书签的 `/usr/bin/sqlite3 -readonly -json -init /dev/null`；共用 `Shell/Subprocess.swift`，要的输出写临时文件） | — | 应用内更新：下载更新包、解包、验签（D8）；kill 列后台进程和监听端口（体检 D12）、port 列在监听的端口和进程的工作目录（2026-10-08）；导出各家浏览器的浏览历史和 Firefox 书签（体检 D8、第 12 批） |
| 启动台触控板捏合（第八族，2026-10-18）：运行时 `dlopen` / `dlsym` 系统私有 `MultitouchSupport.framework`（不链接、不写进工程设置；找不到符号 / 设备就退回，别的入口照常），只用 `MTDeviceCreateList` / `MTRegisterContactFrameCallback` / `MTDeviceStart` / `MTDeviceStop`；**不是依赖**，跑起来才加载 | 10.x | 触控板捏合打开 / 收起启动台 |
| 程序坞预览（第九族，2026-10-22，§10「程序坞预览」）：运行时 `dlopen` / `dlsym` 系统私有 `SkyLight.framework` 的 `_SLPSSetFrontProcessWithOptions` / `SLPSPostEventRecordTo`、CoreGraphics 没公开的 `CGSMainConnectionID` / `CGSHWCaptureWindowList` / `CGSCopySpacesForWindows`、ApplicationServices 的 `_AXUIElementGetWindow` 和已废弃的 `GetProcessForPID`（不链接、不写进工程设置；取不到就退回公开做法，全在 `DockPreview/WindowServer.swift`）；**不是依赖**，跑起来才加载 | 10.x | 窗口编号、截别的桌面上的窗口、查窗口在哪个桌面、按编号切窗口并当 key |
| 启动器系统命令（D2，2026-09-27）：`Process` 调 `/usr/bin/pmset`（睡眠、关闭显示器）和 `/usr/bin/osascript`（访达清倒废纸篓、loginwindow 的退出登录 / 重新启动 / 关机 Apple Event、`set volume`）；`NSRunningApplication` 的 `terminate` / `forceTerminate` / `hide`；`FileManager.unmountVolume`；`dlopen` / `dlsym` 系统私有 `login.framework` 的 `SACLockScreenImmediate`（锁屏，用户拍板的私有 API，找不到退回 `CGEvent` 模拟 ⌃⌘Q）；entitlement `com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`；`kill(2)` 给 kill 列的进程发 SIGTERM / SIGKILL（体检 D12） | 10.x | 锁屏、睡眠、屏保、废纸篓、退出登录 / 重启 / 关机、退出 / 隐藏 / 强制退出 App、推出磁盘、音量、结束进程 |
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
| `Shell/` | `OverlayPanel.swift`、`Feature.swift`（功能开关：九个功能各自能整个关掉，和设置侧栏的页同名；程序坞预览默认关，`defaultOn`；2026-10-21，§10「功能开关」）、`FilePanel.swift`（从不激活本 App 的地方开系统的存储 / 打开面板：请求激活 + 面板提到 `.modalPanel` 拿到最前，关掉后还前台；2026-10-18 macOS 27 上激活被驳回、面板开在后面「点了没反应」后加）、`TransientPanel.swift`（用时再建、收起后放掉的浮层：两张 ⌘Y 大卡由它拿着，第二轮体检 M3）、`Memory.swift`（让分配器把空页还给系统，M4；空闲回收的计时 `Memory.IdleTimer`，2026-10-07）、`HotKeyCenter.swift`、`HotKeyRecorder.swift`、`Permissions.swift`（辅助功能、屏幕录制、文件和文件夹授权、麦克风（录屏第 4 批）；自动化被拒时打开系统设置）、`Paster.swift`（自家写剪贴板的唯一出口；`write(string:record:)` 把本 App 生成的新文字同时记进剪贴板历史）、`Subprocess.swift`（进程外跑系统命令行工具：更新的 ditto / codesign、系统命令的 pmset / osascript、kill 的 ps / lsof、浏览历史的 sqlite3，还有剪贴板后台识字的子进程（本 App 带 `--ocr`）；要的输出写临时文件，不受 64 KB 管道缓冲限制；可给环境变量、超时、优先级）、`Style.swift`（Whisker 刻度：圆角、七条弹簧曲线、中性色 / 家族色、输入框 `InputBox`、复制对勾停留、卡片表面 `CardSurface`、增强对比度的选中描边 `contrastSelectionBorder`、发丝线 `Hairline` / `hairlineBorder`、主按钮 `BrandButtonStyle`、种类色块、键帽、面板描边、面板内浮层的阴影 `floatingShadow`、空状态 `EmptyState`（剪贴板、翻译浮窗、翻译历史共用，2026-10-12 视觉对齐））、`HoverTracker.swift`（列表行悬停：`.activeAlways` 追踪区，非激活浮层里代替 `onHover`；剪贴板、翻译历史、启动器行共用）、`ListReveal.swift`（列表选中跟随滚动：`ListReveal.target` 纯函数按前缀和给目标 y，`RevealsSelection` 接管 `.scrollPosition`、按上次滚动的终点判断、停下没到补滚一次；剪贴板、启动器、翻译历史共用，第 10 批）、`CommandTextField.swift`（单行输入框：方向键 / 回车 / Tab / Esc 走 doCommandBy，对话框输入框、`maxLength`）、`BarNotice.swift`（剪贴板面板、启动器底栏左边的就地提示）、`SearchLine.swift`（剪贴板面板、启动器顶上的搜索线：线头符号定宽、左右内边距，两块面板同一个，2026-10-12 视觉对齐）、`Accent.swift`（强调色：跟随系统 + 8 色、配色计算、根视图的 `.appAccent()`）、`Island.swift`（刘海岛：全局轻提示，替换原来的 Toast；2026-10-26 起能悬停展开、带按钮，点刘海 / 快捷键能叫出来，§10「刘海岛交互」；`Island.announce` 是 VoiceOver 主动播报的唯一入口）、`IslandBoard.swift`（刘海岛的「那一张」：一排快捷动作 + 最近 10 条提示，2026-10-26）、`StatusItem.swift`（菜单栏图标与菜单，NSStatusItem，Whisker D 的呼吸 / 弹一下；`MenuExtra`：菜单栏和启动器内置动作共用的非热键项）、`ActionMenu.swift`（剪贴板 ⌘K、剪贴板筛选面板、剪贴板多选的收藏夹列表、启动器 ⌘K、翻译历史 ⌘K 共用的动作菜单：分节、一级子列表、共用过滤 `filter`（子串 + 拼音前缀），体检 C3 C4）、`Ticker.swift`（每秒在变的一行读数的图层画法，代替 numericText：整行排一次、按字切成一块块图层，每秒只滚变了的数字；状态屏告示上的小字和录制 HUD 的计时共用，2026-10-11 从 `StatusScreen/StatusTicker.swift` 挪过来） |
| `Storage/` | `Database.swift`、`Backup.swift`（数据库的每日备份 `Backup` + 打不开时的恢复 `Recovery`，第二轮体检 S2）、`Keychain.swift`、`Prefs.swift`、`SettingsArchive.swift`（设置与数据的导出与导入：文件格式、读文件时的校验、整类替换 / 按 id 合并、密钥的加解密，片段 / 文字收藏 / 生词本的导出，2026-10-07；2026-10-12 加第七类「便签」`NoteEntry`、格式 2：逐条宽松解码、按编号并进便签库）、`SettingsBackup.swift`（设置与数据的每日自动备份：导出文件每天存一份、导入前存一份，起名、列出、写、轮换，2026-10-08）、`SyncRecords.swift`（全局同步里一条一条的数据的合并规则和文件写法：账本比出本机改动、版本钟、墓碑、后改的赢，纯函数；2026-10-23）、`SyncLedger.swift`（`SyncSource` 协议：仓库交出该同步的那份、落合并结果；账本存法，2026-10-24）、`SettingsSync.swift`（设置、全局快捷键、功能开关接进全局同步：一项一条、留在本机的键、透传，2026-10-24）（~~`LegacyImport.swift`~~ 2026-09-26 随旧版导入删掉） |
| `Clipboard/` | `ClipboardWatcher.swift`、`ClipboardStore.swift`、`ClipItem.swift`、`ClipboardFilter.swift`、`ContentForm.swift`、`Search.swift`、`ImageStore.swift`、`OCR.swift`、`ClipboardPanelModel.swift`（面板状态与操作：筛选标签、选中 / 多选、键盘命令、粘贴 / 复制 / 删除撤销栈、⌘K）、`ClipboardPanelView.swift`、`ClipRowView.swift`、`LensView.swift`（透镜：选中行原地展开的预览）、`PreviewView.swift`、`Dialogs.swift`、`Snippet.swift`（片段占位符展开）、`LinkPreview.swift`（链接富预览：按块读网页 og 标签、isFetchable、内存缓存；头图的缩略图空闲时丢掉、照留着的字节重解）、`QuickLookView.swift`（⌘Y 放大预览）、`ClipDrag.swift`（行拖到别的 App：AppKit 拖放会话 + 行首图标块和标题的预览，体检 D3） |
| `Translate/` | `TranslateCoordinator.swift`、`TranslateService.swift`（服务列表与配置：内置 8 家可删可加回、自建 AI 实例、厂商预设）、`Language.swift`（应用内语言、语种检测、源 / 目标解析）、`SelectionReader.swift`、`SourceTextView.swift`（多行输入框：翻译原文、剪贴板编辑正文 / 新建片段、便签的快速记一条；便签的正文不用它，用 `Notes/NoteTextView.swift`）、`HTTP.swift`（JSON POST、SSE 读取、中文错误信息）、`SSE.swift`、`Providers/`（`Zhipu.swift`、`AIService.swift`（OpenAI 兼容 / Azure / Anthropic，也给智谱复用流式请求；按地址认厂商的表 `AIVendor`，第 13 批）、`RESTProviders.swift`（百度、有道、Google、DeepL / DeepLX、微软）、`CloudProviders.swift`（火山、腾讯，请求签名）、`Signing.swift`（摘要工具、非流式请求包装））、`TranslatePanelView.swift`、`ProviderCardView.swift`（含服务身份 `ServiceTile`：官方 logo、官网图标或品牌色块，彗星边框、骨架扫光）、`ServiceIcons.swift`（自建 AI 服务的官网图标：推官网、经 `LinkPreview.siteIcon` 取、磁盘缓存，第 13 批）、`ResultText.swift`（结果卡片的正文：普通 Text + 生成中的光标；原 RevealText 的显影第二轮体检第 1c 批拿掉）、`HistoryStore.swift`、`HistoryView.swift`（含历史 ⌘K 的动作和 `HistoryMenu`：导出、清空，浮窗「⋯」菜单 / 历史 ⌘K / 设置 › 翻译共用）、`Speaker.swift`（朗读：收起即停、挑高音质声线）、`WordLookup.swift`（查词：是不是一个词、系统词典查询与解析、单词模式示例，D4）、`DictionaryCardView.swift`（系统词典卡）、`TranslateServiceSync.swift`（翻译服务列表接进全局同步，密钥不同步；2026-10-24） |
| `Settings/` | `GeneralTab.swift`、`HotkeysTab.swift`、`ClipboardTab.swift`、`TranslateTab.swift`、`AboutTab.swift`（关于页：更新日志读 `Resources/changelog.json`；2026-10-18 起「未来计划」读 `Resources/roadmap.json`——两个都是随包的 JSON、一条一行，`ChangelogTests` 锁格式）、`LauncherTab.swift`、`ScreenshotTab.swift`（另有截图页、录制页共用的快速保存一行 `SaveDirectoryRow`）、`RecordTab.swift`（录制页：录屏、录音，2026-10-03 从截图页拆出来）、`SettingsTransfer.swift`（通用页最后一组「导出与导入」和两张表单，2026-10-07）、`SyncSection.swift`（通用页「同步」一节：选文件夹、状态、停止 / 立即同步、其他 Mac；2026-10-23 从便签页挪来）、`SettingsWindow.swift`（D 阶段从 Shell 搬来：NavigationSplitView 侧栏 + 搜索 + 页头）、`OnboardingView.swift`（首次安装的欢迎引导：欢迎 + 按一下试试）、`ShortcutsSheet.swift`（快捷键速查表 + `ShortcutsButton`）、`OrderedList.swift`（可拖动排序列表共用的「+ −」按钮条、行高、详情页页头）、`TranslateServiceDetail.swift`（翻译服务详情页）、`SearchEngineDetail.swift`（网页搜索 / 快捷链接详情页）；`StatusScreenTab.swift`（设置 › 状态屏：状态列表的加、删、排序、恢复自带的，退出提示的开关）、`StatusPresetDetail.swift`（改一个状态的详情页：六项 + 图标格子 + 缩小的预览）；`LaunchpadTab.swift`（设置 › 启动台，2026-10-18：总开关、触控板捏合（开关 / 灵敏度 / 系统手势提示）、触发角（带系统冲突提示）、行列数（显示当前值）、从系统启动台导入 / 恢复默认排列 / 撤销、排列数据说明）、`NotesTab.swift`（设置 › 便签，2026-10-12 第 2 批的骨架：正文字号、打开全部便签、数据怎么存的说明）。`SettingsWindow.swift` 里另有两个普通窗口共用的 `NSApplication.leaveDockIfNoWindows`（关掉一个时别的普通窗口都不开着了才切回 accessory）、`DockPreviewTab.swift`（程序坞预览：启用、两项授权，私有接口缺了时橙字说后果；2026-10-22） |
| `Launcher/` | `LauncherItem.swift`（结果项与内置动作）、`AppCatalog.swift`（App 目录 + 中文名 + 拼音）、`LauncherMatch.swift`（匹配与排序纯函数）、`LauncherUsage.swift`（使用记录表 + 收藏表 launcher_favorites，体检 D13）、`LauncherModel.swift`、`LauncherPanelView.swift`、`FileSearch.swift`（文件搜索：open / find / 空格开头，NSMetadataQuery 查询、排除、排序、最近的文件、授权提示，M13）、`SystemCommands.swift`（系统命令目录、quit / hide / forcequit / eject / kill / port 解析与只读列举，D2）、`SystemControl.swift`（系统命令的执行：锁屏、pmset、osascript、退出 App、推出、给进程发信号）、`Processes.swift`（kill 列的后台进程：ps / lsof 输出解析与排序，体检 D12；port 的端口行也在这里，2026-10-08）、`SiteIcons.swift`（网址行的网站图标：读本机 Chromium 系浏览器的 Favicons 库 + 链接预览，按主机缓存，体检 D6）、`BrowserHistory.swift`（各家浏览历史 + Firefox 书签：克隆后 sqlite3 导出、解析、行，体检 D8、第 12 批）、`Bookmarks.swift`（浏览器书签：Chromium 系 JSON、Safari plist，Firefox 取 BrowserHistory 读好的）、`Browsers.swift`（第 12 批：浏览器表、装没装、数据目录与多配置、偏好里开着的、克隆别人的库、读失败分「没授权 / 没有文件」）、`DirectItems.swift`（网址 / 路径直达，纯函数）、`WebSearch.swift`（网页搜索与快捷链接列表）；`AppCatalog.swift` 顺带扫系统设置面板（体检 D9），`Calculator.swift` 含单位换算表和进制（体检 D11）、`WebSearchSync.swift`（网页搜索与快捷链接接进全局同步；2026-10-24） |
| `Launchpad/` | （启动台，第八族，0.6.0，2026-10-18 第 1 批起；拍板和做法在 §10「启动台」，规矩在 `mac-launchpad.mdc`）`LaunchpadLayout.swift`（模型和全部纯函数：页 / 格子 / 文件夹、合并本机 App、默认排法、挪格子、建 / 加 / 拖出 / 解散文件夹、按行列数重新分页、存偏好；不变式由 `LaunchpadFuzzTests` 锁住）、`LaunchpadCatalog.swift`（App 目录：复用 `AppCatalog.scan()`，只留 .app、不要访达和系统设置面板；bundle id、分类、App Store 收据；`LaunchpadIcons` 后台画、常驻的图标位图）、`LaunchpadWallpaper.swift`（背景：那块屏的壁纸在后台裁好、模糊，缓存一张）、`LaunchpadModel.swift`（一块屏的状态：当前页、搜索、选中、拖动 / 落点 / 停留合成 / 跨页让位、文件夹页、Esc 取消、抖动、滚轮）、`LaunchpadMetrics.swift`（按屏幕大小和行列数算的网格尺寸，界面和拖动判定共用）、`LaunchpadPager.swift`（翻页的纯状态机）、`LaunchpadDrag.swift`（拖动的时长、正在拖的那一格、滑进落点的那一份，落点 / 第几格的纯函数）、`LaunchpadPanel.swift`（全屏面板 `LaunchpadPanel`，第七个自建窗口例外；深色外观、滚轮 / 两指滑、⌘← / ⌘→ / ⌘W、方向键入口、失去 key 的判断、窗口簿记）、`LaunchpadView.swift`（模糊的壁纸、照 macOS 15 比例的 7 × 5 网格、居中占位的搜索框、页点、各层的层次和文件夹开关的时机、按下 / 选中、VoiceOver）、`LaunchpadFolderView.swift`（打开的文件夹：后面糊掉的那层、从方块长出来 / 缩回去的纸、名字 / 图标 / 页点、改名）、`LaunchpadIconView.swift`（图层抖动的 App 图标、文件夹面板里的图标、文件夹方块）、`Launchpad.swift`（总控：开关、后台 App 目录、布局读写 / 读不出来时保护、打开 App、回收、导入 / 恢复 / 撤销、捏合和触发角的起停、收起后放掉）、`LaunchpadRecycle.swift`（抖动模式删 App 的确认，`NSWorkspace.recycle` 可注入）、`LaunchpadImport.swift`（系统旧库只读拷贝 + `mode=ro` 读 WAL）、`PinchRecognizer.swift`（纯状态机：开始 / 每帧进度 / 松手（进度 + 速度）/ 取消，松手走完还是退回）、`TouchpadWatcher.swift`（96 字节触点、Mutex 桥（每帧的进度也在里面）、唤醒重注册）、`LaunchpadMissionControl.swift`（打开前认调度中心、开着就让它退：只认 macOS 27 的 WindowManager 整屏 19 层窗口）、`LaunchpadZoom.swift`（开 / 收那一个数：窗口透明度 + 上面那层的缩放，跟手时屏幕刷新回调每帧取进度，松手和按键入口走同一条临界阻尼弹簧）、`LaunchpadCorner.swift`（每屏一个状态栏层级的透明 `NSPanel`、重新武装、系统触发角只读） |
| `DockPreview/` | （程序坞预览，第九族，0.7.0，2026-10-22 第 1 批起；拍板和做法在 §10「程序坞预览」）`WindowServer.swift`（窗口服务器的私有接口：窗口编号、截窗口、在哪个桌面、按编号切过去；运行时取，取不到退回公开做法）、`DockWatcher.swift`（听程序坞：图标列表的选中变化 → 停在哪个 App 图标上；辅助功能坐标换算；读属性的小函数）、`DockWindows.swift`（一个 App 的窗口：辅助功能表 + 别的桌面上的，并表的纯函数 `merge` / `resolveIDs`；切过去、关掉）、`WindowShots.swift`（缩略图：当场截、主线程外缩小、最多留 20 张）、`DockPreview.swift`（控制器：什么时候弹、换、收，点了切过去 / 关掉；面板是普通 NSPanel + `PreviewHost`）、`DockPreviewView.swift`（面板内容和 `DockPreviewModel`）、`DockPreviewLayout.swift`（纯函数：缩略图多大、一排放不下就缩再换行、面板摆哪、选哪块屏、鼠标还算不算在附近 `keepsOpen`、离开后的倒计时 `Linger`） |
| `Screenshot/` | `ScreenCapture.swift`（逐屏冻结帧 + 同一刻的窗口 Z 序快照）、`RegionSelector.swift`（框选会话、每屏一个遮罩、选区几何纯函数）、`SelectionView.swift`（遮罩画面与交互：图层绘制、窗口悬停、手柄、放大镜、工具栏）、`ScreenshotOutput.swift`（PNG、快速保存、另存为）、`PinPanel.swift`（钉图；第二轮体检 F1 起还有「钉住剪贴板里的图」的取图、解码、找位置）、`Annotation.swift`（标注模型，显示与导出共用 draw，M10）、`EditorToolbar.swift`（HUD 主工具栏 + 样式托盘，M10，Whisker 重做）、`FlyCard.swift`（截图飞入右下角 + 快门声，Whisker S1；录屏第 3 批起录屏的最后一帧也从这里飞，落地多播放符号和时长 `VideoMarks`）、`ScrollCapture.swift`（长截图会话：边框、侧边面板、抓帧循环、自动滚动）、`ScrollStitcher.swift`（长截图拼接，纯逻辑）、`AnnotateOverlay.swift`（标注遮罩：整屏压暗、图居中、滚动与缩放、工具栏和样式托盘、出图；长截图按 A 和截图历史里双击都用它，2026-10-26）、`ScrollCanvas.swift`（长图画布：只画看得见的那一段 + 标注交互，标注层复用 `AnnotationCanvas`）、`ShotHistory.swift`（截图历史：原图 + 标注 + 缩略图存 <数据目录>/shots/，记录在主库的 shots 表，按天数和总量清理，2026-10-26）、`ShotHistoryWindow.swift`（历史窗口和模型：筛选、按天分组、每条的操作、缩略图缓存）、`ShotHistoryView.swift`（历史窗口的界面：网格 + 预览 + 操作）、`Clothesline.swift`（晾衣绳：面板、什么时候滑下来 / 收起、挂上 / 取下、卡片上的动作，第十族 2026-10-26）、`ClotheslineLayout.swift`（晾衣绳的几何与时机：排法、垂度、菜单栏那一条、收不收，纯函数）、`ClotheslineRope.swift`（绳子的物理：verlet 质点 + 重力 + 阻尼 + 距离约束，纯值类型）、`ClotheslineView.swift`（晾衣绳的内容：绳子、卡片、夹子、悬停和鼠标 `CardMouse`）、`ShotShelf.swift`（CleanShot 式常驻缩略图，Whisker D；录屏第 3 批加视频卡 `ShelfCard.Kind.video`，右键菜单 / 旁白动作同一份 `ShelfCard.menu`）、`SizeField.swift`（遮罩里的尺寸胶囊：就地输入宽高、比例菜单）、`ScreenRecorder.swift`（录屏会话：SCRecordingOutput 先写到同卷、系统不清理的地方再挪进快速保存目录、白名单面板的例外过滤器、选区边框、菜单栏停止项、中断与闪退恢复，录屏第 1 批；第 2 批加倒数、放弃、帧率 / 倒数 / 光标设置；第 3 批挪好后取最后一帧 `poster`；第 4 批按录制条开关配声音 / 麦克风 / 点按（`Options`、`configure`）、开录前问麦克风授权、麦克风断开；录制条（四个开关：系统声音、麦克风、显示点按、显示按键） `RecordBar` 在 `EditorToolbar.swift`、框选是 `SelectionView` 的 `.record` 模式；手测反馈第 1 批起点按圈由 `InputOverlay` 画，`configure` 只管声音，过滤器例外多并一个它的窗口号 `exceptedOwnWindows`）、`InputOverlay.swift`（录屏里显示用户的输入，手测反馈第 1 批 2026-10-01：显示点按开着时盖在被录区域上的透明 NSPanel（普通实例、不接鼠标、层级 popUpMenu + 2），global / local 鼠标监听，按下圆盘 / 右键空心环 / 拖动跟随 / 松开涟漪都是 CALayer 动画；坐标换算、形状、哪些自家窗口上不画是纯函数；手测反馈第 2 批加按键提示：录制条「显示按键」开着时同一块窗口底部居中的 HUD 胶囊，global / local 的 keyDown 监听（global 要辅助功能授权），键名复用 `HotKey.display`，内容和停手清空是纯状态 `Keys`，位置是纯函数；显示点按 / 显示按键任一开着就建窗口）、`RecordingHUD.swift`（录制 HUD：倒数 / 录制中两态、红点呼吸、计时、放弃两下、停止，普通 NSPanel 状态栏层级、能拖，录屏第 2 批；第 4 批录制态加只读声音状态（系统声音 / 麦克风，开录时的麦克风断开变橙）；录音第 5 批加录音形态 `medium = .audio`：电平 `LevelMeter`、暂停 / 继续、「没听到声音」、底部居中从底边长出来；手测反馈第 3 批加录音的待录态 `State.ready`：[系统声音][麦克风] ｜ [✕][●]，来源开关读写 `Prefs.audioRecordSource`，开始后原地换成录制态）、`VideoExport.swift`（录屏转成 GIF，录屏录音第 7 批：15 fps、宽 ≤ 960、最长前 60 s，`AVAssetImageGenerator` 逐帧取、`CGImageDestination` 逐帧编（关全局调色板）、`@concurrent`；帧时刻 / 输出尺寸 / 存盘名是纯函数；常驻缩略图的 GIF 卡是 `ShelfCard.Kind.gif`，入口是视频卡的「转成 GIF」`ShelfCard.convertToGIF`）、`AudioRecorder.swift`（录音会话，录音第 5 批：AVAudioRecorder 录 m4a、授权、暂停续写、20 Hz 电平与 `Levels` 历史、「没听到声音」、中断（系统睡眠 / 输入设备断开 / 磁盘）、停止后画波形 poster；收尾挪文件、闪退恢复、结果岛、菜单栏停止项和录屏共用 `ScreenRecorder` 的 `settle` / `recover` / `summary` / `makeStopItem`（`ScreenRecorder.Medium`），常驻缩略图的录音卡是 `ShelfCard.Kind.audio`；第 6 批加来源 `Source`（麦克风 / 系统声音 / 两者），后两种用 `ScreenRecorder` 的只录声音模式 `audioOnly` 当引擎，电平由它的样本回调算好投过来；手测反馈第 3 批分成两个阶段：`open()` 待录只出控制条，`start()` 才读来源、问 `allowsStart`、开录） |
| `StatusScreen/` | `StatusPreset.swift`（一个状态：标题、说明、图标、样式、电源、自动结束；自带的三个；偏好里的 JSON 和 `sanitized`）、`InputBlock.swift`（事件拦截，全仓库唯一碰 `CGEvent.tapCreate` 的地方；会话是不是锁着 `isSessionAway`）、`ExitHold.swift`（退出判断：按住 esc / 按住退出提示 2 秒，纯状态）、`Passcode.swift`（退出密码：4–8 位数字、钥匙串里的条目、密码框的输入状态，纯状态）、`StatusScreen.swift`（一次会话：进入、触碰、锁屏时让开、退出、退出后拦截的留守）、`StatusScreenView.swift`（每屏一张全屏面板 `StatusScreenPanel` 和画面）、`StatusEmoji.swift`（动画表情：16 个可选 + 眼睛的清单、静止画面、解帧、按帧换图层内容的播放；素材 `Resources/status-emoji-<id>.heics` 由 `macos/status-emoji.swift` 从 Microsoft Fluent Emoji Animated 转来）、`StatusPicker.swift`（按全局快捷键时先出的选状态面板：一排预览卡片、键盘选择、把选中卡片的位置交给会话让画面从它长到整屏）；规矩见 mac-overlay-panel §11、`StatusPresetSync.swift`（状态屏的状态接进全局同步：一个一条 + 顺序一条；2026-10-24） |
| `Notes/` | （便签，§10「便签」；2026-10-12 立项、2026-10-18 八批全部做完）**数据**：`Note.swift`（模型、标题 / 摘要、清洗和上限）、`NoteStore.swift`（单独的库、排序搜索、最近删除 30 天、落盘重试）、`NotesBackup.swift`（每日备份留 7 份、打不开时的恢复，和剪贴板的平行）、`NoteSample.swift`（空库首次放一条示例）。**入口和窗口**：`NoteCapture.swift` + `NoteCaptureView.swift`（⌥N 快速记一条）、`NotesWindow.swift` + `NotesWindowView.swift`（全部便签窗口的列表 / 搜索 / 工具栏 / 右键）、`NoteWall.swift` + `NotesWallView.swift`（便签墙的纯函数和视图）。**屏幕边缘**：`NoteEdge.swift`（开关、叫停、面板生命周期）、`NoteDeck.swift` / `NoteDeckModel.swift` / `NoteDeckState.swift` / `NoteDeckOptions.swift` / `NoteDeckLayout.swift` / `NoteDeckPill.swift` / `NoteDeckPanel.swift` / `NoteDeckView.swift`（药丸、标签列、状态机、几何、设置、面板）。**打开的便签**：`NoteSheet.swift` + `NoteSheetModel.swift` + `NotePanel.swift`（那叠和浮动共用）、`NoteFloat.swift` / `NoteFloatModel.swift` / `NoteFloatState.swift` / `NoteFloatLayout.swift` / `NoteFloatPanel.swift`（拖出来、拉大小、固定后回原位；一张一个）、`NoteFloats.swift`（同时浮几张：上限、最久没碰、几张一起记位置，2026-10-22）、`NoteFields.swift`（标题 / 正文输入框）、`NoteColorPicker.swift`（颜色菜单的「其他颜色…」：系统取色面板、最近用过，2026-10-22）。**正文**：`NoteTextView.swift` + `NoteTextView+Images.swift`（显式搭的 TextKit 1；样式只改属性；组字期间不重排不落盘）、`NoteStyles.swift`（行距、五种任务方框、代码块、文字颜色）、`NoteMarkdown.swift`（不用正则的扫描器、标记藏 / 露）、`NoteTasks.swift`（任务和列表的纯函数）、`NoteTaskBox.swift`（任务方框自己画的圆角方框：几何、五种画法、记号取色；2026-10-18）、`NotePaper.swift`（8 种纸色、6 种文字颜色）、`NoteImages.swift` + `NoteImageStore.swift` + `NoteImageAttachment.swift`（令牌、图片目录、附件字符）、`NoteImageCrop.swift`（图片的裁切层：几何纯函数 + 盖在正文滚动区上的视图，2026-10-22）、`NoteMarkdownFiles.swift`（整个 / 单条的导出导入）、`NoteSync.swift`（同步的合并规则：版本钟、状态后改的赢、墓碑，纯函数；2026-10-22）、`NoteSyncFolder.swift`（同步文件夹的写法、一轮该合什么、刹车、该写出去什么，纯函数；2026-10-22）、`NoteSyncDisk.swift`（读写同步文件夹：协调读写、没下载完的文件、缓存，主线程外；2026-10-23）、`NoteSyncer.swift`（同步的执行层：什么时候合、一轮怎么走、刹车、正在编辑的先不换、认出库被退回去了；2026-10-23）。规矩：编辑器、Markdown、任务、颜色、图片、导出导入在 mac-overlay-panel §3 §5，那叠和浮动在 §12，长相在 `mac-whisker-notes.mdc`，备份在 mac-clipboard §1，划词在 mac-translate §5。 |

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
- Safari 受完全磁盘访问权限保护，又没有请求授权的 API：读失败按 `Browsers.failure` 分「需要授权 / 没有文件」，不弹框、不缓存，设置里给「去授权」。Safari、Firefox 的库是 WAL，克隆要连 -wal。Arc 侧栏里的书签、Safari / Firefox 的图标库不读（ponytail）。

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
- 第 7 批之后（2026-10-03，用户要求）：剪贴板面板的「钉到屏幕」也改用 `PinBoard.clipboardFrame` 让开屏幕上已有的钉图（模型多了 `pinnedFrames`，AppDelegate 接 `pins.panels`），同一张钉两次、多选的几张不再叠在一起。
- 第 8 批（2026-10-03）文档瘦身：PLAN 只留仍有效的部分（其余原样归档到 `docs/archive/`），手测挪到 `HANDTEST.md` 并在最前面加发版冒烟清单，mac-whisker 按界面拆成核心 + 5 个文件，提交说明的标题只写一行。
- 第 8 批之后（2026-10-03，用户要求两条）：钉图透明度改成 10–100% 的滑块（`OpacitySlider`，悬停圆钮弹出的菜单和右键「透明度 ▸」是同一行；放在菜单里免得跟着钉图一起变淡，最低 10%），对标 CleanShot；录屏、录音的设置从截图页拆成单独的「录制」页（`Settings/RecordTab.swift`，侧栏在截图后面，「保存到」和截图页「快速保存到」是同一行 `SaveDirectoryRow`），侧栏搜的是页名时停在那页。不做：⌘[ / ⌘] 和双指滚动调透明度（滚轮已经是缩放）、0% 透明度、鼠标穿透。
- 同日用户又两条：翻译浮窗放得下三张结果卡（`TranslatePanelView.panelHeight`：不超过三张全放下、多于三张至少放下前三张，最高到可见区减 24；原来最高 85%，三张写满的卡差几点就多出外层滚动条），第四张起才滚；`ActionMenu` 的滚动区铺满菜单宽，滚动条贴菜单右边（剪贴板、启动器、翻译历史的 ⌘K 和筛选面板都是它）。不做：小屏上压低卡片的 8 行上限来保证三张露全。

**常驻内存（2026-10-07）**
- 背景：用户让查正式版（0.3.2 本地包，跑了 3 天）`footprint` 342 MB、峰值 510 的构成。只读活进程（两份 memgraph，各停约 3 秒）+ 独立小程序 + 仓库拷贝里跑探针，给了 5 项改法，用户回「全部按推荐」，分批提交。**不是漏**（`leaks` 20 个 / 3 KB；窗口 10 个、面板 3 个、带位图的图层 32 个都对得上）：用过一次就不还的台阶 + 填到上限的缓存 + 堆里空着没还的页。
- 构成（MB，约数）：缩略图缓存 58（透镜 20 张 × 2 份 = 50，在 48 MB 上限内；行图标等小图 8）｜**面板和卡片描边的整块图层 55–58**（最大的意外，见下一批）｜识字模型 30（点得出名的：堆 21 + IOSurface 4 + 显存 4；独立实测进程内识一次常驻 52）｜进程内 Metal 渲染 26（SF Symbol 动效、Canvas 带起来的 RenderBox，起步约 9）｜界面对象 57（三块常驻面板的 SwiftUI 视图图、Swift 运行时、符号 / 字体 / 菜单）｜字形缓存 12（CoreGraphics 的，系统封顶 16 MB，一小时后已到顶）｜通用对象和系统运行时 23｜剪贴板 / 翻译历史 / 启动器自己的数据 ≤ 3｜堆里空着没还的 58（整页空着的约 34 能还，页里夹着活对象的零头约 25 还不了）｜固定开销 13。一次性的台阶（实测）：每块面板第一次呼出 +13–33（屏上、深色）、第一次进程内识字 +52、设置窗第一次打开 +21（六页点遍 +54，关掉后还留约 40；屏外量的）。峰值 510 是瞬时的（⌘Y 大卡、面板呼出时的解码）。
- 量法（mac-native「测量与诊断」、`MemoryProbeTests` 文件头第 4 个坑）：探针把面板摆在屏幕外时系统不画图层，三块主面板量出来各 3–8 MB，真上屏是 12–33 MB——第二轮体检第 2 批的「三块主面板都不到 10 MB」是这么来的；结论（主面板一直留着、不放掉）没变，数不对。探针加了屏上模式（`TEST_RUNNER_KITTY_MEMORY_PROBE_ONSCREEN=1`）。
- 分批：内存探针屏上模式 + 本节（先落，后面几批拿它对数）→ 描边换画法 → 空闲回收 → 空闲时放掉识字模型。
- 描边换画法：`PanelRim` 和 `CardSurface` 深色高光原来是 `strokeBorder(LinearGradient…)`，SwiftUI 把它栅格化成整块形状大小、每像素 8 字节的位图图层（720 × 520 的面板一张 11.4 MB，收起后不还，窗口高度做动画时每帧重画、还同时留两三份）；改成纯色描边 + 渐变蒙版（都不带位图），屏外逐像素最多差 1/255。屏上实测（深色、第二轮）：剪贴板显示后 +19.5 → +6.8–9.7 MB、启动器 +12.5 → +2.5、翻译三张卡 +18.5 → +2.6–3.5；逐帧改窗口高度每帧 3.5–4.0 → 0.9 ms。规矩在 mac-whisker §8，`StyleTests.rimAndCardHighlightAreNotRasterized` 锁住。
- 空闲回收（`AppDelegate.idleReclaim` + `Memory.IdleTimer`）：三块主面板哪块收起都重新计时，两分钟（`Memory.idleDelay`）后还没有面板开着、也不在框选，就清透镜缓存（`ThumbnailView.dropPreviews()`，装满约 50 MB；再看到时重做，一张 14–97 ms）并调 `Memory.relieve()`（跑了三天的正式版按「整页没有活对象」估能还 20–34 MB，其中 12.3 MB 是最近释放的一大块；没法在正式版里实调）。行图标缓存不清。系统内存吃紧时这两样本来也会被收（NSCache、分配器），这一步是让闲着的时候就还。
- 空闲时放掉识字模型（`OCR.releaseModel()`，同一个空闲回收里，进程内识完字也重新计时）：⌥O 识字、截图翻译、钉图识字仍在进程内，连着识时模型留着；闲下来用 Vision 的私有接口 `VNSession.globalSession.releaseCachedResources` 放掉（用户同意用私有接口；公开接口放掉请求和处理器不还；接口不在了就什么都不做）。内存探针（识过两张整屏截图）：进程内识字常驻 +57 MB，放掉 + 回收接口回落 56 MB，之后第一次识字 0.90 s（冷的 1.08 s、热的 0.96 s，整屏密集文字；独立小程序 1200 × 600 的选区：热 0.2 s、放掉后第一次 0.4–0.56 s）。放掉本身 18–200 ms，在主线程外做。
- 链接预览的头图（同日补：用户问剪贴板的预览占不占内存时量到的，上面的「构成」里没算它，当时进程里有 7–12 条；`LinkPreview.dropHeroes()`，同一个空闲回收里）：`LinkPreview` 最多留 12 条，每条的头图是长边 1200 的缩略图，原来一直拿到退出。独立小程序（照产品的缓存和画法，真上屏）：12 张 1200 × 630 的头图都在透镜里看过 +76 MB（CG raster data 37 + CoreAnimation 35，一张约 6 MB），面板收起不回落。**顺带查清一个量法上的坑**：ImageIO 的缩略图创建时就解码了，像素一做好就在物理内存里，只是没画过时不计入本进程的 footprint——源字节放掉、把可回收内存清掉之后照样画得对；做 100 张没画过的 1200 × 630（像素共 288 MB），本进程 footprint +3 MB，全机匿名页 +270–500 MB（多出来的是噪声），放手才回去（从文件做的 `ImageStore.thumbnail` 一样）。第二轮体检记的「懒解码、不画不占内存」只对 footprint 成立（缩略图缓存的上限按画过的两份记，不受影响）。所以头图取好没看也占着一份（12 条约 35 MB），想还就得把缩略图整个放手，「换成一张没画过的」不算。改法：条目里另留头图下载来的字节（解得出来才留），空闲回收时把缩略图都丢掉，再显示时 `LinkHero` 照字节重解（`restoreHero`：JPEG 2–15 ms、要缩小的 PNG 20–44 ms；不联网、不等 0.25 s 停留，标题和网站图标一直在，这一两帧头图区是渐变 + 图标）。改后小程序：空闲回收后 +8 MB——其中约 6 MB 是 SwiftUI / CoreAnimation 自己留着的一张（头图区第一次插进来的那张，换掉、拿掉之后还留着，改前就有，不累积），其余是字节和零头；收起的面板里第一条正好是链接时，它的头图还挂着、会马上重解回来（+14 MB）；连着「丢掉再重解 12 张」600 轮不涨。留着的字节：实取一批常见网站，取到头图的 24 个里中位数 84 KB，超过 1 MB 的只有 2 个（3.0 MB 的 PNG；4.8 MB 的 GIF 超过 4 MB 的上限、本来就不取），12 条常见 1–3 MB；上限 12 × 4 MB，没封顶（ponytail 在 `dropHeroes`）。没选的：空闲时整条丢掉（再选中要重新联网取、再扫一次光，还挂着的卡不会自己重取）。没做、等用户定：头图分档（透镜只要 320 × 180 像素，按它解一张画过才约 0.5 MB，12 条都看过从约 70 MB 降到约 6 MB；代价是 ⌘Y 大卡要另解一张 1200 的，从透镜长出来的头几帧先糊后清）；把 12 条调小。规矩在 mac-clipboard §5「链接预览」，手测 `HANDTEST.md`「0.3.2 手测」17。
- 不做：字形缓存（系统封顶，公开接口清不了）；进程内 Metal（符号动效就会带起来，单把棋盘格 Canvas 换成形状实测省不到 1 MB）；主面板用完放掉（描边改完后三块加起来只再还约 10 MB，每次呼出却要重建）；设置窗的一次性开销（系统控件的堆）；缩略图上限不改（改成空闲时清）；识字全走子进程（现成的 `--ocr` 子进程每次 0.51–0.70 s，进程内热的是 0.22 s，每次都过 0.3 s、都会闪「识别中」）。
- 便签（2026-10-18，调优 T2）：空闲回收原来只在三块主面板收起、识完字时排计时，也只看浮层开没开——只用便签的人，便签墙上看过的图一直占着。内存探针第 6 节（300 条便签、50 张 2400 × 1600 的图；屏外 / 屏上各跑一遍，数几乎一样）：便签墙打开、一屏一屏滚到底再滚回来比基线多 123 MB（图片缩略图缓存 53 张 34 MB，画过之后 CoreAnimation 和 CG raster 各一份）；关窗口（窗口对象留着）一点不降；清缩略图缓存 + 回收接口回落 65 MB、还比基线多 58 MB；**再把关着的窗口整个放掉又回落 11.5–11.6 MB**（窗口的图层、视图树、墙上卡片自己拿着的缩略图）；剩下的约 46 MB 是仓库里的卡片缓存和进程里第一扇 SwiftUI 窗口的一次性开销（探针只跑这一节时没有热身，没再细拆）。放掉之后重开到第一屏 0.18–0.21 s（Debug），卡片不用重建（缓存在仓库那一层）。屏幕边缘那叠打开一条带 5 张图的便签：只解了看得见的 2 张（5.3 MB），收起 2 秒后面板本来就自己放掉，再清缓存回落 0.0 MB。改了：全部便签窗口关掉、那叠收起、浮动便签收回 / 关掉也排空闲回收（`NotesWindow.onClose`、`NoteEdge.onHide`）；「算不算闲」抽成纯函数 `AppDelegate.isIdle`——全部便签窗口开着、那叠展开着（扇着、打开着便签；「一直展开」时静置的那一列常驻屏幕上，不算）不算闲，**浮动便签不拦**（它可以一直浮着，拦了就永远不回收）；空闲回收时放掉关着的全部便签窗口（过了 10 MB 的线；模型留着，选中、视图、搜索词下次打开还在；最小化着的不放）；清缩略图缓存时留下浮在屏幕上那张便签里的图（`NoteImageThumbnails.discard(keeping:)`：清了它下一次重画——点进去、滚动、拉大小——先画一块纸色再出图）。没改：那叠（本来就收起后放掉面板）、缩略图缓存的上限、仓库里的卡片缓存。手测「调优手测」2

**设置的导出与导入（2026-10-07）**
- 背景：用户要「导出已经设置的设置、快捷键、配置的 AI 服务等，并请补充」。对标（官方文档，2026-10-07 查）：Raycast「Export Settings & Data」——一个 `.rayconfig` 文件、用至少 8 位的口令加密、导入时列出类别勾选、没勾的不动（manual.raycast.com/import-export）；Alfred 的偏好同步故意不带每台机器各自的东西（主热键、主题、剪贴板历史、自动更新设置等，alfredapp.com/help/advanced/sync）；Rectangle 设置里有导入 / 导出 JSON 的按钮（偏好和快捷键，README）。Bob 的文档、CleanShot 的更新日志里没查到设置的导出 / 导入。
- 范围（按推荐先做出来，用户 2026-10-07 看过截图和说明后同意、提交）：设置 › 通用最后一组「导出与导入」。一个 JSON 文件四类——设置（各页改过的选项，含剪贴板排除的 App）、快捷键、翻译服务（含 AI 服务的地址和模型）、网页搜索与快捷链接；导出、导入都能按类别勾选。**用户点名的三样之外补充的**：网页搜索与快捷链接；翻译服务的密钥（可选，密码加密）；导入（没有它导出没用）和导入时的校验；会让历史保留得更少时的提醒。
- 取舍：密钥默认不带，带就必须设密码加密（文件可能发给别人、放网盘；明文违反「密钥只进钥匙串」）；偏好只导出改过的 + 导入时整类替换（结果和导出那台一样，没改过的继续跟默认值走）；两张列表合并不删（删 AI 服务会丢密钥）；导入后现场生效，不重启；格式用 JSON（人看得懂、能比较），不注册自己的扩展名。
- 第二批（用户同日同意按推荐做）：片段、文字类的收藏和收藏夹、生词本放进同一个文件（`clips` + `clipGroups`、`vocabulary`，明文），导入时合并进库——`ClipboardStore.adopt`（收藏夹按名字对、条目按正文对，已有的只补标记、时间和位置不动，没有的按原来的时间新建）、`HistoryStore.adoptFavorites`（没有的记成收藏，已有的只标收藏）。文件上限从 1 MB 放到 32 MB（单条文字最大 5 MB；读和解析在主线程，独立实测 32 MB 全是短片段时最坏 0.6 s），条数上限 5000 条片段 / 收藏、200 个收藏夹、2 万条生词，自己导出时超了直接不让导出。第二批同样过了一遍独立审查，修掉的：条目带出来的收藏夹名字绕过 200 个的上限、超出条数时导入悄悄截掉（改成导出时就拦）、同一秒的几条导入后顺序反了、备注太长整条被丢、刘海岛小结可能超宽。刘海岛的导入小结压到一行（原来四类全导时就超了 280 pt）。考虑过直接拿每日备份那份数据库文件当导出文件（图片也能带）：导入别人给的数据库文件比 JSON 难校验得多，而且会有两套导出机制，没选。
- 不做：图片 / 文件类的收藏（体积大，要换成文件夹式的备份；本机损坏有每日自动备份）、启动器收藏（⌘D 几秒能重加，目标路径换台电脑不一定在）、普通剪贴板历史（有保留天数、退出 / 锁屏清空这些隐私控制，不该靠导出留下来；每日备份同样的取舍）；~~定时自动导出、导入前自动留一份~~（2026-10-08 做了，见下面「设置与数据的每日自动备份」）；恢复默认设置的按钮；登录时打开（系统的登录项，要装在「应用程序」里才能开）；截图的存储文件夹（这台电脑上的路径，而且别人给的文件不该能改截图存到哪）。导入框里把文件里的翻译服务会连到的自己填的地址列出来（`customHosts`）：名字叫 OpenAI 的服务连的不一定是 OpenAI。
- 实现后做了一轮独立审查（一个只读的评审 agent），修掉的：DeepLX 地址开头带空格时列不出主机（和发请求改用同一个解析）；地址只列前 8 个能把恶意地址藏在后面（改成全列、启用的在前、多了滚动）；密钥没和服务地址绑在一起（改了地址照样解得开 → 加进 GCM 的附加数据）；只导入「设置」时也能关掉敏感过滤、清空排除列表、打开复制即译而没有提醒（加 `privacyLosses` 橙字、信任提醒常驻）；读文件前的大小检查绕得过（改成最多读上限 + 1 字节）；存储面板开着时还能改表单；两张列表的字段没有长度上限。没修、留着的：手改文件写了不在档位里的整数（图片上限 123、帧率 45、倒数 4）时功能照常、对应的选择器显示成空白（保留天数和翻译历史条数有 `Prefs.migrate` 挪档位）。

**设置与数据的每日自动备份（2026-10-08）**
- 背景：用户问「导出功能是否可以加一个本地自动定时备份，防止数据丢失」。核对现状：数据库每天自动备份（`Backup`，只有留下的东西、3 份）只在库打不开时用得上，设置里哪都没提；设置、快捷键、翻译服务、网页搜索在偏好里，没有任何自动备份；误删的片段没法从库的备份里单独找回来；备份和数据在同一个文件夹，硬盘坏了一起没。对标（官方手册，当天查）：Raycast 的定时导出是付费版功能——每天 / 每周 / 每月导出到用户选的文件夹、留最近 1 / 5 / 10 份、必须设至少 8 位口令把整个文件加密（manual.raycast.com/import-export）。
- 范围（给了推荐范围和三项待定，用户回「按推荐」）：每天自动存一份导出文件（六类）在数据目录的 `backups/`；可以另选一个文件夹每天再存一份；设置 › 通用「导出与导入」里显示已有的备份、「从备份恢复」；导入前先自动存一份。三项：**默认开、可关**；**留最近 7 份**（导入前那种留 3 份）；**不带密钥**。
- 取舍：时机跟数据库的备份走（启动、换日、锁屏），不加定时器、不给「每周 / 每月」的档位；恢复不另写一套，就是导入（设置、快捷键整类换回那天的样子；两张列表和数据是合并——没有的加回来、同一条改回去，不删后来多出来的）；开关、另存的文件夹和它的名字、电脑编号、没备成的原因不注册默认值、不跟着导出 / 导入走；另选的文件夹不在了不建、只记原因，那里的文件名带这台电脑的编号、只动自己写的；哪一类多到导出上限就不带哪一类、别的照备；本机那份和另存的那份各走各的，碰另选的文件夹的（看在不在、写）都在主线程外，设置页那一行也不碰它（可能在卡住的网络盘上），读设置、编 JSON 在主线程（上限 32 MB 约 0.6 s，常见的几十 KB 是毫秒级）；数据库当次备份发现库有问题时不做。
- 评审后改的（实现完找了一个独立评审，14 条都处理了）：① 轮换改成和数据库的备份共用 `Backup.expired`——刚写的那份不删、多出来的先删日期比现在还晚的（原来只按日期留最新几份：系统时钟调到过未来时写下的那几份会把今天这份当场顶掉，之后每次白备；**数据库的每日备份原来也有这个问题，一起修了**）；②「导入前」那份**只能把设置和快捷键换回去**，界面和更新日志不再说「导错了能退回去」；③ 另存的文件名带电脑编号（几台电脑、正式版和 Dev 版共用一个文件夹时，不互相当成「今天备过了」、不互相轮换）；④「导入前」最多留 7 天、同一秒里的第二份不盖第一份；⑤ 另存的说明里写明文件不加密；⑥ 两处橙字分开记（本机的在「已有的备份」下面，另存的在「另存一份到」下面，换了文件夹就收掉；等结果的那会儿换了文件夹，旧文件夹的结果不写）；⑦ 没权限时的原因说去哪开；⑧ 哪一类超了不带哪一类（原来不管谁超都先去掉片段与收藏）；⑨ 另存的那一行不在主线程上问文件夹的名字和图标；⑩ 写了新的一份，设置页当场重新列。
- 代价（拍板前说给用户了）：片段、收藏、生词在备份文件里是明文（本机那份和数据库放在一起，没有新增暴露；选了云盘文件夹会同步上去；服务地址里自己写进去的令牌也在里面）；删掉的片段在备份里留到被后面的顶掉为止（7 份，每天都开着就是 7 天；关掉开关后已有的不删、也不再轮换）。
- 已知的边角：系统时钟调到过未来、那时份数又还没满，那几份会留到真到了那天，被当成「今天备过了」（数据库的备份同样）；数据库打不开选「重新开始」后「从备份恢复」是空的——那些 JSON 跟着 `backups/` 挪进了 `damaged-…/`，要用得走「导入…」选里面的文件（弹框里有一段说怎么导回来，用户 2026-10-08 同意加；没做成「重新开始之后设置里还能直接选到」，要的话是重新开始时把那几份拷一份回新的 `backups/`）；上一次另存还卡着时换了文件夹，新文件夹要等下一次触发才有今天那份；重装、清了偏好后电脑编号会换，另存的文件夹里旧编号的那几份不再轮换（还能导入，要手动删）。
- 不做（要的话另说）：备份带密钥（要把一个密码存进钥匙串）；每周 / 每月的档位；「立即备份」按钮（打开开关、选了文件夹时会当场备一次）；另选的文件夹里也放「导入前」那种；从另选的文件夹里直接恢复（走「导入…」选文件）；删备份的按钮；图片 / 文件类的收藏（仍只有数据库的每日备份管着）；内容没变就不新写。
- 没验的：真机流程（`HANDTEST.md`「0.3.2 手测」18）；往桌面 / 文稿 / iCloud 云盘这类受保护的文件夹写时系统的授权框弹不弹、什么时候弹（在面板里选过的文件夹可能直接就有权限；被拒时是那一行的橙字，说去哪开——只在单测里拿只读文件夹验过这句话）；网络盘卡住时的表现（只按「主线程不碰它」写了，手头没有卡住的盘可试）；AppDelegate 里只剩「什么时候调、两份别叠着调、库有问题时跳过」（`backupSettingsIfDue`），这几句单测跑不到——每一份该不该写、写、把结果记进偏好的整条路在 `SettingsBackup.backUpLocal` / `mirror` / `snapshot`，有单测。

**启动器 port（2026-10-08）**
- 背景：用户想加一个 `port` 指令「列出当前运行的端口，可以结束它们」，又担心和 kill 重复。核对：功能上确实重复——`kill :` 已经列所有在监听的进程、`kill :3000` 按端口筛；但拿它「看端口」有四处接不住（在用户机器上实查）：行标题是进程名（20 个监听进程里 9 个都叫 node）、分不出是哪个项目（同一个项目的 wall、server 各起了两份）、程序坞里的 App 不列（微信占着 5 个端口，`kill :14013` 却写「没有进程在监听这个端口」）、`:端口` 这个写法只在速查表里。对标（当天查）：Raycast 的 Kill Process 和 Port Manager 是两个作者的两个扩展，Kill Process 没有端口功能，所以它们不重叠。
- 范围（给了推荐，用户回「按这个做」）：加 `port`，但只做成 kill 同一份数据的另一个视图——ps / lsof、`.process` 行、结束 / 强制结束、上膛确认全部复用，`kill :3000` 不动。不同的只有：只列在监听的、一个端口一行按端口号排、标题是端口、副标题带工作目录、数字按端口号开头筛、含程序坞里的 App（↩ 正常退出，⌘↩ 强制退出）。细则在 mac-whisker-launcher「系统命令」。
- 做的时候定的（没另问）：父子进程都在监听同一个端口时只列父进程（用户机器上的 nginx 就是）；上膛的确认提示里写进程名；端口号等宽数字；App 行右侧仍写「进程」；工作目录分两次 lsof 取（只取在监听的那几个：本机 459 个进程实测 30 ms，一次全取 100 ms），整次列举约 65 ms，和 kill 一样。
- 实测过的：取工作目录不触发文件夹授权（工作目录在 `~/Library/Safari`、当前进程列不了那个目录的进程，lsof 照样给出路径；受保护目录里的文件 stat 得到、读不到——隐私保护管的是内容和列目录，不管元数据）；真机上列出来的 24 行和 `lsof` 对得上，nginx 的 worker 没列。
- 已知的边角：进程自己改过标题的（`process.title`、nginx）名字是它改成的那个的最后一段（「vite.js」「nginx -g daemon off;」），kill 一直也是这样；别的用户、系统的进程在监听时看不到（lsof 不用 root 只看得到自己的），所以空结果写「没有找到」；同一个 App 开了两个实例时退出的是先找到的那个（quit 一直也是）。
- 不做（要的话另说）：显示绑定地址（仅本机 / 局域网可访问）、在浏览器里打开、给端口起名、UDP、复制端口 / PID。
- 没验的：真机流程（`HANDTEST.md`「0.3.2 手测」19）。

**状态屏（2026-10-10 立项，0.4.0）**
- 背景：用户想要「类似屏幕清洁，但能自定义有哪些状态，比如电脑正在跑项目请勿触碰」。对标（都没有同时做到可自定义状态和清洁）：KeyboardCleanTool 8（键盘、可选鼠标触控板；按住鼠标键几秒退出、特意不给键盘快捷键；全屏压暗 + 计时卡；可定时自动解锁）、CleanLock（键盘鼠标媒体键全拦；左右两个 ⌘ 退出；纯黑 / 半透明 / 自选图；说明里写明不是安全锁）、Mole 清洁模式（退出钮要鼠标移动够远才出现、按住 1 秒）、Leave My Mac Alone（触控 ID 退出；留言预设 + 自己写；保持唤醒；紧急出口是远程登录后结束进程）。拍板页 https://claude.ai/artifact/NRnPSmoeRo989G16ZEhkxp ，用户回「全部按推荐」。
- 拍板（Z1–Z12）：① 名字「状态屏」。② 定位是告示加防误触，**不是安全锁**，不做退出验证（验证出问题时键盘鼠标都被拦着，只能强制关机）；界面和更新日志里不要写成「锁」。③ 自带三个状态：清洁屏幕（熄屏、电源照常、5 分钟自动结束）、请勿触碰（透出、屏幕常亮、说明「电脑正在跑任务，别动键盘和鼠标」）、马上回来（告示、不睡眠）；都能改、删、拖动排序，能再加。④ 每个状态六项：标题、说明（可空）、图标（一组符号里选，可不要）、样式、电源（照常 / 不睡眠 / 屏幕常亮；第三项 2026-10-12 前叫「不睡眠且屏幕常亮」）、自动结束（不 / 5 / 15 / 30 / 60 分钟）；告示和透出样式底部固定一行小字「几点开始 · 已经多久」，按分钟更新。⑤ 三种样式：熄屏（纯黑，什么都不显示）、告示（深色底 + 大字）、透出（屏幕压暗 + 大字）。⑥ 键盘、鼠标点按和滚动、媒体键全拦。⑦ 退出：按住 esc 2 秒，或用鼠标按住屏幕上的退出提示 2 秒；按住 esc 期间碰到别的键就重来。⑧ 退出提示平时不显示，有人碰了键盘鼠标才浮出 3 秒，同时标题晃一下；设置里可以关（关了只剩按住 esc）。⑨ 锁屏期间不拦输入、电源设置照旧生效，**解锁回来自动结束**（想真防人：进入状态屏后再锁屏）。⑩ 入口：启动器（每个状态一条）、菜单栏「状态屏」子菜单、一个全局快捷键（不设默认键，进入列表第一个状态）。⑪ 设置新加一页「状态屏」，排在「录制」后面。⑫ 单独发 0.4.0。
- 做法：每块屏幕一张不抢前台的全屏面板（层级 `CGShieldingWindowLevel()`，盖住菜单栏、程序坞、通知横幅；`canJoinAllSpaces + fullScreenAuxiliary + stationary`；鼠标所在屏的那张当 key）叠一个会话层的事件拦截（`CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap)`，吞掉按键、修饰键、鼠标键、滚轮、媒体键和手势；**鼠标移动不拦**，退出提示要靠它）。两层都要：拦截管系统快捷键、别的 App 的全局热键和媒体键；面板当 key 是为了安全输入开着时（下一条实测）按键落在自己的面板上，不进前台 App——面板的 `keyDown` / `keyUp` 和拦截喂给同一套退出判断。鼠标按下被拦截吞了、到不了面板，退出提示的命中由拦截给的坐标自己判断。不用 kiosk 模式（`NSApplication.presentationOptions`）：它要本 App 变成前台 App。保持唤醒同录屏（`ProcessInfo.beginActivity`）。进入时收起三块浮层、停用本 App 的全局热键，退出时恢复；退出完成后拦截留到 esc / 鼠标键松开才撤（不然按住的 esc 连发会落进前台 App）。代码在 `KittyTools/StatusScreen/`（`StatusPreset` 状态与自带状态、`InputBlock` 事件拦截、`ExitHold` 退出判断、`StatusScreen` 会话、`StatusScreenView` 面板与画面）加 `Settings/StatusScreenTab.swift`；写代码的规矩在 mac-overlay-panel §11。
- 实测过的（第 0 批，2026-10-10，测试宿主里跑的临时探针：只吞自己发的带标记的合成事件，真实输入放行）：只有「辅助功能」授权就建得起会吞事件的拦截（Dev 版没要过「输入监控」，`CGPreflightListenEventAccess` 也是 true）；会话层、HID 层都建得起来（Apple 文档说 HID 层只有 root 能建，过时了；用会话层）；要的事件类型里系统留下了 1–4（左右键）、10–12（按键、修饰键）、14（媒体键）、18–20 / 29–31（手势）、22（滚轮）、25–27（其他鼠标键），丢了 32、34、37、38；吞掉之后别的进程的全局监听收不到、**注册成 Carbon 全局热键的组合不触发**（别的 App 的快捷键走的就是它）；⌘Tab、⌘空格、⌃↑ 拦截都看得到（看得到就吞得掉，前台 App 没换）；媒体键（音量加）看得到、吞掉后音量没变；鼠标键吞掉后别的监听收不到。**安全输入开着时（密码框、终端的「安全键盘输入」）拦截一个按键都看不到**，所以面板必须当 key。回调卡住 2.5 秒：系统停用拦截并发一次 `tapDisabledByTimeout`，`tapEnable` 重新打开后照常——主线程卡死不会把人锁在外面，收到停用通知要立刻重新打开。
- 没验的（`HANDTEST.md`「状态屏手测」）：触控板三指 / 四指手势（调度中心、切换桌面）拦不拦得住；触发角（鼠标移动不拦，角上的动作会触发，只是盖在面板下面）；盖在全屏 App / 全屏游戏上时前台 App 会不会被拉出全屏；屏幕常亮时屏保和自动锁屏还来不来；终端开着「安全键盘输入」时按键确实进不了终端；电源键、触控 ID 键、合盖拦不住（同类产品都一样）。
- 不做（要的话另说）：退出要触控 ID（退出密码 2026-10-11 做了，见下面「第三轮」）、拍下动手的人、进入时暂停音乐、空闲多久自动进入 / 定时进入、命令跑完自动结束 / 显示任务进度、自选图片和表情、回来时间倒数、模糊样式、每个状态单独设快捷键、退出键可改。
- 做的时候定的（第 1 批，没另问，汇总给用户确认）：**透出样式的字垫一块 HUD 底板**（后面是别人的窗口，说明和小字会和它们的字叠在一起，截图自检里读不出来；压暗仍是 0.68，后面的窗口还看得见）；告示样式的底和熄屏一样用纯黑；退出提示写「按住 Esc 退出」，左边一个进度环（拍板页的演示是环套着 esc）；按住 esc 期间来了**任何别的触碰**（别的键、修饰键、鼠标键、媒体键）都取消，滚动不取消；**锁屏时面板收掉**（层级很高，没法确认会不会盖住锁屏界面）、「屏幕常亮」降成只防睡眠（不然锁屏界面一直亮着）；正在录屏 / 录音时不让进（控制条和停止项会被盖住），截图框选、设置里录快捷键时也不进；状态屏里复制即译不弹浮窗；启动器里状态行同分排后、不记使用（↩ 不确认，同「退出 Kitty Tools」）；家族色 systemBrown（告示牌的木色；mint 和网址的 teal 太近）；没选图标的状态在菜单、启动器和设置列表里用 `text.alignleft` 垫着（第 2 批从 `textformat` 换的：它在中文系统上画成「格式」两个字）；菜单栏那一节不画节标题、只有一项「状态屏」带子菜单；鼠标指针进入时和提示收起时藏到下一次挪动（本 App 不在前台，系统理不理待手测）；偏好键 `statusScreenPresets` / `statusScreenExitHint`、启动器 id 前缀 `statusScreen:`（单说 status 指菜单栏图标）；自带状态的 id 是 clean / busy / back，可选图标 20 个、没有锁的图标。
- 做的时候定的（第 2 批设置页，没另问）：「恢复自带的状态」放在「+」菜单里（同翻译服务、网页搜索「删掉的从 + 加回来」），不单独一个按钮；删除时和自带的一模一样的直接删、自己加的和改过的先确认；至少留一个；满 20 个整个「+」置灰；详情页的输入框绑一份草稿，标题删光时留着原来的标题、超长只出橙字不硬截（怕打断输入法组字），存进去的是收拾过的；预览是缩小的同一个画面（不带退出提示，时间是摆的）；快捷键页和速查表里那一行叫「进入排在最前面的状态」（`HotKeyAction.rowTitle`）；速查表页头的跳转胶囊加到 8 枚、每行 4 枚折成两行；启动器里排第一的状态行右侧显示全局快捷键的键帽；菜单栏子菜单最下面「管理状态…」。**导出导入**：状态列表跟「设置」一类走（`SettingsArchive.kinds` 里单独登记成 `.statuses`，文件里是一组看得懂的状态；不注册默认值——没存过 = 自带的三个，以后改自带的，没动过列表的人跟着变；不升 `currentFormat`：没加类别，0.3.2 读到不认识的值会丢掉这个键，读源码确认的），但**导入时按 id 合并、文件里没有就不动本机的**（它是用户自己写的东西，同两张列表；别的设置是「文件里没有就回到默认」），读文件、写偏好两步都过 `StatusPreset.sanitized`。顺带修的两处：分组页脚折到第二行的字原来靠右（`OrderedList.footnote`，翻译服务列表下面那句也跟着变靠左）、`DangerButton` 置灰时标题不变淡。界面文案里系统的「锁定屏幕」「解锁」照实写，不许叫「锁」的只是状态屏自己。
- 已知的边角：界面自动化（要点屏幕、发按键的脚本和测试）和状态屏不兼容——面板盖着整屏、键盘在面板上，放行合成事件也没用；命令行任务、训练、编译、下载不受影响。安全输入开着时系统快捷键（⌘Tab、⌘空格）既不过拦截也不到面板，退出后还按着的 esc 的连发会落进前台 App。左右两个同名修饰键都按着、松开一个时会多算一次触碰。清洁时碰到大写锁定键，退出后大写锁定可能是开着的（没做还原）。触发角设了动作的，鼠标挪到角上照样触发（盖在面板下面）。主线程彻底卡死时系统会放行输入，但熄屏 / 告示样式的面板还盖着看不见桌面（没有看门狗）。会话本身（进入、退出、锁屏那一套）没有自动化覆盖：它要真建拦截和窗口，只有 `ExitHold`、`InputBlock.classify`、`StatusPreset.sanitized` 这些纯函数有单测。
- **第二张拍板页（2026-10-10 傍晚，用户装上 0.4.0 测试包后提的两件事；https://claude.ai/artifact/W9SHBbMgvbHnJEy7x9Mv3Z ，回「全部按推荐」）**：⑬ 按全局快捷键时先出一排预览卡片，选一个再进（←→ / 数字键 / ↩ / Esc；默认选中上次用的；设置里一个开关可改回「直接进入排在最前面的」，默认关）。⑭ 选中的卡片放大成整屏。⑮ 告示的图标改用现成的动画表情——用户嫌我手画的动画「太粗糙」，要我去网上找现成的：选了 **Microsoft Fluent Emoji Animated**（github.com/microsoft/fluentui-emoji-animated，MIT，746 个，动画 PNG 256 像素；Google Noto 那套许可没从官方核实到、缺 Zzz 和黑猫，LottieFiles 要加播放库、和零依赖冲突）；清单 16 个（用户确认过）：举手、挥手、发光的星、闹钟、沙漏、热饮、Zzz、睡觉脸、嘘、人影、电话、火箭、机器人、火、闪电、黑猫，另加被碰时用的眼睛。⑯ 进场：表情落下弹一下、标题逐字浮现。⑰ 有人碰键盘鼠标时：标题晃、表情甩一下、屏幕底边冒出一双眼睛看一眼（熄屏样式不冒）。⑱ 设置里一个总开关「告示上的动画」，默认开；系统的「减弱动态效果」打开时一律静止。
- 表情怎么播（2026-10-10 独立小程序实测）：macOS 15 的 ImageIO 能直接解动画 PNG 和动画 WebP 的每一帧；边解边播（`CGAnimateImageAtURLWithBlock`）动画 PNG 4.1% CPU、WebP 29.9%，不能挂几小时；**进入时一次解完、`CAKeyframeAnimation` 按帧换图层的 contents：0.02–1.2% CPU**，内存多 18–38 MB、退出即还。原文件每个 0.8–2.8 MB（17 个共 29 MB，不进仓库），用 `macos/status-emoji.swift` 转成 HEICS（HEVC 图像序列，带透明通道，ImageIO 能写能读，256 像素不缩放）后 0.2–0.5 MB、17 个共 6 MB。对照：系统的符号动效持续播放 SwiftUI 2.0–5.0%、AppKit 1.4–2.9%，只动变换的图层动画 0.07–0.15%——所以要挂几小时的一律走图层，符号动效只用在一下子播完的地方。
- 做的时候定的（第 4 批选状态，没另问）：面板是一块 `OverlayPanel`（Panel 皮肤，`TransientPanel` 拿着：用时再建、收起后放掉），出现在鼠标所在屏中央，和剪贴板面板、启动器互斥；一行最多 4 张卡片，多了折行、放不下滚动；底栏照启动器的写法（动词在前、键帽在后）：「选择 ←→」「直接进入 1–9」「取消 Esc」「进入 ↩」；↑↓ 到头不回绕、←→ 和 Tab 回绕；面板开着再按一次快捷键 = 下一张（不是 key 时先把键盘拿回来）；只有 1 个状态也照样出面板；「上次进入的」记在 `statusScreenLastPreset`（不注册默认值，不跟导出走），菜单栏、启动器进的也算；快捷键页和速查表那一行关着叫「选一个状态进入」、开着叫「进入排在最前面的状态」；菜单栏子菜单关着时最上面多一行「选择状态…」带快捷键、各状态不带键位，开着时第一个状态带键位；启动器里第一个状态行的键帽也只在开着时显示。放大只动内容图层的变换和圆角（窗口一直是整屏、期间透明，`StatusScreenPanel.grow`），`StatusScreen.enter` 里各步的顺序没动。
- 做的时候定的（第 5 批动画表情，没另问）：`StatusPreset.symbol` 的键不变、含义从系统符号名改成表情 id，`sanitized` 里把测试包存过的旧符号名换过来（对不上的置空）；自带三个用发光的星 / 举手 / 闹钟；会动的只有整屏告示和详情页预览（窗口是 key 时），别处一律静止画面——选状态的卡片最多 20 张，全播要几百 MB；在播时把垫着的静止画面透明度设成 0（不然帧的透明处透出第一帧，会重影）；锁屏时也放帧；眼睛边长 = 标题字号、在退出提示右边、露八成，提示被设置关掉时照冒；动不动在进入那一刻定，会话中途改系统的「减弱动态效果」不影响这一次；设置 › 状态屏一出现就在主线程外预热 16 张静止画面（现解一张约 4.5 ms，格子现解要七八十毫秒）；启动器和菜单栏的状态行选了表情的只画表情、不套家族色块；关于页那行出处后面有个「许可全文」链接；深色的「开会」表情在告示上垫一团亮光（黑底上原本几乎看不见，截图自检里看到的）。逐字浮现用 `TextRenderer`，没给 `displayPadding`（给了屏外截图里标题整体右移 16 pt）：字刚冒头那一瞬模糊的边可能被裁掉一点，真机待看。
- 分批：第 0 批本机实测（上面那条）→ 第 1 批拦截、面板、退出、自带状态、三个入口（高风险：拦错了会把人锁在电脑外面；实现 + 正确性 / 规范两名评审，2026-10-10 完成：全局快捷键也在这一批，因为菜单栏和启动器都按 `HotKeyAction` 分发）→ 第 2 批设置页（状态的增删改排序、预览、导出导入、速查表；低风险：一个实现任务 + 主线程审查，2026-10-10 完成）→ 第 3 批收尾（2026-10-10 完成：防残影——告示那一列每分钟挪几个点，`StatusScreen.drift(minute:)`，横向 ±12、纵向 ±8 以内；界面规则 `mac-whisker-status-screen.mdc`；版本号 0.4.0 和更新日志）。 → 第 4 批按快捷键先选状态（2026-10-10 完成）→ 第 5 批动画表情、进场、被碰时的反应、总开关（2026-10-11 完成）。
- **第三轮（2026-10-11，用户装上测试包后又要的两件事，原话：「倒计时时间改成加入秒，然后期望时间过度有动画效果」「期望还可以加入密码，设置了密码就必须输入密码才能解锁」；没出拍板页，直接做的）**：⑲ 告示上的小字精确到秒、变了的数字滚过去。**滚动不用 SwiftUI 的 `numericText`**：独立小程序实测（19 pt 的这一行、每秒换一次、只算本进程）它占 9–15% CPU（13 pt 约 7%，每 5 秒一次 1.6%），逐字 `.transition(.push)` 1.6–2.4%，`.contentTransition(.opacity)` 0.9%，`.interpolate` 3.3%，只换字不做动画 0.2–0.3%；自己排的图层版（当时在 `StatusScreen/StatusTicker.swift`，现在是 `Shell/Ticker.swift`：一字一块 CoreText 位图，只给变了的数字加滑动和淡入淡出的图层动画）0.5%，用它。录制 HUD 的计时（13 pt、numericText）按这个数录制时一直占着约 7%，没在这一轮改，同一天另改了（下面「录制 HUD 的计时」）。⑳ **退出密码**——推翻 ② 的「不做退出验证」。当初不做的理由是「验证出问题时键盘鼠标都被拦着，只能强制关机」，现在的出路：解锁即结束（⑨）不变，忘了密码、输不进去都可以锁定屏幕再解锁出来；钥匙串读不到就当没设。规矩在 mac-overlay-panel §11「退出密码」，样子在 `mac-whisker-status-screen.mdc`。
- **第四轮（2026-10-12，用户原话：「期望这个效果不是点击鼠标或者按下按键才触发，期望能随机出现在屏幕的四个任何区域」）**：眼睛改成从屏幕四条边里随机的一处探出来（顶边倒着、左右横着），没人碰的时候隔 15–45 秒自己冒一次、露 3 秒；有人碰键盘鼠标时照旧也冒（现在也是随机的一处，不再固定在退出提示右边）。用户同一天补了一句「四个边出现的位置也要随机，有可能在中间，有可能在最边上」：沿着边整条都随机，正中、贴着角都可能。做的时候定的：「四个区域」按四条边做（不是四个角）；只有两种时候让开正中——退出提示正要浮出来的那一次让开底边正中、有带刘海的屏时让开顶边正中（被摄像头挡着）；眼睛垫在退出提示下面；不连着两次同一条边；多块屏同一处；间隔和露多久没做成设置项。样子在 `mac-whisker-status-screen.mdc`「眼睛」，待手测 31。
- 做的时候定的（第三轮，没另问，等用户确认）：小字写成「已 1 小时 23 分 05 秒」（不写成 1:23:05：旁边就是「14:02 开始」，会被读成钟点），前面有更大的单位时补两位、宽度不跳；**定了自动结束的状态小字改成倒数**「还剩 4 分 32 秒」（用户说的是「倒计时」，原来没有真的倒数）；熄屏样式什么都不显示、定时器仍然每分钟一下；数字滚动跟「告示上的动画」开关和减弱动态效果走。**密码只收 4–8 位数字、按键位认**（不看输入法和键盘布局，理由在规则里）；一个全局的密码，不分状态；设置里填两遍、存钥匙串、不跟导出和备份走；按住满两秒才出密码框（猫踩键盘、擦键盘不会把它弄出来），打满位数当场比、不用按 ↩；每错满 5 次收起、10 秒不按收起；到时间自动结束、解锁回来不问密码；改和移除密码不用输旧的；没做屏幕上的数字键盘（键盘坏了就锁屏再解锁）；没给密码框开安全输入。界面里叫「退出密码」，仍然不写「锁」。

**录制 HUD 的计时（2026-10-11）**
- 起因：计时（13 pt 圆体 semibold + 等宽数字）原来每秒 `.contentTransition(.numericText)` 滚一次，录屏 / 录音期间一直占着 CPU，还可能影响录制本身。
- 实测（独立小程序，不启动 Dev 版：屏幕右下角一小块 HUD 样子的窗口、里面就这一行、每秒换一次，只算本进程，M3 Air，每次量 30 秒；程序留在 `macos/build/research/ticker-cpu/`，不进仓库）：numericText 8.2–11.0%（从 0:00 起、从 1:00:00 起各两次）；同一个 Text 只换字不做动画 0.23–0.36%；图层版 0.19–0.27%（改之前的 `StatusTickerView`）、0.21–0.23%（现在的 `TickerView`）；只有窗口和定时器 0.01%。
- 改法：计时不再是 SwiftUI——`RecordingHUD` 里直接放一个 `TickerView`（AppKit 视图，不经宿主视图），按 h:mm:ss 的宽度给约束（字靠左，一小时起变长不跳）；每秒只换变了的那几位、往上滚；录音暂停 / 继续换颜色，整行重排、不滚；减弱动态效果时 `direction` 给 0，直接换；读数不进旁白（HUD 自己有值）。窗口行为没动。倒数的数字（只有三五秒，每跳一下 pop）还是 SwiftUI。
- 图层视图从 `StatusScreen/StatusTicker.swift` 挪到 `Shell/Ticker.swift`，改名 `Ticker`（SwiftUI 里用）/ `TickerView`，状态屏的小字和录制 HUD 的计时共用。画法改了两点，状态屏的小字跟着变：① **整行交给 CoreText 排一次、按字切开**（每块是整行里这个字占的那一段，按像素对齐、互不重叠；原来一个字一个字单独排）——夹在数字中间的冒号是另一个字形（抬高 1.4 pt），单独排拿不到，「0:12」「14:02」的冒号会比普通的 Text 低；各字的位置有变（字数变了、数字不等宽）就整行重排。② **基线离顶 = 字体上行高度四舍五入到整点**——SwiftUI 的 Text 的摆法（系统字体 10–30 pt 逐个量过都对得上）；原来用字体的下行高度，13 pt、16 pt 的字都比 Text 低 1 个像素。
- 验过的：截图自检 `ScreenshotSnapshotTests/renderRecordingHUD()` 改前改后逐像素比——倒数、待录的 5 张完全一样；带计时的 12 张 HUD 尺寸不变，只有计时那一块有差，最大差 1/255（90–104 个像素，是颜色取整）。`SnapshotProbeTests/statusScreen()` 里图层版的小字和 Text 版竖直对齐了（原来低 1 个像素），水平还差约 0.2 个像素（居中时取整不同，没追）。单测：`StatusScreenTests.tickerRollsOnlyChangedDigits` / `tickerCellsTileTheWholeLine`（各块拼起来和整行一次画出来一样）、`RecordingHUDTests.clockRollsOnlyChangedDigits`。
- 没动的：菜单栏停止项的计时是状态栏按钮的标题，直接换、本来就不滚；长截图的高度、设置里的字号、列表条数这些偶尔才变的数字还是 numericText（mac-whisker §8）。
- 没验的：真机上滚动的样子、录制期间活动监视器里的 CPU（`HANDTEST.md`「录屏 / 录音手测」68）。


**视觉对齐（2026-10-12，0.4.0）**
- 背景：用户原话「目前系统所有的界面都需要做一个视觉对其」。理解成全 App 的对齐和一致性走查：该在一条线上的有没有对上、同一种东西长得一不一样、值在不在刻度上。
- 走查：整套截图自检跑一次（591 张），四个只读子任务分族看图加量像素（面板 / 翻译 / 截图与录制 / 设置及其它），交回 73 条，归并成 33 项出拍板页 https://claude.ai/artifact/Ftr8zDprnRrGkXLKVhUVRF ，用户回「全部按推荐」。四份走查结果（带文件:行和量到的数）、各批的说明、改前改后的图都在 `macos/build/visual-audit/`（不进仓库）。
- 定下来的（真要选的五项）：同一个 ⌘K 菜单全 App 叫「操作」（速查表里指菜单本身时叫「操作菜单」；代码和规则里的部件名「动作菜单」不改，已发布的更新日志不改）；主按钮 `BrandButtonStyle` 常规档高 20、和系统按钮等高；键帽 10.5 pt / 左右 5、键帽之间 3 是刻度的例外，不动；录屏和录音的控制条各状态按**右边线**对齐（✕ 和主圆钮不动、只往左长）；计时按当前位数留宽。
- 五批，一批一个提交：① `fdcb36ed` 共用件和叫法（`Shell/SearchLine.swift` 搜索线、面板底栏内缩 16 / 选状态 20、`EmptyState`、`floatingShadow()`、底栏成功提示白勾）② `4fd1aa8a` 剪贴板和启动器（行右缘、⌘Y 大卡边线 12、文件透镜靠左、对话框字号和键位提示、`Style.swatchRim` / `listPanelWidth`）③ `2cac17d8` 翻译和刘海岛（原文框占位和文字重合、错误卡图标格、`CardActions`、岛的语气符号一律圆底 `Island.hasPlate`）④ `c0ce4c8d` 截图和录制（`RecordingHUD.origin` / `x` 右边线摆位、防误触从 ⏸ 换到 ■ 的 `ignoresStop`、长截图面板、开关关态单色、卡片标记、`Style.Shot` / `Style.HUD.keyFont`）⑤ `ad4ef4c5` 设置（`SectionFootnote`、`pageHeaderInsets()`、行副标题 11 pt、控件大小、文案规矩、深色表情垫底 `StatusEmoji.plated`）。每批：一个实现任务改，主会话看 diff 和前后截图、重跑 lint 和全量单测后提交；单测 709 → 721。改过的值都写回了各份 `mac-whisker*` 规则，核心 §3 新增「面板里共用的几件」，设置规则新增「设置页的说明文字」。
- 顺带查清 / 修掉的：贴着裁切区的层级色文字在屏外截图里发白是假象，真机正常（规则 §9）；长截图面板的按钮行偶发整行左移 14.5 pt 是真的布局歧义（横向抱紧优先级太低），已修并有单测。
- 做的时候定的（没另问）：成功 / 警告提示的字用 secondary（两块面板深浅一致）；「翻译 ↩」离原文框右、下各 8，不并到 395 那条线；音量的岛只分静音 / 有声两种带圆底的喇叭；录屏不倒数时 ■ 同样有保护；拖过的控制条位置改记右下角；钉图百分比内边距 12（字到边和尺寸胶囊一样）；⌘Y 正文块上下也是 12、图片大卡窗口宽高各 +4；设置路径写成「设置 › 快捷键」不加引号；引导行标题用 medium；E5 新加的三行标题和说明是实现时拟的。
- 看过、定了不动的：快捷键页色块 20（别处 24）；截图工具栏悬停底圆角 6 对当前工具底块 12；启动器空结果一行字；剪贴板的中性种类图标；卡片右上角按钮没有悬停效果（新交互，另说）；菜单栏菜单里实心 / 线框图标混用（没有截图，先补截图再定）；状态屏整屏量过没有要改的。
- 截图自检加了 `TEST_RUNNER_KITTY_SNAPSHOT_ONLY=前缀,前缀`（`ea5a1370`）：只出文件名以这些前缀开头的图，renderPanels 从七八分钟降到十几秒到几分钟；只改一族界面时用它。
- 没验的：全部是屏外截图和单测，真机一次没看；录屏 / 录音的实录自检没跑。手测在 `HANDTEST.md`「视觉对齐手测」1–20。
**便签（2026-10-12 立项，0.5.0）**
- 背景：用户给了 github.com/aimen08/noty（屏幕边缘的便签，原生 macOS，Swift + SwiftUI + AppKit，MIT），要把完整功能迁进来，定了放进 Kitty 当第七族。源码读过（`2a1a81d`：38 个文件 12,523 行，测试 2,218；编辑器与图片 3,389、边缘那叠与浮动便签 2,384、数据 978、同步 907、设置与快捷键 1,212）。同类只看了通行做法：系统「便笺」（置顶、半透明、折叠、第一行当标题）、SideNotes（贴边，热边 / 快捷键 / 菜单栏唤出，隐藏 Markdown 标记，全屏里也能用）、Raycast Notes（浮动窗口、快捷键、Markdown、删掉的留 60 天）。拍板页 https://claude.ai/artifact/VHHy2dsV5L3KjyYunQTNg6 （25 项 A1–F2，另有逐项对照表），用户回「便签：全部按推荐。开始前先发布 0.4.0」。调研材料在 `macos/build/research/noty/`（不进仓库）：`report-editor.md`、`report-data-sync.md` 两份深读报告（带 文件:行号，接手先读）、`probe/edge-probe.swift` 测量小程序、`src/` Noty 源码（只读；**别跑它的脚本和测试**——它的测试会把真实的图片目录当孤儿清空）、拍板页的生成脚本。Noty 是 MIT：只借思路和数值自己重写，许可声明随包、关于页写一行出处（mac-whisker §11）。
- 拍板（A 定位）：① 叫「便签」。② 管「留着看、接着改」的东西（待办、备忘、草稿）；和片段（反复粘贴的文字）、收藏（留下的剪贴板条目）、钉图（临时对照的图）各存各的、不合并，靠操作互转。③ 0.4.0 发布后开工，作为 0.5.0。
- 拍板（B 边缘那叠）：① **有了第一条便签才出现**（第一次出现时刘海岛说一句在哪），设置里有总开关，**关掉不建窗口**，便签照样能用快捷键、启动器、全部便签窗口。② 默认右边、只在主显示器；左 / 右、全部 / 主屏 / 指定屏、按住 ⌥ 拖药丸换边换高度换屏都有；两块屏相接的那条边不放、自动换到外侧。③ 默认不盖在全屏 App 上，设置里可开；快速记一条同别的面板，全屏里也能呼出。④ 扇出的标签 4 秒不碰收回；**打开的便签不按时间自己收**（Noty 是 1 分钟），点别处才收，固定后点别处也不收。⑤ 新增两个自建窗口的例外（边缘那叠、浮动便签），都不激活本 App；快速记一条用 `OverlayPanel`；全部便签是普通窗口、和设置窗同一套打开方式。⑥ 药丸算装饰（截图、录屏都不收），打开着的便签和浮动便签算内容（截图冻结帧里有、能悬停选中，录屏白名单里有，同钉图）；框选、长截图、选录屏区域时边缘不响应鼠标；进状态屏前先落盘、收起那叠。
- 拍板（C 便签本身）：① 编辑器三步都做、分三批，每步做完都能用：纯文本 + 任务 → Markdown 边打边变样 → 行内图片（先不带裁切、宽度预设、工具条）；图片可以晚一个小版本。② 浮动便签一次一张（同 Noty），固定着的那张重启后回到原处；同时浮多张以后再说。③ 8 种纸色照搬、深色外观另调一套；默认系统字体、设置里可换；形状、阴影、动效按 Whisker 重画，另写 `mac-whisker-notes.mdc`；家族色黄。④ 文字方向菜单不做。
- 拍板（D 数据）：① **单独的库和图片目录**，剪贴板的清理、保留天数、锁屏清空、「重新开始」都碰不到；便签库打不开时单独处理。② **正文不加密**（同剪贴板，靠系统的磁盘加密；Noty 的密钥是库旁边的文件，防不了能读到库的人，放钥匙串则换签名 / 换机 / 从备份恢复时一丢全丢）。③ 归档照搬；**删除进「最近删除」留 30 天**，刚删时刘海岛给「撤销」。④ 便签库每天备份（连图片，留 7 份）；便签文字并进导出文件和每日 JSON 备份当第七类；设置 › 便签另有「导出为 Markdown 文件夹」和「导入」（文件头带编号、颜色、日期，原样导回不重复）。⑤ **iCloud 同步这一版不做**，以后单独立项；模型先留好稳定编号、修订号、删除记录。
- 拍板（E 打通）：① 三个动作进启动器；关键词 `note`：空着列最近的，带关键词搜标题和正文，↩ 打开，⌘↩ 把后面那段话存成新便签；不进默认搜索结果。**2026-10-17 用户去掉**（第 8 批不做）。② 开着便签时从剪贴板面板 / 启动器粘贴要落进便签；点 Kitty 自己的面板不算点别处；剪贴板 ⌘K 加「存成便签」——**粘贴落进便签 2026-10-17 做了（第 8 批 R12），剪贴板 ⌘K「存成便签」用户去掉**。③ 常驻缩略图的菜单加「存成便签」，跟图片那一批——**2026-10-17 用户去掉**。④ 焦点在便签里时划词翻译读便签自己的选区——**2026-10-17 做了（第 8 批 R13）**。⑤ 给别的工具调用的链接（URL scheme）不做。
- 拍板（F 入口）：① 全局键只有「快速记一条」有默认键 ⌥N；「新建便签」「全部便签」不设默认键；归档并进全部便签窗口。② 设置加一页「便签」；快捷键页、速查表、菜单栏、启动器各加「便签」一节，三项同名同序；便签里的按键固定（⌘K 操作、⌘P 固定、⌘T 任务、⌘F 查找、⌘⌫ 删除、Esc / ⌘W 关），不做成可改。
- 不做 / 以后再说：Sparkle、Intel 版、Homebrew、多语言不做；txt 导出、合成一个文档、Noty 的归档格式不做。以后再说：自定义纸色和「常用」颜色（2026-10-13 用户提了又说「暂时不做，后面再说」；当时的设想：`color` 整数里另编一段表示 sRGB 色值、由选的颜色推出纸 / 色条 / 墨、系统取色面板、最近选过的 8 个记成常用）、iCloud 同步、同时浮多张、图片裁切和宽度预设、表格 / 有序列表的样式（Noty 也没有）、分隔线、裸网址自动成链接、引用嵌套（代码块和 ⌘B / ⌘I 这类加标记的快捷键第 6 批定成不做，2026-10-15 手测反馈第 4 批做了）、斜杠菜单、自动补全成对的符号、代码的语法高亮、⌘K 当链接键（⌘K 是操作菜单；后四样是手测反馈第 4 批定成不做的）、翻译和识字结果「存成便签」、便签选中文字「存成片段」、「只待在一个桌面」、从 Noty 导入它的归档；把便签里的图片拖到别的 App 成文件、在便签里按住图片挪位置、点开看大图、动图播放（只显示第一帧）、图片说明文字（第 7 批定成不做，图片的工具条 / 裁切 / 宽度预设见上面「图片裁切和宽度预设」）；启动器 `note` 关键词、剪贴板 ⌘K「存成便签」、常驻缩略图「存成便签」（2026-10-17 用户在第 8 批去掉）、文字颜色的快捷键和 ⌘K 入口、任意颜色（取色板）、高亮底色、字号 / 字体、任务状态的快捷键 / 截止日期 / 按状态筛选和排序、导出成一个合起来的文档 / txt / PDF、导入时进子文件夹 / wiki 式 `![[图]]` / 联网下载图片、导出时自动打开访达（第 8 批）；标题 4–6 级的菜单项（能手打）、多选几条一起导出、拷贝为 Markdown、脚注、下划线、任务以外的勾选框（第 8 批之后的一轮）。
- Noty 怎么做的、我们哪里不照它（读源码确认的，出处在两份报告里）：它每块屏一个面板，平时只有药丸大，鼠标进追踪区就把**同一个窗口**放大成「便签宽 + 22 × 可见区高」再扇出，为此打了几处时序补丁（等两帧、手动同步提交）；点标签时调 `NSApp.activate()`、收起再 `deactivate()`；扇出后每 0.12 s 查一次鼠标位置。我们：边上只留一条**只用图层画**的小窗口（装饰），扇出和便签是**用时再建、收起后放掉**的另一块面板（内容；`TransientPanel` 的路数），永不激活本 App。它的编辑器是显式搭的 TextKit 1（自己的 `NSLayoutManager` 子类把带隐藏属性的字符的字形属性设成 `.null`；普通 `NSTextView` 拿到的是 TextKit 2，这招失效），8 条正则按行重排（会把 `snake_case` 的下划线当斜体、代码里的星号当粗体——我们自己写扫描器）。它的图片不是文本附件：约 55 个字符的隐藏令牌 + 布局代理撑高那一行 + 盖一个视图，只给 4 个方向键和 2 个删除键打了补丁，令牌被改坏图就没了；而且**每次启动把没被正文引用的图片文件全删**（和备份恢复冲突，我们改成跟「最近删除」留 30 天）。它的同步靠时间戳判断变化，同步文件夹在但空了时本机便签整批真删（`SyncPlan.swift:94-102`），一边删一边改不算冲突。
- 实测过的（2026-10-12，独立小程序 `probe/edge-probe.swift`，M3 Air 一块 2 倍屏，窗口真摆在屏幕右边缘）：已加载过 SwiftUI 的进程里再建一条 SwiftUI 宿主的药丸窗口 +0.2–0.3 MB / 屏，只用图层画约 +0；静置 CPU 0.01%（只挂进出追踪区、没有定时器）；扇出成一列标签再 +1.6 MB，每 0.12 s 查鼠标 0.045% CPU；打开一张 460 × 380 的 `NSTextView` 便签 +4.7 MB（含文本系统首次加载）。常驻开销可以忽略。
- 做法（数据，第 1 批照这个写）：数据目录里 `notes.sqlite3`（WAL，`PRAGMA user_version` 记版本，从 1 起）、`notes-images/`（第 7 批起）、`notes-backups/`（每天一个文件夹 `notes-YYYY-MM-DD/`，里面是 `VACUUM INTO` 出来的库和克隆的图片目录，留 7 份）——都不在剪贴板的 `Recovery.setAside` 名单里。表 `notes`：`id TEXT PRIMARY KEY`（UUID）、`title`（自己起的标题，空 = 取正文第一行）、`body`、`color`、`created_at` / `modified_at`（整数毫秒）、`revision`（每次改动 +1）、`archived`、`pinned`、`sort_order REAL`、`deleted_at`（非空 = 在最近删除里）。`NoteStore` 在主线程、全量读进内存、搜索在内存里做；改正文先改内存再落盘：停手 250 ms 落一次、连续改动满 2 s 必落一次，便签收起 / 失去键盘焦点 / 退出 / 锁屏 / 睡眠 / 更新重启前都显式落盘，写不成的留着重试并提示。每日备份的时机跟现有的 `AppDelegate.backupIfDue` 走（启动、换日、锁屏），另开只读连接、先 `quick_check`、坏库不备也不动已有备份，轮换用 `Backup.expired`。打不开时问用户：用最近的备份 / 重新开始 / 这次先不用便签（别的功能照常）；前两种先把出问题的文件挪进 `damaged-…/`。导出文件加第七类「便签」（只带文字，不带图片和最近删除里的；导入按编号合并，本机没有的加进来，两边都有的留修改时间新的，本机独有的不动；`currentFormat` 升一级）。
- 已知取舍（便签的备份，2026-10-12 评审时记下）：① 便签全删光之后不再备份（空表不备），旧备份不再轮换、一直留着。② 永久删除的便签在 `notes-backups/` 里最多还留 7 份（不是每天都开就更久），在每日 JSON 备份里同理。③ 便签连续 7 天不可用（每次都选「这次先不用」、或者一直是更新版本写的库）时，带便签的每日 JSON 会被不带的顶光——这期间 `notes-backups/` 不动，数据还在。

- 分批（一批一个提交；高风险 = 实现 + 两名评审，低风险 = 一个实现任务 + 主会话审查；**已全部做完**，原来的分批顺序和每批的做法在 `docs/archive/PLAN-notes.md` 开头）：0 实测与做法 → 1 数据层 → 2 能用起来 → 3 边缘那叠 → 4 浮动便签 → 5 编辑器、任务、查找、撤销 → 6 Markdown → 7 行内图片 → 8 打通和 Markdown 导出导入 → 9 收尾。
- 各批一行摘要（做了什么 + 提交号 + `HANDTEST.md`「便签手测」的编号；详细实现、量到的数和评审记录都在 `docs/archive/PLAN-notes.md`）：
  - 0 实测与做法（`3176e649`）：药丸用图层画、那叠两块窗口、不激活本 App 的面板里打字、粘贴不靠合成按键，全部按不依赖真实鼠标键盘的写法定下。
  - 1 数据层（`44f3f399`）：单独的库、最近删除留 30 天、每日备份留 7 份和打不开时的恢复、导出文件第七类；手测 1–9。
  - 2 能用起来（`7422a37b`）：⌥N 快速记一条、全部便签窗口、三个入口、设置 › 便签；手测 10–38。
  - 3 边缘那叠（`62580bb8`，手测反馈第 1 批 `91c916b8`）：药丸、扇出的标签、从边缘滑出来的便签、右键菜单、设置「屏幕边缘」；手测 39–86。
  - 4 浮动便签（`cc896121`）：拖出来留一张、拉大小、固定后重启回原位，和那叠共用 `NoteSheet`；手测 137–162。
  - 5 编辑器（`07db034e`）：专用 `NoteTextView`（显式搭的 TextKit 1）、任务、便签内查找、撤销重做；手测 87–106。
  - 6 Markdown（`de7f7621`）：不用正则的扫描器、标记零宽藏起、只在光标所在行露出；手测 107–136。
  - 7 行内图片（`7d1622c2`，评审 `ee0e2297`、复查 `74283aac`）：图片令牌和附件字符、宽度、缩略图、30 天清理；手测 218–239。
  - 8 打通与导出导入（`bb87a03d`，评审 `0ee65b0e`）：文字颜色、任务五种状态、Markdown 文件夹导出导入、从剪贴板 / 启动器粘贴落进便签、划词翻译读便签选区；手测 240–253。
  - 8 之后的一轮（`47f7a57e`、`9e72da0c`、`1c808ead`）：单条导出、右键「格式」补全、格式合并、一行两张图导出闪退；手测 254–257。
  - 手测反馈各轮：`f4d439cc`（163–171，滚动条、切换、设置入口、默认倾斜、右键）、`3142de43`（172–184，行距、代码块、⌘B / ⌘I / ⇧⌘X / ⌘E、粘贴网址成链接）、`e5130a46` + `83c6cd15`（185–206，便签墙和它的性能）、`ff9524bf`（207–217，便签墙 16 处、浮动层级、长便签切换）。
- 仍然生效的约定（不在这一节重复）：便签库、图片、备份和剪贴板互不相干在 mac-clipboard §1；那叠和浮动的窗口、焦点、键盘、截图 / 录屏里各算什么在 mac-overlay-panel §12；正文编辑器、Markdown、任务、颜色、行内图片、导出导入在 mac-overlay-panel §3 §5；长相和交互在 `mac-whisker-notes.mdc`；划词读便签选区在 mac-translate §5。

**ponytail（便签这一族里刻意留下的简化和上限，升级路径都写在原注释里）**

| 位置 | 简化 / 上限 |
|---|---|
| `Notes/Note.swift` | 正文上限由编辑器 / 快速记一条 / 导入各自先拦，仓库自己不拦；标题和摘要认代码块只看开头 `blockScanLimit` 个字 |
| `Notes/NoteStyles.swift` | 露着标记的那一行每次整篇过一遍属性（1.2 MB 量过，每挪一次光标约 31 ms） |
| `Notes/NoteTextView.swift` | 连续排版（不开 non-contiguous）；组字中超出上限整段退回、撤销栈清空；软换行 U+2028 / U+0085 不处理；查找条聚焦时正文标记全藏，搜到藏在标记里的字可能看不见高亮 |
| `Notes/NoteTextView+Images.swift` | 复制图片时转 PNG 在主线程做（用户主动复制一张，几十毫秒） |
| `Notes/NoteImageAttachment.swift` | 动图只显示第一帧；代码块里的图片令牌也显示成图，不能按原文 |
| `Notes/NoteImageStore.swift` | 清理时在主线程列一遍目录、逐个解 UUID（几千张以内） |
| `Notes/NoteMarkdown.swift` | 强调的定界没照 CommonMark（紧挨着的标记按就近配对）；链接地址长度封顶；找收尾围栏是线性扫 |
| `Notes/NoteMarkdownFiles.swift` | 导出文件名截到 80 个字 / 200 字节，不按文件系统的 255 字节；代码块里的图片令牌导出时不带文件 |
| `Notes/NoteCapture.swift` | 面板高度是估的（系统一直显示滚动条时文本框窄 15 pt，可能早折一行） |
| `Notes/NoteDeckView.swift` / `NoteDeckModel.swift` | 一次画全部标签，拖到视口外不自动滚；「+N」展开滚过之后卡片按没滚时的位置摆 |
| `Notes/NoteDeckOptions.swift` | 显示器用 `localizedName`，同型号第二块起加序号 |
| `Notes/NoteDeck.swift` | 只认输入法组字；表情与符号面板不算，点了会把没固定的便签收掉 |
| `Notes/NoteSheetModel.swift` | 操作菜单不能打字过滤（7 项 + 8 种颜色，方向键够用） |
| `Notes/NoteStore.swift` | 视图每次访问都现筛现排、搜索每次把正文现折叠一遍（几百条毫秒级） |
| `Notes/NotesBackup.swift` | 和 `Storage/Backup.swift` 是平行的两份；图片靠 APFS 克隆，数据目录在别的文件系统上就是真拷贝、七份备份占七倍 |
| `Notes/NoteWall.swift` | 墙卡片上不画引用的竖线和代码块的圆角底，只一眼看个大概 |
| `Shell/OverlayPanel.swift` | 关闭淡出用窗口帧动画；浮层里的「拷贝」不经 `Paster`；`saveFrame` 只存当前帧 |
| `Shell/Paster.swift` | 按物理键位发 V，Dvorak 这类布局下会变成别的键 |

**便签的四个新功能（2026-10-22 开工，进 0.6.0）**
- 来由：设置 › 关于「未来计划」里的四条新功能（iCloud 同步、自定义纸色、同时浮几张、图片裁切和宽度档位）。调研在主检出 `macos/build/research/notes-roadmap-2026-10-19/`（`icloud.md`、`three-features.md`、纸色推导的原型 `three-features-proto/`），拍板页 https://claude.ai/artifact/7GJvFLf6Q5UBxQaxJL45JM（19 项，生成脚本 `build-decisions.py`），交接 `HANDOFF-features.md`。用户 2026-10-22：**19 项全部按推荐，唯一的改动是 E1——直接进 0.6.0**（推荐写的是 0.7.0；0.6.0 还没发布，版本号不改）。在检出 `kitty-tools-macos-roadmap`（分支 `roadmap-wip`）里一批一个提交，评审过 rebase main、ff 并回 main。
- 拍板（A 同步）：① **同步文件夹**，不走 CloudKit（团队没付费会员；CloudKit 要入会、换 Developer ID 签名、公证，所有用户要重给一遍授权）；数据准备（状态改动时间、同步账本、完整的电脑编号、永久删除的记录、三方合并的纯函数）两条路共用，以后入会只换执行层。② 默认关，设置 › 便签 加一节「同步」：选文件夹、看状态（上次同步、为什么没同步）、立即同步、关掉。③ 只有两边都改过才算冲突：后改的赢，输的那版另存进「最近删除」，刘海岛说一句；只有一边改过直接换、不留旧版。④ 一边删一边改：留后改的内容、照旧在「最近删除」里；永久删除也传（墓碑），对面那条要在「最近删除」里、之后没再改过才真删。⑤ 一轮要放进「最近删除」的超过 20 条或三成就停下来问；文件夹里放标记文件，读到才算「是那个文件夹、列表是真的」，列目录出错整轮放弃。
- 拍板（B 自定义纸色）：① **分开存**：`color` 写「最接近的预设」，另记一个色值（库加一列、导出文件加一个可选字段），表结构版本和导出格式都不升——0.5.0 看到的是最接近的那种，改正文不碰新的那一列。② 挑的颜色就是浅色外观的纸，太深才提亮到刚好合格；色条、墨、深色那套按感知亮度（OKLCH）推，增强对比度那一档自动跟上。③ 颜色菜单末尾「其他颜色…」打开系统取色面板，边拖边变。④ 最近用过记 8 个（这台电脑的偏好，不跟导出走），颜色菜单里预设后面一节；⌘. 和新建便签的轮换只在 8 种预设里。
- 拍板（C 同时浮几张）：① 最多 5 张，再浮一张时最久没碰的那张收回边缘（刘海岛说是哪张）。② 按菜单浮出来的和已经浮着的错开 24 点往右下，出了屏幕回到第一行再往下一行；拖出来的不动。③ Esc / ⌘W 只收当前那张，键盘还给原来的 App、不跳到另一张。④ 固定着的每一张重启后都回原处（都不当键盘焦点）；「全部收回」先不做。
- 拍板（D 图片）：① 裁切**另存一张新图**（新编号；令牌写法一个字不改，0.5.0、导出、复制、备份都不用动，⌘Z 回原图，原图按老规矩没人用 30 天才删）。② 裁切在这条便签上盖一层裁切视图（同一扇窗口，不另开、不碰激活）。③ 宽度五档：小 120 / 中 240 / 大 360 / 铺满（存上限 4000）/ 原始大小（不记宽度），现在是哪档打勾，选中几张一起改、一步撤销。④ 右键点在图片上弹图片自己的小菜单：宽度五档、裁切…、拷贝。
- 拍板（E）：① 都进 0.6.0。② 顺序 图片宽度档位 → 自定义纸色 → 同时浮几张 → 图片裁切 → 同步，一批一个提交。
- 不做 / 以后再说：CloudKit；几张浮动便签之间轮换的快捷键；「全部收回边缘」；新插的图默认用哪档宽度；裁成圆形、滤镜、旋转；iPhone / iPad 版。
- 各批一行摘要（`HANDTEST.md`「便签手测」接着 269 往下编）：
  - 1 图片宽度档位：右键点在图片上（或选区正好一张图时 ⌃↩）只弹图片自己的小菜单——「宽度」一节五档（`NoteImages.WidthPreset`，现在那档打勾，几张不同档时不勾）+ 拷贝（裁切… 第 6 批再放）；点的那张在选区里就改选区里的每一张，不在就把选区换成它；几张一起改一步撤销、选区不变（`NoteTextView.setImageWidth`，走现成的 `replaceImageWidth`）。只读、组字中不弹。手测 270–272。
  - 2 自定义纸色的数据和推导（界面不变，取色入口是第 3 批）：内存里 `Note.color` 还是一个整数，自定义的写成 `Note.customColor | 0xRRGGBB`；**落盘拆成两样**——库的 `color` 列写最接近的那种预设（`Note.storedPreset`，按推出来的浅纸在 OKLab 里的距离），色值进新加的可空列 `tint`（打开时没有就 `ALTER TABLE ADD COLUMN`，**user_version 不升**：规矩改成「只加可空的列、旧版本读写都写明列名碰不到它时不升；改含义才升」）；导出文件的 `NoteEntry` 加可选的 `tint`「#RRGGBB」、Markdown 文件头加一行 `tint: "#RRGGBB"`，`currentFormat` 不升。库的 `tint` 列存「写入时的预设 << 24 | 色值」，读回来 `Note.color(stored:tint:)` **只比这两个数**（评审后改的：原来靠重算「最接近的预设」去对，以后调推导参数会让一部分已存的自定义色对不上、悄悄丢掉）——对不上说明 0.5.0 换过颜色，按它换的，打开时把这几条记成没落盘、下一次落盘清掉留着的色值（免得 0.5.0 再换回来时自定义色「活」过来）；文件里的 tint 只有新版本写，合法就认。推导 `NotePaper.derived(rgb:)` 照原型 derive2.py（OKLCH；挑的就是浅纸，太深才提亮），按色值缓存；名字「自定义 · 蓝」。直接拿下标取纸的五处改走 `NotePaper.of(color:)`；⌘. 和新建便签的轮换只在预设里（`Note.nextPreset`）。单测 `NoteCustomPaperTests`：网格 8640 种颜色过全部门槛（0.3 s）、8 张预设推回自己、**模拟 0.5.0**（只认原来几列、写明列名的 upsert）读写同一个库：看到最接近的那种、改正文不丢色值、换了颜色按它换的；导出文件和文件头往返。随机编辑探针的换纸色一半换成自定义的；它顺带跑出一个和纸色无关的老毛病：外面换进来的正文里有软换行（U+2028）时，`replaceAll` 带着它排样式，系统把前后两行当一段、段落样式统一成前一行的（围栏行的段前留白落到块里第一行），换进文本存储时才变成 `\n`、这一行就一直错着——改成先换再排（`NoteTextViewTests.softLineBreaksBecomeNewlines` 补了一段）。键盘操作菜单颜色那一级的选中行先停在最接近的预设上。
  - 3 自定义纸色的界面：先写独立小程序验系统取色面板（`macos/build/research/notes-roadmap-2026-10-19/colorpanel-repro/`，LSUIElement 的 .app 用 `open -g` 起，只读状态、不发输入事件）——macOS 27 上从不激活的便签面板里开：请求激活被驳回、取色面板照样出得来，但 `hidesOnDeactivate` 是 true 就马上被藏掉；本 App 没到前台时它当不了 key、硬 `makeKey` 让便签也丢了键盘；程序设 `color` 也会发一次 action。照这三条写了 `Notes/NoteColorPicker.swift`（`hidesOnDeactivate = false`、到前台了才让它当 key、先设色再挂 target；边拖边变走慢落盘 `NoteStore.setColor(live:)`；关掉时落盘、记最近用过、前台和键盘还回去；打开它的那一处换了一条 / 收起 / 关掉时关它）。颜色菜单（`NotePaper.colorItems`，五处共用）加两节：自定义的（这条现在用的 + 最近用过，最多 8 个，`Prefs.notesRecentColors`，这台电脑自己的、不注册默认值）、「其他颜色…」；挑的正好是预设浅纸就存成那种预设（`Note.picked`）；那叠的操作菜单颜色那一级停在打勾的那一行。那叠「点别处」放过 `NSColorPanel`。评审（一名 agent）后改：取色面板会把 `changeColor:` 发给第一响应者、正文框接了会把整篇字染色 → `NoteTextView` 不接；收尾分「用户自己关」（还前台和键盘）和静默收（那一处换了一条 / 收起、别的 App 到了前台、重开）；打开的正是它在改的那条不收；吸管取色那一下那叠晚一拍判断；标签的旁白动作不再白建颜色子菜单。截图自检 `notes()` 加 4 种自定义纸（`notes-markdown-paper-custom-*`）、`notesFloat()` 加 `notes-float-custom-*` 和颜色菜单（增强对比度那一档屏外画不出——AppKit 的动态色看的是系统开关——靠门槛单测锁）。手测 273–276。
  - 4 同时浮几张（结构）：先写独立小程序验几块不激活浮动面板之间的键盘（`multifloat-repro/`）——收掉当 key 的那块，AppKit 把 key 交给另一块、一直不放；`NSApp.deactivate()` 才能让本进程谁都不是 key（`previous.activate()` 没用）。**每张一个 `NoteFloat`**（类基本不动：只管这一张），新的 `Notes/NoteFloats.swift` 管集合：按编号找 / 建 / 放，上限 5 张、再浮一张收回最久没碰的（碰 = 当 key、叫到前面、按把手挪），刘海岛说是哪张；收回拿着键盘的那张后 key 落到另一张浮动便签上、本 App 又不在前台就 `deactivate`；固定着的每一张都记位置（`Prefs.notesFloatPlaces`，旧的 `notesFloatPlace` 读成一条、删掉），重启后都回来、都不当 key。`NoteEdge.float` → `floats`，那叠的 `floatingID` → `floatingIDs`（几条标签各带竖条、点哪条叫哪张到前面），全部便签窗口、AppDelegate（空闲回收留下所有浮着的便签的图、长截图逐张让开）跟着换。评审（一名 agent）后改：`deactivate` 会把还按 NSPanel 默认 `hidesOnDeactivate = true` 的窗口一起收走——退场替身、刘海岛、常驻缩略图、飞卡都改成 `false`；还键盘看「本进程里还有 key 窗口」（key 也可能落到那叠的面板上），那叠里的便签关掉回到那一列时也调；AppKit 自己交过来的 key 不算「碰」；仓库变化时只 reconcile 一遍、写一次偏好。单测：原来「一次一张」的几条改成多张的口径，新加 `severalFloatsUpToTheLimit`、`restoringThePinnedFloats`（几张、旧键迁移、存坏的清掉）、`pinnedFloatsAreRememberedAndReleased`（收回的那张真的放掉、多过上限 / 重复的记录）。手测 277–279。
  - 5 同时浮几张（收尾）：按菜单浮出来的和已经浮着的错开（`NoteFloatLayout.cascaded`，纯函数：左上角和哪张相距不到 8 点就往右下挪 24，出了可见区回到起点那一列往下一行，挪满还挤就用起点；`NoteFloats.present` 把浮着的几张的位置传进 `NoteFloat.present(avoiding:)`；拖出来的不错开）。内存探针（`MemoryProbeTests` 第 6 节末尾，屏外模式）：没图的便签一张张浮出来，每多一张 +0.7–1.4 MB、5 张合计约 1.4 MB（中间一次 IOSurface 回落 4 MB 抵掉了），全部收回后回到浮之前——**屏外的窗口系统不画图层，这个数不含图层存储**；按 mac-native「测量与诊断」的口径估，真上屏每张再多一整块面板的图层（2 倍屏 460 × 380 pt 约 5.6 MB），5 张封顶约 30 MB，静置时没有定时器、CPU ≈ 0；屏上模式（`TEST_RUNNER_KITTY_MEMORY_PROBE_ONSCREEN=1`，会在主屏中间摆几块几乎透明的面板）没跑，要量时再跑。截图自检 `notesFloat()` 加那叠里两条都带竖条的 `notes-float-deck-tab-two`（错开是窗口的位置，屏外出图画不出，靠单测锁）。roadmap.json 拿掉这一条。手测 280。
  - 6 图片裁切：右键图片的小菜单「拷贝」前面加「裁切…」（选区正好一张图、文件在、没在组字、没在裁时可用）→ 正文的滚动区上盖一层 `NoteImageCropView`（`Notes/NoteImageCrop.swift`，同一扇窗口里的视图，不另开、不碰激活；四处的正文框是同一个，一处做完四处都有）：不透明的深底、整张图按这块地方放下、框外压暗，强调色框 + 8 个把手 + 三分线；底下一排比例（自由 / 原比例 / 1:1 / 4:3 / 3:4 / 16:9 / 9:16——竖的两档就是「横竖互换」，用一个弹出菜单而不是分段控件：最小的浮动便签里排得下）、取消、完成。它当第一响应者：↩ 完成、Esc 取消（到不了面板的「关这条便签」）、方向键挪、滚轮吞掉。几何借截图框选的 `RegionSelector.handle` / `resized`（拖边拖角、锁比例、越过对边翻过去），坐标是转正之后的像素、原点左下；新的纯函数只有选比例（整张图里最大的、对着现在的中心，反复换不越换越小）、挪、最小 16 像素、交出去的像素框（四边取整、翻成左上角原点、整张图 = 没裁）。图走正文的缩略图缓存（`NoteImageThumbnails`：正文里那一档先缩放着画，不闪空白）。完成后 `NoteImageStore.crop`（`@concurrent`：转正的整张图上裁、新文件方向 1、DPI 照原图、PNG / JPEG / HEIC 照原格式（有损 0.93）、GIF 和别的存 PNG、20 MB 上限）另存一张新图，回主线程**认目标**（`cropTarget`：还是这条便签、正文框还在窗口里；正文没变看原来那个字，变了同一张图只剩一处才换）再换令牌（`replaceImage`，宽度改那一支也走它；记了宽度的按 `NoteImages.croppedWidth` 换算，铺满照旧铺满），一步撤销、选区照原样（开始裁时选中的就是这张图）。外面换了正文、正文框离开窗口时收起裁切层；全部便签窗口里裁切层拿着键盘时 ⌘⌫ 不删便签。随机探针「改宽度」那一支一半换成「换成另一张图」；截图自检 `notes()` 加 `notes-window-image-crop*`（浅、深、窗口最小），`notesFloat()` 加 `notes-float-crop-min`（最小的浮动便签里底下那一排排得下）。评审（一名 agent，在 scratchpad 里写独立脚本验了几条 AppKit 行为）后改：`NSScrollView` 变大小不带自定义子视图（autoresizingMask、约束都不管用）→ 裁切层自己听 `frameDidChange`；键盘离开裁切层（点标题框、⌘T / ⌘F）→ 当取消（不然字打进藏着的正文、↩ 被「完成」接走）；裁的时候正文框藏起来（它的追踪区会把光标设回箭头）；全部便签窗口的 ⌘Z / ⇧⌘Z 在裁切层拿着键盘时不动（原来会放回删掉的便签）；打开时先 `makeKey`；回来时正在组字就欠着、确认后再换，换完选区照原样；「正文变没变」按开始裁那一刻比；还在后台裁时不能再开；编码 / 写盘失败另说一句（`Rejection.unsaved`）、HEIC / JPEG 编不出来退 PNG；去掉和 `RegionSelector.moved` 重复的那个。手测 281–284。
  - 7 同步的数据准备（两条路共用，界面不变）：先把合并规则推了一遍，没照调研里的「基线」做——基线（上次同步时的样子）在三台以上、或一台钟慢时分不清「看过我这版再改」和「各改各的」，会无声丢字或永远合不到一起；改成**内容的版本钟**（`Note.clock`，每台电脑改过几次内容）：被盖过的直接换、不留旧版，谁都盖不住谁才是两边各改了（A3）——后改的赢，输的另存一条进「最近删除」，编号和字段由那一版推出来（几台存的是同一条）。状态（归档、固定、删除）、顺序各按自己的时刻后改的赢（本机改时只往前走），一边删一边改 = 最新内容在最近删除里（A4）。新文件 `Notes/NoteSync.swift`（纯函数）；`NoteStore`：四列（`state_changed_at`、`clock`、`order_changed_at`、`written_revision`）三表（墓碑 `note_erased`、写进文件夹的修订号 `note_published`——第 8 批去掉了、电脑编号 `note_meta`）都不升 `user_version`（0.5.0 照样读写），改内容钟走一格、改状态 / 顺序记时刻，永久删除 / 清空 / 到期清理留墓碑，导入算本机改动，`applySync` 落一轮合并结果，`recordPublished` / `clearPublished`（第 8 批评审后去掉：每轮读自己的子文件夹直接比，不另记账）；电脑编号跟着库走、硬件编号（`gethostuuid`）对不上就换新的，从备份恢复也换（`NotesBackup` → `NoteStore.forgetDevice`）。评审（一名 agent，独立脚本复现了几种情况）后改：墓碑原来只压「最近删除」里的、记的是删的时刻——删了再清空，一台合盖一个月 / 不用了留下的旧文件夹里那份没删的会把它救回来，还是没删的样子 → 改成记被删那一版的钟和状态时刻，压住它和它的前身、不过期（A4 的「对面要在最近删除里才真删」：那份旧的按状态规则本来也会先进最近删除，合成一步，删了又改 / 放回过的照样压不住）；0.6.0 之前没钟的、0.5.0 改过的行会被有钟的旧版本无声盖掉 → 加 `written_revision`，打开库时认出旧版本动过的行、算本机改一次；从备份恢复后计数退回 → 换电脑编号；整列重排会翻掉别的电脑同时做的删除 → 顺序单独一个时刻；落合并结果前本机又改了会被盖 → `Merge.base` 对不上就跳过；比较时把未来时刻夹成现在会让几台挑出不同赢家 → 按原值比；读进来的次数加上限（再 +1 不溢出）；`gethostuuid` 传 0 秒是一直等 → 最多 1 秒；另存那条只看本机墓碑 → 这一轮读到的也看；合并的修订号只看本机的。单测 `NoteSyncTests`（合并的每条规则、仓库的账、0.5.0 的库和它改过的行、从备份恢复）、随机测试 `NoteSyncFuzzTests`（三台真的仓库 + 一台中途写过一次就不动的、钟各快慢几分钟，随机改删、永久删、互相合；查**不丢字**（谁打过的每一版要么还在、要么有人在它之上改过、要么被永久删了）、安静下来三台一模一样、再合一轮不变；默认 4 个种子 × 300 步，按需加大）。**留给执行层的**：正在编辑（尤其输入法组字中）的那条，合并结果换进来之后编辑器会拿旧底 + 新字整段写回、钟又 +1，把同步来的改动盖掉——执行层要等那条不在编辑时再换；自己子文件夹里某条的 `clock[本机]` 比库里大（时间机器恢复）要换编号；文件写出去之前先落盘。手测 285。
  - 8 同步文件夹的写法和一轮的规划（纯函数，还没碰真的文件夹）：新文件 `Notes/NoteSyncFolder.swift`——根上标记 `kitty-notes-sync.json`（库编号）、`devices/<电脑编号>/notes/<便签编号>.md` + `erased.json` + `device.json`、共用的 `images/`，每台只写自己的子文件夹；便签文件是导出同样的键（「导入…」读得懂）+ 整数毫秒的时间、删除时刻、版本钟，**正文原样**（导出那套换 Markdown、ISO 时间都做不到往返一个字不差）。`round`：标记对不上 / 谁的墓碑读不出来整轮不合，谁的某一条读不出来那一条跳过，数一轮要放进最近删除的条数 → `brakes`（A5：超过 20 条或三成；三成只在至少 5 条时算，替用户定的）；`publish`：要重写 / 删的文件、墓碑文件、两头补齐的图片；`regressed`：认出时间机器恢复了整个数据目录（自己子文件夹里本机那一格的钟比库里大）。`NoteMarkdownFiles.iso` / `jsonDecode` 放开给它用。单测 `NoteSyncFolderTests`（往返、认不出的文件、墓碑文件、一轮的几种停、跳过、计数、刹车的边界、写出去、退回去了）；随机测试 `NoteSyncFuzzTests` 多了一个走文件夹的（真的文件写法 + round / publish，读别人的文件时随机看到旧一版、没下载完、墓碑文件读不出来），并把「不丢字」查到另存那条的后来；先各埋一个错（不写墓碑文件、不另存输的那版）看它真抓得到。**它抓到了第 7 批的一处错**：另存那条原来带着输的那版的钟，几台从钟不同、字一样的几版另存出同一条后接着改会撞号，真改过的字被当成被盖过扔掉（2000 次里出现两次）——另存那条改成钟从空的起。默认随全量跑 1200 步 × 2，按需加大（各 6 万步、五批种子都过）。评审（一名 agent，独立脚本核了几十种往返和坏文件）后改了 5 条中等：认出「库被退回去了」之前打的字照样会被扔 → `regressed` 返回是哪几条（连别人那份里本机那一格也看），`NoteStore.switchDevice(bumping:)` 换编号时给它们各记一笔新编号的改动；外面动过 / 读到一半的文件会以同一个钟和真的比、一半概率赢 → 文件头加内容哈希，写了却解不出来的键、重复的键都当读不出来；自己文件夹里读不出来的文件永远不重写、别人永远跳过这条 → 去掉「写过哪个修订号」的账（`note_published`、`recordPublished`、`clearPublished`），每轮直接和自己文件夹里那一版比，读不出来的那一版只扔这一版、不整条不合；永久删过又导进来的钟从 1 重数 → 接着墓碑的钟；不可信输入没上限 → 文件大小、钟的格数先拦。另：自己文件夹里本机没有的（0.5.0 的到期清理不留墓碑）不再当成「退回去了」、照常合回来；更新的格式另说「先更新」、墓碑读不出来带上是哪台；时刻夹进范围；同一编号大小写两份的墓碑并起来；ISO 格式器只建一个；设置里「导入…」跳过同步文件。随机测试跟着改严：「不丢字」按编号查（不拿别的便签恰好一样的内容顶）、永久删只放过删之前打的、旧一版从历史里随便挑、读到被外面动过的、自己的文件被写坏——**又抓到一处**：本机永久删了、又被别处删之前改过的那版救回来时，钟里本机那一格退回去了（接着改会重复用计数）→ 留下来的那条钟里并上墓碑的钟。
  - 9 同步的执行层（还没有界面：开同步的设置页是第 10 批）：新文件 `Notes/NoteSyncDisk.swift`（`@concurrent` 读写文件夹：每个文件先看属性，没下载到本机的（下载状态不是当前、旧式 `.名字.icloud` 占位）算读不出来并请系统去下载，太大的不读；读写过 `NSFileCoordinator`、写是原子的、`device.json` 最后写；没变的文件按路径 + 文件号 + 时刻 + 大小用上一轮读出来的；开同步前看一眼 `inspect`，标记不覆盖着写 `createMarker`）和 `Notes/NoteSyncer.swift`（`@Observable`：每 20 秒、醒来、立即同步各一轮，串行；一轮 flush → 读 → 认文件夹 → 认库被退回去了就换编号 → 合 → 刹车（刘海岛「继续」）→ 正在编辑的先不换也不写出去 → 落 → 冲突另存了刘海岛说一句 → 写；状态：关着 / 正在同步 / 好了 / 停了（为什么）/ 等确认，别的电脑和最后看到它变的时刻）。`AppDelegate` 建它，便签功能开关跟着 start / stop，醒来合一轮；`NoteStore` 加 `meta` / `setMeta`，`NoteImageStore.fileNames`，`Prefs` 两个只在本机的键（文件夹、库编号）。单测时发现光看钟认不出「恢复之后又打了字、计数追上了」→ 加「写出去的是第几轮」（epoch：库里和 `device.json` 各记一份）；换编号时那几条的钟去掉旧编号那一格（留着的话发出去的那版会被当成前身扔掉；代价：恢复后没改过的那几条也另存一份进最近删除，替用户定的）。评审（一名 agent）后改了 3 条高、7 条中：判断「正在编辑」原来看所有窗口——浮着的、后台窗口里的那条永远收不到改动 → 只认 key 窗口 + 挂着组字的；没换进来的那条照样写出去、对面每轮多一条另存的半截 → 也先不写；开同步时把没下载完的标记当成没有、新写一个把别的电脑全挡在外面 → 标记读不出来、没标记却有别人的子文件夹都不开，标记不覆盖着写；epoch 原来是随机串比相等，写到一半停了、换过文件夹也认成退回去 → 只增的整数、文件夹里的大才算；自己的 `device.json` 读不出来时认不出退回 → 停这一轮，写出去只删有墓碑的；没认文件夹就先换编号 → 先认；刹车每 20 秒弹一次、「继续」不看条数 → 条数变了才弹、只放行不超过当时那么多条；缓存按秒级时刻可能一直拿着旧版 → 加文件号、刚改过和读失败的不记；单测里两轮同时跑 → `enable` 不自己起一轮（调用方 start）；另：`switchDevice` 先落那几条再记编号、`meta` 读错不当成空、文件夹没了不替它建回来、拷图撞上别处刚放好的算成、停着时「继续」不起一轮、标题框拿着焦点也算正在编辑。没改的：换编号后本机旧的子文件夹在「别的电脑」里显示成同名的一台；网络盘卡住时一轮不结束（ponytail）。单测 `NoteSyncerTests`（两台真的仓库 + 临时文件夹：来回传、冲突两边各一条、永久删除、刹车、正在编辑、停、关、图片、库被退回去了三种、写到一半、不盖标记、读写那一层），改动处各埋错验过测得出。
  - 10 同步的设置页：设置 › 便签 在「屏幕边缘」和「数据」之间加「同步」一节（`NoteSyncSection`，写在 `Settings/NotesTab.swift`，跟着便签的功能开关变灰）。没开：「在几台 Mac 之间同步」+「选择文件夹…」（面板先指到 iCloud 云盘，可以新建文件夹）；选的文件夹里已经有别的 Mac 的便签 → 先问「和这个文件夹里的便签合在一起？」（几台、几条）；没开成橙字写为什么（不在了、标记还没下载完、没标记却有别人的、**不是空的**——替用户定的：不往「文稿」这种文件夹里撒子文件夹，`NoteSyncDisk.Inspection.empty`）。开着：「同步文件夹」+ 名字（悬停看路径，iCloud 云盘里的写成「iCloud 云盘/…」）+「停止同步」（链接样式，同「另存一份到」的「不再另存」）+「立即同步」（刹车时换「继续同步」），说明是「上次同步：刚刚 / 2 分钟前」+ 还在下载几个，停了 / 等确认橙字说为什么、能怎么办；「其他 Mac」列名字和上次有改动的时刻（还没有时说去另一台选同一个）；页脚说文件不加密、多久传过去、冲突和刹车、停止后什么都不删。`NoteSyncer` 的文件夹和库编号改成被观察的属性（原来现读偏好，开关之后页面不变）；打开全部便签窗口时也合一轮（`AppDelegate.showNotes`）。更新日志 0.6.0 加一条、摘要加一句；roadmap.json 里最后一条（iCloud 同步）拿掉，变成空的（关于页不显示「未来计划」，`ChangelogTests` 放开空的）。截图自检 `SnapshotProbeTests/notesSync()`（图以 notes-sync- 开头）。评审（一名 agent）后改：选文件夹的面板原来不是表单，开着时能关掉便签、换页——关了便签之后照样把同步起起来、换了页确认框不出来 → 面板挂成设置窗上的表单，开完再看一眼便签开没开（关着只记下文件夹，打开便签时起）；第一轮就停了也写「正在同步…」→ 只在真在同步时写，不然「还没同步过」；「合在一起？」里的条数把每台的全套加起来、多算几倍 → 按编号去重（含最近删除里的，文案写明），别的 Mac 一条都没有就不问，格式更新的不问；标记被删后「再重新选」走不通（自己的子文件夹还在、不算空）→ 改成「选一个新的空文件夹（每台都换过去）」；空文件夹把旧式 iCloud 占位当隐藏文件 → 不算空；开同步失败的系统原话带句号 → 去掉；第一轮合完之前「其他 Mac」说「还没有」→「同步一轮之后列在这里」；看文件夹卡住时说一声；「立即同步」不再每轮闪灰；相对时间每分钟走一下；没名字的那台写「另一台 Mac」；手测里的刹车线、「正式版」写准。手测 286–295，冒烟清单 53。

**全局同步（2026-10-23 拍板；0.6.0 只挪位置，其余进 0.7.0）**
- 来由：用户 2026-10-23「便签这个同步功能是不是可以移动到通用里面，直接全局同步就可以了」。拍板页 https://claude.ai/artifact/HPqLM8wzRHx9eF5dpFBfQv（20 项，生成脚本在主检出 `macos/build/research/global-sync-2026-10-23/build-decisions.py`；对标 Raycast Cloud Sync、Alfred 同步偏好文件夹、Paste 的 iCloud 同步，查的官方说明），用户「全部按推荐」。
- 拍板（A 入口）：设置 › 通用 里一节「同步」，便签页那一节拿掉；一个文件夹管全部；每类一个勾，默认勾上推荐的几类，取消一类只是不再同步、文件夹里的不删。
- 拍板（B 同步哪些）：同步设置（**留在本机**：启动台整页、录屏 / 录音选的麦克风、便签放在哪块显示器，加上导出已经排除的窗口位置、文件夹路径、授权状态这些）、全局快捷键、功能开关、片段和文字收藏和收藏夹、生词本、网页搜索与快捷链接、翻译服务列表（**密钥不同步**，别的 Mac 上显示「还没填密钥」、自己填一次）、启动器收藏（另一台没装的 App 不显示）；图片收藏以后再说，文件收藏不同步；**不同步**剪贴板普通历史、翻译历史、启动器使用记录、启动台排法。
- 拍板（C 怎么合）：一条一条的数据（片段、收藏、生词、搜索与链接、翻译服务、启动器收藏）后改的赢、不留旧版；删除也同步（留记录），一轮删太多先停下来问（和便签同一个刹车）；设置一项一项比、后改的赢（要开始给每一项记改动时刻）；新加入的 Mac 设置和快捷键跟着文件夹里已有的，数据合在一起（同样的正文不重复），开之前的「合在一起？」写清楚。
- 拍板（D）：0.6.0 只把便签同步挪到「通用」（说法改成全局的，暂时只有便签一类），其余几类进 0.7.0；顺序 挪位置 → 框架和按类开关 → 片段、收藏、生词 → 搜索与链接、翻译服务、启动器收藏 → 设置、快捷键、功能开关。**0.7.0 那几批不进 main**（main 是 0.6.0 的发布线）：在 roadmap 检出另开分支 `sync-wip` 做、审查后各一个提交，0.6.0 发布后再 rebase 并回 main、改版本号（2026-10-24 0.6.0 发布后以合并提交 `c2dca076` 并进 main，版本号升到 0.7.0）。
- 各批一行摘要：
  - 1（0.6.0）挪位置：「同步」一节从 `Settings/NotesTab.swift` 挪进新文件 `Settings/SyncSection.swift`（`SyncSection`），放在 设置 › 通用「权限」和「导出与导入」之间；便签页「数据」页脚指过去。页脚先说「同步的是便签，连同正文里的图片」；原来整节跟着便签的功能开关变灰，搬到通用后不灰，便签关着时橙字「便签关着，先不同步…」（`NoteSyncer` 照旧停着）。截图自检改名 `SnapshotProbeTests/sync()`（图以 sync- 开头，多两张：通用页里的位置、便签关着）。更新日志、手测 286–295 和冒烟清单 53 里的位置跟着改。
  - 2（0.7.0，`sync-wip`）一条一条的数据的引擎（纯函数，还没接仓库）：新文件 `Storage/SyncRecords.swift`。各仓库不记钟，用**账本**（上一轮合完每条的钟、内容哈希、改于）比出本机改了、删了、新加了什么；合法和便签同一套版本钟，C1 后改的赢、不留旧版，C2 删除留墓碑、不过期；账本被时间机器退回去时只把自己那一格追上；第一次合 union（同样内容只留文件夹那条，只对活着的版本去重）/ adopt（设置整个跟着别的电脑）。文件是自己子文件夹里的 `<类别>.json`，便签之外多出来的文件 0.6.0 读不到也不碍事（文件夹格式不升，0.6.0 和 0.7.0 能同时用一个文件夹同步便签）。单测 `SyncRecordsTests`（17 个）、随机测试 `SyncRecordsFuzzTests`（三台、旧一版的文件、钟快慢、退回、丢账本、编号再用、adopt；默认 20 个种子，按需 `TEST_RUNNER_KITTY_SYNC_RECORDS_FUZZ=<种子数>`，2000 个种子过）。评审（一名 agent，Python 移植复现）后改：删过的编号再加回来被别台的旧文件翻回去、两台各自新设同一项总是先发的赢 → 空钟只在第一次合时给，别的走「新加的」、计数接着见过的最大；账本退回时并整个钟会让钟快的旧值赢遍每一台 → 只追上自己那一格；第一次合的去重对上已经改掉 / 删掉的旧版本 → 只对活着的版本；两种写法的同一个字（合成 / 组合的 é）两台来回改 → 按字节比；改于记的是发现的时刻（退出、合盖后才合到的改动会翻掉别人后来改的）→ 调用方可以给每条真正改的时刻（设置要记）；adopt 误报刹车、本机自己删一大批没刹车（加 `erasing`）、文件读得不够严（「更新版本」要结构和类别对得上，钟的格子写坏就读不出来）。**留给执行层**（写在文件头）：账本和数据同一个事务提交、从备份恢复时账本跟着退回、关掉一类不清账本、交进来的是落下的全部、编码稳定、值里不带只属于这台电脑的东西。程序坞预览（另一个 0.7.0 新功能）在 `dock-wip`，2026-10-23 用户定合进 `sync-wip`、0.7.0 走一条线（main 保持 0.6.0）。
  - 3（0.7.0）片段、收藏、生词本接进同步：新文件 `Storage/SyncLedger.swift`（`SyncSource` 协议：仓库交出该同步的那份、落合并结果；账本表 `sync_ledger` 在 kitty.sqlite3，一类一行整本 JSON，落结果和存账本一个事务，记着文件夹的库编号；每日备份整张留着，`BackupTests` 的表清单跟着加）。`ClipboardStore`：留下来的文字条目和收藏夹；别处删了 / 不再留着的本机只取消收藏、移出片段和收藏夹（还在历史里按保留天数清理——替用户定的：不直接删行），新来的和历史里同正文的普通条目合成一条；面板里有能撤销的改动时这一轮先不合。`HistoryStore`：生词本，同原文 + 同目标语言只留一条，别处不再收藏的本机取消收藏。执行层一部分一部分合：每部分一个勾（`Prefs.syncSkipped`）、跟着各自的功能开关（便签 / 剪贴板 / 翻译，都关了才整个停，`AppDelegate.syncFeatures`）；刹车把别处要删的和本机一下删掉的加起来算；「继续」只管下一轮；每类的文件在 device.json 之前写。设置页「同步的内容」三个勾（功能关着时勾下面说先不同步）。单测 `NoteSyncerTests` 多八个（来回传、第一次合不重复且本机的备注和同名收藏夹不丢、两台合之前各自存了同样的、合完再合一轮什么都不写、面板忙 / 没勾 / 功能关着先不合、便签不合时 epoch 不往小里写、刹车每部分各算）。评审（一名 agent，Python 移植复现）后改：两台各自收藏同一句 / 存同样的片段，生词两边都丢、片段重复 → 撞上时**编号小的留下**（几台挑的一样），输的那条本机删掉、它的收藏 / 片段 / 备注 / 收藏夹并进留下的那条；事务里删掉的行又被「写改动」插回来、重启多一条 → 删掉的不再写；第一次合按名字去重收藏夹时条目掉出收藏夹、同正文合并时本机备注丢 → 条目归进同名的、缺的补上（同 adopt）；收藏夹同一毫秒建的会来回翻 → 排序加编号；值解不出来当成删除会删到每一台 → 整个不落、这一类停在「没存上」；账本读错当成第一次合 → 抛错、这一类先不合；编出来超过 32 MB 每轮重写一份读不了的文件 → 不合不写、说清楚；复制时间不同步了（每粘贴一次就变，会让别处同时改的备注输掉）；带 NUL 的不同步（库里存的是截断的）；自己那份按字节比；便签关着、剪贴板开着时在设置里开同步不起 → 看 `NoteSyncer.wanted`；便签不合时 device.json 的 epoch 往小里写 → 取文件夹里的；刹车的「继续」几部分共用一个额度 → 每部分各记各的；「合在一起？」只在文件夹里有便签时问 → 有别的 Mac 就问。没改的：别人一份文件一直读不出来（不用了的电脑留下的坏文件）这一类一直停（ponytail，要忽略再加）；便签库打不开时整个同步都没有（电脑编号在便签库里）。
  - 4（0.7.0）网页搜索与快捷链接、翻译服务、启动器收藏：新文件 `Launcher/WebSearchSync.swift`、`Translate/TranslateServiceSync.swift`（存在偏好里的列表，账本也放偏好里 `syncLedger.<类别>`，先写数据再存账本；偏好里的列表读不出来时这一类先不合），`LauncherUsage` 末尾实现 `SyncSource`（编号 = 类型 + 目标的哈希，库和账本一个事务，不卡 8 个）。翻译服务**密钥不同步**：别的 Mac 上显示「未填密钥」（启用着的翻译时照常提示缺密钥，替用户定的：不悄悄跳过）；第一次合时同协议、同地址、同模型的自建 AI 服务只留一个，本机那个的密钥搬给它；别处删了只拿出列表、不删钥匙串里的密钥。内置的搜索 / 服务编号各台一样，第一次合时跟着文件夹里已有的（同设置，「合在一起？」里写明）。**有序列表的顺序单独一条记录**（`SyncRecords.orderID`，编号数组、后改的赢；第 3 批的收藏夹顺序也改成这样）：改内容和挪顺序不互相盖掉。**启动器收藏还原不出来的只藏起来、不删、不占 8 个名额**（原来顺手删掉——同步时会删掉别的 Mac 上有用的），⌥⌘↑↓ 只和看得见的邻居换（`LauncherUsage.swapFavorites`）；`LauncherBatch5Tests` 那条改成 `missingFavoritesAreHidden`。值是更新版本写的（多了不认识的字段，`SyncRecords.decodeExact` 编回去不一样）整个不落、这一类停（不把别人的字段删掉再发出去）。设置页「同步的内容」六个勾。单测：`NoteSyncerTests` 多四个（三类来回传、启动器收藏两台各加满都留着、合完再合一轮什么都不写扩到六类、两台各在末尾加一条 / 一台挪顺序一台改名几轮内一样且都留下）。评审（一名 agent）后改：收藏满了时删掉藏着的会同步删掉别的 Mac 的（高）→ 不删、按看得见的数名额；每条带位置会让挪顺序吃掉同时的改名、要多写几轮才稳 → 顺序单独一条；第一次合去重掉的 AI 服务密钥没跟过去 → 搬；先存账本后写数据 → 对调；偏好读不出来当成删光 → 先不合；更新版本的字段会被删掉再发出去 → 编回去不一样就不落；重复编号崩 → 去重；启动器收藏编号和内容对不上 → 不落。
  - 5（0.7.0）设置、全局快捷键、功能开关 + 状态屏的状态：新文件 `Storage/SettingsSync.swift`（一项一条：`pref:` + 偏好键、`hotkey:` + 动作；哪些键、什么类型、怎么收拾和设置的导出一样——`SettingsArchive.kinds` / `Kind.plist`，功能开关也在里面，发之前也核一遍；只同步改过的，改回默认 = 删掉这一条；账本在偏好里）、`StatusScreen/StatusPresetSync.swift`（一个状态一条 + 顺序一条，第一次合并在一起、标题一样的只留一个）。**留在本机**（`SettingsSync.localKeys`）：启动台整页和它的开关、录屏的麦克风和显示按键、录音来源、程序坞预览开关、便签放在哪块屏、菜单栏图标显不显示、剪贴板面板和翻译浮窗的图钉。每项改的时刻听偏好变化的通知记（`syncChangedAt.settings`），同步落下的清掉；第一次合跟着已有的（adopt），「合在一起？」写明保留天数、「不记录」的 App、功能开关也换、超出的历史会清，清掉了刘海岛说几条。同步不再跟着功能开关起停（设置那部分一直合），打开同步管的功能那一刻合一轮；`NoteSyncer.wanted` 删掉。设置页「同步的内容」八个勾（设置在最上、不跟功能；状态跟状态屏）。单测 `NoteSyncerTests` 多四个（设置跟着已有的、一项一项后改的赢、状态两台都留下、透传和忙着先不合），「合完再合一轮什么都不写」扩到七类（带小数、字符串数组、清除了的快捷键、自己写的状态）。评审（一名 agent，独立脚本核系统行为）后改：状态列表整张一条——第一次合抹掉这台写的、两台同时各加一个丢一个（高）→ 另走一类；录屏「显示按键」跟着授权、一录就写回关掉对面的，程序坞预览开关同步过去凭空弹授权框，图钉、菜单栏图标每台不同 → 进 localKeys；**新旧版本混用时不认识的键整类停**（以后加设置、改 localKeys 都会停，只能在 0.7.0 第一次发布前补）→ 这一版不认识 / 留在本机 / 落不下的**原样透传**（`syncPassthrough.settings`，不落、不留墓碑、不停；复查时补：透传着的那几项交出去的是透传那份，本机再改才换——不然拿本机的旧值把新版本的翻回去）；别处关掉录制会停掉这台正在录的 → 录屏 / 录音、录快捷键、状态屏开着时这一类先不合；两边同时把同一个组合给两个动作 → 刘海岛说一声；收到的快捷键不查 `isUsable` → 查；对面落不下的照发 → 发之前核；设置也走删除刹车（说不通）→ 不算；改的时刻落下后不清、存账本失败时把刚落下的当成本机改的 → 清、先重取再存。**用户 2026-10-24 定**：保留天数、「不记录」的 App、剪贴板功能、复制即译这几项**继续跟着别的 Mac 同步**、不进 localKeys（评审 H1；第一次合时「合在一起？」里写明，之后别处把保留天数改短本机也跟着清，清掉了刘海岛说几条）。没改的：「不记录」的 App 列表整张一条（两台同时各加一个丢一个，ponytail）；改回默认和别处同时改值时改值的赢（墓碑压不住同时的改动，写在文件头）；跨版本收拾规则变了（表情清单、保留档位）可能把新版本的值收拾掉再发回去。
- **0.7.0 并回 main 时**（0.6.0 发布之后；2026-10-24 已照这份写进 `changelog.json`，加了程序坞预览一句，第二句末尾补了「正在录屏、录音时先不换」）：`sync-wip`（含程序坞预览）rebase 到 main，升 `MARKETING_VERSION` 0.7.0、`changelog.json` 加一条（程序坞预览那句见下面「程序坞预览」）。同步这几句的草稿：
  - feat / 同步：「同步」不再只管便签：设置 › 通用「同步」里多了几类，各一个开关、默认都开——设置与快捷键、片段和收藏（连同收藏夹和备注）、生词本、网页搜索与快捷链接、翻译服务、状态屏的状态、启动器收藏。同一条两台都改过的，后改的留下；删掉的也会同步，一下删很多时先停下来问。
  - feat / 同步：设置一项一项比，后改的留下；跟着这台 Mac 的不同步：启动台的排法和行列数、录屏的麦克风和「显示按键」、录音来源、程序坞预览开关、便签放在哪块屏幕、菜单栏图标、面板的图钉。新加入的 Mac 设置换成已经在同步的那几台的，「合在一起？」里写明。
  - feat / 同步：翻译服务的密钥不同步：别的 Mac 上那个服务写着「未填密钥」，在那台自己填一次。启动器收藏里这台没装的 App 先不显示，装上就回来。
  - ui / 启动器：收藏里还原不出来的 App 不再被顺手删掉，先藏起来、不占 8 个名额。

### 启动台（第八族，0.6.0，2026-10-18 立项）

需求、做法和验收标准在 `macos/build/research/launchpad/SPEC.md`（用户交给 agent 的规格；R1–R11 是验收标准）。这里只记仍有效的约束和已定的事。
- **是什么**：复刻 macOS 15 的全屏图标网格（macOS 26 起系统那个换成了「应用程序」视图）。**只在 macOS 26 起出现**（2026-10-19 用户定）：15 上系统自带启动台，我们的整个藏起来（`Launchpad.isAvailable`，各入口怎么藏见 mac-launchpad §4）。**和现有的「启动器」（`Launcher/`，⌥Space 的搜索框）是两个东西**：名字、设置、快捷键都分开。家族色薄荷绿 `Style.Family.launchpad`。
- **在哪**：`KittyTools/Launchpad/`（§4 文件表），设置页 `Settings/LaunchpadTab.swift`；规矩 `mac-launchpad.mdc` + `mac-whisker-launchpad.mdc`；手测 `HANDTEST.md`「启动台手测」。
- **窗口**：自建窗口的新例外 `LaunchpadPanel`（mac-overlay-panel §1）：盖满鼠标所在那块屏、`.statusBar`、`.nonactivatingPanel` + `canBecomeKey`、不激活本 App、每次打开新建、收起放掉。盖住整块屏（菜单栏和程序坞都在下面）——普通窗口做不到「盖住菜单栏又让程序坞露在上面」，这是唯一做不到和 macOS 15 一样的地方（SPEC §3.2）。
- **布局**：一份 JSON 存 `Prefs.launchpadLayout`（注册空串默认值，SettingsArchive 的「设置」一类跟着导出 / 导入和每日备份走；不另开库）。App 按 bundle id 认（没有的按解开链接后的路径）。第一次打开、还没存过布局时：有系统旧启动台库就自动导入（SPEC §5.4），读不到用默认排法（系统 App 在前、`Utilities` 进「其他」文件夹、其余按显示名）。
- **入口**：菜单栏一项、现有启动器里一条「启动台」、全局快捷键（默认不设）、触控板捏合（第 3 批，主入口）、触发角（第 3 批，默认关）。总开关 `Prefs.launchpadEnabled`（2026-10-21 并进功能开关 `Feature.launchpad`，见下面「功能开关」）。截图 / 录屏 / 状态屏 / 正在录快捷键时不响应；打开别的功能先收起。
- **不做**（这一版）：下载中的 App 进度图标、往程序坞拖、iCloud 同步布局、小组件、按分类自动整理、多块屏同时显示、「启动台」作为独立 App 出现在程序坞里、自定义图标、隐藏某个 App、给文件夹换颜色、「最近使用」排序。
- **进度**：第 1 批（2026-10-18）模型和纯函数、App 目录、默认排法、全屏面板、网格 / 分页 / 两指滑 / 圆点 / 搜索 / 键盘导航 / 打开 App、开收动画、入口、总开关、设置页骨架、`MARKETING_VERSION` 0.6.0 + 更新日志、规则和本节的初稿。第 2 批（2026-10-18）拖动排序和跨页（跟手、让位、边缘停着翻页、Esc 取消）、文件夹（原地展开、改名、内部分页、拖进 / 拖出、只剩一个解散）、抖动模式和删 App（按住 1 秒 / 按住 ⌥、只有 App Store 装的出 ✕、确认后 `NSWorkspace.recycle`）、每次挪动马上存、改行列数重新分页。第 3 批（2026-10-18）触控板捏合（`PinchRecognizer` 纯状态机 + `TouchpadWatcher` 运行时 `dlopen` 私有框架 + 系统手势只读检测 + 设置里那一组）、触发角（`LaunchpadCorner` 每屏一个几点的透明 NSPanel 实例 + 追踪区）、旧库导入（`LaunchpadImport`：拷贝 → `file:…?mode=ro` 只读打开拷贝（**不读 `immutable=1`，会跳过 -wal**）→ 三张表 → 纯函数拼布局；第一次打开自动一次 + 设置里两个按钮）。第 4 批（2026-10-18）设置页补全（触控板那一组、触发角、导入 / 恢复 / 撤销；`Form` 显式 `.formStyle(.grouped)`，和别的设置页一致）、菜单栏 / 启动器 / 快捷键页 / 速查表各一项同名同序、`SnapshotProbeTests/launchpad()`（17 张图，浅深各一份 + 设置页；F30 补了整页 / 第 2 页空位 / 宽文件夹 / 浅色搜索）、`LaunchpadBitmapTests`（画进位图：第 2 页第 3 行第 1 格有图标、第 2 / 3 格是空的）、`LaunchpadProbeTests`（按需 `TEST_RUNNER_KITTY_LAUNCHPAD_PROBE=1`）。
- **四批评审后的一轮（2026-10-18，FIXES F1–F46）**：拖到有图标的格子上不再一律建文件夹（停中心 0.4 s 才合成，边沿 / 快松 = 排序）；文件夹 7 × 5 = 35 个一页、原地展开；页边界不再被整份重排（只有超容量才推下去），新装接最后；导入读 WAL、取 `ROOTPAGE`、整理重复 / 单 App 文件夹；布局读不出来时不覆盖、设置导入 / 备份不再丢布局；删 App 走 `NSWorkspace.recycle`、失败带「在访达中显示」；面板先出岛后出、收起按窗口簿记、内容晚一拍拆、失去 key 收起；捏合默认按系统开着算、设置页回来就生效；触发角 `.statusBar`、重新武装、系统冲突提示；抖动改图层、文件夹按内容行数、读屏和格内点击区；随机测试开关改对（`KITTY_LAUNCHPAD_FUZZ`）并加纯函数 + model 两层、改容量 / 新装 / 删除 / 加进文件夹。
- **复查后的第二轮（2026-10-18，FIXES-2 G1–G29，主会话修）**：触控板 C 回调在默认 MainActor 隔离下会被推成主线程隔离、框架线程一进来就 trap（第 3 批起就有，系统手势一关、一碰触控板就崩）——桥、全局、回调本体都显式 `nonisolated`，回调字面量里不写闭包；目录后台扫完之前打开不再用空目录把布局合并清空；合成的目标是指针下面画着的那个、落点按指针在图标哪一半（图标不再被空位挤走、也不追着指针跑），拖文件夹不合成，最后一页右边缘停够新开一页；文件夹面板格子宽高分开算（名字不再互叠）；系统手势几个域的合并、触发角真画底色 / 启动台开着不重新武装 / 「—」不算占用、设置页只在系统手势变了时重起监听、开文件夹 / 抖动后焦点还给搜索框、翻页快甩按速度方向且第一帧不算速度、搜索时点刚装的 App 按目录打开、拖动 / 搜索中来的布局和目录松手再接；岛上的动作按钮多留几秒、第一下就能点；设置导入的布局收拾后再写、空的不收。新单测 `LaunchpadRecheckTests`（含后台线程调回调、进程内 `window.sendEvent` 走真 SwiftUI 手势的单击 / 拖动）。没在真 App 里看过的：真捏合（G1 修好后第一次真注册）、触发角的点穿和吞点击、抖动转轴、岛按钮的第一下点击、确认框是不是 sheet（G27）——见 HANDTEST「启动台手测」27–32。
- **真机反馈后照 macOS 15 对齐（2026-10-18，主会话做，方案页 `macos/build/research/launchpad/LOOK.md`，用户「全部按推荐」）**：四指捏合打不开是系统 更多手势 › 应用程序 还开着（按设计让给系统，设置页提示写明是哪一行）；第一次打开卡一阵是图标在主线程按多尺寸重渲染（111 个 1.8 s），改成后台画位图、常驻（用户定），第一次导入时岛上挂「正在排列…」；文件夹展开乱是半透明面板透出后面的网格，改成后面整张糊掉压暗、面板在屏幕中间（用户定）；背景改成壁纸模糊、网格 / 图标 / 名字 / 搜索框 / 文件夹按官方截图的比例（`mac-whisker-launchpad` §1–§3）。没在真 App 里看过的：材质是不是真把后面的图标糊掉、很亮的壁纸上名字看不看得清、插入点藏起来时输入法组字——见 HANDTEST「启动台手测」33–38。
- **交互对齐 macOS 15（2026-10-18 夜，方案 `build/research/launchpad/INTERACT.md`，用户「全部按推荐」）**：先修了只认图标的点击范围和文件夹名只有字能点（`93e18a04`）；
  再按 GitHub 上 10 个同类（`github-survey.md`，最像的 LaunchNext 是 GPL-3，只借行为和数字；**网上没有 macOS 15 的真实动效参数**）改拖动：
  让位停 0.15 s、松手执行屏上的排法、一拖就抖、合成底板、停在文件夹上打开并放进任意一格、拖出文件夹接着拖、边上连续翻页、松手滑进落点；
  另有文件夹从图标长出来、空白处鼠标拖着翻页、翻页门槛 20%、打开 App 时淡出。拖动的「挪 / 松手」另在最外层收一份（文件夹被拆掉时格子上的手势会被取消）。
  没做：文件夹打开时后面的网格缩到 0.97（缩放会让拖动判定用的格子位置跟着动画变；第六轮补上了）。手感要真机试（HANDTEST「启动台手测」41–48）。
- **第三轮真机反馈（2026-10-18 夜）**：图标多的文件夹展开卡、关上没有动画、让位不像 macOS 15。屏外逐帧量过：让位时图标**根本没滑**（格子按位置建，
  换的是格子里画的图标）——改成按格子的 id 建、`.position` 摆位置，图标真的滑过去；35 个的文件夹展开第一帧主线程约 54 ms → 41 ms
  （名字平时是 Text、图标平时是 SwiftUI Image），不抖时面板压成一张图缩放（GPU 那头屏外量不到）；关上本来有动画，改成更慢的 `retract` 让它看得出。
  对照参考：用户装了 BuhoLaunchpad（付费、自称最接近原版），录一段它的拖动 / 文件夹再逐帧对（HANDTEST 49–51）。
- **第四轮真机反馈（2026-10-18 夜）**：进出编辑一闪、关文件夹还是没动画。用户同意后在屏幕左下角放了个测试窗口（在所有窗口后面、不当 key）、
  ScreenCaptureKit 只录它，改前改后各录一遍对过：① 关文件夹——ZStack 里离场的视图被 SwiftUI 挪到兄弟视图下面画，面板缩到网格和不透明的壁纸后面去了
  （改前第一帧就没了），给后面那层 / 面板 / 跟手那份写死 `zIndex`；② 闪——上一轮把图标改成「平时 Image、抖动换 NSImageView」，换的那一下淡出淡入。
  改成不换：主网格一直 NSImageView（图层抖动，主线程约 2%），文件夹里一直 SwiftUI（`Jiggle`，35 个约 17%，只抖看得见的一页）。屏外截图帮不上：
  `cacheDisplay` 画不出动画中途的变换和离场视图的层次，屏外窗口 ScreenCaptureKit 也录不到。录到的帧在 `build/research/launchpad/onscreen-*.png`。
- **第五轮（2026-10-18 夜）**：用户要文件夹关上时「从中间逐渐回到文件夹的位置，像便签墙」——改成便签墙编辑卡的做法：动的是一块不透明的「纸」
  （`FolderPaper`，框从方块长到中间 / 缩回方块，圆角和底色跟着变），内容另一层淡进淡出（关的时候 0.07 s 就淡掉），屏上逐帧录过（`onscreen-paper-*.png`）；
  `FolderZoom` 删掉。触发角：开着时离开收不到事件、收起后要再离开一次才重新武装——收起时鼠标不在角里就重新武装。
- **第六轮（2026-10-18 夜，「按你的建议全部开始」）**：屏上动画实录留成按需自检（`LaunchpadAnimationLiveTests`）；文件夹里的编辑模式平时 SwiftUI Image、
  抖动时不带动画地换成图层抖动（35 个约 7%，原来 18–24%）；文件夹里拖到面板左右边上翻文件夹的页；文件夹开着时后面那层缩到 0.97——上一轮没做是怕
  格子位置跟着变，改成在缩之前那层坐标（`gridSpace`）里量。`LaunchpadModel` / `LaunchpadView` 拆成七个文件（只搬家；拖动的流程留在
  `LaunchpadModel`——挪到别的文件要把 7 个 `private(set)` 和 11 个私有属性放开，不值）。
- **第七轮真机反馈（2026-10-19，主会话做，用户给了同类 BuhoLaunchpad 的设置截图）**：① 触控板手势改成 关闭 / 四指捏合 / 五指捏合（`Prefs.launchpadPinchGesture`，默认四指；四指只认正好 4 指、五指认 5 指及以上），组页脚写清怎么认（系统的开着让给系统、唤醒后自己接上）；没照同类加「唤醒后重启」开关（唤醒重注册本来就是自动的，G24），也没做「系统手势开着时拦下系统的捏合给自己用」（要事件拦截 + 私有事件类型，另议）。② 点搜索框没反应：焦点本来就在框里、插入点藏着，点了没变化——面板 `sendEvent` 认出按在框上，占位滑到左边、亮出插入点。③ 动画不如 macOS 15 丝滑，查出四处：松手翻页从静止起步（改成接着手指的速度，界面拿掉按页号的隐式动画）、`glide` / `pop` 带回弹（启动台一律改成不回弹）、打开时两层淡入相乘且连背景一起缩（改成窗口淡一次、只缩上面那层）、打开和文件夹展开的动画从第一帧画完之前就开始算（改成画完再起）。收起改成往前放大（原来缩小）。数字是按记忆里的 macOS 15 定的，等真机手感（HANDTEST「启动台手测」59–66）。跟手每帧主线程（Debug，屏外，113 个 App）中位 0.96 ms / 最长 7.2 ms，不是卡的原因。
- **捏合跟手（2026-10-19，拍板页 `macos/build/research/launchpad/GESTURE.md` A，用户「全部按推荐」，第 1 批）**：识别器从「捏够了出一次」改成「开始 / 每帧进度 / 松手（进度 + 速度）/ 取消」（缩 4% 开始、满格 = 灵敏度那两个比例、过一半或快甩走完、往回甩退回，数都在 `PinchRecognizer`）；框架线程每帧只把进度写进桥的 `Mutex`，三件事才派回主线程；新 `LaunchpadZoom`（每块面板一个数，窗口透明度和上面那层的缩放都听它）跟手时用屏幕刷新回调每帧取进度，松手和快捷键 / 菜单 / 触发角 / Esc / 打开 App 都走同一条临界阻尼弹簧（打开 0.4、收起 0.3，接着手指的速度、不冲过头），原来的窗口 `NSAnimationContext` 淡入淡出 + SwiftUI 缩放两套拿掉。关着时开始捏就建面板（透明、不收鼠标、不拿键盘），松手走完才 makeKey；退回倒着走打开那一段；开着时张开同样跟手。监听停掉 / 重新注册时报一次取消，捏到一半的面板不会挂着。没做：面板常驻（A8 的 ②，开头那约 0.1 s 真机觉得慢再做）、逐渐加模糊。量（Debug，屏外，113 个 App）：跟手每帧改一次缩放主线程中位 3.3 ms / 最长 3.9 ms（翻页跟手约 1 ms；缩放要把几十个图标逐个摆，ponytail 在 `LaunchpadZoomScale`）。单测 `LaunchpadZoomTests` + 改写的 `LaunchpadPinchTests`。评审（一个代理）报的 4 条已修：旧面板收起走完 orderOut 失去 key 时把新捏出来的那块当「别的 App 到前台」收掉（回调只认现在这块）、设备中途断开等不到松手（跟手时每 0.5 s 看帧数）、捏一下又退回去也导入布局 / 弹提示（松手走完才算打开）、拆模型在走完时才取（改成收起那一刻取）；它疑心的「窗口透明度 0 时刷新回调不来」本机实测照常来（`probe/alpha-link`）。真手指的手感待 HANDTEST「启动台手测」67–73。系统手势开着也能用（B）等用户在场时跑探针（`build/research/launchpad/probe/`），过了做第 2 批。
- **调度中心里打开会透出 ✕（2026-10-19 真机反馈，用户试捏合跟手时报的）**：调度中心给窗口画的关闭按钮盖在启动台上面、还点得到（点了会关掉后面真的窗口）。量过：它不是普通窗口（窗口表里没有它的层级，调高启动台的层级盖不住）；macOS 27 起调度中心归 WindowManager（不再是程序坞），开着时有一块整屏大小的 19 层窗口。改成打开启动台前先认调度中心、开着就打开系统的「调度中心」App 让它退（`LaunchpadMissionControl`）。独立小程序在本机实测：认得准、0.35–0.5 s 退干净，马上摆上来的同类面板一直是 key、不会被收掉（探针在 `build/research/launchpad/probe/`）。26 上不认（认法会把「显示桌面」也算进去），待手测 HANDTEST 74。**同日返工**：第一版退调度中心的同时就把启动台盖上来，真机两次之后某个应用（Claude）的窗口一直压在最上面、切到别的应用也盖不过它，`killall WindowManager` 才恢复；独立小程序分开试（`probe/mc-focus/test.swift`）：光让调度中心退不会、等它退干净再过 0.3 s 盖面板也不会——先改成等退干净再开，用户嫌晚半秒；再试「马上盖、退干净再 makeKey」也不乱，最后用它（启动台马上出来、捏合照样跟手；1.5 s 还退不掉就收起启动台）。
- **四指捏合没反应 / 捏到一半断（2026-10-19 真机，跑探针时发现）**：① Kitty 启动时系统的「应用程序」手势开着就不注册触控板回调，系统设置改了我们收不到，用户之后关掉系统的、捏合一直没反应，要开一次设置页才接上——改成功能开着就注册，开始捏的那一刻再读系统的（开着照旧不打开）；② 探针日志里用户的捏合常常多碰到一根（手指数 4 → 5 → 4），四指档原来只认正好 4 根、一出现第 5 根就取消——改成认 4 根及以上（同系统的「应用程序」），跟着的时候手指数在认的范围里跳就按现在的进度换起点接着跟。待手测 HANDTEST 75。
- **R11 量出来的数**（2026-10-18，Debug，屏外，`LaunchpadProbeTests`；本机 113 个 App）：扫 App 目录 130–164 ms（**本轮已挪到 `@concurrent` 后台**，打开路径不等它；面板先出，扫完 / 导入完再把目录和布局接上）、屏外建界面到量到网格框（第一帧）55–80 ms、翻一页后主线程布局一次中位 1.9–2.3 ms / 最长 2.5–3.0 ms（R11 目标 ≤ 8 ms）、建出来 +16 MB、收起放掉后本进程 footprint 没降回去（窗口 / 图层资源，屏外量不准；真机上由图标缓存空闲回收 + `Memory.relieve()` 管，HANDTEST 16）。拖动 / 跟手的每帧时间、真机第一帧、静置 CPU **都还没量**（单测里不注册触控板回调，HANDTEST 10 / 16）；Release 单测构建在这个仓库里本来就编不过（和这一族无关），量的是 Debug / `-O` 覆盖。

---

### 功能开关（2026-10-21 立项，0.6.0）

- 用户 2026-10-21：「不用的功能模块可以有一个关闭的按钮，或者就不加载这个模块」。方案 `build/research/features-2026-10-21/SPEC.md`（D1–D8 都按推荐；
  原想交用户的 agent 做，2026-10-22 用户改成主会话直接做，在单独的检出 `kitty-tools-macos-features`、分支 `features-wip`）。
- 对标（官方文档 / 源码核实过）：PowerToys（仪表盘每个工具一个开关 + 工具页顶部「启用」卡片，关掉的页变灰、快捷键透传、进程结束）、Stats（模块
  enable / disable 起停 reader 和定时器、移除菜单栏小组件）、iStat Menus（每页顶部大开关）、Raycast（关掉的命令不进根搜索）。
- 原理：代码不拆插件（`Bundle.unload` 要保证没人引用、`dlclose` 不卸含 Objective-C 类的库）；没执行过的代码页本来不进常驻内存，
  省的是运行时的东西——全局快捷键（交还系统）、剪贴板 0.3 s 轮询和复制图片后的识字、启动器 / 启动台启动时扫目录、启动台常驻图标（约 15 MB）、
  触控板回调、触发角、便签屏幕边缘的药丸。
- 拍板：八个功能（= 设置侧栏的八页，`Feature` 与 `SettingsPage` 同名）各一个开关；两处同一个偏好（通用页最上面「功能」一组 + 各页第一行「启用…」，
  关着的页其余设置变淡点不了、管数据的不变）；立即生效；关掉 = 入口全藏 + 快捷键不注册 + 后台停，**数据层照常**（库照开、每日备份、保留天数和
  「最近删除」到期照删）；默认全开、引导不加；启动台原来的总开关并进来；开关跟着导出的「设置」走，导入会让剪贴板从关变开、让复制即译实际跑起来时
  橙字提醒；不做一键全关。
- 2026-10-22 第九族程序坞预览加进来：九个，它**默认关**（`Feature.defaultOn`，拍板页 A3）、没有全局动作（`FeatureTests` 的例外），见下面「程序坞预览」。
- 实现：`Shell/Feature.swift`；偏好 `feature.<名字>`（`Prefs.featurePrefix`，注册默认值 true——程序坞预览 false；读用 `Feature.isOn`，没存过 = 开）；
  `HotKeyAction.feature` / `isActive`（注册、分节用它；查重仍用 `isAvailable`，关着的功能的键也算）；`HotKeyAction.sections` 改成现算
  （`visibleSections(enabled:)`：两个功能合一节的只剩一个时节标题换成它的名字）；启动器内置动作的缓存键 `ActionState.features`；
  `ShortcutsSheet.groups(enabled:)`（组和行可标 `features` / `needs`）；`AppDelegate.applyFeatures`（启动时只起开着的，之后看
  `UserDefaults.didChangeNotification`、只对变了的功能做事）；剪贴板关着时轮询只为复制即译跑（`ClipboardWatcher.records`，过滤照旧）、
  两样都用不上时 `stop()`；自家写剪贴板记不记历史统一看 `recordsClipboard`；便签关着时那叠靠 `NoteDeckOptions.isEnabled` 自己收、浮动便签
  `suspend(covering: .infinite)` 藏起来（固定位置不清）、启动时关着就不 `start()`；启动器里归关着的功能的收藏只藏不删；
  `Launchpad.turnOff()` 放掉图标位图；跨功能的入口（剪贴板 ⌘T / 「钉到屏幕」、启动器 cb / fy、截图工具栏的翻译和录屏、钉图的翻译）关着时不出现，
  `run(_:)` 等几处再兜一道。设置页的变灰是 `.gated(by:)`（`.disabled` + 乘禁用不透明度：分组表单里光 `.disabled` 标签不变淡，屏外实测）。
- 评审后一轮（一个只读评审 agent，没查出崩溃 / 丢数据）：三块主面板加「建过没有」的弱引用（`builtClipboardPanel` 等），收起时只收建过的——
  原来打开设置窗、呼出别的面板都会为了收起把三块面板建出来，关着的功能也一样；钉图在 `PinBoard.pin` 一处挡（角落缩略图、剪贴板都走它，
  缩略图上的钉图钮和菜单项跟着藏）；菜单栏「只有一项、节标题和它同名」的节不画节标题（关掉剪贴板后只剩「启动器」那一节）；
  关翻译时浮窗没开着也直接停请求和朗读；启动器「全开时的列表」只算一次、不进缓存（`actions(_:caching:)`）。
- 验证：单测 `FeatureTests`（分节、启动器内置动作和收藏只藏不删、速查表、迁移、注册默认值）、`SettingsArchiveTests.listsFeatureSwitchLosses`；几条原来读活偏好的
  分节 / 速查表单测改成喂全集（用户在 Dev 版里关了功能也不挂）；截图自检 `SnapshotProbeTests/features()`。手测 `HANDTEST.md`「功能开关手测」1–14。

### 程序坞预览（第九族，0.7.0，2026-10-22 立项）

- 用户 2026-10-22：要 wins.cool（付费闭源）里的 Dock Preview——鼠标停在程序坞的 App 图标上，弹出它所有窗口的缩略图。
  调研和拍板页在 `build/research/dock-preview-2026-10-22/`（`decisions.html`，17 项**全部按推荐**；探针源码在 `probe/`）。
  集成进 Kitty 当第九族、不新开项目（授权、浮层、截窗口、设置、更新都现成）；进 0.7.0（0.6.0 照原计划先发）；主会话在单独的检出
  `kitty-tools-macos-dock`（分支 `dock-wip`）分批做。
- 对标：DockDoor（6.4k 星，GPL-3.0，最像）、AltTab（16.4k 星，⌥Tab 切换器，列窗口 / 切窗口的做法）、DockPeek（只用公开接口）；
  **都是 GPL 系，只借做法、不拷代码**。
- **私有接口**（用户 2026-10-22 拍板 A1「四个都用」，同日又同意加查桌面的那个；全在 `DockPreview/WindowServer.swift`，跑起来时
  `dlopen` / `dlsym`，取不到就退回公开做法）：`_AXUIElementGetWindow`（辅助功能的窗口 → 编号；退回按标题 + 位置大小配）、
  `CGSHWCaptureWindowList`（截窗口；退回 ScreenCaptureKit，只截得到当前桌面上的）、`CGSCopySpacesForWindows`（在哪个桌面；
  取不到就不列别的桌面上的）、`_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo`（按编号切过去、当 key；退回
  `NSRunningApplication.activate`）；配套 `CGSMainConnectionID`、`GetProcessForPID`（废弃的公开函数，直接调有警告）。
- **本机实测**（macOS 27.0.1，2026-10-22；第 1 批探针 `DockPreviewProbeTests`，Debug）：七个符号都在；程序坞一个 AXList、
  App 图标子角色 `AXApplicationDockItem`、都带 AXURL，`kAXSelectedChildrenAttribute` 读得到，观察者挂得上（停上去发不发通知要
  真机手测）；ScreenCaptureKit 截全屏桌面上的窗口报错，私有接口截得到、不是空白；私有 1x 截 + 缩到 520 × 280 一扇中位 15 ms
  （缩小画进 8 位 BGRA；评审前画进原图的颜色空间、没指定字节序时中位 32 ms）——ScreenCaptureKit 直接出缩略图 35–85 ms，
  再加 `SCShareableContent` 23–44 ms，所以一律用私有的；`CGSCopySpacesForWindows` 问 112 扇共 2.6 ms；列一个 App 的窗口
  （辅助功能 + 全表）中位 18–20 ms、最长 26–50 ms（Chrome），在主线程。
  **微信关掉的聊天窗口还留在窗口服务器里、不在任何桌面上**：不查桌面就会被当成「在别的桌面」。
  **还没验的三样**（拍板页说第 1 批验，要真机、要人在场，挪到手测 HANDTEST「程序坞预览手测」1–3）：鼠标停到图标上程序坞发不发
  选中变化的通知、最小化的窗口私有接口截出来是不是全透明（代码两种都接得住：全透明当没截到，用上次的图或 App 图标）、
  跨桌面 / 全屏 App 按编号切过去并当 key 准不准（不准时退回 activate）。
- **做法**：听程序坞 AXList 的 `kAXSelectedChildrenChangedNotification`（`DockWatcher`；每 5 秒体检一次，程序坞重启、重建界面、上次没挂上
  都重挂——程序坞是 LSUIElement 的 App，系统不发它的启动通知）；列窗口 = 辅助功能
  `kAXWindows`（当前桌面 + 最小化）+ 全表里在别的桌面上的（`DockWindows.merge`：标准窗口和对话框、宽高 ≥ 100 点；全表拿不到子角色，没标题、整个套在同一 App
  另一扇别的桌面上的窗口里的当成表单不列；按编号即打开
  先后、最小化的最后）；缩略图停上去当场截、在主线程外缩，上次截的最多留 20 张（`WindowShots`，空闲回收和关掉功能时清掉）；切 = 显示隐藏的
  App、还原最小化的、按编号拿到最前、发一条「当 key」的事件、设主窗口并抬起（事件照 AltTab 踩过的坑写：缓冲区 0x100 清零——
  0xf8 会让系统读到堆上的垃圾闪退；只发按下——按下 + 松开在 Figma、Telegram 里会点到左上角的按钮；坐标在窗口右下方很远——
  NaN 会被纠成 (0, 0)，贴着窗口边在 macOS 27 上会把窗口拉大）；关 = 按关闭钮（别的桌面上的没有辅助功能对象，不给 ✕）。
- **默认关**（拍板 A3）：`Feature.defaultOn`，程序坞预览注册成 false（导出只带存过的值，导入旧文件会回到关）；运行中打开时缺
  辅助功能就弹系统的授权框，有了再要屏幕录制（`AppDelegate.applyFeatures`；启动时不问）。导入会不会打开它不进
  `SettingsArchive.privacyLosses`：缩略图只在内存里、不往外发。
- **面板**（第 2 批）：普通 `NSPanel` 实例（不子类化，mac-overlay-panel §1）+ 宿主 `PreviewHost`（`acceptsFirstMouse`）；材质和
  OverlayPanel 共用 `OverlayPanel.makeBackground`（改成 internal）；第一次弹时建；空闲回收时收着的面板整块放掉（`DockPreview.reclaim`）。
  **收不收按鼠标位置**：弹着时每 0.1 秒看一次鼠标在不在面板、图标和两者之间那道缝里（`keepsOpen`），离开满 0.3 秒收
  （`Linger`）；同一个定时器里别的功能（启动台、状态屏、截图框选）一来就收。不用追踪区的进出（面板改尺寸会重建追踪区、
  淡出时进来的事件会丢，评审 H1），也不全信程序坞的选中。切到别的桌面立刻收（2026-10-23 手测：鼠标还停在面板那块、
  按位置一直算「在附近」）；面板不用 canJoinAllSpaces、用 moveToActiveSpace——原来在所有桌面上，切桌面时被带到新桌面上，
  等切完收到通知再收会闪一下（同日第二次手测报的），现在跟着旧桌面滑走。点了面板以外（全局 + 本地监听）立刻收，点的是那个图标就记下，
  鼠标离开它之前不再弹；按着鼠标拖东西经过程序坞不弹。弹出前重读一次图标位置（放大、自动隐藏的动画），屏按离图标最近的
  那块选；程序坞的 AXURL 和进程的 bundleURL 都解开链接再配（/Applications/Safari.app 是链接），配不上按 bundle id。
  **放不下就换行**，不用滚动视图（面板不当 key，滚动视图里的点击、只有竖滚轮的鼠标都靠不住）；排满这块屏还放不下的不列。
  换图标：窗口帧 glide 的贝塞尔近似 0.26 s，内容铺满宿主、两排叠在一处交叉淡变；入场同 OverlayPanel（淡入 + 6 点弹回，
  方向朝着图标）；收起淡掉窗口自己的透明度（永不当 key，不用替身）。
- **快速划过程序坞**（2026-10-26 手测反馈：一路冒出好几个预览、动画卡顿掉帧）：原来每路过一个图标就在主线程列一遍窗口
  （辅助功能，20–50 ms）、重排、开一段 0.24 s 交叉淡变，几段淡变叠在一起、主线程被堵。改成弹着时换图标停稳 80 毫秒才换
  （路过的不列不画），等着换的那个图标也算在附近（面板不收），0.3 秒内连着换的不淡变；配进程不再逐个解开所有 App 的链接
  （先按路径、再按 bundle id）。没量帧数（要真在程序坞上划），靠手测 HANDTEST「程序坞预览手测」17。
- **压住程序坞的名字提示**（2026-10-23 手测反馈）：提示画在程序坞那块铺满屏的窗口里（层级 20，悬停时不另开窗口），面板在它
  上面。原来离图标框 +6，面板底边在看得见的图标上方 20 点，提示的三角（图标上方约 8 点）和气泡下沿从缝里露出来；程序坞给的
  图标框比看得见的图标高约 13.5 点。改成压进图标框 6 点（底边离图标约 7.5 点，盖过三角尖），面板至少和提示一样宽（14 点字的
  App 名 + 27，各多 4）。数是程序坞在下面、没开放大时悬停截图量的（量法：后台小程序在面板出现时自己截屏）。
- **进度**：第 1 批（2026-10-22）底层四个文件 + 纯函数单测 `DockPreviewTests` + 按需探针 `DockPreviewProbeTests`
  （`TEST_RUNNER_KITTY_DOCK_PROBE=1`，只读、不动屏幕）。第 2 批（2026-10-23）面板、控制器、排法，功能开关（默认关）、
  设置 › 程序坞预览、空闲回收，截图自检 `SnapshotProbeTests/dockPreview()`（`dock-preview-*`、`settings-dock-preview*`）；
  两名评审（正确性 / 规范）提的都改了。第 3 批（2026-10-23）屏上量内存（`DockPreviewMemoryProbeTests/memory()`，Debug：14 扇、976 × 417 点的面板弹出 +10.6 MB，
  收起只清内容照样 +10.5，整块放掉后 +4.5，两遍不累积）→ 空闲回收时放掉收着的面板；CPU 只在弹着时有一个 0.1 s 的定时器
  （读一次鼠标位置、比几个矩形），收着时 0；新规则 `mac-dock-preview` + `mac-whisker-dock-preview`（技能目录各有链接）。
  MARKETING_VERSION 0.7.0 和更新日志并回 main 时（0.6.0 发布之后）才升，免得 dock-wip 先占了版本号；更新日志那句写「默认关，
  在 设置 › 程序坞预览 里打开」（拍板 A3）——2026-10-24 随全局同步并进 main 时升了、写了。

### 刘海岛交互（0.7.0，2026-10-26 立项）

- 用户 2026-10-26：「灵动岛的通知非常鸡肋，又不能交互」。只改通知本身，不重启 10 月那套常驻刘海（2026-10-03 定了先不做，
  调研和拍板页在 `build/research/notch-*`）。拍板页 `build/research/island-interactive-2026-10-26/decisions.html`，10 项
  **全部按推荐**：A1 只改通知（改 Whisker S2 的「窗口不接鼠标」）；B1 悬停停住并展开成卡片；B2 平时露最主要的一个按钮；
  B3 点岛 = 打开类动作（撤销这类只能点按钮）；B4 × + 双指上滑；B5 悬停时新提示排队；B6 动过才算悬停 + 0.3 s 防误点；
  C1 按场景表加按钮；D1 提示历史先不做；D2 不加「只在出错时弹出」的开关。
- 对标：系统通知横幅（悬停出按钮和 ×、能滑走）、HIG 的通知（最多 4 个按钮、不放「只是打开 App」的按钮、优先不会出事的动作）
  和实时活动（轻点打开到相关的地方、按钮只放必要的）、截图工具截完的小浮层（悬停出复制 / 保存）。
- 做法（规矩在 mac-whisker S2、mac-overlay-panel §8「轻提示」）：窗口平时不接鼠标，开着时按指针位置开关（全局 + 本地鼠标移动
  监听，悬停期间 0.2 s 复核）；离开后接着走剩下的时间（至少 1.5 s）；按钮 `Island.Action`，常用的 `.settings(for:)`、`.reveal`、
  `[Island.Action].file`；`dismiss(ifShowing:)` 收进行中提示；`Island(showing:)` 不建窗口。
- 第 1 批 `109c85a0`（岛本身；评审一轮 7 条都改了）、第 2 批 `3c9d45cb`（按 C1 的表接按钮，约 40 处：授权 12、去设置 2、存成文件 12、
  开关 2、能撤的删除 2、进行中 4、重试 3、更新 2），在单独的检出 `kitty-tools-macos-island`（分支 `island-wip`）里做。
  **没自动验的**：屏上的悬停和点穿（要挪真鼠标，没跑）——挪到 HANDTEST「刘海岛交互手测」。屏上临时探针只验了展开、进行中、
  出错抖动这几种画面在真窗口里不陷进排版循环（9 轮）。
- **主动叫出来**（`c8595f5b`；同日用户试了测试包：「不能手动交互吗，现在只能被动交互」；问了三项都按推荐）：没有提示时点刘海（指针停在
  刘海上先鼓起一点），或者按全局快捷键「打开刘海岛」（默认不设键；没有刘海的屏只能用它），长出「那一张」：一排快捷动作 +
  本次启动以来最近 10 条提示（只留打开类的按钮）。`HotKeyAction.feature` 改成可选：「打开刘海岛」不属于任何功能、一直在，
  一节「刘海岛」排在最后（菜单栏、启动器、快捷键页、速查表都有）。不做：最近复制的几条（和 ⌥C 面板重复、隐私）、录屏计时
  这类常驻的「活动」、悬停就展开（划过刘海去点菜单栏会误开）。
- **修了一个崩溃**（`0077692a`）：岛的宿主原来直接当窗口的 contentView，SwiftUI 按内容改窗口最小 / 最大尺寸，窗口画过内容后再改大小就在
  「更新约束」里死循环崩掉——第 1 批的测试包里刘海屏和外接屏换着弹提示就可能踩到；宿主包进普通容器后屏上探针过了。
  开过一次那一张后常驻多约 3 MB（窗口加高后的图层，收起也不还；探针量的 phys_footprint）。
- **动画卡顿**（同日用户试了测试包：「灵动岛的交互动画存在卡顿」，让参考 GitHub 上的高星开源项目）：照 10 月调研
  （`build/research/notch-oss-shell.md` §B、§5.3：boring.notch、NotchDrop、DynamicNotchKit、jackson-storm/DynamicNotch、
  CodeIsland 等九家）改成一份几何驱动形体和遮罩、内容按最终尺寸排好被裁出来；形体只跟正在出场的内容（不再先宽后窄）；
  收起时内容淡出和形体缩回同时走（原来中间停 0.08 s）；鼓起改 0.2 s easeOut；那一张不做模糊动画、小块模糊半径 8 → 4；
  窗口一次定成最高的尺寸（开那一张不改窗口大小；量过常驻内存和开过一次那一张一样）。新加按需探针
  `IslandFrameProbeTests`：主线程每拍的间隔改前改后都只零星掉 0–4 帧（主线程本来就不是瓶颈）；逐帧实录要 Dev 版有屏幕录制
  授权，这次没跑成（系统拒了），手测 HANDTEST 23。用户再试：「刘海回收的最后一瞬间会卡顿，hover 进入后退出也存在」
  （录屏是 Kitty 自己的录屏录的，按规矩不录岛，只看得到鼠标停在刘海上再离开）——收起的终点比刘海宽 2、带 6 的耳朵，
  窗口移走时那几点黑边一下子没了；改成收起缩进真刘海里面（`IslandGeometry.tucked`），移走窗口前等 0.6 s。用户再试：
  「顺了，但是觉得现在的过渡动画没之前好看了」——把修卡顿时顺手改淡的三样改回原样（内容出场 blur 8 / scale 0.9 /
  smooth 0.28 / 晚 60 ms，那一张也模糊；收起先退内容、0.08 s 后再缩；鼓起 `pop`），结构上的几处（一份几何 + 遮罩、只跟
  正在出场的内容、收起缩进刘海、窗口不改大小）留着。

### 晾衣绳（第十族，0.7.0，2026-10-26 立项）

- 用户 2026-10-26 看了开源项目 tendedero（MIT，把截图挂在屏幕顶部一根绳子上）后要求集成进来，当作截图的第三种展示方式。
  **只借做法、不抄代码**；它的名字和图标不在 MIT 范围内，所以中文名叫「晾衣绳」、图标自己画，界面里不提任何别家产品。
  拍板页 `build/research/clothesline-2026-10-26/decisions.html` 和 SPEC.md，**全部按推荐**：A1 名字 / A2 归截图家族（不新增功能开关）；
  B1 和右下角的常驻缩略图二选一（设置 › 截图「截完图放哪」三选一）、B2 绳子是截图历史的一个视图（挂着的打个标记，取下只改标记）、
  B3 最多 8 张、屏幕窄时按宽度减、不自动消失、不跨重启；C1 停菜单栏 0.3 s 滑下来 / 离开 0.4 s 收 + 一个可设的全局快捷键、
  C2 中间断开给刘海岛让位、C3 单击拷贝 / 双击改标注 / 拖出去 / 右键一整套（不做用力点按、不做系统「标记」）；
  D1 保留常驻缩略图那张卡的做法、换上夹子和摇摆、D2 取下不问（东西还在历史里）、D3 只在鼠标所在的那块屏、全屏时不出来。
- 四批（都在这个检出里串行做，每批一个提交）：第 1 批 `758ba482` 顶部那块地方（窗口、层级、滑下来 / 收起、跟着鼠标换屏、
  全屏躲开、中间让位）；第 2 批 `56a5c487` 卡片（内容和操作、夹子、摇摆、取下、单击 / 双击 / 拖出 / 右键）；
  第 3 批 `21055d34` 和截图家族接线（「截完图放哪」三选一 + 偏好平滑过渡、飞行卡片落点改成绳子上那个位置、
  截图 / 长截图 / 录制都能挂）；第 4 批收尾（快捷键和菜单栏入口、速查表、无障碍、文档）。
- **线、夹子、动画重做了一轮**（`a6d3bdf1`；2026-10-26 用户手测反馈：「线要优化、夹子要真像夹子、挂上去没动画、
  动画要物理驱动，有引力的那种」。样机 `build/research/clothesline-2026-10-26/mockup.html` 里那份 verlet 照搬成
  `ClotheslineRope.swift`）：线改成细线 + 投影（端点钉在面板上沿以上、藏在菜单栏后面，同日用户要求不让人看见），夹子改成木夹子（两片 + 中间一道弹簧弧），
  **绳子变成 34 个质点的物理**——挂上去是落下来、咬住绳子，摆动、让位、取下的回弹全是物理带的，卡片没有自己的动画；
  `CADisplayLink` 驱动、全停了就停表，减弱动态效果时整个不跑。绳子垂多深是量出来的，面板按它留地方。
  偏离样机的两处：落差 180 → 26（面板上沿贴着菜单栏，落得再高会被裁、飞行卡片的落点还会跑出屏幕），
  「y −26、x +8」那个脉冲用在取下的回弹上（落地那一下只按样机压低 6 点，不然卡片一挂上去绳子反而往上弹）。
- **同日用户又提了两条**（同一个提交的后续）：**弧度小一点**——垂度 26 → 12、每帧约束迭代 24 → 64
  （verlet 的约束是软的，迭代少了重力就把绳子拉得很深，**绷紧它比调垂度管用**），跨度 646 从垂 95.8 点变成 66.3，
  面板从约 235 点高收到 203；**空绳时别让卡片等绳子**——截图一出图（卡片刚起飞）就把绳子滑下来等着
  （`Clothesline.prepare(on:)`），原来是卡片先停在半空、过一会儿绳子才滑下来，看着像「飞到一半又回来」；
  等不来那张（截图取消了、没拷成）绳子自己收。
- 做法和红线在 `.cursor/rules/mac-overlay-panel.mdc` §14，长相在 `mac-whisker-capture.mdc`「晾衣绳」，手测在
  `HANDTEST.md`「晾衣绳手测」1–22（真机都还没走）。
- **自动验不了、只能真机看的**：停菜单栏多久滑下来的手感、挡不挡菜单、点不点得穿、全屏时出不出来、拖到废纸篓 / 文件夹 /
  别的 App 的落点、刘海屏中间让位看着对不对——屏外渲染只锁得住排法和长相。

## 11½. Whisker 设计语言改造（2026-09-25 起）

已归档到 `docs/archive/PLAN-12.md` §11½（A–E 各阶段的内容、状态和 2026-09-26 的交接）。现状：A 基础与招牌时刻、B 界面重做、C 品牌、E 截图重设计都已完成（待手测）；D 深度只剩「macOS 26 玻璃 + `.icon`」——玻璃分支第 11 批已写好，等 26 测试机按 `HANDTEST.md`「macOS 26 手测」实测，`.icon` 也等 26。规范正文在 `.cursor/rules/mac-whisker.mdc`（核心）和各 `mac-whisker-<界面>.mdc`。


## 12. 进度与交接（2026-09-24，新会话从这里接着做）

> 2026-10-03 瘦身：原来的完成记录和整段的「下一步」「暂不发版」「发布」「接手须知」原样挪到 `docs/archive/PLAN-12.md`；**手测清单**（原「待用户手测」那一大段）原样挪到 `HANDTEST.md`，条目和编号不变——代码注释里的「PLAN §12 第 N 条」「§12「录屏 / 录音手测」N」「§12「macOS 26 手测」第 1 条」都去那里按小节名找。新的手测条目加在 `HANDTEST.md` 里。

**2026-10-26：晾衣绳（第十族，0.7.0）**（§10「晾衣绳」）：拍板「全部按推荐」；四批在从 main 切出来的
`claude/clothesline-110f0a` 工作树上做完（`758ba482` / `56a5c487` / `21055d34` + 收尾），**没 push、没并回 main、
没动 `MARKETING_VERSION`**（更新日志加在已有的 0.7.0 条目里）。待手测 HANDTEST「晾衣绳手测」1–22；
自动验不了的那几样（手感、挡不挡菜单、点不点得穿、全屏、拖拽落点）在 §10 那一节末尾列着。

**2026-10-26：刘海岛交互（0.7.0）**（§10「刘海岛交互」）：拍板「全部按推荐」；两批在 `island-wip` 做完，同日用户试了
测试包要「主动叫出来」，第三批（点刘海 / 快捷键叫出「那一张」，修窗口改大小的崩溃）也在 `island-wip`；没 push、没并回 main；
待手测 HANDTEST「刘海岛交互手测」1–23。

**2026-10-24：0.7.0 并进 main**（用户要求，0.6.0 发布之后）：`sync-wip`（程序坞预览三批 + 手测反馈、全局同步第 2–5 批）以合并提交 `c2dca076` 并进 main（main 为第一个父提交，冲突只在 AGENTS / PLAN 的文档），`MARKETING_VERSION` 升到 0.7.0、`changelog.json` 加 0.7.0（照 §10「全局同步」的草稿 + 程序坞预览一句）；全量单测过。没 push、没打包、没发布。待手测 HANDTEST「全局同步手测」1–18、「程序坞预览手测」1–14；`perf-wip` 还没复查、没进来。

**2026-10-24：0.6.0 已发布**（tag `macos-v0.6.0`，latest；用户要求发布，从 `147e54b3` 的干净检出打的包，更新日志日期改成当天；发布说明照 0.5.0 的格式，「从旧版升级」写了启动台只在 macOS 26 起出现、功能开关默认都开、便签同步每台都要先更新、包变成 11.4 MB。启动台手测、功能开关手测、便签四个新功能和同步的手测（`HANDTEST.md` 270–295）、发版冒烟清单都没走完，照旧待做）。0.7.0（程序坞预览 + 全局同步）在 roadmap 检出的 `sync-wip`，接下来并回 main；`perf-wip`（便签上千条的调优 + 修稳两条偶发单测，2026-10-21）还没复查、没进 main。

**2026-10-24：全局同步（0.7.0）**（§10「全局同步」）：拍板「全部按推荐」；第 1 批（挪位置）在 main（0.6.0），第 2–5 批（引擎；片段、收藏、生词本；
搜索、翻译服务、启动器收藏；设置、快捷键、功能开关、状态屏的状态）在 roadmap 检出的 `sync-wip` 上各一个提交，程序坞预览（`dock-wip`）也合进了 `sync-wip`
（0.7.0 一条线，main 保持 0.6.0）；没 push、没打包。待手测 HANDTEST「全局同步手测」1–18；保留天数、「不记录」的 App 这几项继续同步（用户 2026-10-24 定，§10 第 5 批）。

**2026-10-22：程序坞预览（第九族，0.7.0）**（§10「程序坞预览」）：拍板页 17 项全部按推荐；主会话在 `kitty-tools-macos-dock`（分支 `dock-wip`）
分批做，第 1–2 批（底层、面板和设置页）在 dock-wip 上，没并进 main（main 要先发 0.6.0）；待手测 HANDTEST「程序坞预览手测」1–14
（1–3 是第 1 批没能自动验的）。

**2026-10-22：功能开关**（§10「功能开关」）：八个功能都能在 设置 › 通用 › 功能 里整个关掉；在 `features-wip` 上做完并提交，没并进 main、没打包，
待手测 `HANDTEST.md`「功能开关手测」1–14。

**2026-10-19：0.5.0 已发布**（tag `macos-v0.5.0`，latest；用户要求发布，从 `6a6b692a` 的干净检出打的包，更新日志日期改成当天；发布说明照 0.4.0 的格式，「从旧版升级」写了示例便签、⌥N、便签单独存、包变成 10.8 MB。发版冒烟清单「便签」38–52、便签手测、调优手测都没走完，`HANDTEST.md` 照旧待做）。启动台（0.6.0）还在 `launchpad-wip`，没并进 main。

**2026-10-18：任务方框改成自己画的圆角方框**（`build/research/notes-taskbox/SPEC.md`，用户选的「A · 圆角方框」；用户让主会话直接做，在 notes 检出做完并回 main，随 0.5.0 发布）：正文里存的五个字不变、照常排版占 ☐ 那么宽（`boxMetrics` 简化成同一种字体 + kern，不再缩字号、不再 `baselineOffset`），字上记状态和颜色（`taskBoxKey` / `taskMarkKey`、`Theme` 多五个颜色）；`NoteLayoutManager.drawGlyphs` 把方框字切出来不交给系统、改调新的 `Notes/NoteTaskBox.swift` 画（几何按字号算、取整到屏幕像素，竖向对着 capHeight / 2）。便签墙卡片的正文从 `NSAttributedString.draw` 换成 `NoteWallCard.layout`（同一个布局管理器，量高和画同一套；单测比过和原来的高度一样，截图逐张比过字的位置没变；代码块那几行的底因此铺满一行宽）。量测（Debug，同一种构建前后各一次）：500 条任务整篇画一遍 12.5 → 16.5 ms（一屏二十来行，每帧多约 0.2 ms）；`NotesProbeTests/switching()` 各项前后在误差内；墙卡片量高 300 张约 20 → 41 ms（每张多约 0.07 ms，卡片是边看边建、建完缓存的；一套排版反复用也一样，差别不在建排版上）。新单测 `NoteTaskBoxTests` 5 条，随机探针 4 万步种子 1 / 1001 零差异。没在真 App 里看过：Retina / 非 Retina 屏的像素对齐、增强对比度那一档（读系统开关，屏外没法切），待手测「便签手测」264；未来计划里方框那条拿掉了。

**2026-10-18：调优一批**（`build/research/tune-2026-10-18/SPEC.md`，主会话直接在 main 上做，三个提交 + 「未来计划」一个提交，随 0.5.0 发布）：T1 全部便签窗口和设置窗的内容包进普通容器（`NSViewController.windowContent`），修 0.5.0 测试包的一次约束死循环闪退（屏外复现了、有回归单测，规矩记在 mac-overlay-panel §1）；T3 编译警告清零（SPEC 的 5 条 + Xcode 27.1 新出的 3 条）；T2 便签接进空闲回收、空闲时放掉关着的全部便签窗口（§10「常驻内存」末条）；设置 › 关于 加「未来计划」（下面「已知的小毛病和以后的大功能」）。待手测 `HANDTEST.md`「调优手测」1–3。

**2026-10-18：便签第 9 批（收尾）**：八批代码全部做完，0.5.0 没打包没发布。这一批只动文档、许可和死代码：更新日志 0.5.0 的便签条目合并成 10 条讲现在能做什么（日期改成 2026-10-18）；`HANDTEST.md` 的发版冒烟清单加了「便签」15 步（38–52），便签手测的节头写明先走这 15 步；PLAN §10 的各批实现记录原样归档到 `docs/archive/PLAN-notes.md`，这里只留每批一行摘要；规则和代码对齐（`mac-overlay-panel` §3 §12、`mac-whisker-notes`、`mac-translate` §5、`mac-clipboard` §1）；Noty 的 MIT 许可全文随包在 `Resources/notes-LICENSE.txt`、关于页加了出处。**0.5.0 现在只差真机手测**：发版前先走「发版冒烟清单 › 便签」15 步，再按各节「先做」补；测完改版本号、打包含经用户确认。第 9 批的验证：单测全过、随机编辑测试 2 万步零差异、偏好 plist 的 md5 前后一致、关于页截图浅色 / 深色各一张、包里带着许可全文。

**2026-10-12：0.4.0 已发布**（tag `macos-v0.4.0`，latest；用户要求发布，从 `49ca527c` 的干净检出打的包；状态屏和视觉对齐的真机手测没走完，`HANDTEST.md` 两节照旧待做）。同一天便签立项（§10「便签」，0.5.0）：拍板页 25 项全部按推荐，分 10 批（2026-10-18 十批全部做完），逐批摘要看那一节、详细记录在 `docs/archive/PLAN-notes.md`。**便签第 2 批（2026-10-13）之后 main 是 0.5.0**：便签有了入口（快速记一条 ⌥N、全部便签窗口、设置 › 便签），`MARKETING_VERSION` 改成了 0.5.0、更新日志有了条目，没打包没发布；第 3 批（2026-10-13）做了屏幕边缘那叠（先走 `HANDTEST.md`「便签手测」39–75），同日用户真机试过后的手测反馈第 1 批（修了扇出收回后必崩、焦点、拖动排序抖、示例便签、快速记一条的标题、颜色菜单的圆点；§10「便签」，待手测 76–85），第 5 批（2026-10-13，提到第 4 批前面做）换了便签专用的正文编辑器（显式搭的 TextKit 1），做了任务、便签内查找，修了「便签里不能撤销、全 App 没有重做」，加了「标签倾斜」的设置（§10「便签」第 5 批；待手测 87–106，**撤销和输入法那几条（87–92）先做**），第 6 批（2026-10-13）做了 Markdown 边打边变样（标题、粗体、斜体、删除线、行内代码、引用、列表符号、链接；标记只在光标所在的行露出来，设置里可关；§10「便签」第 6 批，2026-10-14 评审后又修了一轮；待手测 107–136，**输入法和光标进出一行那几条（107–112）、撤掉组字那条（133）先做**），第 4 批（2026-10-14）做了浮动便签（把屏幕边缘打开的便签拖出来留在屏幕上，一次一张、能拉大小、固定着的重启后回到原处；§10「便签」第 4 批；待手测 137–159，**先做 137–142**——这一批真窗口一次都没开过），手测反馈第 3 批（2026-10-15：滚动条、点着换一条卡、各处去设置的入口、标签一律斜着、那叠的右键菜单；待手测 163–171）、手测反馈第 4 批（2026-10-15：正文的行距三档、标题和引用块的留白、代码块、⌘B ⌘I ⇧⌘X ⌘E、粘贴网址成链接；同日评审后又修了一轮；§10「便签」手测反馈第 4 批；待手测 172–184，**先做 172、173、176、179**）、手测反馈第 5 批（2026-10-15：全部便签窗口默认改成便签墙——卡片瀑布流、点开放大成编辑卡、方向键、拖动排序，列表视图留着、⌘1 / ⌘2 切换；用户说测试留给他，没跑全量单测、没量性能；§10「便签」手测反馈第 5 批；待手测 185–206，**先做 185–190**），手测反馈第 6 批和便签墙编辑卡动画（2026-10-16：收回回到卡片原位、浮动便签一律浮动层级、长便签切换只当场排开头一屏、第一次进墙分批建卡片；§10「便签」那两条；待手测 207–217，**先做 207–210**）、**第 7 批（2026-10-16）做了行内图片**（正文里粘贴 / 从访达拖进 / 右键「插入图片…」插图，每张独占一行、一步撤销；图片单击选中、拖右下角把手改宽度；文件找不到画占位框；图片目录 `notes-images/` 每天跟着备份、没人引用满 30 天才清；便签墙卡片顶上显示第一张图的缩略图；§10「便签」第 7 批；待手测 218–232，**先做 218–221**）。同一天/次日又做了**第 7 批评审后的一轮**（主会话审查 + 正确性评审 + 规范评审合并成 F1–F30：插图在 `\r\n` 中间越界崩溃、纯文字时「粘贴」变灰、比正文宽的图被压扁盖住上一行、组字时欠着的插图补上后交出去的正文把图丢了、剪贴板里同时有字和图时进来的是图、那叠的「插入图片…」一开面板就收起便签、缩略图缓存死循环 / 闪纸色 / 竖图糊、拖把手松手后临时宽度没清、拒收时刘海岛那句话出不来、只有图片的行让摘要和标题重复、令牌原文在几处露出来、粘贴网址把图换成坏链接、读屏位置错一位、先挑 TIFF 又按原始大小卡 20 MB、任务行里插图被挤到下一行、插完光标留在图那一行（改成图下一行）、图后折行每行都和图一样高、悬停在图片行行首组字时图跳、`setFrameSize` 里当场重排、字数和搜索把令牌算进去；§10「便签」那一条有全部 30 条的记录和「偏离 SPEC 的地方」）。**第 8 批（2026-10-17）做了 Markdown 文件夹导出 / 导入、文字颜色、任务五种状态，以及「便签开着时从剪贴板 / 启动器粘贴落进便签」「便签里划词翻译读便签选区」（拍板 E①③ 的启动器 / 存成便签用户去掉）。**0.5.0 等便签几批做完、手测过再发**（`HANDTEST.md`「便签手测」；从这一批起已经没有「导出表单上有便签、却没有入口」的问题）。已发布的 0.4.0 读不了格式 2 的导出文件（会说「先更新再导入」）；这期间要修 0.4.x 就从 tag `macos-v0.4.0` 拉分支。

**2026-10-18：便签第 8 批之后的一轮**（单条导出、格式菜单、格式合并）代码做完、待手测 `HANDTEST.md` 254–257：粗体 / 斜体 / 删除线 / 颜色改成「整段一种」（原来碎成几段的合成一段、全选再加同一种不再拆开），右键「格式」补齐链接、标题 1–3、引用、列表、代码块、清除格式，单条便签能导出成和「导出全部」同一种 `.md`。单测 1183 → 1200（新 `NoteBatch8bTests` 15 条；`NoteTextViewTests` 加菜单勾 / 停用和各项动作两条，改右键菜单、行内代码里的斜体两处；`NoteFloatTests` / `NoteDeckTests` / `NotesWindowTests` 跟着菜单多一项、菜单行数 10.5 改断言）。随机编辑测试加了块格式 / 链接 / 清除格式 / 同色再上一次，种子 1、1001、3001 各 4 万步零差异，另跑种子 2001 那批（含 2019）也零差异；全量两遍，偏好 plist 的 md5 前后都是 6e33779281e6bd3c4e48bccdad683ba0。没改版本号（还是 0.5.0）。

**2026-10-10：0.3.2 已发布**（tag `macos-v0.3.2`，latest；用户要求发布，下面各节的真机手测照旧待做）。同一天 `MARKETING_VERSION` 升到 0.4.0：状态屏（§10「状态屏」）第 0–5 批都已提交（第 4、5 批是用户装上测试包后要的：按快捷键先选状态、告示改用动画表情），**没发布，自动化从没进过状态屏**（它会拦住键盘鼠标），发布前先走 `HANDTEST.md`「状态屏手测」1–30，第 1 条确认出得来再往下。2026-10-11 又加了第三轮（小字到秒、退出密码，§10「状态屏」），代码做完、待手测 29、30。2026-10-12 第四轮（眼睛从四条边随机探头）代码做完、待手测 31。同一天做了全 App 的视觉对齐（§10「视觉对齐」，五批已提交），待手测 `HANDTEST.md`「视觉对齐手测」1–20。同一天把录制 HUD 的计时从 numericText 换成图层（§10「录制 HUD 的计时」：录制期间这一行原来占 8–11% CPU，现在 0.2%），待手测「录屏 / 录音手测」68。

**现状（2026-10-08）**：`MARKETING_VERSION` 是 0.3.2（0.3.1 发布后第一批：「呼出面板时挤压弹开」转正、单独成「动效」组，逐帧动画限 60 Hz；剪贴板列表条目多了高亮错位、↑↓ 和滚动卡：改成只画可见区附近、上下按前缀和撑开，去掉 `move(by:)` 里的平方级查找；翻译历史同样只画可见区附近，两边共用 `ListWindow`；AI 服务填 OpenCode 地址时补上它要求的会话 ID 请求头，不再报 400；设置里的有序列表不再封顶 10 行——表单里的 List 不能滚，第 11 行起原来看不到；模型建议下拉单行截断；三块面板关闭时泛白：系统的窗口淡出丢了毛玻璃的压暗，改成替身窗口淡出，屏上逐帧实测不再冲亮；剪贴板加开关「单击条目直接粘贴」（设置 › 剪贴板，默认关：仍是单击选中、双击粘贴）；有新版本时的提示加常驻入口：菜单栏图标右上角的小圆点、剪贴板面板和启动器底栏的「更新到 x」，已发现的新版本复查期间不清；常驻内存（§10「常驻内存」）：面板描边和卡片高光换成不带位图的画法，面板都收起两分钟后清透镜缓存和链接预览头图的缩略图、放掉识字模型、把空页还给系统，`HANDTEST.md`「0.3.2 手测」11、12、14、17；设置 › 通用加「导出与导入」（§10「设置的导出与导入」）：设置、快捷键、翻译服务、网页搜索与快捷链接，加上片段、文字类的收藏和收藏夹、生词本存成一个 JSON 文件，密钥可选、用密码加密，手测 13；动作菜单用 ↑↓ 选到一节的第一行（剪贴板 ⌘K 的「删除」）时只滚出分节线、选中的行看不到：分节线和行包成一个视图，手测 15；删除、清空、放弃这类危险操作和它们的二次确认统一用危险色 `Style.danger`（用户要求以后统一，规矩在 mac-whisker §3「危险色」），手测 16；设置与数据每天自动备份一份、能从备份恢复、导入前先存一份（§10「设置与数据的每日自动备份」），手测 18；启动器新增 port：kill 同一份进程的端口视图（§10「启动器 port」），手测 19）；已发布 0.1.0、0.2.0、0.3.1（2026-10-03 用户要求，tag `macos-v0.3.1` 打在 cdb38614，latest）和 0.3.0（同日补发，tag `macos-v0.3.0` 打在 b22c7c54，用 2026-10-01 从它打的包，不是 latest；0.3.1 的发布说明连 0.3.0 的内容一起写了）。下面这些手测发布前没走完，查出的问题进下一版。
- 代码完成、待真机手测：录屏 / 录音 0–7 批和三批手测反馈（`HANDTEST.md`「录屏 / 录音手测」1–67）、剪贴板手测反馈（「剪贴板手测反馈」1–8），这些是 0.3.0；第二轮体检 1–7 批（「第二轮体检手测」1–34，23–28 只在 Dev 版上演练），这些进 0.3.1；第 8 批只动文档。
- 更早代码完成、还没手测完的（长截图、M13、2026-09-28 体检各批、第 9–13 批）在 `HANDTEST.md` 各自的小节；系统设置面板还要逐个核对能跳到（「体检第 6 批」第 3 条）。
- 等 macOS 26 测试机：液态玻璃分支（第 11 批，15 上逐像素不变）按「macOS 26 手测」实测、微调、再补更新日志；D5 系统翻译的验证（§10）。

**启动台（第八族，0.6.0）**：2026-10-18 立项（§10「启动台」，规格 `macos/build/research/launchpad/SPEC.md`），在 worktree `kitty-tools-macos-launchpad`（分支 `launchpad-wip`）里做完四批、两轮审查（FIXES F1–F46、FIXES-2 G1–G30）和六轮真机反馈，2026-10-19 等 0.5.0 发布后并进 main（一个合并提交）；同日捏合跟手（GESTURE.md A）做完，系统手势开着也能用（B）等探针。没发布；手测在 `HANDTEST.md`「启动台手测」1–73，真机项（捏合、触发角、删 root 拥有的 App、滚轮方向、拖动手感）还没走。
**下一步**：先按 `HANDTEST.md`「发版冒烟清单」和「启动台手测」把 0.6.0 真机走一遍（0.5.0 已于 2026-10-19 发布，「便签手测」照旧待做）；修完发现的问题，改 `MARKETING_VERSION`（加 changelog 条目）后经用户确认再跑 `macos/build-dmg.sh` 打包发布。之后的新功能先按对标规则给用户「差距 + 推荐范围」，拍板后再分批做。

**已知的小毛病和以后的大功能**（2026-10-18 用户：「已知的小毛病都记录下来，后续逐步实现，并且放到设置中，添加一个未来计划的展示区域」）：给用户看的说法在 `KittyTools/Resources/roadmap.json`（设置 › 关于「未来计划」，`improve` 改进在前、`feature` 新功能在后，写法同更新日志：不写代码名、不提别的产品、不写 Markdown 记号）。**做完一条就从那里拿掉、在更新日志里写一条**，加了新的也往那里加，两边别对不上。开发看的位置：
- 改进（便签的已知小毛病）：① ~~任务方框改成自己画的圆角方框~~（2026-10-18 晚做完，见 §12「任务方框」，roadmap.json 里已拿掉）；② ~~粘贴进来带软换行（U+2028 / U+0085）的那几行排版歪~~（2026-10-19 做完：正文的文本存储在 `willProcessEditing` 里把它们原地换成 `\n`，一个字换一个字、长度不变，`NoteTextView.unifyLineBreaks`；仓库里已经存着的打开时换、下次改动存回去；待手测 `HANDTEST.md` 268，roadmap.json 里已拿掉）；③ ~~屏幕边缘打开着没固定的便签时，点系统「表情与符号」面板便签会收起~~（2026-10-19 做完：点别处的 global 监听按点中的窗口归哪个进程认，归「Input Methods」目录里的 App 不算点别处，`OverlayPanel.isInputMethodClick`，浮层也一样；待手测 `HANDTEST.md` 266，roadmap.json 里已拿掉）；④ ~~剪贴板面板不粘贴直接关掉后，浮动便签要再点一下才能打字~~（2026-10-19 做完：用键盘关掉的浮层把 key 还给呼出前那条便签，`OverlayPanel.dismiss(byKeyboard:)`，mac-overlay-panel §2；待手测 `HANDTEST.md` 265，roadmap.json 里已拿掉）；⑤ ~~代码块里的图导出 Markdown 时不带图片文件~~（2026-10-19 做完：导出时块里的令牌照换、带上文件，导回时块里只认导出写出去的 `attachments/<编号>.<扩展名>`，`NoteMarkdownFiles.isExported`；待手测 `HANDTEST.md` 267，roadmap.json 里已拿掉）；⑥ ~~1 MB、每行都有颜色的便签挪一下光标慢 2–3 ms~~（2026-10-19 做完：`NoteStyles.outdated` 找露着的行时让系统把同值的段并起来、并起来的一段逐行看；`NoteBatch8ProbeTests` 同一种构建（-O、屏外）改前 / 改后：挪一次光标每行有颜色 8.4 → 3.5 ms、没颜色 5.1 → 1.4 ms，打一个字 23.3 → 19.0 ms、19.2 → 15.5 ms；待手测 `HANDTEST.md` 269，roadmap.json 里已拿掉）。**五条改进都做完了**，roadmap.json 只剩四条新功能（拍板页见下面「便签的四个新功能」）。
- 新功能（§10「便签」「以后再说」里定过的）：~~iCloud 同步（做成同步文件夹）~~、~~自定义纸色（和「常用」颜色）~~、~~同时浮多张便签~~、~~图片裁切和宽度预设~~（2026-10-22 后三样做完、2026-10-23 同步做完，在 `roadmap-wip` 一批一个提交、并回 main、没 push，roadmap.json 里已拿掉，待手测 `HANDTEST.md` 270–284；同步（§10 第 7–10 批：数据层、文件夹写法、执行层、设置页）也做完进了 main；2026-10-23 拍板「全局同步」（§10「全局同步」），0.6.0 只把同步挪到 设置 › 通用，其余几类进 0.7.0（`sync-wip` 分支）；roadmap.json 已清空，待手测 `HANDTEST.md` 270–295，见 §10「便签的四个新功能」）。

**便签的四个新功能**（2026-10-19 调研、出拍板页，https://claude.ai/artifact/7GJvFLf6Q5UBxQaxJL45JM）：**2026-10-22 用户拍板，19 项全部按推荐、直接进 0.6.0**，在检出 `kitty-tools-macos-roadmap`（`roadmap-wip`）里分批做，结论和每批摘要在 §10「便签的四个新功能」。材料在主检出 `macos/build/research/notes-roadmap-2026-10-19/`（`icloud.md`、`three-features.md`、纸色推导的原型 `three-features-proto/`、生成拍板页的 `build-decisions.py`）。推荐：iCloud 走「同步文件夹」（不入会、不改发布流程；CloudKit 要付费会员 + Developer ID + 公证，所有用户重新授权一次），自定义纸色「最接近的预设 + 另记色值」分开存（0.5.0 读到超范围的颜色会夹回石板、改一下正文就写回库），裁切「另存一张新图」（改令牌写法的话 0.5.0 会把图显示成原文、30 天后删掉原图），浮动便签最多 5 张；新功能进 0.7.0，顺序 宽度档位 → 纸色 → 浮几张 → 裁切 → 同步，约 11 批。

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
