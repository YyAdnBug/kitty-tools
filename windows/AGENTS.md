# windows/AGENTS.md

Kitty Tools 的 **Windows 原生版**（C# + WinUI 3，2026-10-23 立项）。在 `windows/` 下工作时以本文件和各版方案为准：根目录的 `AGENTS.md` 和 `.cursor/rules/mac-*.mdc` 只管 `macos/`，在这里只当行为规格读——而且只读方案里点名的那几节。

## 全程自主（2026-10-24 起）

用户的要求：**「全部开始，直至全部完成所有需求」**。从现在起不再一批一停，按下面的顺序一直做到底。

### 顺序

1. `PLAN-v2.md` 第 3–6 批（第 1、2 批已经做完，结论见它的 §2b）→ 版本 0.2.0
2. `PLAN-v3.md` 第 1–6 批 → 0.3.0
3. `PLAN-v4.md`（录屏和录音）第 1–4 批 → 0.4.0
4. `PLAN-v5.md`（和 Mac 互通的同步）第 1–3 批 → 0.5.0
5. 写「全部完成报告」（见文末）。
6. **之后**（2026-10-25 起，1–5 已经做完）：每一轮照样 fetch + rebase，按 `REVIEW.md`「待修」的 P0 → P1 → P2 → P3 一条一条修，修完一条就提交、推送（报告写在提交正文里，条目挪到「已修」）。待修清空了就停，等审查方加新的。R13–R21 都修完后升 0.6.0（changelog + `build-release.ps1`，不发布）。

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

### 全部完成报告

最后一批做完之后，单独提交一个 `docs(win): 全部完成报告`，正文汇总：

- 每一版做了什么；
- 没做成的（原因）、没测的、替用户定的；
- 最终的数字：空闲内存、四个功能各用一次后的内存、冷启动时间、发布体积（不含 pdb）；
- `HANDTEST.md` 里还标着「待定」「没测」的条目，给用户的真机手测清单。

## 先读

- **`PLAN-v2.md`**：第一版的审查结果、UI 风格（§3）、系统优化（§4）、自动更新（§5）、分批（§6）。§2b 是第 1、2 批之后定下来的结论。**后面几版的界面都要守 §3 的视觉规矩**。
- **`PLAN-v3.md`**：第三版（数据安全、翻译 / 剪贴板 / 启动器 / 截图补齐）。§1.5 的「互通约定」是给第五版铺路的，第三版就要照着做。
- **`PLAN-v4.md`**：第四版（录屏、录音）。
- **`PLAN-v5.md`**：第五版（和 Mac 互通的同步）。
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
