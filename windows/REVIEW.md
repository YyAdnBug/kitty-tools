# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## 待修

（2026-10-25 审到 `864fc5b8`：第三版、第四版、第五版和全部完成报告。按 P0 → P1 → P2 → P3 的顺序修。）

### R13（P0）同步的合并规则和 mac 不一样，和真 Mac 一起用会丢改动

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

**进展（2026-10-25，`2728574`）：**
- 引擎已接执行层：`SyncKind` 用 `SyncEngine.Round`，旧账本 `clock|hash` 迁成新格式；设置里的「同步」重新打开。
- 17 个移植用例 + 20 个种子的 fuzz 随全量跑；`KITTY_SYNC_RECORDS_FUZZ=2000` 实测 2000 个种子 34.9 秒；
  两台 Windows + 假 Mac 的临时目录集成测试（8 轮，三份一样）也过了。
- 还差：执行层挪出 UI 线程（云盘未下载文件会卡，仍 `Task.Yield` + UI 线程）；旧账本迁移只把 modified 记 0；
  真机 / 真 Mac 的长期同步没测。

### R14（P1）录屏换成 H.264 MP4，补系统声音

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

### R16（P1）截图拍到了用户的隐私，而 `windows-shots` 在公开仓库里

- `0.4.0-batch-1/record-saved.png`、`0.4.0-batch-2/record-select.png`、`0.4.0-batch-3/hud.png` 都是 2560×1440 的整个桌面，拍进了用户别的窗口：代理配置、局域网和代理服务器的 IP、别的对话的内容。`0.4.0-batch-4/effects-frame.jpg`、`0.4.0-batch-5/gif-frame.png` 这两张录屏帧里也有。
- **以后的规矩**（已写进 `AGENTS.md`）：
  - 截图只截我们自己的窗口：按窗口矩形裁，或者只抓我们的 HWND。
  - 录屏的验证先开一个自己的测试窗口（满屏测试图案），只录它的范围。
  - 整屏的图一律不推。推之前自己看一遍，不能有别的 App 的内容。
- 已经推上去的那几张怎么处理，由用户定（要改写 `windows-shots` 的历史），agent **不要动**。

### R17（P1）启动器文件搜索是自己扫目录，E6 否掉的就是这种做法

- `Launcher/LookupServices.cs` 的 `Walk` 递归 `GetFiles` / `GetDirectories`。用户目录大的时候要几秒、费电，结果还被 `MaxCandidates` 截断（同一个词有时搜得到有时搜不到）。
- 照 E6 做：WinRT 的 `StorageFolder.GetFolderFromPathAsync(用户目录).CreateFileQueryWithOptions(new QueryOptions { FolderDepth = FolderDepth.Deep, IndexerOption = IndexerOption.OnlyUseIndexer, UserSearchFilter = … })`，非打包的桌面程序能用，只走索引。查不到（索引服务关着）时退回现在的扫目录，但限深度、限 300 ms。
- **验收**：报告里写同一个词两种做法的耗时，以及索引服务停掉后的退路。

### R18（P2）端口靠解析 `netstat` 的输出

- 每查一次起一个进程（一两百毫秒）；有些语言的系统上状态那一列是本地化的（德语是 `ABHÖREN`），解析会漏。
- 改用 `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)` / `GetExtendedUdpTable(UDP_TABLE_OWNER_PID)`（CsWin32 能生成），IPv4、IPv6 各调一次，`LauncherCommands.cs` 文件头的说明一起改。单测改成测「表的行 → 列表项」。

### R20（P2）第三版报告里记的「没做成」，补上

- 启动器：浏览器历史（Chrome / Edge 的 `History` 是 SQLite，先拷到临时文件再读，别直接打开正在用的那个）、Firefox 书签；Ctrl+K 子列表的打字过滤。
- 长截图：向上滚的入口、自动滚动（`SendInput` 滚轮，每一屏对比重叠再拼）。
- 链接预览的头图：`BitmapImage.DecodePixelWidth` 缩到长边 1200 再解码。
- 有道、火山、腾讯的签名单测：期望值换成 mac `macos/KittyToolsTests/ProviderSigningTests.swift` 里的固定向量（`origin/main` 上就有；百度那条是官方文档的例子）。自己算出来的期望值，可能和实现错在同一处。

### R21（P3）几处小问题

- 剪贴板预览头部的时间被右边的按钮盖住（`0.3.0-batch-3/clipboard-snippets.png` 只剩「16:20:3」，`0.3.0-batch-4/ocr-search.png` 只剩「16:33:4」）。时间那一列给最小宽度，放不下就不显示秒。
- `ocr-search.png` 里搜到的那张图，预览是一片灰格子。确认是测试图本身透明，还是图没画出来。
- 录屏 HUD 胶囊外面有一圈浅色方框（`0.4.0-batch-3/hud.png`），和 R5 是一回事：宿主窗口没有透明的 SystemBackdrop，用 R5 那套修。
- 按键胶囊写的是 `CTRL + SHIFT + S`，按 Windows 的习惯写成 `Ctrl + Shift + S`。

### R12（P2）第 4、5 批欠的验证

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
