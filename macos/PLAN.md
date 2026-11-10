# kitty-tools 原生 macOS 分支迁移方案（Phase 1：剪贴板历史 + 翻译）

> 2026-10-28（第三轮体检第 7 批）：再归档一次——§10 各块的批次记录、实测、评审、「做的时候定的」和 §12 里 2026-10-22 及更早的进度原样挪到 `docs/archive/PLAN-batches-2026-10.md`，原位置留一行去处；AGENTS.md「项目概述」原来的长段挪进 §12 末尾。
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
| Foundation `URLSession.bytes(for:)`、`AttributedString(markdown:)` | 12 | SSE 流式输出、结果卡片的 Markdown（逐行认块级 + 行内） |
| CryptoKit：`Insecure.MD5`、`SHA256`、`AES.GCM` | 10.15 | 百度 / 有道签名、图片去重 hash；设置导出里加密翻译服务的密钥（2026-10-07，`Storage/SettingsArchive.swift`）；便签同步的内容哈希和冲突另存那条的编号（2026-10-22，`Notes/NoteSync.swift`） |
| Darwin `gethostuuid` | 10.5 | 便签同步认「这台 Mac」：电脑编号跟着库走，硬件编号对不上（库被搬到了另一台）就换新的（2026-10-22，`NoteStore.hostID`） |
| CommonCrypto `CCKeyDerivationPBKDF` | 10.7 | 设置导出：按用户设的密码算加密密钥（PBKDF2-HMAC-SHA256；CryptoKit 没有按密码算密钥的函数） |
| Security `SecItem*` | — | API Key 存钥匙串 |
| Foundation `URLSession.download`、`Process`（调系统的 `/usr/bin/ditto`、`/usr/bin/codesign`、`/bin/chmod`；启动器 kill / port 列进程的 `/bin/ps`、`/usr/sbin/lsof`；浏览历史 / Firefox 书签的 `/usr/bin/sqlite3 -readonly -json -init /dev/null`；共用 `Shell/Subprocess.swift`，要的输出写临时文件） | — | 应用内更新：下载更新包、解包、验签（D8）；kill 列后台进程和监听端口（体检 D12）、port 列在监听的端口和进程的工作目录（2026-10-08）；导出各家浏览器的浏览历史和 Firefox 书签（体检 D8、第 12 批） |
| 启动台触控板捏合（第八族，2026-10-18）：运行时 `dlopen` / `dlsym` 系统私有 `MultitouchSupport.framework`（不链接、不写进工程设置；找不到符号 / 设备就退回，别的入口照常），只用 `MTDeviceCreateList` / `MTRegisterContactFrameCallback` / `MTDeviceStart` / `MTDeviceStop`；**不是依赖**，跑起来才加载 | 10.x | 触控板捏合打开 / 收起启动台 |
| 程序坞预览（第九族，2026-10-22，§10「程序坞预览」）：运行时 `dlopen` / `dlsym` 系统私有 `SkyLight.framework` 的 `_SLPSSetFrontProcessWithOptions` / `SLPSPostEventRecordTo`、CoreGraphics 没公开的 `CGSMainConnectionID` / `CGSHWCaptureWindowList` / `CGSCopySpacesForWindows`、ApplicationServices 的 `_AXUIElementGetWindow` 和已废弃的 `GetProcessForPID`（不链接、不写进工程设置；取不到就退回公开做法，全在 `DockPreview/WindowServer.swift`）；**不是依赖**，跑起来才加载 | 10.x | 窗口编号、截别的桌面上的窗口、查窗口在哪个桌面、按编号切窗口并当 key |
| FinderSync：`FIFinderSync`、`FIFinderSyncController`（访达扩展 target `KittyToolsFinder`；App 里只用 `isExtensionEnabled` / `showExtensionManagementInterface()`） | 10.10 / 10.14 | 访达右键（第十一族，2026-11-08，§10「访达右键」）：访达右键菜单第一层的「新建文件」「拷贝路径」「在“X”中打开」 |
| 启动器「ip」（2026-10-28）：Darwin `getifaddrs`；SystemConfiguration `SCDynamicStoreCopyValue`（`State:/Network/Global/IPv4` 的 PrimaryInterface）、`SCNetworkInterfaceCopyAll` / `SCNetworkInterfaceGetLocalizedDisplayName`；`URLSession` 问两家外网地址查询服务（`myip.ipip.net/s`、`api.ipify.org`，只在输了 ip 停 0.3 s 后问） | 10.x | 本机的局域网 / 内网地址和网卡名，外网地址（开着代理时国内、国外看到的常不一样，两家都问） |
| 启动器系统命令（D2，2026-09-27）：`Process` 调 `/usr/bin/pmset`（睡眠、关闭显示器）和 `/usr/bin/osascript`（访达清倒废纸篓、loginwindow 的退出登录 / 重新启动 / 关机 Apple Event、`set volume`）；`NSRunningApplication` 的 `terminate` / `forceTerminate` / `hide`；`FileManager.unmountVolume`；`dlopen` / `dlsym` 系统私有 `login.framework` 的 `SACLockScreenImmediate`（锁屏，用户拍板的私有 API，找不到退回 `CGEvent` 模拟 ⌃⌘Q）；entitlement `com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`；`kill(2)` 给 kill 列的进程发 SIGTERM / SIGKILL（体检 D12） | 10.x | 锁屏、睡眠、屏保、废纸篓、退出登录 / 重启 / 关机、退出 / 隐藏 / 强制退出 App、推出磁盘、音量、结束进程 |
| 系统 libsqlite3（`import SQLite3`；本机 3.43.2，带 FTS5） | — | 剪贴板历史和翻译历史 |
| ServiceManagement `SMAppService.mainApp` | 13 | 开机自启 |
| `os.Logger`、Swift Testing | 11 / Xcode 16 | 日志、单元测试 |
| 本地化：不建 String Catalog；开发语言设为 zh-Hans，Info.plist 声明 `CFBundleLocalizations = [zh-Hans]`，SwiftUI 里直接写中文字面量 | — | 让系统自带的菜单、弹窗、关于面板显示中文 |
| `xcodebuild`、`hdiutil`、`codesign`、`spctl`、`swift-format`、`jq`（macOS 15 自带）；拿到证书后加 `notarytool`、`stapler` | — | 构建、打包、签名、格式化、changelog 校验 |
| Translation：系统翻译服务（2026-11-05，`Providers/FreeProviders.swift`；只用 26 起的 `TranslationSession(installedSource:target:)`，15 上不出现） | 26 | 离线翻译 |
| 以后可选：FoundationModels（26）、`glassEffect`/`NSGlassEffectView`（26，届时就地写 `#available`） | 26 | 不在 Phase 1 范围 |

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
- 加 1 个访达扩展 target `KittyToolsFinder`（2026-11-08 拍板 A1，§10「访达右键」）：嵌在 App 的 `Contents/PlugIns/`，开沙盒、
  Swift 5 语言模式（mac-native §3 的例外），只画菜单，活交给 App。
- 不建 SPM 包、framework，没有别的扩展，也没有辅助进程。

**文件结构**（一个概念一个文件，不预先建空目录）

| 目录 | 文件 |
|---|---|
| `App/` | `KittyToolsApp.swift`（入口 `@main enum Main`：带 `--ocr` 起的是剪贴板后台识字的子进程，只识字不启动 App；否则启动 `KittyToolsApp`，唯一的 scene 是不插入菜单栏的 MenuBarExtra，菜单栏图标在 `Shell/StatusItem.swift`）、`AppDelegate.swift`（单实例检查、组装对象、生命周期、退出和锁屏清理）、`Updater.swift`（应用内更新，D8）、`Log.swift`（统一日志 os.Logger，不记密钥、URL、剪贴板正文） |
| `Shell/` | `OverlayPanel.swift`、`HomePanel.swift`（主界面：左键点菜单栏图标打开的那块面板，全部功能一格一格排，分节和菜单同一份；纯函数 `enum Home` + 模型 + 视图，2026-10-29，§10「主界面」）、`WhatsNew.swift`（新功能标记：这一版新加的功能在菜单、主界面、设置侧栏和设置页里那一节挂「新」，清单 + 本机记账 + 规则的纯函数，`NewDot` / `NewTag` 两个小视图；2026-11-05，§10「新功能标记」）、`Feature.swift`（功能开关：十个功能各自能整个关掉（2026-11-04 加了提醒），和设置侧栏的页同名；程序坞预览默认关，`defaultOn`；新装第一次启动只开四个，`seedNewInstall`；2026-10-21，§10「功能开关」「功能管理」）、`FilePanel.swift`（从不激活本 App 的地方开系统的存储 / 打开面板：请求激活 + 面板提到 `.modalPanel` 拿到最前，关掉后还前台；2026-10-18 macOS 27 上激活被驳回、面板开在后面「点了没反应」后加）、`TransientPanel.swift`（用时再建、收起后放掉的浮层：两张 ⌘Y 大卡由它拿着，第二轮体检 M3）、`Memory.swift`（让分配器把空页还给系统，M4；空闲回收的计时 `Memory.IdleTimer`，2026-10-07）、`HotKeyCenter.swift`、`HotKeyRecorder.swift`、`ModifierTaps.swift`（连按两下修饰键的状态机，2026-11-06）、`HotKeyBlock.swift`（在哪些 App 里停用快捷键：名单的存法和「此刻停哪些」的纯函数，2026-11-10，§10「按 App 停用快捷键」）、`Permissions.swift`（辅助功能、屏幕录制、文件和文件夹授权、麦克风（录屏第 4 批）；自动化被拒时打开系统设置）、`Paster.swift`（自家写剪贴板的唯一出口；`write(string:record:)` 把本 App 生成的新文字同时记进剪贴板历史）、`Subprocess.swift`（进程外跑系统命令行工具：更新的 ditto / codesign、系统命令的 pmset / osascript、kill 的 ps / lsof、浏览历史的 sqlite3，还有剪贴板后台识字的子进程（本 App 带 `--ocr`）；要的输出写临时文件，不受 64 KB 管道缓冲限制；可给环境变量、超时、优先级）、`Style.swift`（Whisker 刻度：圆角、七条弹簧曲线、中性色 / 家族色、输入框 `InputBox`、复制对勾停留、卡片表面 `CardSurface`、增强对比度的选中描边 `contrastSelectionBorder`、发丝线 `Hairline` / `hairlineBorder`、主按钮 `BrandButtonStyle`、种类色块、键帽、面板描边、面板内浮层的阴影 `floatingShadow`、空状态 `EmptyState`（剪贴板、翻译浮窗、翻译历史共用，2026-10-12 视觉对齐））、`HoverTracker.swift`（列表行悬停：`.activeAlways` 追踪区，非激活浮层里代替 `onHover`；剪贴板、翻译历史、启动器行共用）、`ListReveal.swift`（列表选中跟随滚动：`ListReveal.target` 纯函数按前缀和给目标 y，`RevealsSelection` 接管 `.scrollPosition`、按上次滚动的终点判断、停下没到补滚一次；剪贴板、启动器、翻译历史共用，第 10 批）、`CommandTextField.swift`（单行输入框：方向键 / 回车 / Tab / Esc 走 doCommandBy，对话框输入框、`maxLength`）、`BarNotice.swift`（剪贴板面板、启动器底栏左边的就地提示）、`SearchLine.swift`（剪贴板面板、启动器顶上的搜索线：线头符号定宽、左右内边距，两块面板同一个，2026-10-12 视觉对齐）、`Accent.swift`（强调色：跟随系统 + 8 色、配色计算、根视图的 `.appAccent()`）、`Island.swift`（刘海岛：全局轻提示，替换原来的 Toast；2026-10-26 起能悬停展开、带按钮，点刘海 / 快捷键能叫出来，§10「刘海岛交互」；`Island.announce` 是 VoiceOver 主动播报的唯一入口）、`IslandBoard.swift`（刘海岛的「那一张」：一排快捷动作 + 最近 10 条提示，2026-10-26）、`StatusItem.swift`（菜单栏图标与菜单，NSStatusItem，Whisker D 的呼吸 / 弹一下；`MenuExtra`：菜单栏和启动器内置动作共用的非热键项）、`ActionMenu.swift`（剪贴板 ⌘K、剪贴板筛选面板、剪贴板多选的收藏夹列表、启动器 ⌘K、翻译历史 ⌘K 共用的动作菜单：分节、一级子列表、共用过滤 `filter`（子串 + 拼音前缀），体检 C3 C4）、`SymbolImage.swift`（符号名 → 图：`kitty.` 开头的取资源目录 `FeatureIcons/` 里自画的功能图标，其余 SF Symbols；SwiftUI `Image(symbol:)`、AppKit `NSImage.symbol(_:)`，2026-10-30，§10「功能图标」）、`FirstNonNil.swift`（`Sequence.firstNonNil`：代替会转两次的 `lazy.compactMap(…).first`，2026-11-06 闪退）、`Ticker.swift`（每秒在变的一行读数的图层画法，代替 numericText：整行排一次、按字切成一块块图层，每秒只滚变了的数字；状态屏告示上的小字和录制 HUD 的计时共用，2026-10-11 从 `StatusScreen/StatusTicker.swift` 挪过来） |
| `Storage/` | `Database.swift`、`Backup.swift`（数据库的每日备份 `Backup` + 打不开时的恢复 `Recovery`，第二轮体检 S2）、`Keychain.swift`、`Prefs.swift`、`SettingsArchive.swift`（设置与数据的导出与导入：文件格式、读文件时的校验、整类替换 / 按 id 合并、密钥的加解密，片段 / 文字收藏 / 生词本的导出，2026-10-07；2026-10-12 加第七类「便签」`NoteEntry`、格式 2：逐条宽松解码、按编号并进便签库）、`SettingsBackup.swift`（设置与数据的每日自动备份：导出文件每天存一份、导入前存一份，起名、列出、写、轮换，2026-10-08）、`SyncRecords.swift`（全局同步里一条一条的数据的合并规则和文件写法：账本比出本机改动、版本钟、墓碑、后改的赢，纯函数；2026-10-23）、`SyncLedger.swift`（`SyncSource` 协议：仓库交出该同步的那份、落合并结果；账本存法，2026-10-24）、`SettingsSync.swift`（设置、全局快捷键、功能开关接进全局同步：一项一条、留在本机的键、透传，2026-10-24）（~~`LegacyImport.swift`~~ 2026-09-26 随旧版导入删掉） |
| `Clipboard/` | `ClipboardWatcher.swift`、`ClipboardStore.swift`、`ClipItem.swift`、`ClipboardFilter.swift`、`ContentForm.swift`、`Search.swift`、`ImageStore.swift`、`OCR.swift`、`ClipboardPanelModel.swift`（面板状态与操作：筛选标签、选中 / 多选、键盘命令、粘贴 / 复制 / 删除撤销栈、⌘K）、`ClipboardPanelView.swift`、`ClipRowView.swift`、`LensView.swift`（透镜：选中行原地展开的预览）、`PreviewView.swift`、`Dialogs.swift`、`Snippet.swift`（片段占位符展开）、`LinkPreview.swift`（链接富预览：按块读网页 og 标签、isFetchable、内存缓存；头图的缩略图空闲时丢掉、照留着的字节重解）、`QuickLookView.swift`（⌘Y 放大预览）、`ClipDrag.swift`（行拖到别的 App：AppKit 拖放会话 + 行首图标块和标题的预览，体检 D3） |
| `Translate/` | `TranslateCoordinator.swift`、`TranslateService.swift`（服务列表与配置：内置 8 家可删可加回、自建 AI 实例、厂商预设）、`Language.swift`（应用内语言、语种检测、源 / 目标解析）、`SelectionReader.swift`、`SourceTextView.swift`（多行输入框：翻译原文、剪贴板编辑正文 / 新建片段、便签的快速记一条；便签的正文不用它，用 `Notes/NoteTextView.swift`）、`HTTP.swift`（JSON POST、SSE 读取、中文错误信息）、`SSE.swift`、`Providers/`（`FreeProviders.swift`（不用 key 的系统翻译、有道词典，2026-11-05）、`Zhipu.swift`、`AIService.swift`（OpenAI 兼容 / Azure / Anthropic，也给智谱复用流式请求；按地址认厂商的表 `AIVendor`，第 13 批）、`RESTProviders.swift`（百度、有道、Google、DeepL / DeepLX、微软）、`CloudProviders.swift`（火山、腾讯，请求签名）、`Signing.swift`（摘要工具、非流式请求包装））、`TranslatePanelView.swift`、`ProviderCardView.swift`（含服务身份 `ServiceTile`：官方 logo、官网图标或品牌色块，彗星边框、骨架扫光）、`ServiceIcons.swift`（自建 AI 服务的官网图标：推官网、经 `LinkPreview.siteIcon` 取、磁盘缓存，第 13 批）、`ResultText.swift`（结果卡片的正文：普通 Text + 生成中的光标；原 RevealText 的显影第二轮体检第 1c 批拿掉）、`HistoryStore.swift`、`HistoryView.swift`（含历史 ⌘K 的动作和 `HistoryMenu`：导出、清空，浮窗「⋯」菜单 / 历史 ⌘K / 设置 › 翻译共用）、`Speaker.swift`（朗读：收起即停、挑高音质声线；英文单词放有道真人发音、卡片读哪段字、单词卡的读音行，2026-11-05）、`WordLookup.swift`（查词：是不是一个词、系统词典查询与解析（英英、汉语、牛津英汉汉英三种格式）、单词模式示例，D4）、`DictionaryCardView.swift`（系统词典卡）、`TranslateServiceSync.swift`（翻译服务列表接进全局同步，密钥不同步；2026-10-24）、`ScreenshotOverlay.swift`（截图翻译「把译文直接盖回截图上」：按段抹底色、排译文、贴回冻结帧，2026-11-05 PR #5） |
| `Settings/` | `HotKeyBlockSection.swift`（设置 › 快捷键 最下面「在这些 App 里停用」，2026-11-10）、`FinderMenuTab.swift`（设置 › 访达右键：开关、系统里扩展开没开、「用 App 打开」的列表，2026-11-08）、`RemindersTab.swift`、`ReminderDetail.swift`（设置 › 提醒的列表和详情，2026-11-04）、`GeneralTab.swift`、`FeaturesPage.swift`（通用 › 功能推进去的那一页，2026-11-07）、`WebSearchPage.swift`（启动器 › 网页搜索与快捷链接推进去的那张列表，2026-11-07）、`HotkeysTab.swift`、`ClipboardTab.swift`、`TranslateTab.swift`、`AboutTab.swift`（关于页：更新日志读 `Resources/changelog.json`；2026-10-18 起「未来计划」读 `Resources/roadmap.json`——两个都是随包的 JSON、一条一行，`ChangelogTests` 锁格式）、`LauncherTab.swift`、`AppAliasesPage.swift`（启动器 › 应用别名：按应用名 / 别名筛选、编辑多个别名，2026-11-09）、`ScreenshotTab.swift`（另有截图页、录制页共用的快速保存一行 `SaveDirectoryRow`）、`RecordTab.swift`（录制页：录屏、录音，2026-10-03 从截图页拆出来）、`SettingsTransfer.swift`（通用页最后一组「导出与导入」和两张表单，2026-10-07）、`SyncSection.swift`（通用页「同步」一节：选文件夹、状态、停止 / 立即同步、其他 Mac；2026-10-23 从便签页挪来）、`SettingsWindow.swift`（D 阶段从 Shell 搬来：NavigationSplitView 侧栏 + 搜索 + 页头）、`OnboardingView.swift`（首次安装的欢迎引导：欢迎 + 按一下试试）、`ShortcutsSheet.swift`（快捷键速查表 + `ShortcutsButton`）、`OrderedList.swift`（可拖动排序列表共用的「+ −」按钮条、行高、详情页页头）、`TranslateServiceDetail.swift`（翻译服务详情页）、`SearchEngineDetail.swift`（网页搜索 / 快捷链接详情页）；`StatusScreenTab.swift`（设置 › 状态屏：状态列表的加、删、排序、恢复自带的，退出提示的开关）、`StatusPresetDetail.swift`（改一个状态的详情页：六项 + 图标格子 + 缩小的预览）；`LaunchpadTab.swift`（设置 › 启动台，2026-10-18：总开关、触控板捏合（开关 / 灵敏度 / 系统手势提示）、触发角（带系统冲突提示）、行列数（显示当前值）、从系统启动台导入 / 恢复默认排列 / 撤销、排列数据说明）、`NotesTab.swift`（设置 › 便签，2026-10-12 第 2 批的骨架：正文字号、打开全部便签、数据怎么存的说明）、`ScriptsSection.swift`（设置 › 启动器「脚本命令」「命令」两节：开关、怎么写脚本、文件夹、新建、拖进来导入先看全文、读不成的原因、「命令和别名」那一行，2026-11-07）、`LauncherCommandsSection.swift`（推进去的「命令和别名」页 `LauncherCommandsPage`：名称 / 别名 / 启用的表）、`ScriptGuide.swift`（推进去的「怎么写脚本」说明页 `ScriptGuidePage`，含命令的查找路径）、`NewScriptSheet.swift`（「新建脚本」的小表单：名字、关键词、结果给谁、用什么写，2026-11-08 第三轮 D2）。`SettingsWindow.swift` 里另有两个普通窗口共用的 `NSApplication.leaveDockIfNoWindows`（关掉一个时别的普通窗口都不开着了才切回 accessory）、`DockPreviewTab.swift`（程序坞预览：启用、两项授权，私有接口缺了时橙字说后果；2026-10-22） |
| `Launcher/` | `LauncherItem.swift`（结果项与内置动作）、`AppCatalog.swift`（App 目录 + 中文名 + 拼音 + bundle id）、`AppAliases.swift`（应用别名：稳定身份、存储、搜索词扩充，2026-11-09）、`LauncherMatch.swift`（匹配与排序纯函数）、`LauncherUsage.swift`（使用记录表 + 收藏表 launcher_favorites，体检 D13）、`LauncherModel.swift`、`LauncherPanelView.swift`、`FileSearch.swift`（文件搜索：open / find / 空格开头，NSMetadataQuery 查询、排除、排序、最近的文件、授权提示，M13）、`SystemCommands.swift`（系统命令目录、quit / hide / forcequit / eject / kill / port 解析与只读列举，D2）、`SystemControl.swift`（系统命令的执行：锁屏、pmset、osascript、退出 App、推出、给进程发信号）、`Processes.swift`（kill 列的后台进程：ps / lsof 输出解析与排序，体检 D12；port 的端口行也在这里，2026-10-08）、`IPAddresses.swift`（「ip」：本机网卡地址、两家外网地址查询、拼行，2026-10-28）、`ExchangeRates.swift`（计算器的汇率换算：「100 usd」解析、按表换算、取汇率表和存进偏好，2026-11-04）、`SiteIcons.swift`（网址行的网站图标：读本机 Chromium 系浏览器的 Favicons 库 + 链接预览，按主机缓存，体检 D6）、`BrowserHistory.swift`（各家浏览历史 + Firefox 书签：克隆后 sqlite3 导出、解析、行，体检 D8、第 12 批）、`Bookmarks.swift`（浏览器书签：Chromium 系 JSON、Safari plist，Firefox 取 BrowserHistory 读好的）、`Browsers.swift`（第 12 批：浏览器表、装没装、数据目录与多配置、偏好里开着的、克隆别人的库、读失败分「没授权 / 没有文件」）、`DirectItems.swift`（网址 / 路径直达，纯函数）、`WebSearch.swift`（网页搜索与快捷链接列表）；`AppCatalog.swift` 顺带扫系统设置面板（体检 D9），`Calculator.swift` 含单位换算表和进制（体检 D11）、`WebSearchSync.swift`（网页搜索与快捷链接接进全局同步；2026-10-24）；脚本命令（2026-11-07，§10「脚本命令」）：`ScriptCommand.swift`（一个脚本 = 一条命令：开头注释的两种写法、参数切分、列表输出解析、输出收拾、给脚本的环境，纯函数）、`ScriptLibrary.swift`（从哪读：默认文件夹 / 另加的 / 包里的自带脚本，主线程外读、看下载标记；设置页用的新建 / 导入 / 复制自带的）、`ScriptIcons.swift`（图片 / https 网址图标：主线程外读、下载一次存进缓存，出错原因；启动器和设置的表共用的 `ScriptIconView`，2026-11-07 第二轮 B1 B2）、`ScriptAIGuide.swift`（给 AI 的脚本写法说明，第二轮 A1）、`ScriptRunner.swift`（怎么跑：按 #! 调解释器、登录 shell 的 PATH、超时和停止、去下载标记）、`ScriptTerminal.swift`（全文输出那一页认终端颜色：SGR → AttributedString，纯函数；2026-11-08 第三轮 A2）、`LauncherCommands.swift`（「命令」表：内置关键词命令 / 系统命令 / 脚本的别名和开关、别名换回原关键词） |
| `Launchpad/` | （启动台，第八族，0.6.0，2026-10-18 第 1 批起；拍板和做法在 §10「启动台」，规矩在 `mac-launchpad`）`LaunchpadLayout.swift`（模型和全部纯函数：页 / 格子 / 文件夹、合并本机 App、默认排法、挪格子、建 / 加 / 拖出 / 解散文件夹、按行列数重新分页、存偏好；不变式由 `LaunchpadFuzzTests` 锁住）、`LaunchpadCatalog.swift`（App 目录：复用 `AppCatalog.scan()`，只留 .app、不要访达和系统设置面板；bundle id、分类、App Store 收据；`LaunchpadIcons` 后台画、常驻的图标位图）、`LaunchpadWallpaper.swift`（背景：那块屏的壁纸在后台裁好、模糊，缓存一张）、`LaunchpadModel.swift`（一块屏的状态：当前页、搜索、选中、拖动 / 落点 / 停留合成 / 跨页让位、文件夹页、Esc 取消、抖动、滚轮）、`LaunchpadMetrics.swift`（按屏幕大小和行列数算的网格尺寸，界面和拖动判定共用）、`LaunchpadPager.swift`（翻页的纯状态机）、`LaunchpadDrag.swift`（拖动的时长、正在拖的那一格、滑进落点的那一份，落点 / 第几格的纯函数）、`LaunchpadPanel.swift`（全屏面板 `LaunchpadPanel`，第七个自建窗口例外；深色外观、滚轮 / 两指滑、⌘← / ⌘→ / ⌘W、方向键入口、失去 key 的判断、窗口簿记）、`LaunchpadView.swift`（模糊的壁纸、照 macOS 15 比例的 7 × 5 网格、居中占位的搜索框、页点、各层的层次和文件夹开关的时机、按下 / 选中、VoiceOver）、`LaunchpadFolderView.swift`（打开的文件夹：后面糊掉的那层、从方块长出来 / 缩回去的纸、名字 / 图标 / 页点、改名）、`LaunchpadIconView.swift`（图层抖动的 App 图标、文件夹面板里的图标、文件夹方块）、`Launchpad.swift`（总控：开关、后台 App 目录、布局读写 / 读不出来时保护、打开 App、回收、导入 / 恢复 / 撤销、捏合和触发角的起停、收起后放掉）、`LaunchpadRecycle.swift`（抖动模式删 App 的确认，`NSWorkspace.recycle` 可注入）、`LaunchpadImport.swift`（系统旧库只读拷贝 + `mode=ro` 读 WAL）、`PinchRecognizer.swift`（纯状态机：开始 / 每帧进度 / 松手（进度 + 速度）/ 取消，松手走完还是退回）、`TouchpadWatcher.swift`（96 字节触点、Mutex 桥（每帧的进度也在里面）、唤醒重注册）、`LaunchpadMissionControl.swift`（打开前认调度中心、开着就让它退：只认 macOS 27 的 WindowManager 整屏 19 层窗口）、`LaunchpadZoom.swift`（开 / 收那一个数：窗口透明度 + 上面那层的缩放，跟手时屏幕刷新回调每帧取进度，松手和按键入口走同一条临界阻尼弹簧）、`LaunchpadCorner.swift`（每屏一个状态栏层级的透明 `NSPanel`、重新武装、系统触发角只读） |
| `DockPreview/` | （程序坞预览，第九族，0.7.0，2026-10-22 第 1 批起；拍板和做法在 §10「程序坞预览」）`WindowServer.swift`（窗口服务器的私有接口：窗口编号、截窗口、在哪个桌面、按编号切过去；运行时取，取不到退回公开做法）、`DockWatcher.swift`、`SwitcherWatcher.swift`（⌘Tab 时读系统切换器的选中，2026-11-06）（听程序坞：图标列表的选中变化 → 停在哪个 App 图标上；辅助功能坐标换算；读属性的小函数）、`DockWindows.swift`（一个 App 的窗口：辅助功能表 + 别的桌面上的，并表的纯函数 `merge` / `resolveIDs`；切过去、关掉）、`WindowShots.swift`（缩略图：当场截、主线程外缩小、最多留 20 张）、`DockPreview.swift`（控制器：什么时候弹、换、收，点了切过去 / 关掉；面板是普通 NSPanel + `PreviewHost`）、`DockPreviewView.swift`（面板内容和 `DockPreviewModel`）、`DockPreviewLayout.swift`（纯函数：缩略图多大、一排放不下就缩再换行、面板摆哪、选哪块屏、鼠标还算不算在附近 `keepsOpen`、离开后的倒计时 `Linger`） |
| `FinderMenu/` | （访达右键，第十一族，2026-11-08；拍板和做法在 §10「访达右键」）`FinderLink.swift`（扩展交过来的网址：解析和凭证、拷贝的字、交给 App 打开哪些都是纯函数，`perform` 做那一步）、`NewFile.swift`（新建文件：自带五种模板在 `Resources/new-file/`、数据目录「新建文件模板」文件夹、重名让开、自定义后缀的框）、`FinderMenuItem.swift`（每一项的开关和默认值）、`FileMoves.swift`（移动到 / 复制到、剪切 / 粘贴、替身、彻底删除；动文件的一条队 `enqueue`、不覆盖的改名 `land`、记账的临时名 `temporary`）、`Archives.swift`（压缩、解压到这里，系统 tar / ditto）、`ZipNames.swift`（读 zip 的中央目录：名字的编码、加没加密）、`NameRepair.swift`（修复乱码文件名，扩展里有一份逐字一样的）、`FileFlags.swift`（显示 / 隐藏 隐藏文件、隐藏所选项、扩展名）、`FileHash.swift`（拷贝哈希） |
| `macos/KittyToolsFinder/` | 访达扩展 target（不在 `KittyTools/` 里）：`FinderMenu.swift`（只画菜单，点了用 App 的网址交过去）；设置在 `Config/Finder.xcconfig`、`Finder-Info.plist`、`Finder.entitlements` |
| `Screenshot/` | `ScreenCapture.swift`（逐屏冻结帧 + 同一刻的窗口 Z 序快照）、`RegionSelector.swift`（框选会话、每屏一个遮罩、选区几何纯函数）、`SelectionView.swift`（遮罩画面与交互：图层绘制、窗口悬停、手柄、放大镜、工具栏）、`ElementFinder.swift`（悬停认窗口里的元素：问指针下那扇窗口的主人这一点上是什么、往上取框；裁剪 / 过滤 / 去重、换层是纯函数，2026-11-08）、`ScreenshotOutput.swift`（PNG、快速保存、另存为）、`PinPanel.swift`（钉图；第二轮体检 F1 起还有「钉住剪贴板里的图」的取图、解码、找位置）、`Annotation.swift`（标注模型，显示与导出共用 draw，M10）、`EditorToolbar.swift`（HUD 主工具栏 + 样式托盘，M10，Whisker 重做）、`TranslationCard.swift`（截图翻译盖回截图上时放不下的段：选区外的译文卡片，2026-11-08）、`FlyCard.swift`（截图飞入右下角 + 快门声，Whisker S1；录屏第 3 批起录屏的最后一帧也从这里飞，落地多播放符号和时长 `VideoMarks`）、`ScrollCapture.swift`（长截图会话：边框、侧边面板、抓帧循环、自动滚动）、`ScrollStitcher.swift`（长截图拼接，纯逻辑）、`ShotKeys.swift`（截图时能改的 21 个键，2026-11-06）、`AnnotateOverlay.swift`（标注遮罩：整屏压暗、图居中、滚动与缩放、工具栏和样式托盘、出图；长截图按 A 和截图历史里双击都用它，2026-10-26）、`ScrollCanvas.swift`（长图画布：只画看得见的那一段 + 标注交互，标注层复用 `AnnotationCanvas`）、`ShotHistory.swift`（截图历史：原图 + 标注 + 缩略图存 <数据目录>/shots/，记录在主库的 shots 表，按天数和总量清理，2026-10-26）、`ShotHistoryWindow.swift`（历史窗口和模型：筛选、按天分组、每条的操作、缩略图缓存）、`ShotHistoryView.swift`（历史窗口的界面：网格 + 预览 + 操作）、`Clothesline.swift`（晾衣绳：面板、什么时候滑下来 / 收起、挂上 / 取下、卡片上的动作，第十族 2026-10-26）、`ClotheslineLayout.swift`（晾衣绳的几何与时机：排法、垂度、菜单栏那一条、收不收，纯函数）、`ClotheslineRope.swift`（绳子的物理：verlet 质点 + 重力 + 阻尼 + 距离约束，纯值类型）、`ClotheslineView.swift`（晾衣绳的内容：绳子、卡片、夹子、悬停和鼠标 `CardMouse`）、`ShotShelf.swift`（CleanShot 式常驻缩略图，Whisker D；录屏第 3 批加视频卡 `ShelfCard.Kind.video`，右键菜单 / 旁白动作同一份 `ShelfCard.menu`）、`SizeField.swift`（遮罩里的尺寸胶囊：就地输入宽高、比例菜单）、`ScreenRecorder.swift`（录屏会话：SCRecordingOutput 先写到同卷、系统不清理的地方再挪进快速保存目录、白名单面板的例外过滤器、选区边框、菜单栏停止项、中断与闪退恢复，录屏第 1 批；第 2 批加倒数、放弃、帧率 / 倒数 / 光标设置；第 3 批挪好后取最后一帧 `poster`；第 4 批按录制条开关配声音 / 麦克风 / 点按（`Options`、`configure`）、开录前问麦克风授权、麦克风断开；录制条（四个开关：系统声音、麦克风、显示点按、显示按键） `RecordBar` 在 `EditorToolbar.swift`、框选是 `SelectionView` 的 `.record` 模式；手测反馈第 1 批起点按圈由 `InputOverlay` 画，`configure` 只管声音，过滤器例外多并一个它的窗口号 `exceptedOwnWindows`）、`InputOverlay.swift`（录屏里显示用户的输入，手测反馈第 1 批 2026-10-01：显示点按开着时盖在被录区域上的透明 NSPanel（普通实例、不接鼠标、层级 popUpMenu + 2），global / local 鼠标监听，按下圆盘 / 右键空心环 / 拖动跟随 / 松开涟漪都是 CALayer 动画；坐标换算、形状、哪些自家窗口上不画是纯函数；手测反馈第 2 批加按键提示：录制条「显示按键」开着时同一块窗口底部居中的 HUD 胶囊，global / local 的 keyDown 监听（global 要辅助功能授权），键名复用 `HotKey.display`，内容和停手清空是纯状态 `Keys`，位置是纯函数；显示点按 / 显示按键任一开着就建窗口）、`RecordingHUD.swift`（录制 HUD：倒数 / 录制中两态、红点呼吸、计时、放弃两下、停止，普通 NSPanel 状态栏层级、能拖，录屏第 2 批；第 4 批录制态加只读声音状态（系统声音 / 麦克风，开录时的麦克风断开变橙）；录音第 5 批加录音形态 `medium = .audio`：电平 `LevelMeter`、暂停 / 继续、「没听到声音」、底部居中从底边长出来；手测反馈第 3 批加录音的待录态 `State.ready`：[系统声音][麦克风] ｜ [✕][●]，来源开关读写 `Prefs.audioRecordSource`，开始后原地换成录制态）、`VideoExport.swift`（录屏转成 GIF，录屏录音第 7 批：15 fps、宽 ≤ 960、最长前 60 s，`AVAssetImageGenerator` 逐帧取、`CGImageDestination` 逐帧编（关全局调色板）、`@concurrent`；帧时刻 / 输出尺寸 / 存盘名是纯函数；常驻缩略图的 GIF 卡是 `ShelfCard.Kind.gif`，入口是视频卡的「转成 GIF」`ShelfCard.convertToGIF`）、`AudioRecorder.swift`（录音会话，录音第 5 批：AVAudioRecorder 录 m4a、授权、暂停续写、20 Hz 电平与 `Levels` 历史、「没听到声音」、中断（系统睡眠 / 输入设备断开 / 磁盘）、停止后画波形 poster；收尾挪文件、闪退恢复、结果岛、菜单栏停止项和录屏共用 `ScreenRecorder` 的 `settle` / `recover` / `summary` / `makeStopItem`（`ScreenRecorder.Medium`），常驻缩略图的录音卡是 `ShelfCard.Kind.audio`；第 6 批加来源 `Source`（麦克风 / 系统声音 / 两者），后两种用 `ScreenRecorder` 的只录声音模式 `audioOnly` 当引擎，电平由它的样本回调算好投过来；手测反馈第 3 批分成两个阶段：`open()` 待录只出控制条，`start()` 才读来源、问 `allowsStart`、开录） |
| `StatusScreen/` | `StatusPreset.swift`（一个状态：标题、说明、图标、样式、电源、自动结束；自带的三个；偏好里的 JSON 和 `sanitized`）、`InputBlock.swift`（事件拦截，全仓库唯一碰 `CGEvent.tapCreate` 的地方；会话是不是锁着 `isSessionAway`）、`ExitHold.swift`（退出判断：按住 esc / 按住退出提示 2 秒，纯状态）、`Passcode.swift`（退出密码：4–8 位数字、钥匙串里的条目、密码框的输入状态，纯状态）、`StatusScreen.swift`（一次会话：进入、触碰、锁屏时让开、退出、退出后拦截的留守）、`StatusScreenView.swift`（每屏一张全屏面板 `StatusScreenPanel` 和画面）、`StatusEmoji.swift`（动画表情：16 个可选 + 眼睛的清单、静止画面、解帧、按帧换图层内容的播放；素材 `Resources/status-emoji-<id>.heics` 由 `macos/status-emoji.swift` 从 Microsoft Fluent Emoji Animated 转来）、`StatusPicker.swift`（按全局快捷键时先出的选状态面板：一排预览卡片、键盘选择、把选中卡片的位置交给会话让画面从它长到整屏）；规矩见 mac-overlay-panel §11、`StatusPresetSync.swift`（状态屏的状态接进全局同步：一个一条 + 顺序一条；2026-10-24） |
| `StatusScreen/`（2026-11-05 补） | `EmojiPack.swift`（动画表情包：挑的系统表情有 Fluent 动画版时按对照表 `Resources/emoji-pack.json` 从本仓库 release `emoji-pack-<版本>` 下载、缓存在数据目录 `emoji-pack/`（上限 50 MB，删最久没用的），开关 `Prefs.emojiPackDownloads`；表情包由 `macos/emoji-pack.swift` 生成） |
| `Reminders/` | `ReminderSound.swift`（提示音：系统的、个人「声音」文件夹里的、自己选的文件（拷进数据目录 `reminder-sounds/`），播放最多 30 秒、处理了就停；编号的校验，2026-11-04 用户反馈）、`ReminderPhrase.swift`（启动器一句话建提醒的解析，纯函数）、`ReminderSync.swift`（提醒列表接进全局同步）、`ReminderScreen.swift`（全屏提醒，面板 `ReminderScreenPanel`）、`ReminderGlow.swift`（边框：每屏四条贴边窄窗口）、`Reminder.swift`（一条提醒：标题、说明、表情、开关、时间规则 `Schedule`、提醒方式、全屏多久、声音、催促；三条示例；偏好里的 JSON、逐字段兜底的解码和 `sanitized`；设置页的列表纯函数和摘要）、`ReminderSchedule.swift`（纯函数：一次 / 每周 / 每月的下一次、间隔按锚点和时段、`ReminderCheck.check` 此刻哪几条响 / 算错过 / 下次几点看、`reconciled`；这台电脑的状态 `ReminderState`）、`ReminderCenter.swift`（执行层：一个睡到下一刻的计时任务、锁屏 / 解锁 / 醒来 / 改时钟的监听、间隔提醒的空闲检查、挂在刘海岛上的那一条、知道了 / 稍后）；2026-11-04，§10「提醒」 |
| `Notes/` | （便签，§10「便签」；2026-10-12 立项、2026-10-18 八批全部做完）**数据**：`Note.swift`（模型、标题 / 摘要、清洗和上限）、`NoteStore.swift`（单独的库、排序搜索、最近删除 30 天、落盘重试）、`NotesBackup.swift`（每日备份留 7 份、打不开时的恢复，和剪贴板的平行）、`NoteSample.swift`（空库首次放一条示例）。**入口和窗口**：`NoteCapture.swift` + `NoteCaptureView.swift`（⌥N 快速记一条）、`NotesWindow.swift` + `NotesWindowView.swift`（全部便签窗口的列表 / 搜索 / 工具栏 / 右键）、`NoteWall.swift` + `NotesWallView.swift`（便签墙的纯函数和视图）。**屏幕边缘**：`NoteEdge.swift`（开关、叫停、面板生命周期）、`NoteDeck.swift` / `NoteDeckModel.swift` / `NoteDeckState.swift` / `NoteDeckOptions.swift` / `NoteDeckLayout.swift` / `NoteDeckPill.swift` / `NoteDeckPanel.swift` / `NoteDeckView.swift`（药丸、标签列、状态机、几何、设置、面板）。**打开的便签**：`NoteSheet.swift` + `NoteSheetModel.swift` + `NotePanel.swift`（那叠和浮动共用）、`NoteFloat.swift` / `NoteFloatModel.swift` / `NoteFloatState.swift` / `NoteFloatLayout.swift` / `NoteFloatPanel.swift`（拖出来、拉大小、固定后回原位；一张一个）、`NoteFloats.swift`（同时浮几张：上限、最久没碰、几张一起记位置，2026-10-22）、`NoteFields.swift`（标题 / 正文输入框）、`NoteColorPicker.swift`（颜色菜单的「其他颜色…」：系统取色面板、最近用过，2026-10-22）。**正文**：`NoteTextView.swift` + `NoteTextView+Images.swift`（显式搭的 TextKit 1；样式只改属性；组字期间不重排不落盘）、`NoteStyles.swift`（行距、五种任务方框、代码块、文字颜色）、`NoteMarkdown.swift`（不用正则的扫描器、标记藏 / 露）、`NoteTasks.swift`（任务和列表的纯函数）、`NoteTaskBox.swift`（任务方框自己画的圆角方框：几何、五种画法、记号取色；2026-10-18）、`NotePaper.swift`（8 种纸色、6 种文字颜色）、`NoteImages.swift` + `NoteImageStore.swift` + `NoteImageAttachment.swift`（令牌、图片目录、附件字符）、`NoteImageCrop.swift`（图片的裁切层：几何纯函数 + 盖在正文滚动区上的视图，2026-10-22）、`NoteMarkdownFiles.swift`（整个 / 单条的导出导入）、`NoteSync.swift`（同步的合并规则：版本钟、状态后改的赢、墓碑，纯函数；2026-10-22）、`NoteSyncFolder.swift`（同步文件夹的写法、一轮该合什么、刹车、该写出去什么，纯函数；2026-10-22）、`NoteSyncDisk.swift`（读写同步文件夹：协调读写、没下载完的文件、缓存，主线程外；2026-10-23）、`NoteSyncer.swift`（同步的执行层：什么时候合、一轮怎么走、刹车、正在编辑的先不换、认出库被退回去了；2026-10-23）。规矩：编辑器、Markdown、任务、颜色、图片、导出导入在 mac-overlay-panel §3 §5，那叠和浮动在 §12，长相在 `mac-whisker/notes.md`，备份在 mac-clipboard §1，划词在 mac-translate §5。 |

各 provider 函数签名统一，由 coordinator 里的一个 `switch` 分发。不建 registry 或 factory。

**文档**（`macos/` 下，2026-10-03 第二轮体检第 8 批）：`PLAN.md`（本文，仍有效的方案）、`HANDTEST.md`（发版前走的「真机回归清单」约 40 条 + 正在验收的那一轮的手测，新的手测往里加；2026-11-01 第四轮体检 W1 起，原来的发版冒烟清单和到 2026-10-30 的各批手测原样归档在 `docs/archive/HANDTEST-2026-10.md`）、`docs/archive/`（PLAN 挪出去的迁移期历史和已完成批次的实现记录，原样、只查不改：`PLAN-migration.md`、`PLAN-10.md`、`PLAN-12.md`、`HANDTEST-2026-10.md`）。

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

> 2026-10-03 瘦身：每块只留约束、已拍板决定的结论和不做清单；各批的实现要点、实测数字、评审记录原样挪到 `docs/archive/PLAN-10.md`，按下面同名的粗体小节找。现行的实现约束在各 `mac-*` 规则里，界面规格在 `mac-whisker/<界面>.md`。以后的新批次照这个写法：这里只补一两行结论，实现要点和实测数字写进提交说明的正文。

> 2026-10-28 第二次瘦身（第三轮体检第 7 批）：各块的批次记录、实测、评审、「做的时候定的」和已经做完的进度原样挪到 `docs/archive/PLAN-batches-2026-10.md`，按同名小节找（原位置留了一行去处）；这里留拍板、约束、不做、ponytail、留给执行层的要求和还没做的。

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

**不迁**：ts / b64 / url / case / uuid / ip 小工具（2026-10-28 做了 ip；2026-11-07 时间戳、b64、url、uuid、进制、JSON、正则做成自带的脚本命令，§10「脚本命令」）、~~网站图标~~（2026-09-28 体检 D6 改为做：不联网，只读本机 Chrome 的库 + 剪贴板链接预览取到的，旧版联网抓取仍不迁）、~~Safari / Firefox 书签~~（2026-09-29 第 12 批改为做：用户「浏览器书签与历史缺少 Safari」，拍板加 Safari + 只列装了的，顺带 Firefox 和其它 Chromium 系，见下方「浏览器书签与历史（第 12 批）」）、~~汇率换算~~（体检 D11 因为要联网没做；2026-11-04 用户要，做进计算器，`Launcher/ExchangeRates.swift`）；延时、美化 / 水印、比例条、Enter 全屏、焦点窗口截图、窗口置顶、屏幕清洁、WebP；截图历史与钉图历史（复制的截图进剪贴板历史，作为唯一的历史；要再钉出来，剪贴板里的图片 ⌘K / 右键 / ⌘Y「钉到屏幕」，2026-09-28 体检 D1）。
- 热键：启动器 ⌥Space、截图 ⌥A（用户实际用的键）；编辑器工具键不带修饰的 1–4、钉图 T（沿用用户改键），不做编辑器内改键。⌥Space 只在 15.0–15.1 上注册失败，录制器已提示。

**启动器网址线（M11，2026-09-25）**
- 网页搜索和快捷链接是**同一张列表**（`SearchEngine`）：网址里有 `{query}` 的是搜索（「关键词 空格 内容」直达，勾「兜底」的按列表顺序兜底），没有的是快捷链接；cb、fy、open、find 和 quit / hide / forcequit / eject / kill 是保留关键词（`WebSearch.reservedKeywords`）。预置 13 个，新装只有第 1 个（Google）兜底（体检 A24）；兜底默认只在没有本地结果时出现（`launcherFallbackAlways` 可改成总附在最后）。
- 键盘：↩ 计算结果粘贴回原 App（没有辅助功能授权时只复制并提示），cb ↩ 交给剪贴板面板搜；⌘↩ 在访达中显示 / 只复制；⌥↩ 访达搜索、⌃↩ 用第一个兜底搜索，按住修饰键时选中行的副标题换成替代动作；Tab 补全。↩ / ⌥↩ / ⌃↩ 先确认是回车键（别的键绑定也会发这几个选择器）。
- 「常用」（体检 A22 由「最近使用」改名）里 ⌘⌫ 忘掉一项、⌘Z 放回；收藏 ⌘D（体检 D13，`launcher_favorites`，最多 8 个，空查询先列收藏、再用常用补足到 8 行）；呼出时切英文输入法（`launcherRomanInput`）默认关。
- 空搜索框列不列「常用」做成开关（issue #2，2026-11-05，lqy007700 提「隐藏常用，简洁一些」；用户定「有的人希望列出常用」，做成开关）：`launcherShowsFrequent` 默认开、注册默认值（跟着导出 / 同步走），关掉只列收藏、使用记录照记；空搜索框里一行都没有时面板只剩搜索框（`LauncherPanelView.isBare`，有错误 / 就地提示 / 动作菜单 / 新版本时照旧带底栏）。
- 从书签、快捷链接打开过的网址跟着源头走（issue #10，2026-11-06，0.7.3）：使用记录多记一列 `listed`（最后一次是从这两份列表打开的），这种不当「用过的网址」自己找回来、「常用」里只从现在的列表里取——浏览器里删了书签就搜不到，加回来照旧；手输打开的网址、浏览历史行打开的照旧靠使用记录搜到。修之前记下的（`listed` = 0）照旧会冒出来，⌘⌫ 或「清空使用记录」清掉。

**文件搜索（M13，2026-09-26）**
- `open 词` 打开、`find 词` 在访达中选中（⌘↩ 互换），空格开头 = open；普通搜索不混排文件（打开过的文件靠使用记录搜到）；不做 in（内容）/ tags、目录导航、自定义关键词、可编辑排除目录。
- 查询（`Launcher/FileSearch.swift`）：每个词一个 `kMDItemFSName == "词*"cdw`（拼音也能命中），范围只用主目录，路径在客户端滤（~/Library、node_modules、build 这类）；子串写法要几秒，所以 1 个拉丁字母不查。
- **授权（实测，用户选「按需申请」）**：Spotlight 按调用方的「文件和文件夹」授权过滤结果、也不弹框，所以文件结果最后一行是授权提示（↩ 逐个 `opendir` 让系统弹框）；问过之前一律不碰这些目录（`Prefs.folderAccessRequested`）。

**系统命令（D2，2026-09-27）**
- 关键词照抄 Alfred、默认全开，不做改关键词 / 逐个开关 / 排除名单；规格在 `mac-whisker/launcher.md`「系统命令」。带对象的 quit / hide / forcequit / eject 是「关键词 空格」模式（同文件搜索：列一次对象、打字只过滤、不记使用）。
- 执行在 `SystemControl`（面板先收起；单测、截图自检从不真执行）。要 apple-events entitlement + `NSAppleEventsUsageDescription`（强化运行时下没有它，发给别的 App 的 Apple Event 会被静默拒绝），被拒时刘海岛说明并打开 系统设置 › 自动化；其余命令不要新授权。
- 确认：清倒废纸篓、全部退出、强制退出第一下只上膛，同一行同一个键再按一次才执行。

**启动器新功能（体检第 6 批，2026-09-28，D6 D8 D9 D11 D12）**
- 读浏览器的库一律先克隆到临时目录再读、读完删（Chrome 开着时库被它锁着）；小查询在主线程，整表这类大读交给 `/usr/bin/sqlite3` 进程外（mac-native §3）。
- 网站图标（D6）只用本机浏览器里已有的图标，不联网；浏览历史（D8）默认关，排在本地结果后面、最多 5 行，不算本地结果；系统设置面板（D9）按 .appex 的 Info.plist 认，**还没在真机上逐个核对 45 个能跳到**（`HANDTEST.md`「体检第 6 批」第 3 条）；计算器加单位换算 / 进制（D11）；汇率 D11 时因为要联网没做，2026-11-04 补上（`ExchangeRates`：汇率表联网取、存进偏好，过 6 小时再取）；kill（D12）↩ SIGTERM、⌘↩ SIGKILL（上膛），挡掉 loginwindow 和本 App。

**浏览器书签与历史（第 12 批，2026-09-29，用户「浏览器书签与历史缺少 Safari……还没安装」，拍板加 Safari + 只列装了的）**
- 浏览器表一处定义（`Launcher/Browsers.swift`），设置里只列装了的；偏好两个键 `launcherBrowserBookmarks` / `launcherBrowserHistory`，默认书签只开 Chrome、历史都关。
- Safari 受完全磁盘访问权限保护，又没有请求授权的 API：读失败按 `Browsers.failure` 分「需要授权 / 没有文件」，不弹框、不缓存，设置里给「去授权」。Safari、Firefox 的库是 WAL，克隆要连 -wal。Arc 侧栏里的书签、Safari / Firefox 的图标库不读（ponytail）。

**翻译服务 logo（第 13 批，2026-09-30，用户 2026-09-29「期望内置一些常用的 logo icon……我的 DeepSeek，OpenCode」，拍板「内置常见厂商 + 自动取官网图标」）**
- 不用 logo.dev 或任何第三方图标聚合站（要注册拿 token，运行时取图还会把用户用了哪些服务透露出去）；内置图只取各家官网 / 官方站点自己声明的图标（来源表在归档）。厂商按可注册域名认（`AIVendor`，关思考分档也读它），认不出的取官网图标存在本地，都没有就是品牌色块首字母。

**录屏与录音（2026-09-30 立项，用户「需要开始实现录屏和录音功能……风格要保持和我们系统风格一致」）**
- 拍板：方案页 https://claude.ai/artifact/5zCumGF6N4SwNMBBgwyn3k 的 27 项（R1–R12 录屏、A1–A6 录音、C1–C9 共用）+ 13 条默认细节，用户「全部按推荐」；原文和调研出处在归档。
- 定下的要点：录制管线用系统的 `SCRecordingOutput`（不能暂停、不能调码率，录制中改配置会停录；ponytail，升级路径是自己用 AVAssetWriter 写）；录屏复用截图框选；**本 App 的窗口**：过滤器排除整个本 App，再把剪贴板面板、启动器、翻译浮窗、设置窗、钉图这几类窗口列进例外，刘海岛、飞行卡片、常驻缩略图、遮罩、录制边框 / HUD / 停止项永远不进；系统声音默认开、麦克风默认关、混成一条音轨；mp4 + H.264（第二轮体检起可选 HEVC），超过编码上限的等比缩；录音先麦克风（`AVAudioRecorder`，m4a，能暂停），系统声音复用录屏管线、导出 m4a；新增授权只有麦克风；中断统一收尾、保住已录的部分（C6）；录制不占截图的忙碌标记，录屏和录音互斥。
- 第 0 批实测结论、分批、手测反馈三批的摘要已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「录屏与录音」）；现行约束在 mac-overlay-panel §8–§10，界面在 `mac-whisker/capture.md`，手测 `HANDTEST.md`「录屏 / 录音手测」1–67。

**剪贴板手测反馈（2026-10-01，0.3.0 发布前）**
- 行标题已原样显示全的短文本，透镜不再画第二遍（`ClipRowView.showsWholeText`，纯函数、只看条目自己的数据：透镜高度在两处各算一遍，读当前时间、修饰键、系统设置就会对不上）；⌘Y 大卡的图片居中，屏幕放不下时窗口按图片比例缩（`QuickLookView.idealSize`）。不改版本号，更新日志 0.3.0 加了两条；代码完成待手测（`HANDTEST.md`「剪贴板手测反馈」1–8）。业界做法的调研、布局实测和已知上限在归档。

**截图（体检第 7 批，2026-09-28，A28 B40–B43 B45–B47 C9 D17 D18）**
- 「另存为」不改 ⌘S 快速保存的目录（A28，§11 #96）；长截图时和选区相交的钉图变淡让开、常驻缩略图收走（B40）；截图家族叫法统一「拷贝（↩）/ 存储到「桌面」（⌘S，访达显示名）/ 另存为…（⇧⌘S）」（B41）；长截图状态行分正常 / 警告 / 对不上（B42）；选区太矮不进长截图（B43）；钉图的按键同截图出图、能识字和翻译（C9 D17）；多屏冻结帧同时截（B47）；常驻缩略图可关（D18）。
- 钉住剪贴板里的文字（issue #4，2026-11-05，airk 提，对标贴图工具「剪贴板是图钉图、是文字钉文字」）：动作改名「钉住剪贴板内容」（rawValue 不变），没有图片、没有文件、不是 ConcealedType 时把文字排成卡片图（`PinBoard.textCard`）交给同一套钉图；剪贴板面板里文字条目同日也加了「钉到屏幕」（用户要的；只在 ⌘K 和右键，⌘Y 页脚那颗胶囊不动）。
- 截图拷贝为 PNG 文件（2026-11-06，用户转来：用 USB 对拷线在两台电脑间共用剪贴板时截图粘不过去，对拷线的软件只搬文字和文件；对标贴图工具的「复制图像为文件」）：拍板页 https://claude.ai/artifact/Fbr36YjckBeUPs1UcxKPhJ Q1–Q8「全部按推荐」。设置 › 截图「截图拷贝为　图像｜PNG 文件」，默认图像；选文件时截图里每一种拷贝都只放一个 PNG 文件（拖出目录里新的子文件夹，启动时清空、换日时删一天以前的），剪贴板历史照旧记图片；只做 PNG。Windows 同一套写进 `windows/PLAN-v15.md`。现行约束在 mac-native §5、mac-overlay-panel「截图拷贝为 PNG 文件」，手测 `HANDTEST.md`「截图拷贝为文件」1–7。
- 框选时保持屏幕原色（用户 2026-11-06：截图时像蒙了一层粉色滤镜，取色不友好，要能关）：设置 › 截图「工具栏位置」下面加开关「框选时保持屏幕原色」（`Prefs.screenshotKeepsColors`，默认关、跟着导出走），打开后不压暗、悬停窗口只描边、放大镜十字带只描线。替用户定的：默认保持现在的样子，只给开关。随 0.7.3 发布。手测 `HANDTEST.md`「框选时保持屏幕原色」1–2。
- 程序坞预览偶尔闪退（用户 2026-11-06 转来 0.7.1、0.7.2 两份崩溃报告）：`DockWatcher.selectionChanged` 的 `lists.lazy.compactMap { … }.first` 把选中读了两次、第二次是 nil 强解包就闪退；全仓库同样写法的五处换成 `Sequence.firstNonNil`（`Shell/FirstNonNil.swift`，每个元素只转一次），mac-native §4 记一条红线。随 0.7.3 发布。手测 `HANDTEST.md`「程序坞预览偶尔闪退」1。

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
- **截图重设计（2026-09-26）**：方案页 https://claude.ai/artifact/WQFQonH4urad3hmnceBiko 的 D1–D15 全部按推荐，控件换品牌粉（`Style.Shot.accent`）；M9 / M10 里的「8 手柄」「1–4 四种工具」「6 色」已被取代。规格只看 `mac-whisker/capture.md`「截图」，实现约束在 mac-overlay-panel §8–§10。

**第二轮体检（2026-10-02）**
- 背景：0.3.0 打包后的第二轮体检，拍板页 https://claude.ai/artifact/YVtyGn4aKb61AFNHjpbFp8 ，20 项全部按推荐，8 批串行、每批一个提交；改动进 0.3.1（0.3.0 等手测后单独发，不往里加）。手测见 `HANDTEST.md`「第二轮体检手测」。
- 第 1–8 批和之后用户追加的几条（钉图透明度滑块、录制页、翻译浮窗放下三张卡、动作菜单滚动区）的实现记录已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「第二轮体检」）；规矩在 mac-whisker §8、mac-clipboard §1、mac-native「测量与诊断」，手测 `HANDTEST.md`「第二轮体检手测」。

**常驻内存（2026-10-07）**
- 背景：用户让查正式版（0.3.2 本地包，跑了 3 天）`footprint` 342 MB、峰值 510 的构成。只读活进程（两份 memgraph，各停约 3 秒）+ 独立小程序 + 仓库拷贝里跑探针，给了 5 项改法，用户回「全部按推荐」，分批提交。**不是漏**（`leaks` 20 个 / 3 KB；窗口 10 个、面板 3 个、带位图的图层 32 个都对得上）：用过一次就不还的台阶 + 填到上限的缓存 + 堆里空着没还的页。
- 构成、量法、分批，描边换画法、空闲回收、空闲时放掉识字模型、链接预览的头图，以及便签接进空闲回收（调优 T2）的实现记录和实测数已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「常驻内存」）；规矩在 mac-whisker §8、mac-clipboard §5「链接预览」、mac-native「测量与诊断」。
- 等用户定（原「链接预览的头图」那条末尾）：头图分档（透镜只要 320 × 180 像素，按它解一张画过才约 0.5 MB，12 条都看过从约 70 MB 降到约 6 MB；代价是 ⌘Y 大卡要另解一张 1200 的，从透镜长出来的头几帧先糊后清）；把 12 条调小。
- 不做：字形缓存（系统封顶，公开接口清不了）；进程内 Metal（符号动效就会带起来，单把棋盘格 Canvas 换成形状实测省不到 1 MB）；主面板用完放掉（描边改完后三块加起来只再还约 10 MB，每次呼出却要重建）；设置窗的一次性开销（系统控件的堆）；缩略图上限不改（改成空闲时清）；识字全走子进程（现成的 `--ocr` 子进程每次 0.51–0.70 s，进程内热的是 0.22 s，每次都过 0.3 s、都会闪「识别中」）。

**设置的导出与导入（2026-10-07）**
- 背景和对标、第二批（片段、收藏、生词本放进同一个文件）、两轮独立审查改了什么已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「设置的导出与导入」）；规矩在 mac-native §2、mac-clipboard §1。
- 范围（按推荐先做出来，用户 2026-10-07 看过截图和说明后同意、提交）：设置 › 通用最后一组「导出与导入」。一个 JSON 文件四类——设置（各页改过的选项，含剪贴板排除的 App）、快捷键、翻译服务（含 AI 服务的地址和模型）、网页搜索与快捷链接；导出、导入都能按类别勾选。**用户点名的三样之外补充的**：网页搜索与快捷链接；翻译服务的密钥（可选，密码加密）；导入（没有它导出没用）和导入时的校验；会让历史保留得更少时的提醒。
- 取舍：密钥默认不带，带就必须设密码加密（文件可能发给别人、放网盘；明文违反「密钥只进钥匙串」）；偏好只导出改过的 + 导入时整类替换（结果和导出那台一样，没改过的继续跟默认值走）；两张列表合并不删（删 AI 服务会丢密钥）；导入后现场生效，不重启；格式用 JSON（人看得懂、能比较），不注册自己的扩展名。
- 不做：图片 / 文件类的收藏（体积大，要换成文件夹式的备份；本机损坏有每日自动备份）、启动器收藏（⌘D 几秒能重加，目标路径换台电脑不一定在）、普通剪贴板历史（有保留天数、退出 / 锁屏清空这些隐私控制，不该靠导出留下来；每日备份同样的取舍）；~~定时自动导出、导入前自动留一份~~（2026-10-08 做了，见下面「设置与数据的每日自动备份」）；恢复默认设置的按钮；登录时打开（系统的登录项，要装在「应用程序」里才能开）；截图的存储文件夹（这台电脑上的路径，而且别人给的文件不该能改截图存到哪）。导入框里把文件里的翻译服务会连到的自己填的地址列出来（`customHosts`）：名字叫 OpenAI 的服务连的不一定是 OpenAI。

**设置与数据的每日自动备份（2026-10-08）**
- 背景和对标、评审后改的 14 条已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「设置与数据的每日自动备份」）；规矩在 mac-native §2、mac-clipboard §1。
- 范围（给了推荐范围和三项待定，用户回「按推荐」）：每天自动存一份导出文件（六类）在数据目录的 `backups/`；可以另选一个文件夹每天再存一份；设置 › 通用「导出与导入」里显示已有的备份、「从备份恢复」；导入前先自动存一份。三项：**默认开、可关**；**留最近 7 份**（导入前那种留 3 份）；**不带密钥**。
- 取舍：时机跟数据库的备份走（启动、换日、锁屏），不加定时器、不给「每周 / 每月」的档位；恢复不另写一套，就是导入（设置、快捷键整类换回那天的样子；两张列表和数据是合并——没有的加回来、同一条改回去，不删后来多出来的）；开关、另存的文件夹和它的名字、电脑编号、没备成的原因不注册默认值、不跟着导出 / 导入走；另选的文件夹不在了不建、只记原因，那里的文件名带这台电脑的编号、只动自己写的；哪一类多到导出上限就不带哪一类、别的照备；本机那份和另存的那份各走各的，碰另选的文件夹的（看在不在、写）都在主线程外，设置页那一行也不碰它（可能在卡住的网络盘上），读设置、编 JSON 在主线程（上限 32 MB 约 0.6 s，常见的几十 KB 是毫秒级）；数据库当次备份发现库有问题时不做。
- 代价（拍板前说给用户了）：片段、收藏、生词在备份文件里是明文（本机那份和数据库放在一起，没有新增暴露；选了云盘文件夹会同步上去；服务地址里自己写进去的令牌也在里面）；删掉的片段在备份里留到被后面的顶掉为止（7 份，每天都开着就是 7 天；关掉开关后已有的不删、也不再轮换）。
- 已知的边角：系统时钟调到过未来、那时份数又还没满，那几份会留到真到了那天，被当成「今天备过了」（数据库的备份同样）；数据库打不开选「重新开始」后「从备份恢复」是空的——那些 JSON 跟着 `backups/` 挪进了 `damaged-…/`，要用得走「导入…」选里面的文件（弹框里有一段说怎么导回来，用户 2026-10-08 同意加；没做成「重新开始之后设置里还能直接选到」，要的话是重新开始时把那几份拷一份回新的 `backups/`）；上一次另存还卡着时换了文件夹，新文件夹要等下一次触发才有今天那份；重装、清了偏好后电脑编号会换，另存的文件夹里旧编号的那几份不再轮换（还能导入，要手动删）。
- 不做（要的话另说）：备份带密钥（要把一个密码存进钥匙串）；每周 / 每月的档位；「立即备份」按钮（打开开关、选了文件夹时会当场备一次）；另选的文件夹里也放「导入前」那种；从另选的文件夹里直接恢复（走「导入…」选文件）；删备份的按钮；图片 / 文件类的收藏（仍只有数据库的每日备份管着）；内容没变就不新写。
- 没验的：真机流程（`HANDTEST.md`「0.3.2 手测」18）；往桌面 / 文稿 / iCloud 云盘这类受保护的文件夹写时系统的授权框弹不弹、什么时候弹（在面板里选过的文件夹可能直接就有权限；被拒时是那一行的橙字，说去哪开——只在单测里拿只读文件夹验过这句话）；网络盘卡住时的表现（只按「主线程不碰它」写了，手头没有卡住的盘可试）；AppDelegate 里只剩「什么时候调、两份别叠着调、库有问题时跳过」（`backupSettingsIfDue`），这几句单测跑不到——每一份该不该写、写、把结果记进偏好的整条路在 `SettingsBackup.backUpLocal` / `mirror` / `snapshot`，有单测。

**启动器 port（2026-10-08）**
- 背景、做的时候定的、实测过的已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「启动器 port」）；细则在 mac-whisker-launcher「系统命令」。
- 范围（给了推荐，用户回「按这个做」）：加 `port`，但只做成 kill 同一份数据的另一个视图——ps / lsof、`.process` 行、结束 / 强制结束、上膛确认全部复用，`kill :3000` 不动。不同的只有：只列在监听的、一个端口一行按端口号排、标题是端口、副标题带工作目录、数字按端口号开头筛、含程序坞里的 App（↩ 正常退出，⌘↩ 强制退出）。细则在 mac-whisker-launcher「系统命令」。
- 已知的边角：进程自己改过标题的（`process.title`、nginx）名字是它改成的那个的最后一段（「vite.js」「nginx -g daemon off;」），kill 一直也是这样；别的用户、系统的进程在监听时看不到（lsof 不用 root 只看得到自己的），所以空结果写「没有找到」；同一个 App 开了两个实例时退出的是先找到的那个（quit 一直也是）。
- 不做（要的话另说）：显示绑定地址（仅本机 / 局域网可访问）、在浏览器里打开、给端口起名、UDP、复制端口 / PID。
- 没验的：真机流程（`HANDTEST.md`「0.3.2 手测」19）。

**状态屏（2026-10-10 立项，0.4.0）**
- 背景和对标、做法、第 0 批实测、没验的、已知的边角、各批「做的时候定的」、表情怎么播（实测）、分批已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「状态屏」）；写代码的规矩（做法、实测、没验的、已知拦不住）在 mac-overlay-panel §11，样子在 `mac-whisker/status-screen.md`，手测 `HANDTEST.md`「状态屏手测」。
- 拍板（Z1–Z12）：① 名字「状态屏」。② 定位是告示加防误触，**不是安全锁**，不做退出验证（验证出问题时键盘鼠标都被拦着，只能强制关机）；界面和更新日志里不要写成「锁」。③ 自带三个状态：清洁屏幕（熄屏、电源照常、5 分钟自动结束）、请勿触碰（透出、屏幕常亮、说明「电脑正在跑任务，别动键盘和鼠标」）、马上回来（告示、不睡眠）；都能改、删、拖动排序，能再加。④ 每个状态六项：标题、说明（可空）、图标（一组符号里选，可不要）、样式、电源（照常 / 不睡眠 / 屏幕常亮；第三项 2026-10-12 前叫「不睡眠且屏幕常亮」）、自动结束（不 / 5 / 15 / 30 / 60 分钟）；告示和透出样式底部固定一行小字「几点开始 · 已经多久」，按分钟更新。⑤ 三种样式：熄屏（纯黑，什么都不显示）、告示（深色底 + 大字）、透出（屏幕压暗 + 大字）。⑥ 键盘、鼠标点按和滚动、媒体键全拦。⑦ 退出：按住 esc 2 秒，或用鼠标按住屏幕上的退出提示 2 秒；按住 esc 期间碰到别的键就重来。⑧ 退出提示平时不显示，有人碰了键盘鼠标才浮出 3 秒，同时标题晃一下；设置里可以关（关了只剩按住 esc）。⑨ 锁屏期间不拦输入、电源设置照旧生效，**解锁回来自动结束**（想真防人：进入状态屏后再锁屏）。⑩ 入口：启动器（每个状态一条）、菜单栏「状态屏」子菜单、一个全局快捷键（不设默认键，进入列表第一个状态）。⑪ 设置新加一页「状态屏」，排在「录制」后面。⑫ 单独发 0.4.0。
- 不做（要的话另说）：退出要触控 ID（退出密码 2026-10-11 做了，见下面「第三轮」）、拍下动手的人、进入时暂停音乐、空闲多久自动进入 / 定时进入、命令跑完自动结束 / 显示任务进度、自选图片和表情、回来时间倒数、模糊样式、每个状态单独设快捷键、退出键可改。
- **第二张拍板页（2026-10-10 傍晚，用户装上 0.4.0 测试包后提的两件事；https://claude.ai/artifact/W9SHBbMgvbHnJEy7x9Mv3Z ，回「全部按推荐」）**：⑬ 按全局快捷键时先出一排预览卡片，选一个再进（←→ / 数字键 / ↩ / Esc；默认选中上次用的；设置里一个开关可改回「直接进入排在最前面的」，默认关）。⑭ 选中的卡片放大成整屏。⑮ 告示的图标改用现成的动画表情——用户嫌我手画的动画「太粗糙」，要我去网上找现成的：选了 **Microsoft Fluent Emoji Animated**（github.com/microsoft/fluentui-emoji-animated，MIT，746 个，动画 PNG 256 像素；Google Noto 那套许可没从官方核实到、缺 Zzz 和黑猫，LottieFiles 要加播放库、和零依赖冲突）；清单 16 个（用户确认过）：举手、挥手、发光的星、闹钟、沙漏、热饮、Zzz、睡觉脸、嘘、人影、电话、火箭、机器人、火、闪电、黑猫，另加被碰时用的眼睛。⑯ 进场：表情落下弹一下、标题逐字浮现。⑰ 有人碰键盘鼠标时：标题晃、表情甩一下、屏幕底边冒出一双眼睛看一眼（熄屏样式不冒）。⑱ 设置里一个总开关「告示上的动画」，默认开；系统的「减弱动态效果」打开时一律静止。
- **第三轮（2026-10-11，用户装上测试包后又要的两件事，原话：「倒计时时间改成加入秒，然后期望时间过度有动画效果」「期望还可以加入密码，设置了密码就必须输入密码才能解锁」；没出拍板页，直接做的）**：⑲ 告示上的小字精确到秒、变了的数字滚过去。**滚动不用 SwiftUI 的 `numericText`**：独立小程序实测（19 pt 的这一行、每秒换一次、只算本进程）它占 9–15% CPU（13 pt 约 7%，每 5 秒一次 1.6%），逐字 `.transition(.push)` 1.6–2.4%，`.contentTransition(.opacity)` 0.9%，`.interpolate` 3.3%，只换字不做动画 0.2–0.3%；自己排的图层版（当时在 `StatusScreen/StatusTicker.swift`，现在是 `Shell/Ticker.swift`：一字一块 CoreText 位图，只给变了的数字加滑动和淡入淡出的图层动画）0.5%，用它。录制 HUD 的计时（13 pt、numericText）按这个数录制时一直占着约 7%，没在这一轮改，同一天另改了（下面「录制 HUD 的计时」）。⑳ **退出密码**——推翻 ② 的「不做退出验证」。当初不做的理由是「验证出问题时键盘鼠标都被拦着，只能强制关机」，现在的出路：解锁即结束（⑨）不变，忘了密码、输不进去都可以锁定屏幕再解锁出来；钥匙串读不到就当没设。规矩在 mac-overlay-panel §11「退出密码」，样子在 `mac-whisker/status-screen.md`。
- **第四轮（2026-10-12，用户原话：「期望这个效果不是点击鼠标或者按下按键才触发，期望能随机出现在屏幕的四个任何区域」）**：眼睛改成从屏幕四条边里随机的一处探出来（顶边倒着、左右横着），没人碰的时候隔 15–45 秒自己冒一次、露 3 秒；有人碰键盘鼠标时照旧也冒（现在也是随机的一处，不再固定在退出提示右边）。用户同一天补了一句「四个边出现的位置也要随机，有可能在中间，有可能在最边上」：沿着边整条都随机，正中、贴着角都可能。做的时候定的：「四个区域」按四条边做（不是四个角）；只有两种时候让开正中——退出提示正要浮出来的那一次让开底边正中、有带刘海的屏时让开顶边正中（被摄像头挡着）；眼睛垫在退出提示下面；不连着两次同一条边；多块屏同一处；间隔和露多久没做成设置项。样子在 `mac-whisker/status-screen.md`「眼睛」，待手测 31。

**录制 HUD 的计时（2026-10-11）**
- 起因：计时（13 pt 圆体 semibold + 等宽数字）原来每秒 `.contentTransition(.numericText)` 滚一次，录屏 / 录音期间一直占着 CPU，还可能影响录制本身。
- 实测、改法、图层视图挪到 `Shell/Ticker.swift` 和画法的两处改动、验过的已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「录制 HUD 的计时」）；规矩在 mac-whisker §8。
- 没动的：菜单栏停止项的计时是状态栏按钮的标题，直接换、本来就不滚；长截图的高度、设置里的字号、列表条数这些偶尔才变的数字还是 numericText（mac-whisker §8）。
- 没验的：真机上滚动的样子、录制期间活动监视器里的 CPU（`HANDTEST.md`「录屏 / 录音手测」68）。

**视觉对齐（2026-10-12，0.4.0）**
- 背景：用户原话「目前系统所有的界面都需要做一个视觉对其」。理解成全 App 的对齐和一致性走查：该在一条线上的有没有对上、同一种东西长得一不一样、值在不在刻度上。
- 走查、五批提交、顺带查清的、做的时候定的、截图自检的前缀开关已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「视觉对齐」）；改过的值都在各份 `mac-whisker*` 规则里。
- 定下来的（真要选的五项）：同一个 ⌘K 菜单全 App 叫「操作」（速查表里指菜单本身时叫「操作菜单」；代码和规则里的部件名「动作菜单」不改，已发布的更新日志不改）；主按钮 `BrandButtonStyle` 常规档高 20、和系统按钮等高；键帽 10.5 pt / 左右 5、键帽之间 3 是刻度的例外，不动；录屏和录音的控制条各状态按**右边线**对齐（✕ 和主圆钮不动、只往左长）；计时按当前位数留宽。
- 看过、定了不动的：快捷键页色块 20（别处 24）；截图工具栏悬停底圆角 6 对当前工具底块 12；启动器空结果一行字；剪贴板的中性种类图标；卡片右上角按钮没有悬停效果（新交互，另说）；菜单栏菜单里实心 / 线框图标混用（没有截图，先补截图再定）；状态屏整屏量过没有要改的。
- 没验的：全部是屏外截图和单测，真机一次没看；录屏 / 录音的实录自检没跑。手测在 `HANDTEST.md`「视觉对齐手测」1–20。

**便签（2026-10-12 立项，0.5.0）**
- 背景：用户给了 github.com/aimen08/noty（屏幕边缘的便签，原生 macOS，Swift + SwiftUI + AppKit，MIT），要把完整功能迁进来，定了放进 Kitty 当第七族。源码读过（`2a1a81d`：38 个文件 12,523 行，测试 2,218；编辑器与图片 3,389、边缘那叠与浮动便签 2,384、数据 978、同步 907、设置与快捷键 1,212）。同类只看了通行做法：系统「便笺」（置顶、半透明、折叠、第一行当标题）、SideNotes（贴边，热边 / 快捷键 / 菜单栏唤出，隐藏 Markdown 标记，全屏里也能用）、Raycast Notes（浮动窗口、快捷键、Markdown、删掉的留 60 天）。拍板页 https://claude.ai/artifact/VHHy2dsV5L3KjyYunQTNg6 （25 项 A1–F2，另有逐项对照表），用户回「便签：全部按推荐。开始前先发布 0.4.0」。调研材料在 `macos/build/research/noty/`（不进仓库）：`report-editor.md`、`report-data-sync.md` 两份深读报告（带 文件:行号，接手先读）、`probe/edge-probe.swift` 测量小程序、`src/` Noty 源码（只读；**别跑它的脚本和测试**——它的测试会把真实的图片目录当孤儿清空）、拍板页的生成脚本。Noty 是 MIT：只借思路和数值自己重写，许可声明随包、关于页写一行出处（mac-whisker §11）。
- 拍板（A 定位）：① 叫「便签」。② 管「留着看、接着改」的东西（待办、备忘、草稿）；和片段（反复粘贴的文字）、收藏（留下的剪贴板条目）、钉图（临时对照的图）各存各的、不合并，靠操作互转。③ 0.4.0 发布后开工，作为 0.5.0。
- 拍板（B 边缘那叠）：① **有了第一条便签才出现**（第一次出现时刘海岛说一句在哪），设置里有总开关，**关掉不建窗口**，便签照样能用快捷键、启动器、全部便签窗口。② 默认右边、只在主显示器；左 / 右、全部 / 主屏 / 指定屏、按住 ⌥ 拖药丸换边换高度换屏都有；两块屏相接的那条边不放、自动换到外侧。③ 默认不盖在全屏 App 上，设置里可开；快速记一条同别的面板，全屏里也能呼出。④ 扇出的标签 4 秒不碰收回；**打开的便签不按时间自己收**（Noty 是 1 分钟），点别处才收，固定后点别处也不收。⑤ 新增两个自建窗口的例外（边缘那叠、浮动便签），都不激活本 App；快速记一条用 `OverlayPanel`；全部便签是普通窗口、和设置窗同一套打开方式。⑥ 药丸算装饰（截图、录屏都不收），打开着的便签和浮动便签算内容（截图冻结帧里有、能悬停选中，录屏白名单里有，同钉图）；框选、长截图、选录屏区域时边缘不响应鼠标；进状态屏前先落盘、收起那叠。
- 拍板（C 便签本身）：① 编辑器三步都做、分三批，每步做完都能用：纯文本 + 任务 → Markdown 边打边变样 → 行内图片（先不带裁切、宽度预设、工具条）；图片可以晚一个小版本。② 浮动便签一次一张（同 Noty），固定着的那张重启后回到原处；同时浮多张以后再说。③ 8 种纸色照搬、深色外观另调一套；默认系统字体、设置里可换；形状、阴影、动效按 Whisker 重画，另写 `mac-whisker/notes.md`；家族色黄。④ 文字方向菜单不做。
- 拍板（D 数据）：① **单独的库和图片目录**，剪贴板的清理、保留天数、锁屏清空、「重新开始」都碰不到；便签库打不开时单独处理。② **正文不加密**（同剪贴板，靠系统的磁盘加密；Noty 的密钥是库旁边的文件，防不了能读到库的人，放钥匙串则换签名 / 换机 / 从备份恢复时一丢全丢）。③ 归档照搬；**删除进「最近删除」留 30 天**，刚删时刘海岛给「撤销」。④ 便签库每天备份（连图片，留 7 份）；便签文字并进导出文件和每日 JSON 备份当第七类；设置 › 便签另有「导出为 Markdown 文件夹」和「导入」（文件头带编号、颜色、日期，原样导回不重复）。⑤ **iCloud 同步这一版不做**，以后单独立项；模型先留好稳定编号、修订号、删除记录。
- 拍板（E 打通）：① 三个动作进启动器；关键词 `note`：空着列最近的，带关键词搜标题和正文，↩ 打开，⌘↩ 把后面那段话存成新便签；不进默认搜索结果。**2026-10-17 用户去掉**（第 8 批不做）。② 开着便签时从剪贴板面板 / 启动器粘贴要落进便签；点 Kitty 自己的面板不算点别处；剪贴板 ⌘K 加「存成便签」——**粘贴落进便签 2026-10-17 做了（第 8 批 R12），剪贴板 ⌘K「存成便签」用户去掉**。③ 常驻缩略图的菜单加「存成便签」，跟图片那一批——**2026-10-17 用户去掉**。④ 焦点在便签里时划词翻译读便签自己的选区——**2026-10-17 做了（第 8 批 R13）**。⑤ 给别的工具调用的链接（URL scheme）不做。
- 拍板（F 入口）：① 全局键只有「快速记一条」有默认键 ⌥N；「新建便签」「全部便签」不设默认键；归档并进全部便签窗口。② 设置加一页「便签」；快捷键页、速查表、菜单栏、启动器各加「便签」一节，三项同名同序；便签里的按键固定（⌘K 操作、⌘P 固定、⌘T 任务、⌘F 查找、⌘⌫ 删除、Esc / ⌘W 关），不做成可改。
- 不做 / 以后再说：Sparkle、Intel 版、Homebrew、多语言不做；txt 导出、合成一个文档、Noty 的归档格式不做。以后再说：自定义纸色和「常用」颜色（2026-10-13 用户提了又说「暂时不做，后面再说」；当时的设想：`color` 整数里另编一段表示 sRGB 色值、由选的颜色推出纸 / 色条 / 墨、系统取色面板、最近选过的 8 个记成常用）、iCloud 同步、同时浮多张、图片裁切和宽度预设、表格 / 有序列表的样式（Noty 也没有）、分隔线、裸网址自动成链接、引用嵌套（代码块和 ⌘B / ⌘I 这类加标记的快捷键第 6 批定成不做，2026-10-15 手测反馈第 4 批做了）、斜杠菜单、自动补全成对的符号、代码的语法高亮、⌘K 当链接键（⌘K 是操作菜单；后四样是手测反馈第 4 批定成不做的）、翻译和识字结果「存成便签」、便签选中文字「存成片段」、「只待在一个桌面」、从 Noty 导入它的归档；把便签里的图片拖到别的 App 成文件、在便签里按住图片挪位置、点开看大图、动图播放（只显示第一帧）、图片说明文字（第 7 批定成不做，图片的工具条 / 裁切 / 宽度预设见上面「图片裁切和宽度预设」）；启动器 `note` 关键词、剪贴板 ⌘K「存成便签」、常驻缩略图「存成便签」（2026-10-17 用户在第 8 批去掉）、文字颜色的快捷键和 ⌘K 入口、任意颜色（取色板）、高亮底色、字号 / 字体、任务状态的快捷键 / 截止日期 / 按状态筛选和排序、导出成一个合起来的文档 / txt / PDF、导入时进子文件夹 / wiki 式 `![[图]]` / 联网下载图片、导出时自动打开访达（第 8 批）；标题 4–6 级的菜单项（能手打）、多选几条一起导出、拷贝为 Markdown、脚注、下划线、任务以外的勾选框（第 8 批之后的一轮）。
- Noty 怎么做的、立项时的实测、做法（数据，第 1 批照它写的库、备份和导出格式）、分批和各批一行摘要（提交号、`HANDTEST.md`「便签手测」编号）已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「便签」）；各批的详细实现、量到的数和评审记录在 `docs/archive/PLAN-notes.md`。
- 已知取舍（便签的备份，2026-10-12 评审时记下）：① 便签全删光之后不再备份（空表不备），旧备份不再轮换、一直留着。② 永久删除的便签在 `notes-backups/` 里最多还留 7 份（不是每天都开就更久），在每日 JSON 备份里同理。③ 便签连续 7 天不可用（每次都选「这次先不用」、或者一直是更新版本写的库）时，带便签的每日 JSON 会被不带的顶光——这期间 `notes-backups/` 不动，数据还在。

- 仍然生效的约定（不在这一节重复）：便签库、图片、备份和剪贴板互不相干在 mac-clipboard §1；那叠和浮动的窗口、焦点、键盘、截图 / 录屏里各算什么在 mac-overlay-panel §12；正文编辑器、Markdown、任务、颜色、行内图片、导出导入在 mac-overlay-panel §3 §5；长相和交互在 `mac-whisker/notes.md`；划词读便签选区在 mac-translate §5。

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
- 各批摘要（1 图片宽度档位、2–3 自定义纸色、4–5 同时浮几张、6 图片裁切、7–10 同步的数据准备 / 文件夹写法 / 执行层 / 设置页；手测 270–295）已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「便签的四个新功能」）；规矩在 mac-native §2「便签同步」、mac-overlay-panel §3 §5 §12、`mac-whisker/notes.md`。
- 留给执行层的（原第 7 批，第 9 批已照做，规矩在 mac-native §2「便签同步」）：正在编辑（尤其输入法组字中）的那条，合并结果换进来之后编辑器会拿旧底 + 新字整段写回、钟又 +1，把同步来的改动盖掉——执行层要等那条不在编辑时再换；自己子文件夹里某条的 `clock[本机]` 比库里大（时间机器恢复）要换编号；文件写出去之前先落盘。
- 没改的（原第 9 批）：换编号后本机旧的子文件夹在「别的电脑」里显示成同名的一台；网络盘卡住时一轮不结束（ponytail）。

**全局同步（2026-10-23 拍板；0.6.0 只挪位置，其余进 0.7.0）**
- 来由：用户 2026-10-23「便签这个同步功能是不是可以移动到通用里面，直接全局同步就可以了」。拍板页 https://claude.ai/artifact/HPqLM8wzRHx9eF5dpFBfQv（20 项，生成脚本在主检出 `macos/build/research/global-sync-2026-10-23/build-decisions.py`；对标 Raycast Cloud Sync、Alfred 同步偏好文件夹、Paste 的 iCloud 同步，查的官方说明），用户「全部按推荐」。
- 拍板（A 入口）：设置 › 通用 里一节「同步」，便签页那一节拿掉；一个文件夹管全部；每类一个勾，默认勾上推荐的几类，取消一类只是不再同步、文件夹里的不删。**升级例外**（第三轮体检 R1，2026-10-27）：0.6.0 时就开着便签同步、升上来的那台（同步文件夹有、设置这一类没有账本、勾从没存过，`NoteSyncer.isUpgrade`），便签之外的几类第一轮之前先不勾、存下来——不然设置第一次合是 adopt，不问就把这台的设置、快捷键、功能开关整个换成别的 Mac 的、再按对面的保留天数清历史；刘海岛（并进「已更新到」那座）和设置页各说一声。**勾上时先问**：勾上一类会是它第一次合（没有这个库的账本）而文件夹里有别的 Mac 时，先弹「『某类』和已经在同步的 Mac 合在一起？」，说明和选文件夹时那段一样（`NoteSyncer.joins`）；0.7.0 里第一次选文件夹的照旧走选文件夹时那一问，开同步时把勾存一份。
- 拍板（B 同步哪些）：同步设置（**留在本机**：启动台整页、录屏 / 录音选的麦克风、便签放在哪块显示器，加上导出已经排除的窗口位置、文件夹路径、授权状态这些）、全局快捷键、功能开关、片段和文字收藏和收藏夹、生词本、网页搜索与快捷链接、翻译服务列表（**密钥不同步**，别的 Mac 上显示「还没填密钥」、自己填一次）、启动器收藏（另一台没装的 App 不显示）；图片收藏以后再说，文件收藏不同步；**不同步**剪贴板普通历史、翻译历史、启动器使用记录、启动台排法。
- 拍板（C 怎么合）：一条一条的数据（片段、收藏、生词、搜索与链接、翻译服务、启动器收藏）后改的赢、不留旧版；删除也同步（留记录），一轮删太多先停下来问（和便签同一个刹车）；设置一项一项比、后改的赢（要开始给每一项记改动时刻）；新加入的 Mac 设置和快捷键跟着文件夹里已有的，数据合在一起（同样的正文不重复），开之前的「合在一起？」写清楚。
- 拍板（D）：0.6.0 只把便签同步挪到「通用」（说法改成全局的，暂时只有便签一类），其余几类进 0.7.0；顺序 挪位置 → 框架和按类开关 → 片段、收藏、生词 → 搜索与链接、翻译服务、启动器收藏 → 设置、快捷键、功能开关。**0.7.0 那几批不进 main**（main 是 0.6.0 的发布线）：在 roadmap 检出另开分支 `sync-wip` 做、审查后各一个提交，0.6.0 发布后再 rebase 并回 main、改版本号（2026-10-24 0.6.0 发布后以合并提交 `c2dca076` 并进 main，版本号升到 0.7.0）。
- 各批摘要（1 挪位置、2 引擎、3 片段收藏生词本、4 搜索翻译服务启动器收藏、5 设置快捷键功能开关和状态屏的状态、第三轮体检第 6 批提速）和并回 main 时的更新日志草稿已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「全局同步」）；现行规矩在 mac-native §2「便签同步」里的「全局同步」，执行层要守的写在 `Storage/SyncRecords.swift` 文件头。
- 留给执行层（原第 2 批，写在文件头）：账本和数据同一个事务提交、从备份恢复时账本跟着退回、关掉一类不清账本、交进来的是落下的全部、编码稳定、值里不带只属于这台电脑的东西。
- **用户 2026-10-24 定**（原第 5 批）：保留天数、「不记录」的 App、剪贴板功能、复制即译这几项**继续跟着别的 Mac 同步**、不进 localKeys（评审 H1；第一次合时「合在一起？」里写明，之后别处把保留天数改短本机也跟着清，清掉了刘海岛说几条）。
- 没改的 / ponytail（原第 3、5 批和第三轮体检第 6 批）：别人一份文件一直读不出来（不用了的电脑留下的坏文件）这一类一直停（ponytail，要忽略再加）；便签库打不开时整个同步都没有（电脑编号在便签库里）；「不记录」的 App 列表整张一条（两台同时各加一个丢一个，ponytail）；改回默认和别处同时改值时改值的赢（墓碑压不住同时的改动，写在文件头）；跨版本收拾规则变了（表情清单、保留档位）可能把新版本的值收拾掉再发回去；指纹只在内存、重启后第一轮全合；没变的一轮仍随文件数线性涨（5000 条 13–19 ms），升级路径 FSEvents。

### 启动台（第八族，0.6.0，2026-10-18 立项）

需求、做法和验收标准在 `macos/build/research/launchpad/SPEC.md`（用户交给 agent 的规格；R1–R11 是验收标准）。这里只记仍有效的约束和已定的事。
- **是什么**：复刻 macOS 15 的全屏图标网格（macOS 26 起系统那个换成了「应用程序」视图）。**只在 macOS 26 起出现**（2026-10-19 用户定）：15 上系统自带启动台，我们的整个藏起来（`Launchpad.isAvailable`，各入口怎么藏见 mac-launchpad §4）。**和现有的「启动器」（`Launcher/`，⌥Space 的搜索框）是两个东西**：名字、设置、快捷键都分开。家族色薄荷绿 `Style.Family.launchpad`。
- **在哪**：`KittyTools/Launchpad/`（§4 文件表），设置页 `Settings/LaunchpadTab.swift`；规矩 `mac-launchpad` + `mac-whisker/launchpad.md`；手测 `HANDTEST.md`「启动台手测」。
- **窗口**：自建窗口的新例外 `LaunchpadPanel`（mac-overlay-panel §1）：盖满鼠标所在那块屏、`.statusBar`、`.nonactivatingPanel` + `canBecomeKey`、不激活本 App、每次打开新建、收起放掉。盖住整块屏（菜单栏和程序坞都在下面）——普通窗口做不到「盖住菜单栏又让程序坞露在上面」，这是唯一做不到和 macOS 15 一样的地方（SPEC §3.2）。
- **布局**：一份 JSON 存 `Prefs.launchpadLayout`（注册空串默认值，SettingsArchive 的「设置」一类跟着导出 / 导入和每日备份走；不另开库）。App 按 bundle id 认（没有的按解开链接后的路径）。第一次打开、还没存过布局时：有系统旧启动台库就自动导入（SPEC §5.4），读不到用默认排法（系统 App 在前、`Utilities` 进「其他」文件夹、其余按显示名）。
- **入口**：菜单栏一项、现有启动器里一条「启动台」、全局快捷键（默认不设）、触控板捏合（第 3 批，主入口）、触发角（第 3 批，默认关）。总开关 `Prefs.launchpadEnabled`（2026-10-21 并进功能开关 `Feature.launchpad`，见下面「功能开关」）。截图 / 录屏 / 状态屏 / 正在录快捷键时不响应；打开别的功能先收起。
- **不做**（这一版）：下载中的 App 进度图标、往程序坞拖、iCloud 同步布局、小组件、按分类自动整理、多块屏同时显示、「启动台」作为独立 App 出现在程序坞里、自定义图标、隐藏某个 App、给文件夹换颜色、「最近使用」排序。
- 四批进度、两轮评审（FIXES F1–F46、FIXES-2 G1–G29）、七轮真机反馈、捏合跟手、调度中心里打开、四指捏合两处修复和 R11 量出来的数已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「启动台」）；规矩在 `mac-launchpad` + `mac-whisker/launchpad.md`，手测 `HANDTEST.md`「启动台手测」。
- 还没做 / 没量的（原文在归档各轮里）：系统手势开着也能用（B）等用户在场时跑探针（`build/research/launchpad/probe/`），过了做第 2 批；没做「系统手势开着时拦下系统的捏合给自己用」（要事件拦截 + 私有事件类型，另议）；没做：面板常驻（A8 的 ②，开头那约 0.1 s 真机觉得慢再做）、逐渐加模糊；拖动 / 跟手的每帧时间、真机第一帧、静置 CPU **都还没量**（单测里不注册触控板回调，HANDTEST 10 / 16）；Release 单测构建在这个仓库里本来就编不过（和这一族无关），量的是 Debug / `-O` 覆盖。

---

### 功能开关（2026-10-21 立项，0.6.0）

- 用户 2026-10-21：「不用的功能模块可以有一个关闭的按钮，或者就不加载这个模块」。方案 `build/research/features-2026-10-21/SPEC.md`（D1–D8 都按推荐；
  原想交用户的 agent 做，2026-10-22 用户改成主会话直接做，在单独的检出 `kitty-tools-macos-features`、分支 `features-wip`）。
- 对标、实现（`Shell/Feature.swift` 和各处怎么接）、评审后一轮、验证已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「功能开关」）；规矩在 mac-native §1「功能开关」，手测 `HANDTEST.md`「功能开关手测」1–14。
- 原理：代码不拆插件（`Bundle.unload` 要保证没人引用、`dlclose` 不卸含 Objective-C 类的库）；没执行过的代码页本来不进常驻内存，
  省的是运行时的东西——全局快捷键（交还系统）、剪贴板 0.3 s 轮询和复制图片后的识字、启动器 / 启动台启动时扫目录、启动台常驻图标（约 15 MB）、
  触控板回调、触发角、便签屏幕边缘的药丸。
- 拍板：八个功能（= 设置侧栏的八页，`Feature` 与 `SettingsPage` 同名）各一个开关；两处同一个偏好（通用页最上面「功能」一组 + 各页第一行「启用…」，
  关着的页其余设置变淡点不了、管数据的不变）；立即生效；关掉 = 入口全藏 + 快捷键不注册 + 后台停，**数据层照常**（库照开、每日备份、保留天数和
  「最近删除」到期照删）；默认全开、引导不加；启动台原来的总开关并进来；开关跟着导出的「设置」走，导入会让剪贴板从关变开、让复制即译实际跑起来时
  橙字提醒；不做一键全关。
- 2026-10-22 第九族程序坞预览加进来：九个，它**默认关**（`Feature.defaultOn`，拍板页 A3）、没有全局动作（`FeatureTests` 的例外），见下面「程序坞预览」。

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
- 本机实测、做法、面板和时机、两次手测反馈（快速划过程序坞、压住程序坞的名字提示）、三批进度已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「程序坞预览」）；现行规矩在 `mac-dock-preview`（私有接口、听程序坞、列窗口、缩略图、面板和时机、内存、测试口径）+ `mac-whisker/dock-preview.md`，手测 `HANDTEST.md`「程序坞预览手测」。
- **默认关**（拍板 A3）：`Feature.defaultOn`，程序坞预览注册成 false（导出只带存过的值，导入旧文件会回到关）；运行中打开时缺
  辅助功能就弹系统的授权框，有了再要屏幕录制（`AppDelegate.applyFeatures`；启动时不问）。导入会不会打开它不进
  `SettingsArchive.privacyLosses`：缩略图只在内存里、不往外发。
- 2026-10-29 体检（用户「说不上来哪里不对劲」，对照 DockDoor 和系统菜单查出 7 条，用户选改 1–4）：等着弹时按过鼠标不弹、
  收着时停稳一半就列窗口截图、面板直接出现不淡入、✕ 挪到左上角；没改的 5–7（悬停改强调色描边、换图标不滑改成跳、长标题中间截断）
  先搁着。规矩在 mac-dock-preview §5、mac-whisker-dock-preview §1–3，手测 HANDTEST「程序坞预览手测」18、19。

### 刘海岛交互（0.7.0，2026-10-26 立项）

- 用户 2026-10-26：「灵动岛的通知非常鸡肋，又不能交互」。只改通知本身，不重启 10 月那套常驻刘海（2026-10-03 定了先不做，
  调研和拍板页在 `build/research/notch-*`）。拍板页 `build/research/island-interactive-2026-10-26/decisions.html`，10 项
  **全部按推荐**：A1 只改通知（改 Whisker S2 的「窗口不接鼠标」）；B1 悬停停住并展开成卡片；B2 平时露最主要的一个按钮；
  B3 点岛 = 打开类动作（撤销这类只能点按钮）；B4 × + 双指上滑；B5 悬停时新提示排队；B6 动过才算悬停 + 0.3 s 防误点；
  C1 按场景表加按钮；D1 提示历史先不做；D2 不加「只在出错时弹出」的开关。
- 对标、做法、两批提交、修了的崩溃、动画卡顿的几轮已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「刘海岛交互」）；规矩在 mac-whisker S2、mac-overlay-panel §1 §8「轻提示」，手测 `HANDTEST.md`「刘海岛交互手测」。
- **主动叫出来**（`c8595f5b`；同日用户试了测试包：「不能手动交互吗，现在只能被动交互」；问了三项都按推荐）：没有提示时点刘海（指针停在
  刘海上先鼓起一点），或者按全局快捷键「打开刘海岛」（默认不设键；没有刘海的屏只能用它），长出「那一张」：一排快捷动作 +
  本次启动以来最近 10 条提示（只留打开类的按钮）。`HotKeyAction.feature` 改成可选：「打开刘海岛」不属于任何功能、一直在，
  一节「刘海岛」排在最后（菜单栏、启动器、快捷键页、速查表都有）。不做：最近复制的几条（和 ⌥C 面板重复、隐私）、录屏计时
  这类常驻的「活动」、悬停就展开（划过刘海去点菜单栏会误开）。

### 晾衣绳（第十族，0.7.0，2026-10-26 立项）

- 用户 2026-10-26 看了开源项目 tendedero（MIT，把截图挂在屏幕顶部一根绳子上）后要求集成进来，当作截图的第三种展示方式。
  **只借做法、不抄代码**；它的名字和图标不在 MIT 范围内，所以中文名叫「晾衣绳」、图标自己画，界面里不提任何别家产品。
  拍板页 `build/research/clothesline-2026-10-26/decisions.html` 和 SPEC.md，**全部按推荐**：A1 名字 / A2 归截图家族（不新增功能开关）；
  B1 和右下角的常驻缩略图二选一（设置 › 截图「截完图放哪」三选一）、B2 绳子是截图历史的一个视图（挂着的打个标记，取下只改标记）、
  B3 最多 8 张、屏幕窄时按宽度减、不自动消失、不跨重启；C1 停菜单栏 0.3 s 滑下来 / 离开 0.4 s 收 + 一个可设的全局快捷键、
  C2 中间断开给刘海岛让位、C3 单击拷贝 / 双击改标注 / 拖出去 / 右键一整套（不做用力点按、不做系统「标记」）；
  D1 保留常驻缩略图那张卡的做法、换上夹子和摇摆、D2 取下不问（东西还在历史里）、D3 只在鼠标所在的那块屏、全屏时不出来。
- 四批提交、线 / 夹子 / 动画重做的一轮、同日两条（弧度、空绳时别让卡片等）已归档到 `docs/archive/PLAN-batches-2026-10.md`（§10「晾衣绳」）。
- 做法和红线在 `.claude/skills/mac-overlay-panel/rule.md` §14，长相在 `mac-whisker/capture.md`「晾衣绳」，手测在
  `HANDTEST.md`「晾衣绳手测」1–22（真机都还没走）。
- **自动验不了、只能真机看的**：停菜单栏多久滑下来的手感、挡不挡菜单、点不点得穿、全屏时出不出来、拖到废纸篓 / 文件夹 /
  别的 App 的落点、刘海屏中间让位看着对不对——屏外渲染只锁得住排法和长相。

### 主界面（0.7.0，2026-10-29 立项）

- 用户 2026-10-29：「点击系统托盘的左键和右键都是打开菜单，需要改成左键可以有一个窗口可以看到所有功能，就是类似一个主界面的功能，
  windows 也需要一起同步这个功能」。拍板页 https://claude.ai/artifact/QFAprVTYcWsbWpRWGbMwS6（本地 `build/research/home-panel-2026-10-29/decisions.html`），
  17 项**全部按推荐**：A1 挂在图标下的面板（不是普通窗口）、A2 右键照旧弹菜单、A3 不加「左键也弹菜单」的设置、A4 macOS 27 先样机、
  A5 叫「主界面」；B1 和菜单同一份、只放功能（不放最近的内容）、B2 色块格子一行 5 格、B3 点功能先收再做 / 开关原地切、
  B4 方向键 + ↩ + Esc、B5 状态屏那格同它的快捷键、B6 点图标挂在图标下面、别的入口在屏幕上方正中；C1 关着的功能藏起来 + 一行
  「N 个功能关着 · 管理…」、C2 加全局动作「打开主界面」（默认不设键、不归功能）+ 启动器 + 再打开一次 App、C3 更新日志 + 引导半句；
  D1 Windows 内容同 mac、外壳跟 Windows、D2 Windows 等 0.1.0 打完包作为 0.2.0 第一批、D3 照 PLAN-v10 D5 混合分工。
- 做法：面板是 `OverlayPanel` 实例（`Shell/HomePanel.swift`，AppDelegate `homePanel`，第一次用时建、留着）；内容按
  `HotKeyAction.sections` + 每节的 `MenuExtra` 现算（`Home.sections`），菜单栏菜单不列「打开主界面」。菜单栏图标不再挂
  `item.menu`：按钮的动作收左右键（右键、⌃点从按钮上 `popUp` 菜单），macOS 27 起左键走 `expandedInterfaceDelegate`。
  **27.0.1 样机实测**（`build/research/home-panel-2026-10-29/probe/`，用户在本机点的）：右键照样到得了按钮的动作；挂 `item.menu`
  再 `performClick` 会被当成左键、开出展开界面（所以菜单从按钮上直接弹）；展开开着时再点图标系统什么都不说（靠面板的「点了外面」
  收起，15–26 上由按钮的动作收，`StatusItem.ownsClick`）；⌃点系统当左键开展开、按钮同时还收到右键（带 ⌃ 的展开当场取消）。
  另外：测试程序别叫 `probe` 这类通用名——偏好域按可执行文件名，别的同名程序留下的 `NSStatusItem VisibleCC Item-0 = 0` 会把第一个图标藏掉。
- 手测 `HANDTEST.md`「主界面手测」；15 / 26 上没真机，左键靠按钮动作那条路只按代码推过。

### 功能图标（0.7.0，2026-10-30）

- 用户 2026-10-30：两边的图标没保持一致，「考虑要不要引入一套 icon 给他们共同使用」「每个功能的 icon 帮我重新设计一下，然后统一到
  windows 和 macos」。拍板页 https://claude.ai/artifact/H9NqNwEMZgFmvdkKRnbvRJ（本地 `build/research/icons-2026-10-30/`），**全部按推荐**：
  D1 自己画一套、一份 SVG 源脚本生成两边（不引入图标库）；D2 只换色块里的功能图标，通用操作照旧用各自系统的；D3 实心 + 镂空；
  D4 mac 进 0.7.0，Windows 在 0.1.0 发布后换（PLAN-v10 §6）；D5 Windows 长截图的预览面板（PLAN-v9 S11）提前做——
  其实 10-29 已经在 windows-next 上做完了（6026ed60，连同 S12 长图标注）；用户 10-30 定 Windows 不分 0.2.0，windows-next 并进 windows、随 windows-v0.1.0 发布，分支已删。
- 做法：源 `icons/feature/kitty.*.svg`（26 个），`icons/build-icons.swift` 把填充、线条、虚线都描成面并合成一条路径（CGPath 的并集），
  出 mac 的自定义符号模板（Template v.3.0，只放 Regular-M，24 格 × 5 = 120 宽，格子中心对着大写高的中线）和 Windows 的
  `FeatureIcons.cs`（24 格坐标的 XAML 路径数据）。App 里 `HotKeyAction.symbol`、`SettingsPage.symbol` 改成 `kitty.*`，
  符号名照旧一路是字符串，`Shell/SymbolImage.swift` 一个入口按前缀取。`SymbolImageTests` 守着源文件 / 资源目录 / 代码三边对得上。
- **坑**：设置侧栏的 `List` 里按名字取的资源符号（`Image("kitty.…")`）什么都不画（macOS 27 屏外实测，同一个 List 里系统符号和
  `Image(nsImage:)` 都正常），所以 `KindTile` 画自画符号走配好字号的 NSImage（`SymbolImage.sized`）。
- 手测 `HANDTEST.md`「功能图标手测」。

### 提醒（2026-11-04 立项）

- 用户 2026-11-04：「想添加一个定时提醒的功能，提醒的方式有轻提醒和全屏提醒，你也可以再加几种」，问放新模块还是状态屏。
  拍板页 https://claude.ai/artifact/Wgahjd1V2kbhN8BriU5fCm（40 项，A 定位 / B 时间 / C 方式 / D 入口 / E 数据 / F 示例），
  用户说「先做提醒」（模块化总路线往后放），**按推荐开工**。对标 Due（没点完成就催）、Time Out / Stretchly（全屏休息、推迟、
  空闲算休息过、严格模式）、LookAway（录屏 / 开会时暂停、离开重置）；对标只写在这里和注释里。
- 定位（A1–A6）：**新开一族「提醒」，第十个功能开关（默认开）**，状态屏不动——状态屏的根是拦键鼠，全屏提醒要能点按钮；
  全屏借状态屏的画面，强制休息用「进入状态屏」。家族色是自定义的琥珀（系统色用完了、红是危险色）。只做 mac，在检出
  `kitty-tools-macos-reminder`（分支 `reminder-wip`，从 macos `c4c0b7d4`）分三批做，评审后并回 macos。
- 时间（B1–B5）：一次 / 每周（每天、工作日 = 周一到周五不认调休、自己勾）/ 每月（没有这天在最后一天）/ 间隔（勾的日子、时段里每隔
  N 分钟）；按当地钟表时间；间隔碰上锁屏、醒来、5 分钟没碰键鼠算休息过、回来重新数；晚 5 分钟以内照常响，更晚的合成一条「错过了
  N 个提醒」，间隔类不补；几条同时到点合成一条。改了每周 / 每月的时间从改的那一刻重新算（`ReminderState.Mark` 连着记规则）。
- 方式（C1–C13）：轻提醒（刘海岛挂着直到「知道了」「稍后」/ × / 上滑，`Island.pin`）、边框、全屏（不拦键鼠、可设 20 秒自己收、
  出现后 1 秒内的按键点击不算）、进入状态屏（进不去退成全屏）；声音（无 / 提示音 / 朗读标题，只响一声）、催促（默认关，第 3 次换全屏）；
  录屏录音时全屏和边框降成轻提醒、状态屏里排着。
- 入口和数据（D1–E3）：设置 › 提醒（列表 + 详情，同状态屏）；启动器一句话建、列表；「新建提醒」快捷键（打开启动器填好「提醒 」）；
  菜单栏子菜单和主界面一格；一次性的点了「知道了」就删。列表存偏好 JSON（`Prefs.reminders`，不注册默认值），跟「设置」一类
  导出导入、按 id 合并；这台电脑的状态 `Prefs.remindersState` 不导出；同步一条一条合。
- **第 1 批（能响起来，2026-11-04）**：模型和收拾、时间计算和单测（`ReminderTests`）、执行层、刘海岛 `pin`、设置 › 提醒、功能开关、
  导出导入。所有方式先按轻提醒出、只放提示音（ponytail，第 2 批换）；侧栏图标先用系统的 `alarm.fill`（第 3 批画 `kitty.reminders`）；
  列表暂不进同步（`SettingsSync.localKeys`，第 3 批）。截图自检 `SnapshotProbeTests/reminders()`，图以 `reminders-` 开头。
- **第 2 批（各种方式，2026-11-04）**：全屏 `Reminders/ReminderScreen.swift`（借状态屏的透出底色、字号、表情和 HUD 底板；
  面板是新的 `ReminderScreenPanel`——状态屏的面板吞掉所有点击，这里按钮要能点，所以是第九个 NSPanel 子类例外；底板上的
  「稍后」是自画的 HUD 胶囊：系统带边框按钮跟着窗口外观画，屏外出图是白的）、边框 `ReminderGlow.swift`（每屏四条贴边窄窗口，
  不开整屏透明窗）、朗读（翻译那边的 `Speaker`）、催促（`Island.nudge` 抖一下 + 再响，第 3 次换全屏）、录屏录音时降级且不出声、
  状态屏里排着（`StatusScreen.onExit` → `ReminderCenter.recheck`）、进入状态屏（`AppDelegate.enterStatus(forReminder:)` 先挑出
  进不去的情况，进不去退成全屏、底板上写原因 + 「去授权」）。全屏统一用透出样式（ponytail：不给每条选告示 / 透出，要了再加字段）。
- **第 3 批（入口和收尾，2026-11-04）**：一句话建提醒的解析 `Reminders/ReminderPhrase.swift`（纯函数：多久之后 / 哪天几点、
  「9点」取最近的将来时刻，「3点15分」不当成 15 分钟后）；启动器「提醒 …」（`LauncherItem.Kind.reminder`：能认出时间的先是
  「建一条」、再是已有的，↩ 打开 / 暂停、⌘↩ 到设置里编辑；单输关键词出补全提示）；全局动作「新建提醒」（`HotKeyAction.reminderNew`，
  加在枚举末尾、不设默认键：打开启动器填好「提醒 」，启动器关着时打开 设置 › 提醒——拍板 D5 原是「不出现」，退一步更有用）；
  菜单栏「提醒」子菜单（下一个、几分钟后提醒我、暂停全部 / 恢复 `ReminderState.pausedUntil`、管理）；主界面和速查表各一处；
  同步 `Reminders/ReminderSync.swift`（`SyncRecords.Kind.reminders`，照状态屏的状态一条一条合）；自画图标 `kitty.reminders`
  （27 个了；Windows 那份 `FeatureIcons.cs` 要在 windows 分支上重新生成）；界面规范 `mac-whisker/reminders.md`。
  手测 `HANDTEST.md`「提醒手测」。
- **2026-11-05 修**：用户报「没开任何提醒，刘海却提示新提醒」——是「+」›「新提醒」点开看了一眼就退回的那条：一点就存进去、开着、
  定在下一个整点，整点真的响了，点了「知道了」又按 D7 自己删掉，列表里找不到。改成先不存，详情页第一次改动才加进列表
  （`Reminder.saving`），没改就离开（退回、换页、关窗）的不留，同系统提醒事项里空着的那行。调度本身没问题（关着的不排不响）。

### 功能管理（2026-11-04 立项）

- 用户 2026-11-04：功能多了「看起来很乱」，「不应该安装应用就有这么多功能，只有几个，用户需要就开启」；又要求「先评估、看业界标准，
  按成熟产品来，不要乱实现」。调研后推翻 2026-10-28 模块化总路线 A 组（藏页面、加 / 移除功能、删数据、启动器里发现）：PowerToys
  0.99（2026-04）新装默认关 7 个小众工具、侧栏分组、老用户设置不动；Raycast 设置里分组、每条命令一个开关、关掉的不进搜索；
  Alfred 剪贴板历史默认关；系统设置侧栏分组留空不写组名。拍板页 https://claude.ai/artifact/YCCBUZtyF9Uc4KsWmc6B21（M1–M9），
  用户「全部按推荐」。在检出 `kitty-tools-macos-modules`（分支 `modules-wip`，从 macos `83f2dda5`）分两批做。
- 第 1 批（M1–M5）：**页面不藏**——关着的功能那一页照样在侧栏，色块变淡、行尾「已关闭」，点进去第一行就是开关（M1）；侧栏分六组、
  组之间留空不写组名（M2，`SettingsPage.groups`）：通用 ｜ 剪贴板、启动器、翻译 ｜ 截图、录制 ｜ 便签、提醒、状态屏 ｜ 启动台、
  程序坞预览 ｜ 快捷键、关于；**顺序全 App 一套**（M3）：侧栏、通用页「功能」、菜单栏、主界面、启动器内置动作、快捷键页、速查表都按
  这个（`HotKeyAction.allSections` 只调节的先后，枚举顺序不动——注册 id 是下标）；**新装只开剪贴板、启动器、翻译、截图**（M4），
  **升级上来的不变**（M5）。做法：`Feature.defaultOn` 全 App 只有一套（程序坞预览之外开），新装（`Prefs.lastSeenVersion` 空）第一次启动在
  注册默认值之前把十个开关明写进偏好（`Feature.seedNewInstall`，只补没存过的）。**不做成「各台默认值不同」**：导出、设置同步里「没有这一项
  = 默认值」，默认值各台不一样的话，导入老电脑的文件、加入同步（第一次合 adopt）时没动过的开关会被悄悄换成这台的默认（评估时推出来的）。
- 2026-11-05 真机试用后用户提议、对标 VS Code（扩展栏底下折叠着的「已停用」）：关着的功能挪进侧栏最底下默认收起的「已关闭（N）」组，行尾不再写「已关闭」；右边内容区本来就变灰（第一行开关 + `gated(by:)`，同 PowerToys）。
- 第 2 批（M6；M7–M9 是「照现在的」：关掉只停用不删数据、总开关留在通用页那一组、启动器不搜关着的功能）：欢迎引导第一屏
  每个功能一个勾选框（就是功能开关、立即生效；新装只勾着那四个），第二屏只列勾上的功能用得着的授权（`OnboardingView.permissions`，
  一项都不要就跳过），第三屏本来就只列开着的功能的键（一行都没有时说去 设置 › 快捷键 设）。
- 不做：藏页面 / 加减功能（侧栏少一页找不回来）、关掉时删数据（数据层不跟开关走，mac-native §1）、一键全开 / 全关、按用途给预设包。

- 2026-11-04 真机反馈（试功能管理测试包时）三条，查了成熟产品后「全部按推荐」：
  - 提示音（对标 Time Out）：系统的 + 个人「声音」文件夹（~/Library/Sounds、/Library/Sounds）里的自动列出 + 菜单末尾「选择文件…」，
    选的文件拷进数据目录 `reminder-sounds/`（20 MB 以内、放得出来才收，同名不同内容加数字），最多放 30 秒、「知道了」「稍后」当场停；
    `Reminder.chime` 存编号（声音名或「file:文件名」），编号跟着提醒导出、同步，文件不跟——别的 Mac 上没有时响「玻璃」、详情页说一句；
    编号是不可信输入，只认一段文件名（`ReminderSound.isValid`）；没提醒用的文件在提醒开始运行时清掉。不从「音乐」资料库选歌。
    长提示音只在用户处理（「知道了」「稍后」、关掉功能）和开始录屏 / 录音时停——进入状态屏、只剩错过的收面板时不停（评审抓到的：
    原来写在收面板里，进入状态屏的提醒到点刚响就被停了）。选文件的面板挂成设置窗上的表单，选好时从现在的那一份改。
  - 没理会时再催：菜单照 Due 的一排 1 / 5 / 10 / 15 / 30 / 60 分钟（原来 5 / 10 / 15）+「自定义…」填 1–120 分钟
    （我原来推荐不加自己填，用户定要加：输入框 + 步进器，存的不是菜单里的数时详情页自然显示自定义）。
  - 侧栏：功能那四组带小标题（文字与搜索、截图与录制、便签与提醒、桌面）、点标题收起 / 展开、记在这台电脑（`Prefs.settingsCollapsedGroups`），
    搜索时全展开、跳到收起的组里的页时自己展开；关着的功能仍不藏（PowerToys 0.86 起导航分组带标题、能折叠；Raycast 关掉的只是不进搜索）。

- 2026-11-04 用户问状态屏、提醒的图标要不要多加、包大小怎么办（量过：16 个动画表情平均 0.36 MB、共 5.9 MB，占 19 MB 的 App 三成；
  HEICS 打进 DMG 几乎压不小）。对标 Apple 提醒事项的清单图标（自带图标 + 任意表情）、Slack 状态（任意表情），用户「按推荐做」：
  ① 图标格子最后一格「其他表情」，挑任意系统表情（静态、0 字节，`StatusEmoji.isCustom`；状态的 JSON 里放在 `emoji` 键，见 mac-whisker
  status-screen.md「动画表情」）；② 动画表情补约 12 个缺的场景（吃饭、运动、通勤、吃药、喝水、学习、专注、庆祝……），约 +4.5 MB，
  下载 Fluent 原文件前先把清单和大小给用户确认；③ 加之前先试抽帧 / 降画质能省多少、顺不顺，量完再定。
  评审后补的：0.7.x 导入新版的导出文件、自动备份时，挑了系统表情的状态 symbol 是空、图标静默丢掉（同便签纸色 tint 的降级，可以接受）；
  系统旧的 Mac 的 Unicode 表没收的新表情，落在 U+1F000–1FAFF 也认，不置空。
  ② ③ 做完（用户同意下载）：Fluent 动画那套只有 700 多个、没有药丸 / 书 / 耳机 / 房子 / 对勾 / 碗，取最接近的 12 个——厨师、跑步、
  汽车、医护、水滴、学生、打坐、礼花、上班、走路、生日蛋糕、点赞（原文件共 21.6 MB，留在 `macos/build/status-emoji/src/`、不进仓库）；
  全部表情改用画质 0.65 重新编码（`status-emoji.swift` 的 `quality`），29 个共 5.5 MB，比原来 17 个的 5.9 MB 小。
- 2026-11-05 用户想「所有图标按 URL 加载、缓存在本地」，用户「按推荐做」：Fluent 动画那套 746 个每个都标着表情字，所以不另做选择器——
  「其他表情」挑到的字有动画版就自动下载、缓存，之后和自带的一样动；没下好、没联网先画系统表情字。对标 Teams、Telegram（动画表情用到时
  从自己的服务器下、存本机）。放在本仓库单独的 release `emoji-pack-1`（2026-11-05 已发：746 个 + LICENSE.txt，目标分支 macos，不标 latest——App 内更新只认 macos-v*，不受影响；发完跑过联网自检 `KITTY_LIVE_EMOJI_PACK`；不从微软的大文件托管直接下：那不是给 App 实时下载用的、
  流量算在他们头上）；746 个原文件 1.6 GB（发布后已删，要重新生成从素材仓库再下，照仓库的 assets/<名字>/ 摆进 src/），转好 155 MB（平均 213 KB）在 `out/`，对照表 18.6 KB 打进包里。
  缓存上限 50 MB、不备份不导出不同步；开关「自动下载动画表情」默认开（设置 › 状态屏「动画」、设置 › 提醒「图标」）；下载时只带表情编号。
  有肤色的只做了默认肤色（挑了别的肤色保持静态，全肤色包要大三倍）。
  2026-11-05 真机试用后用户：系统表情和动画版要分开、两个选择入口（原来挑系统表情时自动换成动画版，想用系统样子的用不了）——
  改成图标格子最后两格「动画表情」（自己的气泡，照系统表情面板排——用户又要求和系统的一致：搜索框 + 6 列大格子从头滚到尾 + 底下一排分类图标 + 「常用」；格子不动，用户「选择后就自动播放动画，不要 hover」：挑上之后详情页的大预览一直放选中的那个，悬停不预览）和「系统表情」（系统面板，
  永远系统样子、不动）；动画表情存「pack:编号」。缩略图 96 × 96 HEIC 共约 3.2 MB 打进包里（Resources/emoji-thumbs/），中文名和搜索
  关键词用 Unicode CLDR 的中文注释（cldr-json 46.0.0 annotations + annotationsDerived 的 zh，约 1 MB，只在生成时用，放 build/emoji-pack/cldr/）。
  发表情包之前在本机试：`defaults write <bundle id> emojiPackTestServer http://127.0.0.1:<端口>`，在 `macos/build/emoji-pack/out/` 起一个静态文件服务器（只认 http 的 127.0.0.1 / localhost），用完 `defaults delete`。

### 新功能标记（2026-11-05 立项）

- 用户 2026-11-05：新版本加了功能，用户可能不知道，能不能在菜单、tab 上加个小圆点提示「这是这个版本的新功能」，参考业界标准。
  调研：Chrome 菜单里新功能后面一个「New」（同一个最多出现 10 次、用过 2 次或 60 天后不再出，Chromium `user_education_features.cc`
  的默认值）；macOS 14 起系统菜单有 `NSMenuItemBadge`，SwiftUI 列表行有 `.badge()`；iOS 主屏新装的 App 名字前一个小圆点、打开一次就没；
  JetBrains、Raycast、Notion、Figma 都是行尾「New」字；macOS 菜单里行首的圆点是「选中 / 混合状态」的记号。拍板页
  https://claude.ai/artifact/PhbiAHxNHBqk4cr9NymKxH（本地 `macos/build/research/new-badge-2026-11-05/decisions.html`，A1–D1 共 13 项），
  用户「全部按推荐」。在 `modules-wip` 上两批做（第 1 批 `1fe82fed` 清单、记账和规则，第 2 批画出来）。
- 样子（A1–A4、C1–C2）：列表写「新」、格子和收起处用小圆点——右键菜单是系统的菜单徽标（`WhatsNew.menuBadge`；子菜单的父项跟着挂，
  只在设置里才有入口的挂在「设置…」上）；主界面格子名字前一个 6 pt 强调色圆点（`NewDot`），底栏「设置」前同样一个；设置侧栏行尾是系统列表的
  `.badge`，字用强调色 `brandInk`（2026-11-06 用户嫌系统的灰不显眼；强调色的选中行上换成 `onBrand`），收起的功能组标题后一个圆点；设置页里新的那一节标题后是强调色描边的小胶囊「新」（`NewTag`）。
  菜单栏图标不挂（那个点是「有新版本」）。颜色只用强调色（红是危险色）。读屏：自己画的读「新功能」，系统徽标系统读。
- 规则（B1–B6，`Shell/WhatsNew.swift` 的纯函数）：清单 `WhatsNew.entries` 每版最多 3 个、只挑有入口的（新的一族、新动作、设置页里新的一节），
  修问题、改样子、没有入口的（启动器汇率）不标；只有升级上来的标（`adopt`：上次打开的版本之后、这一版及以前的都算，跳着升级的中间几版一起），
  新装不标；真用过一次就各处一起没（`run(action)` 一个口子：菜单、主界面、快捷键、启动器；提醒子菜单的快捷提醒也算；拨过它那一节 / 那一行的开关
  `WhatsNew.touch(section:of:)`——看着的时候不闪掉、换页才没，`SettingsNavigation.fresh` + `WhatsNew.shown`；**光打开设置页不算**，2026-11-06
  用户看 0.7.2 测试包后改的）；**升到下一版时上一版和更早的一起没**（`adopting` 里记成 `distantPast`，不删：退回旧版本再升上来不重新挂，同日）；
  一直没碰也没升级的，从这台 Mac 第一次打开那一版起最多挂 30 天；功能关着不标、「已关闭」组
  不汇总；没有开关、没有「全部标为已看」。记账（`Prefs.whatsNewStarted` / `whatsNewTouched`）是这台 Mac 自己的：不注册默认值、不导出不同步。
- 0.8.0 的清单：提醒（菜单「提醒」和「新建提醒…」、主界面「新建提醒」、侧栏「提醒」）、设置 › 通用「功能」那一节（侧栏「通用」、页里那一节、
  菜单「设置…」和主界面「设置」）。发版时挑这一版的写进 `entries`（mac-native §7）；id 发布后别改。
- 和拍板页不一样的一处：A4 说菜单的「设置…」前面一个小圆点，系统菜单里画不了圆点（只能塞进图片），改成同样挂系统徽标「新」。
- 不做：「这一版有什么新」弹窗（更新后不弹窗、不抢前台，A29）、数出现了几次、启动器 / 快捷键页 / 速查表里标、同步「碰过没有」、出现消失的动画、
  TipKit（气泡卡片，挂不到系统菜单上）、Windows 版。截图自检 `SnapshotProbeTests/whatsNew()`（图以 whatsnew- 开头），手测 `HANDTEST.md`「新功能标记手测」。

### 翻译反馈四条（2026-11-05）

- 用户转来四条反馈（截图是 mac 版）：系统词典卡没排版、能不能加更多免费词典（举了 DeepL 的 api-free）、两个喇叭一个读原文一个把整张卡都念了 +
  想要更好的朗读、启动器 / 剪贴板 / 翻译浮窗想改大小。拍板页 https://claude.ai/artifact/QtfothdcHqttF413ZaZJbD（D1–D5 / S1–S6 / R1–R6 /
  W1–W4 / X1），用户「全部按推荐」。在检出 `kitty-tools-macos-translate`（分支 `translate-wip`，从 `b7a55e33`）四批各一个提交。
- 第 1 批词典排版（`13b67633`）：「词典」App 里牛津英汉汉英排在最前时返回的是另一种格式（A. B. 分词性、①② 义项、▸ 例句、中文后带拼音、
  汉译英「词 拼音 英文词性」、繁体跟在词后），`WordLookup.parse` 认出来另走 `bilingualGroups`：词性显示中文名，语域标签和括号说明收成义项后面
  一句淡色小字的注，拼音去掉（D2），‹…› 搭配词、PHRASAL VERB 小节不要（D4）；读音分英 / 美；收起时每条一个例句（D3）。D5 设置里本来就写了
  「把牛津英汉拖到最前」，没再加。单测样本是本机词典的真实返回（探针用私有 `DCSDictionaryCreate` 指定那本词典取原文，只在探针里用）。
- 第 2 批朗读（`8d581e5f`）：卡片右上角的喇叭只读译文（单词卡读第一行释义，`Speaker.speechText`）；单词卡第一行「美 /…/ 英 /…/」换成带小喇叭的
  一行（`Speaker.phoneticLine` + `PronounceButton`，词典卡的读音也有）；英文单词放有道词典的真人录音（`dict.youdao.com/dictvoice`，美 / 英，
  3 秒超时，取不到用系统的美式 / 英式声音），设置 › 翻译「朗读」两行（`Prefs.translateWordRecording` / `translateWordAccent`）。
  **R4（句子用微软在线神经网络语音）没做**：那个接口要冒充 Edge 浏览器的扩展（伪造扩展来源和浏览器标识）才回，违反「只如实标明自己」，
  实测时也被权限拦下；有道的发音接口读长句返回 500。句子照旧系统声音，设置里提示去系统设置下载音质更好的声音。要在线朗读句子可以以后接用户
  自己 AI 服务的语音接口（OpenAI 兼容的 /audio/speech，要 key、按量收费）。
- 第 3 批免费服务（`318a5282`）：DeepL 的 api-free 本来就支持（Auth Key 以 :fx 结尾），没改。新加 `Kind.apple`（系统翻译，26 起；语言没下载时
  配置类错误指去 系统设置 › 通用 › 语言与地区 › 翻译语言）和 `Kind.youdaoDict`（有道词典网页版 `jsonapi`，不签名，只查单词和短语、写成单词卡的样子；
  `Kind.isDictionary`：不是单词不开卡、不当主结果、不进静默替换）。新种类只能加在 `ai` 前面的末尾。导出格式没升（见 `SettingsArchive.currentFormat`
  的注释）。**S3（Google 留空走免费接口）没做**：本机直接请求返回 429 反机器人页。本机没下载翻译语言，系统翻译只验到「提示去下载」。
- 第 4 批面板大小：启动器、剪贴板也能拖左右边改宽（560–1200），三块都能拖下边（`ResizeEdge(.bottom)`，`OverlayPanel.heightRange` /
  `heightDragged`）：启动器、剪贴板定最多几行（6.5–14.5，按半行吸附），翻译浮窗定最高多高（拖过就照它，前三张卡也在卡片区里滚）。宽度记在
  `OverlayPanel.widthKey` 指的偏好里（没写过不动，翻译浮窗以前拖过的宽度照旧在 frameName 里）。六个键都是这台电脑自己的、不注册默认值。
  设置三页「面板大小」一行「恢复默认大小」（`PanelSizeRow`）。剪贴板标题「是否整条显示全」仍按 720 宽算（ponytail：拖窄后个别标题会截断、
  透镜不补，真碰到再把宽度传进去）。
- 不做：选声线、朗读速度、DeepL / 必应 / 火山的免费网页接口、快速记一条和主界面改大小、Windows 版（X1：下一轮写进 windows 的 PLAN）。
  手测 `HANDTEST.md`「翻译反馈手测」。

### 用户四条 + ⌘Tab 预览（2026-11-06）

- 用户提了四条：截图工具条自定义快捷键、快捷键支持连按两下修饰键、程序坞预览悬停一下再弹、长截图选区大了反复「对不上」；做的过程中又加
  第 6 条：⌘Tab 切换时也弹窗口预览、和程序坞预览一致。在检出 `kitty-tools-macos-four`（分支 `four-wip`，从 macos `3d2e04e7`）做。
- **长截图大选区反复对不上**（bug，直接修）：根因不在拼接——离线拿无头 Chrome 渲染的 2880 × 1800 帧和裁成 1400 × 900 的同一串帧比，
  两种大小都接得上八成高的位移、耗时 Release 30 ms 一帧（材料在 `build/research/scroll-large-2026-11-06/`）。是 11-05 改成匀速之后的
  自动滚动不等拼接：速度按「每秒几个选区高」算，两帧之间滚多远 = 速度 × 一轮抓帧、算帧、拼接的时间，而后者跟着选区面积涨（截一张只要
  21–27 ms，算帧 Debug 构建 600 × 400 点 89 ms、整屏 740 ms，整屏的容差拼接 Debug 1.4 s），选区越大两帧之间越容易滚过一整屏 →
  退回、接上、再全速又滚过头。原来一帧一步是闭环的，改匀速后丢了。修法：比上次接上的那一帧最多领先半个选区高（`ScrollCapture.room` /
  `maxLead`），到顶就停发、接上了再滚；领先到顶时一帧没发、画面也没动照样算「到头」（不然滚到底停不下来）。Release 下普通大小的选区
  碰不到这个顶，滚动照旧匀速。手动滚动在 Debug 构建下整屏一轮要两秒多，照样容易对不上，这个只有把算帧、拼接再提速才行（没做）。
- **程序坞预览悬停一下再弹**（直接做）：原来定死 0.2 秒（拍板 B1，同 DockDoor 的默认；DockDoor 设置里能拉 0–2 秒，另有「只有第一次
  弹才等」）。替用户定的：做成设置项（设置 › 程序坞预览「停多久再弹出」，0.2 / 0.4 / 0.7 / 1 秒四档，`Prefs.dockPreviewDelay`，
  注册了默认值、跟着导出走），**默认 0.4 秒**（系统任务栏缩略图的默认也是 0.4 秒；0.2 秒往程序坞点 App 时一路冒预览），只管收着时
  第一次弹，弹着时换图标照旧 80 毫秒就换（同 DockDoor 那个选项打开的样子，不另给开关）；收着时照旧停到一半就列窗口、开始截图。
- **截图工具条快捷键、连按两下修饰键、⌘Tab 预览**（新功能，先拍板）：拍板页 https://claude.ai/artifact/7C2hwjcrdqm3ChjJcN1jor
  （A1–A5 / B1–B8 / C1–C5，源文件在 `build/research/four-2026-11-06-decisions.html`），等用户回复。要点：A 工具栏上的键都能改、
  放在设置 › 快捷键「截图时」一组、标注遮罩跟着改；B 只听不拦的全局修饰键监听（要辅助功能）、每下 ≤ 0.3 秒、两下间隔 ≤ 0.3 秒、
  第二下松开时触发、不分左右、同一个录制框录；C 保留系统切换器、读程序坞进程里切换器的选中（同 DockDoor 的做法，本机 27 上没探过）、
  在它上方弹程序坞预览那块面板，归程序坞预览、默认开。拍板后三批：B → A → C。
- 2026-11-06 用户「全部按推荐」。**第 1 批 连按两下修饰键（B）**：`Shell/ModifierTaps.swift`（纯状态机）+ `HotKeyCenter` 的全局 / 本地
  `flagsChanged` 监听（只听不拦、要辅助功能、授权变了跟着重来）+ 录制框里连按两下就录上；存法是修饰键自己的键位 + 修饰键位 0（不升任何
  格式，旧版本导入 / 同步时丢掉）。规矩在 mac-overlay-panel §4，手测 HANDTEST「用户四条」6–9。
- **第 2 批 截图时的快捷键（A）**：`Screenshot/ShotKeys.swift`（21 个键、默认、固定不改的、查重）；截图框选、标注遮罩都经
  `ShotKey.matching` 认键；设置 › 快捷键「截图时」两组（录制框同一个，`KeyTarget`）+「全部恢复默认」，设置 › 截图 一行跳过去；
  导出文件里记 `shot.<名字>`、同步 `shotkey:<名字>`（不升格式，旧版本忽略）；工具栏悬停提示、HUD 菜单、速查表现写。⇧T 不再等于 T
  （按键比 ⇧，原来单字母键带 ⇧ 也算）。规矩在 mac-overlay-panel §8，手测「用户四条」10–14。
  用户随后问「放在截图时去修改是不是更友好」，我建议设置页留着做总表、截图里加右键改键，用户「做右键改键」：工具栏有快捷键的钮右键 →
  「改「X」的快捷键…」→ 等下一下按键（规矩同设置页），收下就生效；标注遮罩没接。手测「用户四条」22–24。
- **长截图面板四周的黑边**（用户 2026-11-06 看测试包，说「之前其窗口也有这个问题」）：就是 10-19 修过的 macOS 27 玻璃当 key 时圆角外
  画一层淡黑（e0c05c8f），那次只修了 `OverlayPanel`；长截图面板（当 key 收按键）、截图工具栏和尺寸胶囊（在当 key 的截图遮罩里）各自建玻璃、
  漏了。四处都改走 `NSGlassEffectView.clipped(cornerRadius:)`。手测「用户四条」27。
- **⌘Tab 预览在 27 上没生效**（用户 2026-11-06 看测试包）：本机探针（用户按了 ⌘Tab）——切换器列表照旧在程序坞里、选中变化也收得到，
  但**项没有 AXURL**，只有标题（DingTalk、WeChat、WPS Office），第一版只按 URL 配 App 就一直配不上。改成没有 URL 时按标题配（显示名、
  包名、.app 文件名）。探针 `DockPreviewProbeTests/switcher()` 加了打顶层结构、选中项的全部属性名、按着 ⌘ 时谁的窗口在哪一层。
- **截图翻译完再框别处，上次的译文留在「屏幕」上**（用户 2026-11-06，开着「把译文盖回截图上」）：就地翻译把整屏冻结帧换成了贴了
  译文的那张，选区一换，那块译文就像上一张截图贴在屏幕里。改成译文只属于翻的那个选区：选区一变就换回原图、提示一句。手测「用户四条」28。
- **第 3 批 ⌘Tab 预览（C）**：`DockPreview/SwitcherWatcher.swift`（按着 ⌘ 才找系统切换器 `AXProcessSwitcherList`、听它的选中）+
  `DockPreview` 的 `fromSwitcher` 模式（切换器上方居中、不按鼠标收、点一张先发 Esc 收起系统切换器）；设置 › 程序坞预览「按 ⌘Tab 时也显示」
  （`Prefs.dockPreviewCmdTab`，默认开）。**本机 macOS 27 上切换器的辅助功能结构没探过**：要人在场跑 `DockPreviewProbeTests/switcher()`
  （`TEST_RUNNER_KITTY_SWITCHER_PROBE=1`，15 秒内按 ⌘Tab）。规矩在 mac-dock-preview §5½，手测「用户四条」15–19。
- **别的桌面上全屏的 Chrome 多出两张扁卡片**（用户 2026-11-06，带截图和窗口信息）：全表里主窗口 1760 × 868 之外还有两扇没标题的
  1508 × 178、1760 × 166，伸出主窗口上沿、只部分重叠，「整个套在里面才算表单」漏掉了。`DockWindows.merge` 加一条：没标题、宽 ≥ 高 × 4、
  搭在同一 App 一扇更高的窗口上（相交或贴边）的不列。是 Chrome 的哪个控件没认（按形状认）。

### 截图翻译盖回的小字（0.8.0，2026-11-08）

- 用户 2026-11-08 报：开着「截图翻译时把译文直接盖回截图上」，选区小的时候贴回去的译文特别小、看不清（一行中文翻成英文，挤成一行
  3 pt 左右的小字），「你看看市面上成熟的产品是怎么实现优化的」。根因：译文只画在选区那张图里，排不下先缩到 3/4、再往下借空白，
  还放不下就一路缩到 6.5 **像素**（没按屏幕倍率，Retina 上 3.25 pt）；第一行压在原文的基线上，原文上方的空白、右边多出来的空白都不用。
- 调研（只看网页）：Google 镜头 / 翻译（重分行选字号；卡片拖上看全文；显示原文、复制文字）、苹果「翻译」App 相机（放大看；点一块看详情）、
  DeepL（手机盖回 + 一键关盖层 + 原文译文分开看 + 拷贝；桌面版不盖回）、PixPin（图到图 / 图到文字两种模式）、沉浸式翻译（区域翻译把译文
  放在旁边的卡片）、HIG（macOS 最小 10 pt）。都是「图上尽量排，排不下给一个看全文的地方」，没有一家只靠一直缩小。拍板页 9 项
  https://claude.ai/artifact/FzAKP28tPx2xusoQ7ofJuM （源文件 `build/research/overlay-small-text-2026-11-08/decisions.html`），用户「全部按推荐」。
- 做法：A1 字号下限按点算（3/4、不小于 10 pt，原文不到 10 pt 的不缩）；A2 照原文基线排不下时用周围空白（右到邻栏、上下到别的段和已排好的段），
  整块居中、行距 1.25 倍字号；B1 还放不下的段图上留原文，原文和译文交给选区外的译文卡片（B2 只列放不下的段、每段一行原文 + 能选中的译文、
  拷贝译文和 ✕；B3 挂在工具栏另一侧，选区一变 / ✕ / Esc 收；B4 不进出图）；C1 字色不改、C2 不做看原文开关（记进未来计划）。
  规矩在 mac-translate「截图翻译」、mac-whisker capture.md「译文卡片」，手测 HANDTEST「截图翻译盖回的小字」1–23。
- 在检出 `kitty-tools-macos-overlay`（分支 `overlay-wip`，从 macos `15bcac45`）两批各一个提交：第 1 批排版（`ScreenshotOverlay.layout`
  交回 leftovers、`render` 交回 `Outcome`，截图页传每点几个像素），第 2 批卡片和文档。更新日志 0.8.0 发版时一起写（截图翻译一条 fix）。
- 用户随后「多检查几遍，看看还有没有能优化的地方，统一对标成熟产品」：第三个提交是复查修正。一是真截图探针
  （测试工程里临时的 `OverlayProbeTests`，留档在 `build/research/overlay-small-text-2026-11-08/`，用官网的应用截图 + 离线假译文），
  看出往外借空白会排到图标、色点、开关上去字擦花（识字框看不见它们）、字色取到旁边图标的颜色、窄栏里英文词按字母拆开；
  二是不看前面思路的独立复查（随机 3000 个版面叠字 14 次：排好的段按去字外接框、按方向筛障碍会漏掉跨边的；留原文的段会被
  邻段去字擦掉一条）。改成：每个排法都查「译文实际占的地方」（`Span.area`）和别的段原文、已排好译文逐个相交，伸出原文的地方
  原图里得是空的（`isBlank`）；词被拆开算放不下；用空白排的段译文那块另外去字（`Span.cover`）；留原文的段去字时一个像素都不动；
  字色只在原文框里取。单测加了复查复现的两种叠字、400 个随机版面的不变式、图标不被擦、留原文的段不被擦（改坏实测会失败）。
- 第二轮拍板（同一页第 2 版）6 项「全部按推荐」：E1 翻完总挂窄栏（看原文开关、拷全部译文；只有窄栏时不拦 Esc、看着原文
  关窄栏换回译文——这两处是我定的）；F1–F3 识字分段；G1 同时 3 段；H1 随 0.8.0。做的时候评审用真 Vision 实测推翻了 F1–F3
  的原始写法，改成：F1 只去「整行一个字、方、比正文高出三成」的（「Q 搜索设置」这种行首图标字分不出来，没做；单个大写字母
  的框也近乎方，按方不方删会删掉表格列标）；F3 按「宽 ÷ 加权字数」估字号、差三成且字号大的那行框也高才断（行框高度单独
  能差 1.45 倍）；F2 改成看整段（≥3 行、都短、对齐至多一行例外、宽窄差一半以上、没有接着往下说的），两两比分不开行距宽的
  窄栏正文。E1 评审另修了：重翻同一个选区从原图截（以前读的是译文）、失败时旧卡片照旧、马赛克缓存按图认。
- 第二轮做完又用真 Vision 复查了一遍（官网 1x / 2x 设置截图、合成的中英文对）：2 倍图侧栏三行粘着图标字（「合状态屏」「0程序坞预览」
  「8关于」）超出「至多一行例外」拆不开 → 放宽到四分之一的行，并把左对齐一列里往左歪出一个字的行首字去掉、框收回对齐线
  （截图翻译不再把这几个图标擦掉，识字结果里也没有乱字）；「8关于」宽出一截、字号估大四成被当成标题切开（框只高 8%，和设置页
  标题「通用」一样，靠高度分不开）→ 字号大的那行往左多出一个字以上的不拆；i、l 多的英文行接中文行被误拆（28 对里 4 对）→
  字宽按字估、只比同一种字的两行；大号单字（「序」「A」）在截图识字里被删 → 去图标只在截图翻译盖回时做。探针图上另看出
  选中的粉色按钮里的字译文排到按钮外、字色取成粉的（底色按去字范围外面那圈取，那圈已经出了按钮）→ 贴身那一圈八成同色时用它。
- Windows 的盖回（PLAN-v16 S1 / S1b）还没做，windows 分支的 PLAN-v16 补了一句照这次的规则。

### 应用别名（2026-11-09）

- 目标：和 Raycast 的应用别名一样，用自己选的词快速找到应用。入口在 设置 › 启动器 › 应用别名；独立于内置命令和脚本的「命令和别名」页。
- 一个应用可以有多个别名，中英文逗号、分号、换行分隔，保留词内空格。原名、中文名和原来的拼音匹配继续有效；别名也支持大小写 / 全半角折叠、拼音和首字母。完整输入别名时对应应用排在普通结果和无参数脚本前面；同别名的多个应用保持使用习惯排序。带参数的内置命令、脚本仍走原来的模式；文件模式保留「整句匹配应用」的已有行为。
- `Prefs.launcherAppAliases` 保存 JSON（稳定标识 → 输入原文），默认空，随设置导出 / 导入、全局同步。标识优先 bundle id；没有标识才用标准化路径（用户目录缩成 `~`）。同一 bundle id 的副本共享别名，缺席的应用不清配置，重新安装继续用。结果 id / target 不变，收藏、使用记录、打开动作不受影响。
- 每个应用的输入最多 256 字，总 JSON 最多 65,536 字（和设置归档 `.text` 一致）；编辑不自动改写原文，匹配时再解析。搜索索引只在偏好原文或应用目录变化时重建，清空后旧别名不会留在缓存里。应用目录沿用后台扫描，不在每次输入时扫磁盘。
- 验证入口：`AppAliasTests`；屏外截图 `SnapshotProbeTests/appAliases()`（`settings-app-aliases*` / `launcher-app-aliases*`）；真机清单见 HANDTEST「应用别名」。本次开发机只有 Swift 6.0.3 命令行工具，完整 Xcode 构建、单测和界面截图待补。

### 脚本命令（0.8.0，2026-11-07）

- 用户 2026-10-28 问能不能自己写脚本加启动器的命令，当时出了两份拍板页（脚本命令 13 项、模块化总路线 19 项）说先不做；
  2026-11-07「启动器的自定义脚本可以开始做了，随 0.8.0 一起发布……主要看看市面上热门的工具是怎么实现的」，附了一张
  「名称 / 别名 / 启用」三列表的截图。调研八家（Raycast 脚本命令、Alfred Workflow / Script Filter、LaunchBar 动作、macOS 26
  聚焦和快捷指令、uTools、HapiGo、PowerToys Run / 命令面板、Quicker），截图是 HapiGo 设置里的「扩展」页（它没有插件平台）。
  拍板页在原链接上改成 17 项 https://claude.ai/artifact/XXkottuFbfgdudz9UsANFb（源文件在主检出
  `macos/build/research/script-commands-2026-11-07/decisions.html`），用户「全部按推荐」。总路线「脚本命令 → 脚本列表 →
  JS 扩展」这次做前两层，JS 扩展照总路线以后另出拍板页。在检出 `kitty-tools-macos-scripts`（分支 `scripts-wip`，从 macos
  `29c2d080`）分四批做，各一个提交。对标只写在这里和注释里。
- 写法（A1–A3）：一个文件一条命令，开头注释 `@kitty.title`（不写用文件名）/ keyword / icon（emoji、SF 符号、同文件夹的
  图片）/ mode / description / package / argument1–3（占位文字或 JSON）/ confirm / timeout，也认 `@raycast.` 的同名字段
  （fullOutput 是全文，compact / silent / inline 都当岛上一行），注释 `#` `//` `--` 都行；第一行 #! 决定解释器，Kitty 自己
  调（不要可执行权限）；`.template.` 不列，扩展名像脚本却没有 #! 的记原因。默认文件夹在数据目录 `scripts/`，另加的文件夹
  只读、不扫子文件夹（`Prefs.scriptFolders`，不注册默认值）；每次呼出启动器在主线程外重读（ponytail：几百个脚本时改按修改时间）。
- 运行（B3 B4）：工作目录是脚本所在文件夹，标准输入是空的，环境只给 HOME / USER / LOGNAME / SHELL / TMPDIR / LANG + PATH +
  KITTY_SCRIPT_DIR / KITTY_DATA_DIR / KITTY_VERSION；PATH 第一次用时 `$SHELL -l -i` 读一遍记进偏好（`Prefs.scriptShellPath`，
  不注册默认值），3 秒没读到用 /opt/homebrew/bin:/usr/local/bin + 系统目录、这次运行不再试；默认 60 秒超时、岛上「停止」
  （`Subprocess` 的 stopsOnCancel，只停脚本本身，ponytail：它起的子进程可能留着）；输出去颜色码、最多读 1 MB。
- 输出（B1 C2）：island 最后一行 / paste / copy / full（启动器里原地的输出页，↩ 粘贴、⌘C 复制、Esc 返回）/ list（一行
  「标题⇥副标题」或 Script Filter 的 JSON，停手 0.15 s 重跑、杀掉上一次、每次最多 10 s，结果行 Kind `scriptResult`）/ none；
  出错一律岛上红字最后一行。参数（B2）：「别名 / 标题 空格 文字」，必填没填时副标题「输入「tq 空格 城市」」。
- 安全（B5）：拖进设置导入先看全文；带下载标记的脚本第一次跑之前启动器里先给全文（↩ 运行就去掉标记，去不掉的这次运行里记着）；
  写了 confirm 的上膛（危险色）；自己写的、改过的不问。界面上写明「以你的身份运行，能用 Kitty Tools 已有的授权」。
- 「命令」表（C3 C4）：内置 12 个关键词命令 + 14 个系统命令 + 自带脚本 + 我的脚本，每条别名和开关；别名改了旧词不再认，
  只存改过的（`launcherCommandAliases` / `launcherCommandsOff`，注册默认值 ""，跟着设置导出、同步——E1）；内置命令不改各自的
  解析，搜索一开头把别名换回原关键词、原关键词改掉 / 关掉的挡掉（`LauncherCommands.canonical`）；撞词（含网页搜索关键词）描橙框。
- 自带 9 个（D1 D2）：Unix 时间戳 time、JSON 格式化 json、UUID 生成器 uuid、进制转换 bcvt、URL 编码 & 解码 url、Base64 编码 &
  解码 b64、正则表达式测试 regt、切换深色模式 dark、防止睡眠 awake，`Resources/scripts/script-*.sh`（打进包里平铺），只用 zsh 和
  osascript（JavaScript）——python3 / swift 在没装开发者工具的 Mac 上一跑就弹安装框，jq 在 15.0 上有没有没核实。随 App 只读、
  跟着更新，「命令」表里右键「复制一份到我的脚本」（同时关掉自带那条）。flomo、简悦要账号，不自带。搜索菜单栏（D3）另立一项。
- 不做：每个脚本的全局快捷键、定时刷新的 inline、按内容自动出现、只跑一次的本地过滤列表、选中文字交给脚本、脚本商店、
  Windows 版。脚本文件不同步、不进设置导出（E1）；归启动器功能，「脚本命令」开关默认开（E2）。
- **第 1 批**（`7c5ea76e`）：脚本库、运行、启动器里的行、下载脚本先看全文、四种输出；**第 2 批**（`85f478cb`）：参数、全文、
  列表；**第 3 批**（`bda29731`）：「命令」表和脚本设置；**第 4 批**：自带 9 个脚本和收尾。单测 `ScriptCommandTests.swift`
  （解析、真跑临时脚本、读文件夹、启动器、命令表、自带脚本真跑）；截图自检 `SnapshotProbeTests/launcherScripts()`
  （图以 launcher-scripts 和 settings-launcher-scripts / -commands / -script-guide 开头）。待手测 HANDTEST「启动器脚本命令」。
- 2026-11-07 真机反馈三条（测试包「脚本命令」），直接改：① 启动器设置页太长 → 那张表挪进推进去的「命令和别名」页
  （`LauncherCommandsPage`，同网页搜索的详情页），「脚本命令」一节收成几行、查找路径挪进说明页；② 不知道脚本怎么写 →
  加「怎么写脚本」说明页（`Settings/ScriptGuide.swift`：三步、查天气的例子能复制 / 直接新建、字段表、列表格式、运行环境、
  安全和同步），「新建脚本」后岛上说在启动器里输 hello；③ 表里没有汇率换算 → 关键词命令加「汇率换算 汇率」：别名出用法提示，
  关掉后计算器不换算货币、不取汇率表、不出货币候选（算式、单位、进制照算）。
- 2026-11-07 独立评审（一个没看过我结论的 agent 从头审 6 个提交，15 条 + 3 条待确认）后修：「先看一眼」最多显示 256 KB，
  比这还长的写明没显示全、不让在启动器里运行 / 导入（原来只读 64 KB、不说截断）；看全文那一页按住 ↩ 的连发不放行、
  全文没读到不放行、⌘1–9 / ⌘Y 这些不对着后面的行；列表脚本的结果排在普通结果**前面**、不再吞掉普通结果（「time machine」
  照样搜得到时间机器；跑失败了、下面又有真结果时不留错误那行），结果到之前按 ↩ 等到了再执行第一条（原来粘的是上一次的）；
  LANG 拼出系统里没有的（en_CN）退回 en_US.UTF-8；Subprocess 停不掉的 1 秒后补 SIGKILL（交互 zsh 不理 SIGTERM，读 PATH 的
  3 秒超时原来不管用）、输出写到上限 4 倍就停；登录 shell 读 PATH 几个脚本共用一次、不跟着列表撤掉；别名 / 关掉的偏好改成
  64 KB 的 text 类（原来超过 4096 字导入、同步会被删掉），别名存原样（输入框光标不跳）、改成另一条开着的命令自己的关键词时
  原来那条优先；符号链接的脚本也读；读的时候又要读的读完再读一遍；确认过的去掉下载标记后不再记着；复制自带脚本去掉下载标记；
  自带脚本：进制超过 2^63−1 报错、时间戳超过 13 位报错、认 Z 和 +08:00 时区、JSON 有系统 jq 时用它（大整数不丢精度）。
  没改（ponytail）：改了别名后 tx、remind、「本机ip」这类同义词照旧认；关掉 open 连带关掉空格开头的文件搜索。
- **第二轮**（2026-11-07，用户四问：给 AI 的开发规范、图标能不能用图片地址 / 网址、我的脚本要排最前、对照业界标准）：
  拍板页 https://claude.ai/artifact/MQm71TJZzcANmCNniBoa8i（源文件在主检出
  `macos/build/research/script-commands-round2-2026-11-07/decisions.html`），用户「全部按推荐。在 Kitty 里直接让 AI 写我的意思
  就是一份给 AI 的写法说明，不是让 AI 写」——所以 A1 从「启动器里原地让 AI 写」改成**只给一份写法说明**（Kitty 不调模型），
  D2 的「用 AI 写脚本」换成「复制脚本写法说明（给 AI）」。三批各一个提交：
  - 第 1 批（`7b3198f9`，A1 A2 D2）：`Launcher/ScriptAIGuide.swift`（中文 Markdown：格式、字段、六种结果方式、列表、环境、硬规矩、
    例子，最后一段留给用户写想做什么）；设置「脚本命令」加「让 AI 来写」（复制写法说明、从剪贴板新建——去 ``` 围栏、要 #! 开头、
    按关键词起名、先看全文再存）；启动器两条内置动作「新建脚本」「复制脚本写法说明（给 AI）」。
  - 第 2 批（`f8519ba7`，B1 B2 C1）：`@kitty.icon` 能写 https 网址（下载一次、10 秒、≤1 MB、必须是图片，按网址 SHA-256 存进
    数据目录 `script-icons/`，以后只读缓存；http 不认；ponytail：缓存不清理）、`@kitty.iconDark`；读不出来 / 下不下来的原因在
    「命令和别名」那一行橙字（`Launcher/ScriptIcons.swift`）。「命令和别名」我的脚本 → 自带脚本 → 关键词命令 → 系统命令、
    组里按名字排，上面「全部 / 我的脚本 / 自带脚本 / 内置」和「只看开着的」。
  - 第 3 批（D1 D3 D4）：脚本行 ⌘K 接在「打开」后面加「编辑脚本 ⌘E」「改别名…」（打开设置的「命令和别名」只列这一条、别名框
    拿焦点，`SettingsNavigation.focusedCommand`）、「关掉这条命令」（启动器留着重搜，岛上「撤销」）；自带的没有「编辑脚本」，
    ⌘E 是「复制一份到我的脚本」（同时关掉自带那条；包里那份不在原地改）；出错的岛上带「看输出」（叫出启动器原地显示这次的
    输出 + 错误输出，同全文页；只留最近一次，自己停的、没输出的不带；启动器功能关着不叫）；编辑用脚本文件的默认 App，但它
    得在「能开纯文本」的 App 名单里（白名单：终端、Python Launcher 这类一开就跑的都不在），否则退回纯文本编辑器，说明页写了怎么换。
  - 第二轮独立评审（一个没看过我结论的 agent 审三批，12 条）后修：「看输出」先叫出启动器再换上输出页（收起超过 60 秒呼出会清查询、
    顺手关掉输出页）、换之前停掉正在跑的全文脚本；**下载来、没看过的脚本不碰网址图标和脚本文件夹外的图**（扫描时去掉，
    `ScriptCommand.dropUntrustedIcons`：网址能当信标，别处的图会弹文件夹授权框）；网址图标改成 ephemeral 会话、整次 10 秒
    （`timeoutIntervalForResource`）、`bytes(from:)` 边收边数超过 1 MB 就停、跳到 http 的不要；读到的图在主线程外解成 96 像素的
    小图再画（1 MB 的 PNG 可以是几万像素见方）；本地图标跟着符号链接看真文件、只读普通文件、最多读上限 + 1 字节；编辑器从
    终端黑名单改成白名单；「撤销」在启动器收起时不重搜；「改别名…」按 id 只列那一行（原来按名字搜，复制出来同名的也跟着出来）；
    速查表补 ⌘E。
  - 空状态（用户问要不要在脚本文件夹里放示例脚本；推荐不放——放进去就是一条真命令，新用户还得自己删，同类产品也只给模板
    和例子库）：一个自己的脚本都没有时，「脚本命令」和「命令和别名」的「我的脚本」组各一行「还没有自己的脚本」带「用例子新建」
    （查天气，`ScriptLibrary.newExample`，说明页的「用它新建」同一个）。
  - 设置收紧（用户：网页搜索与快捷链接也做成进入详情编辑、通用的「功能」占满了右边，「两个都改」）：启动器页「网页搜索」一节
    只留一行，列表进 `Settings/WebSearchPage.swift`（编辑页从它再推进一层）；通用页「功能」只留一行，开关进
    `Settings/FeaturesPage.swift`，通用页的页头挪进自己的 NavigationStack。规矩写进 mac-whisker settings「一页里列不完的一组
    东西收成一行推进去」。
  - 默认别名统一英文（2026-11-08 用户：「为什么这两个是中文，不应该统一英文吗」）：「命令」表里新建提醒的默认别名 提醒 → remind、
    汇率换算 汇率 → currency（都是原来就认的词，不用切输入法）；中文和 tx、huilv 照旧认。提醒的用法提示写打的那个词，表里改了
    别名时例子里的关键词也跟着换（`LauncherCommands.relabel` 换「「关键词 」」）。
- **第三轮评审**（2026-11-08，用户「多检查几遍，然后看看有没有还能优化的地方，统一对标成熟产品」）：三路独立审查（正确性 /
  安全 / 界面，各一个没看过我结论的 agent）合起来 37 处，全部修了，三个提交：
  - 安全（`42b2244e`）：双向文字控制符（U+202A–202E、2066–2069、200E、200F、061C）能把一段命令显示成注释——看全文那一页
    和导入表单把它们标成「⟦U+2067⟧」、有就不放行（`ScriptCommand.revealed`、`ScriptReading`）；读下载标记跟着符号链接看
    两头、去标记两头都去；导入存的是看的时候读到的字节（`ScriptLibrary.save(Data)`，删掉 `importScript`：原来会把链接原样
    复制、预览开着时文件能被换掉）；没看过的下载脚本不靠别名抢第一行、全文显示出来 1 秒内的 ↩ 不算（`reviewDwell`）；没看过
    的下载脚本子文件夹里的、本身是链接的图标也不用；扫描之后才换成下载来的，跑之前（主线程外）再看一眼标记、不跑。
  - 正确性（`39201035`）：列表脚本写 confirm 解析成读不成的原因（打字就跑，确认不了）；已经在传参数的行 ⇥ 不补全；列表重跑时
    ⌘C / ⌘↩ / ⌘N 不对着旧结果；列表超时说真用的秒数；自带进制、时间戳加 `setopt extended_glob`（非交互 zsh 默认不开）；
    折叠后变长的标题（ß）按原样输入切参数；输出页 ↩ 挡连发；启动器关着时「看输出」不留过期页；读 PATH 时被撤掉的列表不起进程；
    **全文脚本跑着时启动器收起了接着跑**（岛上「正在运行」带「停止」，跑完说一声带「看输出」；`lastFailure` 改名 `lastOutput`）；
    「还在运行」那座岛也带「停止」；去颜色码前先看有没有 ESC / 回车。对标时补上参数 JSON 的 `percentEncoded`
    （社区库 110 个脚本这么写；`ScriptCommand.passed`，RFC 3986 unreserved 以外都编码）。
  - 界面：报错用红字（systemRed，不取 `Style.danger`）、看不全 / 藏着字符 / 输出截断是橙字；看全文 / 输出那一页 ↑↓ 滚一小段、
    PageUp / PageDown 滚一屏（`LauncherModel.PageScroll`），读屏名「脚本全文」「脚本输出」；「运行」在不能放行时禁用、
    「先填参数」不画成主按钮；Esc 键帽大写；「命令和别名」页脚写实际的优先级、开关 mini、
    名字悬停提示「在访达中显示」并给读屏动作；`SettingsPushRow` 的 › 同可排序列表（`chevron.forward` tertiary）；设置侧栏
    搜脚本 / 别名 / AI 能到启动器页；导入表单主按钮 `BrandButtonStyle`、第一行不是 #! 的不让导入、加「选择文件…」；两处
    「查天气」例子合成一份（`ScriptLibrary.example`，写法说明直接引用；`curl -sS --max-time 10`、出错写 stderr）；速查表补
    全文 / 输出页的 ↩ ↑↓ Esc；Base64 换不带字的符号；功能全关时「N 个功能都关着」。
  - 复查（一个没看过改法的 agent 审这三个提交，修在第四个提交里）：只拦双向控制符不够——零宽字（200B、2060、FEFF、00AD、标签字符）、
    单独的回车、换行类字符（2028、2029、0085、\v、\f）、NUL 放在 # 前面，# 就不在词首、不算注释，显示出来却像注释（zsh、bash
    实跑过）：改成 `ScriptCommand.hidden` 按类别判断（默认可忽略、控制、格式、换行类拦；\r\n、emoji 里的 ZWJ 和变体选择符不拦；
    不换行空格、全角空格只标出来不拦），不是 UTF-8 的字节也不放行；下载来没看过的「关键词 空格 参数」那一行也不排最前；
    导入 `.template.` 的模板说清楚要填值改名才列出来、点开头的去掉点；「命令和别名」页脚写准（只打这个词时脚本排第一，接了空格
    和文字时内置命令先认）；看全文那 1 秒里「运行」画成禁用（`ScriptReview.isSettled`）；导入后岛上那句按能不能跑说。
  - 没改（设计层面，记在这里）：信任只认下载标记——git clone、curl、Homebrew 拿到的脚本没有标记、不先看全文；同一个用户下的
    别的程序能往脚本文件夹放脚本、借 Kitty 的授权（「以你的身份运行」这个拍板本身的代价）；看全文只覆盖这一个文件，`source`
    进来的同目录文件看不到。符号链接的脚本工作目录、相对图标按链接所在的文件夹算（不按真文件）。
  - 对标（Raycast 脚本命令官方说明、Alfred Script Filter、社区脚本库计数）后的差距出了第三轮拍板页 https://claude.ai/artifact/3JNjBqx61xWRT4nrwoWA3S（源文件在主检出
    `macos/build/research/script-commands-round3-2026-11-08/decisions.html`）：全文边跑边显示 / 颜色 / ⌘R，列表 url、path、
    icon、autocomplete、text.copy、只跑一次自己过滤，下拉 / 引号 / 密码参数，每条命令的快捷键，新建表单。
- **第三轮对标**（2026-11-08，用户「全部按推荐」：11 项按推荐答案做，四批各一个提交，在 `scripts-wip`）：
  - 第 1 批 全文那一页（A1–A3）：**边跑边显示**——`Subprocess.run(live:)` 给了就把错误输出并进标准输出（同一个句柄，先后
    同终端；结果的 error 是空的，出错那一句从输出的最后一行取），每 0.25 秒（和看输出大小的那一轮一起）交一次写到现在的，
    末尾写到一半的 UTF-8 字先不交（不闪「�」）；页上正文原来停在底部就跟到新的底部、往上翻了不跟（`ScriptPageView.follows`），
    小字「正在运行… 已 12 秒」（`TimelineView` 一秒一次的普通文字）。**认终端颜色**——`Launcher/ScriptTerminal.swift`（纯函数）：
    SGR 的 16 色用系统色（黑白换成文字主次色、浅色里黄压暗）、256 色、24 位、背景（淡 0.25）、粗体 / 斜体（`inlinePresentationIntent`）、
    暗、下划线、删除线；冒号子参数的写法整段去掉不认。单独的回车同终端回到行首、后面写的盖掉这一行（`ScriptCommand.carriageReturns`，
    `clean` 也改成这样：进度条只留最后一帧，岛上一行、列表行、粘贴的都跟着）。页上只排前 10 万字（`LauncherModel.outputDisplayLimit`
    挪到模型里，`ScriptOutput.show` 一次算好纯文字和带颜色的）。**⌘R 重跑**——全文那一页和「看输出」打开的那一页都能，用同样的
    参数（`ScriptOutput.arguments`）、按脚本现在的样子（改完再跑一次），结果都在这一页上看（不是全文模式的也一样）；还在跑、写了
    confirm 的（重跑不该绕过「按两次」）不跑，脚本不在了岛上说一声；底栏「重跑 ⌘R」，速查表补一行。`runScript` 多一个 live 参数。
    ponytail：边跑边看每次从头读临时文件（最多 1 MB，一秒 4 遍），慢了再只读新增的。
    评审（一个没看过改法的 agent，7 处，修在单独一个提交）：⌘R 重跑的粘贴 / 复制脚本跑着时启动器收起了，按它自己的模式交、会把
    结果粘进前台 App——收起后一律按全文交（岛上「看输出」）；`clean` 改成回车盖行后，只拿 \r 分行的输出（AppleScript 的
    `return`、这样分行的 JSON）只剩最后一行——没有别的换行时 \r 当换行，\r 后面只跟着颜色码的不盖（\r\e[K 清行再写照盖）；
    显示截断按收拾前的字数算、提示按收拾后的算——先收回车再截、`ScriptOutput.isCut` 记截没截；截在控制码中间显示出参数——
    `ScriptTerminal.droppingPartialEscape`；**每 0.25 秒把 1 MB 全收拾一遍、排 10 万字，主线程跟不上**——跑着时只排最后
    2 万字（`showLive`、`liveDisplayLimit`，从一行开头起）、纯文字跑完再算；进程结束后还交出一个空的——睡醒先看撤没撤；
    按住 ⌘R 连发——不算连发。没改：错误输出并进来后和标准输出共用 1 MB（写在错误输出里的进度条也占），ponytail。
  - 第 2 批 列表结果（B1–B3）：JSON 每条多认 `url`（有协议的；`file:` 当文件）、`path`（~ 展开、相对的按脚本文件夹算；社区写法
    `type: file` 的 arg 也当路径）→ ↩ 打开（不记使用），网址行 ⌘↩ / ⌘C 复制网址，文件行 ⌘↩ 在访达中显示、⌘Y 快速查看、⌘C 复制路径、
    ⌘K 多「快速查看」；行右侧写「网址」「文件」（拍板写的是「打开」，做出来和底栏左边的种类名重复成两个「打开」，改成种类、↩ 打开写在
    底栏主动作上）。`icon`（字符串同 `@kitty.icon` 但不认网址：一列几十条各下载一次、还能当信标；对象 `{"type": "fileicon", "path"}`
    取那个文件在访达里的图标——新的 `ScriptCommand.Icon.file`，`ScriptIcons.fileIcon` 主线程外取 `effectiveIcon` 画成 96 像素，
    超过 300 张整批忘掉重取；`{"path"}` 是图片），文件结果没写图标时用它自己的图标；`autocomplete`（⇥ 填成「打的关键词 空格 它」，
    普通列表接着重跑）；`text.copy`（⌘C 复制它；⌘↩ 仍复制 ↩ 会用的那个，所以 ⌘K 另列「复制结果」）。**`@kitty.filter`**（只认列表，
    写了就不收参数）：这次呼出里第一次打到「关键词 空格」跑一次（`filterTask`，打字不撤它），结果按标题、说明、拼音全拼和首字母过滤
    （`LauncherModel.filtered`：`LauncherMatch.score` 大于 0 的按分排、同分按脚本给的顺序），收起时清掉；没跑成的那一行不过滤。
    两份写法说明（给 AI 的、设置里的）补上这些字段。
    评审（一个没看过改法的 agent，9 处，修在单独一个提交）：**自己过滤的脚本结果晚到时一律重搜**——眼前已经换成别的查询时选中
    跳回第一行、上膛被撤、另一条列表脚本被重跑：现在只在还在打这条脚本时才重搜（并留住手动选的那一行）；**「还在等结果」不分
    脚本**——一条在跑时别的脚本的行 ↩ / ⌘C / ⌘N 都不认：按脚本分（`isPending`，`listPath`）、⌘↩ 也看；**没跑成的那行一直挡在
    前面**——下面有别的结果时不留它（同普通列表），不再打这条脚本时忘掉、再打到它重跑一次；文件图标并排取，断了的网络盘会
    占满共用线程——排队一张一张取（`fileQueue`）；图标缓存在画图标时清、会清掉正在显示的、图片图标不限——改成在读完时清最早的
    （`settle`，最近 300 张）、读完时已被挤掉的不放；`file:` 网址不展开 ~ 和相对路径、`/` 或 ~ 开头的网址不认、`"path": ""`
    挡住 arg、不能选的行也写「网址」——都修了。没改：网址什么协议都交给系统（同在访达里点链接，要 ↩），评审建议只放 http(s)，
    `raycast://`、`obsidian://` 这类要能开，没收紧。
  - 第 3 批 参数和新建（C1–C3、D2）：**下拉**——参数 JSON 的 `"type": "dropdown"` 带 `data`（title 给人看、value 交给脚本；
    一个选项都没有的当普通文字）：正在打的是它、还没对上某个选项时（`Invocation.typing`，最后一个字是空白算下一个），选项按打的字
    过滤（认拼音）排在脚本那一行前面（`.prompt` 行，目标前缀 `LauncherModel.choicePrefix`，右侧「选项」，主动作「选这个」），
    ↩ / ⇥ 填进搜索框（带空白的括上引号，后面还有参数的接空格）；填的不是选项时那一行写能选什么、↩ 只响提示音
    （`ScriptCommand.invalidChoice`）；交给脚本前换成 value（`passed`，先换再做网址编码）。**引号**——不止一个参数时
    `"…"`、`“…”` 括起来的算一段，最后一段整个括着的去掉引号；一个参数的照旧整段（`split`）。**密码**——`"type": "password"`：
    行上写「•••」、跑之前清空搜索框（全文输出时启动器留着，不清一直看得见）、使用记录按关键词记不按打的字（`record`）、
    打着没跑就收起的也不留到下次呼出；说明页写明打的时候搜索框里看得见。没做真遮挡（拍板的推荐）。**新建表单**——
    `Settings/NewScriptSheet.swift`：名字、关键词、结果给谁（六种）、用什么写（zsh、JavaScript、AppleScript、Python），
    `ScriptLibrary.template` 生成开头几行 + 一段能直接跑的示例（各语言 × 各模式单测里都能读成命令，zsh / JavaScript /
    AppleScript 真跑过），文件名按关键词（没有按名字）、扩展名按语言；设置里的按钮和启动器里的「新建脚本」
    （`SettingsNavigation.showsNewScript`，打开 设置 › 启动器 再盖上）是同一张。删掉原来的固定模板和 `newScriptAndEdit`。
    评审（一个没看过改法的 agent，9 处，修在单独一个提交）：**只有一个参数的下拉，选了带空格的选项填进去括着引号**，一个参数的
    不去引号，对不上选项、↩ 只响——一个参数的不括引号；列表脚本的下拉没对上选项也每打一个字跑一次——不跑；表单挂在启动器页
    那一节上，那一节不在屏上就出不来、标记一直留着——挂到设置窗根上（同速查表），速查表 / 欢迎引导盖着时启动器那条不叠；
    一个选项的标题正好是另一个的 value 时认错——先认一字不差的标题、再不分大小写、最后 value；没配上的引号里打空格就算到下一个
    参数、最后一个参数里有空格就出界——没配上的引号拿走剩下的全部、打到最后一个就一直是它；`""` 填回去变成空的——`quoted("")`
    是 `""`；按住 ⌃ / ⌥ 时的说明连密码一起显示、⌃↩ / ⌥↩ 拿密码去网页 / 访达里搜——打着密码时这两样都没有；看全文后下拉不对
    不响——响；列表模板的提示教人写 confirm（列表写了读不成）——列表的提示换成 `@kitty.filter`。没改：`"a"b` 这种引号在词中间的
    切成两段（和 shell 不一样，少见）。
  - 第 4 批 每条命令的快捷键（D1）：「命令和别名」表多一列「快捷键」（同快捷键页的 `HotKeyRecorder`，`KeyTarget.command`，
    宽 116；规矩同全局动作——要带修饰键、不收通用编辑键、不认连按两下；和全局动作、别的命令两边一起查重；录错 / 注册不上的
    原因写在那一行下面）。存在 `Prefs.launcherCommandHotKeys`（编号 → 组合的 JSON，注册默认值 ""，`.text`，跟着设置导出、同步；
    读的时候 `LauncherModel.commandHotKeys(fromText:)` 按录制框的规矩过一遍、最多 200 条——文件和同步来的是不可信输入）。
    注册在 `HotKeyCenter`（各动作之后注册：撞了的是命令这边失败；热键 id 从 `commandBase` 起；`commandFailures`），
    只注册此刻能做事的（`LauncherModel.canRunHotKey`：启动器功能开着、那条开着、脚本这台 Mac 上有且脚本命令开着、关键词命令
    的功能开着且还有别名、系统命令都在）——别的 Mac 上没有那条脚本就不注册；脚本加了 / 删了（`ScriptLibrary.onChange`）、
    表里开关 / 别名 / 脚本命令总开关变了时 `reloadCommandsIfChanged`。按下（`LauncherModel.runHotKey`）：不要参数、不用确认、
    看过全文的脚本直接跑（不打开启动器，粘贴的粘进眼前的 App；全文输出的打开启动器看）；要参数的、列表的、写了 confirm 的、
    下载来没看过的打开启动器做按 ↩ 的那一步（填好「关键词 空格」/ 上膛 / 先看全文）；关键词命令打开启动器填好「关键词 空格」；
    系统命令要确认的上膛、别的直接做；使用只记总数。设了命令快捷键时启动器的面板在启动时就建好（模型在建面板时接线），没设的不建。
    没做：速查表里不列这些（表本身就是它们的清单）；快捷键不认连按两下修饰键。
    评审（一个没看过改法的 agent，8 处，修在单独一个提交）：**注册会过时**——只有那一页的 onChange 跟，⌘K「关掉这条命令」、
    「启用脚本命令」改了不注销（关掉的脚本的组合还在所有 App 里吞键）：改成 AppDelegate 看着偏好变化调 `reloadCommandsIfChanged`；
    **删掉的脚本、别的 Mac 同步来的组合留在偏好里一直挡着查重**（没有那一行、清不掉）：查重只算这台 Mac 上有的命令
    （`HotKeyCenter.knowsCommand` → `LauncherModel.hasCommand`；偏好里的不删，那台 Mac 还要用）；截图框选、状态屏停热键前只看
    动作的热键，只设了命令快捷键的人截一次图就全没了：看 `HotKeyCenter.isActive`；有一条注册不上时每次都当变了、整个重注册：
    和上次要注册的比（`commandAttempts`）；**热键 id 按排在第几**，重新注册后排着队的事件会落到别的命令上：每条命令这次运行里
    一个固定的号、不复用，只认此刻注册着的；全文脚本的快捷键会停掉眼前在跑的那一页：它自己在跑就交给「还在运行」，别的在跑
    就交给岛；⌘K 菜单开着时按，上膛的那句压在菜单下面、菜单第一项一按就跑：先收起菜单；录屏「显示按键」不显示命令的快捷键：
    补上。没改：超过 200 条时多出来的读不进（按编号排前 200 条，ponytail）。
  不做（拍板页「不做的」）：外部 AI 直接读写脚本（要开本地接口）、官网 llms.txt、AI 写完直接运行、自动加执行权限、调试日志页。

### 访达右键（第十一族，2026-11-08 立项）

- 有人想把「超级右键」（访达右键增强）加进来；11-04 定过留在 Kitty Box（7zz 破零依赖、菜单画在访达里看不出是哪个 App）。
  11-08 重新评估：Kitty Box 一直没发布（同日用户说不开发了），新建文件 / 拷贝路径 / 用 App 打开本来就不需要 7zz。拍板页
  https://claude.ai/artifact/QdgogaSGLrWapmF9BErhaH（源文件在主检出 `macos/build/research/finder-menu-2026-11-08/decisions.html`），
  对标超级右键（iRightMouse）、ToMenu、OpenInTerminal、Menuist、Raycast / Alfred 的文件动作，用户「全部按推荐」。对标只写在这里和注释里。
- 拍板：做子集——访达右键第一层「新建文件 ▸」「拷贝路径」「用 X 打开」（默认只有终端，设置里加），新的一族「访达右键」（默认关，
  引导里能勾，开关是这台电脑自己的、不同步）；不做移到 / 拷到常用文件夹、压缩解压（访达自带 zip；7z / RAR 要 7zz）、显示隐藏文件、
  哈希、文件夹图标，也不做启动器里对访达选中的文件做事（要自动化授权，和启动器「动作面板只放零授权动作」冲突）。菜单平铺在第一层、
  不套子菜单、不加分隔线（macOS 26 上会画成空白行）、不放工具栏按钮。0.8.0 之后的下一版。
- 做法：扩展只画菜单，点了用 App 自己的网址把动作交给常驻的 App（`FinderLink`；带偏好里的凭证，网页打开这个网址什么都不做），
  扩展的沙盒例外只有读 App 偏好一条；App 不在沙盒里，写文件不用一个个文件夹授权。设置页（`Settings/FinderMenuTab.swift`）第一组
  是开关 + 系统里扩展开没开（「去打开…」直接到 系统设置 › 通用 › 登录项与扩展；15.0 / 15.1 系统设置里没有入口，给一条 pluginkit
  命令），第二组是「用 App 打开」的列表。运行中打开开关、系统里还没开扩展时直接弹出系统设置那一页。家族色自定义的石板蓝，
  图标 `kitty.finder.menu`（`icons/feature/`，菜单 + 光标）。
- 实测（11-08，本机临时打开 Gatekeeper，用同样签法的 Kitty Box 扩展）：从网上下载的、不公证的 App 被拦 →「仍要打开」放行 →
  登录项与扩展里打开 → 访达加载扩展，不会再单独弹框。**没验**：App 内更新换掉整个 App 后，系统设置里的开关还在不在。
- 分批（检出 `kitty-tools-macos-finder`，分支 `finder-wip`，从 macos `8bbc2f8d`；0.8.0 发布后 rebase）：
  - 第 1 批：扩展 target、App 收动作（拷贝路径、用 App 打开）、开关和设置页、文档。
  - 第 1 批 `1407f417`：扩展 target、App 收动作（拷贝路径、用 App 打开）、开关和设置页、文档；独立评审后改了：脚本 / 可执行文件 /
    终端配置「用 X 打开」只交给编辑器（终端登记了 .command、.tool、可执行文件和 .terminal，给它就跑）、引导里勾上的走完刘海岛说
    「还要在系统设置里打开」、扩展直接把网址投给包着它的 App（不按 scheme 找：别的 App 能声明同一个 scheme）、空白处 / 选中的
    按菜单种类记在 tag 里分开、网址把 App 冷启动时先存着等起来再做。
  - 第 2 批：新建文件——空白处右键最前面「新建文件 ▸」：自带五种（文本、Markdown、Word、Excel、PPT，模板从 Kitty Box 拿来的，
    自己做的、元数据是空的，`Resources/new-file/`）、数据目录「新建文件模板」文件夹里放的每个文件（扩展为列菜单多一条只读例外）、
    「自定义后缀…」（App 弹框，`Prefs.finderLastSuffix` 记上次的，「以后列在「新建文件」里」默认勾着，已有这个后缀的模板就不放）、
    「打开模板文件夹」；App 拷一份进去、重名加「 2」、日期改成现在。模板文件夹不放例子。独立评审后改了：数据目录、模板文件夹、
    模板本身有一层是替身（符号链接）就不建（不然别的程序读到凭证、把模板文件夹换成指向 ~/Documents 的替身，就能借本 App 的
    文件夹授权 / 完全磁盘访问把受保护的文件拷走）、不往 ~/Library 里建、问后缀的框照 FilePanel 提到 .modalPanel 层（27 上激活常
    被驳回，框会开在访达后面）、扩展点模板时标题对上才建、扩展不再退回按 scheme 投网址（沙盒里直接投给登记了 scheme 的 App
    能行，小程序实测过；退回会被别的 App 截走、还可能做两遍）。没做：建好后选中它并进入改名
    （要控制访达的自动化授权）。Info.plist 里桌面 / 文稿 / 下载的授权说明加了「在访达右键里新建文件」。
  - 真机反馈（11-08，用户装了测试包、菜单出来了）：「拷贝路径」的图标要设计一下 → 自己画了「拷贝路径」「新建文件」两个
    （`icons/finder/`，`build-icons.swift` 加了 finder 出口），子菜单里两项补上系统符号——没图标的项文字会错开一截。
  - 用户：「访达右键的操作功能都要和业界的标准对齐」→ 查了访达和终端自己的做法、Windows、RClick（开源，读源码）、
    OpenInTerminal（读源码）、Raycast Copy Path（读源码）、超级右键、Menuist、New File Menu、Easy New File Creator，
    几家一致而我们不一样的照着改：建好新文件后在访达里选中、按回车进入改名（同访达「新建文件夹」、Windows；做法同 RClick：
    等访达到前台再按，要辅助功能授权，没有就只选中）；「用 X 打开」改叫访达自己的「在“X”中打开」；多选时终端只开第一个、
    编辑器全给（同 OpenInTerminal）；拷贝路径后刘海岛说「已拷贝路径」（同 Raycast、Menuist 拷完有提示）；「新建文件」
    「拷贝路径」在设置里各能单独关（四五家都有）。各家不一致的不动：默认文件名、重名加「 2」、路径不加引号 / 不转义、
    文件夹路径不带结尾的「/」。没做（几家有、算不上必须）：访达工具栏按钮、平铺 / 子菜单切换、关掉菜单图标、建好后打开。
  - 右键扩充（11-08 用户「右键功能丰富一点，参考 GitHub / 业界」）：调研 8 个开源项目（RClick、finder-menu、FinderRight、
    SuperRight 等，大多读了源码）和超级右键、Menuist 等，拍板页 https://claude.ai/artifact/DgkYJzZGMKZkK9NUrxBEy3（源文件主检出
    `macos/build/research/finder-menu-more-2026-11-08/decisions.html`），用户「全部按推荐」：加 11 项、5 项默认开，分三批。
    - 第 1 批：扩展到 App 核对发送方签名（A1；冷启动 / 已在运行时苹果事件里的发送方都是扩展本身，沙盒小程序实测）；每项一个
      开关（`FinderMenu/FinderMenuItem.swift`，A2）；拷贝名称（B1）；移动到 / 复制到 + 常用文件夹（C1，`FileMoves`，系统 mv /
      ditto 另起进程、不覆盖、重名加「 2」、刘海岛进度和停止）；剪切 / 粘贴（C2：记下剪切的、同时放进剪贴板让 ⌥⌘V 也能用，
      剪贴板换过就作废）；发送替身到桌面（C3，默认关）。独立评审后重写了搬文件（会丢数据的两处）：不用 mv（跨卷搬文件夹它另起
      cp、rm 子进程，「停止」停不住，停在 rm 那一步原件和新的都会没）——同一个卷上移动直接改名；跨卷和复制先 ditto 到目标里的
      隐藏临时名，拷完用「已存在就报错」的改名落到正式名字，移动的这时才删原件，停了 / 失败只删临时名；名字在真正动手时才算
      （不分大小写）；「停止」停自己那一批；复制符号链接拷链接本身；剪切的清单只在内存里（偏好只给扩展留几项和 changeCount，
      App 启动时清掉）；常用文件夹不注册默认值、不跟着导出 / 导入走（同截图的存储文件夹）。跨卷移动有按需跑的实测
      （`TEST_RUNNER_KITTY_LIVE_VOLUME=1`，挂一个 20 MB 的磁盘映像）。
    - 第 2 批 `dbf48b7e`：压缩 ▸ ZIP、7Z（D1，`Archives`：系统 tar；zip 名字标 UTF-8（`zip:hdrcharset=UTF-8`，访达和 ditto 打的
      不标）、不带 __MACOSX / ._* / .DS_Store；只选一个包时走 ditto，带着扩展属性；不同文件夹里的同名东西不打；名字太长截短）；
      解压到这里（D2：zip、7z、tar 一族；`ZipNames` 从 Kitty Box 搬来，没标 UTF-8、又不是合法 UTF-8 的名字按 GB18030 解，
      有加密的条目先问密码；先解进隐藏临时文件夹，一样东西放到包旁边、几样改成包的名字；系统 tar 自己会带上隔离标记、
      不解绝对路径和 ..，实测）；修复乱码文件名（D3，`NameRepair`：GBK 被读成 CP437 / MacRoman / CP1252 / Latin-1、UTF-8 被读成
      后三种；扩展里一份逐字一样的判断决定出不出这一项；刘海岛带「撤销」）。共用的几件收进 `FileMoves`（`enqueue` 一条队、
      `land` 不覆盖地改名、`temporary` 临时名记进偏好 `Prefs.finderTemporaries`，退出时没收尾的下次启动删掉）和
      `FinderLink.ask`（弹框）。独立评审后修了：认不出的加密包（前面多一截）无限重解、把队堵死；葡萄牙语 / 法语 / 芬兰语的名字
      被当成乱码（要求至少两个字连着、GBK 这一路字节本身是合法 UTF-8 的不走）；重问密码的框堵住队列；坏包让主线程把整个文件
      读进内存（中央目录最多读 64 MB）；权限 000 的临时文件夹删不掉（先 chmod）；压缩失败报成解压的原因。
    - 第 3 批：显示 / 隐藏 隐藏文件（E1，`FileFlags`：替用户在访达里按 ⇧⌘.，要辅助功能授权，不重启访达；没查实 ⇧⌘. 会不会写进
      `AppleShowAllFiles`，菜单里只有一项切换）；隐藏 / 取消隐藏、隐藏 / 显示扩展名（E2，扩展看选中的现在是什么样决定叫哪个，
      点开头的不出「取消隐藏」）；拷贝哈希 ▸ SHA-256、MD5、SHA-1（E3，`FileHash`：CryptoKit 一块块读，主线程外算——hash 类，
      几个文件按 shasum 的格式一行一个）；彻底删除…（E4：一定先问，列前 5 个名字和总数、写明不进废纸篓，默认按钮是取消，
      根目录 / 第一层系统文件夹 / 主目录 / 卷的根不让删；`rm` 的路径去掉结尾的「/」，免得顺着指向文件夹的替身删到那边）。
      这四项默认关。
    - 真机反馈（11-08）：① 右键菜单出来有延迟——菜单项跨进程交给访达时，`NSWorkspace` 给的文件 / App 图标带着 32 种尺寸整个编过去
      （「终端」图标 72 MB、编一次 40–90 ms，文件夹图标 36 MB，本机实测），一次右键几百 MB；改成先画成 16 pt 小位图（约 10 KB）
      并缓存，App 偏好只开一次、App 位置记着，扩展一起来先把菜单搭一遍（符号字体第一次要 30–60 ms），`47bf9474`。
      ② 图标要彩色：出了三种样子（彩色方块 + 白符号 / 彩色线条 / 彩色实心），用户选 A——每一项是按类上色的方块里一个白色符号
      （mac-whisker settings.md 有规格）。③ 菜单可能太长：设置里加「收进一个子菜单」（`Prefs.finderMenuGrouped`，默认关、照旧平铺），
      打开后第一层只多一项「Kitty Tools ▸」（品牌粉方块里一个白色爪印），我们的项都在它里面。
    - 用户「超级右键多检查几遍、看看还能优化什么」「基础统一对标成熟产品」（11-08）：分三路独立检查（文件操作安全、扩展和交接、
      和成熟产品逐项对照，对照读了 RClick、FinderRight、OpenInTerminal 等的源码）。扩展和交接那一路的修正 `a066b445`
      （投给正在运行的那份 App、问密码先点刘海岛、外接盘也出菜单、退出时清剪切……）。基础对齐一批：做不成时刘海岛说原因
      （原来只响一声）、常用文件夹不在了不替它建回来、桌面上新建不另开窗口、「移动到」里用不上的变灰并接最近选过的 3 个
      （`Prefs.finderRecentFolders`）、设置里两张列表能拖动排序、加 App 时列出装着的常用终端和编辑器（`FinderLink.knownTools`）、
      按住 ⌥ 换「拷贝路径（终端写法）」「拷贝名称（不带扩展名）」、侧边栏右键当空白处、「压缩」改叫「压缩为」（访达自己有一项
      「压缩“X”」）、「显示 / 隐藏 隐藏文件」改叫「切换隐藏文件」。
      文件操作安全那一路实测出来的修了：从分大小写的盘跨卷移动 / 复制时只差大小写的同名会被 ditto 悄悄吞掉一个、原件随后被删
      （拷前查、拷完数，少了不删原件）；`FileManager.moveItem` 不是原子的、跨卷还在主线程上整份拷贝（改用 `renamex_np(RENAME_EXCL)`）；
      锁定文件、带「不许删」ACL 的文件夹（文稿、桌面）拷完落不下、留下删不掉的隐藏垃圾（ditto `--noacl`、先解锁再落、扔临时名
      先清锁和 ACL、删掉了才销账）；文件夹里有命名管道时 ditto 卡死、整条队堵住（拷前查）；进行中的提示 60 秒后收起就停不了
      （每 50 秒再挂）；移动一块盘的根会把它清空（整块盘、系统文件夹、主目录只能复制）；跨卷移动原件没删掉也报「已移到」；
      没下载的 iCloud 包读一下就整个下载、主线程卡住（不读）；启动时清临时名和还在写的 ditto 抢（等半分钟、盘没接上留账）。
      没改、写了 ponytail：tar 打的包不带访达的标签和替身（设置页写明）、解区分大小写的 tar 包会少文件、7z 在启动盘暂存。
      第四轮独立评审（看上面两批新改的）又修了：exFAT 的 U 盘不支持 RENAME_EXCL（报 ENOTSUP，复制、移动、压缩、修复乱码全失败）
      → 这类盘退回「先看在不在再改名」；从 U 盘拷文件夹时 `._` 文件被 ditto 并回扩展属性、两边数不上必报「少了」→ 两边都不数
      `._`；进度提示每 50 秒重挂会盖掉别的提示（只在岛上空着或正挂着它时重挂）；根目录「/」能复制进自己下面；拷完数的那一步
      按停止不管用；粘贴到原文件夹被拒时剪切也作废了；排队时目标文件夹被删会被 ditto 建回来；「不带扩展名」把「Release v1.2」
      截成「Release v1」（只去系统认得的扩展名）；名字长度按字符算（不按字节）。扩展判断变灰改成只比路径字面、不碰文件，
      常用 / 最近文件夹只有主目录第一层的取访达里的名字和图标——扩展在沙盒里看文稿、桌面里面的东西可能让系统替它要授权。
      U 盘有按需跑的实测（`exFATVolume`、`caseClashAcrossVolumes`，`TEST_RUNNER_KITTY_LIVE_VOLUME=1`）。
      之后用户从对照报告里「按推荐」挑了 4 个新功能：解压只压了一个文件的 .gz / .bz2（系统的 gunzip / bunzip2，带上隔离标记；
      RAR 要下载样本来验，先没做）、右键一个文件夹「粘贴 N 项到这个文件夹」、「新建文件 ▸ 从剪贴板新建」（图存 PNG、文字存 .txt，
      App 看剪贴板，扩展不读）、拷贝哈希时剪贴板里原来是同样长的校验值就顺带比一下。没做：子菜单分层、移动后撤销（下一批）、
      登记成系统服务（关不掉，和「功能关掉入口全藏」冲突）。
      第五轮评审修了：连着算几个文件的哈希第二个起误报「不一致」（剪贴板里是本 App 刚写的不比）；末尾补零的 .gz 解好了被当失败删掉；
      废纸篓里的文件夹也出「粘贴到这个文件夹」；大段剪贴板文字比哈希卡主线程；剪贴板 TIFF 转 PNG 丢了 DPI；剪切后「从剪贴板新建」
      说成按 ⌘V（那是复制）；gunzip / bunzip2 的出错原因。顺手：剪贴板里是密码这类标了隐私的不存成文件；图和文字都有时按来源 App
      给的顺序取。
    - 真机反馈（11-08）「打包和解压时没有窗口和进度条，太不友好」：刘海岛那一条加进度条和「42% · 1.2 GB / 2.9 GB」
      （`ByteMeter`；同 App 内更新、转 GIF 的进度条，原地更新、不重新出场）。系统的 tar / ditto / gunzip 不报百分比：压缩、复制
      按读过的字节算（tar -v / ditto -V 报做完的文件，加上正读着的那个大文件读到哪了——libproc 看子进程开着的只读文件的位置），
      解压按压缩包读到第几个字节（zip / 7z 一开始先读包尾的目录，读到过前九成之前比九成大的不算）；一共多大用 find 加 stat 把普通
      文件的大小加起来（du 每个文件往上取整到 512 字节、还算文件夹，小文件多时多算几十倍）。`Subprocess.run` 加了 watch（跑着的
      时候每 0.25 秒给进程号和标准错误新写完的几行）。实测：tar -v 开始一个文件时先写「a 名字」、做完才补换行；同一个卷上 ditto
      是克隆、只报「hardlinked 名字」；du、tar -v 在没有 UTF-8 locale 时把中文名打成「?」「\345…」，要给它们设 LC_ALL；内核报的
      打开方式 FREAD = 1、FWRITE = 2；出错原因只看「tar:」「ditto:」开头的行（-v 的行里有文件名）。第六轮评审查出了这几处。
    - 最早拍板里「不做」的压缩解压、显示隐藏文件、哈希，由这次扩充改成了做；文件夹图标、启动器里对访达选中的文件做事仍不做。
### 截图识别元素（下一版，2026-11-08）

- 用户转来的需求：截图框选时鼠标移到侧栏、工具栏、列表、卡片、按钮上就框出那一块，单击截下；问能不能做、能不能对齐市面上的。
  拍板页 https://claude.ai/artifact/2W5EqQuQohfGTvVdk3fEKz （源文件和探针在主检出 `macos/build/research/shot-element-detect/`），
  15 项，用户「全部按推荐」（同日另问过性能、要不要开关，答复在拍板页 D1 / E1 的思路里）。在检出 `kitty-tools-macos-element`
  （分支 `element-wip`，从 macos `15bcac45`）分两批做；原定 **0.8.0 发布之后**才并回 macos（A2），11-08 用户说「都合并到 macos 并推送」，以合并提交并回。对标只写在这里和注释里。
- 对标（只读网页）：做元素识别的只有 Snipaste、PixPin，都靠系统辅助功能接口，交互一样——Tab 切「只认窗口 / 认元素」、
  滚轮往上大一层；都没有图像兜底，浏览器网页要用户自己打开无障碍。PixPin 默认开、Snipaste 的 Mac 版默认关。iShot（沙盒）、
  CleanShot、Shottr（按像素自动收边）、系统截图都只认到窗口。
- 实测（macOS 27.0.1，探针只读）：App 级按位置查一次中位 0.0–0.3 ms、最慢 13 ms，往上读一串 0.3–2 ms；访达、微信、
  Safari 网页一个点上 4–6 层；Chrome 网页、Electron（Claude、VS Code）、Tauri 网页视图、系统设置右边那页都只有一整块。
  被别的窗口盖着的点上，系统级查询返回的是盖在上面的 App（会查到自家遮罩），App 级查得到被盖着的那个。替 Electron 设
  `AXManualAccessibility` 要几秒才建好、一直开到它退出（VS Code 870 个元素、一个点上 8–10 层），不做（B2）。拍整棵树一扇窗口
  4–188 ms，不拍（B1）。Vision 矩形检测对界面基本全错；自写的分界线检测平的界面能用、复杂背景乱框，不做图像兜底（B3）。
  第 1 批用产品代码再量：第一次问某个 App 27–37 ms（Kitty Tools 自己的 SwiftUI 设置窗 107 ms），同一个进程里之后 0.1–9 ms。
- 做法：冻结时窗口列表多记归哪个进程（`ScreenCapture.Window`、`Shot.owners`）；悬停时 `ElementFinder.query`（App 级命中测试 +
  `AXUIElementCopyMultipleAttributeValues` 一次读种类名 / 位置 / 大小 / 父级，最多 48 层）→ `layers`（裁进窗口和包住指针的
  上层、宽高 < 24 点不算、和窗口差不到 4 点的去掉、相邻差不到 4 点的并成一层留外面的）+ 窗口那层。悬停停在最小那层（C1），
  滚轮 / 双指物理方向往上大一层（C2，`ElementFinder.step`），Tab 切只认窗口（这一次框选），单击选中停着的那层；截图和录屏的
  框选都有，截图翻译 / 识字和 ⌥S 截图翻译没有（C3）；拖框吸附照旧只吸窗口边（C4）。主线程问、一次查询总时限 0.1 s、超了的 App 这次不再问（E1；起初是每个对象 0.1 s，评审指出几十层慢一点就能卡几秒），
  指针还在同一个元素上时只做命中测试（`ElementFinder.Cache`）；不问本 App 自己的窗口（B5）。设置 › 截图「悬停时识别窗口里的
  元素」（`Prefs.screenshotFindsElements`，注册默认值、跟着导出走）拍板 D1 是默认开，同日用户改成**默认关**（「框选时保持屏幕原色和悬停时识别窗口里的元素默认都不打开」；保持原色本来就默认关），没有辅助功能授权时那一行下面出授权行、照旧只认
  窗口、不弹框（D2）。
- 不做：图像兜底、替网页 / Electron 打开辅助功能、元素检测边距、W/A/S/D 挪光标、右键自动标注元素、「不检测」一档、拖框吸到
  元素边。Windows 版用 UI Automation 能做（拍板页最后一节），没出方案。
- 第二轮（同日用户：「识别窗口再优化一下，对照业界的标准，或者 github 开源类似项目」「截图移动到 dock 和顶部菜单的整个区域无法截图」）：
  调研了 ShareX（截图开始时建好整张矩形表，只认 HWND 子窗口）、Greenshot（指针在窗口边上 = 整扇窗口）、macshot（原生 Swift，
  App 级命中后按框往下钻、取面积最小，35 ms / 8 层 / 48 个上限，后台线程只留最新的点）、cindy（核对 AXWindow 和 CG 窗口一致）、
  Thaw（27 上菜单栏图标只能走 AX：各 App 的 `AXExtrasMenuBar`，每个 App 最多 400 ms）、axe-windows（指针停住才查）。做了：
  ① 往下钻（照 macshot，见 mac-overlay-panel §8「往下钻」）：访达列表视图从「滚动区」变成能认到每一行和格，一次 1–8 ms；
  ② 程序坞和菜单栏能整块悬停、单击选中（⌘⇧4 + 空格同样），认元素时程序坞是每个图标、菜单栏是各个菜单和系统图标
  （`ScreenCapture.hoverWindows`、`ElementFinder.dockBar`；第一次读程序坞 42 ms、之后 0.6 ms）；③ 一层的下限 24 → 20 点
  （菜单栏图标高 22）。评审后又改：缓存按进程分开、钻过的只在指针还在最里面那块时用（不然同一个大容器里换一行还给旧的）、往下钻的超时封在一半里、主菜单层级只认 WindowServer 的那一条、菜单栏看不见时不收。没做：AX 挪出主线程（现在有总时限和命中缓存，够用）、第三方菜单栏图标（要挨个问所有 App，第一次几百毫秒）、
  核对 AXWindow、窗口边上 = 整扇窗口、替 Chromium / Electron 临时打开辅助功能（拍板 B2；macshot 是开、结束时只撤自己开的那次）。

**启动器 / 启动台按使用习惯排 App（2026-11-10）**（论坛反馈：「唤出启动台之后输入 s 然后回车，结果启动了 Safari」，想要
Shadowrocket；用户看了建议回「按推荐改」；调研笔记和探针在主检出 `macos/build/research/launcher-app-ranking-2026-11-09/`）
- 原因：启动台搜索不看也不记使用记录；启动器只认一字不差的输入、同一输入的记忆 3 天衰减、选过一次压不过平时用得多的。
- 对标：Alfred 4 周滚动窗口、输入和选中绑定（latching），没记录时看系统的使用日期；Raycast 按次数 + 最近程度，「打过的输入或它的开头」都算。
- 改了五处：① 启动台搜索接 `LauncherUsage.boost`、打开成功记一次（搜着时带输入）；② 输入的开头也算：查询以这次输入开头的记录按一半
  （`LauncherUsage.prefixWeight`，E8「提到固定行前面」仍只认一字不差的 `chose`）；③ 同一输入的时间常数 3 → 28 天，条数上限 512 → 1024；
  ④ 公式里同查询那项 a/(a+2) → a/(a+0.5)（`LauncherMatch.weighted`，文件搜索同一个）：选过一次 +0.67，压过全局最多的 +0.5；
  ⑤ 同分时按系统记的使用（`AppCatalog.systemUse`：Spotlight 的 kMDItemUsedDates 按 28 天衰减求和，扫 App 时顺带读，105 个约 50–90 ms、
  不要授权）再标题短的在前。不做：导入别家启动器学过的记录（界面不能出现别家名字）。Windows 的 2–4 条可原样跟上，⑤ 换 Windows 的来源。

**按 App 停用快捷键（2026-11-10）**（用户转来的反馈：全局快捷键和某些 App 自己的快捷键撞了，想「在这些 App 里不响应、把键让给它」，
mac 和 Windows 都要）。拍板页 https://claude.ai/artifact/FKGz6fNopMTW97NsqeFMqS（7 题，用户「全部按推荐」；对标 PixPin 两级忽略表、
Alfred 的 Related Apps、BetterTouchTool 按 App 停用，调研和测开销的小程序在会话笔记 `hotkey-block/`）。
- 拍板：① 一份 App 名单，每个 App 默认停全部（含启动器命令的快捷键和连按两下），那一行的弹出菜单能改成只停勾的几个全局动作；
  ② 设置 › 快捷键 最下面一节；③ 菜单栏菜单一项「在「某 App」中停用 / 恢复快捷键」（前台是本 App、访达、不是普通 App 时没有）；
  ④ 默认空着，不预置；⑤ Windows 另有「全屏游戏时停用快捷键」（默认开），mac 不做；⑥ 名单跟着设置导出、备份、全局同步走；
  ⑦ mac 一批进 0.8.1，Windows 写成 `windows/PLAN-v17.md`。
- 做法：Carbon 热键把键吞掉、前台 App 收不到（以前实测过），所以名单 App 在前台时**不注册**它停用的那几个（`HotKeyCenter.reload`
  按 `HotKeyBlock.rule` 跳过），按键原样到那个 App；`HotKeyCenter` 看着 `didActivateApplicationNotification`，对新前台的规则和
  上次注册时不同才 `reload`（8 个热键注销 + 注册一轮约 0.27 ms，2026-11-10 本机量）。否掉的：触发时判断再把键合成发回去（要辅助功能授权，
  发出去的键又撞上自己的热键）。连按两下本来就不拦键，`reload` 不给停用的动作挂上就行；录屏倒数的临时 Esc、截图时的键不受名单管。
- 存法：`Prefs.hotKeyBlockedApps`（字符串数组、注册了默认值 []），一条「bundle id」或「bundle id|动作,动作」；不认识的动作名原样留着。
  `HotKeyCenter.isActive` 把「因为停用才没注册」也算上（截图框选、状态屏结束时据此 `reload`）。
- 没做 / ponytail：本 App 的浮层开在名单 App 上面时前台还是它，按快捷键收不回浮层（Esc、点外面照常）；整张名单在同步里算一项，
  两台同时各加一个 App 会丢一个（同剪贴板「不记录」的 App）；切到名单 App 到收到通知之间那几毫秒按下的还归本 App（推断，没测）。

## 11½. Whisker 设计语言改造（2026-09-25 起）

已归档到 `docs/archive/PLAN-12.md` §11½（A–E 各阶段的内容、状态和 2026-09-26 的交接）。现状：A 基础与招牌时刻、B 界面重做、C 品牌、E 截图重设计都已完成（待手测）；D 深度只剩「macOS 26 玻璃 + `.icon`」——玻璃分支第 11 批已写好，等 26 测试机按 `HANDTEST.md`「macOS 26 手测」实测，`.icon` 也等 26。规范正文在 `.claude/skills/mac-whisker/rule.md`（核心）和各 `mac-whisker/<界面>.md`。

## 12. 进度与交接（2026-09-24，新会话从这里接着做）

> 2026-10-03 瘦身：原来的完成记录和整段的「下一步」「暂不发版」「发布」「接手须知」原样挪到 `docs/archive/PLAN-12.md`；**手测清单**（原「待用户手测」那一大段）原样挪到 `HANDTEST.md`，条目和编号不变——代码注释里的「PLAN §12 第 N 条」「§12「录屏 / 录音手测」N」「§12「macOS 26 手测」第 1 条」都去那里按小节名找。新的手测条目加在 `HANDTEST.md` 里。2026-11-01（第四轮体检 W1）起这些旧条目连同「发版冒烟清单」又原样挪进了 `docs/archive/HANDTEST-2026-10.md`（编号不变，上面这些引用和下文的「`HANDTEST.md`「X 手测」N」都去那里找）；`HANDTEST.md` 现在是「真机回归清单」+ 正在验收的那一轮。

> 2026-10-28（第三轮体检第 7 批）：2026-10-22 及更早的进度记录、做完的「已知的小毛病」、旧的「现状」「下一步」原样挪到 `docs/archive/PLAN-batches-2026-10.md` §12；AGENTS.md「项目概述」原来的长段原样挪到本节末尾「各族进度摘要（原 AGENTS 项目概述）」。

**2026-11-10：按 App 停用快捷键**（§10 同名一节）：检出 `kitty-tools-macos-hotkeyblock`（分支 `hotkey-block-wip`，从 macos
`80e01660`）一个提交，写了 0.8.1 的更新日志；没并回 macos、没 push。待手测 HANDTEST「按 App 停用快捷键」1–9。Windows 那一半是
`windows/PLAN-v17.md`（windows 分支）。

**2026-11-10：启动器 / 启动台按使用习惯排 App**（§10 同名一节）：检出 `kitty-tools-macos-ranking`（分支 `ranking-wip`，从 macos
`a15a904e`）一个提交，全量单测过；没并回 macos、没 push、没写更新日志（下一版发版时写）。待手测 HANDTEST「按使用习惯排 App」1–6。

**2026-11-09：0.8.0 已发布**（tag `macos-v0.8.0`，latest；用户先要了测试包、装上试过说「没问题，发布」）：从 macos `a0fec9ef`
（升 0.8.0、写更新日志 24 条、`WhatsNew` 0.8.0 三个：提醒、通用 › 功能、启动器「脚本命令」一节）打的包，dSYM 在 `build/dsym-0.8.0/`；
全量单测 2101 过，`UpdaterTests` 用这次的 zip 过。发布说明照 0.7.3 的格式（这一版没有外部贡献者的新提交，不写「感谢」）。
关于页「未来计划」的四条（片段关键词、粘贴队列、窗口布局、程序坞速览）都还没做，原样留着。上面这些「待手测」照旧没逐条走完。

**2026-11-08：访达右键（第十一族）**（§10「访达右键」）：两张拍板页都「全部按推荐」；检出 `kitty-tools-macos-finder`
（分支 `finder-wip`，从 macos `8bbc2f8d`）做完最早两批、和业界对齐、右键扩充三批（11 项）、六轮独立检查的修正、4 个新功能、
刘海岛进度条；同日用户说「提交并合并到 macos」，以合并提交并进 macos（全量单测过），没 push、没动版本号和更新日志。
用户真机试过一轮没发现问题；待手测 HANDTEST「访达右键手测」1–53。

**2026-11-08：截图翻译盖回的小字（0.8.0）**（§10「截图翻译盖回的小字」）：第一轮 9 项、第二轮 6 项都「全部按推荐」；检出
`kitty-tools-macos-overlay`（分支 `overlay-wip`，从 macos `15bcac45`）第一轮三个提交（排版、卡片、复查）、第二轮三个提交
（E1 窄栏、F1–F3 识字分段连同复查、G1 同时 3 段）；2026-11-08 用户说并，变基到 macos `6449e5f6` 之后快进并回（全量 1987 过），
没 push、没打包、没动版本号和更新日志（0.8.0 发版时写一条 fix）。待手测 HANDTEST「截图翻译盖回的小字」1–23。2026-11-10 用户报有序列表并成一行：「1.」后面没空格认不出记号、
列表后面的正文并进最后一项，修了；同时修了单行的段先缩字（和旁边原字号的列表项大小不一）、1x 截图里按钮周围晕开一圈。
截图页（SelectionView）改得多，`element-wip` 并回时要变基到这之后。
**2026-11-08：截图识别元素（下一版）**（§10「截图识别元素」）：拍板 15 项「全部按推荐」；检出 `kitty-tools-macos-element`
（分支 `element-wip`，从 macos `15bcac45`）两批各一个提交（第 1 批 `8e0ab3c1`），同日第二轮（往下钻、程序坞和菜单栏）一个提交，之后又改成默认关；11-08 用户说「都合并到 macos 并推送」，以合并提交并回 macos 并 push，没动版本号和更新日志，
发版时 `WhatsNew.entries` 可挑「悬停时识别窗口里的元素」。待手测 HANDTEST「截图识别元素」。

**2026-11-07：启动器脚本命令（0.8.0）**（§10「脚本命令」）：拍板 17 项「全部按推荐」；检出 `kitty-tools-macos-scripts`
（分支 `scripts-wip`，从 macos `29c2d080`）四批各一个提交，没 push、没打包、没动版本号和更新日志（0.8.0 发版时一起写，
发版时 `WhatsNew.entries` 可挑「脚本命令」）。待手测 HANDTEST「启动器脚本命令」；并回 macos 等用户说。
同日真机反馈 + 评审修正已并回本地 macos（`776554be`）；第二轮（给 AI 的写法说明、网址 / 深色图标、命令表我的在前、⌘K 管理、
看输出、编辑器）三批 + 独立评审在 `scripts-wip` 做完，待手测 HANDTEST「启动器脚本命令」29–42。
2026-11-08 第三轮评审（三路独立审查 37 处 + 复查 5 处，四个提交）修完，待手测 47–57；对标后的第三轮拍板页用户「全部按推荐」，
四批在 `scripts-wip` 做完（§10「脚本命令」第三轮对标，各批一个提交、各一次独立评审，评审修在单独的提交里），待手测 58–71。

**2026-11-06：用户四条 + ⌘Tab 预览**（§10「用户四条 + ⌘Tab 预览」）：检出 `kitty-tools-macos-four`（分支 `four-wip`）；长截图大选区反复对不上、
程序坞预览悬停时间各一个提交，截图工具条快捷键、连按两下修饰键、⌘Tab 预览先出拍板页等用户回复；没 push、没打包。待手测 HANDTEST「用户四条（2026-11-06）」。

**2026-11-05：翻译反馈四条**（§10「翻译反馈四条」）：词典排版、有道真人发音和卡片朗读、系统翻译和有道词典、三块面板拖边改大小；在 `translate-wip` 四批各一个提交，同日用户说「并回并打包」：已快进并回本地 macos（没 push），测试包 `build/Kitty Tools_0.7.1_翻译反馈_arm64.dmg`；待手测 HANDTEST「翻译反馈手测」。

**2026-11-03：0.7.1 已发布**（tag `macos-v0.7.1`，latest；用户要求推送并发布，从 `d25494a2` 的干净检出打的包（带 DMG 版式），dSYM 在 `build/dsym-0.7.1/`；更新日志日期改成当天；发布说明照 0.7.0 的格式，「从旧版升级」写了中国大陆默认兜底搜索换百度、包变成 12.4 MB。真机回归清单和「第四轮体检手测（0.7.1）」1–78 都没走完，照旧待做）。

**2026-10-30 – 11-01：第四轮体检（0.7.1）**：0.7.0 发布当天用户说「全局检查当前项目整体的所有功能是否还有可以打磨，优化，完善的地方」；本机取证（正式版连跑 4.4 h：footprint 162 MB / 峰值 296、平均 CPU 0.4%、无崩溃报告；编译 0 警告、lint 0）+ 六块只读审查报 96 条，合并成拍板页 https://claude.ai/artifact/7BPsniwYMM7cbvJmpYuCGw（67 项，用户「全部按推荐」；生成脚本、规格 `SPEC.md` 在主检出 `macos/build/research/checkup-4-2026-10-30/`）。在检出 `kitty-tools-macos-checkup4`（分支 `checkup4-wip`，从 `75099259`）里六批各一个提交：第 1 批 `17f7d0d0` 剪贴板与同步、第 2 批 `3b305931` 截图与录制、第 3 批 `402e476a` 翻译与启动器、第 4 批 `d54e1cf8` 便签、第 5 批 `1fde819a` 外壳 / 启动台 / 程序坞预览 / 状态屏（含修稳三条满载偶发的单测）、第 6 批（`26d697f6` 手测清单原样归档 + 本批：文案、真机回归清单、`MARKETING_VERSION` 0.7.1、更新日志、`roadmap.json` 加四项「以后」）。高风险的第 1、4 批各两名评审、第 2、5 批各一名；评审抓到并改掉的重要几处：安全删除用 ON 不用 FAST（FAST 不清长正文的溢出页）、改标注时马赛克「先删后写」会露明文、便签组字中被当空白删掉、导入时被「碰过」的旧文件盖掉新内容。拍板页里选了「做」的新功能 X1–X20 进 0.8.0，每项先出屏外截图；X21–X24 写进 `roadmap.json`。没 push、没并回 macos、没打包。待手测 `HANDTEST.md`「第四轮体检手测（0.7.1）」1–78。

**2026-10-29：主界面（0.7.0）**（§10「主界面」）：拍板「全部按推荐」；在检出 `kitty-tools-macos-home`（分支 `home-wip`，从 main `605f41c8`）
做两批 + 收尾，各一个提交；待手测 HANDTEST「主界面手测」。Windows 那一半等 0.1.0 打完包（`windows/PLAN-v10.md`）。

**2026-10-27–28：第三轮体检**：拍板页 https://claude.ai/artifact/WXzDXTWQDDmbesNDjnPrqr（33 项，用户「全部按推荐」；生成脚本和核实记录在主检出 `macos/build/research/checkup-3-2026-10-27/`）。在检出 `kitty-tools-macos-checkup`（分支 `checkup-wip`）里七批各一个提交：第 1 批 `e910f432` 同步、第 2 批 `e9a4e2a8` 截图历史与晾衣绳、第 3 批 `504e78a6` 外壳、第 4 批 `feb9d6d3` 翻译启动器启动台、第 5 批 `27304ba7` 便签（含拣进来的 `perf-wip` 两个提交 `e19c05c6`、`c6cac5d2`）、第 6 批 `03f47047` 同步提速、第 7 批本批（文档与更新日志：AGENTS「项目概述」压到一屏、原文挪到本节末尾；PLAN 再归档一次；changelog 0.7.0 补上老功能的修复、summary 补全）；中间夹着的 `694e8dcc`、`08d64efc`、`1ec2ca9a` 是 main 上截图历史 / 晾衣绳的提交，不属于体检。第 1–4 批已在 origin/main（`1ec2ca9a`），第 5、6 批和本批没 push；没打包、没发布；待手测 `HANDTEST.md`「第三轮体检手测」1–48（48 是第 7 批补的 B10 第三条）。P7（约 50 MB 的 ColorSync CMYK / Lab 查找表）查明机理、没定位到触发代码、没改，下一步用 MallocStackLogging 取分配栈；B10 三条只写了手测（39、40、48，先确认再修）。`perf-wip` 分支的内容已拣进来，分支可以删了，留给用户决定。

**2026-10-26：晾衣绳（第十族，0.7.0）**（§10「晾衣绳」）：拍板「全部按推荐」；四批在从 main 切出来的
`claude/clothesline-110f0a` 工作树上做完（`758ba482` / `56a5c487` / `21055d34` + 收尾），**没 push、没并回 main、
没动 `MARKETING_VERSION`**（更新日志加在已有的 0.7.0 条目里）。待手测 HANDTEST「晾衣绳手测」1–22；
自动验不了的那几样（手感、挡不挡菜单、点不点得穿、全屏、拖拽落点）在 §10 那一节末尾列着。

**2026-10-26：刘海岛交互（0.7.0）**（§10「刘海岛交互」）：拍板「全部按推荐」；两批在 `island-wip` 做完，同日用户试了
测试包要「主动叫出来」，第三批（点刘海 / 快捷键叫出「那一张」，修窗口改大小的崩溃）也在 `island-wip`；没 push、没并回 main；
待手测 HANDTEST「刘海岛交互手测」1–23。

**2026-10-30：0.7.0 已发布**（tag `macos-v0.7.0`，latest；用户要求发布，从 `936140f8` 的干净检出打的包（带 DMG 版式），dSYM 在 `build/dsym-0.7.0/`；更新日志补齐 10-24 之后的改动、日期改成当天；发布说明照 0.6.0 的格式，「从旧版升级」写了左键开主界面、翻译浮窗默认在屏幕上方、复制即译复制中文也弹、程序坞预览默认关、同步多了几类要每台先更新、截图历史默认开、包变成 12.3 MB。各批手测和发版冒烟清单都没走完，照旧待做）。

**2026-10-24：0.7.0 并进 main**（用户要求，0.6.0 发布之后）：`sync-wip`（程序坞预览三批 + 手测反馈、全局同步第 2–5 批）以合并提交 `c2dca076` 并进 main（main 为第一个父提交，冲突只在 AGENTS / PLAN 的文档），`MARKETING_VERSION` 升到 0.7.0、`changelog.json` 加 0.7.0（照 §10「全局同步」的草稿 + 程序坞预览一句）；全量单测过。没 push、没打包、没发布。待手测 HANDTEST「全局同步手测」1–18、「程序坞预览手测」1–14；`perf-wip`（便签上千条的调优 + 修稳两条偶发失败的单测）2026-10-27 拣进第三轮体检（`checkup-wip`），复查后在第 5 批补了两处：三个视图命中缓存时也要读一下 `notes`（不然同一代里只有第一个读的界面登记上「看着它变」，那叠扇开时改标题标签列不变），搜索的折叠缓存改成按标题、正文比（修订号到顶就不再变）。

**2026-10-24：0.6.0 已发布**（tag `macos-v0.6.0`，latest；用户要求发布，从 `147e54b3` 的干净检出打的包，更新日志日期改成当天；发布说明照 0.5.0 的格式，「从旧版升级」写了启动台只在 macOS 26 起出现、功能开关默认都开、便签同步每台都要先更新、包变成 11.4 MB。启动台手测、功能开关手测、便签四个新功能和同步的手测（`HANDTEST.md` 270–295）、发版冒烟清单都没走完，照旧待做）。0.7.0（程序坞预览 + 全局同步）在 roadmap 检出的 `sync-wip`，接下来并回 main；`perf-wip`（便签上千条的调优 + 修稳两条偶发单测，2026-10-21）还没复查、没进 main。

**2026-10-24：全局同步（0.7.0）**（§10「全局同步」）：拍板「全部按推荐」；第 1 批（挪位置）在 main（0.6.0），第 2–5 批（引擎；片段、收藏、生词本；
搜索、翻译服务、启动器收藏；设置、快捷键、功能开关、状态屏的状态）在 roadmap 检出的 `sync-wip` 上各一个提交，程序坞预览（`dock-wip`）也合进了 `sync-wip`
（0.7.0 一条线，main 保持 0.6.0）；没 push、没打包。待手测 HANDTEST「全局同步手测」1–18；保留天数、「不记录」的 App 这几项继续同步（用户 2026-10-24 定，§10 第 5 批）。

**更早的进度**：2026-10-22 程序坞预览、功能开关，2026-10-19 0.5.0 发布，2026-10-18 任务方框、调优一批、便签第 9 批和第 8 批之后的一轮，2026-10-12 0.4.0 发布（连便签各批的进度），2026-10-10 0.3.2 发布，「现状（2026-10-08）」，启动台的进度，便签的四个新功能的调研，便签条数多时（2026-10-21）——都已原样归档到 `docs/archive/PLAN-batches-2026-10.md` §12。

**还没做的**（从归档的「便签条数多时」（2026-10-21）摘的）：全部便签窗口打开到第一屏 -O 5000 还是 2.6 s、点另一条 / 新建 / 删除 100–140 ms——`sample` 拍下来是 SwiftUI 的 `OutlineList` 一次插 5000 行、逐行问 `ForEach` 要视图，要改得把左栏 `List` 换成自己窗口化的列（界面、拖动排序都跟着动）。

**下一步**（2026-11-01；2026-10-28 那条：0.7.0 发布前走冒烟清单和各节手测，0.7.0 已发布、清单已归档）：0.7.1 已发布（2026-11-03），`HANDTEST.md`「真机回归清单」和「第四轮体检手测（0.7.1）」照旧待走。之后照第四轮体检拍板页做 0.8.0 的新功能 X1–X20（先分批出屏外截图给用户看样子）。

**已知的小毛病和以后的大功能**（2026-10-18 用户：「已知的小毛病都记录下来，后续逐步实现，并且放到设置中，添加一个未来计划的展示区域」）：给用户看的说法在 `KittyTools/Resources/roadmap.json`（设置 › 关于「未来计划」，`improve` 改进在前、`feature` 新功能在后，写法同更新日志：不写代码名、不提别的产品、不写 Markdown 记号）。**做完一条就从那里拿掉、在更新日志里写一条**，加了新的也往那里加，两边别对不上。开发看的位置：
- 改进五条、新功能四条都已做完（roadmap.json 空过一阵）；2026-11-01 第四轮体检把选了「以后」的四项（片段关键词、粘贴队列、窗口布局、程序坞预览速览）写进去，关于页又显示「未来计划」；两条原来的完成记录原样归档到 `docs/archive/PLAN-batches-2026-10.md` §12「已知的小毛病和以后的大功能」。

**各族进度摘要（原 AGENTS 项目概述）**

> 2026-10-28（第三轮体检第 7 批）从 AGENTS.md「## 项目概述」原样挪来，一个字没改，之后不再更新；AGENTS 里现在只留一屏的概述。

**kitty-tools 原生 macOS 版**：用 Swift 6 + SwiftUI / AppKit 重写的纯原生菜单栏工具，替代 Tauri 版的 macOS 端。基本自用：只支持 Apple 芯片（arm64），最低 macOS 15.0。

- **功能**：剪贴板历史、翻译（划词 / 输入 / 复制即译 / 截图翻译，全部翻译服务）、启动器（`Launcher/`，⌥Space 的搜索框）、启动台（`Launchpad/`，第八族，0.6.0，复刻 macOS 15 的全屏图标网格，只在 macOS 26 起出现：分页、搜索、拖动排序、文件夹、抖动删 App、触控板捏合、触发角、导入系统旧布局）、截图（`Screenshot/`：框选、标注、识字、钉图、长截图，长图拼完还能标注（整屏遮罩，同截图那套工具栏）；截图历史把截图 / 长截图 / 录制都收在一处、能回头接着改标注，2026-10-26）；**晾衣绳**（`Screenshot/Clothesline*.swift`，第十族，0.7.0，2026-10-26：截完图挂到屏幕顶上一根绳子上，鼠标停到菜单栏那一条上它就滑下来，和右下角的常驻缩略图二选一；绳子是真的物理（verlet 质点，`ClotheslineRope.swift`），挂上去、摇摆、取下都是它带的；挂的就是截图历史里的那几条，规矩在 `mac-overlay-panel` §14、长相在 `mac-whisker/capture.md`，PLAN §10「晾衣绳」、手测 `HANDTEST.md`「晾衣绳手测」1–22）、录屏与录音（`Screenshot/ScreenRecorder.swift`、`AudioRecorder.swift`）都已做完。程序坞预览（`DockPreview/`，第九族，0.7.0，2026-10-22 立项：鼠标停在程序坞的 App 图标上弹出它所有窗口的缩略图，点一张切过去；拍板页 `macos/build/research/dock-preview-2026-10-22/decisions.html` 全部按推荐，主会话在 `kitty-tools-macos-dock`（分支 `dock-wip`）分批做，第 1–3 批（底层、面板和设置页、内存和规则）和手测反馈做完，2026-10-24 随 0.7.0 并进 main、没发布，规矩在 `mac-dock-preview` + `mac-whisker/dock-preview.md`，PLAN §10「程序坞预览」）。状态屏（`StatusScreen/`：一键把所有屏幕盖上告示、拦住键盘鼠标，状态可自定义；2026-10-10 立项，0.4.0，代码已做完、待真机手测，PLAN §10「状态屏」；告示上的图标是 Microsoft Fluent Emoji 的动画表情，MIT，素材随包）。每个功能都能在 设置 › 通用 › 功能 里整个关掉（2026-10-22，`Shell/Feature.swift`，PLAN §10「功能开关」）。
- **版本**：已发布 0.1.0、0.2.0、0.3.0（录屏录音）、0.3.1（第二轮体检）、0.3.2（设置的导出与导入、每天自动备份、启动器 port、长列表性能和常驻内存）、0.4.0（状态屏和全 App 的视觉对齐）、0.5.0（2026-10-19；便签）、0.6.0（latest，2026-10-24；启动台、功能开关、便签的四个新功能和同步。这几版都是用户要求发布的，真机手测都还没走完，`macos/HANDTEST.md`「状态屏手测」「视觉对齐手测」「便签手测」「启动台手测」「功能开关手测」照旧待做）。**便签**（屏幕边缘的便签，第七族，0.5.0）2026-10-12 立项、2026-10-18 八批全部做完，2026-10-19 随 0.5.0 发布：⌥N 快速记一条、全部便签窗口（便签墙 / 列表）、屏幕边缘那叠、浮动便签；正文是纯文本 + Markdown 显示样式、任务五种状态、文字颜色、行内图片、查找和撤销，能整个或单条导出成 Markdown 再导回，和剪贴板 / 启动器 / 划词翻译打通；便签有单独的库和每日备份、删除留 30 天。代码在 `Notes/`（39 个文件，§4 文件表），拍板和每批摘要看 PLAN §10「便签」（详细记录在 `docs/archive/PLAN-notes.md`），规矩在 mac-overlay-panel §3 §5 §12、mac-whisker-notes、mac-translate §5、mac-clipboard §1；手测 `HANDTEST.md`「便签手测」1–264，发版前先走冒烟清单「便签」15 步（用户试过几轮、报的问题都修了，清单还没逐条打勾）。**启动台**（第八族，0.6.0）2026-10-18 立项，四批、两轮审查和六轮真机反馈都做完，2026-10-19（0.5.0 发布后）并进 main，2026-10-24 随 0.6.0 发布：拍板和做法在 PLAN §10「启动台」，代码在 `Launchpad/`，规矩在 `mac-launchpad` + `mac-whisker/launchpad.md`，手测在 `macos/HANDTEST.md`「启动台手测」1–66（真机都还没走）。**0.7.0**（程序坞预览，第九族；全局同步：设置、快捷键、片段和收藏、生词本、网页搜索、翻译服务、状态屏的状态、启动器收藏都能在几台 Mac 之间同步）2026-10-24 从 `sync-wip` 并进 main、`MARKETING_VERSION` 升到 0.7.0，没发布（2026-10-26 又加了刘海岛交互：提示能悬停展开、带按钮，点刘海 / 快捷键能叫出最近的提示和快捷动作，PLAN §10「刘海岛交互」，手测 `HANDTEST.md`「刘海岛交互手测」1–23）：全局同步的拍板和每批摘要在 PLAN §10「全局同步」，手测 `HANDTEST.md`「全局同步手测」1–18、「程序坞预览手测」。哪些待手测、下一步做什么看 PLAN §12「现状」；手测条目和发版冒烟清单在 `macos/HANDTEST.md`；里程碑 M7–M13、已拍板的 D1–D5 与不迁清单见 PLAN §10。
- Bundle ID `com.yy.kitty-tools.native`（Debug `com.yy.kitty-tools.native.dev`），不再改（改了会丢偏好、钥匙串和授权）；产品名 / .app 名 `Kitty Tools`（Debug `Kitty Tools Dev`，2026-09-26 起，之前叫 Kitty Tools Native）。和 Tauri 旧版同名：安装前先删掉 /Applications 里旧版的 `Kitty Tools.app`。
- **规格**：各 `mac-*` 规则（界面与动效按 `mac-whisker`）+ 对标产品（启动器 Alfred / Raycast、翻译 Bob、截图 iShot / CleanShot、录屏 CleanShot / ⌘⇧5、录音 QuickTime / iShot、剪贴板 Paste）。`macos/PLAN.md` 只留仍有效的：§2 技术栈白名单、§4 架构与文件表、§8 打包、§10 约束与已拍板决定、§11 旧逻辑问题与语言规则、§12 现状与下一步；迁移期历史（§5 的 Tauri 映射、§6 数据迁移等）和已完成批次的实现记录原样归档在 `macos/docs/archive/`（PLAN 原位置写了去处）。
- **Windows 原生版**在 `windows/`（C# + WinUI 3，2026-10-23 立项，第一版剪贴板 / 翻译 / 启动器 / 截图，用户的 agent 分批实现、Claude 审查）：规矩和方案在 `windows/AGENTS.md`、`windows/PLAN.md`。本文件其余部分和 `.claude/` 里的规则只管 `macos/`；Windows 的提交写成 `<type>(win): …`，release 不标 latest。

**发布**：`macos/build-dmg.sh` 出 arm64 DMG 和 `_arm64.zip` → 本仓库 github.com/YyAdnBug/kitty-tools 发**正式 release、标 latest**（App 内更新读 `releases/latest`），两个文件都附上，tag `macos-v<版本>` 打在 `main`；**发布前须经用户确认**。细节见 §8.5、`build-dmg.sh` 头部注释和 AGENTS.md「开发约定」。

**接手须知**：先读 `AGENTS.md`、`.claude/rules/mac-native.md`，改哪块读哪块的技能（mac-overlay-panel / mac-clipboard / mac-translate；界面先读 mac-whisker 核心，再读那个界面的 `mac-whisker/<界面>.md`）。界面改动用 SnapshotProbeTests 屏幕外渲染自检，**不要**为截图弹出浮层（会抢用户键盘）；按需开关（默认都不跑；用法在 AGENTS.md「常用命令」和各测试文件头）：联网冒烟 `TEST_RUNNER_KITTY_LIVE_TRANSLATE=1`、链接预览 `TEST_RUNNER_KITTY_LIVE_LINK=1`、文件搜索 `TEST_RUNNER_KITTY_LIVE_FILES=1`、菜单开着时热键 `TEST_RUNNER_KITTY_LIVE_HOTKEY=1`、应用内更新整条链路 `TEST_RUNNER_KITTY_UPDATE_ZIP=<zip 路径>`、截图自检 `TEST_RUNNER_KITTY_SNAPSHOT_DIR=<目录>`、录屏 / 录音实录 `TEST_RUNNER_KITTY_LIVE_RECORD_DIR=<目录>`、内存探针 `TEST_RUNNER_KITTY_MEMORY_PROBE_DIR=<目录>`。用户要求：只兼容 macOS、不照搬 Tauri 实现、样式与交互可按 macOS 习惯重新设计、照搬行为前先核对旧逻辑有没有 bug（记入 §11）。

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
| 94 | `launcherCalculator.ts:1-30` | 计算器只出十进制、不分组，没有单位换算和进制 | 单位换算（`Measurement`，中英文单位名）、进制、千分位分组，⌘K 复制原始数字 / 别的进制；汇率 D11 没做，2026-11-04 补上（`ExchangeRates`） |
| 95 | `launcher/favicon.rs:1-30` | 网址行的网站图标联网抓取第三方服务 | 不联网：只读本机 Chrome 的 Favicons 库 + 剪贴板链接预览取到的（体检 D6） |
| 96 | `screenshot/export.rs:229,320,349` | 「另存为」存完把目录记成快速保存目录，之后 ⌘S、常驻缩略图的存储、双击打开都改存到那里；设置里选过就回不到系统截屏位置 | 另存为不改快速保存目录（存储面板自己记住上次的文件夹，同 ⌘⇧5 / CleanShot），设置 › 截图「快速保存到」显示文件夹图标 + 名字、能恢复默认（体检 A28） |

## 附录：评审处理记录

已归档到 `docs/archive/PLAN-migration.md`（方案评审的 41 条处理记录，全部采纳）。

## 附录：用户决策记录（2026-09-24）

已归档到 `docs/archive/PLAN-migration.md`（签名、公证、架构、翻译服务这些迁移期的决定，以及 2026-09-28 体检各批、第 9–13 批拍板时的用户原话和范围）。仍有效的已写进规则：Apple Development 签名、Team `HTX9F4KG39`、长期不公证（mac-native §6）；只支持 Apple 芯片（mac-native §2）。
