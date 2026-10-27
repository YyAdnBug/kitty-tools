# windows/PLAN-setup-inno.md：安装程序换成 Inno Setup 7

2026-10-27。用户：「安装 exe 的界面太简陋了，市面上没有现成的工具能使用吗，期望优化」→ 看过几种做法以后定了：「安装程序换成 Inno Setup 7。把方案和 REVIEW 条目写好推到 windows-wip，给 Windows 那边的 agent 做」。

- **谁做**：Windows 上的 agent，照 `AGENTS.md`「每一批的流程」做，一批做完；对应 `REVIEW.md` 的 R65。**在 0.1.0 打包之前做**（R53）：0.1.0 是第一个对外版本，先用自己的安装程序发、以后再换，就得给真用户做一次「旧安装程序 → Inno」的迁移；现在换，一个真用户都没有，不用迁移。
- **红线的例外**（用户 2026-10-27 定）：打包用 Inno Setup 7。它只在 `build-release.ps1` 里用，不进 App、不进 NuGet 依赖。其余红线照旧。
  - 装法：`winget install --id JRSoftware.InnoSetup -e`，装完 `ISCC.exe /?` 看版本是 7.x，不是就从 jrsoftware.org 装 7.1 或更新的版本。
  - 授权：作者「请商业用户购买授权」，是请求，不是强制；我们是个人项目，不用买，许可证里要求的版权声明 Inno 自己会带上。
- **替代的东西**：`PLAN-setup.md` 的 S1（安装程序长什么样）、S2（界面）、S6（换文件）、S7 里的标记文件和 Uninstall.exe、S9 的卸载流程、§2.1 载荷尾巴、§2.3 卸载前的检查，都换成下面的做法。S3（装到哪、不许装到哪）、S4（装过的就更新）、S5（开着先叫它退出、不按进程名杀）、S8（只问一个「开机时自动打开」）、S12（不签名）这几条**用户能看到的行为照旧**，只是改用 Inno 来实现。
- **为什么是它**：免费；6.6 起有 `windows11` 风格和跟随系统的深色模式，7.0.2 起自带官方的简体中文；能选安装位置、不要管理员权限，在「设置 › 应用」里能卸载。Velopack 不能选安装位置，WiX / MSI 的界面老、写起来繁琐，MSIX 不签名装不上。
- **删比加好**：`KittyTools.Setup/` 整个项目（五个文件约 1900 行）、`Core/SetupPayload.cs` 和 `Core/SetupRules.cs` 的大半，换成一个一百多行的 `installer/KittyTools.iss`。

## 1. 定下来的做法

| # | 问题 | 定了 |
|---|---|---|
| I1 | 出几个 exe | 和现在一样，每个架构一个：`KittyTools-<版本>-windows-<x64\|arm64>-setup.exe`，release 附件的名字不变。`ISCC /DArch=x64` / `/DArch=arm64` 各编一次 |
| I2 | AppId | **`{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}`，以后永远不改**：「设置 › 应用」里的登记（`HKCU\...\Uninstall\{FF0E2BF7-…}_is1`）、更新时找原来装在哪，都靠它 |
| I3 | 长相 | `WizardStyle=modern dynamic windows11`（跟着系统深浅色）。右上角小图 `installer/wizard-small-*.png`，完成页左边 `installer/wizard-large-*.png`；两组都是透明底的图标，深浅色都能用，由 `tools/app-icon.swift` 生成（审查方已经出好、提交了）。安装程序自己的图标用 `KittyTools/Resources/AppIcon.ico`。只用简体中文（`compiler:Languages\ChineseSimplified.isl`），不弹语言选择 |
| I4 | 有哪几页 | 新装：**选位置**（默认 `%LOCALAPPDATA%\Programs\Kitty Tools`，下面加一个勾选框「开机时自动打开」，默认勾上；按钮写「安装」）→ 安装进度 → **装好了**（勾选「现在打开 Kitty Tools」，默认勾上）。欢迎页、准备安装页、开始菜单文件夹页都不要。更新：不问位置、不问开机启动（照原样），按钮写「更新到 x.y.z」，然后是进度和装好了 |
| I5 | 装在当前用户名下 | `PrivilegesRequired=lowest`，不给改成管理员模式（`PrivilegesRequiredOverridesAllowed` 不写）；`DefaultDirName={autopf}\Kitty Tools`（这种模式下就是 `%LOCALAPPDATA%\Programs`） |
| I6 | 位置的规矩（照 S3、§2.2） | 用户选的文件夹名字不是「Kitty Tools」就在后面拼上 `\Kitty Tools`（点「浏览」选的由 `AppendDefaultDirName=yes` 管；手打的路径在 Pascal 里补）。不许装到：驱动器根目录、`{win}`、`{commonpf32}` / `{commonpf64}` 和它们下面、用户主目录本身，以及桌面 / 文档 / 下载 / 图片 / 音乐 / 视频本身；拼完以后不超过 200 个字符；要写得进去（建一个临时文件试一下）。不合规矩就提示原因、留在这一页。**静默安装也要挡**：同样的检查在 `PrepareToInstall` 里再做一遍，返回错误 |
| I7 | 已经装过 | `UsePreviousAppDir=yes`、`DisableDirPage=auto`：更新时直接用原来的位置。要装的版本和登记里的 `DisplayVersion` 一样或更旧：先问一句「已经装了 x.y.z，要重新安装吗？」（是 / 否，默认否），静默时照装 |
| I8 | 程序正开着（照 S5） | `PrepareToInstall` 和卸载的 `InitializeUninstall` 里：互斥量 `Local\KittyTools` 在就运行 `{app}\KittyTools.exe --quit`（§4.2），最多等 10 s 看互斥量放掉；还在就提示「请从托盘退出 Kitty Tools 再试」，安装停在这一步、卸载取消。`CloseApplications=no`：不让「重新启动管理器」去强关，强关会丢掉剪贴板里还没提交的删除。**不按进程名结束** |
| I9 | 装什么、装完做什么 | `[Files]` 把发布目录（和 zip 里的一模一样）整个放进 `{app}`；`[Icons]` 建 `{userprograms}\Kitty Tools.lnk`（和 `App/StartMenuShortcut.cs` 同一个位置、同一个名字，App 第一次运行时会看到它已经在）；勾了「开机时自动打开」就在 `[Registry]` 写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `KittyTools` = `"{app}\KittyTools.exe"`（和 `App/Autostart.cs` 写的一字不差），带 `uninsdeletevalue`；`[Run]` 用 `postinstall nowait skipifsilent` 打开程序 |
| I10 | 卸载（照 S9） | 从「设置 › 应用」、开始菜单（不加卸载快捷方式，Windows 11 的开始菜单里右键就有「卸载」）或者程序里「从这台电脑移除」进来，都是 Inno 的 `unins000.exe`。流程：叫程序退出（I8）→ 问「同时删除我的数据吗？剪贴板历史、设置、截图历史会挪进回收站」（是 / 否，**默认否**；静默卸载时当「否」）→ 运行 `{app}\KittyTools.exe --uninstall-cleanup`（勾了「是」再加 `--remove-data`，§4.3）：删凭据管理器里的密钥和开机启动值（装的时候没勾、后来在程序里打开的那种，Inno 不知道），要的话把数据目录挪进回收站 → Inno 删它记下的文件 → `[UninstallDelete] Type: filesandordirs; Name: "{app}"` 把整个安装文件夹删掉（程序内更新带进来的新文件 Inno 不认得，不这样删会留下；I6 保证了这个文件夹整个是我们的） |
| I11 | 程序里「从这台电脑移除」（照 S10） | 用安装程序装的（§4.1 的判断）：启动 `unins000.exe`，然后退出程序；zip 解压的：照现在的做法 |
| I12 | 程序内更新之后（照 S11） | 用安装程序装的：把 `{AppId}_is1` 里的 `DisplayVersion` 改成新版本，`EstimatedSize` 重新量（`--updated` 启动、删掉 `*.old` 以后再量一次，同现在的 `RefreshSize`） |
| I13 | 签名 | 照旧不签名；发布说明照旧写「更多信息 › 仍要运行」。以后要签名，`[Setup]` 里加 `SignTool` 就行 |
| I14 | 旧的安装程序装过的 | **不迁移**：Windows 版一个 release 都没发过，只有开发机上装过。开发机先用旧的 `Uninstall.exe` 卸掉，再装新的 |
| I15 | 压缩 | `Compression=lzma2/max`、`SolidCompression=yes`；量一下 setup.exe 的大小和装一次的耗时，写进报告（现在的 setup.exe 约等于 zip，29 MB） |

## 2. `installer/KittyTools.iss` 的骨架

Pascal 那几段（I4 的勾选框和按钮文字、I6、I7、I8、I10 的提问）自己写，照上面的规矩；用到的函数（`CheckForMutexes`、`Exec`、`WizardForm` 的控件、`UninstallSilent`、`ExpandConstant`）以 Inno 7 的帮助为准。

```iss
; Kitty Tools 的安装程序（PLAN-setup-inno）。build-release.ps1 调：
;   ISCC /DAppVersion=0.1.0 /DArch=x64 /DSourceDir=<发布目录> /O<输出目录> installer\KittyTools.iss
; 自检再加 /DTestKey=<字母数字>：AppId、开机启动值、快捷方式、互斥量都换成测试名（和 Core/SetupRules.NamesFor 一致），
; 装的程序配 KITTY_PROBE_PROFILE=<同一个名字> 跑，不碰真的那一份。
#ifndef TestKey
  #define AppIdValue "{{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}"
  #define RunValue "KittyTools"
  #define ShortcutName "Kitty Tools"
  #define MutexName "Local\KittyTools"
#else
  #define AppIdValue "KittyTools.Test." + TestKey
  #define RunValue "KittyTools.Probe." + TestKey
  #define ShortcutName "Kitty Tools.Test." + TestKey
  #define MutexName "Local\KittyTools.Probe." + TestKey
#endif

[Setup]
AppId={#AppIdValue}
AppName=Kitty Tools
AppVersion={#AppVersion}
AppVerName=Kitty Tools {#AppVersion}
AppPublisher=YyAdnBug
AppPublisherURL=https://github.com/YyAdnBug/kitty-tools
DefaultDirName={autopf}\Kitty Tools
AppendDefaultDirName=yes
UsePreviousAppDir=yes
PrivilegesRequired=lowest
DisableWelcomePage=yes
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableReadyPage=yes
ShowLanguageDialog=no
CloseApplications=no
WizardStyle=modern dynamic windows11
WizardImageFile=wizard-large-*.png
WizardSmallImageFile=wizard-small-*.png
SetupIconFile=..\KittyTools\Resources\AppIcon.ico
UninstallDisplayIcon={app}\KittyTools.exe
UninstallDisplayName=Kitty Tools
OutputBaseFilename=KittyTools-{#AppVersion}-windows-{#Arch}-setup
Compression=lzma2/max
SolidCompression=yes
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\{#ShortcutName}"; Filename: "{app}\KittyTools.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#RunValue}"; \
  ValueData: """{app}\KittyTools.exe"""; Flags: uninsdeletevalue; Check: ShouldWriteAutostart

[Run]
Filename: "{app}\KittyTools.exe"; Description: "现在打开 Kitty Tools"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// ShouldWriteAutostart：新装时看「开机时自动打开」那个勾选框，更新时返回 false（照原样，不动用户在程序里改过的）。
// 其余见 §1 的 I4、I6、I7、I8、I10。
```

- 拿不准、要在 Windows 上验的：`Local\` 前缀的互斥量 `CheckForMutexes` 认不认（不认就去掉前缀试，同一个会话里是同一个对象）；`NextButtonClick` 在静默安装时调不调（所以 I6 在 `PrepareToInstall` 里再查一遍）；`AppendDefaultDirName` 在用户已经选了一个叫「Kitty Tools」的文件夹时会不会再拼一层；ARM64 那一份在 x64 机器上会不会被正确地拒掉。

## 3. 图

- `tools/app-icon.swift`（在 Mac 上跑）多出两组透明底 PNG，放在 `windows/installer/`：
  - `wizard-small-58 / 77 / 97 / 116 / 124 / 143 / 159.png`：1:1，Inno 6.6 起小图区按 DPI 的那七档；
  - `wizard-large-202x386 … 534x1022.png`：164:314，大图区的七档。图标宽占六成，中心在离顶边四成的地方。
- Inno 按当前 DPI 自己挑最接近的一张（逗号或通配符给多张）。
- 换角色、换图标：先跑 `macos/brand-icons.swift`，再跑 `windows/tools/app-icon.swift`，三样（两个 ico、两组安装图）一起更新。

## 4. App 这边改什么

### 4.1 `App/SetupRecord.cs` 改成认 Inno

- **「是不是安装程序装的」**：exe 旁边有 `unins000.exe`，而且 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{AppId}_is1` 的 `InstallLocation` 就是这个目录（Inno 写的值末尾带 `\`，比较前去掉；`SetupRules.SamePath` 留着用）。
- **`Uninstaller()`**：返回 `unins000.exe` 的路径。
- **`AfterUpdate` / `RefreshSize`**：只改上面那个键的 `DisplayVersion` / `EstimatedSize`。标记文件那一套删掉，文件清单也不用记了：卸载时整个文件夹删（I10）。
- **测试名**：`SetupRules.NamesFor(testKey)` 的 `UninstallKey` 改成 `{FF0E2BF7-…}_is1` / `KittyTools.Test.<名字>_is1`，其余几个名字和 `.iss` 里的 `#define` 一一对应。

### 4.2 `--quit`

- `App/Program.cs`：带 `--quit` 启动时，在 `SingleInstance.TryStart` 之前处理。已经有一个在跑，就通过管道发 `quit`（`SingleInstance.cs` 已经认这个命令），等它回话或者 2 s 超时，然后退出；没有在跑的，直接退出。
- 两种情况退出码都是 0。不建窗口、不建托盘、不写数据目录。

### 4.3 `--uninstall-cleanup [--remove-data]`

- 也在 `SingleInstance.TryStart` 之前处理，**不开数据库、不往数据目录写日志**（R25 踩过：库和日志开着就挪不进回收站）。
- 做的事是现在 `SettingsWindow.UninstallAsync` 那一套里「删程序文件」之前的部分，抽成一个方法两边共用：
  - `Autostart.Set(false)`（名字带探针后缀，自检时不碰真的那个值）；
  - `Credentials.DeleteAll()`；
  - 带 `--remove-data` 时，把 `Paths.DataDirectory` 挪进回收站。
  - **不删开始菜单快捷方式**：Inno 删它自己建的那个（和 App 建的是同一个文件）；`StartMenuShortcut.Remove()` 不分探针档，自检时会删掉真的那个。zip 解压那条路（`UninstallAsync`）照旧自己删。
- 结果写到 `%TEMP%\KittyTools-uninstall.log`（测试名下带后缀）。退出码：0 全成，1 有一步失败（卸载照常往下走，失败的写进日志）。

### 4.4 其他

- `App/SingleInstance.cs` 文件头里「安装 / 卸载程序（KittyTools.Setup）发来」改成「`--quit` 发来（Inno 安装 / 卸载时调）」。
- 欢迎页那一处 `SetupRecord.IsInstalled → StartWithWindows = Autostart.IsEnabled()`（R37）照旧：安装时问过开机启动，照它实际写下的值。

## 5. 删什么

- `windows/KittyTools.Setup/` 整个目录，`KittyTools.slnx` 里那一行。
- `KittyTools.Core/SetupPayload.cs`。
- `KittyTools.Core/SetupRules.cs`：只留 App 和 e2e 还用的 `NamesFor`、`IsValidTestKey`、`SamePath`、`DirectorySizeKb`、`UninstallRoot`。安装位置的规则（`ResolveInstallDir`、`WhyNotInstallDir`）搬进 `.iss` 的 Pascal 以后，C# 这份删掉。
- `KittyTools.Tests/SetupTests.cs`：跟着删到只剩留下来的那几个函数的测试。删掉的位置规则用例，改成 e2e 里的几条（§6）。
- `PLAN-setup.md` 开头已经加了一句「被 PLAN-setup-inno 取代」，正文留着当历史。

## 6. 打包脚本和自检

- **`build-release.ps1`**：
  - 「发布安装程序本体、把 zip 接在后面」那一段换成调 `ISCC.exe`：先找 `%ProgramFiles%\Inno Setup 7\ISCC.exe`，再找 `%ProgramFiles(x86)%\Inno Setup 7\ISCC.exe`，都没有就报「先装 Inno Setup 7（winget install --id JRSoftware.InnoSetup -e）」并中止。
  - `SourceDir` 就是打 zip 的那个 `<stage>\Kitty Tools`，setup.exe 和 zip 装的东西一模一样。
  - setup.exe 照旧出 `.sha256`，`SIZES.txt` 照旧记大小。
- **`tools/setup-e2e.ps1`** 重写。用 `/DTestKey=E2E` 编一个测试版，装到 `%TEMP%` 下的临时目录，全程设 `KITTY_PROBE_PROFILE=E2E`（`KITTY_SETUP_TEST_KEY` 是旧安装程序用的，跟着删掉），**不碰真的登记、开机启动和快捷方式**：
  1. 静默新装（`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=<临时目录> /LOG=<日志>`，`/TASKS` 或 Pascal 的参数选上开机启动）：文件齐、登记键在且 `InstallLocation` 对、`DisplayVersion` 对、测试名的快捷方式和 Run 值都在。
  2. 程序开着时再装一次：它被 `--quit` 叫退（日志里有 `instance.quit`），装完能再启动。
  3. 装到 `C:\` 和 `%USERPROFILE%`：都被拒，退出码非 0，什么都没写。
  4. 把一个更新 zip 解进去（模拟程序内更新多出来的文件），再静默卸载（`unins000.exe /VERYSILENT /SUPPRESSMSGBOXES`）：安装目录整个没了、登记键没了、快捷方式和 Run 值没了、测试名的凭据没了、数据目录还在（静默卸载默认不删数据）。
  5. 用 `--remove-data` 的那条路再走一遍：数据目录进了回收站。
- 每一步打印一行结果，有一步不过就退出码非 0。`build-release.ps1` 不跑它，发版前手动跑一次（同 `update-e2e.ps1`）。

## 7. 验收

1. `dotnet test` 全过；Release AOT x64 / ARM64 零警告；`build-release.ps1` 出两个 setup.exe。
2. `pwsh windows/tools/setup-e2e.ps1` 五步全过。
3. 真机手测（写进 `HANDTEST.md`「安装程序（Inno）」一节）：
   - 浅色、深色系统下各装一次，**截四张图推到 `windows-shots`**：选位置页、进度页、装好了、卸载时问删不删数据；
   - 150% 缩放下图标不糊；
   - 改位置到 `D:\Apps`，装到了 `D:\Apps\Kitty Tools`；
   - 程序开着时更新：它自己退了、装完重新打开；
   - 程序里「从这台电脑移除」走到 Inno 的卸载；
   - 「设置 › 应用」里显示的名字、版本、大小对；
   - 程序内更新一次以后，那里的版本跟着变。
4. 报告：setup.exe 的大小（两个架构）、装一次和卸载一次的耗时、和方案不一样的地方、没测的。
