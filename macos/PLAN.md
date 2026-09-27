# kitty-tools 原生 macOS 分支迁移方案（Phase 1：剪贴板历史 + 翻译）

> 2026-09-27：Tauri 快照已从本分支删除，下文的 `src/`、`src-tauri/` 路径指 master `ee615b3` 上的文件。
> 2026-09-26 起：本文是迁移期的历史方案。原生版不再参考 Tauri：§5 的「照搬 / 一致」只代表当时的实现；行为、界面、默认值、文案以各 mac-* 规则、Whisker 和对标产品为准。旧版导入（§6）已删除，强调色改为品牌粉（D13 作废）。

**基线**
- master 在 `ee615b3`，工作区干净（已核实）。
- 现有 Tauri 版：v0.1.13，`com.yy.kitty-tools`，最低 macOS 13（`src-tauri/tauri.conf.json:5,43`）。
- 开发机：macOS 15.7.7 / Xcode 26.3 / Swift 6.2.4；系统自带 `/usr/bin/jq`（已核实）。
- 本机旧配置（只读了布尔值，没有输出任何密钥）：
  - 启用的翻译服务：智谱内置、百度、1 个 AI 实例（OpenAI 兼容协议）。
  - 有凭据的服务：百度、有道（有凭据但未启用）、这个 AI 实例。智谱没有自填 key，用的是内置 key。
  - 剪贴板设置：保留上限 500 条、保留 7 天；剪贴板、划词、输入翻译三个热键都已设置。

**一句话方案**：建 `macos-native` 分支，放在独立 worktree 里开发。在 `macos/` 下用 Xcode 工程 + Swift 6 + SwiftUI/AppKit 重写，运行时不引入任何第三方依赖，用 `hdiutil` 打 DMG。分支里的 Tauri 代码是 `ee615b3` 的快照，只作行为参考：不改、不删，也不再 merge master。

---

## 0. 需要你拍板的决策点

| # | 决策 | 推荐 | 理由 | 备选 |
|---|---|---|---|---|
| D1 | 分支从哪里建 | 从 master 建 `macos-native`（2026-09-27 改名 `main`，`master` 留给 Tauri 版）；**不 merge master，也不以合回 master 为目标** | 分支里带着 Tauri 代码快照，本方案所有 path:line 引用都指向它。原生版不需要 Tauri 的后续修复，需要看 Tauri 最新行为时，直接读 master 工作区的绝对路径 `/Users/yy/Desktop/yy/Codes/Tauri/kitty-tools/...` | orphan 分支：更干净，但没有参考代码 |
| D2 | 在哪个目录开发 | `git worktree add ../kitty-tools-macos -b macos-native master` | `.cursor/`、`.claude/`、`.agents/` 都在 .gitignore 里（`.gitignore:58-61`）。在同一目录切分支，Tauri 的规则和技能会继续被加载；独立 worktree 自带一套干净的 agent 上下文 | 同目录切分支（规则会混在一起） |
| D3 | 原生工程放哪 | 仓库根目录下的 `macos/` | 和 `src/`、`src-tauri/` 平级，自成一体 | 把 xcodeproj 放根目录（会弄乱根目录） |
| D4 | 规则是否提交进 git | 本分支提交：`.cursor/rules/mac-native.mdc`、`.cursor/rules/ponytail.mdc`（给 Cursor 用），以及各里程碑结束后写的 `.claude/skills/mac-*`。`.gitignore` 只放行这几项 | 规则跟着代码走，删掉 worktree 也不会丢 | 沿用 master 的做法，只存在本机 |
| D5 | Bundle ID | Release 用 `com.yy.kitty-tools.native`，Debug 用 `com.yy.kitty-tools.native.dev`，**以后不再改** | Phase 1–3 期间启动器和截图还得用 Tauri 版，两个 App 一定会在同一台机器上共存。ID 相同会争用 TCC 授权、UserDefaults 域（`~/Library/Preferences/com.yy.kitty-tools.plist` 已被占用）和数据目录。Debug 要避开 Tauri dev 已占用的 `.dev` | 直接接替 `com.yy.kitty-tools`：只有不再共存时才成立。以后再改 ID 会丢设置和授权（2026-09-26：共存期结束，ID 仍不改） |
| D6 | 显示名 | `Kitty Tools Native`（Debug：`Kitty Tools Native Dev`） | 能和 `Kitty Tools.app` 同时放在 /Applications | Tauri mac 版退役后改 `PRODUCT_NAME` 即可，ID 不变 |
| D7 | Developer ID 与公证 | **✅ 已定（2026-09-24）：长期不公证**，只走路径 B（Apple Development 签名，Team `HTX9F4KG39`，证书 2027-06-10 到期） | 没有 Apple Developer Program 付费会员，拿不到 Developer ID。代价：macOS 15 用户第一次安装要去系统设置点「仍要打开」，发布说明固定写上这个步骤（2026-09-27 起之后的版本走 App 内更新，不用再放行，D8） | 将来入会后按 §8.4 补公证 |
| D8 | 应用内更新 | **2026-09-27 改为做**（用户要求）：`App/Updater.swift` 读本仓库 github.com/YyAdnBug/kitty-tools 的 latest release（tag `macos-v*`，和 Tauri 版的仓库无关），下载 `*_arm64.zip` → `ditto` 解到 App 所在卷 → `codesign -R` 校验 bundle id + Apple 签发 + 团队 HTX9F4KG39、核对版本号 → 原子替换正在运行的 .app → 等进程退出后重新打开 | 原来的顾虑「不公证时每次都要手动放行」不成立：App 自己用 URLSession 下载的文件不带隔离标记（实测），只有第一次安装要「仍要打开」；证书不变授权不丢 | 不用 Sparkle（禁止第三方依赖）；解包、验签用系统的 ditto / codesign（Process，进程外），不新增 C API 代码 |
| D9 | 旧 Tauri 数据 | 手动触发的一次性导入，**分两步**：M4 导偏好和密钥；M6 导**保留类**剪贴板条目（收藏、片段、已归组）及其图片、分组，以及**全部**翻译历史。**普通历史和热键不导** | 普通历史只保留 7 天，共存期间原生版自己已经采集到了，导进来只会重复。热键导进来一定和共存的 Tauri 冲突。偏好和密钥提前到 M4，M4/M5 就能直接拿真实配置测 | 连普通历史一起导（差别只是去掉一个 WHERE 条件）；或者从空库开始（2026-09-26：导入已删除） |
| D10 | CPU 架构 | **✅ 已定（2026-09-24）：只支持 Apple 芯片**，`ARCHS = arm64` 写在 Base.xcconfig | 基本自用，Intel 不在目标内；构建更快、包更小 | — |
| D11 | 翻译服务迁多少 | **✅ 已定（2026-09-24）：全部迁移**：智谱内置、百度、有道、Google、DeepL / DeepLX、微软、火山、腾讯，以及 AI 实例的 openai / azure / anthropic 三种协议 | 与 Tauri 版功能对齐。M4 做智谱 + AI 三协议，M5 做其余 7 家（火山、腾讯的手写签名各算 M） | — |
| D12 | 是否新增 Apple Translation 引擎 | Phase 1 不做，功能对齐后作为第一个候选 | 不在迁移范围内。macOS 15 上 `TranslationSession` 只能依附 SwiftUI 视图获取（脱离视图的 init 需要 macOS 26）；语言包下载 sheet 在不激活的浮层里能否工作也没验证 | 放进 M5（优点：离线、不需要密钥） |
| D13 | 主题 | 去掉 `appThemePreset`、`customHue`、`backgroundOpacity`、`transparentBackground`，~~跟随系统强调色~~和系统材质（2026-09-26 作废：强调色固定为品牌粉 `Style.brand` + AccentColor.colorset，材质仍跟随系统） | 符合 HIG，少维护一套主题系统 | 保留 preset（纯 UI 工作，约 S–M） |
| D14 | 开发机是否升级到 macOS 26.6+ | 暂不升级 | 部署目标是 15，剪贴板隐私、NSPanel、热键这些坑都要在 15 上实测。Xcode 27 官方 skills 偏 SwiftUI/iOS；mcpbridge 能做的事直接跑 `xcodebuild` 也能做 | 升级：能用 Apple 官方 agent skills 和 Xcode MCP，但要另备一台 macOS 15 测试机或虚拟机 |
| D15 | 「划词 / 浮窗默认服务」设置 | 删掉。翻译历史和自动复制都取**列表中第一个已启用的服务**，想换就拖动排序 | 原生版所有服务并行翻译，这个设置只剩「决定哪条结果写进历史」一个作用，而 Tauri 的自动复制本来就是取列表首个。删掉后少一个设置，也少一套默认服务修正规则 | 保留下拉，语义改为「写入历史的服务」 |

---

## 1. 分支与仓库布局

```bash
cd /Users/yy/Desktop/yy/Codes/Tauri/kitty-tools
git worktree add ../kitty-tools-macos -b macos-native master
```

```
kitty-tools-macos/                     # worktree，分支 macos-native
├── macos/                             # 本分支唯一的开发区
│   ├── KittyTools.xcodeproj/          # 用 Xcode 模板创建；scheme 勾选 Shared，提交 xcshareddata/
│   ├── KittyTools/                    # 同步文件夹（synchronized folder），增删文件不改 pbxproj
│   │   ├── App/  Shell/  Storage/  Clipboard/  Translate/  Settings/
│   │   └── Resources/                 # Assets.xcassets、changelog.json
│   ├── KittyToolsTests/               # M2 写出第一个纯函数时再建
│   ├── Config/                        # Base/Debug/Release.xcconfig、Secrets.xcconfig(不入库)、Info.plist(局部)
│   ├── build-dmg.sh                   # 只有路径 B
│   ├── brand-icons.swift              # 品牌图标生成（AppIcon + 菜单栏剪影，D1 原创角色「探头」）
│   ├── .swift-format
│   └── PLAN.md                        # 本方案原文，作为 M2–M6 的行为规格
├── .cursor/rules/mac-native.mdc       # 唯一的常驻规则（正文唯一数据源）
├── .cursor/rules/ponytail.mdc         # 从 master 复制，只给 Cursor 用
├── .cursor/mcp.json / .mcp.json       # sosumi
├── .claude/skills/mac-*/              # M1/M3/M4 结束后逐个补：SKILL.md + rule.mdc 符号链接
├── AGENTS.md                          # 正文（原生版）
├── CLAUDE.md                          # 只有 @AGENTS.md 和 @.cursor/rules/mac-native.mdc 两行
└── src/ src-tauri/ html/ public/ …    # Tauri 快照，只作参考，不改不删
```

**Tauri 代码的去留**：在本分支上不改、不删，也不 merge master。
- 本方案的 path:line 引用以分支里的 `ee615b3` 快照为准。
- 需要看 Tauri 的最新行为或旧规则原文，直接读 master 工作区：`/Users/yy/Desktop/yy/Codes/Tauri/kitty-tools/src-tauri/...`、`/Users/yy/Desktop/yy/Codes/Tauri/kitty-tools/.cursor/rules/...`。

**本分支 `.gitignore` 的改动**：
```
# 把原来的 .cursor/ 和 .claude/ 两行改成：
.cursor/*
!.cursor/rules/
!.cursor/mcp.json
.claude/*
!.claude/skills/
.claude/skills/*
!.claude/skills/mac-*/
# 新增：
macos/build/
macos/Config/Secrets.xcconfig
xcuserdata/
```
`.claude/skills/` 下只放行 `mac-*`：用 `npx skills` 安装的社区技能会在这里建指向 `.agents/`（仍被忽略）的符号链接，不能被提交成断链。

---

## 2. Apple 官方技术栈

| 框架 / API | 最低 macOS | 用途 |
|---|---|---|
| Swift 6.2，Swift 6 语言模式；`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`、`SWIFT_APPROACHABLE_CONCURRENCY=YES`（写在 xcconfig，M0 用 `-showBuildSettings` 验证生效） | 工具链 | 严格并发检查，默认跑在主线程 |
| SwiftUI：`App`、`MenuBarExtra(.menu)`、`Form`、`ContentUnavailableView` | 13 / 14 | 菜单栏和全部视图 |
| Observation `@Observable` | 14 | store 和 view model |
| AppKit：`NSPanel`、`NSHostingView`、`NSWindow` + `NSTabViewController(.toolbar)`、`NSTextField`/`NSTextView`、`NSEvent` 监听、`NSWorkspace`、`NSRunningApplication` | 10.x | 不激活前台的浮层、设置窗、兼容输入法的输入框、来源 App、单实例检查 |
| Carbon HIToolbox `RegisterEventHotKey`；`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` | 10.0（26.2 SDK 中未废弃） | 全局热键；录制快捷键时显示键名 |
| ApplicationServices：`AXIsProcessTrustedWithOptions`、`AXUIElement`、`AXUIElementSetMessagingTimeout` | 10.x | 辅助功能授权、读取选中文本 |
| CoreGraphics `CGEvent` | 10.x | 模拟 ⌘V / ⌘C；长截图自动滚动发像素级滚轮事件（`CGWarpMouseCursorPosition` 先把光标挪进选区） |
| `NSPasteboard`（`changeCount`、`accessBehavior`） | 10.0 / 15.4 | 剪贴板采集、剪贴板隐私状态 |
| ImageIO + UniformTypeIdentifiers | 10.x / 11 | PNG 编码、读取尺寸、按需生成缩略图 |
| QuickLookThumbnailing `QLThumbnailGenerator` | 10.15 | 剪贴板检查器里文件的真实缩略图（PDF 首页、图片、视频帧） |
| QuickLookUI `QLPreviewView` | 10.6 | 剪贴板 ⌘Y 放大预览里的文件（嵌在自己的浮层里；不用 `QLPreviewPanel`，见 D3） |
| Vision `RecognizeTextRequest` | 15.0 | 剪贴板图片 OCR、截图翻译识字 |
| ScreenCaptureKit `SCShareableContent` + `SCScreenshotManager` | 14.0 | 截图翻译的冻结帧（逐屏截图）；长截图用 `SCStreamConfiguration.sourceRect`（12.3+）反复截选区 |
| NaturalLanguage `NLLanguageRecognizer` | 10.14 | 语种检测（替代 Lingua，能识别繁体） |
| AVFoundation `AVSpeechSynthesizer` | 10.14 | 朗读 |
| Foundation `URLSession.bytes(for:)`、`AttributedString(markdown:)` | 12 | SSE 流式输出、行内 Markdown |
| CryptoKit：`Insecure.MD5`、`SHA256` | 10.15 | 百度 / 有道签名、图片去重 hash |
| Security `SecItem*` | — | API Key 存钥匙串 |
| Foundation `URLSession.download`、`Process`（调系统的 `/usr/bin/ditto`、`/usr/bin/codesign`） | — | 应用内更新：下载更新包、解包、验签（D8） |
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

### A. Apple 官方资料（不用安装）

- **查 API 文档**：在任意 `https://developer.apple.com/documentation/<path>` 后面加 `.md` 就能拿到 Markdown（已验证），agent 直接 WebFetch 即可。HIG 没有 `.md` 版本，通过 sosumi 查。
- **Xcode 自带的 Apple agent 文档**：只按绝对路径引用，**不要拷进仓库**。路径是 `/Applications/Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation/`，重点看这几篇：
  - `Swift-Concurrency-Updates.md`（并发的主要参考，替代社区的 concurrency 技能）
  - `AppKit-Implementing-Liquid-Glass-Design.md`
  - `SwiftUI-Implementing-Liquid-Glass-Design.md`
  - `Foundation-AttributedString-Updates.md`
  - `SwiftUI-New-Toolbar-Features.md`
- **语言与并发**：
  - https://www.swift.org/documentation/api-design-guidelines/
  - https://www.swift.org/migration/documentation/migrationguide/
  - https://developer.apple.com/documentation/swift/adoptingswift6
  - https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
  - https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
  - https://github.com/swiftlang/swift-format/blob/main/Documentation/Configuration.md
  - https://developer.apple.com/documentation/testing
- **HIG**（前缀 `https://developer.apple.com/design/human-interface-guidelines/`）：designing-for-macos、the-menu-bar、panels、windows、settings、materials、keyboards、privacy。另有 https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- **Phase 1 用到的框架**：
  - https://developer.apple.com/documentation/appkit/nspasteboard
  - https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum
  - https://developer.apple.com/documentation/appkit/nspanel
  - https://developer.apple.com/documentation/appkit/nsapplication/activate()
  - https://developer.apple.com/documentation/swiftui/menubarextra
  - https://developer.apple.com/documentation/vision/recognizetextrequest
  - https://developer.apple.com/documentation/servicemanagement/smappservice
  - https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
  - https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- **分发**：
  - https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
  - https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
  - https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
  - https://developer.apple.com/documentation/security/resolving-common-notarization-issues
  - https://developer.apple.com/documentation/security/hardened-runtime
- **WWDC**：
  - WWDC24 10169 Migrate your app to Swift 6
  - WWDC25 268 Embracing Swift concurrency
  - WWDC23 10149 Discover Observation in SwiftUI
  - WWDC24 10148 Tailor macOS windows with SwiftUI
  - WWDC25 310 Build an AppKit app with the new design
  - WWDC24 10163 Discover Swift enhancements in the Vision framework
  - WWDC22 10109 What's new in notarization for Mac apps
- **Apple 官方 agent 工具在本机不可用**：
  - Xcode 26.3 的 `xcrun mcpbridge` 在本机启动即 dyld 崩溃，需要 macOS 26.2+。
  - Xcode 27 的官方 skills（`xcrun agent skills export`）需要 macOS 26.6+。
  - 见 D14。升级后把 swiftui-specialist 导出到 `~/.agents/skills`，评估能否替代下面的社区 SwiftUI 技能，两者只留一个。

### B. 社区 skills / MCP（只用于开发，不进产品）

```bash
# 在 worktree 根目录执行
claude mcp add --scope project --transport http sosumi https://sosumi.ai/mcp   # 写入 .mcp.json 并提交；.cursor/mcp.json 填同一个 URL
npx skills add avdlee/swiftui-agent-skill -s swiftui-expert-skill -g -a claude-code -a cursor   # 装在用户级，不进仓库
```

| 选用 | 为什么选它 | 不装的 |
|---|---|---|
| sosumi（MCP，项目级） | 唯一需要的文档 MCP：覆盖 Apple 文档、HIG、WWDC 字幕，远程服务，无需本地安装 | apple-docs-mcp 两款（和 sosumi 重复）；XcodeBuildMCP（直接跑 `xcodebuild` 就够，而且带 Sentry 遥测） |
| avdlee swiftui-expert-skill（用户级） | macOS 内容最全：多窗口、AppKit 互操作、Liquid Glass | twostraws swiftui-pro（偏 iOS）；ehmo macos-design-guidelines（HIG 原文用 sosumi 查） |
| 不装 | avdlee / twostraws 的 swift-concurrency（并发以 Apple 自带的 `Swift-Concurrency-Updates.md` 和 `mac-native` 红线为准）；swift-lsp 插件（sourcekit-lsp 不认 `.xcodeproj`，要靠第三方 xcode-build-server，诊断以 `xcodebuild` 为准）；swiftdata-pro（不用 SwiftData）；Swift Testing 类技能；dimillian 系列（依赖 Tuist/Sparkle）；fayazara（许可不明，用 create-dmg）；dpearson2699（非 OSI 许可） | — |

不改 `skills-lock.json`。ponytail 在 Claude 侧由用户级插件生效，所以 CLAUDE.md 不 @import 它；`.cursor/rules/ponytail.mdc` 只给 Cursor 用。

### C. 本分支的项目规则

**M0 只写一篇常驻规则 `.cursor/rules/mac-native.mdc`**（`alwaysApply: true`，不超过 80 行），CLAUDE.md 用 `@` 导入。内容：

1. **结构**：目录分层（§4）；一个概念一个文件；每个入口文件头部写注释说明用途；禁止为「以后可能用到」建 protocol、manager 或容器；行为规格看 `macos/PLAN.md` §5，Tauri 代码只读参考。
2. **技术栈白名单**：§2 的清单；禁止引入任何 SPM 依赖；部署目标 15.0；需要 macOS 26 API 时就地写 `#available`，回退到 `.regularMaterial` / `NSVisualEffectView`。
3. **并发红线**：默认 MainActor；只有 §4 列出的 3 类工作可以用 `@concurrent`；禁止 `Task.detached`、`@unchecked Sendable`、`nonisolated(unsafe)`（C 全局变量除外，且必须加注释），禁止到处写 `DispatchQueue`。以 Xcode 自带的 `Swift-Concurrency-Updates.md`（绝对路径）为准。
4. **风格**：Swift API 设计规范；`xcrun swift-format lint --strict` 是唯一的格式标准；日期统一用 `Date.FormatStyle`；单行文本用 `lineLimit(1)` + `.truncationMode(.tail)`。
5. **剪贴板写入**：自己写剪贴板一律经过 `Paster.write`，它负责记下 changeCount 并加上 `org.nspasteboard.TransientType`（2026-09-26 改：只有划词还原加 TransientType）。
6. **签名**：固定 `DEVELOPMENT_TEAM`，用 Apple Development 自动签名，禁止「Sign to Run Locally」；ID 见 D5；用 `codesign -d -r-` 自检；授权卡住时执行 `tccutil reset Accessibility com.yy.kitty-tools.native.dev`。
7. **发版**：改 `MARKETING_VERSION` 必须在 `macos/KittyTools/Resources/changelog.json` 追加条目，type 只允许 feat / fix / perf / ui；tag 用 `macos-v*`；发到本仓库 github.com/YyAdnBug/kitty-tools，正式 release、标 latest，附 DMG 和 `_arm64.zip`（2026-09-27 起，详见 `build-dmg.sh` 头部注释）。
8. 用中文回答；commit 格式 `<type>: <description>`。

**按需技能**：等对应里程碑结束、真的踩过坑之后再写。`SKILL.md` 只写触发描述和红线，`rule.mdc` 是指向 `.cursor/rules/mac-*.mdc` 的符号链接。

| 技能 | 何时写 | 触发范围 | 正文来源 |
|---|---|---|---|
| `mac-overlay-panel` | M1 结束 | `Shell/**`、`Translate/SelectionReader.swift`；NSPanel、热键、前台快照、粘贴回原 App、划词时序、设置窗激活 | master 的 `macos-overlay-panel.mdc` 删减（绝对路径读取）+ M1 实测的坑 + 本文 §4、§9 |
| `mac-clipboard` | M3 结束 | `Clipboard/**`、`Storage/Database.swift` | 本文 §5.1、§6 + M2/M3 实测的坑 |
| `mac-translate` | M4 结束 | `Translate/**` | master 的 `zhipu-translate.mdc` 删减 + 本文 §5.2 + M4 实测的坑 |

不单独建 `mac-ui`、`mac-release`：UI 约定写进 `mac-native.mdc`，发布约束写进 `build-dmg.sh` 的头部注释。

**接入步骤**：
1. 规则正文只写在 `.cursor/rules/mac-*.mdc`。技能用符号链接，例如 `ln -s ../../../.cursor/rules/mac-clipboard.mdc .claude/skills/mac-clipboard/rule.mdc`，和现在的做法一致。
2. `AGENTS.md` 写正文：原生分支的项目概述；常用命令（`xcodebuild`、`macos/build-dmg.sh`、`xcrun swift-format`）；技能表；「`src/`、`src-tauri/` 只作参考，最新行为读 master 工作区绝对路径」；用中文回答；commit 规范。不再提 shadcn、dayjs、ui-radius、frameless 等 Tauri 规则。
3. `CLAUDE.md` 只保留两行：`@AGENTS.md`、`@.cursor/rules/mac-native.mdc`。
4. Claude 的自动记忆按路径隔离，worktree 会从一份新记忆开始。旧记忆里仍然适用的结论（例如「测内存看 footprint 而不是 RSS」）直接写进 `mac-native.mdc`。

---

## 4. 原生架构

**工程划分**
- 1 个 App target `KittyTools`，加 1 个测试 target `KittyToolsTests`（只测纯函数）。
- 不建 SPM 包、framework、extension，也没有辅助进程。

**文件结构**（一个概念一个文件，不预先建空目录）

| 目录 | 文件 |
|---|---|
| `App/` | `KittyToolsApp.swift`（@main 和 MenuBarExtra）、`AppDelegate.swift`（单实例检查、组装对象、生命周期、退出和锁屏清理）、`Updater.swift`（应用内更新，D8） |
| `Shell/` | `OverlayPanel.swift`、`HotKeyCenter.swift`、`HotKeyRecorder.swift`、`Permissions.swift`（辅助功能、屏幕录制、文件和文件夹授权）、`Paster.swift`、`Style.swift`（Whisker 刻度：圆角、七条弹簧曲线、中性色 / 家族色、种类色块、键帽、面板描边）、`Accent.swift`（强调色：跟随系统 + 8 色、配色计算、根视图的 `.appAccent()`）、`Island.swift`（刘海岛：全局轻提示，替换原来的 Toast）、`StatusItem.swift`（菜单栏图标与菜单，NSStatusItem，Whisker D 的呼吸 / 弹一下）、`ActionMenu.swift`（剪贴板 ⌘K、剪贴板筛选面板、启动器 ⌘K 共用的动作菜单） |
| `Storage/` | `Database.swift`、`Keychain.swift`、`Prefs.swift`、`LegacyImport.swift` |
| `Clipboard/` | `ClipboardWatcher.swift`、`ClipboardStore.swift`、`ClipItem.swift`、`ClipboardFilter.swift`、`ContentForm.swift`、`Search.swift`、`ImageStore.swift`、`OCR.swift`、`ClipboardPanelView.swift`、`ClipRowView.swift`、`PreviewView.swift`、`Dialogs.swift`、`LinkPreview.swift`（链接富预览：按块读网页 og 标签、isFetchable、内存缓存）、`QuickLookView.swift`（⌘Y 放大预览） |
| `Translate/` | `TranslateCoordinator.swift`、`LanguageResolver.swift`、`SelectionReader.swift`、`SSE.swift`、`Providers/`（`Zhipu`、`AIService`、`Baidu`、`Youdao`、`Google`、`DeepL`、`Microsoft`、`Volcengine`、`Tencent` 各一个 `.swift`）、`TranslatePanelView.swift`、`ProviderCardView.swift`（含服务身份 `ServiceTile`：官方 logo 或品牌色块，彗星边框、骨架扫光）、`RevealText.swift`（流式译文显影，TextRenderer）、`HistoryStore.swift`、`HistoryView.swift`、`WordLookup.swift`（查词：是不是一个词、系统词典查询与解析、单词模式示例，D4）、`DictionaryCardView.swift`（系统词典卡） |
| `Settings/` | `GeneralTab.swift`、`HotkeysTab.swift`、`ClipboardTab.swift`、`TranslateTab.swift`、`AboutTab.swift`、`LauncherTab.swift`、`ScreenshotTab.swift`、`SettingsWindow.swift`（D 阶段从 Shell 搬来：NavigationSplitView 侧栏 + 搜索 + 页头）、`OnboardingView.swift`（首次安装的欢迎引导：欢迎 + 按一下试试）、`ShortcutsSheet.swift`（快捷键速查表 + `ShortcutsButton`）、`OrderedList.swift`（可拖动排序列表共用的「+ −」按钮条、行高、详情页页头）、`TranslateServiceDetail.swift`（翻译服务详情页）、`SearchEngineDetail.swift`（网页搜索 / 快捷链接详情页） |
| `Launcher/` | `LauncherItem.swift`（结果项与内置动作）、`AppCatalog.swift`（App 目录 + 中文名 + 拼音）、`LauncherMatch.swift`（匹配与排序纯函数）、`LauncherUsage.swift`（使用记录表）、`LauncherModel.swift`、`LauncherPanelView.swift`、`FileSearch.swift`（文件搜索：open / find / 空格开头，NSMetadataQuery 查询、排除、排序、最近的文件、授权提示，M13） |
| `Screenshot/` | `ScreenCapture.swift`（逐屏冻结帧 + 同一刻的窗口 Z 序快照）、`RegionSelector.swift`（框选会话、每屏一个遮罩、选区几何纯函数）、`SelectionView.swift`（遮罩画面与交互：图层绘制、窗口悬停、手柄、放大镜、工具栏）、`ScreenshotOutput.swift`（PNG、快速保存、另存为）、`PinPanel.swift`（钉图）、`Annotation.swift`（标注模型，显示与导出共用 draw，M10）、`EditorToolbar.swift`（HUD 主工具栏 + 样式托盘，M10，Whisker 重做）、`FlyCard.swift`（截图飞入右下角 + 快门声，Whisker S1）、`ScrollCapture.swift`（长截图会话：边框、侧边面板、抓帧循环、自动滚动）、`ScrollStitcher.swift`（长截图拼接，纯逻辑）、`ShotShelf.swift`（CleanShot 式常驻缩略图，Whisker D） |

各 provider 函数签名统一，由 coordinator 里的一个 `switch` 分发。不建 registry 或 factory。

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

**单实例**：`applicationDidFinishLaunching` 最开始检查 `NSRunningApplication.runningApplications(withBundleIdentifier:)`。如果有 pid 不是自己的实例，就激活它，然后自己 `NSApp.terminate(nil)`。LaunchServices 不保证同一 bundle id 只跑一份，比如从挂载的 DMG 里运行一份、/Applications 里又启动一份。约 5 行。

**窗口体系**
- **App 入口与菜单栏**：
  - `@main struct KittyToolsApp: App` 用 `@NSApplicationDelegateAdaptor` 挂 AppDelegate，唯一的 scene 是 `MenuBarExtra(.menu)`。
  - `LSUIElement=YES`：不显示 Dock 图标，启动时不闪。
  - 菜单项：剪贴板历史 / 划词翻译 / 输入翻译 / 复制即译（Toggle）/ 设置… / 退出。快捷键用 `.keyboardShortcut` 显示；热键为空时显示「未设置」。
  - 菜单栏图标用单色模板图。左键点击直接弹菜单（HIG 做法），去掉 Tauri 版「左键打开主界面」。
- **`OverlayPanel: NSPanel`**，建两个实例：
  - 剪贴板面板：680×520，固定大小。
  - 翻译浮窗：420×560，最小 360×400，用 `setFrameAutosaveName` 记住位置。
  - `styleMask` 在 `init` 里一次写全，包含 `.nonactivatingPanel`（初始化后再改不会生效，这正是 Tauri 版不得不 swizzle 的原因）。`canBecomeKey=true`，`canBecomeMain=false`，`isFloatingPanel`，`level=.floating`，`hidesOnDeactivate=false`，`becomesKeyOnlyIfNeeded=false`，`collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary]`，`isMovableByWindowBackground=true`。
  - 显示只调 `orderFrontRegardless()` + `makeKey()`，**永远不调** `NSApp.activate`。
  - **点外关闭**（剪贴板面板）：显示时装一个 global 和一个 local 的左右键按下监听，隐藏时在主线程成对卸载。点中的窗口如果是任意一个 `OverlayPanel`，不关闭（点击时实时判断）；固定（pin）状态下也不关闭。
  - **翻译浮窗失焦隐藏**：`windowDidResignKey`，未固定才隐藏。
  - **Esc**：通过响应链的 `cancelOperation(_:)` 交给 SwiftUI 状态逐层处理。
    - 剪贴板面板：对话框 > 多选 > 关闭（固定时也关闭，和 Tauri 前端一致）。
    - 翻译浮窗：对话框 > 历史面板 > **未固定才关闭**，固定时什么也不做。
    - 顺带修掉 Tauri 版原生 Esc 监听抢先关闭面板的问题（`src-tauri/src/plugins/mac_overlay_panel.rs:365-370`）。
- **设置窗**：`SettingsWindow` 用 `NSWindow` + `NSTabViewController(tabStyle: .toolbar)`，每个 Tab 一个 `NSHostingController`。
  - 不用 SwiftUI `Settings` scene：在 LSUIElement 应用里它会被压到其它 App 后面，而且 `openSettings` 只能在 SwiftUI scene 环境里调用，浮层上的齿轮按钮调不到。
  - `show()` 的顺序：先把两个 OverlayPanel 按正常隐藏路径收起（包括作废翻译会话，对应 `src-tauri/src/windows/mod.rs:3683-3685`），再 `setActivationPolicy(.regular)` + `NSApp.activate()` + `makeKeyAndOrderFront`；关闭时切回 `.accessory`。
  - macOS 14 起 `activate()` 是协作式的，不保证一定成功。M3 实测三个入口，到不了最前面就退回 `NSApp.activate(ignoringOtherApps: true)`（已废弃但可用），并写进 `mac-overlay-panel` 技能。
  - 首次启动和版本更新后自动打开（分别打开通用页和关于页），不再单独做引导窗口。
- **依赖注入**：
  - 在 `AppDelegate.applicationDidFinishLaunching` 里按顺序创建：`Database` → `ClipboardStore`、`HistoryStore` → `ClipboardWatcher` → `TranslateCoordinator` → 两个面板 → `HotKeyCenter`，通过 init 传递。
  - 根视图用 `.environment(store)` 注入。
  - 偏好用 `@AppStorage`，键名集中写在 `Prefs.swift`，**沿用旧的 camelCase 键名**，默认值用 `UserDefaults.register(defaults:)` 注册。
  - （2026-09-26：默认值以 `Prefs.swift` 为准，不再对齐 Tauri）默认值基本照搬 Tauri，只有一处不同：`translateServiceEnabled` 默认只开 builtin。Tauri 默认还开了有道，全新安装没有密钥，浮窗里会一直挂着一张有道的错误卡。
  - 热键在模型里用 Optional 表示，nil 就是不注册。
  - 不用 DI 容器，也不为了测试去抽 protocol。

---

## 5. 功能迁移映射

**复杂度**：S 约半天，M 约 1–3 天，L 超过 3 天。

**路径缩写**：`R/` = `src-tauri/src/clipboard/`，`F/` = `src/features/clipboard/`，`T/` = `src-tauri/src/translate/`，`TF/` = `src/features/translate/`，`W` = `src-tauri/src/windows/mod.rs`，`MOP` = `src-tauri/src/plugins/mac_overlay_panel.rs`，`UC` = `F/hooks/useClipboard.ts`，`P` = `F/components/ClipboardHistoryPanel/index.tsx`。

### 5.1 剪贴板历史

| Tauri 模块 / 文件 | 原生组件 / Apple API | 复杂度 | 备注 / 坑 |
|---|---|---|---|
| 轮询采集 `R/watcher.rs:35-61,201-386` | `ClipboardWatcher`：主线程 0.3s `Timer`；`changeCount` 没变就跳过 | M | 处理顺序固定：先查 types 里的隐私标记 → 来源 App → 文件 → 文本 → 图片。被跳过或被过滤的也要提交 changeCount；读不到（被占用）时不提交。启动时直接对齐当前 changeCount，不再像 Tauri 那样把当前内容重记一次（`:216-220`）。LSUIElement 应用符合 App Nap 条件，timer 会被降频，见 M2 验收 |
| 隐私标记 `R/privacy_markers.rs:38-42` | 把 `pasteboard.types` 和 3 个 nspasteboard.org 字符串比较 | S | 先查 types，再读内容 |
| 来源 App `R/source.rs:23-66` | `NSWorkspace.frontmostApplication`（排除自身），取名称和 `bundleURL.path` | S | 这是推测值，用户在 300ms 内切换 App 会记错，接受 |
| 过滤 `R/filter.rs:7-120` | `ClipboardFilter` 纯函数，配单测 | S | 排除 App：名称或路径子串匹配，不区分大小写。敏感文本：`sk-` 后跟 20 位、bearer ≥24、13–19 位且通过 Luhn、整段 ≤64 字节。默认值已注册，不会出现「读配置失败、回退成空列表」 |
| 文本 `R/watcher.rs:276-327` | `string(forType: .string)` | S | trim 后为空或超过 5MB 时丢弃；用上一条的指纹防连续重复 |
| 富文本 `R/rich_text.rs:18,85-145` | 读：`.rtf` 优先，其次 `.html`，上限 2MB。写：一次 `declareTypes([rich, .string])` | S | 分两次 declare 会互相清空；富文本写失败时退回纯文本；关闭「保留格式」不影响已存富文本的粘贴 |
| 图片 `R/image_cache.rs`、`R/image_budget.rs:17-68` | `ImageStore`（@concurrent）：读 png/tiff；尺寸用 `CGImageSourceCopyPropertiesAtIndex` 读取，不解码；对编码字节做 SHA256 去重（有 PNG 用 PNG 字节，否则用转换后的 PNG 字节）；写 `images/{id}.png`。缩略图用 `CGImageSourceCreateThumbnailAtIndex` + `NSCache` | M | 像素上限 128MiB（按宽×高×4 算）；摘要为「图片 W×H」。`ponytail:` 注释写明「同一张图换了编码不会被去重」。字节预算 = `SUM(image_byte_size)`，超出时从最旧的可淘汰项开始，同时删文件和行。启动对账：cutoff 时间要在读 keep 集合**之前**取，keep 集合读失败绝不清理 |
| 文件 `R/paste.rs:383-419`、`R/image_cache.rs:460-493` | `readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly: true])`；大小取自 `attributesOfItem` | S | 摘要：单个显示文件名，多个显示「N 个文件」；目录不递归统计；按路径列表去重 |
| OCR `R/ocr_indexer.rs`、`R/ocr_local.rs:14-100` | `OCR`（@concurrent）：`RecognizeTextRequest`，`.accurate`，语言 `zh-Hans, zh-Hant, en-US`，开语言纠错，最多 4096 字符 | S | 语言必须显式指定；识别为无文字时写 `''`，之后不再重试；失败时留 NULL，下次启动重试；启动后串行补齐存量 |
| 自写抑制 `R/suppress.rs`、`F/lib/clipboard-hotkeys.ts:37-50` | `Paster.write`：写完记下 `changeCount`，watcher 遇到这个值就跳过；同时加 `org.nspasteboard.TransientType`，共存的 Tauri watcher 也会跳过（2026-09-26 改：只有划词还原加 TransientType）。划词期间 `watcher.pause`，结束后把 lastChangeCount 对齐到当前值 | S | 删掉所有时间窗常量（450/500/250/800ms）；跳过时仍更新指纹 |
| 存储 `R/history_db.rs`，以及 `UC:280-331` 的 diff 持久化 | `Database`（libsqlite3 单连接 WAL）+ `ClipboardStore`（@Observable，内存数组，每次变更直接写一行） | M | 表结构见 §6。保留规则 `isRetained = 收藏 ∨ 片段 ∨ 已归组` 只在 Swift 里定义一处 |
| 合并去重 `F/lib/cloud-sync.ts:19-95` | `ClipboardStore.insert` | S | text 比内容，file 比路径，image 比 hash。合并后用新 id 和新时间戳；收藏取 OR；备注优先保留非空；kind 和 groupId 保留旧值 |
| 条数与天数上限 `F/lib/history-settings.ts:15-42` | 每次插入后、面板显示时各执行一次 | S | 默认 100 条 / 7 天，0 表示不限（2026-09-26 改：默认不限条数 / 7 天、图片 512 MB）；只裁普通历史；删掉 10 分钟定时器 |
| 退出与锁屏清空 `src-tauri/src/lib.rs:43-57`、`R/clear_on_lock.rs:45-74` | `applicationWillTerminate`；`DistributedNotificationCenter` 监听 `com.apple.screenIsLocked` | S | 只清普通历史及其图片 |
| 浮层 `MOP:82-233`、`W:775-806` | `OverlayPanel`（见 §4）+ `NSHostingView` | L | 最大风险，M1 先打通 |
| 点外关闭 / Esc / 图钉 / 兄弟窗口豁免 `MOP:112-175,300-420`、`W:821-892` | global + local 鼠标监听、`cancelOperation`、`clipboardHideOnUnfocus` | M | 监听成对安装、成对卸载；图钉状态持久化 |
| 顶栏 `P:284-591` | 搜索框（包一层 `NSTextField`）、`Picker(.segmented)`（全部 / 收藏 / 片段）、计数徽标、图钉、齿轮 | S | 计数徽标的 4 种文案照搬 |
| 工具栏 `F/components/ClipboardFilterToolbar`、`F/lib/clipboard-content-form.ts:54-122`、`parse-clipboard-color.ts:149-184`、`clipboard-source-app-filter.ts:41-57` | `Menu` / `Picker`；`ContentForm` 纯函数，配单测 | M | 形态优先级：颜色 > JSON > URL > 代码。类型、形态、来源 App 之间的联动重置照搬；选中的来源消失时自动退回「全部」；任何筛选变化都滚到顶部、聚焦搜索框、选中第 0 条 |
| **分组筛选与管理** `F/components/ClipboardFilterToolbar:140-168`、`ClipboardGroupManageDialog`、`F/lib/clipboard-group-filter.ts:44-51`、`src/shared/services/clipboard-groups-db.ts` | 分组下拉 + 管理 sheet | S | 下拉项：全部分组 / 未分组 / 各分组（带数量，空组也显示）/「管理分组…」。管理对话框支持新建、重命名、删除。名称 trim 后截到 24 字，精确重名拦下；删除分组只解除归属；按创建时间升序 |
| 列表 `F/components/ClipboardHistoryVirtualList`、`F/lib/clipboard-list-rows.ts:28-66` | `ScrollView` + `LazyVStack(pinnedViews: .sectionHeaders)` + `ScrollViewReader` | M | 无搜索词时按天分组并吸顶（今天 / 昨天 / M月D日 / YYYY年M月D日，用 `Date.FormatStyle`）；有搜索词时按相关度排序、不分组。新条目进来时，除非用户正在浏览（方向键、⌘数字、修饰键点击），选中项回到第 0 条（`UC:200-202`） |
| **行渲染细则** `F/components/ClipboardItemCard:152-250`、`F/lib/clipboard-list-label.ts:4-31` | `ClipRowView` | S | 图标位优先级：色块 > 缩略图 > App 图标 > 类型图标。主文案：text 取前 120 字；image 为「图片 · W×H · 大小」；file 为文件名或「N Files: a, b」。备注第二行只在收藏或片段上显示。右侧依次：分组徽标（仅当分组筛选为「全部」时）、多选勾、前 9 行 ⌘1–9 提示（多选时隐藏）、带格式图标、收藏星 |
| 点击语义 `F/lib/clipboard-multi-select.ts:52-85` | `onTapGesture` + `NSEvent.modifierFlags` | S | 普通点击 = 选中并粘贴；⌘ 点击切换选中；⇧ 点击从锚点重新计算区间；多选状态下普通点击只收起多选 |
| 右键菜单 `ClipboardItemCard:254-327` | `.contextMenu` | S | 9 个菜单项及其出现条件照搬 |
| 空态 `P:623-678` | `ContentUnavailableView` | S | 4 种文案，加「清除筛选」「新建片段」按钮，附快捷键提示（`ClipboardShortcutsHint`）；骨架屏不做 |
| 键盘 `UC:874-960`、`P:434-487`、`F/lib/clipboard-hotkeys.ts:18-35` | 搜索框的 `control(_:textView:doCommandBy:)` 接 moveUp / moveDown / insertNewline / cancelOperation；⌘ 组合键在面板获得焦点时用本地 keyDown 监听处理 | M | ↑↓ 首尾循环，列表为空时不动。Enter 受 `clipboardPasteOnEnter` 控制；⌘Enter 总是粘贴，多选时合并粘贴。⌘1–9 按条目序号选中，`pasteOnEnter` 开启时同时粘贴。⌘A 全选可见条目。⌘D 收藏（多选时批量）。⌘⌫ / ⌘Del 删除。**⌘C 只复制**：不关面板、不置顶，面板内提示「已复制」；片段复制同样展开占位符并强制纯文本；搜索框有选中文字时 ⌘C 让给系统。输入法组字时 Enter 和方向键由输入法处理，不会传过来，不再需要吞键 hack。对话框打开时列表热键让位 |
| 粘贴 `UC:649-708,827-872`、`R/paste.rs:105-307`、`src-tauri/src/platform/macos/mac_input.rs:24-155` | `Paster`：先写最简版本：隐藏面板（orderOut）→ 写剪贴板 → 检查 `AXIsProcessTrusted` → 发 ⌘V（`CGEventSource(.combinedSessionState)`，keyDown/keyUp 都设 `flags = .maskCommand`，投递到 `.cgSessionEventTap`），**不加任何等待** | M | 显式设置 flags 后，热键还按着的 ⇧ 不会混进去。Tauri 的「松修饰键 + 等 30ms」「图片或文件多等 100ms」「每个按键新建 HID 源」都先不搬；M1 手测某个 App 失败时才加对应延迟，并用 `ponytail:` 注释写明是哪个 App。始终注入普通 ⌘V；「纯文本粘贴」靠只写 `.string` 实现。粘贴后该条保持原 id、更新时间戳并置顶。多选全是文本时按复制先后（旧→新）用 `\n` 拼接一次粘贴，并生成一条新历史；含图片或文件时逐条粘贴，间隔 250ms。未授权时内容仍留在剪贴板，面板内给出提示 |
| 片段 `F/lib/clipboard-snippet.ts:8-42` | 纯函数，配单测 | S | 占位符 `{date}`、`{clipboard}`、`{cursor}`，不区分大小写；片段粘贴强制纯文本。新建片段与已有同文本条目合并（`UC:1045-1063`） |
| 收藏 / 备注 / 编辑 / 删除 `UC:512-1068` | SwiftUI `sheet` / `alert` + 面板内撤销条 | M | 取消收藏时：普通历史连带清备注，片段保留备注。备注对话框：Enter 保存，Shift+Enter 换行，留空即清除。编辑内容后丢弃富文本。删除后 5 秒内可撤销并插回原位置；收藏或片段单条删除要确认，仅归组的和批量删除不确认 |
| 多选工具条 `F/components/ClipboardMultiSelectBar` | SwiftUI 工具条 | S | 合并粘贴或依次粘贴、批量收藏（全部已收藏则取消收藏）、归组、删除 |
| 搜索 `F/lib/clipboard-keyword-search.ts:8-166`、`F/lib/clipboard-search-highlight.ts:31-51` | `Search` 纯函数（主线程），约 100 行照搬，配单测 | S | 多个词取 AND；备注权重 ×3；备注、来源 App、路径这类短字段允许子序列匹配，正文和 OCR 只认连续子串；正文只取前 8192 字 |
| 预览 `F/components/ClipboardPreview`、`F/lib/clipboard-preview-actions.ts:14-45` | SwiftUI；长文本用包了一层的 `NSTextView`（TextKit 2） | M | 颜色色块；JSON 美化和字符串互转（只改视图，不改条目，切换条目时重置）；代码用等宽字体、不做高亮；图片；单个图片文件；文件列表最多 120 条；**搜索词高亮**。底栏：时间（今年内 `MM/DD HH:mm`，跨年 `YYYY/MM/DD HH:mm`）和来源 App。操作按钮最多直接显示 3 个，其余进「…」：翻译 / 在浏览器打开 / 复制纯文本 / 在访达中显示（`activateFileViewerSelecting`） |
| 显示与隐藏 `P:223-277` | 面板的 show / hide 回调 | S | 显示时聚焦搜索框；**每次隐藏都重置**搜索、筛选、多选、选中项（回到第 0 条）和滚动位置，包括粘贴触发的隐藏。去掉 Tauri 的「粘贴除外」特例：原生在隐藏前已经拿到要粘贴的条目，不需要它 |
| 设置 `src/features/settings/components/SettingsClipboardTab`、`src/shared/lib/clipboard-history-settings.ts:3-27` | `ClipboardTab`（`Form`） | S | 13 项（去掉 `clipboardDisableTextSelection`）+ 图片占用显示；取值范围照搬 `src-tauri/src/core/config.rs:1235-1247` |
| 热键与菜单 `src-tauri/src/core/hotkeys.rs:253-292`、`src-tauri/src/core/tray.rs:152-159` | `HotKeyCenter`（Carbon）+ `MenuBarExtra` | S | 热键回调的第一件事是快照前台 App；热键为 nil 时不注册 |
| 复制即译钩子 `R/watcher.rs:322-325` | watcher 文本分支里回调 `TranslateCoordinator` | S | 只传通过了过滤的文本 |

**Phase 1 砍掉或推迟的剪贴板功能**：
- 骨架屏：原生加载不到 50ms，不需要。
- Monaco 语法高亮：改为等宽字体 + `JSONSerialization` 美化，不做高亮。
- 预览档位文件（96 / 640–2048 / source 硬链接）和进程内 RGBA LRU：改用 ImageIO 按需生成缩略图 + `NSCache`。
- 前端 diff 持久化、两个数据库连接、OCR/富文本拆表、各种时间窗常量、10 分钟裁剪定时器、事件总线、frameless / 拖动 / 输入法相关的 hack：原生不需要。
- `clipboardDisableTextSelection` 和主题配置项（见 D13）。
- 设置备份的导出导入（含 base64 图片）：只做 D9 的一次性导入。
- 启动器 `cb` 指令、剪贴板与启动器互斥：推迟到 Phase 2（到时给 store 加一个查询函数）。
- 截图 OCR 原文写入历史：推迟到 Phase 3（届时调 `ClipboardStore.insertText` 即可）。

### 5.2 翻译

| Tauri 模块 / 文件 | 原生组件 / Apple API | 复杂度 | 备注 / 坑 |
|---|---|---|---|
| 划词 `T/pipeline.rs:53-100`、`src-tauri/src/selection.rs:325-581` | `SelectionReader`，三步：<br>① 在 `@concurrent` 里用 AX 读 `kAXFocusedUIElement` → `kAXSelectedText`，超时 0.5s；<br>② 读不到，且当前 key 窗口是自家 OverlayPanel（例如浮窗已固定、刚点过里面的按钮）时：先让面板交出 key，并激活热键时快照的前台 App（macOS 14+ 实测 `activate()` 与 `yieldActivation`），**再读一次 AX**（对应 `selection.rs:337-346`）；<br>③ 仍读不到：按 type 逐项备份剪贴板 → `clearContents` → 发 ⌘C（keycode 0x08，flags 显式设为 `.maskCommand`）→ 每 12ms 轮询 changeCount，最多 500ms → 经 `Paster.write` 还原剪贴板（失败重试 3 次，间隔 20ms，防止丢用户数据） | M | **复制完成前禁止显示浮窗**。已有一次在跑时，重复按热键直接忽略；整个过程暂停 watcher；不用 osascript。Tauri 的「等 40ms」先不搬，M4 实测失败再加。选区为空时打开空白输入面板；失败时浮窗显示错误卡片并引导去授权 |
| 输入翻译 `T/pipeline.rs:103-125` | 显示空白浮窗并聚焦输入框 | S | 清空上一次的原文和译文；这个热键不做前台快照 |
| 会话与多引擎并行 `T/session.rs:21-40`、`TF/components/FloatingResult/index.tsx:111-118,468-756` | `TranslateCoordinator`（@MainActor @Observable）：新会话取消旧 Task，用 `withTaskGroup` 并行跑所有启用的服务 | M | 关闭浮窗时作废整个会话；前端结果缓存和 32s/190s 前端定时器都去掉 |
| 预处理与长度校验 `T/text_preprocess.rs:4-32`、`T/validation.rs:5-15` | 纯函数 | S | `translateDeleteNewline`；上限 32KB（按 UTF-8 字节）；百度 6000 字符、有道 5000 字符 |
| 语种检测 `src-tauri/src/lang_detect.rs:7-81` | `NLLanguageRecognizer` + `languageConstraints`（原来的 10 种语言，另加 zh-Hant） | S | 触发阈值照搬：含 CJK/假名/谚文 ≥2 字，或纯拉丁字母 ≥10 字；保留「先显示浮窗、再检测」的顺序 |
| 语言解析 `T/api.rs:116-344` | `LanguageResolver` 纯函数，配单测 | S | 双向互译的 4 个分支；按语系比较（zh-CN 和 zh-TW 算同一族）；兜底目标语言；发给智谱前目标语言不能是 auto；整个流程只检测一次 |
| 浮窗 `TF/components/FloatingResult` | `OverlayPanel` + `TranslatePanelView` | M | 顶栏：固定（`floatingPinned`）、复制即译、历史、设置、关闭。位置用 `setFrameAutosaveName` 记忆，替代约 120 行的屏内校验 |
| 失焦隐藏 `W:1743-1882` | `windowDidResignKey` + 判断是否固定 | M | 隐藏时若剪贴板面板还开着，把焦点交还给它；不还原前台 App。Tauri 的「显示后 500ms 内不自动隐藏」先不搬，M4 出现「刚显示就被隐藏」再加 |
| Esc `FloatingResult:859-873` | `cancelOperation` | S | 历史面板开着 → 只收起面板；否则**未固定才关闭**，固定时什么也不做 |
| 输入框 `FloatingResult:993-1005` | 包一层 `NSTextView`，在 `doCommandBy` 收到 insertNewline 时看 Shift 是否按下 | S | Enter 提交，Shift+Enter 换行；输入法组字时不触发；修改原文会立即取消进行中的请求 |
| 原文操作行 `FloatingResult:903-971,1160-1238` | `AVSpeechSynthesizer`；复制走 `Paster.write` | S | 朗读：源语言为 auto 时用检测结果，再点一次停止，中文优先普通话、排除粤语声线。复制后图标变对勾 1.6s。还有清空、检测语种徽标。「翻译」按钮强制重译，3 种情况下禁用 |
| 语言栏 `FloatingResult:931-953,1241-1267` | 两个 `Picker` + 交换按钮 | S | 切换语言会写回全局 `sourceLang` / `targetLang` 并自动重译；交换规则照搬；两边都是 auto 时禁用交换 |
| 结果卡片 `TF/components/TranslateProviderCard`、`TF/components/TranslateMarkdown/index.tsx:16-34`、`TF/lib/translate-user-error.ts:7-42` | `ProviderCardView`；只对流式服务用 `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)` 渲染 | M | 可折叠，有新内容时自动展开；加载 / 错误 / 译文 / 占位 4 种状态；底部有朗读、复制、重试。链接只允许 http(s)，交给 `NSWorkspace.open`。错误文案映射照搬。没有启用任何服务时显示空态和「打开翻译设置」。流式输出时每 50ms 重建一次富文本 |
| 贴底滚动 `FloatingResult:432-455` | `.defaultScrollAnchor(.bottom)` | S | 用户往上滑后暂停跟随 |
| 自动复制 `FloatingResult:246-249,550-558` | 翻译完成的回调，经 `Paster.write` 写入 | S | 条件：`autoCopy` 打开且「复制即译」关闭；复制的是**列表中第一个已启用服务**的结果 |
| 历史写入 `T/history_db.rs:184-255`、`FloatingResult:283-329` | `HistoryStore`，和剪贴板共用一个 `Database` | S | 一次翻译只记一条，取列表中第一个已启用服务的结果（D15）。mode：输入翻译记 `input`，划词和复制即译记 `selection`。trim 后截到 10000 字；`ON CONFLICT(source_text,target_lang)` 时不覆盖收藏状态和 id；在同一事务里淘汰超出上限的非收藏条目 |
| 历史面板 `TF/components/TranslateHistoryPanel` | 浮窗内的覆盖视图 | S–M | 搜索防抖 180ms，LIKE 查询并转义 `%` `_` `\`，最多 200 条；↑↓、Enter、鼠标悬停同步选中。行时间：今天 `HH:mm` / `昨天 HH:mm` / 今年 `MM/DD` / 跨年 `YYYY/MM/DD`；底部显示「共 N 条 · 收藏 M」。复制、删除、收藏都是乐观更新，失败回滚。应用某条历史时：若它的目标语言不是 auto，先改全局目标语言，再让所有服务重译。清空时保留收藏并先确认；新会话开始时自动收起面板 |
| 复制即译 `T/clipboard_monitor.rs:18-58` | watcher 文本分支的回调 | S | 以下情况不触发：自写的 changeCount、开关关闭、与上次翻译过的文本指纹相同 |
| 智谱内置 `T/api.rs:1569-1607,1801-1826`、`src-tauri/src/builtin_translate.rs` | `Providers/Zhipu.swift` | S | `max_tokens=1024` 写成常量。关闭思考依次尝试 `thinking disabled` → `reasoning_effort low` → 不带参数，只有遇到 400/422 才降一档。用中文提示词；不发 system、temperature。文本模型可选 `glm-4-flash` / `glm-4.6v-flash`（`zhipu.textModel`）。用户没填 key 时用内置 key（来自 `Secrets.xcconfig`） |
| AI 实例 `T/api.rs:419-556,932-2304` | `Providers/AIService.swift` + `SSE.swift`，**openai / azure / anthropic 三种协议**（D11） | M | **azure**：`api-key` 头，`model` 填部署名，不带 max_tokens，关思考档 `effort none → minimal → low → 不带`，不支持获取模型。**anthropic**：URL 含 `/messages` 原样用、末段是版本号补 `/messages`、否则补 `/v1/messages`，默认 `https://api.anthropic.com`；`x-api-key` + `anthropic-version: 2023-06-01`；`system` 放顶层，`max_tokens:4096` 必填；SSE 取 `content_block_delta` 的 `text_delta`；关思考档公网 `thinking disabled → output_config{effort:low} → 不带`，本机 `thinking disabled + chat_template_kwargs → thinking disabled → 不带`；获取模型 `GET …/v1/models?limit=1000`（`api.rs:448-481,502-556,1942-1955`）。<br>**openai** URL 补全：已含 `/chat/completions` 原样用；末段是 `v<数字>` 或 `/openai` 时补 `/chat/completions`；否则补 `/v1/chat/completions`；没写 scheme 补 `https://`。Key 为空不带 Authorization。<br>**max_tokens 按 host 取值**（`api.rs:2004-2010`）：`bigmodel.cn` / `z.ai` 用 1024，OpenAI 官方不传，其余 4096。<br>**本机判定**照搬 `validation.rs:23-35` 的 `is_local_network_host`：loopback、私网 / 链路本地 IP、`localhost`、`*.local`、不带点的主机名。<br>按 host 选关闭思考的参数档，成功的档位按 `url\nmodel` 记在内存里。SSE 按 `data:` 行解析，遇到 `[DONE]` 结束；忽略 reasoning 类字段；只剥掉开头那段 `<think>`（支持标签被拆到多个 chunk）；去掉外层引号；结果为空时报错。本机地址空闲超时 180s，其它 30s（设在 `timeoutIntervalForRequest`，不设总超时）。获取模型列表超时 15s |
| 百度 `T/api.rs:571-657` | `Providers/Baidu.swift`，`URLSession` + `Insecure.MD5` | S | `sign=md5(appid+q+salt+secret)`；返回 `trans_result[].dst` 用 `\n` 拼接；6000 字符上限；语言码 zh / cht / en / jp / kor / fra / de / spa / ru / pt / it |
| 有道 `T/api.rs:2332-2439`、`youdao.rs` | `Providers/Youdao.swift`，`URLSession` + `SHA256` | S | v3 签名：`sha256(appKey+input+salt+curtime+appSecret)`，input 在 q 超过 20 字符时取「前 10 字 + 字数 + 后 10 字」；5000 字符上限；语言码 zh-CHS / zh-CHT |
| Google `T/api.rs:800-912` | `Providers/Google.swift` | S | `POST translation.googleapis.com/language/translate/v2?key=`，JSON `{q, target, format:"text", source?}`；取 `data.translations[0].translatedText / detectedSourceLanguage`；错误看 `error.message` |
| DeepL / DeepLX `T/api.rs:1431-1565` | `Providers/DeepL.swift`（一个文件两种 apiType） | S | Key 以 `:fx` 结尾走 `api-free.deepl.com`、`:dp` 走 `api.deepl-pro.com`、否则 `api.deepl.com`；`Authorization: DeepL-Auth-Key`。**源、目标语言码用两张映射并写单测**：`source_lang` 只接受 EN / PT / ZH 这类基础码，`target_lang` 用 EN-US / PT-BR / ZH-HANS / ZH-HANT（修掉 Tauri 繁体丢失和 EN/PT 已弃用的问题）。DeepLX：`POST {deeplxUrl}`，结果在 `data` |
| 微软 `T/api.rs:1021-1144` | `Providers/Microsoft.swift` | S | 没填 Key：`GET edge.microsoft.com/translate/auth` 取 token（每次重取）→ `api-edge.cognitive.microsofttranslator.com/translate`；填了 Key：`api.cognitive.microsofttranslator.com` + `Ocp-Apim-Subscription-Key`（可选 `-Region`）。`api-version=3.0`，body `[{"Text":t}]`，源为 auto 时省略 `from`；语言码 zh-Hans / zh-Hant |
| 火山 `T/api.rs:1210-1312` | `Providers/Volcengine.swift`，CryptoKit `HMAC<SHA256>` | M | `Action=TranslateText&Version=2020-06-01`，region cn-north-1，service translate，签名头 `content-type;host;x-content-sha256;x-date`；取 `TranslationList[0]`；错误在 `ResponseMetadata.Error.Message`；语言码 zh / zh-Hant。签名用厂商文档示例写单测 |
| 腾讯 `T/api.rs:1315-1415` | `Providers/Tencent.swift`，CryptoKit `HMAC<SHA256>` | M | TC3-HMAC-SHA256，service tmt，region ap-beijing，`X-TC-Action: TextTranslate`、`X-TC-Version: 2018-03-21`；body `{SourceText, Source, Target, ProjectId:0}`；取 `Response.TargetText`；语言码 zh / zh-TW。签名用厂商文档示例写单测 |
| 错误脱敏 `src-tauri/src/core/net_redact.rs` | 按 `URLError.code` 映射错误文案，从不拼接 URL | S | 日志里同样不打印 URL 和请求头 |
| 翻译设置 Tab：`SettingsTranslateTab`、`AiServiceSettingsFields`、`TF/lib/translate-provider-settings.tsx:84-348`、`src/shared/lib/translate-services.ts:83-396` | `TranslateTab`：`List` + `.onMove` 拖动排序，`DisclosureGroup` 展开表单，输入框直接读写钥匙串 | L | 包含：复制即译开关；服务列表（排序、启用开关、至少保留一个启用的服务）；各服务表单（智谱：文本模型 + 可选 key；百度：App ID、密钥；有道：应用 ID、密钥；Google：Key；DeepL：apiType、Key 或 DeepLX 地址；微软：可选 Key + Region；火山、腾讯：AccessKey/SecretId、Secret；AI：协议、名称、服务地址、API Key、模型）。「验证连接」用 `Hello` 做 en→zh-CN，非流式，先做前端预检。AI：预设照搬（三种协议都保留）；「从预设填入」时保留用户改过的名称；新实例 id 为 `ai:<8位>`；删除要二次确认，是最后一个启用服务时拒绝删除，删除后清掉对应的钥匙串条目；「获取模型」用输入框里尚未保存的值，并用序号防止乱序回包。翻译语言卡（智能互译开关和联动规则、语言 A/B 或源/目标）。行为卡：自动复制、去掉换行、记录历史 + 保留条数（100/200/500/1000/2000） |
| 凭据：现在是 `src-tauri/src/core/config.rs` 里的明文 JSON | `Keychain.swift`（SecItem 的 get / set / delete，约 40 行） | S | account 列表见 §6；用户清空输入框时删除对应条目；运行期 token 只放内存 |
| 菜单栏与热键 `src-tauri/src/core/tray.rs:160-182`、`src-tauri/src/core/hotkeys.rs:131-153,272-331` | `MenuBarExtra` + `HotKeyCenter` | S | 划词热键先快照前台 App，输入翻译不快照。保存前检查所有热键不重复；逐项注册并收集错误，显示在快捷键 Tab |
| 剪贴板预览里的「翻译」按钮 `F/components/ClipboardPreviewActions/index.tsx:54-59` | 直接调用 `TranslateCoordinator.translate(text)` | S | 打开翻译浮窗，剪贴板面板保持不关（兄弟窗口豁免） |

**Phase 1 砍掉或推迟的翻译功能**：
- 截图翻译已做（2026-09-24，用户决定提前）：只用 Vision 本机识字，识别出的原文交给全部启用服务翻译。**不做**：「截图翻译默认服务」下拉、智谱识图（`zhipu.visionModel`）、百度图片翻译、百度 OCR 凭据、各家云端 OCR（旧链路坏了好几处，见 §11 #7–#9、#22）。
- 「划词 / 浮窗默认服务」下拉（D15）、翻译 Tab 顶部的快捷键汇总卡（快捷键 Tab 已经有）。
- Markdown 块级渲染降级：Tauri 用 GFM + breaks 渲染列表、标题、代码块；`.inlineOnlyPreservingWhitespace` 只渲染行内格式，块级标记会原样显示为文字。接受这个降级，真有需要再按 `PresentationIntent` 拆块（约 80 行）。
- 点击译文正文朗读：砍掉，保留朗读按钮。原因是原生要开 `.textSelection(.enabled)` 让用户能选中文字，和点击手势冲突。
- 以下 Tauri 专用机制全部删掉：`pending_translation` / `floating_ready` 握手、`emit_floating_event`、会话结果缓存、`translateRoutingDefaultsV2`、legacy openai/ollama/gemini 迁移、死掉的 `capturing` 状态、主题和透明度相关代码。
- 不新增 Apple Translation 引擎（见 D12）。

### 5.3 共享外壳

| Tauri | 原生 | 复杂度 | 备注 |
|---|---|---|---|
| `main.rs`、`platform/macos/startup_focus.rs`、预建 WebView | `LSUIElement=YES` | S | 整套防抢焦点的启动流程都不需要了 |
| single-instance 插件、Dock reopen | `NSRunningApplication` 检查（见 §4）；`applicationShouldHandleReopen` 里打开设置窗 | S | — |
| `ALLOW_APP_EXIT` 退出拦截 | 不需要（AppKit 关掉最后一个窗口不会退出） | S | 清理逻辑放在 `applicationWillTerminate` |
| 通用 Tab | `SMAppService.mainApp`（状态为 `.requiresApproval` 时引导；从 DMG 里直接运行时不注册）；外观（浅色 / 深色 / 跟随系统）用 `NSApp.appearance`；权限卡片；「从旧版导入」按钮（M4 先放这个按钮） | S | 权限卡片：<br>• 辅助功能：调一次带 prompt 的 `AXIsProcessTrustedWithOptions`。<br>• 剪贴板访问（`#available(macOS 15.4, *)`）：`.default` 和 `.alwaysAllow` 不显示卡片（`.default` 表示从未触发过弹窗，此时系统设置面板里根本没有本 App）；`.ask` 引导用户到「隐私与安全性 › 从其他 App 粘贴」改成始终允许；`.alwaysDeny` 显示错误卡片，说明剪贴板采集已被系统拒绝 |
| 快捷键 Tab | `HotKeyRecorder`：用本地 keyDown 监听录制 | M | 不按修饰键组合一刀切：直接尝试注册，把 -9868 映射成「当前系统（15.0/15.1）不支持只带 ⌥ 的组合」。有「清除」按钮（设为 nil，显示「未设置」）。录制期间注销全部全局热键 |
| 关于 Tab 和更新日志弹窗 `src-tauri/src/commands/app_update.rs` 的 `arm_whats_new_release` | `lastSeenVersion` 存 UserDefaults；版本变化且不是首次安装时，打开设置窗的关于 Tab；`changelog.json` 随包分发 | S | 在线更新见 D8（`App/Updater.swift`） |
| 功能主页、7 步欢迎引导 | 砍掉 | — | 首次启动直接打开设置窗通用页 |

---

## 6. 数据与配置迁移

**新存储位置**：
- 数据目录：`~/Library/Application Support/com.yy.kitty-tools.native/`（Debug 版用 `.native.dev`，与 Release 数据隔离），里面放 `kitty.sqlite3`（WAL 模式）和 `images/{id}.png`。
- 偏好：UserDefaults 域 = bundle id，键名和旧版一样用 camelCase。`aiServices` 去掉 apiKey 后，以 JSON 存在 UserDefaults。
- 密钥：钥匙串 generic password，service 为 bundle id，account 如下表。用传统的文件型登录钥匙串：条目的保护来自 ACL（绑定签名要求），默认不同步到 iCloud。**不设 `kSecAttrAccessible`**：在 macOS 上它只对 data protection keychain 或可同步条目生效。D7 已定不公证，暂不切换到 data protection keychain（需要 access group 和 provisioning profile）。

| 旧 JSON 字段 | 钥匙串 account | 阶段 |
|---|---|---|
| `zhipu.apiKey` | `zhipu.apiKey` | Phase 1 |
| `baidu.appId` / `baidu.secret` | `baidu.appId` / `baidu.secret` | Phase 1 |
| `youdao.appKey` / `youdao.appSecret` | `youdao.appKey` / `youdao.appSecret` | Phase 1 |
| `aiServices[].apiKey` | `ai:<id>`（删除实例时一并删除） | Phase 1 |
| `baidu.ocrApiKey` / `baidu.ocrSecretKey` | 不导（截图翻译只用 Vision 本机识字） | — |
| Google、DeepL、微软、火山、腾讯的凭据（`google.apiKey`、`deepl.apiKey`、`microsoft.apiKey`、`volcengine.accessKeyId/secretAccessKey`、`tencent.secretId/secretKey` 等，以 `config.rs` 实际字段名为准） | 同名规则 `<service>.<field>` | Phase 1（M5） |

**新表结构**：把旧版的 OCR 表和富文本表合并进主表。

```sql
CREATE TABLE clip_items(
  id TEXT PRIMARY KEY, type TEXT NOT NULL, content TEXT NOT NULL DEFAULT '',
  content_hash TEXT, image_byte_size INTEGER, image_width INTEGER, image_height INTEGER,
  file_paths TEXT, file_byte_sizes TEXT, timestamp INTEGER NOT NULL,
  source_app TEXT, source_app_path TEXT, favorited INTEGER NOT NULL DEFAULT 0,
  note TEXT, kind TEXT NOT NULL DEFAULT 'history', group_id TEXT,
  ocr_text TEXT,               -- NULL=未识别，''=识别过、没有文字
  rich_format TEXT, rich_data BLOB);   -- 列表查询不取 rich_data，粘贴时再读
CREATE INDEX clip_items_ts ON clip_items(timestamp DESC);
CREATE TABLE clip_groups(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL);
-- translate_history 与旧表完全一致，包括 UNIQUE(source_text, target_lang) 和时间索引
```

**旧数据到新存储的对应关系**（旧目录：`~/Library/Application Support/com.yy.kitty-tools/`）：

| 旧 | 新 | 处理方式 |
|---|---|---|
| `app_config.sqlite3` 里的 `app_config.payload`（camelCase JSON）→ **M4** | UserDefaults + 钥匙串 | 用 `JSONDecoder` 解码，结构体里只定义白名单字段：<br>• 导入：`clipboard*`（热键和 `clipboardDisableTextSelection` 除外）、`sourceLang`/`targetLang`、`bidirectional*`、`autoCopy`、`floatingPinned`、`translateClipboardMonitor`、`translateDeleteNewline`、`translateHistory*`、`theme`、`zhipu.textModel`；`translateServiceEnabled` / `translateServiceOrder` 以旧值为准，全部服务 id 和 `ai:*` 都保留。<br>• `aiServices` 照搬 `config.rs:1259-1286` 的规范化：丢弃非法或重复 id，未知协议当 openai，空名改成「AI 服务」；`deepl.apiType`、`deepl.deeplxUrl`、`microsoft.region` 等非密钥字段进 UserDefaults。<br>• `launchOnStartup=true` 要调用 `SMAppService.mainApp.register()`，只写偏好不生效。<br>• **不导入**：所有热键（原生用自己的默认值）、`lastSeenVersion`、`firstRun`、`floatingWindowX/Y`、`selectionTranslateProvider`、主题 preset 类字段。<br>• 旧的扁平格式和 snake_case 格式不支持，遇到时提示用户先启动一次 Tauri v0.1.13 |
| `kitty-settings.db` 的 `clipboard_history`，LEFT JOIN `clipboard_image_ocr` 和 `clipboard_rich_text`，**只取** `favorited=1 OR kind='snippet' OR group_id IS NOT NULL` → M6 | `clip_items` | 逐行按 §5.1 的去重键（text 比内容、file 比路径、image 比新算的 hash）查找已有条目：有则合并（收藏取 OR、备注取非空、kind 取 snippet 优先、分组取非空、时间取较新），无则按原 id 和原时间插入。`type` 不是 text/image/file 的归为 text |
| `clipboard_groups` → M6 | `clip_groups` | 按 id `INSERT OR IGNORE`；和已有分组同名的并入已有分组（映射 group_id） |
| `translate_history` → M6 | `translate_history` | 全部导入，保留旧行的收藏：<br>`INSERT OR IGNORE INTO translate_history SELECT … FROM old.translate_history;`<br>`UPDATE translate_history SET favorited=1 WHERE favorited=0 AND EXISTS (SELECT 1 FROM old.translate_history o WHERE o.favorited=1 AND o.source_text=translate_history.source_text AND o.target_lang=translate_history.target_lang);` |
| `clipboard_images/{id}.kchi`（只处理被导入条目的） → M6 | `images/{id}.png` | 文件以 PNG 签名开头就直接复制，并对这些字节算 SHA256 作为新 hash。本机 95 个全是 PNG（已核实），所以不写 KCH 解析；不是 PNG 的，连同那一行一起跳过，并在导入结果里计数 |
| 普通历史、`*.preview-*.png`、`settings` 表、`~/Library/Caches/com.yy.kitty-tools/`、WebKit localStorage | 丢弃 | 普通历史见 D9 |
| 启动器和截图相关文件 | 暂不处理 | Phase 2/3 再导入 |

**导入流程**（「设置 › 通用」里只有一个「从旧版导入」按钮，可以重复执行；不做首启提示横幅）：
1. 界面提示用户最好先退出 Tauri 版。
2. **不能直接只读打开旧库。** 两个旧库都是 WAL 模式；库旁没有 `-wal`/`-shm` 时，`mode=ro` 打开会报 SQLITE_CANTOPEN(14)，因为只读连接没法创建 `-shm`（已实测）。Tauri 正常退出时会删掉这两个文件，`app_config.sqlite3` 平时就没有，所以按原来的写法导入必然失败。正确做法：
   1. 把 `<db>` 和存在的 `<db>-wal`、`<db>-shm` 一起复制到本 App 数据目录下的临时目录；
   2. 以读写方式打开或 `ATTACH` 这份副本，SQLite 会自动回放 WAL；
   3. 执行 `PRAGMA quick_check`，结果不是 `ok` 就中止，提示「请先退出旧版再导入」（Tauri 运行中复制，可能拿到写到一半的副本）；
   4. 导完删掉临时目录。
3. 顺序：偏好 → 密钥 →（M6）分组 → 剪贴板条目 → 图片 → 翻译历史，数据部分在一个事务里完成。导入过程中不触发条数和天数裁剪。
4. 铁律一：**任何读取失败都中止并报错，绝不用默认值覆盖**（沿用 `CONFIG_LOAD_FAILURE` 的原则）。
5. 铁律二：原文件只复制、不打开、不修改。
6. 导入结束显示结果：新增 N、合并 M、跳过 K（及原因）。
7. 不动 `~/Library/LaunchAgents/`，那是 Tauri 开机自启写的，Tauri 版还在用。

---

## 7. 里程碑

### M0：分支、工程骨架、规则、DMG 空壳流水线
**交付物**
- worktree 和分支。
- `macos/` 工程：用 Xcode 模板创建。**创建后把 target 层的 buildSettings 全部清空，原有的值搬进 `Base.xcconfig`**，只留 xcconfig 引用。原因：pbxproj 里 target 层的值优先级高于 xcconfig，而模板在 target 层写死了 `SWIFT_VERSION=5.0`、`MACOSX_DEPLOYMENT_TARGET=<本机最新>`、`REGISTER_APP_GROUPS=YES`、`ENABLE_APP_SANDBOX=YES`、`ENABLE_USER_SELECTED_FILES=readonly`，以及版本号、bundle id、签名项（本机模板已核实）。不清掉的话，工程会停在 Swift 5 语言模式，严格并发等于没开，最低系统版本也不是 15.0。模板生成的 `.entitlements` 文件和 `CODE_SIGN_ENTITLEMENTS` 一并删除。
- 工程开发语言设为 zh-Hans。
- 三个 xcconfig、`Config/Info.plist`、`.swift-format`（`xcrun swift-format dump-configuration` 生成）、`build-dmg.sh`（只有路径 B）。
- `changelog.json`，含 0.0.1 的条目。
- 只有「关于 / 退出」两项的 MenuBarExtra；单实例检查。
- `AGENTS.md`、`CLAUDE.md`、`.cursor/rules/mac-native.mdc`、`.cursor/rules/ponytail.mdc`、`.mcp.json`、`.cursor/mcp.json`；用户级安装 swiftui-expert-skill。
- `macos/PLAN.md`：本方案原文。

**验收标准**
1. `xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools build` 成功，而且没有任何 warning。
2. `xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools -configuration Release -showBuildSettings | grep -E '^ *(SWIFT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_APP_SANDBOX|SWIFT_DEFAULT_ACTOR_ISOLATION) ='` 依次输出 6.0 / 15.0 / NO / MainActor；`vtool -show-build <app>/Contents/MacOS/<exe>` 显示 minos 15.0。
3. `xcrun swift-format lint --strict -r macos/KittyTools` 没有输出。
4. 运行 Debug 版：菜单栏出现图标，Dock 没有图标；「关于」面板是中文。
5. `codesign -d -r- <Debug.app>` 的输出里包含 `anchor apple generic` 和 `com.yy.kitty-tools.native.dev`，而不是 cdhash。
6. `macos/build-dmg.sh` 产出 `Kitty Tools Native_0.0.1_arm64.dmg`，`lipo -archs` 输出 `arm64`，`hdiutil verify` 通过。
7. **模拟真实下载**：本机生成的 DMG 没有隔离属性，Gatekeeper 不会评估它，直接测等于没测。先执行 `xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" "$DMG"`（或者从本仓库的 GitHub release 用 Safari 下载），再挂载、拖进 Applications。`spctl -a -vvv -t exec "/Applications/Kitty Tools Native.app"` 应显示 rejected；到系统设置点「仍要打开」后能正常启动。
   - 注：开发机 Gatekeeper 已关闭（`spctl --status` = assessments disabled，M0 实测），本机一律 accepted；这条只能在开着 Gatekeeper 的 Mac 上验证。
8. 在 worktree 里新开一个会话：只加载了 `mac-native`，没有加载 Tauri 规则；`claude mcp list` 能看到 sosumi；swiftui-expert-skill 可用。

### M1：浮层外壳的技术验证（先打通最大的风险）
**交付物**：`OverlayPanel`（两个实例，翻译浮窗先只放一个输入框，用来测兄弟窗口豁免和输入法）、`HotKeyCenter`（默认热键写死，非独占注册）、`Permissions`、`Paster`（最简版），以及接好的菜单项。结束时写 `mac-overlay-panel` 技能。

**验收标准**（手动测试清单，写进 PR 描述）
1. 分别以 Safari、VS Code、微信、全屏 Keynote 为前台时按 ⌥C，面板都能弹出，而且前台 App 的菜单栏名称不变（说明没有激活本应用）。
2. 面板里的输入框能用拼音、双拼、日文输入，候选窗位置正确；组字过程中按 Enter 不会触发提交。
3. 点其它 App 时面板关闭；点另一个自家面板时不关；固定（pin）后都不关；按 Esc 关闭。
4. 按住 ⌥C 触发面板后，点测试按钮：文本成功粘贴到 TextEdit、Chrome 地址栏、VS Code、微信输入框、飞书。某个 App 失败时，才加对应的延迟或改用 HID 事件源，并用 `ponytail:` 注释写明是哪个 App 需要。
5. 连续重新编译 5 次，辅助功能授权仍然有效。
6. 热键实验：Tauri 版运行、占用同一组合时，确认两边都会响应（非独占的预期行为）。再用 `kEventHotKeyExclusive` 注册试一次：如果能稳定拿到错误，就改成独占注册（改一个 flag），让快捷键 Tab 能显示冲突；拿不到就保持非独占。

### M2：剪贴板数据层
**交付物**：`Database`、`ClipboardWatcher`、过滤、隐私标记、来源 App、富文本、图片和缩略图、OCR、`ClipboardStore`（合并、裁剪、字节预算）、搜索、退出和锁屏清空，以及测试 target。

**验收标准**
1. 单测覆盖并通过：Luhn、`sk-`、bearer 过滤；合并去重；保留规则；条数和天数裁剪；片段占位符；内容形态识别；搜索。
2. 手测：
   - 从 1Password 复制的内容、带 ConcealedType 的内容都不入库。
   - 文本、RTF、图片、多个文件各复制一次，各生成 1 条。
   - 连续复制相同内容不会产生重复条目。
   - 中文截图复制后，能通过 OCR 文字搜到。
   - 锁屏后普通历史被清空，收藏保留。
3. **App Nap**：App 空闲 10 分钟以上、没有任何窗口可见时，1 秒内依次复制 A、B、C，三条都要入库。漏了就在采集开启期间持有 `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`（关闭采集时 end），然后重测第 4 条里的空闲 CPU。
4. 性能：塞入 5000 条后，启动加载少于 300ms（用 `os.Logger` 计时）；在主线程搜索 5000 条时输入不卡顿（卡了才把搜索挪到 `@concurrent`）；空闲时 CPU 占用低于 1%；复制一张 20MP 图片时界面不卡顿。
5. **剪贴板隐私实测**：`defaults write com.yy.kitty-tools.native.dev EnablePasteboardPrivacyDeveloperPreview -bool yes` 后，确认只读 `changeCount` 和 `types` 是否会触发弹窗、读内容时的弹窗表现，以及四种 `accessBehavior` 取值下通用页卡片是否正确。重置用 `tccutil reset Pasteboard com.yy.kitty-tools.native.dev`（这个 service 名同样要实测）。实测结论写进 §9 和 `mac-clipboard` 技能。

### M3：剪贴板界面全部功能 + 设置窗
**交付物**：面板界面、筛选、分组管理、键盘操作、多选、各种对话框、预览；`SettingsWindow`、`HotKeyRecorder`、剪贴板 Tab、快捷键 Tab。结束时写 `mac-clipboard` 技能。

**验收标准**
1. 按 §5.1 表格逐行勾选完成。重点检查：⌘1–9 与 `pasteOnEnter` 的联动、⇧点击区间选择、删除后 5 秒撤销、编辑内容后富文本被丢弃、「纯文本粘贴」只写了 `.string`、⌘C 在搜索框有选中文字时交给系统、粘贴后再次打开面板时搜索和筛选已重置。
2. 设置窗：Safari 在前台时，分别从菜单栏菜单和剪贴板面板的齿轮打开，设置窗都在最前面；打开前两个面板已收起；出现 Dock 图标，关闭后消失。
3. 快捷键录制：15.2+ 上允许只带 ⌥ 的组合；注册失败（例如 -9868）时快捷键 Tab 显示错误；「清除」后菜单显示「未设置」，热键不再响应。

### M4：翻译核心、浮窗、智谱内置、AI 服务、偏好与密钥导入
**交付物**：`SelectionReader`、`LanguageResolver`、`TranslateCoordinator`、浮窗界面、智谱和 AI 服务（openai / azure / anthropic 三种协议、关闭思考分档、SSE）、`Keychain`、翻译历史和历史面板、复制即译、剪贴板预览里的「翻译」按钮、`LegacyImport` 的偏好和密钥部分（通用页先放导入按钮）。结束时写 `mac-translate` 技能。

**验收标准**
1. 单测：`LanguageResolver` 的全部分支；SSE 解析（`<think>` 标签跨 chunk、去引号、错误事件、`[DONE]`）；原文预处理；max_tokens 按 host 取值（照搬 Tauri 的 `max_tokens_rules` 测试）；本机 host 判定。
2. 分别在 Safari、Chrome、VS Code、Pages、微信里划词后按 ⌥D：
   - 浮窗显示原文，译文逐段流式出现；
   - 划词前后用户的剪贴板内容不变，原生和 Tauri 的剪贴板历史里都没有新增条目；
   - 连续快速划词两次，两路译文不会交错。
3. 浮窗固定且处于 key 状态时，在 Safari 选中文字后按 ⌥D，能取到词。
4. Esc：历史面板开着时只收起面板；未固定时关闭浮窗；固定时不关。
5. 从翻译浮窗的齿轮打开设置窗，Safari 在前台时设置窗也在最前面。
6. 没有辅助功能授权时，划词会给出引导卡片。
7. 本机 Ollama（127.0.0.1）能调通；局域网上的大模型也能调通（第一次会弹一次本地网络授权）。
8. 从本机真实旧配置导入：已有的 AI 实例能直接翻译；百度、有道的凭据出现在钥匙串里；`defaults read com.yy.kitty-tools.native.dev` 的输出里没有任何密钥。

### M5：其余 7 家服务和翻译设置 Tab
**交付物**：百度、有道、Google、DeepL / DeepLX、微软、火山、腾讯；翻译设置 Tab 全部功能；这些服务的凭据导入。

**验收标准**
1. 有真实密钥的服务（本机：百度、有道、AI 实例）「验证连接」能返回示例译文；微软免 Key 路径直接实测；其余没有密钥的服务如果你能提供测试 Key 就实测，否则只靠第 2 条单测。
2. 用厂商文档里的示例数据写的签名单测通过：百度 MD5、有道 v3、火山 HMAC-SHA256、腾讯 TC3；DeepL 源/目标语言码映射单测通过。
3. `log show --predicate 'subsystem == "com.yy.kitty-tools.native.dev"'` 的输出里找不到任何密钥。

### M6：旧数据导入、收尾、发布 0.1.0
**交付物**：`LegacyImport` 的数据部分；通用页（权限卡片、剪贴板访问卡片、导入按钮）；开机自启；关于页和更新日志；0.1.0 发布（2026-09-27 起：本仓库正式 release，见 §8.5）。

**验收标准**
1. 用本机真实旧数据导入：导入结果里「新增 + 合并 + 跳过」= 旧库 `SELECT count(*) FROM clipboard_history WHERE favorited=1 OR kind='snippet' OR group_id IS NOT NULL`；收藏、片段、分组、备注都在，图片能预览；翻译历史里旧库的收藏仍是收藏；第二次导入全部计入「合并」，不产生重复。
2. Tauri 已退出时导入成功；Tauri 运行中导入也成功，或者明确提示「请先退出旧版」，不会导进半截数据。
3. 导入前后，旧库文件（含 `-wal`、`-shm`）的 mtime 不变。
4. `security find-generic-password -s com.yy.kitty-tools.native -a baidu.secret` 能找到条目；`defaults read com.yy.kitty-tools.native` 的输出里没有任何密钥。
5. 在另一台机器或另一个 macOS 15 用户账户上，从本仓库的 GitHub release 下载 DMG 全新安装，首次启动流程能走通。
6. ~~GitHub prerelease 发布后，在 master 工作区运行 `pnpm release:verify` 仍然通过。~~（2026-09-27 废止：原生版发在本仓库，不碰 Tauri 仓库）

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

| 风险 | 表现 | 缓解 |
|---|---|---|
| 剪贴板隐私（macOS 15.4+ `accessBehavior`） | 一旦系统强制执行，后台读剪贴板可能弹窗。15.4–15.7 以及目前的 26.x 默认都没有强制执行，大多数用户读到的是 `.default` | 通用页按状态处理（见 §5.3）：`.default` 不显示卡片，因为这时本 App 根本不在系统设置面板里。Apple 只保证 `detect*` 系列方法不通知用户；读 `changeCount`/`types` 会不会触发弹窗，以 M2 实测为准，测出结果前不做假设。开发者预览开关据报道在 26.2 已废弃，只在 15.4–15.7 上能用 |
| TCC 授权随重新编译失效 | 辅助功能开关看着是开的，实际没有生效 | 固定 Team；用 `codesign -d -r-` 自检；卡住时执行 `tccutil reset Accessibility <id>` |
| 钥匙串访问弹窗 | 签名一变就弹「想要访问钥匙串」 | 固定签名身份；从路径 B 切到 A 时会弹一次，接受 |
| NSPanel 焦点 | styleMask 在初始化后修改不生效；应用处于非激活状态时 resignKey 的时机不可靠；从剪贴板面板唤起翻译浮窗时两个面板互相关闭 | styleMask 在 init 里一次写全；剪贴板面板用鼠标监听判断点外，不依赖 resignKey；兄弟窗口在点击时实时判断；M1 用手测清单打通；翻译浮窗出现「刚显示就被隐藏」时再加抑制期 |
| 中文输入法 | 非激活面板里候选窗位置不对；组字时按 Enter 被误当成提交 | 输入框用 `NSTextField` / `NSTextView` + `doCommandBy`（组字期间不会回调）；M1 实测拼音、双拼、日文 |
| 粘贴回原 App 失败 | 热键的 ⇧ 还按着，发出去的是 ⌘⇧V；Electron 应用协商剪贴板格式较慢 | ⌘V 事件显式设 `flags = .maskCommand`；先不加任何等待，按 M1 实测结果逐个 App 补延迟，并用 `ponytail:` 注释写明原因 |
| 划词取词 | Chromium/Electron 的 AX 返回空；自家面板是 key 窗口时，AX 和 ⌘C 都落在自家面板上；延迟提供（promised）的数据无法完整还原；AX 调用卡住；先显示浮窗会把原 App 的选区取消掉 | AX 读不到时先交还焦点、激活快照 App、再读 AX，最后才用 ⌘C 兜底；promised 数据接受还原不完整；AX 放进 `@concurrent` 并设超时；「复制完成前不显示浮窗」写进 `mac-overlay-panel` 的红线 |
| 全局热键 | `RegisterEventHotKey` 默认非独占：和别的 App 注册同一组合时注册会成功，按一次两个 App 都响应。只带 ⌥ 或 ⌥⇧ 的组合只在 15.0–15.1 上被拒（-9868），15.2 起已恢复 | ~~共存期间在 Tauri 设置里清空剪贴板、划词、输入翻译三个热键（原生不导入热键，用同样的默认组合）~~（2026-09-26：共存期结束，默认改为剪贴板 ⌥C、划词翻译 ⌥D）；M1 实验 `kEventHotKeyExclusive` 能否检测冲突；录制器不按组合一刀切，直接注册并把 -9868 映射成提示 |
| ~~与 Tauri 版共存~~（2026-09-26：共存期结束） | 两边的 watcher 都会采集剪贴板；两边都开复制即译时，一次 ⌘C 弹两个浮窗；一方的自动复制、粘贴、划词还原会进另一方的历史 | 原生自己写剪贴板时一律加 `org.nspasteboard.TransientType`，Tauri watcher 会跳过（`R/privacy_markers.rs:38-42`）。共存期操作：Tauri 只保留 ⌘⇧S 截图翻译（本机 500 条翻译历史里 358 条是截图翻译），关掉 Tauri 的复制即译。Tauri 的自动复制如果开着，截图翻译的译文会进原生的历史，接受或者关掉它 |
| 多实例 | 从 DMG 里运行一份、/Applications 再启动一份，热键重复、两个进程写同一个库 | 启动时检查同 bundle id 的其它实例（§4） |
| App Nap | 空闲时 timer 被降频，连续快速复制可能漏条 | M2 实测，漏了再持有 `beginActivity` |
| 旧库导入 | WAL 库只读打开失败；Tauri 运行中复制可能拿到写到一半的副本 | 复制到临时目录后读写打开，`PRAGMA quick_check` 不通过就中止并提示先退出旧版（§6） |
| Gatekeeper | 没有 Developer ID，第一次安装要手动放行 | D7 长期如此；发布说明固定写「仍要打开」和 `xattr` 两种做法；之后走 App 内更新（D8）不用再放行 |
| ~~Tauri 更新被影响~~ | 2026-09-27 起原生版发在自己的仓库（YyAdnBug/kitty-tools），不再影响 Tauri 仓库的 latest | 本仓库正常标 latest |
| ATS 与本地网络隐私 | http 地址被 ATS 拦截；访问局域网 LLM 时弹授权 | 设置 `NSAllowsArbitraryLoads` 和 `NSLocalNetworkUsageDescription`；127.0.0.1 不受影响 |
| Swift 6 严格并发和 C API（Carbon、AX、sqlite3） | 编译报错一大片 | 和 C 交互的代码只放在 `HotKeyCenter`、`Database`、`SelectionReader` 三个类型里；主线程回调里用 `MainActor.assumeIsolated`；禁止用 `@unchecked Sendable` 糊过去 |
| LSUIElement 应用的设置窗 | 窗口被压在其它 App 后面；固定的浮层盖在设置窗上面 | 先收起两个浮层，再切 `.regular` 并 `activate()`；macOS 14 起激活是协作式的，M3/M4 从三个入口实测，不行就退回 `activate(ignoringOtherApps:)` |
| 没在 macOS 26 上测过 | 开发机是 15，看不到 Liquid Glass 下的效果 | 标准控件会自动适配；浮层材质只用 `.regularMaterial` / `NSVisualEffectView`；发布前找一台 macOS 26 实机或虚拟机检查一遍浮层 |
| 内置密钥 | 内置智谱 key 可以被提取 | 只放在不入库的 `Secrets.xcconfig` 里（安全性与 Tauri 版相同） |
| 大数据量性能 | 5000 条 × 8KB 在主线程搜索 | 保留上限默认 100、本机 500；M2 用 5000 条实测，卡了再挪到 `@concurrent`；列表查询不取 `rich_data` |

---

## 10. 以后迁移启动器和截图时要提前知道的约束

这里只列约束，现在不写任何脚手架。

**启动器与截图工具的迁移计划（2026-09-24 定，按用户真实使用数据排优先级）**

用户数据：启动器 3 个月 834 次，网址 82%（书签 / 手输）、App 次之，文件 8 次、kill 7 次、系统命令 0 次；截图历史 24 条里 5 条有标注、全是矩形，美化 / 水印 / 长截图 / 整屏 0 次，钉图 24 次（至 09-17），08-13 后没存过文件；热键 ⌥Space / ⌥A。

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M7 启动器核心 | `OverlayPanel`（`topAnchored` + `setContentHeight`）、App 目录（文件名 / 显示名 / 中文名 / 拼音全拼与首字母）、内置动作、匹配分档（含跨词首字母 vsc）、`launcher_usage` 使用记录（τ 全局 14 天 / 查询 3 天）、最近使用、旧 JSON 导入、与剪贴板面板互斥 | 已完成 |
| M8 启动器补全 | Chrome / Edge / Brave 书签（导入时还原被转小写的网址）、网址 / 路径直达（展开 `~`、认 localhost:端口、`Safari.app` 不算网址）、网页搜索（关键词直达 + 兜底，不记使用）、计算器（递归下降，不用 NSExpression）、`cb`（`ClipboardStore.search` 取文本前 30 条）、设置 › 启动器 | 已完成；M9 起按 Alfred / iShot Pro 对标调研重排 |
| M9 截图框选 + 输出 | 抽出和截图翻译共用的会话（权限 → 冻结 → 框选）；`RegionSelector` 加截图模式：悬停高亮窗口 / 单击截整窗（冻结时拍按 Z 序的窗口快照，§11 #41）、确认后 8 手柄调整 + 方向键微调 + 按住空格平移 + 尺寸标签、放大镜取色（C 复制色值）、D / ⌥X 重拍上次区域；输出 ↩ 复制（同时进剪贴板历史）/ ⌘S 快速保存 / 另存为 / T 钉图；钉图（缩放、透明度、双击或 Esc 关、菜单栏「隐藏全部」） | 已完成（实现要点见下方「截图（Phase 3）」） |
| M10 标注 + 识字 | 矩形、箭头、文字、马赛克 + 撤销（标注存整屏坐标，调整选区不丢）；工具栏识字 / 翻译按钮；独立识字热键（静默复制、二维码用 Vision `DetectBarcodesRequest`、去换行） | 已完成（实现要点见下方「截图（Phase 3）」） |
| M11 启动器网址线 + 键盘（对标 Alfred） | 自定义网页搜索（增删排序、多预置引擎）、Quicklink（固定网址 + 别名 + {query}）、兜底列表配置、⌥↩ 访达搜索 / ⌃↩ 网页搜索（按住修饰键换副标题）、Tab 补全（计算结果写回接着算）、cb / 计算结果 ↩ 粘贴、清空 / 单条重置学习记录、呼出时切英文输入法（开关，默认关） | 已完成（实现要点见下方「启动器网址线（M11）」） |
| M12 翻译补强（对标 Bob） | 窗口快捷键（⌘R 重试、⌘S 收藏、⌘W 关、⌘P 钉住、⌘+/- 字号、⌘1–9 复制第 N 张卡）、用译文替换原文（按钮 + 静默热键，默认不设键）、浮窗高度随内容、卡片折叠状态持久化、收藏筛选与导出 | 已完成（实现要点见下方「翻译补强（M12）」） |
| 长截图（2026-09-25 插入，用户改主意） | 截图框选后 S / 工具栏进入；实时画面上边滚边拼（往下、往上都行）、侧边预览、空格自动滚动；↩ 复制 / ⌘S 保存 / ⇧⌘S 另存为。原生实现，不参考旧版 | 代码已完成，待手测（实现要点见下方「长截图」） |
| M13 动作面板 + 文件 + 进程 | → / ⌘K 动作面板（打开方式、在访达中显示、复制路径、移到废纸篓，只放零授权动作）；⌘Y Quick Look（先验证 `QLPreviewPanel`，不行嵌 `QLPreviewView`）；open / find 文件搜索（NSMetadataQuery）；kill（GUI App 用 `terminate()`，⌘↩ 才强杀）。quit / hide / forcequit 不做（D2） | 文件搜索已完成（待手测，实现要点见下方「文件搜索（M13）」）；动作面板、⌘Y、kill 待做 |

**已拍板（2026-09-24，对标调研后用户选定）**：
- D1 长截图、录屏：~~都不做~~ → **长截图做（2026-09-25 用户改主意，要求按 macOS 原生方式实现、不参考旧版）；录屏仍不做**（以后真要录屏用 `SCRecordingOutput` 单独立项）。原先顾虑的两点已解决：冻结帧只管框选，框完收起遮罩再在实时画面上截；不用 15.2 的 `captureImage(in:)`，用 14.0 的 `captureImage(contentFilter:configuration:)` + `sourceRect`。
- D2 系统命令：**都不做**（锁屏、睡眠、推出磁盘、重启、关机、清空废纸篓、切深浅色，以及退出 / 隐藏 / 强制退出 App 都不做，2026-09-25 用户确认；以后再考虑）。
- D3 文件动作面板与 Quick Look：**动作面板进 M13，只放零授权动作**；⌘Y Quick Look 先验证 `QLPreviewPanel` 在不激活面板里能否拿到控制权，不行改嵌 `QLPreviewView`；不做目录导航和多文件缓冲。
- D4 查词 / 生词本：**M12 之后，只用系统能力**：系统词典（`DCSCopyTextDefinition`）+ 单词模式提示词；生词本 = 收藏筛选 + CSV / TSV 导出；不引入 ECDICT。**已完成（2026-09-26，待手测）**，规则见 mac-translate §5.2。

**开源参考（只借鉴思路，不拷代码）**：
- macshot（github.com/sw33tLie/macshot）：**GPL-3.0**，任何代码 / 文案 / 逐行改写都不能进仓库。约 6 万行 AppKit，截图 / 标注 / 钉图 / 识字 / 长截图 / 录屏都有，可看交互细节。
- Snapzy（github.com/duongductrong/Snapzy）：BSD-3-Clause，同样只借鉴思路。
- 可借鉴：多屏冻结帧用 TaskGroup 并发截（我们已排除自家窗口，比它们先藏窗口更稳）；`CGWindowListCreateImage` 在 15 SDK 已标废弃、不能用；标注用值类型 + 显示与导出共用一个 draw；文字工具叠一个 NSTextView 编辑完再提交；钉图用不激活的 NSPanel、以鼠标为锚点缩放。
- 本机调研原始记录（不入库）：`macos/build/research/`（对标路线 benchmark-roadmap.md、Alfred / iShot / Bob 明细、macshot / Snapzy 源码研究、旧版启动器 / 截图行为清单）。

**不迁**：系统命令（锁屏已坏 §11 #24，且要 Apple Events 授权）、ts / b64 / url / case / uuid / ip 小工具、网站图标、Safari / Firefox 书签；延时、美化 / 水印、比例条、Enter 全屏、焦点窗口截图、窗口置顶、屏幕清洁、WebP；截图历史与钉图历史（复制的截图进剪贴板历史，作为唯一的历史）。
- 热键：启动器 ⌥Space、截图 ⌥A（用户实际用的键）；编辑器工具键不带修饰的 1–4、钉图 T（沿用用户改键），不做编辑器内改键。⌥Space 只在 15.0–15.1 上注册失败，录制器已提示。

**启动器网址线（M11，2026-09-25）**
- 网页搜索和快捷链接是**同一张列表**（`SearchEngine`，偏好里的 JSON，字段沿用旧版）：网址里有 `{query}` 的是搜索（「关键词 空格 内容」直达、勾「兜底」的按列表顺序兜底；单输关键词时最前面出一条 `.prompt`「↩ / Tab 补全关键词」，输名字 / 拼音开头时这条提示排在本地结果后面，不抢同名 App；关键词 cb 留给剪贴板指令），没有 `{query}` 的是快捷链接（名字 / 关键词 / 拼音搜到，↩ 打开网址或 / ~ 路径，记成 .url / .path 进使用记录）。旧版设置页强制要求 `{query}`，旧数据不受影响；以前「漏写 {query} 追加到末尾」的兜底去掉。
- 预置 13 个（Google g、Bing、百度 bd、GitHub gh、知乎 zh、哔哩哔哩 bili、维基 wiki、YouTube yt、地图 map、淘宝 tb、京东 jd、豆瓣 db、MDN），新装默认前 8 个、前 3 个兜底；已有列表不自动加，设置里「添加」菜单挑。
- 兜底默认只在没有本地结果时出现，可改成总是附在最后（`launcherFallbackAlways`）。
- 键盘：↩ 计算结果 / cb 粘贴回原 App（无辅助功能授权时只复制并提示）；⌘↩ App / 路径在访达中显示、计算结果 / cb 只复制；⌥↩（`insertNewlineIgnoringFieldEditor:`）`showSearchResults(forQueryString:)`；⌃↩（`insertLineBreak:`）用第一个兜底搜索；按住 ⌘ / ⌥ / ⌃ 时（`onModifierKeysChanged`）选中行副标题换成替代动作；Tab（`insertTab:`）补全：计算结果、目录「路径/」、搜索「关键词 」、App / 动作 / 网址补标题；程序改输入框文字后光标放末尾。
- ↩ / ⌥↩ / ⌃↩ 先确认是回车键（⌃O 等别的键绑定也会发这两个选择器，吞掉）；cb ↩ 自己写剪贴板 + ⌘V + 置顶，不借剪贴板面板的 paste（会收起钉住的面板、提交可撤销的删除）；计算器认科学计数，Tab 写回的大 / 小结果能接着算；输入的网址 Tab 保留原样。设置页固定 640 高、表单自己滚。
- 学习记录：「最近使用」里 ⌘⌫ 忘掉一项（有查询时 ⌘⌫ 照常删到行首）；设置里「清空使用记录…」。
- 呼出时切英文输入法（`launcherRomanInput`，默认关）：搜索框字段编辑器的 `allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]`，离开后系统恢复；关掉时显式设回 nil（字段编辑器整个窗口共用）。

**文件搜索（M13，2026-09-26）**
- 对标 Alfred（Raycast v2、macOS 26 聚焦搜索为辅），用户拍板：`open 词` 打开、`find 词` 在访达里选中（`activateFileViewerSelecting`，修 §11 #28），⌘↩ 两者互换；空格开头 = open；只输 `open` / `find` 时出「↩ / Tab 补全关键词」提示（同网页搜索关键词，不抢同名 App；open / find 和 cb 一样是保留关键词）。普通搜索不混排文件（打开过的文件照样靠使用记录搜到、进「最近使用」）；in（内容）/ tags、⌘Y、目录导航、自定义关键词、可编辑排除目录不做。
- 查询（`Launcher/FileSearch.swift`，本机实测）：每个词一个 `kMDItemFSName == "词*"cdw` 用 && 连（中文按词切、**拼音也能命中**），加 `kMDItemSupportFileType != "MDSystemFile"`（去掉 ~/Library 的绝大部分），范围只用主目录，按修改时间降序；≥ 2 个字 P50 约 40 ms。子串写法「ab」要 1–17 s、1 个拉丁字母要 1–7 s → 1 个字母不查（提示「再输入一个字母」），1 个汉字照查。`kMDItemPath` 进不了谓词，路径在客户端滤：主目录外、~/Library（iCloud 云盘、CloudStorage 除外）、node_modules / build / DerivedData / dist / target / out / Pods / Carthage / vendor / venv / __pycache__ / coverage；隐藏文件、包内部 Spotlight 本来不收。只读路径每条约 3 µs，最多处理 2 万条（「readme」6000 多条里九成在 node_modules，只看前 2000 条会漏）；预取名字 / 类型 / 日期（每条每个属性单取约 0.2 ms）。
- 最近的文件（只输关键词或一个空格）：`kMDItemLastUsedDate` 30 天内 ∪ 14 天内下载的（`kMDItemWhereFroms` + `kMDItemDateAdded`），约 70 ms。「最近修改 / 添加」不能用：代码目录在桌面，全是源码；上次打开时间只有千分之一的文件有，只够做「最近」。
- 排序：匹配分 × 使用加成（同启动器公式；Spotlight 靠驼峰 / 中文词中间命中、我们匹配分为 0 的给底分 30）→ 最近一次打开 / 修改 / 下载 → 路径浅；最多 50 条。前面放整句（连关键词）匹配到的 App / 内置动作（「find my」→「查找」，修 §11 #38），空格开头不放。
- 结果分批到：查询中留着上一次的结果（不闪空、不闪「没有匹配」），同一查询的后续批次保持选中项；过期查询的结果丢掉；收起面板停查询。
- 行：图标按 Spotlight 类型（`NSWorkspace.icon(for: UTType)`，不碰文件）、副标题是所在文件夹（iCloud 云盘写成「iCloud 云盘/…」）、右侧扩展名大写或「文件夹」；Tab 直接补路径（文件夹带 /，不 stat）。⌥↩ / ⌃↩ 搜去掉关键词后的词。
- **授权（实测，用户选「按需申请」）**：Spotlight 按调用方的「文件和文件夹」授权过滤结果，没授权的文稿、下载、iCloud 云盘一条都没有，也不弹框（本 App 身份：文稿 / 下载 / iCloud 0 条；Claude.app 身份：都有）。所以文件结果最后一行是授权提示（橙色锁）：没问过 → ↩ 收起启动器、逐个 `opendir` 桌面 / 文稿 / 下载 / iCloud 云盘让系统弹框（主线程停到用户点完），刘海岛报结果；问过有被拒的 → ↩ 打开系统设置 › 文件和文件夹。问过之前一律不碰这些目录（`Prefs.folderAccessRequested`）。设置 › 启动器「文件搜索」有一行状态（`PermissionRow`）。Info.plist 补了桌面 / 文稿 / 下载的用途说明。

**翻译补强（M12，2026-09-25）**
- 浮窗快捷键在 `TranslateCoordinator.handleKeyEquivalent`（接到 `OverlayPanel.keyEquivalentHandler`）：⌘R 重新翻译、⌘S 收藏 / 取消（第一个服务出结果后）、⌘W 收起（固定着也收）、⌘P 固定、⌘+（含 ⌘⇧=）/ ⌘- / ⌘0 字号（0.8–1.6 倍，存 `translateFontScale`）、⌘1–9 复制第 N 张卡；⌘C / ⌘V 等编辑键仍给输入框。原文里 ⇧↩ / ⌘↩ 换行（⌘↩ 系统发的是 `noop:`，在 doCommandBy 里接）。
- 收藏 = 生词本：星标 / ⌘S 按「原文 + 实际目标语言」写 translations 表（关了历史也能收藏，连译文记一条）；历史里可只看收藏；设置 › 翻译「导出…」：全部 / 只收藏 × CSV（带 BOM，Excel 认 UTF-8）/ TSV（Anki：正面原文、背面译文，换行写成 `<br>`）。
- 替换原文：划词时记下前台 App 的 pid 和原选区（`replaceSource`），会话里显示「替换原文」按钮（收起浮窗 → `Paster.write` → ⌘V）；静默热键「划词翻译并替换」（默认不设键，翻译中再按一次取消）：取词 → `translateOnce`（只用第一个服务、等完整结果、不合并换行、记历史）→ 粘回，全程轻提示。两条都按原选区补回首尾空白（`rewrap`，三击整行不吞段落），**前台已不是取词的 App 或自家浮层成了 key 时只复制不粘**；`OverlayPanel.present` 每次重记 previousKeyPanel，收起浮窗不会把 key 还给不相干的面板。
- 导出：CSV 按 Unicode 标量判断要不要加引号（Swift 把 \r\n 当一个字符）、= + - @ 开头加 '、时间写本地时间；Anki TSV 带 `#separator:tab` / `#html:true` 头，字段 HTML 转义、各种换行写成 `<br>`、含引号或以 # 开头的加引号。关着历史时取消收藏会删掉那条。
- 高度随内容（Bob 的做法，只让人拖宽度：min / maxSize 的高度钉在当前值）：视图量出顶栏 + 原文区 + 卡片内容的高度，`setContentHeight` 夹在 220 到屏幕可见区 85% 之间；`setContentHeight` 往下出屏就整体上挪。卡片折叠按服务 id 存 `translateCollapsedServices`，不再因出结果自动展开。

**长截图（2026-09-25）**
- 入口：截图框选后按 S 或工具栏「长截图」（选区至少 60 点高，否则提示音）；标注不带过去。框选会话交回 `Outcome.scroll(选区)`，不裁图（裁出的图会拖住整屏冻结帧直到长截图结束）。遮罩收起（冻结帧只管框选），`AppDelegate.scrollCapture` 在 `beginCapture` 里跑，整个过程 `isCapturing`，别的截图热键不响应。独立热键、启动器动作没做（要时再加）。
- 抓帧（`ScrollCapture`）：`SCContentFilter(display:excludingApplications:[本 App])`（之后才建的边框、面板也滤掉，钉图也不进长图）+ `SCStreamConfiguration.sourceRect`（屏内、点、原点左上，对齐到像素）+ 宽高 = 选区像素，不画光标；`SCScreenshotManager.captureImage` 手动滚时每 40 毫秒一帧、自动滚时每步 160 毫秒。拼接在主线程（1600×1400 帧 < 10 毫秒）。
- 拼接（`ScrollStitcher`，纯逻辑、单测锁住）：逐行哈希（右边 16 点滚动条不比）投票，最高票 ≥ 6、≥ 第二名 2 倍、≥ 重叠可比行 25% 才接；纯色行、帧内重复超 8 次的行、原地不变的行不投票。画布记每帧位置，往下、往上都能接（聊天记录），往回滚只挪位置；吸顶栏 / 页脚：长图 =「最上面那帧的吸顶栏 + 内容 + 最下面那帧的页脚」，页脚取「原地不变的尾行」和「对上的最后一行以下」中大的（页脚里光标闪烁时前者估小，会在长图中间留下页脚碎片，单测锁住）；回弹：刚接过的那头往回滚时，画布那头和新帧那头逐字节相同的行（页脚、还露着的越界底色）换成新帧的，再往里多出来的行全是纯色才去掉，有字的行一行不丢（真实的多帧回弹、小幅回滚都有单测）。上限 30000 像素高、4000 万像素（= 剪贴板历史收图上限，复制后能进历史）。
- 选型实测（合成页面：吸顶栏、页脚、浮动滚动条、动画块、光标、半像素、往上滚，150 对帧）：逐行哈希投票零误接；Vision `VNTranslationalImageRegistrationRequest` / `TranslationalImageRegistrationRequest` 有吸顶栏时 50%–90% 算错、置信度却恒为 1，不能用；容差行签名更慢、召回更低。原始记录在 scratchpad，不入库。
- 界面：选区外 2 点强调色边框（`ignoresMouseEvents`，滚轮落到下面的窗口；状态栏层级，低了会被 AppKit 挪到菜单栏下面）；侧边面板 `ScrollCapturePanel`（不激活、能当 key），贴选区右边、和选区一样高（放不下放左边，再放不下以 320 点高放进选区右上角），内容：预览（最近接的那头，最多每 0.2 秒重画）、状态、尺寸、按钮（自动滚动、取消、另存为、保存、复制）。按键：↩ / ⌘C 复制、⌘S 保存、⇧⌘S 另存为、空格自动滚动（按住不重复开关）、Esc 取消；点了目标 App 后面板不再是 key，鼠标移回面板就拿回键盘（不激活本 App），按钮一直能点；状态文字不可选中（否则点一下就抢走第一响应者）。对不上时橙色提示「往回滚一点，再慢慢滚」，拼上新内容后恢复。
- 自动滚动：要辅助功能授权（没有就提示并申请）；光标不在选区里或停在面板上，先挪到选区中间，按下就先滚一步；发像素级滚轮事件到 HID 层（交给光标下的窗口）；每步目标滚出选区 40%，按实测位移调步长；对不上就退回、步子减半，连续 4 帧对不上就停；实测位移和发出去的方向相反就翻转滚轮正负号；在已拼范围里滚也算在动，只有连续 3 帧不动（到头）才停；光标移到面板附近（去点 ⏸）只暂停不停，移出选区到别处就停；方向跟着用户手动滚的方向；截屏出错后抓帧停止，只能复制 / 保存 / 取消。
- 输出沿用截图的 `copyImage` / `saveImage`（复制进剪贴板历史；保存失败改放剪贴板）。

**截图（Phase 3）**
- 屏幕录制权限（TCC）：用 `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 检查和申请，同样绑定签名。授权提示由系统提供，App 不能自定义文案（没有对应的 Info.plist 键）。macOS 15 会周期性地再次询问屏幕录制授权。
- 保留冻结底图的铁律：按下热键后先截整屏（ScreenCaptureKit `SCScreenshotManager`，macOS 14+），框选、取色、裁剪都只读这一帧；禁止改回「框选之后再截屏」。
- 遮罩窗口：每块屏幕一个无边框窗口，层级要高于菜单栏；注意 AppKit（原点在左下）和 CG（原点在左上）的坐标换算，以及多屏拼接。全屏透明窗口的 backing store 是内存大头，不要让它常驻。
- **截图翻译已实现**（2026-09-24，提前到 Phase 1；用户决策：只用 Vision、原文写剪贴板历史、默认热键 ⌥S）：`AppDelegate.screenshotTranslate` → 屏幕录制授权 → `ScreenCapture.freeze`（每屏一张，当时排除自家浮层和设置窗、保留菜单栏图标；2026-09-26 起按留用名单截得到，见下条）→ `RegionSelector.select`（每屏一个不激活的无边框遮罩，层级高于弹出菜单；拖动框选，Esc / 右键取消；期间暂停全局热键）→ `OCR.recognizeText(in: CGImage)`（自动识别语种、不给语言提示）→ 原文过敏感过滤后记进剪贴板历史 → `TranslateCoordinator.translate` 走现有多服务翻译。截图标注（⌘⇧A）以后做时复用 `ScreenCapture` 和 `RegionSelector`。
- 热键：截图 ⌥A、截取上次区域 ⌥X（iShot 的默认键，可连按）、截图翻译 ⌥S（都是只带 ⌥ 的组合，15.0–15.1 注册不了时快捷键页会提示）。
- **截图已实现（M9，2026-09-24）**：`AppDelegate.screenshot` 与截图翻译共用 `beginCapture`（互斥、收起没固定的浮层）+ `frozenSelection`（授权 → 冻结 → 暂停热键框选 → 恢复）。
  - 冻结：`ScreenCapture.freeze()` 按 `keptOwnWindows` 留用名单留下本 App 开着的窗口（2026-09-26 起浮层、设置窗、钉图都截得到、能悬停选中），同一时刻用 `CGWindowListCopyWindowInfo` 拍窗口快照（从前到后，只要低于程序坞的层和展开的弹出菜单，去掉全透明、太小和不在留用名单里的自家窗口），悬停与单击按 Z 序命中（§11 #41）。
  - 遮罩画面全是图层：冻结帧是 `SelectionView` 自己图层的内容，暗色蒙层 / 边框 / 手柄 / 尺寸 / 放大镜是 layer-hosting 的 `Canvas` 上的 CALayer（M10 起标注层夹在两者之间），拖动时只改路径，不重画整屏；工具栏是 AppKit 按钮（`acceptsFirstMouse`），NSVisualEffectView 用 `.withinWindow`（模糊冻结帧，不是背后的真桌面）。
  - 交互：悬停高亮窗口，单击截该窗口（没有窗口截整屏）；拖动框选（按住空格整块平移）；确认后 8 手柄、拖动平移、方向键 1 点 / ⇧ 10 点，选区外单击不动（免得误点丢选区）、拖出新选区，右键回到待选、Esc 取消；尺寸标签显示像素。放大镜 15×15 像素、取样转 sRGB 显示 #RRGGBB，C 复制色值（同时记进剪贴板历史）。D 选中上次区域（按相交面积最大的屏放，外接屏拔掉时提示音）。
  - 输出：↩ / ⌘C / 双击选区 = 复制（PNG 带 DPI，经 `Paster.write`，自己记进剪贴板历史）；⌘S 快速保存到上次「另存为」的目录（旧版的 `screenshot_save_prefs.json` 可导入，没有时用系统截屏位置，再没有是桌面），文件名「截图 yyyy-MM-dd HH.mm.ss.png」、重名追加序号；⇧⌘S 另存为（遮罩已收起，激活本 App 弹 NSSavePanel，存完还前台）；T 钉图。裁出的图都拷成独立的图，不拖住整屏冻结帧。
  - **标注（M10）**：1–4 切矩形 / 箭头 / 文字 / 马赛克（再按一次收起，回到拖动平移选区），⇧ 画正方形 / 45° 箭头；6 种固定 sRGB 颜色 × 3 档粗细，默认红色中号（旧版用户全是红色 4 点矩形）。点中标注（矩形只认边线）可拖动、⌫ 删除、方向键挪、改样式（作用于选中项，§11 #47），双击文字重新编辑；⌘Z / ⇧⌘Z 撤销重做（数组快照栈）。标注存整屏视图坐标，调整选区不丢（§11 #43）；显示（标注层只重画变了的那块）和导出（`Annotation.render`）共用一个 draw。文字用叠在上面的 NSTextView 输入（输入法正常；Esc、点外面收下，↩ 换行）；马赛克从冻结帧缩小再不插值放大。
  - **识字（M10）**：⌥O 框选后静默复制（二维码 / 条码优先，`DetectBarcodesRequest`）；设置 › 截图可开「把换行合成一段」（整段合成一行：中日文直接连、其它加空格、行尾连字符接回；Vision 不分段落，要保留段落得按行框间距切，未做）；截图工具栏也有识字、翻译按钮，识别的是打码后的合成图（§11 #44）。结果记进剪贴板历史，用轻提示（2026-09-25 起是刘海岛 `Island`）反馈；⌘S 快速保存、复制色值也有轻提示。
  - 钉图 `PinPanel`：原位置出现、不激活本 App 也不抢键盘；拖动移动，滚轮 / 捏合以鼠标为锚点缩放（24 点到 5 倍），双击或 Esc（先点一下）关闭，⌘C / ⌘S / ⌘W / ⌘0，右键菜单含透明度；菜单栏有钉图时显示「隐藏 / 显示全部钉图」「关闭全部钉图」。
- **截图重设计（2026-09-26）**：方案页 https://claude.ai/artifact/WQFQonH4urad3hmnceBiko ，D1–D15 全部按推荐（交互对标 ⌘⇧5 / CleanShot / Shottr / iShot / Snipaste，控件全换品牌粉 `Style.Shot.accent`、HUD 刻度 `Style.HUD`），提交 `edb0758^..HEAD`。规格只看 mac-whisker §6「截图」，实现约束在 mac-overlay-panel §8–§10；上面 M9 / M10 里的「8 手柄」「1–4 四种工具」「6 色」已被取代：整条边和四角都能拖（`RegionSelector.handle`）、⇧ / ⌥ / 空格 / ⌃、吸附冻结时的窗口边和屏幕边（粉色虚线参考线）、⌘ / ⌥ + 方向键推收边、可输入的尺寸胶囊 `SizeField` + 比例菜单、两段 HUD 胶囊工具栏（10 个工具 + 撤销 / 重做 ｜ 识字 / 翻译 / 长截图 / 钉图 ｜ 保存 ▾ ｜ 取消 / 拷贝）、按工具的样式托盘（8 色 × 3 档 × 选项，按工具记在 `Prefs.screenshotToolStyles`）、标注编辑（画完自动选中、粉色手柄改大小、⌥ 拖动复制、⌘D、⇧ 锁轴）、Esc 逐级退、有标注时右键不清空、取消时遮罩淡出；截图翻译 / 识字的框选同一套外观。周边：飞行卡片 / 常驻缩略图 / 钉图 / 长截图换粉，钉图弹入改 display link 逐帧弹簧。交互用合成事件锁在 `SelectionInteractionTests` / `AnnotationEditingTests` / `ShotAccessibilityTests`；屏外自检 `ScreenshotSnapshotTests`（`TEST_RUNNER_KITTY_SNAPSHOT_DIR`，假桌面上约 50 张 2x PNG，含局部 `-crop`），看图修了：小数点选区的粉线发糊和洞边半像素暗边（选区外观按像素取整）、放大镜落在半像素上、尺寸胶囊放进选区时贴着左边盖住角手柄、提示胶囊两端多一道竖线（capsule 用 circular 圆角）、输入框选中底色是系统蓝（改粉）、保存角标写 Desktop（改访达显示名「桌面」）。真机手测清单见 §12「截图重设计手测」。

---

## 11½. Whisker 设计语言改造（2026-09-25 起）

用户看过方案页（https://claude.ai/artifact/1iPQSF1Vr6XswMp4mDkZyN）后拍板：「视觉、交互、动画非常完美，以后也要按照这个去执行……所有的效果我都要」。规范正文在 `.cursor/rules/mac-whisker.mdc`（技能 `mac-whisker`），这里只记计划与进度。

**决定**：方案页的 D1–D16 全部按推荐答案；「所有效果都要」= A、B、C、D 四个阶段都做（D8 常驻缩略图、D11 菜单栏动画也做，只是排在后面）。D1 原创角色等用户的素材。

| 阶段 | 内容 | 状态 |
|---|---|---|
| A 基础与招牌时刻 | A1 `Shell/Style.swift`（圆角、七条曲线、描边、减弱动态效果）；A2 `OverlayPanel` 进出与高度动画 + 无边框 16 pt（先验证 key / 输入法 / Esc / 点外关闭 / 粘贴 / 固定 / 拖宽）；A3 启动器与剪贴板共用的滑动选中 + 按住 ⌘ 键帽；A4 刘海岛替换 `Toast`；A5 截图飞入 + 快门声 + 窗口磁吸 + 新手柄；A6 译文显影 + 光标 + 骨架扫光 | 已完成（待手测） |
| B 界面重做 | 启动器单行 / 色块 / 计算卡 / 底栏；翻译语言胶囊 / 服务色块 / 彗星边框 / 错误卡；截图 HUD 工具栏 / 样式托盘 / 放大镜；剪贴板检查器卡片 / QL 缩略图 / ⌘K 面板；钉图打磨 | 已完成（待手测） |
| C 品牌 | App 图标、菜单栏角色剪影（等用户素材）、设置页头与控件分工、关于品牌页、DMG 背景 | 设置页头、控件分工、关于品牌页（随 D 的设置重做）、DMG 背景已完成（待手测）；App 图标与菜单栏剪影换成原创小黑猫「探头」（2026-09-26，`macos/brand-icons.swift` 生成，待手测） |
| E 截图重设计（2026-09-26） | 方案页 https://claude.ai/artifact/WQFQonH4urad3hmnceBiko 的 D1–D15 全部按推荐：选区手势、吸附与参考线、尺寸输入与比例、两段胶囊工具栏、10 个工具与样式托盘、标注编辑、Esc / 右键、周边换品牌粉、旁白与无障碍（提交 `edb0758^..HEAD`，要点见 §10「截图重设计」） | 已完成（屏外自检已看图修过，待真机手测，清单在 §12） |
| D 深度 | 长截图 HUD 与边框动效、标注渲染升级、链接富预览、⌘Y 放大预览、设置侧栏 + 搜索 + 实时预览 + 引导、菜单栏 `NSStatusItem` 动画、CleanShot 式常驻缩略图、Spotlight 挤压入场实验、macOS 26 玻璃 + `.icon` | 进行中：长截图 HUD 与边框、标注渲染升级、链接富预览、⌘Y 放大预览、设置（侧栏 + 搜索 + 页头 + 控件分工 + 权限动效 + 实时预览 + 关于品牌页 + 欢迎引导，含 C 阶段的设置部分）、菜单栏 `NSStatusItem` 动效、CleanShot 式常驻缩略图、Spotlight 挤压入场实验（启动器可选）已完成（待手测）；剩 macOS 26 玻璃 + `.icon`（等测试机） |

**交接（2026-09-26，新会话从这里接着做）**
- D 阶段除「macOS 26 玻璃 + `.icon`」（等 26 测试机）外全部做完并推送：标注渲染升级、链接富预览、⌘Y 放大预览、设置重做（连同 C 阶段的设置部分）、菜单栏 `NSStatusItem` 动效、CleanShot 式常驻缩略图、启动器挤压入场（实验）；C 阶段的 DMG 背景也做了。第一轮对抗式审查（标注 / 链接预览 / ⌘Y）确认的问题已修（`b175e80`）；第二轮（设置 / 菜单栏 / 常驻缩略图）确认的 16 条也已修（换页丢导入状态和 sheet、搜索词残留、减弱动态效果、预览卡死按钮、缩略图位置 / 钉长图 / 双击开临时文件 / 静止光标不悬停 / 小卡按钮重叠 / 拷贝冲掉「已保存」、菜单栏在角标出现时才弹等）。单测 107 个全过（另有 `TEST_RUNNER_KITTY_LIVE_LINK=1` 联网冒烟），lint 无输出。
- 各项的手测清单在 §12「待用户手测」里（标注外观 7–8、链接预览、⌘Y、设置、菜单栏、常驻缩略图、挤压入场）。
- C 阶段已全部完成（2026-09-26）：原创角色「探头」（方案页 https://claude.ai/artifact/QmFQcLjNPvgaN5xWiYtDNL ，用户在四个方向里选了 B：小黑猫扒在奶油色剪贴板卡片边上、低头看卡片），App 图标 10 张（16 / 32 px 手调）和菜单栏模板图 `StatusIcon` 都由 `macos/brand-icons.swift` 用 CoreGraphics 生成，替换了 Hello Kitty 和 cat 符号；关于页、引导、设置侧栏读的是 App 图标，自动跟着换。macOS 26 的 `.icon`（深色 / 着色版）等测试机。
- 验证手段：界面用 `SnapshotProbeTests`；窗口动画用不抢键盘的 scratch 程序实测（本轮用它确认了：窗口帧动画冲不过头且会忽略时长、`QLPreviewPanel` 不是 nonactivating、`isARepeat` 问鼠标事件会抛异常、主线程上逐字节 await `AsyncBytes` 每字节约 5 µs）。
- 打包：`macos/build-dmg.sh`（访达摆位要控制访达的权限，第一次跑会问；`DMG_LAYOUT=0` 跳过）。测试包 `macos/build/Kitty Tools Native_0.1.0_arm64.dmg`（`cfe5d65`，含 D 阶段全部、两轮审查修复、D4 查词、M13 文件搜索、截图框选整边拖动 / 10 种标注 / 周边换品牌粉，以及新的角色图标「探头」；从干净的 HEAD 临时 worktree 用 `DMG_LAYOUT=0` 打的，不含工作区里别的会话没提交的改动，没有背景摆位）。

## 12. 进度与交接（2026-09-24，新会话从这里接着做）

**已完成并推送到 `origin/macos-native`**（单测 69 个全过，`xcrun swift-format lint --strict` 无输出，Debug 构建零警告）：
- M0 工程骨架 / 规则 / DMG 脚本；M1 浮层、热键、粘贴；M2 剪贴板数据层；M3 剪贴板面板（原生重新设计）+ 设置窗 + 快捷键录制；
- M4 翻译核心（智谱、AI 三协议、划词、复制即译、历史、翻译浮窗与设置页、旧版偏好与密钥导入）；
- M5 其余 7 家服务（百度、有道、Google、DeepL/DeepLX、微软、火山、腾讯）+ 各服务设置表单 + 导入扩展到全部内置服务；
- M6 代码部分：`LegacyImport` 数据导入（保留类剪贴板条目 + 图片 + 分组 + 全部翻译历史，一个事务、可重复执行；本机真实旧库演练：保留 10 条全新增，翻译 500 条 → 新增 495、合并 5，第二次全部合并）；通用页（开机自启 `SMAppService.mainApp`、辅助功能与剪贴板访问状态、一键导入）；关于页（版本、发布页、随包 changelog）；首次安装打开通用页、更新后打开关于页（`lastSeenVersion`）；`MARKETING_VERSION = 0.1.0` + changelog 条目。

- 翻译语言模型重做（用户反馈「自动 - 自动」「英文 - 日语」混乱；调研 Bob / Easydict / Pot / DeepL / Google 后按 §11「翻译语言」实现，单测 54 个全过）。
- M7 启动器核心（§10 迁移计划）：⌥Space 呼出，App 目录（中文名 / 拼音 / 跨词首字母）、内置动作、使用记录与最近使用、旧版启动器记录导入、与剪贴板面板互斥。
- 截图翻译（提前到 Phase 1，§10）：⌥S → 冻结帧逐屏框选 → Vision 本机识字（自动识别语种、不给提示）→ 原文记剪贴板历史 → 多服务翻译；通用页加「屏幕录制」授权行；剪贴板图片 OCR 顺带修掉只认中英（§11 #21）。单测 58 个全过。

- M8 启动器补全（书签、网址 / 路径直达、网页搜索、计算器、cb、设置 › 启动器）及审查修复（兜底只在无本地结果时出现、结果去重等）。单测 69 个全过。

- M9 截图框选 + 输出（2026-09-24）：⌥A 截图 / ⌥X 截取上次区域，窗口悬停与 Z 序命中、调整选区、放大镜取色、复制 / 快速保存 / 另存为 / 钉图，启动器内置动作「截图」，旧版保存目录导入；对抗式审查确认的 12 条问题已修（多屏按键与选区、边界、钉图缩放、保存失败兜底、另存为不阻塞主线程等）。单测 74 个全过。

- M10 标注 + 识字（2026-09-25）：矩形 / 箭头 / 文字 / 马赛克 + 撤销重做、选中改样式、⌥O 识字（二维码优先、可去换行）、截图工具栏识字 / 翻译、设置 › 截图、轻提示；对抗式审查确认的 14 条问题已修（输入文字后焦点归还、栏间隙误触、残留草稿、输入法组字时输入框跟随、每个输入框独立撤销等）。单测 80 个全过。

- M11 启动器网址线 + 键盘（2026-09-25）：搜索与快捷链接一张列表（增删排序、13 个预置、兜底配置）、⌥↩ / ⌃↩ / ⌘↩ 替代动作与副标题、Tab 补全、计算结果 / cb ↩ 粘贴、单条移除 / 清空使用记录、呼出时切英文输入法。对抗式审查确认的问题已修（搜索提示抢同名 App、cb 粘贴收起钉住的剪贴板面板、设置页太高、⌃O 误触网页搜索等）。单测 83 个全过。

- M12 翻译补强（2026-09-25）：浮窗快捷键、收藏（生词本）与只看收藏、导出 CSV / Anki TSV、替换原文按钮与静默「划词翻译并替换」、高度随内容、字号、卡片折叠记住。对抗式审查确认的问题已修（替换粘错 App / 粘进自家面板、段落被吞、Anki / CSV 转义、⌘↩ 不换行、高度可拖等）。单测 87 个全过。

- 长截图（2026-09-25，用户改主意、要求原生实现）：截图框选后 S / 工具栏进入，边滚边拼（往下 / 往上）、侧边预览、空格自动滚动，↩ 复制 / ⌘S / ⇧⌘S；拼接选型先做了合成页面实测（逐行哈希投票零误接，Vision 平移配准不可用）。对抗式审查确认的 11 条问题已修（回弹修剪查错行会丢字、在已拼范围里自动滚动误报到底、点 ⏸ 反而重启、面板在选区里时滚轮发给自己、连续对不上一直倒退、按住空格反复开关、状态文字抢第一响应者、边框贴屏顶被挪位、长截图拖住冻结帧、超 4000 万像素不进剪贴板历史等）。单测 96 个全过。

- 修：启动器搜不到 Chrome 书签（2026-09-25）。新版 Chrome（本机 154）登录 Google 账号后把书签存进配置目录里的 `AccountBookmarks`，本机的 `Bookmarks` 变成空的（本机 432 条全在前者）；原来只读后者。现在每个配置目录两个文件都读（格式相同），单测锁住。Chrome 同时写了加密版（`EncryptedAccountBookmarks2`），哪天不再写明文就得解密（要钥匙串「Chrome Safe Storage」授权），到时再做。

**下一步（新会话从这里接着做）**：D4 查词、M13 文件搜索已完成（2026-09-26，待手测）；接下来 M13 的动作面板（→ / ⌘K）+ ⌘Y Quick Look + kill（§10），动手前先按对标规则给用户「差距 + 推荐范围」。

**暂不发版**（用户决定，2026-09-24）：0.1.0 只在本地用 `macos/build-dmg.sh` 打包自用（arm64、Apple Development 签名、无 get-task-allow），不打 tag、不发 GitHub / GitCode；以后要发时再按下面的「发布 0.1.0」步骤（2026-09-27 已改成发到本仓库），且须先经用户确认。

**待用户手测**（代码已就绪，清单见各里程碑验收标准）：M1 #1–#5、M2 #2、M3 #1–#3、M4 #2–#8、M5 #1、~~M6 #1–#5~~（2026-09-26：导入已删除），以及 §11「翻译语言」的几种组合；截图翻译手测：
  1. 首次按 ⌥S：弹一次系统「屏幕录制」授权框，同时打开系统设置 › 屏幕录制，刘海岛警告「需要「屏幕录制」授权」（2026-09-27 起不再借翻译浮窗说）；授权（必要时重开 App）后再按能进入框选。
  2. 内屏 2x + 外接 1x 各框一次文字，识别内容与框选一致；鼠标所在屏按 Esc / 右键能取消，取消后不用点击就能继续在原 App 打字。
  3. 其它 App 开着右键菜单时按 ⌥S，菜单在冻结帧里；全屏 App 的空间里能用；从菜单栏点「截图翻译」时冻结帧里没有自家菜单残影（有就给菜单入口加短延迟）。
  4. 框选期间按 ⌥C 等热键没反应，结束后恢复；固定着的翻译浮窗不被收起，在冻结帧里（2026-09-26 起截得到本 App，见 #13）。
  5. 中文 / 英文 / 日文 / 韩文网页截图：各服务卡并发翻译，第一个服务写历史、自动复制；剪贴板历史里出现原文（无来源 App），画面里有 `sk-…` 密钥时不入历史。
  6. 框选空白处：只提示「没有识别到文字」、没有卡片；十字光标在按下热键后立即出现、结束后恢复箭头。
  7. `footprint` 看框选结束后内存回落（遮罩和冻结帧不常驻）。
- 截图（M9）手测：
  1. ⌥A：鼠标下的窗口高亮（被挡住的小窗不会被选中），单击截整窗；空白处单击截整屏；菜单栏里展开的菜单能单独截。
  2. 拖动框选时按住空格平移；松手后 8 个手柄、拖动平移、方向键 / ⇧方向键微调，尺寸标签是像素；右键回到待选，Esc 取消后能直接在原 App 打字。
  3. 放大镜跟着光标、靠边翻面，色值和系统「数码测色计」的 sRGB 一致；按 C 后剪贴板是色值。
  4. ↩：粘到备忘录 / 微信里大小正确（Retina 不放大一倍），剪贴板历史里出现这张图；⌘S 存到上次另存为的目录（首次写下载 / 桌面时系统会问一次授权），同一秒存两次不覆盖；⇧⌘S 弹保存面板，存完回到原 App。
  5. T 钉图：原位置出现、不抢键盘；拖动、滚轮 / 捏合缩放、右键透明度、双击和（点过后）Esc 关闭；菜单栏隐藏 / 显示 / 关闭全部；钉图出现在下一次截图里。
  6. ⌥X / 框选里按 D：选中上次区域，可连按；内屏 2x + 外接 1x 各试一次，外接屏拔掉后按 D 只有提示音。
  7. 截图翻译回归：上面「截图翻译手测」1–7 再走一遍（行为应与 M9 前完全一致）。
- 截图重设计手测（2026-09-26，方案页 https://claude.ai/artifact/WQFQonH4urad3hmnceBiko ；浅色 / 深色桌面、内屏 2x + 外接 1x 各走一遍）：
  1. 待选：⌥A 后顶部提示胶囊（离屏顶约 64 pt，3 s 淡出）；悬停窗口时洞和粉框在窗口之间、窗口和桌面之间磁吸变形，洞上方是窗口像素尺寸；单击窗口选中、单击桌面整屏、双击直接拷贝。
  2. 拖边：调整时四条边的任意位置和四角都能拖（不只手柄点），悬停的边变粗、对应手柄放大，光标是对应方向的缩放箭头；选区外误拖出的小框恢复原选区；触控板慢慢拖时粉线始终清楚、不发糊。
  3. 修饰键：框选 / 拖边时 ⇧ 正方形（锁了比例按比例）、⌥ 从中心、空格整块平移、⌃ 暂停吸附，拖动中按下 / 松开立刻生效；边离窗口边或屏幕边 6 pt 内吸上，出整屏粉色虚线参考线。
  4. 键盘：方向键平移 1 pt（⇧ 10）；⌘ + 方向键把那条边往外推、⌥ + 方向键往里收；选中标注时方向键挪标注。
  5. 尺寸胶囊：点数字变输入框（选中底色是粉色、不是蓝色），Tab 切宽高、↩ 生效（左上角不动）、Esc 放弃、点别处提交；「自由 ▾」弹 HUD 菜单，选 16:9 立即套用并锁住（按钮变粉底），之后框选、拖边都按比例，选「自由」解锁；选区贴屏顶时胶囊放进选区左上角、不盖住角手柄。
  6. 工具栏：两段胶囊松手后从选区底边中间长出来（贴屏底时在上方、整屏时在选区里），拖动 / 缩放 / 平移选区时淡出、松手再长出，画标注、拖标注时不动；当前工具的粉色底块在工具间滑动；保存单击快速保存，▾ 弹「存储到「桌面」⌘S / 另存为… ⇧⌘S」。
  7. 10 个工具（1–0，再按一次收起）：矩形空心 / 实心、椭圆、锥形箭头、直线、画笔（跟手、平滑）、荧光笔（压在字上字仍清楚）、文字（无底 / 描边 / 底色，输入时就是最终样子，输入中改样式立刻变）、序号（单击放、自动 +1、永远在最上）、马赛克（像素 / 模糊）、聚光灯（其余压暗，多个合成一层）；⇧ 正方形 / 正圆 / 45°；样式托盘从当前工具下方长出、换工具时滑过去；每个工具记住上次的样式（重开 App 仍在）。
  8. 标注编辑：画完自动选中（粉色虚线框 + 手柄），拖手柄改大小（⇧ 约束）、拖本体挪（⇧ 锁轴）、⌥ 拖动复制一份（光标带 +）、⌘D 复制、⌫ 删除、双击文字重新编辑；⌘Z / ⇧⌘Z；拖着标注时按 ⌘Z / ⌫ / ⌘D 没反应。
  9. Esc 顺序：菜单 → 尺寸输入 → 选中的标注 → 工具 → 取消截图（遮罩约 0.1 s 淡出，之后直接能在原 App 打字）。右键：没标注时回到待选；有标注时提示音 + 顶部「有标注时右键不清空 · Esc 退出」。
  10. 截图翻译 ⌥S / 识字 ⌥O：同样的粉色选区、放大镜、修饰键和吸附参考线，松手即出结果，没有窗口悬停和调整。
  11. 品牌粉一致：遮罩、托盘、放大镜十字条带、飞行卡片的 ✓ 与保存角标（写「桌面」，不是 Desktop）、常驻缩略图、钉图、长截图边框与按钮都是粉色，截图家族里找不到系统蓝；钉上时从略大一点弹回原位，马上拖动 / 滚轮缩放不会被弹回去。
  12. 无障碍：VoiceOver 下选中时播报「已选中 宽 × 高」、换工具和锁比例都有播报，托盘色点、菜单项、尺寸胶囊的宽 / 高 / 比例有名字；减弱动态效果时手柄、工具栏、放大镜只淡入不弹，洞不滑动变形，飞行卡片不飞；降低透明度时 HUD 控件不透；增强对比度时 HUD 描边和分隔线更明显。
  13. 截到本 App（2026-09-26 用户要求；`ScreenCapture.keptOwnWindows` 留用名单，⌥A / ⌥X / 启动器 / 菜单栏截图都不再先收面板；从菜单栏点时点图标本身算点外，没固定的剪贴板面板 / 启动器照常收起）：分别开着剪贴板面板（没固定）、翻译浮窗（没固定、是 key）、启动器、⌘Y 放大预览、设置窗、一张钉图时按 ⌥A：它们都在冻结帧里，悬停时粉框吸到它们上面、单击选中的就是整个窗口；拷贝 / Esc 取消后它们都还开着，原来是 key 的那个还能直接打字（本 App 没被激活）；刘海岛、飞行卡片、常驻缩略图、菜单栏菜单、上一次的遮罩不会出现在画面里，菜单栏图标照旧在。⌥S / ⌥O：没固定的面板照旧先收起，固定着的和设置窗截得到。框选中按 S 转长截图时没固定的浮层先收起（不挡选区和滚轮），固定着的还在。
- 链接预览手测（Whisker D）：
  1. 复制 GitHub 仓库、少数派文章、B 站视频、苹果文档的网址，在剪贴板面板里选中：约 0.25 s 后头图区扫光，1–3 s 内标题、头图、网站图标淡入；再选回来是瞬间出来（不再联网）。
  2. 取过预览的链接，列表行角标变成网站图标；没取过的还是链接符号。
  3. 快速按 ↓ 扫过一串链接：不会每条都联网（停下来的那条才取）；断网时只显示域名卡，联网后再选中会重取。
  4. `http://192.168.1.1`、`http://localhost:3000`、带 `?token=` 的网址、登录 / 重置密码 / 退订链接：只显示域名卡、不联网（可用「小飞机」之类的抓包工具确认没有请求）。
  5. 设置 › 剪贴板关掉「链接显示网页标题和图片」后只显示域名卡；深色、减弱动态效果（扫光静止）各看一次；`footprint` 看取完预览后没有多出 WebKit 进程。
- ⌘Y 放大预览手测（Whisker D）：
  1. 剪贴板面板里选中一张截图按 ⌘Y：大卡片从透镜的位置长出来（不是凭空淡入），图按原尺寸显示（太大时缩到屏幕 90%）；再按 ⌘Y 或 Esc 缩回透镜。
  2. 预览开着时按 ↑↓：剪贴板里的选中照常移动，预览即时换内容、窗口换尺寸（按住方向键连发时不做尺寸动画）；键盘一直在剪贴板面板里（能继续打字搜索）。
  3. 文件条目（PDF、视频、Keynote 各一个）：预览里是 Quick Look 的内容，PDF 能滚动翻页、视频能播放；本 App 没有被激活（菜单栏左上角还是原 App 的名字）。
  4. 代码 / JSON / 长文本：字变大，短文本窗口矮、长文本高；点选文字后 ⌘C 能复制，Esc 回到剪贴板面板继续用键盘。
  5. 预览开着时：点预览里的「粘贴」、双击列表行、⌘K、⌘E、点面板外面，预览都跟着消失，粘贴落到原 App；关掉「显示透镜」后按 ⌘Y 从选中行长出来。
  6. 减弱动态效果：只淡入淡出、不放大；深色下看一次。
- 设置手测（Whisker D）：
  1. 菜单栏「设置…」：左边侧栏带家族色块，右边每页有页头；窗口标题跟着页变；关掉再开回到上次的页；拖大窗口后表单跟着变宽。
  2. 侧栏搜索「快门」「密钥」「书签」「字号」：侧栏只剩对应的页，右边自动跳过去；搜不到时显示「没有匹配的设置」。
  3. 剪贴板页：切「显示透镜」「链接显示网页标题和图片」时上面的面板线框跟着变（有动画）；图片上限是一排单选。
  4. 翻译页：拖字号滑块，下面的卡片字号实时变，打开翻译浮窗也是这个字号（和 ⌘± 同一个值）；智谱模型、AI 协议、DeepL 接口是分段控件，历史条数是单选。
  5. 截图页：点喇叭试听快门声（关掉快门声后喇叭变灰）；切「识字后把换行合成一段」，下面的示例在三行和一行之间切换。
  6. 通用页：先在系统设置里关掉辅助功能授权，回到设置窗看到橙色感叹号 +「去授权」；重新授权后回来，图标换成绿色对勾并弹一下。
  7. 关于页：大图标点一下摇一摇、鼠标在上面移动时轻微 3D 倾斜；版本胶囊和当前版本圆点是品牌粉；「重看欢迎指南」打开引导。
  8. 欢迎引导：已改成一页欢迎 +「按一下试试」，手测见下面「N1–N17」第 25 条。
- 菜单栏手测（Whisker D）：
  1. 菜单栏图标点开：各项左边是家族色符号，右边显示当前快捷键（没设的留空，分节见下面「N1–N17」第 26 条）；「复制即译」打勾切换；有钉图时出现钉图两项；⌘, / ⌘Q 能用。
  2. 「划词翻译并替换」：翻译中图标一明一暗地呼吸，替换完成弹一下；⌥O 识字成功弹一下；截图 ↩ 后飞行卡片落地时弹一下；平时复制东西（被动记录）不动。
  3. 减弱动态效果打开后以上都不动；设置窗打开时顶部主菜单的「编辑」里拷贝粘贴照常可用。
- 常驻缩略图手测（Whisker D）：
  1. ⌥A 框选 ↩：卡片飞到右下角、弹出对勾后留在那里（看不出换了窗口）；不碰它 6 s 后往右滑走。
  2. 鼠标移上去：变暗，中间「拷贝」「存储」，四角关闭 / 钉图（存过的还有「在访达中显示」）；停在上面不会滑走，移开 2.5 s 后滑走。点「存储」后角标变成文件夹 + 目录名。
  3. 把卡片拖进访达 / 桌面：得到「截图 日期 时间.png」；拖进备忘录、微信、邮件也行；双击用预览打开。
  4. 触控板两指往右扫：卡片跟着手指走，扫过一段就滑走，扫一点点松手会弹回。
  5. 连截三四张：新的在最下面，旧的往上让，超过 3 张时最早的滑走；关掉中间一张，上面的落下来。
  6. 点缩略图不会激活本 App（菜单栏左上角还是原 App），之后再截图时画面里没有它；减弱动态效果时不飞、在角落淡入。
- 挤压入场手测（Whisker D 实验）：设置 › 启动器打开「呼出时挤压弹开」，⌥空格：启动器从窄一点、矮一点弹开，略冲过头再回来（约 0.4 s，毛玻璃和阴影跟着窗口走）；呼出后马上打字，结果照常往下长、宽度不会停在半路；关掉开关或打开减弱动态效果后是原来的淡入下落。
- 查词手测（D4）：
  1. 划词 / 输入 `serendipity`：结果区最上面出「系统词典」卡（词头、音标、按词性分组的释义和斜体例句，「展开全部」看完）；智谱卡片是「读音 / 词性行 / 例：」三段的词条格式。
  2. 查 `ran`、`went`、`children`：词典卡显示原形（run / go / child）并写「ran 的原形」；查 `look up`、`give up`：没有词典卡，只有大模型的词条。
  3. 查 `苹果`、`一丝不苟`：词典卡出拼音和中文释义；查一整句话：没有词典卡、大模型照常翻译。
  4. 开着「自动复制」查单个词：剪贴板没被换掉；划词查单个词时没有「替换原文」；「划词翻译并替换」对单个词照常替换成译文。
  5. 「词典」App › 设置里勾上牛津英汉汉英并拖到最前：再查英文词，词典卡变成中文释义；卡上的书本按钮打开「词典」App 到这个词。
  6. 设置 › 翻译关掉两个查词开关：词典卡不出、大模型回到普通翻译；⌘+ / ⌘- 时词典卡字号跟着变。
- 长截图手测：
  1. ⌥A 框一段网页正文（别框进侧栏）→ S：遮罩收起、选区有品牌粉边框（慢慢呼吸）、右边出面板；触控板慢慢往下滚，预览跟着长，尺寸变大；↩ 后剪贴板历史里有这张长图，粘到备忘录里文字清晰、没有重复行或断层。
  2. 快速一甩：面板变橙色「对不上了」；往回滚一点再慢慢滚，恢复拼接，结果里没有缺口。滚到页面底部回弹后，长图末尾没有多出一截空白。
  3. 带吸顶导航栏的网页、微信 / 飞书聊天窗口（输入框里光标在闪）：往下滚时导航栏只在长图顶上出现一次；聊天记录往上翻，长图最上面是标题栏、最下面是输入框，中间没有输入框碎片。
  4. 空格自动滚动：未授权辅助功能时提示并弹授权；授权后光标跳到选区中间、页面自己一段段往下滚，到底自动停并提示「已经滚到底了」；中途移开鼠标或再按空格停止。上翻过聊天记录再按空格时往上滚。
  5. ⌘S 存到快速保存目录、⇧⌘S 弹保存面板存完回到原 App；Esc 取消后什么都不留下、能直接在原 App 打字。
  6. 选区占满屏宽（比如整个浏览器窗口）时面板放进选区右上角；外接屏（1x）上也试一次；面板和边框不出现在长图里。
  7. 框选时 S 的提示（工具栏按钮悬停显示「长截图（S）」）；选区太矮（< 60 点）按 S 只有提示音。
- 翻译（M12）手测：
  1. 浮窗里 ⌘R 重译、⌘S 收藏（星标变黄，历史里只看收藏能看到）、⌘1 / ⌘2 复制对应卡片（卡片上出对勾）、⌘P 固定、⌘W 收起、⌘+ / ⌘- / ⌘0 字号；⌘C / ⌘V / ⌘A 在输入框里照常。
  2. 划词翻译后点「替换原文」：浮窗收起，原 App 里选中的文字换成第一个服务的译文（备忘录、浏览器输入框、微信各试一次）。
  3. 快捷键页给「划词翻译并替换」设键：选中文字按键 → 轻提示「翻译中…」→ 选区被替换、提示「已替换为译文」；没选中时提示。
  4. 浮窗高度：查一个词时很矮、长段落变高，最高不超过屏幕 85%，流式输出时跟着长；靠近屏幕底部时不跑出屏幕。
  5. 收起某个服务卡片 → 重启 App 后仍是收起的。
  6. 设置 › 翻译「导出…」：CSV 用 Numbers / Excel 打开中文不乱码；TSV 导入 Anki 正反面正确。
- 品牌图标手测（C 阶段，原创角色「探头」）：
  1. 装上测试包后程序坞、访达、启动台、「关于本机 › 储存空间」里都是粉底小黑猫扒着卡片（不是 Hello Kitty）；还显示旧图标时是系统图标缓存，把 App 拖出再拖回「应用程序」或重启程序坞（`killall Dock`）。
  2. 访达列表视图（16 px）和侧栏（32 px）里看得出是猫加卡片，不糊成一团；关于页、欢迎引导、设置侧栏「关于」是新图标。
  3. 菜单栏：浅色、深色菜单栏里都是扒在线上的猫剪影（耳朵、两只爪子、两个眼洞），和旁边的系统图标一样高；外接 1x 屏上也不糊。「划词翻译并替换」时照样呼吸、完成时弹一下；减弱动态效果时不动。

- 文件搜索手测（M13）：
  1. 第一次输 `open 报告`：结果最后一行是橙色锁「搜不到桌面、文稿、下载、iCloud 云盘里的文件？」，↩ 后启动器收起、系统依次问桌面 / 文稿 / 下载 / iCloud 云盘（没开 iCloud 云盘就少一个），都允许后刘海岛「已允许访问」；再搜能搜到下载、文稿里的文件，提示行消失。拒绝一个：刘海岛写哪个被拒，提示行变成「没有权限搜「下载」…」，↩ 打开系统设置 › 文件和文件夹。设置 › 启动器「文件搜索」那一行状态跟着变。
  2. 搜索和显示结果时不弹任何授权框（授权之前也不弹）；中文文件名用中文、拼音（`open jidu`）都能搜到；多个词（`open kitty dmg`）每个都要命中；`open a` 提示「再输入一个字母」、`open 报` 照查。
  3. `open 词` ↩ 用默认 App 打开、⌘↩ 在访达里选中；`find 词` 反过来（↩ 访达里选中该文件，不是打开父目录）；按住 ⌘ 时选中行副标题跟着换（N8 起底栏不再显示替代动作，⌘K 里能看到全部）；⌘C 复制路径、Tab 把路径补进输入框（文件夹带 /）、⌥↩ 用去掉关键词的词在访达里搜。
  4. 只输 `open ` 或一个空格：「最近打开和下载的文件」，刚下载的 dmg、最近打开的文档在前；node_modules、build、~/Library 里的不出现；iCloud 云盘里的副标题写「iCloud 云盘/…」。
  5. `find my`：「查找」App 在最前、↩ 打开它；` find my`（空格开头）只有文件。单输 `open` / `find`：第一行是补全提示，↩ / Tab 变成「open 」；设置里网页搜索关键词填 open / find 会提示被文件搜索占用。
  6. 快速连打 / 删字：列表不闪空、不闪「没有匹配的文件」，高度平滑变化；打开过的文件之后不带关键词也能搜到、出现在「最近使用」。深色、减弱动态效果各看一次。

- 启动器（M11）手测：
  1. 设置 › 启动器：添加预置 / 自定义搜索、自定义快捷链接（网址和 ~ 路径各一个），拖动排序、点进详情改关键词、「−」删除（N12）；「gh swift」直达，单输「gh」出提示、↩ 或 Tab 变成「gh 」。
  2. 快捷链接按名字、关键词、拼音都能搜到，↩ 打开，之后出现在「最近使用」；「最近使用」里 ⌘⌫ 移除一项，设置里清空后「最近使用」为空。
  3. 算式 ↩ 粘到前台 App、⌘↩ 只复制、Tab 把结果写回接着算；「cb 关键词」改成转交剪贴板面板（见下面「N1–N17」第 20 条）；未授权辅助功能时提示去授权。
  4. 按住 ⌥ / ⌃ / ⌘ 时选中行副标题变化；⌥↩ 在访达里出 Spotlight 搜索窗口；⌃↩ 用第一个兜底搜索。
  5. 开「呼出时切到英文输入法」：中文输入法下呼出启动器自动变英文，关掉启动器后回到中文；开关关掉后再呼出不再切。
  6. Tab 在「/Applications」「~/Desktop」上补成「…/」接着往下找。
- 标注与识字（M10）手测：
  1. 框选后按 1–4 / 点工具栏切工具，再按一次收起；画矩形、箭头（⇧ 正方形、45°）、马赛克；↩ 粘出来的图里标注和马赛克都在、位置对。
  2. 文字：点一下出输入框，**中文输入法打字时候选窗不被遮罩压住**（被压住就记下来，改遮罩层级）；↩ 换行、Esc 或点外面收下；双击已有文字重新编辑。
  3. 点中标注拖动、方向键挪、⌫ 删除、改颜色粗细只改它；⌘Z / ⇧⌘Z 撤销重做；拖手柄调整选区后标注不丢。
  4. 工具栏「识字」：打码处的字识别不出来；「翻译」走翻译浮窗。
  5. ⌥O：框文字 → 轻提示「已复制：…」，剪贴板历史里有；框二维码 → 复制链接；设置 › 截图开「合成一段」后中文不插空格。
  6. ⌘S 后有「已保存到『下载』」提示；设置 › 截图「更改…」换目录后 ⌘S 存到新目录。
  7. 标注外观（Whisker D）：矩形转角微圆、箭头从尾部细到头部粗的实心锥形、文字是圆体；白色标注放在白底上也看得见（一圈淡阴影）；↩ 粘出来的图里阴影和屏幕上一样深（内屏 2x、外接 1x 各看一次）；挪动 / 删除标注后原位置不留阴影残影；输入文字时字也带阴影。
  8. 待选 / 拖动框选 / 拖手柄时按住 ⌘：出一横一竖穿过光标的细线（白线贴一条暗线，深浅背景都看得见），松开就没；调整选区时按 ⌘C / ⌘S 不出线。

- N1–N17 界面重做手测（2026-09-26，方案页 https://claude.ai/artifact/DAksYJdU4Xm5HpwXwWzvzv ；浅色 / 深色、减弱动态效果各走一遍）：
  - 剪贴板（透镜指令条 Lens Bar）：
    1. N2 ⌥C：面板在屏幕上方 20%，和启动器同位置同宽；条数少时矮、多时最高 520，搜索 / 筛选改变条数时顶边不动地伸缩，↑↓ 时窗口高度不变。
    2. N1 透镜：↑↓ 时选中行原地展开，灰色高亮连同高度一起滑（按住连发时瞬时）；文本 / 代码 / JSON / 颜色 / 链接 / 图片 / 文件各选一条，透镜高度按类型固定、长内容底部渐隐；点选是滑过去的；鼠标悬停只有淡灰底、透镜不动；输入搜索词、清空搜索词、复制一条昨天的旧条目（挪进「今天」）之后再 ↑↓，透镜照样在选中行展开，高亮不盖住别的行、行上的时间是新的；输入第一个字和清空搜索时各行图标不 pop 一下，这时按 ⌘Y 大卡也从透镜长出来。
    3. N1 双击：从下往上、从上往下、慢速双击各试一次，粘出来的都是第一下点中的那条。
    4. N1 命中摘录：搜一个只在长文本后面出现的词，行标题和透镜都从命中处截取、两头「…」、命中词黄底。
    5. N1 搜索框：光标和全选时的选中底色是粉色，不是系统蓝。
    6. N4 Tab：筛选面板从搜索栏下方长出，输入 saf 只剩 Safari，↩ 生成粉色标签并关面板，对已生效的项再 ↩ 取消；⇧Tab 在 全部 / 收藏 / 片段 间循环；搜索为空时 ⌫ 第一下选中最后一个标签、第二下删掉；点标签 × 删除、点标签本身开面板。
    7. N4 →：光标在词尾（或搜索为空）时打开 ⌘K（锚右下），过滤词为空时 ← 关掉；光标在词中间时 → / ← 照常移光标；输入法组字时这些键不被截走。
    8. N4 Esc：⌘Y 大卡 → 筛选 / ⌘K → 对话框 → 待删标签 → 搜索词 → 多选 → 关面板，逐级退；标签不被 Esc 清掉，收起再开才清。
    9. N1 底栏：左「N 条」，按住 ⌥ / ⌘ 换成替代动作说明，多选时变成「合并粘贴 ↩ · 收藏 ⌘D · 分组… · 删除 ⌘⌫ · 取消 Esc」且每个都能点；右「粘贴 ↩」键帽是粉色实心，齿轮、图钉在最右，固定后点外面不关。
    10. N1 片段范围：第一行是虚线「＋ 新建片段 ⌘N」，没有片段时只有它；新建对话框从搜索栏下沿落下、只压暗列表，保存按钮是粉色。
    11. N3 ⌘Y：大卡从透镜位置长出来，带来源 App 彩色页眉；图片下面有识别到的文字，多个文件是一排缩略图；主界面没有彩色页眉（只有透镜元信息行里的 16 pt 来源图标 + App 名）。
    12. 设置 › 剪贴板关掉「显示透镜」：纯列表、能看到 9 行以上，⌘Y 从选中行长出；上面的线框预览跟着变。
    13. VoiceOver：行的操作里有「粘贴 / 放大预览 / 收藏」；标签读「筛选：收藏」，⌫ 待删时有播报。
    14. N17 片段「Hello {cursor}!」：粘到备忘录、浏览器输入框、微信后光标停在「!」前；超过 500 字的片段、多条合并粘贴不挪光标。
  - 翻译：
    15. N5 浮窗里没有「翻译」按钮，↩ 翻译；翻完再改原文，原文框右下角弹出粉色「翻译 ↩」，↩ 或点它后收回。
    16. N6 顶栏只有语言胶囊、图钉、⋯；⋯ 里是 历史 ⌘Y / 复制即译 / 设置 ⌘,，⌘Y、⌘, 在浮窗里直接可用；开复制即译后顶栏出现粉色「复制即译」胶囊，点一下关掉，菜单栏的勾跟着变。
    17. N7 历史：↑↓ 灰色高亮滑动、↩ 重新翻译、⌘⌫ 删（⌘Z 撤销）、⌘C 复制译文、Esc 回浮窗；按 今天 / 昨天 / 日期 分组，全部 / 收藏 胶囊；右键菜单（或 ⌘K）里有条数、清空、导出；打开时原文区不动、结果区淡变。
  - 启动器：
    18. N8 底栏左边是选中项的种类色块 + 名字，右边「打开 ↩ · 动作 ⌘K」（↩ 粉色实心）；没有图钉、齿轮（⌘, 仍开设置）；点面板外面总会收起；设置 › 启动器没有「点面板外面时自动关闭」。
    19. N8 ⌘K：弹出和剪贴板同一套的动作菜单，列出 ↩ ⌘↩ ⌥↩ ⌃↩ ⌘C ⌘⌫ 等动作和键位，能过滤、↩ 执行；按住 ⌘ / ⌥ / ⌃ 时选中行副标题照旧变化，底栏不再写「按住 ⌘ ⌥ ⌃ 看更多动作」。
    20. N9 输入「cb 会议」：只有一行「在剪贴板历史里搜索『会议』」，↩ 后启动器收起、剪贴板面板在同一位置出现、搜索框里是「会议」；剪贴板面板固定着时按 ⌥空格，它先收起再出启动器（两者不叠在一起）。
    21. N10 搜「剪贴板」：副标题只写「Kitty Tools」，选中时右侧有它的快捷键键帽（⌥C）；没设快捷键的动作不显示键帽；输 Clipboard 仍能搜到。
  - 设置与引导：
    22. N11 启动器 / 翻译 / 截图三页没有大段按键说明，「查看全部快捷键…」弹出速查表：按家族分组、键帽显示，全局热键是当前设置的组合（改了快捷键再开跟着变）。
    23. N12 翻译服务、网页搜索列表：拖动排序（重开 App 仍是新顺序），行上开关，下面「+ −」；点一行进详情页（大图标 + 名称、表单、密钥、测试连接），点工具栏「‹」、⌘[ 或菜单栏「显示 › 返回」回到列表（别的页上「‹」和菜单项置灰，开着确认框时菜单项也置灰；推进 / 返回时标题栏和内容不跳）。
    24. N13 快捷键页：按 剪贴板与启动器 / 翻译 / 截图 分组，行首家族色块；点输入框按下组合即录入，ⓧ 清除，右键「恢复默认」；注册失败（15.0–15.1 上只带 ⌥ 的组合）在那一行下面出橙字说明。
    25. N14 `defaults delete com.yy.kitty-tools.native.dev lastSeenVersion` 后重开：一页欢迎（图标、大标题、四行功能，授权状态嵌在对应行、授权后一秒内变绿）→「按一下试试」：真按 ⌥C 等热键时那一行打勾弹 ✓；没有跳过、页码点、上一步；关于页能重看。
  - 菜单栏与名字：
    26. N15 菜单分三节（剪贴板与启动器 / 翻译 / 截图，带节标题），复制即译在翻译节；没设快捷键的项右边空着，不写「未设置快捷键」。
    27. N16 先删掉 /Applications 里旧版 Tauri 的「Kitty Tools.app」再装：程序坞、访达、菜单栏「关于」都叫 Kitty Tools（Debug 叫 Kitty Tools Dev）；授权、偏好、钥匙串里的密钥都还在（Bundle ID 没变）；开机自启不生效就在设置 › 通用重新打开一次。

**发布 0.1.0**（2026-09-27 改）：`macos/build-dmg.sh` 出 arm64 DMG 和 `_arm64.zip` → 本仓库 github.com/YyAdnBug/kitty-tools 发**正式 release、标 latest**（App 内更新读 `releases/latest`；不碰 Tauri 版的仓库，不跑 `pnpm release:verify`），两个文件都附上，**发布前须经用户确认**；tag `macos-v0.1.0` 打在 `main`。发布前先把 changelog.json 的 0.1.0 条目补全（启动器、截图、应用内更新等还没写进去）。

**接手须知**：先读 `AGENTS.md`、`.cursor/rules/mac-native.mdc`，改哪块读哪块的技能（mac-overlay-panel / mac-clipboard / mac-translate）。界面改动用 SnapshotProbeTests 屏幕外渲染自检，**不要**为截图弹出浮层（会抢用户键盘）；联网冒烟 `TEST_RUNNER_KITTY_LIVE_TRANSLATE=1`；真实旧库演练 `TEST_RUNNER_KITTY_LEGACY_DRY_RUN=1`。用户要求：只兼容 macOS、不照搬 Tauri 实现、样式与交互可按 macOS 习惯重新设计、照搬行为前先核对旧逻辑有没有 bug（记入 §11）。

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
| 24 | `launcher/mod.rs:1059-1065` | 锁屏调用的 CGSession 在 15.7 上已不存在，命令必失败 | 系统命令不迁 |
| 25 | `system_apps.rs:468-540` + `installed_apps.rs:529-535` | 9 个系统 App 各出现两行，使用次数也被拆开 | 只有一个 App 目录，不写死系统 App（M7） |
| 26 | `installed_apps.rs:602-619` | 标题用文件名，中文名和拼音搜不到（本机 7/50 个 App 显示名与文件名不同） | 索引显示名、文件名、zh loctable / strings 里的中文名及其拼音（M7） |
| 27 | `mod.rs:634-648,1283-1312` | `~` 不展开，`./` 按 GUI 进程目录解析 | 展开 `~`，不认相对路径（M8） |
| 28 | `files.rs:901-913` | find 回车打开父目录、文件没被选中 | `activateFileViewerSelecting`（M13） |
| 29 | `recency.rs:143-153,247,356` | 另起线程非原子整份写 JSON，可能乱序覆盖；key 用 `::` 拼接有歧义 | SQLite 表，每个字段一列（M7） |
| 30 | `recency.rs:157-164`、`mod.rs:832-856` | 网址被转成小写再打开 | 存原始网址；导入时用书签还原大小写（M8） |
| 31 | `recency.rs:171-175` | 次数永不衰减；注释里的「半衰期」其实是时间常数 | 每用一次：衰减后的分 + 1（M7） |
| 32 | `mod.rs:1516-1541`、`kill.rs:795-805` | 搜索结果页、reveal_path、kill_port 也记进频率，挤占「最近使用」 | 只记能还原的类型；导入时丢掉搜索结果页（M7） |
| 33 | `mod.rs:1394-1399` | 先隐藏再执行，失败提示显示在看不见的窗口里 | 先执行，成功才收起；失败在面板里显示（M7） |
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

## 附录：评审处理记录

共 41 条：采纳 41，不采纳 0。

1. [采纳] major · M0 一次写 6 篇 A 档规则 + 5 个技能，属于预写脚手架 → M0 只写一篇 `mac-native.mdc`（≤80 行）；`mac-overlay-panel`、`mac-clipboard`、`mac-translate` 分别在 M1、M3、M4 结束后写；不建 mac-ui、mac-release。
2. [采纳] major · 引用了仓库里不存在的「盘点文档」 → 删掉全部引用，钥匙串 account 列表写进 §6；技能来源改为「master .mdc 删减 + 本文章节 + 实测的坑」；另外把本方案作为 `macos/PLAN.md` 入库，让 §5 的逐行验收有据可查。
3. [采纳] major · 没有证书，路径 A 无法测试 → `build-dmg.sh` 只保留路径 B；不建 `ExportOptions.plist`；§8.4 改为拿到证书当天的操作步骤。
4. [采纳] minor · 为校验 changelog 依赖 Node 并改共享脚本 → 改用系统自带 `/usr/bin/jq`（已核实存在）；不改 `release-notes.mjs`。
5. [采纳] minor · swift-lsp 对纯 `.xcodeproj` 无效 → 从 §3B 和 M0 验收里删除，诊断以 `xcodebuild` 为准。
6. [采纳] minor · 社区 concurrency 技能与 Apple 官方文档重复；放行 `.claude/skills/` 会提交断链；改 skills-lock；ponytail 重复加载 → 只用户级装 swiftui-expert-skill；并发以 Xcode 自带文档为准；`.gitignore` 只放行 `.claude/skills/mac-*/`；不碰 skills-lock.json；CLAUDE.md 不再 @import ponytail，`.mdc` 只给 Cursor。
7. [采纳] minor · Phase 1 不用玻璃效果却预建 `Glass.swift` → 删掉该文件和规则条目，材质直接用 `.regularMaterial` / `NSVisualEffectView`。
8. [采纳] minor · M1 混入非风险项（设置窗、录制器） → 两者和对应验收都挪到 M3（从翻译齿轮打开设置窗的验收放在 M4）。
9. [采纳] minor · 原样搬 WebView 时代的时序补丁 → 粘贴先用最简实现（显式 `.maskCommand`、`combinedSessionState`、`cgSessionEventTap`，不等待）；30/100/40/500ms 都等实测失败再按 App 加，并写 `ponytail:` 注释。划词还原的 3×20ms 重试保留，因为它防的是丢用户剪贴板数据，不是时序问题。
10. [采纳] minor · 导入范围过大、热键导入与共存矛盾、首启横幅重复 → 只导保留类条目（本机核实为 7 天保留，共存期原生已自己采到普通历史）；热键不导；去掉横幅；偏好和密钥导入提前到 M4。
11. [采纳] minor · 像素 SHA256 要全量解码，而且和旧 xxh3 永远对不上 → 对编码字节做 SHA256，尺寸读属性不解码，加 `ponytail:` 注释说明换编码不去重。
12. [采纳] minor · 搜索和导入不必用 `@concurrent` → 白名单缩到 3 类，M2 用 5000 条实测。注：评审说 Tauri 搜索跑在主线程，这点不准确（≥120 条时走 Worker，`clipboard-history-worker.ts:98`），但结论成立。
13. [采纳] minor · 只有一种语言却建 String Catalog → 不建 xcstrings；开发语言设 zh-Hans，并声明 `CFBundleLocalizations`。
14. [采纳] minor · CLAUDE.md 和 AGENTS.md 双份维护 → 正文只写在 AGENTS.md，CLAUDE.md 只有两行 @import。
15. [采纳] minor · 「定期 merge master、合回 master」是猜测性需求 → D1 明确不 merge、不合回；最新行为读 master 工作区绝对路径。
16. [采纳] minor · 没核对实际配置就全量迁 8 家服务 → 已只读核实（只输出布尔值）：启用的是 builtin、百度、1 个 OpenAI 协议 AI 实例，有凭据的是百度、有道和该 AI。D11 定为智谱 + AI（OpenAI 兼容）+ 百度 + 有道，其余推迟；同样的原则也用到了 AI 的 anthropic/azure 协议上。
17. [采纳] major · 模板在 target 层写死的 `SWIFT_VERSION=5.0` 等会压过 xcconfig → 本机模板已核实；M0 改为清空 target 层 buildSettings、全部搬进 xcconfig，并加 `-showBuildSettings` 和 `vtool` 验收。
18. [采纳] major · 误读 `accessBehavior`：`.default` 时 App 不在设置面板里 → 按四种状态分别处理；不再断言读 `types` 不会弹窗，改由 M2 实测。
19. [采纳] major · `RegisterEventHotKey` 默认非独占，不会报冲突 → §9 改为「两边都会响应」；共存期靠清空 Tauri 热键；M1 实验 `kEventHotKeyExclusive`；录制器验收改为 -9868 时显示错误。
20. [采纳] minor · 只带 ⌥ 的组合在 15.2 起已恢复 → 录制器不一刀切，直接注册并把 -9868 映射成提示；§10 改为「⌥Space 只在 15.0–15.1 不可用」。
21. [采纳] minor · `kSecAttrAccessible` 对文件型钥匙串无效 → 从 §6 删除，等切换到 data protection keychain 时再加。
22. [采纳] minor · App Nap 会降低 timer 频率 → M2 加空闲后连续复制的测试，漏了再持有 `beginActivity`。
23. [采纳] minor · LaunchServices 不保证单实例 → 启动时用 `NSRunningApplication` 检查，约 5 行。
24. [采纳] minor · 本机生成的 DMG 没有隔离属性，测不到 Gatekeeper → M0 验收改为先手动加 quarantine（或从 prerelease 下载），并用 `spctl` 确认 rejected。
25. [采纳] minor · `NSApp.activate()` 从 14 起是协作式的 → M3/M4 从三个入口实测，不行就退回 `activate(ignoringOtherApps:)`，并写进技能。
26. [采纳] minor · 不存在 `NSScreenCaptureUsageDescription` → 从 §10 删除。
27. [采纳] blocker · WAL 库在没有 `-shm` 时 `mode=ro` 打开报 SQLITE_CANTOPEN → 改为复制 db、`-wal`、`-shm` 到临时目录后读写打开，并加 `PRAGMA quick_check`（防止 Tauri 运行中复制到半截数据），原文件不碰；M6 补「Tauri 退出 / 运行中」两条验收。
28. [采纳] major · 只按 id `OR IGNORE` 导致共存期数据重复、旧收藏丢失 → 剪贴板条目逐行按去重键合并；图片重算新 hash；翻译历史用 `INSERT OR IGNORE` + `UPDATE favorited`。没有照搬评审给的 `ON CONFLICT DO UPDATE`：它只处理指定的唯一键，第二次导入时撞上 id 主键会直接报错。
29. [采纳] major · 热键空串表示关闭，录制器缺「清除」 → 模型里用 Optional；录制器加「清除」，菜单显示「未设置」；热键不导入。
30. [采纳] major · 划词漏了「还前台后再读一次 AX」 → SelectionReader 改为三步；M4 加「浮窗固定且为 key 时划词」验收。
31. [采纳] major · AI 行漏了 max_tokens 规则和本机判定 → 写明按 host 取值（1024 / 不传 / 4096）并照搬 `is_local_network_host`，M4 补单测。
32. [采纳] minor · 设置窗没有先收起浮层 → `SettingsWindow.show()` 先按正常路径收起两个面板（含作废翻译会话）。
33. [采纳] minor · 漏了粘贴成功后的重置 → 选了更简单的做法：去掉「粘贴除外」，每次隐藏都重置，并选中第 0 条。
34. [采纳] minor · 翻译浮窗固定时 Esc 不应关闭 → 翻译浮窗的 Esc 链最后一步改成「未固定才关闭」；剪贴板面板保持 Tauri 前端的行为（固定时 Esc 也关闭）；M4 加验收。
35. [采纳] minor · §5.1 缺多项用户可见行为 → 新增「分组筛选与管理」「行渲染细则」两行，其余并入键盘、列表、空态、片段、备注、预览各行。
36. [采纳] minor · 翻译 Tab / 历史面板缺字段 → 默认服务下拉删除（D15，列表首个决定历史和自动复制）；智谱文本模型、AI 预设保留名称、历史时间格式与底部计数、mode 规则写入表格；快捷键汇总卡和 Markdown 块级降级列入砍掉清单；Azure 随协议推迟。
37. [采纳] minor · 偏好不能整份照搬 → LegacyImport 用白名单；排除 lastSeenVersion、firstRun、floatingWindow*；launchOnStartup 走 SMAppService；aiServices 照搬规范化。
38. [采纳] minor · 默认启用有道会常驻一张错误卡 → 原生默认只启用 builtin，导入时以旧配置为准。
39. [采纳] minor · 共存期剪贴板互相干扰 → 原生自写一律加 TransientType（经 `Paster.write`）；§9 写明共存期操作（Tauri 只留截图翻译、关复制即译，自动复制自行取舍）。
40. [采纳] minor · DeepL 源、目标语言码不能共用一张映射 → DeepL 已推迟，这条要求写进 §5.2 推迟清单，补服务时照做并写单测。
41. [采纳] minor · KCH 分支用不上，而且和条数对账矛盾 → 删掉两个 KCH 分支；非 PNG 的连同行一起跳过并计数，M6 对账算上跳过数。


## 附录：用户决策记录（2026-09-24）
- 分支：独立 worktree `../kitty-tools-macos`，分支 `main`（原名 `macos-native`，2026-09-27 改名），基于 master `ee615b3`。
- 签名：Apple Development，Team `HTX9F4KG39`（证书 2027-06-10 到期，续期后在 Xcode 里重新生成即可，签名要求不变）。
- 公证：长期不公证（D7）。
- 翻译服务：全部迁移（D11）。
- CPU 架构：只支持 Apple 芯片（arm64），应用基本自用（D10）。
- 其余决策点按推荐执行。
- 截图翻译（2026-09-24）：只用 Vision 本机识字；原文写剪贴板历史；默认热键 ⌥S。
- 启动器 / 截图（2026-09-24）：启动器首版做 App、书签、直达、网页搜索、最近使用、内置动作、计算器、cb，文件搜索与 kill 放 M11；标注首版做矩形、箭头、文字、马赛克；附加功能只做取色（长截图、延时、美化 / 水印不做；长截图 2026-09-25 改为做，见 §10 D1）；做钉图，不做截图历史和钉图历史。
