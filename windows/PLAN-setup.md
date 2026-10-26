# windows/PLAN-setup.md：安装程序

2026-10-26，用户要求「打包成 exe 安装包、能选安装路径」，并且**由 Claude 在单独的会话里直接做**。下面的取舍已定，照做。

- **分工**：
  - `windows/KittyTools.Setup/` 和这份方案点名的 Core 文件、测试、脚本，归做安装程序的 Claude 会话。
  - Windows 上的 agent 在它交接之前**不动这些文件**；改 App 项目时碰到这里点名的口子（§4），按这里的约定来。
  - 做完之后，审查方在 `REVIEW.md` 里加一条「安装程序真机验收」，交给 Windows 上的 agent 去跑。
- **红线照旧**（`AGENTS.md`）：只用微软的包、Native AOT 零警告、不按进程名结束进程、测试不碰用户的真实数据和注册表项。

## 0. 现在是什么样

- `build-release.ps1` 只出 zip。用户要自己解压到某个文件夹，运行之后开始菜单里有快捷方式，但「设置 › 应用」里看不到这个程序，也没法从那里卸载。
- 程序内更新（`Core/UpdateInstaller.cs`、`UpdateFlow`）是在原来的文件夹里替换文件，失败会回滚。安装程序要和它配合：装在用户能写的地方，更新不弹管理员权限框。

## 1. 定下来的做法

| # | 问题 | 定了 |
|---|---|---|
| S1 | 安装程序长什么样 | **一个 exe**：`KittyTools-<版本>-windows-<x64/arm64>-setup.exe`。前半段是 AOT 编的安装程序本体，后面接上 release 的 zip 当载荷，最后是一段固定格式的尾巴（标记、载荷的起点和长度、sha256）。zip 照旧单独出，程序内更新用它 |
| S2 | 界面 | **系统自带的对话框，不用 WinUI**：任务对话框 `TaskDialogIndirect`（comctl32 v6，进度条也用它的），选文件夹用 `IFileOpenDialog`（`FOS_PICKFOLDERS`），都用 CsWin32 生成。WinUI 要整套运行库，没法做成一个小 exe。这一条符合 `AGENTS.md`「系统自己的东西跟 Windows」 |
| S3 | 装到哪 | 默认 `%LOCALAPPDATA%\Programs\Kitty Tools`，装在当前用户名下，**不要管理员权限**（清单 `asInvoker`）。可以换位置：用户选的文件夹名字不是「Kitty Tools」，就在它下面建一个「Kitty Tools」再装进去，保证这个文件夹整个是我们的，卸载时才能放心整个删掉。不许装到驱动器根目录、Windows 目录、`Program Files`（要管理员权限，以后更新会失败）、用户主目录本身、桌面 / 文档 / 下载本身。选了不能写的地方就提示，重新选 |
| S4 | 已经装过 | 从注册表（§2.4）读出原来的位置，按钮写「更新到 x.y.z」，位置不能改。装的是一样或更旧的版本，就问一句「重新安装 / 取消」。用 zip 解压的旧版不认，当新装处理 |
| S5 | 程序正开着 | 通过单实例管道发 `quit`（§4.1），最多等 10 s 看互斥量 `Local\KittyTools` 有没有放掉。没放掉就提示「请从托盘退出 Kitty Tools 后点重试」。**不按进程名结束** |
| S6 | 怎么换文件 | 先校验载荷的 sha256，再解压到同卷的临时文件夹，然后用 `Core/UpdateInstaller.Install` 换进去（和程序内更新同一套，失败会回滚）。新装时目标文件夹是空的，换进去就是直接放 |
| S7 | 装完做什么 | 写标记文件 `<安装目录>\.kitty-install`（§2.3）；把安装程序本体（不带载荷）复制成 `<安装目录>\Uninstall.exe`；登记「设置 › 应用」（§2.4）；建开始菜单快捷方式（和 `App/StartMenuShortcut.cs` 同一个位置、同一套写法）；按勾选写开机启动（和 `App/Autostart.cs` 同一个注册表值）。最后一页：「装好了」，勾选「现在打开」（默认勾上） |
| S8 | 第一页的选项 | 只有一个勾选框「开机时自动打开」，默认勾上，和程序里 `StartWithWindows` 的默认值一样。别的设置都进程序里改 |
| S9 | 卸载 | 从「设置 › 应用」或者开始菜单进来，都是运行 `Uninstall.exe`。它先把自己复制到 `%TEMP%`，从那份接着跑（自己所在的文件夹删不掉）。确认对话框里有一个勾选框「同时删除我的数据（剪贴板历史、设置等，挪进回收站）」，默认不勾。然后：让程序退出（同 S5）→ 删开始菜单快捷方式 → 删开机启动值 → 删凭据管理器里 `KittyTools/*` 的凭据 → 勾了就把数据目录挪进回收站 → 过一遍检查（§2.3）后删掉安装目录 → 删注册表登记 → 「已卸载」。`%TEMP%` 里那份用 `MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)` 留到重启时删 |
| S10 | 程序里「从这台电脑移除」 | 有 `.kitty-install` 标记（用安装程序装的）：改成启动 `Uninstall.exe` 然后退出程序。没有标记（zip 解压的）：照现在的做法。见 §4.2 |
| S11 | 程序内更新之后 | 有标记就顺手更新注册表里的 `DisplayVersion` 和 `EstimatedSize`。见 §4.3 |
| S12 | 签名 | 不签名，和 zip 一样，第一次运行会被系统拦一下。发布说明里写「更多信息 › 仍要运行」 |

## 2. 细节

### 2.1 载荷尾巴（Core 纯函数）

exe 的最后 64 字节固定格式：

| 字节 | 内容 |
|---|---|
| 0–7 | 标记 `KTSETUP1`（ASCII） |
| 8–15 | 载荷起点（int64，小端） |
| 16–23 | 载荷长度（int64，小端） |
| 24–55 | 载荷的 SHA-256 |
| 56–63 | 保留，填 0 |

- 读：先看文件尾巴，标记不对就当「没有载荷」。这时如果文件名是 `Uninstall.exe`，就进卸载模式；否则报「安装包不完整，请重新下载」。
- 写：`build-release.ps1` 调一个小命令（Setup 自己的 `--pack <stub> <zip> <out>`，或者 Core 里的函数配一个测试用的入口），把 zip 接到本体后面，再写尾巴。
- 复制成 `Uninstall.exe` 时只拷「载荷起点」之前那一段，不带尾巴。

### 2.2 路径规则（Core 纯函数）

- `ResolveInstallDir(选的文件夹)`：名字（不区分大小写）不是 `Kitty Tools` 就拼上 `\Kitty Tools`。
- `IsForbiddenInstallDir(路径)`：驱动器根目录、`%WINDIR%`、`%ProgramFiles%` 和 `%ProgramFiles(x86)%` 及它们下面、`%USERPROFILE%` 本身，以及桌面 / 文档 / 下载 / 图片 / 音乐 / 视频本身。拼上 `Kitty Tools` 之后的路径可以在这些文件夹下面，只是不能是它们本身。
- 路径长度：拼完之后 ≤ 200 个字符，给里面的文件留余量。
- 能不能写，运行时用 `UpdateInstaller.CanWriteInstallDirectory` 判断。

### 2.3 卸载前删安装目录的检查（Core 纯函数）

下面几条**全部满足**才删整个文件夹：

1. 文件夹里有 `KittyTools.exe`；
2. 有 `.kitty-install`，里面记的路径和这个文件夹一样；
3. 文件夹名是 `Kitty Tools`；
4. 不在 §2.2 的禁止名单里。

有一条不满足，就只删 `Uninstall.exe` 以外、我们认得的东西（`KittyTools.exe` 和发布目录里的文件），然后提示用户「这个文件夹里还有别的东西，没有整个删掉」，并打开文件夹。

`.kitty-install` 是 UTF-8 的 JSON：`{"path": "...", "version": "...", "installedAt": <毫秒>}`。

### 2.4 「设置 › 应用」里的登记

`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\KittyTools`：

| 值 | 类型 | 内容 |
|---|---|---|
| `DisplayName` | REG_SZ | `Kitty Tools` |
| `DisplayVersion` | REG_SZ | 版本号 |
| `Publisher` | REG_SZ | `Kitty Tools` |
| `DisplayIcon` | REG_SZ | `<安装目录>\KittyTools.exe,0` |
| `InstallLocation` | REG_SZ | 安装目录 |
| `UninstallString` | REG_SZ | `"<安装目录>\Uninstall.exe"` |
| `QuietUninstallString` | REG_SZ | `"<安装目录>\Uninstall.exe" --quiet` |
| `NoModify` | REG_DWORD | 1 |
| `NoRepair` | REG_DWORD | 1 |
| `EstimatedSize` | REG_DWORD | 安装目录大小，单位 KB |
| `InstallDate` | REG_SZ | `yyyyMMdd` |
| `URLInfoAbout` | REG_SZ | `https://github.com/YyAdnBug/kitty-tools` |

**测试不能写这个真的键**：环境变量 `KITTY_SETUP_TEST_KEY=<名字>` 时，键名换成 `KittyTools.Test.<名字>`；开始菜单快捷方式、开机启动值、凭据前缀也一样换成测试用的名字。值的组装放进 Core 当纯函数测。

### 2.5 不弹界面的模式（给测试和脚本用）

- `--quiet --dir <路径> [--no-autostart] [--no-launch]`：不弹任何对话框，按参数装，退出码 0 表示成功。
- `Uninstall.exe --quiet [--with-data]`：同上，按参数卸载。

## 3. 文件

| 文件 | 内容 |
|---|---|
| `windows/KittyTools.Setup/KittyTools.Setup.csproj` | `net10.0-windows`、`PublishAot`、`win-x64;win-arm64`、`OutputType=WinExe`，不用 WinUI；`app.manifest` 写 `asInvoker`，并启用 comctl32 v6 |
| `windows/KittyTools.Setup/Program.cs` | 入口：判断安装、卸载还是打包模式 |
| `windows/KittyTools.Setup/SetupUi.cs` | 任务对话框的几页：安装、进度、完成、出错、卸载确认 |
| `windows/KittyTools.Setup/Installer.cs` / `Uninstaller.cs` | S5–S9 的流程 |
| `windows/KittyTools.Setup/NativeMethods.txt` / `.json` | CsWin32 用到的接口，`allowMarshaling=false` |
| `windows/KittyTools.Core/SetupPayload.cs` | §2.1 |
| `windows/KittyTools.Core/SetupRules.cs` | §2.2、§2.3、§2.4 里能写成纯函数的部分 |
| `windows/KittyTools.Tests/SetupTests.cs` | 上面两个文件的单测 |
| `windows/tools/setup-e2e.ps1` | §5 的端到端测试 |
| `windows/build-release.ps1` | 出完 zip 之后，发布 Setup（AOT，x64 / arm64）、接上载荷、写 `.sha256`，发布说明里加安装包 |
| `windows/KittyTools.slnx` | 加上 Setup 项目 |

开始菜单快捷方式和开机启动的写法，和 App 里那两个文件保持一致：可以抽进一个共享源文件，在两个项目里用 `<Compile Include="..." Link="..." />` 引用；也可以在 Setup 里照写一份，文件头注明要和 App 那份一起改。二选一，按改动小的来。

## 4. 程序里要开的口子（App 项目，改动要小）

1. **单实例管道加 `quit` 命令**（`App/SingleInstance.cs`，现在只认 `show-settings`）：收到就走正常的退出流程（`ShellRuntime.Exit`），和点托盘「退出」一样。
2. **「从这台电脑移除」**（`Settings/SettingsWindow.cs` 的 `UninstallAsync`）：有 `.kitty-install` 就启动 `Uninstall.exe` 然后退出（S10）。
3. **程序内更新完成后**：有标记就更新注册表里的 `DisplayVersion` / `EstimatedSize`（S11）。

`SettingsWindow.cs` 正在被第七版改。第 2、3 条要是和 agent 的改动撞上，就写成 `REVIEW.md` 的条目交给 agent。第 1 条在做安装程序的会话里直接做。

## 5. 怎么验

- **单测**（Core 是 `net10.0`，Mac 上装了 .NET 10 SDK 就能跑）：
  - 载荷尾巴：写进去再读出来；坏标记；长度越界；sha256 不对。
  - 路径规则：拼「Kitty Tools」、禁止名单、负例。
  - 删除前的检查：四条各缺一条的情况。
  - 注册表值的组装、测试键名的替换。
- **编译检查**：Mac 上不能做 Windows 的 AOT 发布。用 `dotnet build windows/KittyTools.Setup -p:EnableWindowsTargeting=true` 至少确认编得过。
- **真机端到端**（`windows/tools/setup-e2e.ps1`，由 Windows 上的 agent 跑；全程用 `KITTY_SETUP_TEST_KEY` 和临时目录）：
  1. 静默装到临时目录：文件齐全、`.kitty-install` 内容对、注册表测试键的每个值都对、快捷方式存在；
  2. 再装一次更新的版本：位置不变、`DisplayVersion` 变了；
  3. 程序开着时安装：`quit` 之后能装上，日志里没有按进程名结束；
  4. 静默卸载（不带 `--with-data`）：安装目录、快捷方式、开机启动、注册表测试键都没了，数据目录还在；
  5. 带 `--with-data` 再来一遍：数据目录进了回收站；
  6. 在安装目录里放一个别的文件再卸载：不整个删、有提示（静默模式写日志）；
  7. 把载荷改坏一个字节：拒绝安装、什么都没写。
- **截图**：安装页、选文件夹、进度、完成、卸载确认，只截对话框本身。任务对话框是系统画的，系统深色模式下画成什么样就是什么样（多数版本还是浅色），不另外处理。

## 6. 不做

- MSIX、MSI，以及 Inno Setup、NSIS、WiX 这类第三方安装工具（违反红线，或者对这个程序来说太重）。
- 装给所有用户（要管理员权限，程序内更新会失败）。
- 安装程序自己联网下载（载荷已经在 exe 里了）。
- 修复、修改安装（`NoModify` / `NoRepair`，重新运行安装程序就是重装）。
