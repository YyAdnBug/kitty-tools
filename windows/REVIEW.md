# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## 待修

（2026-10-26 审到 `ad82a921`：第六版第 0–7 批。按 P1 → P2 → P3 的顺序修；PLAN-v7 的批次照常往下做，每批开始前先修这里。）

**先说做得好的**：
- GPU 录屏管线做对了：D3D 设备开了视频支持和多线程保护，WGC 的帧用完就还，硬件编码打开了。
- 声音是轮询 + 补静音，10 分钟漂移 ≤ 10 ms。
- AVI 那一套删干净了。
- 文件搜索 880 ms → 62 ms。
- 更新的端到端测试四种情况都过。
- 无障碍自查 0 / 0。
- `275ea952` 自己查出了同步执行层 8 处会删到每一台的问题。

### R22（P1）录屏 HUD 没按 DPI 算尺寸，还写死了屏幕高 1440 → 已修（`82a5a07`）

- HUD 尺寸按目标显示器 `Displays.AtPoint(...).Scale` 换算成物理像素；位置由 Core `HudPlacement.Compute` 限在工作区，下方放不下放上方、再放不下贴选区里面下边。
- `AppWindow.Show(false)` + `WS_EX_NOACTIVATE`，不再 `Activate()` 抢焦点。
- 单测 `HudPlacementTests` 4 条：150%、贴底、整屏、负坐标副屏。
- 还没做：`--fake-dpi=150` 真机截图和“开录后焦点还在原程序”的手测（见 HANDTEST）。

### R23（P1）去掉分段 MP4 以后，闪退会丢掉整段录屏 → 大部分已修

**进展（`266a485`，Mp4Remux）**：
- 录制重新写 FMPEG4（`MFTranscodeContainerType_FMPEG4`），moov 及时落盘。
- 新增 `Mp4Remux`：SourceReader + SinkWriter 按原生压缩样本逐个搬，不重编码；每路时间戳从 0 开始；
  没有音频流按只有画面处理；失败退回「分段 MP4 原样改名」。
- 正常停止和 `RecoverOnStartup` 都走重封装；实测 2 秒 / 3 秒 / 5 秒文件重封装 16–47 ms，
  最终文件 `ftyp=mp42`、`moov` 在尾部、Shell 读出 2 秒 / 3 秒 / 5 秒；崩溃恢复的 5 秒文件也能读时长。
- 仍然差验收里的 **60 秒 / 10 分钟两种重封装耗时**，以及真实系统声音 / 麦克风两路设备
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

### R24（P1）第 2 批的音画同步是对着一张不动的画面量的，要重做

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

### R27（P2）第 5 批的内存回落没做

**进展（`7c63a11`）**：设置窗关闭时清空卡片 / 导航项 / 内容并 `GC.Collect`；加 `System.GC.ConserveMemory=5`。
0.7.0 快速探针（FAST，专用工作集）：托盘 36.0 / 5000 条 47.1 / 剪贴板 49.2 / 启动器 49.8 / 翻译 52.1 /
截图 71.3 / 第二次 74.5 / 钉图 75.2 / 设置 86.8 → 关 86.2 MB。**设置关掉只降 0.6 MB，回落仍不达标**；
截图 / 录屏后的回落和「发布目录前 20 个文件逐个看」还没做，冷启动 90 ms 也没查。

`9a836e49` 的数字：

| 场景 | 内存 |
|---|---|
| 启动器 | 57.8 MB |
| 截图 | 74.0 MB（+16） |
| 设置窗打开 | 83.6 MB |
| 设置窗关掉之后稳定 | 83.5 MB（没降） |

- PLAN-v6 第 5 批第 1–3 条（截图、设置窗、录屏之后回落）和第 4 条里的 `System.GC.ConserveMemory` 都没做；「发布目录前 20 个文件逐个看」也没做。照 PLAN 做完，报告列「之前 / 之后」。
- 冷启动从 64 ms 变成了 90 ms，查一下是哪一批加的、为什么。

### R28（P2）录音还缺控制条，录屏 HUD 还缺「麦克风断开了」

**进展（AudioHud，`0fc69bd`、`a64a8af`）**：新增录音控制条：屏幕上方的深色胶囊，红点 / 计时 / 电平条 / 暂停继续 / 停止，
显示不抢焦点；`--audio-rec-ui=3` 实测 3.2 秒 / 79.7 KB 的 m4a。待录模式已接：设置里关掉
「按快捷键后立即开始录音」后先出条、点 ● 才开始，托盘 / 快捷键再按一次取消。还没做：
HUD 里的「麦克风断开了」、录音直接写 AAC（仍是临时 WAV 再转）。

- PLAN-v6 第 3 批第 4 条没接界面：待录（按快捷键先出控制条、点 ● 才开始）、电平条、「没听到声音」的提示、「按快捷键后立即开始录音」的设置。照 mac `AudioRecorder.swift` 文件头做，界面按 PLAN-v7 的轻提示 / HUD 样式。
- 第 2 批：HUD 计时后面的橙字「麦克风断开了」还没接。
- 录音现在先写临时 WAV、停止后再转 M4A：1 小时就是 690 MB 的临时文件，转码还要等。改成录的时候直接用 SinkWriter 写 AAC。闪退恢复照 R23 的办法：写分段 MP4 容器，停止时重封装成 `.m4a`。

### R29（P2）窗口录制：窗口一改大小，录制就停了

**进展（`a7490ec`）**：录单个窗口时 `ContentSize` 变化不再停止，输出尺寸不变；按新内容居中裁，
窗口变小四周补黑（RTV + `ClearRenderTargetView`）。实测 `--record-test=3` 窗口录制 94 帧 / 3.1 秒 / 626 KB，
重封装 15 ms。还不是按比例缩放（四周留黑），拖窗口边 / 最小化恢复的真机验收待走。

- `OnFrameArrived` 里 `ContentSize` 一变就 `_stop.Set()`，提示「屏幕尺寸变了」。录整屏时这样处理可以；录单个窗口时，用户拖一下窗口边就停了。
- **修**：录窗口时 `ContentSize` 变了就 `Recreate` 帧池，输出尺寸不变，把新的画面按比例缩放、居中画进输出纹理（已经有 Win2D 的画布，`DrawImage` 带缩放就行），四周补黑。窗口最小化时补上一帧，窗口关掉时停止并保存。
- **验收**：录测试窗口，录的过程中拖大、拖小、最小化再恢复，文件能放、画面不变形。

### R30（P3）几处小问题

**进展（`82a5a07`、`356bb30`）**：文件搜索的 LIKE 已把 `%` / `_` / `[` 用字符类转义；`System.ItemUrl` 实测不按百分号编码（空格就是空格），不再 `Uri.UnescapeDataString`，补了 `%20` 保持原样的单测；根目录过滤改成 `SCOPE='file:C:/…'`，`--file-search=jpg` 100 条从 62 ms 降到 31 ms。剩下：第六版截图、提交格式、多 agent worktree。

- **文件搜索的 SQL**（`Core/FileSearchSql.cs`）：
  - 只转义了 `'`。`%`、`_`、`[` 在 LIKE 里是通配符，搜「[草稿]」会搜不到。改成放进方括号转义：`[%]`、`[_]`、`[[]`。
  - `LocalPathFromItemUrl` 对路径做了 `Uri.UnescapeDataString`，文件名里本来就有「%20」的会被改成空格。先确认 `System.ItemUrl` 到底是不是百分号编码的，不是就别解码，补一个单测。
  - 根目录过滤改用 `SCOPE='file:…'`，比 `System.ItemUrl LIKE` 更能用上索引（Command Palette 也这么写）。
- **提交格式**：第六版有十几个提交的标题没有 `<type>(win):`，比如「PLAN-v6 第 6 批（续）：…」。旧提交不改，以后照格式写。
- **截图**：第六版改了托盘分节、录制条开关、卸载对话框、设置里的新选项，`windows-shots` 上一张都没有。补一套：只截窗口，浅色、深色各一张。
- **几个 agent 别共用同一个检出**：`275ea952` 的报告里说「另一个 agent 在主工作区 stash 了一份」。几个 agent 同时在一个目录里改，会互相覆盖、互相 pop 错 stash。每个 agent 用自己的 `git worktree`，做完 rebase 到 `origin/windows-wip` 再推。


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
