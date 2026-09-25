# AGENTS.md

`macos-native` 分支的 agent 项目指引（Cursor / Codex 直接读；Claude Code 经 `CLAUDE.md` 导入）。常驻红线在 `.cursor/rules/mac-native.mdc`。

## 项目概述

**kitty-tools 原生 macOS 版**：用 Swift 6 + SwiftUI / AppKit 重写的纯原生菜单栏工具，替代 Tauri 版的 macOS 端。基本自用：只支持 Apple 芯片（arm64），最低 macOS 15.0。

- **Phase 1（当前）**：剪贴板历史 + 翻译（划词 / 输入 / 复制即译 / 截图翻译，全部翻译服务），目标版本 0.1.0。截图翻译提前做了（Vision 本机识字，`Screenshot/`）；M12 按 Bob 补了浮窗快捷键、收藏导出、替换原文。
- **Phase 2 / 3（进行中）**：启动器（`Launcher/`，M7、M8、M11 已完成）/ 截图工具（`Screenshot/`，复用截图翻译的冻结帧和框选；M9 框选 + 复制 / 保存 / 钉图、M10 标注 + 识字已完成；长截图 2026-09-25 插入，代码完成待手测）。里程碑 M7–M13、已拍板的 D1–D4（D1 长截图已改为做）与不迁清单见 PLAN §10。
- 迁移期与 Tauri 版共存：Bundle ID `com.yy.kitty-tools.native`（Debug `com.yy.kitty-tools.native.dev`），显示名 `Kitty Tools Native`。
- **行为规格**：`macos/PLAN.md`。§4 架构与文件表，§5 逐行对应 Tauri 代码的 path:line，§6 数据迁移，§7 里程碑 M0–M6 与验收，§9 已知坑。

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
├── KittyTools/              # 同步文件夹：App/ Shell/ Storage/ Clipboard/ Translate/ Screenshot/ Settings/ Resources/
├── KittyToolsTests/         # 纯函数单测（Swift Testing），M2 起建
├── Config/                  # Base/Debug/Release.xcconfig、Info.plist（局部）、Secrets.xcconfig（不入库）
├── build-dmg.sh             # 打包：archive → 自检 → DMG → notes
├── .swift-format
└── PLAN.md                  # 行为规格
.cursor/rules/               # mac-native.mdc（常驻）、ponytail.mdc（只给 Cursor）
.claude/skills/mac-*/        # 按需技能，里程碑结束后补
src/ src-tauri/ html/ public/ scripts/ …   # Tauri 快照，只读参考
```

新文件放哪、叫什么，照 PLAN §4 的文件表；一个概念一个文件，不预建空目录。

## 常用命令（仓库根目录执行）

```bash
# 构建 / 单测（联网冒烟：前面加 TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，会真请求内置智谱）
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

# 打 Release DMG（产物在 macos/build/）
macos/build-dmg.sh

# 签名自检；辅助功能授权卡住时重置
codesign -d -r- <App 路径>
tccutil reset Accessibility com.yy.kitty-tools.native.dev
```

## 规则与技能

| 名称 | 类型 | 状态 | 何时加载 / 触发范围 |
|---|---|---|---|
| `mac-native` | 常驻规则 `.cursor/rules/mac-native.mdc` | 已有 | 始终加载 |
| `ponytail` | 常驻规则 `.cursor/rules/ponytail.mdc` | 已有 | 只给 Cursor；Claude 侧由用户级插件生效 |
| `mac-overlay-panel` | 技能 | 已有（M1，M9 补截图与钉图） | `Shell/**`、`Screenshot/**`、`Translate/SelectionReader.swift`；NSPanel、热键、前台快照、粘贴回原 App、划词时序、设置窗激活、截图框选遮罩、钉图 |
| `mac-clipboard` | 技能 | 已有（M3） | `Clipboard/**`、`Storage/Database.swift` |
| `mac-translate` | 技能 | 已有（M4） | `Translate/**` |

- 规则正文只写在 `.cursor/rules/mac-*.mdc`。技能目录 `.claude/skills/mac-<name>/` 里 `SKILL.md` 只写触发描述和红线速查，`rule.mdc` 是符号链接：`ln -s ../../../.cursor/rules/mac-<name>.mdc .claude/skills/mac-<name>/rule.mdc`。
- 动手前先读对应技能的 `rule.mdc` 全文。技能写成之前，按 PLAN 对应章节（§4、§5、§9）执行。
- 不另建 `mac-ui`、`mac-release`：UI 约定在 `mac-native.mdc`，发布约束在 `build-dmg.sh` 头部注释。

## Tauri 代码只作参考

- `src/`、`src-tauri/`、`html/`、`public/`、`scripts/` 等是 master `ee615b3` 的 Tauri 快照，**只作行为参考，不改不删**。本分支不 merge master，也不以合回 master 为目标。
- PLAN 里的 path:line 引用以这份快照为准。
- **只当行为清单，不照搬实现**：原生版只需兼容 macOS，算法 / 数据结构 / 表结构 / 时序 hack 按原生方式自己设计；发现的旧逻辑 bug 记入 PLAN §11。
- 最新 Tauri 行为和旧规则原文，读 master 工作区绝对路径 `/Users/yy/Desktop/yy/Codes/Tauri/kitty-tools`（例如 `…/src-tauri/src/…`、`…/.cursor/rules/…`），只读。

## 开发约定

- 用中文回答用户；文档写中文，代码注释可以写中文。
- 每个入口文件头部写注释说明用途。
- 禁止新增任何第三方依赖（SPM 包、构建 / 格式化工具都算）。
- 刻意的简化写 `ponytail:` 注释，写明上限和升级路径。
- commit 格式 `<type>: <description>`，type 取 feat / fix / ui / refactor / docs / perf / build / chore。
- **更新日志（必遵）**：改 `MARKETING_VERSION` 必须在 `macos/KittyTools/Resources/changelog.json` 追加该版本条目，`type` 只允许 feat / fix / perf / ui（refactor / build / chore 不进用户日志）；缺条目时 `build-dmg.sh` 直接中止。
- 发布：tag `macos-v*`；GitHub 只发 pre-release，不勾 Set as latest；不公证，发布说明固定附「系统设置 › 隐私与安全性 › 仍要打开」步骤。

## 给 agent 的工具

- **Apple API 文档**：任意 `https://developer.apple.com/documentation/<path>` 后面加 `.md` 就能拿到 Markdown，直接 WebFetch（HIG 没有 `.md` 版）。
- **Xcode 自带的 Apple agent 文档**：路径和篇目见 `mac-native.mdc` 文末，只按绝对路径读，不拷进仓库。
- **sosumi MCP**（已接入）：查 Apple 文档、HIG、WWDC 字幕。Claude 读 `.mcp.json`，Cursor 读 `.cursor/mcp.json`，两边同一个 URL `https://sosumi.ai/mcp`。
- **swiftui-expert-skill**（avdlee，已装在用户级 `~/.agents/skills/`，不进仓库）：写 / 审 SwiftUI 代码时加载；macOS 相关看它的 `references/macos-*.md`。它偏 iOS，和本仓库规则冲突时以 `mac-native.mdc` 为准。重装：`npx skills add avdlee/swiftui-agent-skill -s swiftui-expert-skill -g -a claude-code -a cursor`。
- 不用：XcodeBuildMCP、swift-lsp、社区 concurrency 技能。编译诊断以 `xcodebuild` 为准，并发以 Xcode 自带的 `Swift-Concurrency-Updates.md` 为准。
- Claude 的自动记忆按路径隔离，本 worktree 从空记忆开始；仍适用的旧结论已写进 `mac-native.mdc`。
