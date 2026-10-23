# windows/AGENTS.md

Kitty Tools 的 **Windows 原生版**（C# + WinUI 3，2026-10-23 立项）。在 `windows/` 下工作时以本文件和 `PLAN.md` 为准：根目录的 `AGENTS.md` 和 `.cursor/rules/mac-*.mdc` 只管 `macos/`，在这里只当行为规格读——而且只读 `PLAN.md` 点名的那几节。

## 先读

1. `PLAN.md` 全文：范围、技术栈、架构、每个模块的规格、分批和每批的验收清单。
2. 做到哪一批，就读 PLAN 里那一批引用的 mac 源码和规则章节（只看行为，不搬 AppKit 的做法）。

## 红线

- **只改 `windows/` 里的文件。** 根目录 `.gitignore` 要加东西时在报告里说明；`macos/`、根目录的 `AGENTS.md` / `CLAUDE.md`、`.cursor/`、`.claude/` 一律不动。
- **依赖只用微软自家的包**（PLAN §2）；要加别的，先在报告里说明理由，审查同意再加。
- **Native AOT 从第一天开，发布构建零 trim / AOT 警告。** 不用反射、`dynamic`、`{Binding}`、运行时 COM 互操作。
- **日志和错误信息里不出现**剪贴板内容、原文、译文、URL、请求头、密钥。
- **密钥只进凭据管理器**；内置智谱 key 只在不入库的 `Secrets.props` 里。
- **Windows 的 release 一律不标 latest**（`gh release create … --latest=false`），否则 mac 版收不到更新（PLAN §10）。发布前先问用户。
- 刻意的简化写 `// ponytail:` 注释，写明上限和升级路径。每个入口文件头部写注释说明用途。
- 界面文案不提其他产品。

## 工作方式

- **一批一停**（PLAN §0）：构建通过 → `dotnet test` 全部通过 → 按 `HANDTEST.md` 自己手测 → 提交 → 推送 → 停下等审查。
- **分支**：在 `windows-wip` 上做。推送前先 `git fetch origin && git rebase origin/main`（`windows/` 和 `macos/` 互不相交，基本不会冲突）。不改写已经推上去的提交，不碰 `main`；审查通过后由审查方把 `main` 快进到 `windows-wip`。
- **提交格式**：`<type>(win): <description>`，type 取 feat / fix / ui / refactor / docs / perf / build / chore。标题一行、70 字以内；空一行写正文，**正文就是这批的报告**：做了什么、怎么验的、量到的数、和 PLAN 不一样的地方和原因、待定的问题。
- **截图**：新界面的浅色、深色各一张，放 `windows/build/shots/<批次>/`（不入库），报告里列文件名。
- 拿不准的系统行为：先查 learn.microsoft.com，或看 PowerToys 源码（MIT）怎么做；查不到写进报告的「待定」，不自己发明。
- 用中文写文档和报告，代码注释可以写中文。

## 常用命令（仓库根目录执行）

第 0 批定下工程结构后，把下面的命令改成实际能跑的。

```powershell
# 构建、单测
dotnet build windows/KittyTools.slnx -c Debug -p:Platform=x64
dotnet test windows/KittyTools.Tests

# 联网冒烟：真的请求内置智谱，默认不跑
$env:KITTY_LIVE_TRANSLATE = "1"; dotnet test windows/KittyTools.Tests

# AOT 发布（检查零警告）
dotnet publish windows/KittyTools/KittyTools.csproj -c Release -r win-x64

# 打 zip + 发布说明（产物在 windows/build/）
pwsh windows/build-release.ps1
```

两样素材是在 Mac 上生成好提交的，Windows 上不用、也没法重新生成：拼音表 `KittyTools.Core/Resources/pinyin.txt`（`swift windows/tools/pinyin-table.swift`）、应用图标 `KittyTools/Resources/AppIcon.ico`（`swift windows/tools/app-icon.swift`）。
