# PLAN.md 归档：迁移期历史

> 2026-10-03（第二轮体检第 8 批）从 `macos/PLAN.md` 原样挪来，一个字没改，之后不再更新；现行的方案、约束和决定以 `macos/PLAN.md` 和各 `mac-*` 规则为准。
> 收的是：开头的「基线」「一句话方案」，§0 需要你拍板的决策点，§1 分支与仓库布局，§3 规范 rules 与 skills，§5 功能迁移映射，§6 数据与配置迁移，§7 里程碑（M0–M6），§9 风险与已知坑，附录：评审处理记录，附录：用户决策记录（2026-09-24）。章节编号和标题照原文；文中的「§N」仍指 PLAN 的章节（挪走的在 PLAN 原位置写了去处），`src/`、`src-tauri/` 路径指 master `ee615b3` 上的文件。

## 开头：基线与一句话方案

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
| D12 | 是否新增 Apple Translation 引擎 | Phase 1 不做，功能对齐后作为第一个候选 | 不在迁移范围内。macOS 15 上 `TranslationSession` 只能依附 SwiftUI 视图获取（脱离视图的 init 需要 macOS 26）；语言包下载 sheet 在不激活的浮层里能否工作也没验证 | 放进 M5（优点：离线、不需要密钥）。2026-09-28 体检 D16 做了文档层面的可行性验证：文档不足以确认，先不做，结论见 §10「D5 系统翻译」 |
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

## 5. 功能迁移映射

**复杂度**：S 约半天，M 约 1–3 天，L 超过 3 天。

**路径缩写**：`R/` = `src-tauri/src/clipboard/`，`F/` = `src/features/clipboard/`，`T/` = `src-tauri/src/translate/`，`TF/` = `src/features/translate/`，`W` = `src-tauri/src/windows/mod.rs`，`MOP` = `src-tauri/src/plugins/mac_overlay_panel.rs`，`UC` = `F/hooks/useClipboard.ts`，`P` = `F/components/ClipboardHistoryPanel/index.tsx`。

### 5.1 剪贴板历史

| Tauri 模块 / 文件 | 原生组件 / Apple API | 复杂度 | 备注 / 坑 |
|---|---|---|---|
| 轮询采集 `R/watcher.rs:35-61,201-386` | `ClipboardWatcher`：主线程 0.3s `Timer`；`changeCount` 没变就跳过 | M | 处理顺序固定：先查 types 里的隐私标记 → 来源 App → 文件 → 文本 → 图片。被跳过或被过滤的也要提交 changeCount；读不到（被占用）时不提交。启动时直接对齐当前 changeCount，不再像 Tauri 那样把当前内容重记一次（`:216-220`）。LSUIElement 应用符合 App Nap 条件，timer 会被降频，见 M2 验收 |
| 隐私标记 `R/privacy_markers.rs:38-42` | 把 `pasteboard.types` 和 3 个 nspasteboard.org 字符串比较（2026-09-28 体检 B4：再加 1Password 7、TypeIt4Me、Keyboard Maestro、KeeWeb 等 5 个常见类型） | S | 先查 types，再读内容 |
| 来源 App `R/source.rs:23-66` | `NSWorkspace.frontmostApplication`（排除自身），取名称和 `bundleURL.path` | S | ~~这是推测值，用户在 300ms 内切换 App 会记错，接受~~（体检 B6：先读写入方的 `org.nspasteboard.source`，通用剪贴板过来的记「其他设备」，都没有才用前台 App） |
| 过滤 `R/filter.rs:7-120` | `ClipboardFilter` 纯函数，配单测 | S | 排除 App：~~名称或路径子串匹配，不区分大小写~~ 按 bundle ID 精确匹配，设置里是 App 列表（体检 A11，旧关键词迁一次）。敏感文本：`sk-` 后跟 20 位、bearer ≥24、13–19 位且通过 Luhn、整段 ≤64 字节；体检 B5 补 GitHub / AWS / Slack / Google 密钥、私钥块、JWT。默认值已注册，不会出现「读配置失败、回退成空列表」 |
| 文本 `R/watcher.rs:276-327` | `string(forType: .string)` | S | trim 后为空或超过 5MB 时丢弃；用上一条的指纹防连续重复 |
| 富文本 `R/rich_text.rs:18,85-145` | 读：`.rtf` 优先，其次 `.html`，上限 2MB。写：一次 `declareTypes([rich, .string])` | S | 分两次 declare 会互相清空；富文本写失败时退回纯文本；~~关闭「保留格式」不影响已存富文本的粘贴~~ 格式总是采集，设置改为「默认粘贴为纯文本」（体检 A5） |
| 图片 `R/image_cache.rs`、`R/image_budget.rs:17-68` | `ImageStore`（@concurrent）：读 png/tiff；尺寸用 `CGImageSourceCopyPropertiesAtIndex` 读取，不解码；对编码字节做 SHA256 去重（有 PNG 用 PNG 字节，否则用转换后的 PNG 字节）；写 `images/{id}.png`。缩略图用 `CGImageSourceCreateThumbnailAtIndex` + `NSCache` | M | 像素上限 128MiB（按宽×高×4 算）；摘要为「图片 W×H」。`ponytail:` 注释写明「同一张图换了编码不会被去重」。字节预算 = ~~`SUM(image_byte_size)`~~ 普通图片的字节和（体检 B2：收藏 / 片段的不算，最新一张普通图片这一轮不删），超出时从最旧的可淘汰项开始，同时删文件和行。启动对账：cutoff 时间要在读 keep 集合**之前**取，keep 集合读失败绝不清理 |
| 文件 `R/paste.rs:383-419`、`R/image_cache.rs:460-493` | `readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly: true])`；大小取自 `attributesOfItem` | S | 摘要：单个显示文件名，多个显示「N 个文件」；目录不递归统计；按路径列表去重 |
| OCR `R/ocr_indexer.rs`、`R/ocr_local.rs:14-100` | `OCR`（@concurrent）：`RecognizeTextRequest`，`.accurate`，语言 `zh-Hans, zh-Hant, en-US`，开语言纠错，最多 4096 字符 | S | 语言必须显式指定；识别为无文字时写 `''`，之后不再重试；失败时留 NULL，下次启动重试；启动后串行补齐存量 |
| 自写抑制 `R/suppress.rs`、`F/lib/clipboard-hotkeys.ts:37-50` | `Paster.write`：写完记下 `changeCount`，watcher 遇到这个值就跳过（2026-09-28 体检 A30：本 App 生成的新文字用 `write(string:record: true)` 自己记进历史，见 mac-native §5）；同时加 `org.nspasteboard.TransientType`，共存的 Tauri watcher 也会跳过（2026-09-26 改：只有划词还原加 TransientType）。划词期间 `watcher.pause`，结束后把 lastChangeCount 对齐到当前值 | S | 删掉所有时间窗常量（450/500/250/800ms）；跳过时仍更新指纹 |
| 存储 `R/history_db.rs`，以及 `UC:280-331` 的 diff 持久化 | `Database`（libsqlite3 单连接 WAL）+ `ClipboardStore`（@Observable，内存数组，每次变更直接写一行） | M | 表结构见 §6。保留规则 `isRetained = 收藏 ∨ 片段`（~~∨ 已归组~~，体检 A1：分组并进收藏，归进收藏夹就是收藏）只在 Swift 里定义一处 |
| 合并去重 `F/lib/cloud-sync.ts:19-95` | `ClipboardStore.insert` | S | text 比内容，file 比路径，image 比 hash。合并后用新 id 和新时间戳；收藏取 OR；备注优先保留非空；kind 和 groupId 保留旧值 |
| 条数与天数上限 `F/lib/history-settings.ts:15-42` | 每次插入后、面板显示时各执行一次 | S | 默认 100 条 / 7 天，0 表示不限（2026-09-26 改：默认不限条数 / 7 天、图片 512 MB；体检 A4：去掉条数，只留「保留普通历史」1 天 / 1 周 / 1 个月 / 3 个月 / 1 年 / 永久）；只裁普通历史；删掉 10 分钟定时器 |
| 退出与锁屏清空 `src-tauri/src/lib.rs:43-57`、`R/clear_on_lock.rs:45-74` | `applicationWillTerminate`；`DistributedNotificationCenter` 监听 `com.apple.screenIsLocked` | S | 只清普通历史及其图片 |
| 浮层 `MOP:82-233`、`W:775-806` | `OverlayPanel`（见 §4）+ `NSHostingView` | L | 最大风险，M1 先打通 |
| 点外关闭 / Esc / 图钉 / 兄弟窗口豁免 `MOP:112-175,300-420`、`W:821-892` | global + local 鼠标监听、`cancelOperation`、`clipboardHideOnUnfocus` | M | 监听成对安装、成对卸载；图钉状态持久化 |
| 顶栏 `P:284-591` | 搜索框（包一层 `NSTextField`）、`Picker(.segmented)`（全部 / 收藏 / 片段）、计数徽标、图钉、齿轮 | S | 计数徽标的 4 种文案照搬 |
| 工具栏 `F/components/ClipboardFilterToolbar`、`F/lib/clipboard-content-form.ts:54-122`、`parse-clipboard-color.ts:149-184`、`clipboard-source-app-filter.ts:41-57` | `Menu` / `Picker`；`ContentForm` 纯函数，配单测 | M | 形态优先级：颜色 > JSON > URL > 代码。类型、形态、来源 App 之间的联动重置照搬；选中的来源消失时自动退回「全部」；任何筛选变化都滚到顶部、聚焦搜索框、选中第 0 条 |
| **分组筛选与管理** `F/components/ClipboardFilterToolbar:140-168`、`ClipboardGroupManageDialog`、`F/lib/clipboard-group-filter.ts:44-51`、`src/shared/services/clipboard-groups-db.ts` | 分组下拉 + 管理 sheet | S | ~~下拉项：全部分组 / 未分组 / 各分组（带数量，空组也显示）/「管理分组…」。管理对话框支持新建、重命名、删除。名称 trim 后截到 24 字，精确重名拦下；删除分组只解除归属；按创建时间升序~~ 体检 A1：分组并进收藏 = 命名收藏夹，筛选面板里放在「收藏」下面；管理收藏夹是键盘列表（↑↓、↩ / 双击就地改名、⌘⌫ 删除可 ⌘Z、拖动排序存 `position`）；名字超过 24 字拦住输入、不截断；删除后条目留在默认收藏 |
| 列表 `F/components/ClipboardHistoryVirtualList`、`F/lib/clipboard-list-rows.ts:28-66` | `ScrollView` + `LazyVStack(pinnedViews: .sectionHeaders)` + `ScrollViewReader` | M | 无搜索词时按天分组并吸顶（今天 / 昨天 / M月D日 / YYYY年M月D日，用 `Date.FormatStyle`）；~~有搜索词时按相关度排序、不分组~~ 有搜索词也按天分组、时间顺序（体检 A6）。新条目进来时，除非用户正在浏览（方向键、⌘数字、修饰键点击），选中项回到第 0 条（`UC:200-202`） |
| **行渲染细则** `F/components/ClipboardItemCard:152-250`、`F/lib/clipboard-list-label.ts:4-31` | `ClipRowView` | S | 图标位优先级：色块 > 缩略图 > App 图标 > 类型图标。主文案：text 取前 120 字；image 为「图片 · W×H · 大小」；file 为文件名或「N Files: a, b」。备注第二行只在收藏或片段上显示（体检 A3 起所有条目都能写、有就显示）。右侧依次：收藏夹徽标（仅当收藏夹筛选为「全部」时）、多选勾、前 9 行 ⌘1–9 提示（多选时隐藏）、带格式图标、收藏星 |
| 点击语义 `F/lib/clipboard-multi-select.ts:52-85` | `onTapGesture` + `NSEvent.modifierFlags` | S | 普通点击 = 选中并粘贴；⌘ 点击切换选中；⇧ 点击从锚点重新计算区间；多选状态下普通点击只收起多选 |
| 右键菜单 `ClipboardItemCard:254-327` | `.contextMenu` | S | ~~9 个菜单项及其出现条件照搬~~ 和 ⌘K 同一份动作表 `actions(for:targets:)`：名字、顺序、条件、分节一致，收藏夹是子菜单（当前的打 ✓、再点一次移出），不显示键位（体检 B12） |
| 空态 `P:623-678` | `ContentUnavailableView` | S | 4 种文案，加「清除筛选」「新建片段」按钮，附快捷键提示（`ClipboardShortcutsHint`）；骨架屏不做 |
| 键盘 `UC:874-960`、`P:434-487`、`F/lib/clipboard-hotkeys.ts:18-35` | 搜索框的 `control(_:textView:doCommandBy:)` 接 moveUp / moveDown / insertNewline / cancelOperation；⌘ 组合键在面板获得焦点时用本地 keyDown 监听处理 | M | ↑↓ 首尾循环，列表为空时不动。Enter 受 `clipboardPasteOnEnter` 控制；⌘Enter 总是粘贴，多选时合并粘贴。⌘1–9 按条目序号选中，`pasteOnEnter` 开启时同时粘贴。⌘A 全选可见条目。⌘D 收藏（多选时批量）。⌘⌫ / ⌘Del 删除。**⌘C 只复制**：不关面板、~~不置顶~~ 面板开着时列表不动、收起时再置顶（体检 A8），面板内提示「已复制」；片段复制同样展开占位符并强制纯文本；搜索框有选中文字时 ⌘C 让给系统。输入法组字时 Enter 和方向键由输入法处理，不会传过来，不再需要吞键 hack。对话框打开时列表热键让位 |
| 粘贴 `UC:649-708,827-872`、`R/paste.rs:105-307`、`src-tauri/src/platform/macos/mac_input.rs:24-155` | `Paster`：先写最简版本：隐藏面板（orderOut）→ 写剪贴板 → 检查 `AXIsProcessTrusted` → 发 ⌘V（`CGEventSource(.combinedSessionState)`，keyDown/keyUp 都设 `flags = .maskCommand`，投递到 `.cgSessionEventTap`），**不加任何等待** | M | 显式设置 flags 后，热键还按着的 ⇧ 不会混进去。Tauri 的「松修饰键 + 等 30ms」「图片或文件多等 100ms」「每个按键新建 HID 源」都先不搬；M1 手测某个 App 失败时才加对应延迟，并用 `ponytail:` 注释写明是哪个 App。始终注入普通 ⌘V；「纯文本粘贴」靠只写 `.string` 实现。粘贴后该条保持原 id、更新时间戳并置顶。多选全是文本时按复制先后（旧→新）用 `\n` 拼接一次粘贴（片段展开占位符，体检 B1），并生成一条新历史；~~含图片或文件时逐条粘贴，间隔 250ms~~ 全是文件时一次写进全部文件、一次 ⌘V，其余按复制先后逐条、间隔 250ms、文本间补换行（体检 B3）。未授权时内容仍留在剪贴板，面板内给出提示 |
| 片段 `F/lib/clipboard-snippet.ts:8-42` | 纯函数，配单测 | S | 占位符 `{date}`、`{clipboard}`、`{cursor}`，不区分大小写（体检 A7 加 `{time}` `{datetime}` `{weekday}` `{uuid}` `{clipboard:N}`）；片段粘贴强制纯文本；体检 C1 加「移出片段」。新建片段与已有同文本条目合并（`UC:1045-1063`） |
| 收藏 / 备注 / 编辑 / 删除 `UC:512-1068` | SwiftUI `sheet` / `alert` + 面板内撤销条 | M | ~~取消收藏时：普通历史连带清备注，片段保留备注。备注对话框：Enter 保存，Shift+Enter 换行，留空即清除~~（体检 A3：取消收藏不清备注，所有条目都能写，单行 ↩ 保存）。编辑内容后丢弃富文本。~~删除后 5 秒内可撤销并插回原位置~~（体检 A2：删除进撤销栈，⌘Z 连着撤，面板收起 / 退出时才删）；收藏或片段单条删除要确认，仅归组的和批量删除不确认 |
| 多选工具条 `F/components/ClipboardMultiSelectBar` | SwiftUI 工具条 | S | 合并粘贴 / 一起粘贴 / 依次粘贴（体检 B3）、批量收藏（全部已收藏则取消收藏）、放进收藏夹、删除 |
| 搜索 `F/lib/clipboard-keyword-search.ts:8-166`、`F/lib/clipboard-search-highlight.ts:31-51` | `Search` 纯函数（主线程），约 100 行照搬，配单测 | S | 多个词取 AND；~~备注权重 ×3~~（体检 A6：只过滤不排序）；备注、来源 App、路径这类短字段允许子序列匹配，正文和 OCR 只认连续子串；正文只取前 8192 字 |
| 预览 `F/components/ClipboardPreview`、`F/lib/clipboard-preview-actions.ts:14-45` | SwiftUI；长文本用包了一层的 `NSTextView`（TextKit 2） | M | 颜色色块；JSON 美化和字符串互转（只改视图，不改条目，~~切换条目时重置~~ JSON 默认美化，点过「原文」一次呼出里一直看原文、收起面板才复位，体检 A10）；代码用等宽字体、不做高亮；图片；单个图片文件；文件列表最多 120 条；**搜索词高亮**。底栏：时间（今年内 `MM/DD HH:mm`，跨年 `YYYY/MM/DD HH:mm`）和来源 App。操作按钮最多直接显示 3 个，其余进「…」：翻译 / 在浏览器打开 / 复制纯文本 / 在访达中显示（`activateFileViewerSelecting`） |
| 显示与隐藏 `P:223-277` | 面板的 show / hide 回调 | S | 显示时聚焦搜索框；**每次隐藏都重置**搜索、筛选、多选、选中项（回到第 0 条）和滚动位置，包括粘贴触发的隐藏。去掉 Tauri 的「粘贴除外」特例：原生在隐藏前已经拿到要粘贴的条目，不需要它 |
| 设置 `src/features/settings/components/SettingsClipboardTab`、`src/shared/lib/clipboard-history-settings.ts:3-27` | `ClipboardTab`（`Form`） | S | 13 项（去掉 `clipboardDisableTextSelection`）+ 图片占用显示；取值范围照搬 `src-tauri/src/core/config.rs:1235-1247`（体检 A4 A5 A11 起：保留普通历史一行、默认粘贴为纯文本、排除 App 列表，图片占用分「普通 · 留下的」） |
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
| 输入翻译 `T/pipeline.rs:103-125` | 显示空白浮窗并聚焦输入框 | S | ~~清空上一次的原文和译文~~（2026-09-28 体检 A14：热键是开关，再打开保留上次原文和结果、原文全选，中断的卡片重跑）；这个热键不做前台快照 |
| 会话与多引擎并行 `T/session.rs:21-40`、`TF/components/FloatingResult/index.tsx:111-118,468-756` | `TranslateCoordinator`（@MainActor @Observable）：新会话取消旧 Task，用 `withTaskGroup` 并行跑所有启用的服务 | M | 关闭浮窗时作废整个会话；前端结果缓存和 32s/190s 前端定时器都去掉 |
| 预处理与长度校验 `T/text_preprocess.rs:4-32`、`T/validation.rs:5-15` | 纯函数 | S | `translateDeleteNewline`；上限 32KB（按 UTF-8 字节）；百度 6000 字符、有道 5000 字符 |
| 语种检测 `src-tauri/src/lang_detect.rs:7-81` | `NLLanguageRecognizer` + `languageConstraints`（原来的 10 种语言，另加 zh-Hant） | S | 触发阈值照搬：含 CJK/假名/谚文 ≥2 字，或纯拉丁字母 ≥10 字；保留「先显示浮窗、再检测」的顺序 |
| 语言解析 `T/api.rs:116-344` | `LanguageResolver` 纯函数，配单测 | S | 双向互译的 4 个分支；按语系比较（zh-CN 和 zh-TW 算同一族）；兜底目标语言；发给智谱前目标语言不能是 auto；整个流程只检测一次 |
| 浮窗 `TF/components/FloatingResult` | `OverlayPanel` + `TranslatePanelView` | M | 顶栏：固定（`floatingPinned`）、复制即译、历史、设置、关闭。位置用 `setFrameAutosaveName` 记忆，替代约 120 行的屏内校验 |
| 失焦隐藏 `W:1743-1882` | `windowDidResignKey` + 判断是否固定 | M | 隐藏时若剪贴板面板还开着，把焦点交还给它；不还原前台 App。Tauri 的「显示后 500ms 内不自动隐藏」先不搬，M4 出现「刚显示就被隐藏」再加 |
| Esc `FloatingResult:859-873` | `cancelOperation` | S | 历史面板开着 → 只收起面板；否则关闭（~~未固定才关闭，固定时什么也不做~~：2026-09-28 体检 A9 改为固定着也关） |
| 输入框 `FloatingResult:993-1005` | 包一层 `NSTextView`，在 `doCommandBy` 收到 insertNewline 时看 Shift 是否按下 | S | Enter 提交，Shift+Enter 换行；输入法组字时不触发；修改原文会立即取消进行中的请求 |
| 原文操作行 `FloatingResult:903-971,1160-1238` | `AVSpeechSynthesizer`；复制走 `Paster.write` | S | 朗读：源语言为 auto 时用检测结果，再点一次停止，中文优先普通话、排除粤语声线。复制后图标变对勾 1.6s。还有清空、检测语种徽标。「翻译」按钮强制重译，3 种情况下禁用 |
| 语言栏 `FloatingResult:931-953,1241-1267` | 两个 `Picker` + 交换按钮 | S | 切换语言会写回全局 `sourceLang` / `targetLang` 并自动重译；交换规则照搬；两边都是 auto 时禁用交换 |
| 结果卡片 `TF/components/TranslateProviderCard`、`TF/components/TranslateMarkdown/index.tsx:16-34`、`TF/lib/translate-user-error.ts:7-42` | `ProviderCardView`；只对流式服务用 `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)` 渲染 | M | 可折叠，有新内容时自动展开；加载 / 错误 / 译文 / 占位 4 种状态；底部有朗读、复制、重试。链接只允许 http(s)，交给 `NSWorkspace.open`。错误文案映射照搬。没有启用任何服务时显示空态和「打开翻译设置」。流式输出时每 50ms 重建一次富文本 |
| 贴底滚动 `FloatingResult:432-455` | `.defaultScrollAnchor(.bottom)` | S | 用户往上滑后暂停跟随 |
| 自动复制 `FloatingResult:246-249,550-558` | 翻译完成的回调，经 `Paster.write` 写入 | S | 条件：`autoCopy` 打开且「复制即译」关闭；复制的是**列表中第一个已启用服务**的结果 |
| 历史写入 `T/history_db.rs:184-255`、`FloatingResult:283-329` | `HistoryStore`，和剪贴板共用一个 `Database` | S | 一次翻译只记一条，取列表中第一个已启用服务的结果（D15）。mode：输入翻译记 `input`，划词和复制即译记 `selection`。trim 后截到 10000 字；`ON CONFLICT(source_text,target_lang)` 时不覆盖收藏状态和 id；在同一事务里淘汰超出上限的非收藏条目 |
| 历史面板 `TF/components/TranslateHistoryPanel` | 浮窗内的覆盖视图 | S–M | 搜索防抖 180ms，LIKE 查询并转义 `%` `_` `\`，最多 200 条；↑↓、Enter、鼠标悬停同步选中。行时间：今天 `HH:mm` / `昨天 HH:mm` / 今年 `MM/DD` / 跨年 `YYYY/MM/DD`；底部显示「共 N 条 · 收藏 M」。复制、删除、收藏都是乐观更新，失败回滚。应用某条历史时：若它的目标语言不是 auto，先改全局目标语言，再让所有服务重译。清空时保留收藏并先确认；新会话开始时自动收起面板 |
| 复制即译 `T/clipboard_monitor.rs:18-58` | watcher 文本分支的回调 | S | 以下情况不触发：自写的 changeCount、开关关闭、与上次翻译过的文本指纹相同（原生起初漏了去重，2026-09-28 体检 B20 补上，另加自家浮层里的 ⌘C 不触发；A12 再跳过网址、路径、数字、超长和第一语言） |
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
| 关于 Tab 和更新日志弹窗 `src-tauri/src/commands/app_update.rs` 的 `arm_whats_new_release` | `lastSeenVersion` 存 UserDefaults；版本变化且不是首次安装时~~打开设置窗的关于 Tab~~ 弹刘海岛「已更新到 x」（2026-09-28 体检 A29）；`changelog.json` 随包分发 | S | 在线更新见 D8（`App/Updater.swift`） |
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
4. Esc：历史面板开着时只收起面板；否则关闭浮窗（2026-09-28 起固定着也关，体检 A9）。
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
| 全局热键 | `RegisterEventHotKey` 默认非独占：和别的 App 注册同一组合时注册会成功，按一次两个 App 都响应。只带 ⌥ 或 ⌥⇧ 的组合只在 15.0–15.1 上被拒（-9868），15.2 起已恢复 | ~~共存期间在 Tauri 设置里清空剪贴板、划词、输入翻译三个热键（原生不导入热键，用同样的默认组合）~~（2026-09-26：共存期结束，默认改为剪贴板 ⌥C、划词翻译 ⌥D；2026-09-28 体检 A15：输入翻译 ⌘⇧I → ⌥T，默认键全是单 ⌥）；M1 实验 `kEventHotKeyExclusive` 能否检测冲突；录制器不按组合一刀切，直接注册并把 -9868 映射成提示 |
| ~~与 Tauri 版共存~~（2026-09-26：共存期结束） | 两边的 watcher 都会采集剪贴板；两边都开复制即译时，一次 ⌘C 弹两个浮窗；一方的自动复制、粘贴、划词还原会进另一方的历史 | 原生自己写剪贴板时一律加 `org.nspasteboard.TransientType`，Tauri watcher 会跳过（`R/privacy_markers.rs:38-42`）。共存期操作：Tauri 只保留 ⌘⇧S 截图翻译（本机 500 条翻译历史里 358 条是截图翻译），关掉 Tauri 的复制即译。Tauri 的自动复制如果开着，截图翻译的译文会进原生的历史，接受或者关掉它 |
| 多实例 | 从 DMG 里运行一份、/Applications 再启动一份，热键重复、两个进程写同一个库 | 启动时检查同 bundle id 的其它实例（§4） |
| App Nap | 空闲时 timer 被降频，连续快速复制可能漏条 | M2 实测，漏了再持有 `beginActivity` |
| 旧库导入 | WAL 库只读打开失败；Tauri 运行中复制可能拿到写到一半的副本 | 复制到临时目录后读写打开，`PRAGMA quick_check` 不通过就中止并提示先退出旧版（§6） |
| Gatekeeper | 没有 Developer ID，第一次安装要手动放行 | D7 长期如此；发布说明固定写「仍要打开」和 `xattr` 两种做法；之后走 App 内更新（D8）不用再放行 |
| ~~Tauri 更新被影响~~ | 2026-09-27 起原生版发在自己的仓库（YyAdnBug/kitty-tools），不再影响 Tauri 仓库的 latest | 本仓库正常标 latest |
| ATS 与本地网络隐私 | http 地址被 ATS 拦截；访问局域网 LLM 时弹授权 | 设置 `NSAllowsArbitraryLoads` 和 `NSLocalNetworkUsageDescription`；127.0.0.1 不受影响 |
| Swift 6 严格并发和 C API（Carbon、AX、sqlite3） | 编译报错一大片 | 和 C 交互的代码只放在 `HotKeyCenter`、`Database`、`SelectionReader` 三个类型里；主线程回调里用 `MainActor.assumeIsolated`；禁止用 `@unchecked Sendable` 糊过去 |
| LSUIElement 应用的设置窗 | 窗口被压在其它 App 后面；固定的浮层盖在设置窗上面 | 先收起两个浮层，再切 `.regular` 并 `activate()`；macOS 14 起激活是协作式的，M3/M4 从三个入口实测，不行就退回 `activate(ignoringOtherApps:)` |
| 没在 macOS 26 上测过 | 开发机是 15，看不到 Liquid Glass 下的效果 | 标准控件会自动适配；2026-09-29 第 11 批起 Panel / HUD 的材质在 `#available(macOS 26, *)` 里换成 `NSGlassEffectView`（mac-whisker §2「26 分支」，只保证编译通过、15 上逐像素不变）；升级到 26 后按 §12「macOS 26 手测」检查一遍浮层再微调 |
| 内置密钥 | 内置智谱 key 可以被提取 | 只放在不入库的 `Secrets.xcconfig` 里（安全性与 Tauri 版相同） |
| 大数据量性能 | 5000 条 × 8KB 在主线程搜索 | 保留上限默认 100、本机 500；M2 用 5000 条实测，卡了再挪到 `@concurrent`；列表查询不取 `rich_data` |

---

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
- 启动器系统命令（2026-09-27，推翻 D2）：Alfred 的 18 个全做、锁屏用系统私有函数、只确认不可撤销的、中文名 + Alfred 关键词（四项都按推荐）。
- 2026-09-28 体检拍板（方案页 https://claude.ai/artifact/1KuAQRafw2E3QYAM4LULFR ，用户「全部按推荐」）。第 1 批外壳基础与全局：A9 固定只管点别处不收起，Esc / ⌘W / 再按热键一律收起，剪贴板、启动器也认 ⌘W，剪贴板 ⌘P 切换固定，删掉设置里的「点击面板外部时关闭」；A15 输入翻译默认 ⌥T；A29 更新后不开设置窗，改弹刘海岛「已更新到 x」+ 摘要；A30 本 App 生成的新文字写剪贴板时同时记进历史（`Paster.write(string:record:)`），历史里取出的、划词还原、面板里的色值块不记；B15 ⌘, 直达对应设置页；B17 卡片表面 `CardSurface` + `Style.inputFill`，卡片一律不加阴影；B29 `Style.copiedHold` 1.2 s；B30 `Shell/HoverTracker` 共用；B44 识字 text.viewfinder、截图翻译 translate；B48 录制拒绝通用编辑键并播报；B49 剪贴板访问改 PermissionRow；B50 主菜单关于 / 帮助、「退出 Kitty Tools」；B51 侧栏翻译在截图前、「登录时打开」「欢迎引导」；B52 菜单通知改 selector 观察者；B53 发丝线增强对比度 1 pt（`Hairline` / `hairlineBorder`）；B54 主按钮 `BrandButtonStyle`、速查表「完成」= ↩；B55 静默替换取词后先看取消；D20 引导第二屏加「登录时自动打开」勾选框（默认勾）。
- 2026-09-28 体检拍板（同一方案页，用户「全部按推荐」）第 2 批剪贴板数据与模型：A1 分组并进收藏（收藏 = 默认收藏夹，分组 = 命名收藏夹，保留规则只剩收藏 ∨ 片段；启动时迁移已归组的置收藏、`clip_groups` 加 `position`；⌘D 取消收藏同时移出收藏夹；删收藏夹不确认、条目留在收藏、⌘Z 可撤；管理收藏夹改键盘列表、拖动排序、24 字拦住不截断；取消收藏后超期的底栏提示、收起面板才清）；A2 删除进撤销栈、⌘Z 连撤，收起 / 退出时才提交，再复制同内容拿回原条目，撤销后播报；A3 备注所有条目都能写、取消收藏不清、不影响保留、单行对话框；A4 只留「保留普通历史」（1 天 / 1 周 / 1 个月 / 3 个月 / 1 年 / 永久，默认 1 周）+ 图片兜底（只算普通图片）；A5 格式总是采集，「默认粘贴为纯文本」开关，⌥↩ 反过来；A6 搜索只过滤、始终按天分组；A7 占位符 {time} {datetime} {weekday} {uuid} {clipboard:N}；A8 ⌘C 收起面板时置顶；A11 排除 App 改 bundle ID 列表；B1 合并粘贴展开片段；B2 图片预算只算普通图片；B3 多选文件一次粘、依次粘贴按复制先后补换行、动词一个函数给；B4 补 5 种隐私标记；B5 补 7 种密钥格式；B6 来源先读来源标记、通用剪贴板记「其他设备」；C1 移出片段；D4 菜单栏「暂停记录剪贴板」（不存盘）。实现时的一处取舍：备注输入框占位按实际行为写「搜索时能搜到」（方案原文「搜索时优先命中」和 A6 只过滤冲突）；「移出收藏夹」留在默认收藏，超期提示只在取消收藏 / 移出片段时出现。
- 2026-09-28 体检拍板（同一方案页，用户「全部按推荐」）第 3 批剪贴板面板交互：A10 JSON 默认美化，一次呼出里点过「原文」就一直原文、收起面板复位（美化结果按条目缓存）；B7 条目从列表消失后选中挪到下一条（`changingList`），⌘Z 后选中回来的那批最靠前的；B8 勾选随搜索 / 筛选 / 删除裁剪成看得见的，底栏计数和批量操作只对它们；B9 右键 / ⌘Y 页脚「复制」只复制被点的那条；B10 菜单开着时 ⌘ 键做了才收起，过滤框有字时 ⌘⌫ ⌘A ⌘V ⌘X ⌘Z 交给过滤框；B11 ⌘Y 里 ⌘C 只拷纯文本、经 `Paster.write(string:record:)` 记成无来源的新条目，大卡不跳；B12 右键菜单和 ⌘K 共用 `actions(for:targets:)`；B13 打开链接 / 文件、在访达中显示先收起（固定着不收）再后台打开；B14 ⌘T 翻译；B16 底栏提示和色值块复制主动播报；B18 编辑正文清掉链接缓存；C2 编辑 / 新建片段空白或没改动时保存置灰、提示只说相关的、新建片段加可选名称（存成备注）；C3 ActionMenu 分节（0.5 pt 发丝线，上下各 4 pt）+ 一级子列表「移到收藏夹 ›」，多选底栏「收藏夹…」打开同一份列表；C4 三个动作菜单共用 `ActionMenu.filter`（子串 + 中文标题拼音前缀）；D1 图片钉到屏幕（像素 ÷ 屏幕倍率，超 80% 缩小，鼠标所在屏中央，多张错开 24 pt）；D2 文件打开 ⌘O / 在访达中显示 ⌘R / 拷贝路径 ⌥⌘C、链接打开 ⌘O，⌘Y 页脚第 3 个胶囊按类型；D3 行拖到别的 App（AppKit 拖放会话，拖勾选项之一 = 全部勾选项，不算粘贴）。实现时的取舍：子列表那一行叫「移到收藏夹」、行尾 ›，不再加「…」（HIG：打开子菜单的项不写省略号，右键里是同名子菜单）；一个收藏夹都没有时第一级直接是「放进新收藏夹…」（进子列表只有一行没意义）；只勾一条时 ⌘K 和 ⌘E ⌘T ⌘O ⌘R 对着那一条（原来「有勾选就只给批量操作」，一条时没有对象歧义）；替代粘贴 / 复制为纯文本只给带格式的文本或多条；拖出用 AppKit 会话而不是 SwiftUI `onDrag`（一次只给得出一个 NSItemProvider，拖不了多个勾选项和一条里的多个文件）；「拷贝路径」同 ⌘C，面板开着时列表不动、收起时才记成新历史（A8）；⌘Y 里 ⌘C 按审查建议直接记（大卡开着选中不跳）。
- 2026-09-28 体检拍板（同一方案页，用户「全部按推荐」）第 4 批翻译：A12 复制即译静默跳过网址、路径、纯数字 / 符号、超长、目标自动时的第一语言；A13 设置 › 翻译「浮窗位置」跟随鼠标（默认）/ 上次位置（`OverlayPanel.present(anchor:)`）；A14 输入翻译热键是开关、再打开保留上次的原文和结果（原文全选）、中断的卡片重跑；A16 划词没取到文字时占位换成说明 + 播报；A17 智谱第二档换免费纯文本 glm-4.7-flash（查智谱开放文档：它在「免费模型」目录、纯文本、能关思考，2026-01 替代 GLM-4.5-Flash），旧的 glm-4.6v-flash 回落 glm-4-flash；A18 历史保留 1000 / 5000 / 不限（默认 5000）；A19 只有复制即译带来的原文不自动复制；A31 收藏全 App 统一 ⌘D，翻译浮窗和翻译历史的 ⌘S 不再响应；A32 识字和翻译共用一套分段接行（`OCR.paragraphs` 按行框间距 > 1.2 倍中位行高、或句末标点且短于中位行宽 80% 断段，换栏也断；`OCR.joiningLines` 纯文本按空行分段），截图翻译总是按段（段间空一行），识字设置改名「识字后把同一段里的换行接起来」；B19 截断检测；B20 自家浮层里的 ⌘C 不触发复制即译、来源记本 App，同一段不重翻；B21 内置服务可删、「+」加回；B22 历史分页 + 缓存；B23 收起停朗读、挑高音质声线；B24 百度 / 有道错误码译成中文；B25 「思考中」扫光 + 重译正文交叉淡变 0.18 s；B26 语言胶囊互换（glide）；B27 模型框下拉列服务端模型（`textInputSuggestions`）、进页自动取、↻ 重取；B28 设置 › 翻译加「清空翻译历史…」；C5 错误卡分配置（橙、只给打开设置、直达服务详情页）/ 网络与服务（红、重试，自建 AI 另给打开设置）；C6 历史 ⌘K（`ActionMenu`，右键同一份）、「⋯」菜单能导出；D15 「+ › AI 服务」厂商预设；D16 系统翻译只做文档验证，结论见 §10 D5（不做）。A20、A21 保持现状。实现时的取舍：思考信号用流里的空串（只在推理字段或 `<think>` 段里发，开头 role 那一段的空 content 不发），不改流的元素类型；截断在流结束时先给半截、再抛 `TranslateError.truncated`，静默替换因此照常报错不粘；配置类错误的字用默认色、只有钥匙是橙色（橙字在浅色卡底上对比度不够，同剪贴板底栏的警告）；智谱 `max_tokens` 仍按 mac-translate §3 固定 1024（glm-4.7-flash 文档写最大输出 128K，但没联网实测前不改，截断至少看得见了）；「浮窗位置」只记用户拖过 / 拖宽过的位置（`setFrameAutosaveName` 连跟随鼠标摆的位置也记，改成收起时比对后手动存）；内置服务从「+」加回来直接启用（删之前的密钥还在）、AI 服务等测试连接成功再自动启用；历史 ⌘K 的「导出」是一级子列表（全部 / 只收藏 × CSV / Anki TSV）。评审修复：不带锚点出现（输入翻译、「上次位置」）回到用户拖到的位置（`userFrame`），不再用上次跟随鼠标弹出的位置，直接 `orderOut` 收起的也在下次出现前补记拖动；自家浮层里的复制改在复制那一刻记 `Paster.panelCopyChangeCount`（轮询时看 key 窗口会在「复制后马上 Esc」「别处复制后马上呼出浮层」时判反，后者还会绕过排除的 App），来源标记优先于「自家窗口」；两个语言胶囊合成同一种视图，互换时才会滑到对方位置（分支不同只会原地淡变）；卡片标题的智谱模型名走回落后的值。
- 2026-09-28 体检拍板（同一方案页 https://claude.ai/artifact/1KuAQRafw2E3QYAM4LULFR ，用户「全部按推荐」）第 5 批启动器·改造与缺陷：A22「最近使用」改名「常用」；D13 收藏（⌘D、空查询先列收藏再用常用补足到 8 行、⌥⌘↑↓ 调顺序、最多 8 个、新表 `launcher_favorites`）；A23 % 改百分号、取模用 mod；A24 默认只让 Google 兜底；A25 标准目录里的 App 副标题留空、别处写位置；A26 内置动作和菜单栏同一份（`HotKeyAction.sections` + 复制即译、钉图、速查表、关于、检查更新，老 id 保留，`AppDelegate.run(_:)` 共用）；A27 没执行就收起的 60 秒内保留查询；B31 呼出前按目录修改时间重扫；B32 中文输入法的算式；B33 单输 cb 不独占、不分大小写；B34 带路径 / 端口时放宽网址后缀；B35 兜底只看显式网址；B36 同分系统命令最后；B37 行的 VoiceOver 动作与悬停；B38 移除常用可撤销；B39 书签设置写读到几条；C7 文件 ⌘K 打开方式 / 快速查看 ⌘Y / 移到废纸篓、→ 开动作菜单；C8 行右键 = ⌘K；D7 网址 ⌘K「用「X」打开」（⌘↩ = 第二个浏览器）、Markdown 链接 ⇧⌘C、复制标题；D10 fy 关键词直接翻译（单个英文词副标题是词典释义）。另：剪贴板的「拷贝路径」改叫「复制路径」，和启动器同名同符号（剪贴板、启动器都叫「复制…」，只有截图家族叫「拷贝」）。
- 2026-09-28 体检拍板（同一方案页 https://claude.ai/artifact/1KuAQRafw2E3QYAM4LULFR ，用户「全部按推荐」）第 6 批启动器·新功能：D6 网址 / 书签 / 历史 / 网页搜索行换成网站图标（不联网：本机 Chrome 的 Favicons 库 → 剪贴板链接预览取到的 → 青色地球色块；样式同 `ServiceTile`；设置 › 网页搜索列表同用；PLAN 不迁清单去掉「网站图标」）；D8 设置 › 启动器「浏览器书签」改名「浏览器书签与历史」，Chrome 下「也搜浏览历史」（默认关，最近 3000 条常去的页面，排在书签后、不重复）；D9 系统设置面板直接搜到、↩ 跳到对应页；D11 计算器单位换算（`Measurement`）、进制、千分位（⌘K 复制原始数字），汇率不做；D12 kill 进程 / 端口（↩ SIGTERM、⌘↩ SIGKILL 要上膛）。实现时的取舍：浏览历史最多列 5 行、不算本地结果（只有历史匹配上时兜底搜索照样在最后，免得常去的页面把「用 Google 搜」挤掉）；读 History 放进程外（`sqlite3`，刚克隆的库冷缓存在进程里读要 140 ms），网站图标每种开头只看 4 条映射在主线程查（8 个主机 12 ms）；系统设置面板「能跳到」先按 Info.plist 里系统自己声明的 `allowsXAppleSystemPreferencesURLScheme` 判断，逐个打开核对留到真机（§12 第 6 批第 3 条列全 45 个，评审指出推荐原文要求逐个核对，D9 状态记为「待逐个核对」）；面板身份按目录认、不按网址开头（评审修复：以前自建的 x-apple.systempreferences: 快捷链接收藏会被当成面板还原不出来而删掉）；五个只在特定情况出现的面板按名单不列；电池面板没有中文显示名，按机型叫法两个都写（「能耗 / 电池」，判断有没有电池要 IOKit，不在 C API 白名单里）；单位换算 ↩ 粘贴带单位（「6.2137 mi」，写回还能接着换算），「复制原始数字」只给数；kill 的进程列表按「监听端口 → 非系统目录 → 内存」排，系统服务不隐藏（照样能搜到、结束，↩ 不另确认：ps -U 按真实用户列，loginwindow 列不到，列得到的系统服务都由 launchd 重新拉起；评审提的「系统进程 ↩ 也上膛」没采纳，和拍板的「↩ SIGTERM 不确认」冲突），loginwindow 按路径再挡一道，本 App 起的 ps / lsof 按父进程去掉；「kill :」只按端口筛。
- 2026-09-28 体检拍板（同一方案页 https://claude.ai/artifact/1KuAQRafw2E3QYAM4LULFR ，用户「全部按推荐」）第 7 批截图：A28「另存为」不再改 ⌘S 快速保存的目录（存储面板自己记住上次的文件夹），设置 › 截图「快速保存到」显示文件夹图标和名字、能恢复默认；B40 长截图时和选区相交的钉图不接鼠标、淡到 0.3，结束放回，常驻缩略图收走；B41 截图家族统一「拷贝 / 存储到「桌面」/ 另存为…」；B42 长截图到底 / 到顶 / 最长不再橙色抖动，只有对不上抖，缺授权 / 出错橙字不抖，状态变了播报；B43 选区太矮时提示原因；B45 钉图可被 VoiceOver 读到、有自定义动作；B46 矮缩略图的图标按钮有名字；B47 多屏冻结帧同时截；C9 钉图 ⌘S 快速保存、⇧⌘S 另存为，右键菜单「拷贝 / 存储到「桌面」/ 另存为… / 透明度 / 原始大小 / 关闭」；D17 钉图右键「识字并拷贝 O」「翻译」，钉图是 key 时按 O 也行；D18 设置 › 截图「截图后在屏幕角落留缩略图」（默认开，关掉后卡片只闪一下）。补充拍板：A28、C9、D17、D18 按审查建议；B41 文案统一「拷贝 / 存储到「X」/ 另存为…」；C9 和 B41 一起改钉图右键菜单，D17 的识字 / 翻译加进同一个菜单，速查表钉图组同步。
- 2026-09-29 体检收尾（用户「继续第8批」，承接 2026-09-28「全部按推荐」）：版本 0.2.0，更新日志写进系统命令和 7 批里用户看得见的变化（默认值改变单独写明），0.1.0 条目是当时发布的内容、不改；收尾审查属实的问题全部修掉（历史 → 开菜单、清空后不能撤回、启动器预览时提示走岛、长截图收走剪贴板大卡、打开设置不推错页、翻译浮窗复制 / 收藏播报、菜单栏与启动器共用 MenuExtra、底栏提示 / 输入框焦点环 / 选中描边 / 播报 / 按天标题 / 存储叫法 / 导出菜单各收成一处），规则、PLAN §2 §4 §10 §12 按代码现状改。
- 2026-09-29 体检后新增第 9 批（用户原话「加个新功能，就是可以隐藏状态栏的图标」「状态栏的图标可以展示彩色和现在这种形式，彩色就是现在的 app 的应用图标」，并给了截图说明彩色 = 程序坞 / 访达里那张完整的 App 图标；按推荐）：M1 设置 › 通用新增「菜单栏」组，「在菜单栏显示图标」默认开，关掉只是 `NSStatusItem.isVisible = false`，不确认、不弹岛；隐藏后再打开一次 App（访达 / 启动器）走 `applicationShouldHandleReopen` 回设置，启动器内置动作补「退出 Kitty Tools」（菜单里的退出改成同一个 `MenuExtra.quit`）；behavior 没有 `.removalAllowed`，不做反向同步。M2「图标样式」单色（默认，模板剪影）/ 彩色（App 图标 1024 px 大图裁掉留白和阴影、只留主体，预先画成 16 pt @1x / @2x，不用 16 / 32 px 简化剪影）；分段控件塞不进图，改在左边放 1:1 实时预览。评审修复：「退出 Kitty Tools」同分时排在系统命令和 App 后面（`LauncherMatch.priority` 按条目算）、不记使用；同 bundle id 另一份拷贝被打开时对旧实例的包再 open 一次（发 reopen 进设置），不再只 activate；图标隐藏时「图标样式」标签也变淡；brand-icons.swift 注明彩色菜单栏图标按同样的留白 / 主体 / 超椭圆裁。0.2.0 未发布，更新日志 0.2.0 追加两条，不改版本号。
- 2026-09-29 体检后新增第 10 批（承接 2026-09-28 体检拍板「全部按推荐」；用户原话「启动器的上下箭头切换存在 bug，列表不会跟随滚动，剪切板历史记录就不存在这个 bug，这个是不是可以改成通用的方法呢」，按推荐）：列表选中跟随滚动抽成 `Shell/ListReveal.swift`，剪贴板、启动器、翻译历史共用——纯函数 `ListReveal.target(top:bottom:visible:coveredTop:inset:)`（被挡住才滚；往上顶对齐减去要让出来的高度，往下底对齐再留一格内缩，离顶不到两倍内缩回 0）+ `RevealsSelection`（接管 `.scrollPosition`、记可见区、key 变了按调用方的前缀和区间滚，曲线跟 `selectionMotion`）；启动器和翻译历史去掉 `ScrollViewReader.scrollTo(id)` 和行上滚动用的 `.id`（LazyVStack 未实例化的行滚不准，就是用户报告的根源），回到一组第一行连分组标题一起露出，启动器新结果时「露出第 0 行」就是回到顶部、文件结果后续批次保留选中时露出那行；剪贴板行为不变（吸顶标题 24 照旧让出来）。实现时的取舍：启动器 / 翻译历史往上滚时顶上留和底下一样的内缩（6 / 10），上下对称；屏外实测快速连按时 SwiftUI 会吞掉上一段滚动动画末尾发的 `scrollTo`（新目标写进了 `ScrollPosition`、列表停在旧目标，12 个窗口里 3 个停在半路），所以看不看得见按上次滚动的终点判断，滚动停下来还没到目标时补滚一次（只补一次；用户拖动 / 滚轮时放弃），剪贴板一起受益。评审修复：`ScrollPosition` 的 `@State` 在面板上、列表会被空状态换掉，列表消失时复位（不然重建的列表停在旧 y、选中的第一行看不见，屏外探针 launcher-follow-reset 先复现再验证）；待滚目标只在 `ScrollPosition` 还等于自己写进去的值时算数（用户滚动、剪贴板换列表回顶都会换掉它，不再按旧终点判断、也不补滚拉回去），目标就是当前位置时不发原地 `scrollTo`（不然待滚目标清不掉，之后用滚轮滚开再按键会被当成看得见）。
- 2026-09-29 体检后新增第 11 批（承接 2026-09-28 体检拍板「全部按推荐」；用户原话「目前我使用的是 macOS 15，但是 macOS 26、27 是液态玻璃效果，我们需要适配吗」，拍板「现在按设计规范先写好」，只加 26 起才生效的分支、15 上完全不变，升级到 26 后再实测微调）：按 mac-whisker §1 原则 4、§2 皮肤表的 26 列，Panel（`OverlayPanel`：剪贴板、启动器、翻译、两个 ⌘Y）和有材质的 HUD（`HUDBar`：截图工具栏两段放进 `NSGlassEffectContainerView`、样式托盘、HUD 菜单、钉图圆钮与百分比；`ScrollCaptureHUD` 改成 NSView 包材质；尺寸胶囊 `SizeField` 零件搬进玻璃的 contentView；常驻缩略图 `hudSkin` 用 SwiftUI `glassEffect`）在 `#available(macOS 26, *)` 里换 `NSGlassEffectView`，内容进 contentView、不画自绘描边 / Rim / HUD 阴影，HUD 玻璃 darkAqua；降低透明度的 0.9 不透明底只留给 15；提示、放大镜信息卡 26 上仍是填充（遮罩 Canvas 里的 CALayer，换玻璃要另写布局，ponytail 写明）。评审修复：栏宽 / HUD 菜单行边距 / 钉图圆钮按钮边长改从 `HUDBar.materialInset` 算（26 铺满后不再偏 0.5–1 pt）；钉图两个圆钮、常驻缩略图的按钮各进一个玻璃容器（相邻玻璃互相取样不到）；工具栏 / 托盘 / HUD 菜单 / 尺寸胶囊还没合进同一个容器，ponytail 写在 `SelectionView.makeBars`；`ScrollCaptureHUD` 15 分支把圆角裁切、描边、rim 挪回毛玻璃自己的图层（和改前同构）；玻璃的 contentView 设自动缩放掩码；规则里「窗口阴影只有一层」改成待 26 实测；Island 纯黑、系统皮肤自动、`.icon` 等 26 实机（D12）。验证：改前改后截图自检逐文件比对无差异，26 手测清单写进 §12「体检后新增：macOS 26 手测」；不改更新日志（15 上看不到变化）。
- 2026-09-29 体检后新增第 12 批（承接 2026-09-28 体检拍板「全部按推荐」；用户原话「浏览器书签与历史缺少 Safari 浏览器，然后我们还支持了自动检测安装的浏览器吗，怎么提示，还没安装」，拍板「加 Safari + 只列装了的」）：浏览器表一处定义（`Launcher/Browsers.swift`：Safari、Chrome（含 Beta / Dev / Canary）、Edge（含 Beta / Dev / Canary）、Arc、Brave、Firefox、Vivaldi、Opera、Chromium），设置 › 启动器只列装了的（出现 / 设置窗变 key 时重查），每家一行 16 pt App 图标 + 名字 + 书签开关，开着时缩进一行「也搜浏览历史」；Safari 要完全磁盘访问权限（没授权橙字 +「去授权…」+ 说明，读失败不弹框，授权后重新变 key 就读到），默认关；Firefox 书签和历史都克隆后 sqlite3 进程外读；Chromium 系多配置同一套、网站图标从开着的 Chromium 系各家取（Safari / Firefox 图标库不读）；偏好换成 `launcherBrowserBookmarks` / `launcherBrowserHistory` 两个 id 列表，`Prefs.migrate` 搬旧键、删旧键；克隆连 -wal 一起。PLAN §10 不迁清单划掉「Safari / Firefox 书签」；0.2.0 更新日志里浏览历史那条改写（不改版本号）。
- 2026-09-30 体检后新增第 13 批（用户 2026-09-29 原话「期望内置一些常用的 logo icon，可以从 logo.dev 去获取，因为现在我有些翻译的 logo 不存在，比如我的 DeepSeek，OpenCode」，拍板「内置常见厂商 + 自动取官网图标」，不用 logo.dev）：认厂商一张表 `AIVendor`（关思考分档、max_tokens、logo 共用），内置 DeepSeek、Kimi、通义千问、豆包、硅基流动、OpenRouter、Ollama、Mistral、Grok、MiniMax 十张官网图（来源见 §10「翻译服务 logo（第 13 批）」）；表里认不出的自建 AI 服务懒取官网图标（复用剪贴板链接预览的下载器，磁盘缓存 Application Support/ServiceIcons，7 天后台刷新，本机 / 内网 / IP 不取），不加设置开关。
- 截图翻译（2026-09-24）：只用 Vision 本机识字；原文写剪贴板历史；默认热键 ⌥S。
- 启动器 / 截图（2026-09-24）：启动器首版做 App、书签、直达、网页搜索、最近使用、内置动作、计算器、cb，文件搜索与 kill 放 M11；标注首版做矩形、箭头、文字、马赛克；附加功能只做取色（长截图、延时、美化 / 水印不做；长截图 2026-09-25 改为做，见 §10 D1）；做钉图，不做截图历史和钉图历史。
