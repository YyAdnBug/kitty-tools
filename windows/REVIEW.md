# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## 待修

（2026-10-26 晚复查到 `3fe1725e`：R22、R25、R26、R28、R29 认可；R23 认可，60 s 和 10 分钟的重封装耗时并进 R24 一起量；R30 认可，托盘和 HUD 的截图见 R33。新加 R31–R35。R24 一直没动，排在最前面。）

（2026-10-26 夜：安装程序写完了（`616840b`，没编译过），新加 R36–R38。R36 排在 R24 前面先做：没编过的 Setup 不进 slnx，但 Core 单测里已经有它的测试。）

### R24（P1）第 2 批的音画同步是对着一张不动的画面量的，要重做 → 部分重测（`--sync-probe`）

**复查（2026-10-26 晚）**：这一条还没动。重做的时候，顺手把 R23 的重封装耗时（60 s、10 分钟的文件各一次）一起量了，写进同一份报告。

- 报告里写了：「测试图案窗口在 HUD 起来后被这台机器限帧（WGC 只收到 1 帧），视频靠补帧」。60 s 的文件只有 1.6 MB，也说明画面没动。这样「提示音的起点和闪白那一帧差 < 50 ms」根本没法验。CPU 9.2% 也不能算数，因为编码器一直在编同一帧。
- **先查为什么只收到 1 帧**。日志里有 `_arrivedFrames`，对比 HUD 出来之前和之后。怀疑方向：
  - HUD `Activate()` 抢了焦点，测试窗口的动画停了（R22 修好后再看）；
  - 测试窗口被 HUD 盖住的部分 DWM 不更新。
  
  测试窗口要保证一直在画：用 `CompositionTarget.Rendering` 驱动，并在日志里记它自己画了多少帧。
- **录制时的内存**：第 1 批 142 MB、第 2 批 192 MB，用的是 `Process.WorkingSet64`（总工作集，包括映射进来的显存和共享页），不是 §0 规定的专用工作集。
  - 换成专用工作集重新量。
  - 还超过「比录之前多 40 MB」，就把帧池从 4 张改成 2 张（PLAN 写的是 2），再列出剩下的是谁占的。
- **重做第 2 批的验收**，画面要一直在动：
  - 第 1 s 和第 60 s 的音画差都 < 50 ms；
  - 中间静音 20 s 后照样同步；
  - 抽第 1、30、60 s 的帧，测试窗口上的帧号是连续的；
  - CPU 按 Release AOT 量。

**进展（--sync-probe）**：测试图案 10 秒带系统声音，第一次样本闪白 0.417 s / 提示音 0.430 s（差约 13 ms），但 10 秒重测时 AudioWavProbe 仍把系统声音里的其它声音当成提示音（0.333 s 对 0.180 s，差 153 ms），**还不能据此下 < 50 ms 的结论**；60 秒无音轨文件 1812 帧 / 13.1 MB / 重封装 78 ms，专用工作集约 192 MB。还没做第 60 秒的逐帧差、20 秒静音后同步、10 分钟重封装。

### R31（P1）0.7.0 的包是在「设置窗一打开就崩」修好之前打的，要重打；打包时加启动冒烟 → 已修（`5db1e8f`）

**进展（`b10cbce`）**：新增 `--smoke`（设置六页、剪贴板 / 启动器、翻译、截图遮罩、录音待录条），
`build-release.ps1` 解压 x64 zip 后跑，非 0 就失败；0.7.0 已重打（x64 `dd9652c0…` / arm64 `96af0e90…`），
x64 包冒烟通过。设置窗的 Mica 在 Release AOT 下会抛 `ArgumentException`，已改成不透明卡片底；
关于页卡住的原因是 `ShellIcons.LoadPng` 在 Release AOT 下不返回；改成后台线程 + 500 ms 超时后，**七页冒烟全过**。

- `cea27773` 16:21 打的 0.7.0。设置窗崩溃 16:22（`7ec18c5e`）、16:45（`d1c697c8`）才修好，`d1c697c8` 里也写了「0.7.0 包里……真机已复现」。所以 `windows/build/release/0.7.0/` 里的 zip 一打开设置就退出。之后没看到重打。
- 更要紧的是这个崩溃怎么漏过去的：从 `877cdf17` 到 `7ec18c5e`，中间八九个提交，每个都写着「测试全过、AOT 零警告」，可是设置窗根本打不开。单测和编译管不到「界面能不能打开」。

**修**：
1. 加一个 `--smoke` 参数：依次打开设置窗（七页都切一遍）、剪贴板面板、启动器、翻译浮窗、截图遮罩（打开后马上取消）、录音控制条（待录状态，不真录），每个停 1 s。全部没崩就退出码 0；有崩溃记录或者异常就非 0，并打印是哪一步。
   - 用 `KITTY_PROBE_PROFILE` 那一套独立数据，不碰真实数据、开始菜单和托盘名。
2. `build-release.ps1` 打完 zip 后，解压到临时目录，用 `--smoke` 跑解压出来的 exe。不是 0 就打包失败、删掉产物。
3. 每批的自查清单（`AGENTS.md` 第 2 条）加一句：Release 发布物跑一次 `--smoke`。
4. 用当前代码重打 0.7.0，`STATUS.md` 写新的 sha256。

**验收**：故意把 `Kitty.CardStyle` 改回同名，`build-release.ps1` 要失败，并指出是设置窗那一步；改回来再过。

### R32（P1）翻译服务同步：mac 会写 `"usesDeepLX": false`，Windows 读到会把整类停住 → 已修（`8ce539d`）

- `6ebe6041` 报告里的疑问：「mac TranslateService 的编码没有源码可对：usesDeepLX 只在 true 时写」。审查方查了 mac 源码：
  - 翻译服务同步的就是 `TranslateService` 这个结构本身，用的是合成的 `Codable`：可选字段是 nil 才不写，`false` 和 `""` 照写。
  - mac 设置页里 DeepL 的「接口」切换用的是 `Binding(service.usesDeepLX, default: false)`，写回去的是值本身。用户切到 DeepLX 再切回「官方 API」，存下来的就是 `usesDeepLX: false`，`baseURL` 可能是 `""`。
  - 新建的 AI 服务，`model` 和 `baseURL` 都是 `""`。
- 所以 Windows 落地时对每个可选字段都要分清三种情况：没写（nil）/ `false` 或 `""` / 有值，再编回去要一模一样，不然 decodeExact 不过，整类停在「读不懂」。
- **审查方补了**：
  - `reference/mac-sync/TranslateService.swift`（结构原文）；
  - `sync-golden.json` 里 8 个 `kind: "service"` 的样本（用 mac 真正的结构编出来核对过，逐字节一致）：智谱、Google、DeepL 官方（`usesDeepLX:false`）、DeepLX、DeepL 切回官方且地址为 `""`、微软带区域、新建的 AI 服务（`model:""`、`baseURL:""`）、Anthropic。另外加了一个服务顺序的 `order` 样本。
- **要做**：
  - `SyncSourceTests.GoldenSamplesRoundTripThroughTheWindowsEncoders` 加 `case "service"`：用 `ServiceSync` 落下去再编回来，和 `json` 一字不差；
  - Windows 的服务模型里，`usesDeepLX` 改成 `bool?`，`model` / `baseURL` / `region` / `aiProtocol` 都保留 null 和 `""` 的区别（PLAN-v3 §1.5 的互通约定里补一句）。
- 审查方还改了片段样本：之前有「在收藏夹里但没收藏」的组合，mac 的不变式是在收藏夹里的一定是收藏，所以已经不会出现了。`SyncSourceTests` 里为它写的那句特殊处理可以删掉。

**修（`8ce539d`）**：`SyncService.UsesDeepLX` 改 `bool?`，encode 三态（没写 / false / true），decode 用 `FlagOrNull`；App 的 `TranslateServiceConfig` 同步改 `bool?`，DeepLProvider / 设置页按 `== true`。golden 加 service case，8 个 mac 样本全过。

### R33（P2）第七版的截图一张都没推；透明窗口用 WGC 只抓自己的窗口 → 部分已修（`e5100bd`）

- 第七版改的全是界面（剪贴板透镜、启动器 40、轻提示、翻译浮窗、截图工具栏两段、设置侧栏色块、外观缩略图、强调色圆点），`windows-shots` 上只有 R30 那 8 张设置窗。审查方没法看效果。
- 托盘菜单、录制条、轻提示这种透明宿主窗口，`PrintWindow` 拍不到。项目里已经有 WGC 了：`GraphicsCaptureItem.CreateForWindow(自己窗口的 HWND)` 只抓这一个窗口（带透明），不会拍到后面别的程序。抓一帧存成 PNG，透明的地方铺棋盘格或纯色。
- **要做**：把 `--ui-snapshots` 扩展到所有面板和这几个透明窗口，浅色 / 深色各一套，推到 `windows-shots` 的 `0.7.0-v7/`，`STATUS.md` 里列文件名。推之前照旧逐张看，不能有别的程序。
**进展（`e5100bd`）**：`--ui-snapshots` 的启动器 / 剪贴板 / 设置窗浅深 + 翻译输入态共 7 张已推到 `windows-shots/0.7.0-v7/`；`--clip-scroll-test` 5000 条实测中位 **0.8 ms**、p95 **1.3 ms**，远低于 16 ms，不做 ItemsRepeater。翻译 / 设置 / 截图遮罩 / 透明窗口的截图还没接。

- 第七版第 2 批没做 `ItemsRepeater` + 自定义虚拟化布局，现在是 `ListView` 加变高的行。照 PLAN-v7 量一次：5000 条剪贴板按住 ↓ 连发 3 s，每次按键到画面更新的耗时，取中位数和最慢的 5%。超过 16 ms 再做虚拟化布局。

### R34（P2）截图后 +18 MB、设置窗关掉后 +10 MB：先确认会不会越积越多 → 已修（`1f03f72`）

- 报告说剩下的是 WinUI 合成层和 XAML 模板缓存的原生内存，`GC` 回收不掉。只要是「第一次用了之后多出来一块、之后不再涨」，就可以当已知上限接受。
- **要做**：内存探针加两步——截图 5 次、设置窗开关 5 次，每次之后空闲 30 s 记一个数。
  - 平的：在 `STATUS.md`「已知风险」里写清上限，代码里留 `// ponytail:`，写明升级路径（遮罩常驻复用，或者放到单独进程）。
  - 每次都涨：是泄漏，按录屏那次 D3D 设备的查法找出来。

**修（`1f03f72`）**：设置窗全进程只建一次，关闭移到屏幕外、同一页不重建 XAML 树。5 次开关实测 93.2 / 93.2 / 89.9 / 89.8 / 89.6 MB（平）；截图 5 次 86.3 → 88.6 MB（+2.3，模板缓存一次，可接受）。

### R35（P3）别按进程名结束进程

- `bcd3eb7f` 报告里写了：探针被「主工作区另一个 agent 重编时按进程名结束了」。按进程名结束，会把用户正在用的那份 Kitty Tools、或者别的 agent 正在跑的测试一起杀掉。
- `AGENTS.md` 红线里已经加了一条：只结束自己起的那个 PID。两个 agent 各自查一下脚本里的 `taskkill /im`、`Stop-Process -Name`，都改掉。

### R36（P1）安装程序真机验收（`616840b`：Claude 在 Mac 上写的，一次都没编译过）

- PLAN-setup 的代码都写完了，但 Mac 上没装 .NET SDK（用户定的），Core 单测、Setup 编译、AOT 发布、端到端一个都没跑。`KittyTools.Setup` 还**没加进** `KittyTools.slnx`，免得没编过的代码让你们每批的 slnx 构建红掉。
- **要做**（按顺序）：
  1. `dotnet test windows/KittyTools.Tests`：新加的 `SetupTests.cs`（`SetupPayloadTests`、`SetupRulesTests`）全过。
  2. `dotnet build windows/KittyTools.Setup` 编过、零警告，再把它加进 `KittyTools.slnx`（和 Core 一样，`*|x64`、`*|ARM64` 都映射到 `Any CPU`）。
  3. `dotnet publish windows/KittyTools.Setup/KittyTools.Setup.csproj -c Release -r win-x64`，再来一遍 `-r win-arm64`：**零 trim / AOT 警告**，记下 exe 大小。
  4. `pwsh windows/build-release.ps1`：每个架构多出 `KittyTools-<版本>-windows-<x64|arm64>-setup.exe` 和 `.sha256`，发布说明先讲安装包。
  5. `pwsh windows/tools/setup-e2e.ps1 -Zip <上一步的 x64 zip>`：PLAN-setup §5 的七步全过（zip 要从 `616840b` 之后打，App 才认 `quit`）。ARM64 真机没有就写「没测」。
  6. 截图，只截对话框本身（按 HWND 裁），推 `windows-shots` 的 `setup/`：安装页、选文件夹框、进度、完成、「已经装了 / 重新安装」、程序开着时的「重试」、卸载确认、已卸载（文件夹里留了别的文件那种）。用测试名跑（`$env:KITTY_SETUP_TEST_KEY = "shots"`），默认位置会落到 `%TEMP%`，不碰真实的。
  7. 不用测试名手动走一遍真的：装 →「设置 › 应用」里图标、名字、版本、大小对 → 开始菜单能打开 → 程序里自动更新（R38 修完后）→ 从「设置 › 应用」卸载。做完把机器恢复原样。
- **没编译过、最可能要改的地方**：
  - `SetupUi.cs` 的 `TaskDialogConfig` 照 commctrl.h 手写（pack(1)，64 位下 160 字节）：`TaskDialogIndirect` 返回 `E_INVALIDARG`（日志 `ui.taskdialog 0x80070057`）就是布局错了，先对 `sizeof`。
  - CsWin32 生成的名字和重载：`IFileOpenDialog` 的 `SetOptions` / `SetTitle` / `SetOkButtonLabel` / `SetFolder` / `Show` / `GetResult`，`IShellItem.GetDisplayName`，`SHCreateItemFromParsingName` 的指针重载，`CoInitializeEx(null, COINIT)`。照编译器报的改，不要换成手数 vtable。
  - AOT 下清单有没有嵌进 exe：没嵌的话找不到 `TaskDialogIndirect`（日志 `ui.taskdialog missing`），文件名带 setup 还会被系统当成要管理员权限。
  - 回调里换页（`TDM_NAVIGATE_PAGE`）后返回 `S_FALSE`；要是一点按钮对话框就关了，看 `SetupUi.Callback`。
- **和方案不一样的地方**（审查方认可，验收按这个来）：
  - `.kitty-install` 多了 `files` 数组（这次装的文件并上次记的）。§5 第 6 步要求「安装目录里多一个别的文件就不整个删」，§2.3 那四条做不到，所以「没有不认得的文件」算第五条。
  - 测试名不只换注册表键：开机启动值、互斥量、管道、凭据前缀、数据目录都和 App 的 `KITTY_PROBE_PROFILE=<同一个名字>` 对齐（`.Probe.<名字>`），端到端才能真开一个 App 再叫它退出。注册表键照方案是 `KittyTools.Test.<名字>`，快捷方式是 `Kitty Tools.Test.<名字>.lnk`；测试名下默认安装位置在 `%TEMP%`。
  - `MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)` 只有管理员能登记，普通权限下必失败：照样调（只记日志），%TEMP% 里那份卸载程序留到下次安装 / 卸载时清（`Uninstaller.CleanStaleCopies`）。
  - 静默卸载：安装目录里那份复制到 %TEMP% 就退出（退出码 0），真正的结果写进日志 `uninstall.exit <退出码>`；`setup-e2e.ps1` 等的是这一行。
  - 不整个删的时候 `Uninstall.exe` 也删掉（那时它已经退了）。开机启动值和登记只在指向这个安装目录时才删，另一份解压版的不动。
  - 已经装过（更新）时不显示「开机时自动打开」，也不动开机启动值：用户可能在程序里关掉了。
  - 任务对话框的结构体手写、没用 CsWin32（它不是 COM；在 Mac 上没法确认 CsWin32 生成的联合体和回调签名）。选文件夹、快捷方式照旧用 CsWin32。
- 日志在 `%TEMP%\KittyTools-setup.log`（测试名下是 `KittyTools-setup.Test.<名字>.log`）。修完挪到「已修」，写提交号、两个架构的安装包大小、七步结果。

### R37（P2）设置里「从这台电脑移除」交给 Uninstall.exe（PLAN-setup §4.2 / S10）

- `Settings/SettingsWindow.cs` 的 `UninstallAsync` 现在自己删快捷方式、开机启动和凭据，程序文件让用户自己删。安装程序装的（exe 旁边有 `.kitty-install`）改成：
  - `SetupRules.ReadMarker(<exe 所在目录>)` 不是 null，且同目录有 `SetupRules.UninstallerName`：启动它（不带参数，它会自己弹确认，含「同时删除我的数据」），然后走 `ShellRuntime.Exit`，不再弹自己的 ContentDialog。卸载程序会先通过管道发 `quit`，程序没退也会等。
  - 没有标记（zip 解压的）：照现在的做法。
- 顺带：第一次运行的欢迎页里「登录时自动打开」取的是设置的默认值（true），点「开始使用」会把安装时没勾的开机启动又写回去。有标记时改成取 `Autostart.IsEnabled()`，并同步到 `SettingsService.Current.StartWithWindows`。
- 设置窗第七版还在改，所以这条交给你们。

### R38（P2）程序内更新之后改「设置 › 应用」里的登记（PLAN-setup §4.3 / S11）

- 在 `App/AutoUpdater.cs` 的 `update.installed` 之后（这时有 `result.Installed` 和 `version`），安装目录有 `.kitty-install` 就：
  - 改 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<UninstallKey>` 的 `DisplayVersion`（新版本）和 `EstimatedSize`（`SetupRules.DirectorySizeKb(安装目录)`）。登记的 `InstallLocation` 不是这个目录就不动。
  - `.kitty-install` 的 `version` 改成新版本，`files` 并上这次装进去的文件（相对路径，`SetupRules.WriteMarker`）。不然更新带进来的新文件，卸载时会被当成「不认得的」，安装目录就不会整个删。
- 名字用 `SetupRules.NamesFor(null)`；Release 探针档（`KITTY_PROBE_PROFILE=<名字>`）下用 `SetupRules.NamesFor(<名字>)`，和安装程序的测试名是同一套。


## 转入 PLAN-v6

### R14（P1）录屏换成 H.264 MP4，补系统声音 → 转入 PLAN-v6 第 1–3 批

现在是 GDI 抓屏 → CPU 编 JPEG → 自己写 AVI：

- 大：`0.4.0-batch-1` 那段 12.5 MB 才几秒，约 2.5 MB/s，10 分钟 1.5 GB；
- 坏：`AviWriter` 的大小字段是 32 位，过 4 GB 就写坏；没有 OpenDML，很多播放器打不开 1 GB 以上的 AVI 1.0；
- 占内存：`AviReader` 压缩、转 GIF 时 `File.ReadAllBytes` 把整个文件读进来；
- 费 CPU：1440p 30 fps 的 JPEG 编码全在 CPU 上；
- 没有系统声音。

**做法（全走 WinRT，项目里已经在用 WinRT 投影，AOT 能用，不用手写 Media Foundation 的 COM）**，参考 robmikh/SimpleRecorder（MIT）：

1. **抓屏**：`GraphicsCaptureItem`（整屏用 `IGraphicsCaptureItemInterop.CreateForMonitor`、选区先抓整屏再裁，这一个接口用 CsWin32 / 函数指针）+ `Direct3D11CaptureFramePool.CreateFreeThreaded` + `GraphicsCaptureSession`（`IsCursorCaptureEnabled` 按设置；Win11 上能关就把 `IsBorderRequired` 关掉）。
2. **编码**：`MediaStreamSource`（`VideoStreamDescriptor`，BGRA8，选区尺寸取偶数），`SampleRequested` 里交 `MediaStreamSample.CreateFromDirect3D11Surface(frame.Surface, 时间戳)`；`MediaTranscoder.PrepareMediaStreamSourceTranscodeAsync(source, 输出流, MediaEncodingProfile.CreateMp4(...))` → `TranscodeAsync()`。码率按像素数算（1080p30 约 8 Mbps）。没有硬件编码器的机器系统会自己换软件编码，不用管。
3. **系统声音**：WASAPI 回环。CsWin32 在 `allowMarshaling=false` 下生成的 `IAudioClient` / `IAudioCaptureClient` 是带函数指针的结构体，AOT 能用。用**轮询**（每 10 ms `GetNextPacketSize`），**不要用事件模式**（回环 + 事件模式在没有声音播放时不来事件）；包上带 `AUDCLNT_BUFFERFLAGS_SILENT`、或中间断了，按时间戳补静音，不然音画会越录越不同步。PCM 作为同一个 `MediaStreamSource` 的 `AudioStreamDescriptor` 交进去，输出 AAC。
4. **麦克风**：一样走 WASAPI 采集，和回环在 PCM 层混（相加 + 限幅），重采样到同一个采样率。录音功能（现在是 `MediaCapture` 出 M4A）可以留着，也可以换成同一套，自己定。
5. **点按圈、按键胶囊**：改成画在 D3D 纹理上（Win2D：`CanvasDevice.CreateFromDirect3D11Device` + 在拷出来的纹理上画）。
6. **压缩**：同一个 `MediaTranscoder` 降码率再转一遍。**转 GIF**：`MediaComposition` / `MediaPlayer` 的帧服务器逐帧取。不用自己解 AVI 了，`AviWriter / AviReader / JpegEncoder / JpegDecoder` 删掉。

**在换完之前**：AVI 录到 1 GB 自动停止并提示（`// ponytail:` 写上 R14），免得写出打不开的文件。

**验收**：1440p 30 fps 录 60 s，文件 < 60 MB、录制期间本进程 CPU < 15%、内存不随时长涨；放系统声音 + 对着麦克风拍手，音画同步；资源管理器能出缩略图、「媒体播放器」能放；录满 10 分钟一次。

**进展（`50ecd87`、`7edbd92`）**：
- 已改成**直接录 H.264 MP4**：`Mp4Recorder` 用 Media Foundation SinkWriter（GDI 抓屏 → RGB32 → H.264，
  硬件编码），默认开，设置里可退回 AVI；点按圈 / 按键胶囊仍画进画面。
- 实测 2560×1440@30 录 10 秒：**2.75 MB**、MediaPlayer 认 10.0 秒、H.264；录制期间本进程 CPU **2.4%**。
- 停止后另存 MP4 / 托盘手动转 MP4 仍在（AVI 文件可用）。
- **还没做**：系统声音 / 麦克风混音（MP4 目前只有画面）、真实 60 秒 / 10 分钟长录制的内存曲线、
  压缩 / GIF 对 MP4 的支持（现在只对 AVI 显示）。

**审查（`1bdfde8`）**：MP4 能录了，但还是 GDI 抓屏，SinkWriter 没开 `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`，所以用不上硬件编码器。系统声音没做成，原因是用了事件模式：回环流在没有声音播放时根本不出包。这些连同删 AVI、录音补齐，都写进了 PLAN-v6 第 1–3 批。

### R12（P2）第 4、5 批欠的验证 → 剩下的转入 PLAN-v6 第 6 批

报告里写了，这里列出来免得漏。系统自带的截图工具就能录屏（Win+Shift+R），不需要额外装工具。

- **剪贴板面板、启动器的高度动画**：窗口每 16 ms 改一次尺寸，Windows 上这样做常见的问题是边缘闪黑或闪白。录一段 3–5 秒的视频看；有闪就改成不做动画，直接设到新高度。
- **截图**：选区贴着屏幕下边时，工具栏要放到上方或选区里面，不能出屏；中文输入法下的原位文字；飞入卡片拖到资源管理器。
- **数字**：翻译等待动画期间的 CPU、截一次图之后的内存（按 D8）。
- **截图**：截图翻译的浮窗贴着选区出现；飞入卡片的深色版。

**进展（2026-10-25，`4b7e0c1` 之后）**：

- 已验：选区贴着屏幕下边时工具栏在屏内（`windows\build\shots\r4\shot-bottom-toolbar.png`）；
  飞入卡片的深色版正常（`shot-card-dark2-crop.png`，顺手修了深色下卡片黑底黑字和白边）；
  截图翻译贴选区有纯函数单测（`ScreenshotLayoutTests` 的四个用例），真机 OCR + 翻译链路没走。
- 没做：高度动画的录屏（要人工开录屏工具、再逐帧看，自动化里没法可靠完成）、中文输入法的原位文字、
  把卡片拖到资源管理器、等待动画期间的 CPU（手上没有可用的 key / 服务能停在「思考中」）、
  第二次截图的内存（内存探针只截一次，下一轮看要不要给探针加第二步）。
  这些按 `AGENTS.md` 记「没测」，继续做 `PLAN-v3.md`；`HANDTEST.md` §144–161 里已经标了「待走」。

## 已修

### R22（P1）录屏 HUD 没按 DPI 算尺寸，还写死了屏幕高 1440 → 已修（`82a5a07`）

- HUD 尺寸按目标显示器 `Displays.AtPoint(...).Scale` 换算成物理像素；位置由 Core `HudPlacement.Compute` 限在工作区，下方放不下放上方、再放不下贴选区里面下边。
- `AppWindow.Show(false)` + `WS_EX_NOACTIVATE`，不再 `Activate()` 抢焦点。
- 单测 `HudPlacementTests` 4 条：150%、贴底、整屏、负坐标副屏。
- 还没做：`--fake-dpi=150` 真机截图和“开录后焦点还在原程序”的手测（见 HANDTEST）。

### R23（P1）去掉分段 MP4 以后，闪退会丢掉整段录屏 → 已修（`266a485`；长文件的重封装耗时并进 R24）

**进展（`266a485` / `d4b0c10`）**：
- 录制重新写 FMPEG4（`MFTranscodeContainerType_FMPEG4`），moov 及时落盘。
- 新增 `Mp4Remux`：SourceReader + SinkWriter 按原生压缩样本逐个搬，不重编码；每路时间戳从 0 开始；
  没有音频流按只有画面处理；失败退回「分段 MP4 原样改名」。
- 正常停止和 `RecoverOnStartup` 都走重封装；实测 2 秒 / 3 秒 / 5 秒文件重封装 16–47 ms，
  最终文件 `ftyp=mp42`、`moov` 在尾部、Shell 读出 2 秒 / 3 秒 / 5 秒；崩溃恢复的 5 秒文件也能读时长。
- 10 秒带音轨改成单个 SourceReader + ReadSample(ANY_STREAM) 后不再卡：31 ms / 789 样本，成品 10 秒。仍然差验收里的 **60 秒 / 10 分钟两种重封装耗时**，以及真实系统声音 / 麦克风两路设备
  （开发机只验了无声和系统回环空数据）。

- 第 3 批改回了普通 MP4（`MFTranscodeContainerType_MPEG4`）。普通 MP4 的索引（moov）要到 `Finalize` 才写，闪退、断电、被任务管理器结束时，临时文件里一个字节都放不出来。「启动时找回」挪过去的是一个打不开的文件。
- PLAN-v6 第 1 批第 6 条写的是：录分段 MP4，停止时如果缩略图、拖动有问题，就**无损重封装**成普通 MP4，不是改回普通 MP4。你遇到的「MediaComposition 在分段 MP4 上 seek 不准」，正好是重封装要解决的问题。

**修**：
1. 录制写分段 MP4（`MFTranscodeContainerType_FMPEG4`）。
2. 正常停止时重封装：`MFCreateSourceReaderFromURL` 读临时文件，两路都**不设输出类型**（默认就是原生的压缩样本）。第二个 SinkWriter 每一路用 `GetNativeMediaType` 拿到的类型 `AddStream`，`SetInputMediaType` 也传**同一个类型**（输入输出一样就不会插编码器，等于直接搬），逐个 `ReadSample` → `WriteSample`（时间戳减去第一个样本的，从 0 开始），最后 `Finalize`。不重编码，60 s 的录屏应该在一秒以内。
3. 启动时找到临时的分段 MP4，同样重封装后挪进保存目录。重封装失败就原样挪过去，分段 MP4 也能放。
4. 压缩、转 GIF、抽缩略图都只对重封装之后的普通 MP4 做。

**验收**：
- 录 30 s 时用任务管理器结束进程，下次启动找回的文件能放、时长约 30 s；
- 正常停止的文件，资源管理器缩略图、「媒体播放器」拖进度条都正常；
- 报告写 60 s 和 10 分钟两种文件的重封装耗时。

### R25（P1）卸载并删除数据时，数据库和日志还开着 → 已修（`61152c0`）

- 删除前 `ShellRuntime.PrepareForUninstall()`：提交剪贴板删除 → `ClipboardService.Stop()` 关 SQLite →
  停同步定时器 / 更新检查 / 热键 / 托盘 → `Log.Shutdown()`。
- 回收站改用内置 `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(..., SendToRecycleBin)`，
  删完检查目录是否真的不在；失败弹「数据目录没删干净」并可打开文件夹。
- 和审查要求的 `IFileOperation` 不同：CsWin32 的 `IFileOperation` 在当前 NativeMethods 里生成不出来，
  先用 VisualBasic 的内置实现；行为一致（回收站 + 失败提示 + 不静默）。
- 验收还差：`.Dev` 数据目录真机点一次、故意占用一个文件看提示。

### R26（P1）同步执行层的 8 处修复没有任何自动化测试 → 已修（`6ebe604`）

**修了什么（`6ebe604`）**：
- 四类的编出去 / 落回来在 Core：`ClipSync`、`VocabularySync`、`EngineSync`、`ServiceSync`（一类一个文件，照 mac 的 SyncSource / applySync，按合出来的改动落）；一整轮在 Core 的 `SyncRunner`（+ `SyncDisk`、`SyncLedgerText`、`ISyncSource` / `ISyncDevice`）。App 的 `SyncFolder.cs` 只剩定时器、状态和四个薄适配（规划落进库，和账本同一个事务）。
- 单测 `SyncSourceTests` 19 个，§2 每一条都有；集成测试 `SyncIntegrationTests` 走真的 `SyncRunner`：两台 Windows + 假 Mac（golden 样本），3 个种子 × 24 步，最后三边一样、再合一轮谁都不写；坏文件、换回旧备份照旧验。`SyncGoldenTests` 照过。全量 306 个。
- 「两个临时数据库」没用真 SQLite（测试工程只引 Core）：仓库在内存里，落规划的几步和 `ClipboardStore.ApplySyncPlan` / `TranslationHistory.ApplySyncOps` 一一对应；SQL 那几行用真 App 冒烟验了（两份临时 `.Dev` 数据 + 临时同步文件夹，片段落进另一台的库，之后安静的轮次不重写文件）。
- 顺手照 mac 改的（提交正文里有全单）：刹车的「至少 5 条」按要删的条数算（之前按总数，删 5 条里的 2 条也刹），「照样同步」只放行不超过当时那么多条；没东西要写就不重写文件、epoch 只在写了东西时 +1 且先记库；账本读不出来这一类停下；每一类跟着功能开关；面板里有能撤销的删除时先不合。
- 没连真 Mac（用户要求 R26 做完前不连）。

- `275ea952` 修的都是「会删到每一台」级别的问题，而且全在 App 项目的 `SyncFolder.cs` 里：仓库没起来时交空表、收藏夹没落地、`group` 的写法、只交收藏、落地失败照存账本、再编不稳定、抢别人的 uid、刹车。
- 报告里也写了：「这次的改动没有自动化测试覆盖」。`PlanV5IntegrationTests` 测的是 Core 的引擎加手写的值，没经过这些代码。

**修**：
1. 把四类数据各自的「编出去」和「落回来」，从 `SyncFolder.cs` 抽成 Core 里的纯函数：输入本机的记录列表，输出 value 字典；输入合出来的改动，输出要落的改动和失败原因。照 mac 各个 `SyncSource` 的写法，一类一个文件。`SyncFolder` 只管读写文件夹、事务和状态。
2. 单测，每一条对应 `275ea952` 修的一处：
   - 仓库没起来 → 这一类不合；
   - 收藏夹同名 → 编号小的留下、条目归过去；
   - 只是片段的条目要交出去；
   - 有一条解不开 → 整类不落、不存账本；
   - 编 → 落 → 再编，字节一样（备注空白、生词前后有空格、服务缺协议，各一条）；
   - 正文撞上已经留着的条目时不抢它的 uid；
   - 本机删一大批（erasing）也要刹车，等确认的状态不被盖掉。
3. 集成测试改成走真的执行层：两个临时数据库加一个临时同步文件夹，再加一台假 Mac（值用 `sync-golden.json` 里的样本），跑几轮，最后三边一样。
4. `sync-golden.json` 审查方已经改过：之前片段的 `group` 写成了带 `group:` 前缀的，是审查方的错。mac 条目里只写收藏夹的编号，前缀只在收藏夹那条记录自己的编号上，你在 `275ea952` 里改对了。样本已经按 mac 重新生成，跑一遍单测确认还都过。

### R27（P2）第 5 批的内存回落没做 → 已修（`bacd1a6`、`bcd3eb7`；剩下的转 R34）

**补完（`bcd3eb7`，Release AOT 全量探针，专用工作集，探针用独立数据 `KITTY_PROBE_PROFILE`）**：

| 步骤 | 之前（`bacd1a6` 的探针） | 之后 |
|---|---|---|
| 截图后 / 第二次 / 空闲两分钟 | 65.4 / 68.2 / 68.2 | 66.8 / 69.6 / 69.6 |
| 设置窗关掉 30 秒 / 两分钟 | 79.8 / 79.7 | 80.9 / 80.7 |
| 录屏 5 秒，停止后两分钟 | 103.3（+23.5） | 83.9（+3.2） |
| 再录一次，两分钟后 | 每次再 +24 | 84.2（+0.3） |

- **录屏修好了**：每录一次留下一整个 D3D 设备（约 24 MB）。WinRT 的 `IDirect3DDevice` 和每帧的 `frame.Surface` 包装都拿着设备、要等 GC 终结才放；关掉 / `using` 之后设备真的销毁（`d3d.still-referenced` 会记还有人拿着的情况）。NVENC 第一次加载多 20–30 MB 是驱动，之后每次 < 1 MB。
- **冷启动**：10 次中位数 0.5.0 79 ms、第六版第 5 批 76 ms、修之前 107 ms、之后 77 ms。之前报的 64 / 90 是单次读数（这台机器单次 61–118 ms）；真正变慢的是第 7 批把开始菜单快捷方式放在启动路径上（每次 COM 解析 .lnk），挪到启动 3 秒后。
- 设置窗点 × 关掉时放掉引用；截图、录屏、录音结束和设置窗关掉之后都排空闲回收。`GCConserveMemory=5` A/B 各步差不到 0.5 MB（`d1c697c` 已开，没撤）。发布目录前 20 个看过：删 WebView2 两个 DLL（0.91 MB），`Microsoft.UI.Xaml.Phone.dll` 设置窗要用不能删，`.winmd` 先留着。
- **没做成**：截图后 +18 MB、设置窗关掉后 +10 MB，两分钟后都不降。托管堆只剩 2.5–4 MB、GDI 位图已删，剩下的是 WinUI 合成层 / XAML 模板缓存的原生内存；给截图遮罩单独建 Win2D 设备再放掉也省不下（撤了）。再往下要换做法（遮罩常驻复用或单独进程）。录音的回落没量。

`9a836e49` 的数字：

| 场景 | 内存 |
|---|---|
| 启动器 | 57.8 MB |
| 截图 | 74.0 MB（+16） |
| 设置窗打开 | 83.6 MB |
| 设置窗关掉之后稳定 | 83.5 MB（没降） |

- PLAN-v6 第 5 批第 1–3 条（截图、设置窗、录屏之后回落）和第 4 条里的 `System.GC.ConserveMemory` 都没做；「发布目录前 20 个文件逐个看」也没做。照 PLAN 做完，报告列「之前 / 之后」。
- 冷启动从 64 ms 变成了 90 ms，查一下是哪一批加的、为什么。

**复查（`3fe1725e`）**：录屏每次漏一个 D3D 设备的问题找出来修了（+23.5 MB → +3.2 MB），冷启动 107 → 77 ms，发布目录看过、去掉了 WebView2。剩下截图后 +18 MB、设置窗关掉后 +10 MB 不降，转到 R34。

### R28（P2）录音控制条 / 直接写 AAC / 断开提示 → 已修（`3df5058`）

**进展（AudioHud，`0fc69bd`、`a64a8af`）**：新增录音控制条：屏幕上方的深色胶囊，红点 / 计时 / 电平条 / 暂停继续 / 停止，
显示不抢焦点；`--audio-rec-ui=3` 实测 3.2 秒 / 79.7 KB 的 m4a。待录模式已接：设置里关掉
「按快捷键后立即开始录音」后先出条、点 ● 才开始，托盘 / 快捷键再按一次取消。麦克风 / 系统声音断开的
橙字也接了（`132b806`，录音条和录屏 HUD 都读 `LiveNote`）。直接写 AAC 也接了（`c7c4ce4`）：
PCM16 进 SinkWriter 编 AAC，容器先写分段 MP4，停止时无损重封装成 .m4a；实测 3.16 秒 / 64.9 KB。
闪退恢复也接了（`3df5058`）：录到一半强杀，临时 121.8 KB，下次启动重封装 32 ms，恢复出 5 秒 .m4a。
还没测：1 小时长录的真机稳定性和内存曲线。

- PLAN-v6 第 3 批第 4 条没接界面：待录（按快捷键先出控制条、点 ● 才开始）、电平条、「没听到声音」的提示、「按快捷键后立即开始录音」的设置。照 mac `AudioRecorder.swift` 文件头做，界面按 PLAN-v7 的轻提示 / HUD 样式。
- 第 2 批：HUD 计时后面的橙字「麦克风断开了」还没接。
- 录音现在先写临时 WAV、停止后再转 M4A：1 小时就是 690 MB 的临时文件，转码还要等。改成录的时候直接用 SinkWriter 写 AAC。闪退恢复照 R23 的办法：写分段 MP4 容器，停止时重封装成 `.m4a`。

### R29（P2）窗口录制：窗口一改大小，录制就停了 → 已修（WgcScaler）

**修（WgcScaler）**：录单个窗口时 ContentSize 变化不再停止，输出尺寸不变；WgcScaler 用 Win2D 把新画面等比缩放、居中画进输出纹理，四周补黑。同尺寸仍走 CopySubresourceRegion，缩放器起不来退回居中裁。自检 --record-resize：录 900x600 → 回全屏，日志 wgc.scaled 900x600->2560x1440，5 秒 156 帧 / 1.4 MB。还没走：真机手拖窗口边、最小化恢复。

- `OnFrameArrived` 里 `ContentSize` 一变就 `_stop.Set()`，提示「屏幕尺寸变了」。录整屏时这样处理可以；录单个窗口时，用户拖一下窗口边就停了。
- **修**：录窗口时 `ContentSize` 变了就 `Recreate` 帧池，输出尺寸不变，把新的画面按比例缩放、居中画进输出纹理（已经有 Win2D 的画布，`DrawImage` 带缩放就行），四周补黑。窗口最小化时补上一帧，窗口关掉时停止并保存。
- **验收**：录测试窗口，录的过程中拖大、拖小、最小化再恢复，文件能放、画面不变形。

### R30（P3）几处小问题

**进展（`82a5a07`、`356bb30`）**：文件搜索的 LIKE 已把 `%` / `_` / `[` 用字符类转义；`System.ItemUrl` 实测不按百分号编码（空格就是空格），不再 `Uri.UnescapeDataString`，补了 `%20` 保持原样的单测；根目录过滤改成 `SCOPE='file:C:/…'`，`--file-search=jpg` 100 条从 62 ms 降到 31 ms。第六版截图补了（`97c8e7e`，`windows-shots` 的 `0.7.0-review-r30/` 8 张：设置窗 4 处浅深各一；顺手修了深色下对话框是浅色的问题，11 处 ContentDialog 跟着设置的深浅色走）；托盘菜单和录制条是透明宿主窗口，PrintWindow / BitBlt 都截不到，没交。提交格式、各用各的 worktree 照做了。另外 `7ec18c5` 修了 `877cdf1` 起设置窗一打开就崩（`Kitty.Card` 样式键和主题画刷同名）。

- **文件搜索的 SQL**（`Core/FileSearchSql.cs`）：
  - 只转义了 `'`。`%`、`_`、`[` 在 LIKE 里是通配符，搜「[草稿]」会搜不到。改成放进方括号转义：`[%]`、`[_]`、`[[]`。
  - `LocalPathFromItemUrl` 对路径做了 `Uri.UnescapeDataString`，文件名里本来就有「%20」的会被改成空格。先确认 `System.ItemUrl` 到底是不是百分号编码的，不是就别解码，补一个单测。
  - 根目录过滤改用 `SCOPE='file:…'`，比 `System.ItemUrl LIKE` 更能用上索引（Command Palette 也这么写）。
- **提交格式**：第六版有十几个提交的标题没有 `<type>(win):`，比如「PLAN-v6 第 6 批（续）：…」。旧提交不改，以后照格式写。
- **截图**：第六版改了托盘分节、录制条开关、卸载对话框、设置里的新选项，`windows-shots` 上一张都没有。补一套：只截窗口，浅色、深色各一张。
- **几个 agent 别共用同一个检出**：`275ea952` 的报告里说「另一个 agent 在主工作区 stash 了一份」。几个 agent 同时在一个目录里改，会互相覆盖、互相 pop 错 stash。每个 agent 用自己的 `git worktree`，做完 rebase 到 `origin/windows-wip` 再推。

### R13（P0）同步的合并规则和 mac 不一样 → 已修（`f29f437`、`2728574`、`a381cbe`）

**先说审查方的错**：PLAN-v5 让你照搬的 `SyncRecords.swift` 等文件，写方案时只在 Mac 本地、没推到 `origin`，你那边拿不到，只能按文字重写。现在原样拷在 `windows/reference/mac-sync/`（README 里有对照表）。

- **差在哪**：你写的是「`modified` 大的赢，一样再看钟」；mac 是**先比钟**——一版的钟每一格都不小于另一版（盖过它）就直接赢，跟改于无关；只有两版谁也盖不住谁（真的并发改）才比改于，再一样比内容哈希（`SyncRecords.swift` 文件头「合（C1）」）。
- **会出什么事**：Windows 的系统时间比 Mac 快 5 分钟。Windows 改了一条 → Mac 读到、在它上面又改了一次（Mac 这版的钟盖过 Windows 那版，但改于比 Windows 的小）→ Windows 这一轮按改于判自己赢、把 Mac 的改动丢掉，再把钟并起来写出去 → Mac 下一轮看到的钟盖过自己的，跟着退回旧值。两台的时钟差几分钟很常见，这个不是小概率。
- 别的没对上的（都在文件头里写着）：改于不晚于现在、取 changed 时刻；账本被退回去时只追自己那一格（你现在是换编号，那是 device.json epoch 的规矩，两件事都要有）；第一次合的规则（同一编号的不算改动、内容一样的只留文件夹那条、丢的不留墓碑不进刹车）；墓碑不过期。
- **要做**：
  1. 照 `SyncRecords.swift` **逐行**搬成 `KittyTools.Core` 里的纯函数：`round`、`Join.union`、`orderID`、`arranged`、`decodeExact`、`buried`、`standing`，文件头那几段原样保留成注释。你现在的 `SyncClock`、`SyncJson`、`SyncFile` 能对上 golden 的部分留着用。
  2. `SyncRecordsTests.swift` 的 17 个用例全部移植、期望值原样；`SyncRecordsFuzzTests.swift` 照着移植（三台随机加改删合、读到旧文件、钟快慢、退回、丢账本，查三台最后一样），默认 20 个种子随全量跑，`KITTY_SYNC_FUZZ=2000` 跑 2000 个。
  3. PLAN-v5 第 3 批的集成测试：临时文件夹里两台 Windows（两个数据目录）+ 一台用 golden 样本手写的假 Mac，随机改几轮，最后三份一样。
  4. 执行层挪出 UI 线程：同步文件夹多半在云盘里，读一个还没下载的文件会卡几秒。照 `NoteSyncer.swift`：后台读写、合，回 UI 线程落地（落地和账本同一个事务）。
- **修好之前**：设置 › 通用 ›「同步」这一节先藏起来（`// ponytail:` 写上 R13），0.5.0 的产物不能给用户装来同步。
- **验收**：上面 2、3 全过；报告里写 fuzz 2000 个种子的耗时。

**进展（2026-10-25，`2728574` / `a381cbe`）：**
- 引擎已接执行层：`SyncKind` 用 `SyncEngine.Round`，旧账本 `clock|hash` 迁成新格式；设置里的「同步」重新打开。
- 17 个移植用例 + 20 个种子的 fuzz 随全量跑；`KITTY_SYNC_RECORDS_FUZZ=2000` 实测 2000 个种子 34.9 秒；
  两台 Windows + 假 Mac 的临时目录集成测试（8 轮，三份一样）也过了。
- 文件读 / 解码 / 合并已放到线程池（`Task.Run`），回 UI 线程落地和写账本。
- 还差：旧账本迁移只把 modified 记 0；真机 / 真 Mac 的长期同步没测。

**审查（2026-10-25，`1bdfde8`）**：`SyncEngine.Round` 逐段对过 `SyncRecords.round`，账本、墓碑、退回只追自己那一格、第一次合的 union / adopt、`standing`、改于取 `min(changed, now)`、赢家按（改于，哈希）都对得上。旧的 `SyncMerge` 和它的测试还在，PLAN-v6 第 0 批删掉。

### R16（P1）截图拍到了用户的隐私 → 已修（审查方：`windows-shots` 已改写并强推，`d2d38b6`；规矩在 `AGENTS.md`）

- `0.4.0-batch-1/record-saved.png`、`0.4.0-batch-2/record-select.png`、`0.4.0-batch-3/hud.png` 都是 2560×1440 的整个桌面，拍进了用户别的窗口：代理配置、局域网和代理服务器的 IP、别的对话的内容。`0.4.0-batch-4/effects-frame.jpg`、`0.4.0-batch-5/gif-frame.png` 这两张录屏帧里也有。
- **以后的规矩**（已写进 `AGENTS.md`）：
  - 截图只截我们自己的窗口：按窗口矩形裁，或者只抓我们的 HWND。
  - 录屏的验证先开一个自己的测试窗口（满屏测试图案），只录它的范围。
  - 整屏的图一律不推。推之前自己看一遍，不能有别的 App 的内容。
- 已经推上去的那几张怎么处理，由用户定（要改写 `windows-shots` 的历史），agent **不要动**。

### R17（P1）启动器文件搜索是自己扫目录 → 已修（`ed4428d`）

- 改成 `StorageFolder.CreateFileQueryWithOptions` + `IndexerOption.OnlyUseIndexer` + `System.FileName:*词*`；
  失败才退回扫目录，退路 6 层 / 2000 候选 / 300 ms。
- 怎么验的：`--file-search=jpg` 索引 **880 ms / 20 条**，`KITTY_FS_FORCE_FALLBACK=1` 退路 **33 ms / 20 条**
  （退路被 300 ms 截断；这台机器 Downloads 只有 500 多个文件，索引本身约 0.9 s）。

**审查**：改成走索引了，但 WinRT 的查询一次要 880 ms，打字时等不起。转入 PLAN-v6 第 4 批，换成 OLE DB 查索引。

### R18（P2）端口靠解析 `netstat` 的输出 → 已修（`a381cbe`）

- `Launcher/PortTable.cs` 改用 `GetExtendedTcpTable` / `GetExtendedUdpTable`（IPv4 + IPv6，TCP 只要 LISTEN，
  UDP 全部）；纯函数 `PortMath.PortOf/FormatV4` 在 Core；`PortSearch` 不再起进程。
- 怎么验的：`--ports` 实测 129 行（TCP/UDP、IPv4/IPv6、pid 都对）；`PortMath` 2 个单测（字节序、格式）。

### R21（P3）几处小问题 → 已修（`a381cbe`）

- 剪贴板预览时间改 `HH:mm` + 最小宽度，来源名超长省略；
- HUD 加 `TransparentBackdrop`，胶囊外不再有浅色方框（本地截图确认）；
- 按键胶囊加小写字形，显示 `Ctrl + Shift + S`；
- 灰格子确认是测试图本身透明（`0.3.0-batch-4/ocr-search.png` 里预览就是透明棋盘格），不是没画出来。

### R20（P2）第三版报告里记的「没做成」→ 已修（`3e978d9`、`fb0aa36`）

- 浏览器历史：`HistoryIndex` 拷 `History` + `-wal`/`-shm` 到临时文件；本机 Chrome 等载入 217 条，
  Edge 的库拷出来 malformed（正在写），跳过并记日志。
- Firefox 书签：`places.sqlite` 的 `moz_bookmarks`（type=1）并入，书签 404 条。
- Ctrl+K：自建 Flyout（过滤框 + 按钮列表，Enter / Esc），条目和右键菜单同名同顺序。
- 长截图：`S` 向下、`Shift+S` 向上、`A` 自动向下、`Shift+A` 自动向上；自动每 600 ms `SendInput` 滚一格。
- 链接头图 `DecodePixelWidth=1200`；有道 / 火山 / 腾讯签名换成 mac 固定向量（3 个全过）。
- 没测：自动滚动的真机效果（会滚当前窗口，没自动化）；Edge 历史（库正在写时拷不出来）。

### R15（P1）R4 没修好：深色下设置卡还是浅底白字 → 已修（`2728574`）

- `Theme.CardBackground/SecondaryText` 不再从 XamlControlsResources 的主题字典取（实测 Default/Light
  解出来都是 `#B3FFFFFF`，深色用错），改成跟 `EffectiveTheme` 给具体颜色；`ThemeKey` 深色先找
  `Default`，`FindTheme` 只认里面真有这个 key 的字典；启动自检日志 `theme.check` 记实际颜色。
- 怎么验的：系统浅色 + 设置深色，只截设置窗口（`0.5.0-review-r15/settings-dark-system-light.png`，
  卡片深底白字、功能卡有图标）。系统深色 + 设置浅色的组合没测（要改系统主题）；
  XAML 里能写 `ThemeResource` 的地方还没全换，留给 R4 的后续。

### R19（P2）编码：一个文件的注释是乱码、提交信息带 BOM → 已修（`2728574`）

- `Shell/OverlayWindow.cs` 文件头 4 行和第 146 行按原意重写；DeepL / Google / Microsoft 三个
  Provider 去掉 BOM；新增 `windows/.editorconfig`（`charset = utf-8`）；
  本地设了 `git config i18n.commitEncoding utf-8`，提交信息用 Python / write 工具写不带 BOM 的 UTF-8。
- 怎么验的：读文件头是正常中文；`python` 检查 Providers 下没有 BOM；本次提交标题无 U+FEFF。

### R4（P1）设置里选的外观和系统不一样时，代码里设的颜色全是错的那一套 → 已修（`4b7e0c1`）

- `Theme.Brush` 改成按设置里选的那套深浅色去 `XamlControlsResources.ThemeDictionaries[Dark / Light /
  HighContrast]` 取；`SecondaryText / CardBackground / CardColor` 用 `EffectiveTheme`；
  设置窗标题栏用 `AppWindow.TitleBar.PreferredTheme`。
- 怎么验的：系统浅色 + 设置里深色，设置窗卡片深底浅字、翻译卡深底、计算结果说明可见
  （`windows\build\shots\r4\`）；运行中切换外观时设置页会重建、取到新的那一套。

### R5（P1）轻提示和托盘菜单的宿主窗口不是透明的 → 已修（`4b7e0c1`）

- 新增 `Shell/TransparentBackdrop.cs`，轻提示和托盘菜单的宿主窗口都用它；`OnTargetConnected` 里给
  `connectedTarget.SystemBackdrop` 设一个全透明的 `Windows.UI.Composition` 颜色画刷。
- 怎么验的：整屏截图里胶囊外面没有白框；托盘菜单打开时 360×480 的宿主窗口看不见。

### R6（P1）剪贴板列表的标题被挤成三个字，来源显示成 WebView2 → 已修（`4b7e0c1`）

- 行右栏只放短时间（刚刚 / N 分钟前 / N 小时前 / 昨天 / MM-dd / yyyy-MM-dd），来源只在预览卡卡头显示；
  `Core/ProcessTree.cs` 顺着 `th32ParentProcessID` 跳过 `msedgewebview2.exe` 这类宿主，
  `ClipboardFormats.Source` 用 Toolhelp 快照查表。
- 怎么验的：截图里标题能显示到六成以上；`ProcessTreeTests` 覆盖三层 WebView2、普通进程、环、大小写。

### R7（P1）启动器的计算结果那一行溢出了 → 已修（`4b7e0c1`）

- 结果行 64 DIP、普通行 48；`PanelMetrics.LauncherHeightFor` 按实际行高算，选中高亮用容器高度。
- 怎么验的：`PanelMetricsMixedRowsTests`；深色截图里结果和说明都在行内。

### R8（P1）翻译浮窗的高度没算对，最后一张卡被底栏盖住 → 已修（`4b7e0c1`）

- `NeededHeightDip` 改成 Measure + DesiredSize；设置类错误只给「打开设置」，网络 / 服务类给「重试」。
- 怎么验的：截图里错误卡完整显示（`translate-dark2.png`），按钮只有「打开设置」。

### R9（P2）界面文字里不该出现给开发者看的话 → 已修（`4b7e0c1`）

- 通用页和关于页的文案、0.1.0 更新日志只留功能；全项目查过没有「...」占位。

### R10（P2）设置窗的几处细节 → 已修（`4b7e0c1`）

- 每项一个图标、数据目录改成卡片、关于页加应用图标、导航 / 菜单项不画焦点框（焦点给内容区）。
- 怎么验的：截图（`settings-dark-system-light.png`）里图标各不相同、数据目录是卡片；
  托盘菜单第一项没有焦点框。

### R11（P3）截图卡片和更新下载的小问题 → 已修（`4b7e0c1`）

- 拖出用 deferral + await；启动时清空 `%TEMP%\kitty-shots`；下载把 `Content-Length` 当 `knownTotal` 传进去。
- 怎么验的：`UpdateDownloadTotalTests`（不可 seek 的流也能报总大小）。

### R1（第二版第 2 批，`da8cc1a9`）自动更新只认 GitHub 的 https 地址 → 已修（`58e62c2`）

- `Core/UpdateTrust.cs`：发布列表 / 下载地址的白名单纯函数；`App/UpdateHttp.cs` 自己逐跳处理跳转、
  每一跳都过白名单。`KITTY_UPDATE_FEED`、`file://`、本地路径、`http://` 只在 Debug 或 `--update-test` 下认。
- 怎么验的：`UpdateTrustTests` 8 种地址（含大小写、端口、账号密码、`github.com.evil.com`、别的仓库）全过；
  Release AOT 正常启动设 `KITTY_UPDATE_FEED` → 日志 `update.feed-ignored` + `localFeed=False`；
  带 `--update-test` → `newer=True localFeed=True` 并下载成功。

### R2（同上）更新完退出要走正常的退出流程 → 已修（`58e62c2`）

- `AutoUpdater.ExitApplication()` 调 `ShellRuntime.Instance.Exit()`（提交剪贴板删除、注销热键、删托盘图标），
  没有壳时才退回 `Application.Exit()`。
- 怎么验的：自动更新成功路径（同 `HANDTEST.md` §135）看托盘只剩一个图标；`ShellRuntime.Exit` 的
  `clipboard.ready` / `tray.added` / 热键注册在更新前后一致。

### R3（同上）下载直接写文件，不整个读进内存 → 已修（`58e62c2`）

- `Core/UpdateDownload.cs`：80 KB 一块流式写 `updates\<文件名>.partial`，写完才改名；失败 / 取消删半成品。
  托盘那一项在下载中显示「正在下载 37%」。
- 怎么验的：`UpdateDownloadTests`（成功改名、失败不留半成品、取消不留半成品、旧 .partial 被替换）；
  400 MB 假 zip 实测私有提交 91.9 → 100.6 MB（+8.7 MB，不随文件大小涨），校验失败后 `updates\` 里没有残留。

## 有异议

（还没有）
