# AGENTS.md

`main` 分支（原生版主线，2026-09-27 由 `macos-native` 改名）的 agent 项目指引（Cursor / Codex 直接读；Claude Code 经 `CLAUDE.md` 导入）。常驻红线在 `.cursor/rules/mac-native.mdc`。

## 项目概述

**kitty-tools 原生 macOS 版**：用 Swift 6 + SwiftUI / AppKit 重写的纯原生菜单栏工具，替代 Tauri 版的 macOS 端。基本自用：只支持 Apple 芯片（arm64），最低 macOS 15.0。

- **Phase 1（当前）**：剪贴板历史 + 翻译（划词 / 输入 / 复制即译 / 截图翻译，全部翻译服务），目标版本 0.1.0。截图翻译提前做了（Vision 本机识字，`Screenshot/`）；M12 按 Bob 补了浮窗快捷键、收藏导出、替换原文。
- **Phase 2 / 3（进行中）**：启动器（`Launcher/`，M7、M8、M11 已完成；M13 文件搜索 open / find 代码完成待手测，动作面板 / ⌘Y 快速查看 2026-09-28 体检第 5 批代码完成待手测；kill（进程 / 端口）、网站图标、Chrome 浏览历史、系统设置面板（还要逐个核对 45 个能跳到，PLAN §12）、单位换算 / 进制 2026-09-28 体检第 6 批代码完成待手测；系统命令对标 Alfred 2026-09-27 代码完成待手测）/ 截图工具（`Screenshot/`，复用截图翻译的冻结帧和框选；M9 框选 + 复制 / 保存 / 钉图、M10 标注 + 识字已完成；长截图 2026-09-25 插入，代码完成待手测）。里程碑 M7–M13、已拍板的 D1–D5（D1 长截图、D2 系统命令已改为做；D5 系统翻译文档验证后先不做）与不迁清单见 PLAN §10。
- Bundle ID `com.yy.kitty-tools.native`（Debug `com.yy.kitty-tools.native.dev`），不再改（改了会丢偏好、钥匙串和授权）；产品名 / .app 名 `Kitty Tools`（Debug `Kitty Tools Dev`，2026-09-26 起，之前叫 Kitty Tools Native）。和 Tauri 旧版同名：安装前先删掉 /Applications 里旧版的 `Kitty Tools.app`。
- **规格**：各 `mac-*` 规则（界面与动效按 `mac-whisker`）+ 对标产品（启动器 Alfred / Raycast、翻译 Bob、截图 iShot / CleanShot、剪贴板 Paste）。`macos/PLAN.md` 是迁移期的历史方案：§2 技术栈白名单、§4 架构与文件表、§8 打包、§10 / §12 里程碑与手测清单、§11 旧逻辑问题与语言规则仍有效，其余（§5 的 Tauri 映射、§6 数据迁移等）只是历史记录。

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
├── KittyTools/              # 同步文件夹：App/ Shell/ Storage/ Clipboard/ Translate/ Launcher/ Screenshot/ Settings/ Resources/
├── KittyToolsTests/         # 纯函数单测（Swift Testing），M2 起建
├── Config/                  # Base/Debug/Release.xcconfig、Info.plist（局部）、Secrets.xcconfig（不入库）
├── build-dmg.sh             # 打包：archive → 自检 → DMG + App 内更新用的 zip → notes
├── brand-icons.swift        # 品牌图标：角色「探头」的 AppIcon 10 张 + 菜单栏剪影 StatusIcon + DMG 背景（CoreGraphics 生成）
├── .swift-format
└── PLAN.md                  # 迁移期历史方案（§2、§4、§8、§10–§12 仍有效）
.cursor/rules/               # mac-native.mdc（常驻）、ponytail.mdc（只给 Cursor）
.claude/skills/mac-*/        # 按需技能，里程碑结束后补
```

新文件放哪、叫什么，照 PLAN §4 的文件表；一个概念一个文件，不预建空目录。

## 常用命令（仓库根目录执行）

```bash
# 构建 / 单测（联网冒烟：前面加 TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，会真请求内置智谱；
# 菜单开着时热键自检：TEST_RUNNER_KITTY_LIVE_HOTKEY=1 跑 HotKeyMenuTests，会弹真菜单、发一次合成按键；
# 应用内更新整条链路：TEST_RUNNER_KITTY_UPDATE_ZIP=<build-dmg.sh 出的 _arm64.zip 绝对路径> 跑 UpdaterTests，只替换临时目录里的假 App）
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools build
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools test

# 核对关键构建设置（期望 6.0 / 15.0 / NO / MainActor）
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools -configuration Release -showBuildSettings \
  | grep -E '^ *(SWIFT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_APP_SANDBOX|SWIFT_DEFAULT_ACTOR_ISOLATION) ='

# 格式：lint 无输出才算通过；format 就地改写
xcrun swift-format lint --strict -r macos/KittyTools
xcrun swift-format format -i -r macos/KittyTools

# 界面截图自检：屏幕外渲染各状态（含深色）为 PNG，不弹窗、不抢键盘
TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/kitty-shots xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  test -only-testing:KittyToolsTests/SnapshotProbeTests

# 打 Release DMG + App 内更新用的 zip（产物在 macos/build/）
macos/build-dmg.sh

# 重新生成 App 图标、菜单栏剪影和 DMG 背景（改角色或产品名只改这个脚本；加一个目录参数另存放大预览）
swift macos/brand-icons.swift

# 签名自检；辅助功能授权卡住时重置（按 bundle id，.app 改名不影响）
codesign -d -r- <App 路径>
tccutil reset Accessibility com.yy.kitty-tools.native.dev
# 重置了文件夹授权（SystemPolicyDownloadsFolder 等）时，把「问过」的标记也清掉，免得启动器文件搜索按旧状态读目录弹框
defaults delete com.yy.kitty-tools.native.dev folderAccessRequested
```

## 规则与技能

| 名称 | 类型 | 状态 | 何时加载 / 触发范围 |
|---|---|---|---|
| `mac-native` | 常驻规则 `.cursor/rules/mac-native.mdc` | 已有 | 始终加载 |
| `ponytail` | 常驻规则 `.cursor/rules/ponytail.mdc` | 已有 | 只给 Cursor；Claude 侧由用户级插件生效 |
| `mac-overlay-panel` | 技能 | 已有（M1，M9 补截图与钉图） | `Shell/**`、`Screenshot/**`、`Translate/SelectionReader.swift`；NSPanel、热键、前台快照、粘贴回原 App、划词时序、设置窗激活、截图框选遮罩、钉图 |
| `mac-clipboard` | 技能 | 已有（M3） | `Clipboard/**`、`Storage/Database.swift` |
| `mac-translate` | 技能 | 已有（M4） | `Translate/**` |
| `mac-whisker` | 技能 | 已有（2026-09-25） | 任何界面、动效、图标改动：Whisker 设计语言（三种皮肤、刻度、七条弹簧曲线、五个招牌时刻、各界面规范、无障碍、验收）；**用户要求以后都按它执行** |

- 规则正文只写在 `.cursor/rules/mac-*.mdc`。技能目录 `.claude/skills/mac-<name>/` 里 `SKILL.md` 只写触发描述和红线速查，`rule.mdc` 是符号链接：`ln -s ../../../.cursor/rules/mac-<name>.mdc .claude/skills/mac-<name>/rule.mdc`。
- 动手前先读对应技能的 `rule.mdc` 全文。没有对应技能的地方按 `mac-native.mdc` 和 `mac-whisker` 执行，文件归属看 PLAN §4。
- 不另建 `mac-ui`、`mac-release`：视觉与动效在 `mac-whisker`，其余 UI 约定在 `mac-native.mdc`，发布约束在 `build-dmg.sh` 头部注释。

## Tauri 版不作参考

- 分支：原生版在 `main`（2026-09-27 由 `macos-native` 改名）；`master` 仍是 Tauri 版，两条线互不合并。
- Tauri 快照（`src/`、`src-tauri/` 等）2026-09-27 按用户要求从本分支删除，仓库里只剩原生工程；要翻旧代码去 master `ee615b3` 或 git 历史。本分支不 merge master，也不以合回 master 为目标。
- **不作行为、界面、默认值、文案的参考**（用户 2026-09-26）：原生版有自己的样式和逻辑，不兼容 Tauri 版的数据和设置（它已不再运行）；以各 `mac-*` 规则、Whisker 和对标产品为准。
- PLAN §5 / §6 的 path:line 指的是 master 上的文件，只是迁移期的历史记录，不再是规格。

## 开发约定

- 用中文回答用户；文档写中文，代码注释可以写中文。
- 每个入口文件头部写注释说明用途。
- 禁止新增任何第三方依赖（SPM 包、构建 / 格式化工具都算）。
- 刻意的简化写 `ponytail:` 注释，写明上限和升级路径。
- commit 格式 `<type>: <description>`，type 取 feat / fix / ui / refactor / docs / perf / build / chore。
- **更新日志（必遵）**：改 `MARKETING_VERSION` 必须在 `macos/KittyTools/Resources/changelog.json` 追加该版本条目，`type` 只允许 feat / fix / perf / ui（refactor / build / chore 不进用户日志）；缺条目时 `build-dmg.sh` 直接中止。
- 发布：本仓库 github.com/YyAdnBug/kitty-tools（不碰 Tauri 版的仓库），tag `macos-v*`，正式 release、标 latest，附 DMG 和 `_arm64.zip`（App 内更新用）；不公证，发布说明固定附「系统设置 › 隐私与安全性 › 仍要打开」步骤（只有第一次安装要，之后 App 内更新）。

## 给 agent 的工具

- **Apple API 文档**：任意 `https://developer.apple.com/documentation/<path>` 后面加 `.md` 就能拿到 Markdown，直接 WebFetch（HIG 没有 `.md` 版）。
- **Xcode 自带的 Apple agent 文档**：路径和篇目见 `mac-native.mdc` 文末，只按绝对路径读，不拷进仓库。
- **sosumi MCP**（已接入）：查 Apple 文档、HIG、WWDC 字幕。Claude 读 `.mcp.json`，Cursor 读 `.cursor/mcp.json`，两边同一个 URL `https://sosumi.ai/mcp`。
- **swiftui-expert-skill**（avdlee，已装在用户级 `~/.agents/skills/`，不进仓库）：写 / 审 SwiftUI 代码时加载；macOS 相关看它的 `references/macos-*.md`。它偏 iOS，和本仓库规则冲突时以 `mac-native.mdc` 为准。重装：`npx skills add avdlee/swiftui-agent-skill -s swiftui-expert-skill -g -a claude-code -a cursor`。
- 不用：XcodeBuildMCP、swift-lsp、社区 concurrency 技能。编译诊断以 `xcodebuild` 为准，并发以 Xcode 自带的 `Swift-Concurrency-Updates.md` 为准。
- Claude 的自动记忆按路径隔离，本 worktree 从空记忆开始；仍适用的旧结论已写进 `mac-native.mdc`。
