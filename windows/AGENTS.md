# windows/AGENTS.md

Kitty Tools 的 **Windows 原生版**（C# + WinUI 3，2026-10-23 立项）。在 `windows/` 下工作时以本文件和各版方案为准：根目录的 `AGENTS.md` 和 `.cursor/rules/mac-*.mdc` 只管 `macos/`，在这里只当行为规格读——而且只读方案里点名的那几节。

## 全程自主（2026-10-24 起）

用户的要求：**「全部开始，直至全部完成所有需求」**。从现在起不再一批一停，按下面的顺序一直做到底。

### 顺序

1. `PLAN-v2.md` 第 3–6 批（第 1、2 批已经做完，结论见它的 §2b）→ 版本 0.2.0
2. `PLAN-v3.md` 第 1–6 批 → 0.3.0
3. `PLAN-v4.md`（录屏和录音）第 1–4 批 → 0.4.0
4. `PLAN-v5.md`（和 Mac 互通的同步）第 1–3 批 → 0.5.0
5. 写「全部完成报告」（已做完；第六版第 0 批把它改写成 `STATUS.md`）。
6. `PLAN-v6.md`（收尾与优化）第 0–7 批 → 0.6.0。2026-10-25 起做这一步：每批开始前照样先修 `REVIEW.md` 的「待修」。
7. 第 7 批做完就停，等审查方。之后审查方再往 `REVIEW.md` 加「待修」，照样一条一条修、修完一条推一次。
8. `PLAN-v7.md`（界面对齐 mac；2026-10-26 用户拍板 U1–U6 全部按推荐）第 1–6 批 → 0.7.0。v6 第 6 批剩下的几项做完后开始；其中第 1 项「主题资源」不在 v6 里做，并进 v7 第 1 批。每批开始前照样先修 `REVIEW.md` 的「待修」。

`PLAN.md` 是第一版的规格，后面几版没提到的地方照它。

### 每一批的流程

1. **开始前**：`git fetch origin && git rebase origin/windows-wip`，读一遍 `windows/REVIEW.md`。审查方会随时往里面加「待修」的条目：有就**先修完**，把条目改成「已修（提交号）」，再做这一批。
2. **做**：按方案里那一批的内容和验收做。
3. **结束**：过一遍下面的自查清单 → 提交（正文就是报告）→ `git fetch origin && git rebase origin/windows-wip` → 推送 → 截图推到 `windows-shots` 分支的 `<版本>-batch-<N>/` 目录 → **直接开始下一批**，不等审查。

### 每批结束的自查清单

1. `dotnet test` 全过；这一批新加的纯函数都有单测。
2. Release AOT 发布 x64 和 ARM64，**零 trim / AOT 警告**；发布目录里有 `KittyTools.pri` 和 `Microsoft.UI.Xaml.Controls.pri`（第二版第 2 批的构建检查会管）。
3. 跑一遍内存探针（`KITTY_MEMORY_PROBE=1`），和上一批比：哪一项涨了超过 5 MB 要在报告里解释。
4. 空闲 CPU（只有托盘、静置 60 s）为 0。
5. 新界面：浅色、深色、高对比度各截一张；只有图标的按钮都有读屏名字；代码里写死的颜色数量不增加（第二版第 3 批会清到只剩截图 HUD 那一套）。
6. 新加的日志里没有剪贴板内容、原文、译文、URL、请求头、密钥。
7. `HANDTEST.md` 追加这批的手测，自己走一遍。
8. 报告写全：做了什么；怎么验的；量到的数；和方案不一样的地方（「替用户定的」）；没做成的、没测的。

### 遇到问题怎么办（都不停下来）

- **方案里写了退路的**：用退路，报告里说明。
- **方案里没写到的**：按「和 mac 版的行为最接近 + 符合 Windows 习惯」自己定，写进报告的「替用户定的」，继续。
- **试了做不出来的**：写进报告的「没做成」（原因、试过什么），在 `HANDTEST.md` 里标「待定」，**跳过，继续下一项**；全部做完后在最终报告里汇总。
- **条件不够测不了的**（第二块屏、Word、ARM64 真机、某个服务的 key、真的 Mac）：照样做，报告里写「没测」，继续。
- **构建或测试红了**：先修，修不好就回到上一个能过的状态，把这一项按「没做成」处理。**不许为了让测试变绿去删测试、改断言。**

### 只有这几种情况停下来问用户

- 要加一个**不是微软的**包，而且找不到替代做法；
- 要**发布** release、打 tag；
- 要**强推**、删分支、动 `main`；
- 要用用户**真实的**账号、密钥、数据或同步文件夹（测试一律用临时目录和假数据）。

除此之外一律不停。

### 版本和发布

- 每一版的最后一批：改 `Directory.Build.props` 的版本号，在 `KittyTools/Resources/changelog.json` 加这一版的条目（type 只用 feat / fix / perf / ui），跑 `build-release.ps1` 把 x64 / ARM64 的 zip 和 `.sha256` 准备好，报告里写产物路径。
- **不发布**。发布由用户决定；发布时一律 `--latest=false`（mac 版的更新检查只认 latest 且只认 `macos-v*`，Windows 版成了 latest，mac 用户就收不到更新了）。

### 现状文档 `STATUS.md`

第六版第 0 批起，「全部完成报告」改成 `windows/STATUS.md`，写的是**现状**，不是历史。每批收尾时更新：

- 现在能做什么；
- 最新的数字（口径见 `PLAN-v6.md` §0）：空闲内存、四个功能各用一次后的内存、冷启动、发布体积（不含 pdb）；
- 没做成的、没测的、替用户定的；
- `HANDTEST.md` 里还标着「待定」「没测」的条目，也就是给用户的真机手测清单。

## 先读

- **`PLAN-v2.md`**：第一版的审查结果、UI 风格（§3）、系统优化（§4）、自动更新（§5）、分批（§6）。§2b 是第 1、2 批之后定下来的结论。**后面几版的界面都要守 §3 的视觉规矩**；和 `PLAN-v7.md` 冲突的地方以 v7 为准。
- **`PLAN-v3.md`**：第三版（数据安全、翻译 / 剪贴板 / 启动器 / 截图补齐）。§1.5 的「互通约定」是给第五版铺路的，第三版就要照着做。
- **`PLAN-v4.md`**：第四版（录屏、录音）。
- **`PLAN-v5.md`**：第五版（和 Mac 互通的同步）。mac 的源码在 `reference/mac-sync/`。
- **`PLAN-v6.md`**：第六版（收尾与优化）。§0 的规矩（数字口径、录屏只录测试窗口、COM 写法、删比加好）这一版起一直有效。
- **`PLAN-v7.md`**：第七版（界面对齐 mac）。§2 的刻度和共用部件定下来以后，所有界面都从那里取；规格是 mac 的 Whisker（`.cursor/rules/mac-whisker*.mdc`），只读方案里点名的章节。
- **`PLAN-setup.md`**：exe 安装程序（2026-10-26）。**由 Claude 在单独的会话里做**：`windows/KittyTools.Setup/` 和方案 §3 点名的 Core 文件、测试、脚本，交接之前你们不要动。§4 是 App 项目里要开的三个口子，碰到时照那里的约定来。做完后审查方会在 `REVIEW.md` 里加一条「安装程序真机验收」交给你们跑。
- `PLAN.md`：第一版的规格。
- 做到哪一批，就读那一批引用的 mac 源码和规则章节（只看行为，不搬 AppKit 的做法）。

## 红线

- **只改 `windows/` 里的文件。** 根目录 `.gitignore` 要加东西时在报告里说明；`macos/`、根目录的 `AGENTS.md` / `CLAUDE.md`、`.cursor/`、`.claude/` 一律不动。
- **依赖只用微软自家的包**（PLAN §2）。
- **Native AOT，发布构建零 trim / AOT 警告。** 不用反射、`dynamic`、`{Binding}`、运行时 COM 互操作（COM 走 CsWin32 生成的、AOT 能用的写法；CsWin32 生成不了的接口，自己用函数指针按 vtable 调，参考第二版第 1 批报告里图标那一条的处理）。
- **日志和错误信息里不出现**剪贴板内容、原文、译文、URL、请求头、密钥。
- **密钥只进凭据管理器**；内置智谱 key 只在不入库的 `Secrets.props` 里。
- **测试不碰用户的真实数据**：数据库、设置、凭据、同步文件夹一律用临时目录或 `.Dev` 那一套。
- 刻意的简化写 `// ponytail:` 注释，写明上限和升级路径。每个入口文件头部写注释说明用途。
- 界面文案不提其他产品。
- **结束进程只按自己起的那个 PID**，不按进程名（`taskkill /im`、`Stop-Process -Name`）：按名字会把用户正在用的那份 Kitty Tools、或者别的 agent 正在跑的测试一起杀掉。

## 和 mac 版统一什么（2026-10-26）

用户定的方向：**界面尽量和 mac 一致**（`PLAN-v7.md`，U1–U6 已拍板）。方案没写到、拿不准的界面问题，按下面两张单子判断。

**跟 mac 走**（规格是 Whisker：`.cursor/rules/mac-whisker*.mdc`；尺寸、字号、颜色怎么换算看 PLAN-v7 §2）：

- **品牌**：App 图标、角色、品牌粉、家族色、翻译服务的标识色和 logo。
- **功能和行为**：怎么去重、怎么排序、怎么出结果、有哪些快捷动作、怎么撤销，以及各项默认值。
- **布局**：剪贴板是单列透镜，启动器是单行，翻译浮窗分三层，还有搜索线、「动词 + 键帽」的底栏、两段式截图工具栏。
- **刻度**：间距、各种文字用多大的字、颜色的值、强调色 8 色，以及强调色只用在哪些地方。
- **动效**：七条曲线和它们的用法；回弹（bounce）不超过 0.25；系统关了动画效果时只留淡入淡出。
- **文案**：功能名、设置项的名字和分组、提示语、更新日志的写法。同一个动作，全 App 用同一个名字、同一个图标。
- **数据**：导出、同步、片段占位符的格式（PLAN-v3 §1.5、PLAN-v5）。

**跟 Windows 走**（系统画的东西，或者 Windows 用户靠手感记住的东西）：

- **窗口外壳**：DWM 画的 8 圆角、系统阴影、亚克力 / Mica；窗口退场不淡出（PLAN-v7 §1）。
- **设置窗的外壳**：Windows 11 设置的样子，NavigationView + 设置卡（U6）；里面的内容对齐 mac。
- **字体**：Segoe UI Variable、Cascadia Mono。
- **图标字体**：Segoe Fluent Icons。每个符号照 mac 的图标表一一对应，意思和 mac 一样，字形用 Windows 的。
- **常驻入口**：托盘，不是菜单栏。mac 的刘海岛在 Windows 上就是屏幕上方的胶囊，跟刘海有关的交互不移植。
- **快捷键**：写成 `Ctrl + Shift + S`，不写 ⌘ ⌥ 这些符号。默认键避开 Windows 和常用软件已经占用的组合，PLAN.md 里定过的照旧。
- **系统自己的东西**：右键菜单、文件对话框、通知、开始菜单、读屏（UIA），都用系统的。

**两边冲突时**：

- 先照 mac 做。
- 只有两种情况按 Windows 来，并在报告的「替用户定的」里写清楚：
  - 做到 mac 那样，要放弃系统的材质、阴影或无障碍；
  - 和 Windows 用户已经习惯的做法冲突。
- mac 后来新加的功能（比如截图历史、长图标注）：功能跟上，界面按上面两张单子画。

## 提交、分支、截图

- **只推 `origin`（`github.com/YyAdnBug/kitty-tools`）**，不推任何 fork。推送失败先 `git fetch origin && git rebase origin/windows-wip` 再推；还不行就停下来报告，不要换远端。
- **分支**：在 `windows-wip` 上做。审查方也会往这个分支提交文档（`REVIEW.md`、方案的修订），所以推送前一定先 rebase 到 `origin/windows-wip`；不 rebase `origin/main`（并进 `main` 时由审查方处理）。**绝不强推**，也不改写已经推上去的提交。
- **提交格式**：`<type>(win): <description>`，type 取 feat / fix / ui / refactor / docs / perf / build / chore。标题一行、70 字以内；空一行写正文，**正文就是这批的报告**。一批可以拆成几个提交，报告写在最后一个里。
- **截图**：推到孤儿分支 `windows-shots`（`git worktree add ../kitty-shots windows-shots` 之后在那个目录里提交、推送），每批一个目录、6–10 张、单张 < 500 KB；动效录 3–5 秒的短视频（mp4 < 5 MB）也放这里。
- **截图里不能有别的东西**（`windows-shots` 在公开仓库里）：只截我们自己的窗口（按窗口矩形裁，或只抓我们的 HWND）；录屏要验证时，先开一个自己的满屏测试图案窗口，只录它。整个桌面的图一律不推；推之前自己看一遍，不能出现别的 App、别的对话、IP、账号。
- **`windows-shots` 在 2026-10-25 被改写过**（删了五张拍到整个桌面的图）：下次往那里提交前，先在 `../kitty-shots` 目录里 `git fetch origin && git reset --hard origin/windows-shots`。不要 pull、也不要 rebase 本地旧的那条分支，否则删掉的图会被带回来。
- **提交信息用不带 BOM 的 UTF-8**：写进文件再 `git commit -F`；PowerShell 7 用 `Set-Content -Encoding utf8NoBOM`（5.1 的 `-Encoding UTF8` 会带 BOM）。
- 拿不准的系统行为：先查 learn.microsoft.com，或看 PowerToys 源码（MIT）怎么做。
- 用中文写文档和报告，代码注释可以写中文。

## 常用命令（仓库根目录执行）

```powershell
# 构建、单测
dotnet build windows/KittyTools.slnx -c Debug -p:Platform=x64
dotnet test windows/KittyTools.Tests

# 联网冒烟：真的请求内置智谱，默认不跑
$env:KITTY_LIVE_TRANSLATE = "1"; dotnet test windows/KittyTools.Tests

# AOT 发布（检查零警告、PRI 齐全）
dotnet publish windows/KittyTools/KittyTools.csproj -c Release -r win-x64

# 内存探针（每步空闲 30 s；_FAST=1 只用来调探针本身）
$env:KITTY_MEMORY_PROBE = "1"

# 打 zip + .sha256 + 发布说明（产物在 windows/build/）
pwsh windows/build-release.ps1
```

在 Mac 上生成好、提交进来的素材（Windows 上不用、也没法重新生成）：

- 拼音表 `KittyTools.Core/Resources/pinyin.txt`（`swift windows/tools/pinyin-table.swift`）；
- 应用图标 `KittyTools/Resources/AppIcon.ico` 和录制中的托盘图标 `AppIconRecording.ico`（`swift windows/tools/app-icon.swift`）；
- 同步格式样本 `KittyTools.Tests/Fixtures/sync-golden.json`（`swift windows/tools/sync-golden.swift`，第五版用）。
