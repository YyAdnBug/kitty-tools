# windows/PLAN-v6.md：第六版（收尾与优化，0.6.0）

2026-10-25 写，审到 `1bdfde8f`。前五版的功能都有了，这一版**不加新功能**，做三件事：

- 没做完的补完：录屏的 GPU 管线、声音、后处理，录音补齐；
- 慢的、占地方的改好：文件搜索、内存、发布体积；
- 发布前缺的补上：开始菜单快捷方式和卸载、崩溃记录、更新的端到端测试、冒烟清单。

用户 2026-10-25 交给 agent 全程做，下面的取舍**都已按推荐定了**，照做。方案没写到的，按 `AGENTS.md`「遇到问题怎么办」处理。

## 0. 这一版的规矩

1. **顺序**：第 0 批 → 第 7 批。每批开始前先修 `REVIEW.md` 的「待修」，流程和自查清单照 `AGENTS.md`，做完一批推一批，不停。
2. **数字统一口径**，报告里都按这个写：
   - **CPU**：本进程 CPU 时间的增量 ÷ 墙钟时间，单位写「% 单核」（100% = 占满一个核）。之前「2.4%（按核数折算）」那种写法分不清是一个核还是整机。
   - **内存**：专用工作集（`PrivateWorkingSetSize`），和前几版一样。
3. **录屏的测试只录我们自己的测试窗口**。第 1 批加一个调试参数 `--test-pattern`：开一个满屏、每帧都在动的测试窗口（移动的色块 + 滚动的文字 + 帧号 + 一个每秒响一下的 1 kHz 提示音），录屏验证一律录它。不录用户的桌面（R16）。
4. **COM 接口不再手数 vtable 下标**：
   - 现在 `Mp4Recorder` 里是 `(*(void***)writer)[3]` 这种写法，第四版第一次做 SinkWriter 时就修过下标错。新写的 COM 调用用下面两种之一：
     - CsWin32 生成的结构体（`allowMarshaling=false`，项目里已经在用）；
     - .NET 的 `[GeneratedComInterface]` + `StrategyBasedComWrappers`：编译期生成、AOT 能用、零警告。PowerToys 的 Command Palette 就这么写（见第 4 批）。
   - 这不算「运行时 COM 互操作」，红线允许。
   - 旧代码动到哪个文件就改哪个文件，不单独开一批去改。
5. **删比加好**：被新做法顶掉的旧代码（AVI 那一套、旧的 `SyncMerge`、调试用的中间步骤）在同一批里删干净，不留开关。

## 1. 分批

### 第 0 批：清理（小）

- **删旧的同步合并**：
  - 删 `KittyTools.Core/Sync/SyncFile.cs` 里的 `SyncMerge`（第 238 行起），连同只测它的 `PlanV5MergePropertyTests.cs`，以及 `PlanV5Batch1Tests.cs` 里调 `SyncMerge.Merge` 的三个用例。
  - 现在合并全走 `SyncEngine.Round`，旧的留着会让人以为还在用。收敛性由 `PlanV5EngineFuzzTests` 管。
- **报告改成现状文档**：`windows/全部完成报告.md` 改写成 `windows/STATUS.md`，写现状，不写历史：
  1. 现在能做什么（按功能列）；
  2. 最新的数字（§0 的口径）；
  3. 没测的、要用户真机走的；
  4. 已知风险。
  
  旧文件里自相矛盾的几处，按现在的实际改掉：「输出是 AVI 不是 MP4」「执行层还在 UI 线程」「集成测试没写」「同步不是逐行移植」「同一条 modified 大的赢」。以后每批收尾改 `STATUS.md`，不再另写报告文件。`AGENTS.md` 里「全部完成报告」那一节同步改成指向它。
- **REVIEW 里留在「待修」的进展**，照实际挪到「已修」或「转入 PLAN-v6」（审查方已经挪好了，这一步只是核对）。
- **验收**：`dotnet test` 全过（用例数会少，报告里写少了哪几个、为什么）；`grep -r SyncMerge windows/` 没有结果。

### 第 1 批：录屏换到 GPU 管线（抓屏 → D3D11 纹理 → 硬件编码 H.264）

**现状**（`Recording/Mp4Recorder.cs`）：

- GDI `BitBlt` 抓整屏 → 每帧在 CPU 内存里新建一个 RGB32 缓冲 → SinkWriter；
- `MFCreateSinkWriterFromURL` 没传属性，所以**用不上硬件编码器**（要 `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`），文件头写的「硬件编码」不对；
- GDI 抓不到有些硬件加速的画面（视频播放器的覆盖层、部分游戏是黑的）；
- 1440p 每帧 14 MB，30 fps 就是每秒在 CPU 里搬 440 MB。

**做法**：

1. **D3D11 设备**：
   - `D3D11CreateDevice(..., D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, ...)`，硬件不行再退 WARP；
   - 开多线程保护：查询 `ID3D10Multithread`，调 `SetMultithreadProtected(TRUE)`。WGC 回调线程和编码线程会同时用这个设备，不开会随机崩。
2. **抓屏用 Windows.Graphics.Capture**：
   - `GraphicsCaptureItem`：整屏用 `IGraphicsCaptureItemInterop.CreateForMonitor(hmonitor)`，单个窗口用 `CreateForWindow`；
   - 帧池：`Direct3D11CaptureFramePool.CreateFreeThreaded(device, B8G8R8A8UIntNormalized, 2, size)`；
   - 会话：`GraphicsCaptureSession`。光标用 `IsCursorCaptureEnabled`，跟设置走；黄框用 `IsBorderRequired = false`，关不掉也照录。
   - 选区录制：抓整屏，每帧 `CopySubresourceRegion` 到一张选区大小的纹理里（宽高取偶数）。这些纹理用小池子复用，**不要每帧新建**。
   - 屏幕尺寸变了（`FrameArrived` 里 `ContentSize` 和上次不同）：`Recreate` 帧池，选区按新坐标裁；裁不出来就停止并保存，提示「屏幕变了」。
3. **编码用 SinkWriter + DXGI 设备管理器**：
   - `MFCreateDXGIDeviceManager` 拿到管理器，`ResetDevice(device, token)`；
   - 建 SinkWriter 时属性里放：
     - `MF_SINK_WRITER_D3D_MANAGER` = 这个管理器；
     - `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS` = 1；
     - `MF_TRANSCODE_CONTAINERTYPE` = `MFTranscodeContainerType_FMPEG4`（**分段 MP4**，闪退或断电时已经写下的部分还能放，见下面「闪退恢复」）。
   - 输出类型 H.264，码率按 `像素数 × 帧率 × 0.07` bit 算（1080p30 ≈ 4.4 Mbps，1440p30 ≈ 7.7 Mbps），上限 20 Mbps。输入类型 `MFVideoFormat_ARGB32`，色彩转换由 SinkWriter 自动插进来的视频处理器在 GPU 上做。
   - 每帧：`MFCreateDXGISurfaceBuffer(IID_ID3D11Texture2D, 纹理, 0, FALSE, &buffer)` → `MFCreateSample` → `AddBuffer` → `SetSampleTime` / `SetSampleDuration`（100 ns 为单位）→ `WriteSample`。
4. **时间戳**：
   - 用 `Direct3D11CaptureFrame.SystemRelativeTime`（QPC 时钟）减去开录那一刻，第 2 批的音频也用同一个时钟。
   - 屏幕不动时 WGC 不出新帧。MP4 允许可变帧率，但长时间没帧时拖进度条不准，所以**超过 1 s 没新帧就把上一张纹理再写一帧**。
   - 设置里的帧率（15 / 30 / 60）是**上限**：两帧间隔不到 1/帧率 的丢掉。
5. **点按圈、按键胶囊画在纹理上**：
   - 选区纹理建的时候加 `D3D11_BIND_RENDER_TARGET`；
   - 用 Win2D：`CanvasDevice.CreateFromDirect3D11Device(...)` 建一次，每帧 `CanvasRenderTarget.CreateFromDirect3D11Surface(...)` → `CreateDrawingSession()` 画圈和胶囊；
   - 画法（颜色、尺寸、淡出时长）照现在 `RecordingEffects.cs` 的，只是换了画布。点阵字形那一套删掉，胶囊里的字用 `CanvasTextFormat`（Segoe UI Variable）。
6. **闪退恢复**：
   - 分段 MP4 每 1–2 s 写出一段，闪退时临时文件里已经写下的段能直接放。启动时的「找回」逻辑沿用，只是不再修 AVI 头。
   - 停止时要验：资源管理器能出缩略图和时长、「媒体播放器」和 Edge 能放、能拖进度条。三样里**有一样不行**，就在停止时把分段 MP4 无损重封装成普通 MP4（SourceReader 读出压缩样本 → 第二个 SinkWriter 用同样的压缩类型写入，不重编码），报告里写耗时。三样都行就不做重封装。
7. **退路**：WGC 不可用（理论上 Win11 都有），或者硬件编码器建不起来，记日志后退回现在的 GDI + 软件编码那条路（`Mp4Recorder` 改名 `GdiMp4Recorder` 留着，只做退路）。设置里不加开关。
8. **窗口录制**：选区遮罩里「单击窗口取整窗」那一项，改成用 `CreateForWindow` 录这个窗口本身（窗口挪动、被挡住都照录），不再录屏幕上那块矩形。
9. **测试**：
   - 纯函数：码率公式、时间戳和补帧规则、选区取偶数、帧率上限丢帧，进 Core 加单测；
   - 实录：`--test-pattern` + `--record-region=60` 录 60 s。

**验收**（全部录测试窗口，数字写进报告）：

- 1440p30 录 60 s：文件 < 70 MB；录制期间本进程 CPU < 10% 单核；专用工作集比录之前多 < 40 MB，**不随时长涨**（第 10 s 和第 60 s 差 < 5 MB）；
- 录满 10 分钟一次：内存曲线平、文件能放、时长准（±0.5 s）；
- 录的过程中用任务管理器结束进程：临时文件下次启动被找回、能放；
- 帧号对得上：抽第 1、30、60 s 的帧，测试窗口上的帧号连续、不重复超过 1 帧（不动时补的帧除外）；
- 窗口录制：拖动测试窗口，录出来的始终是窗口本身；
- Release AOT 零警告。

### 第 2 批：声音（系统声音、麦克风、混音）进 MP4

**之前为什么没成**：WASAPI 回环用的是事件模式。回环流在**没有声音播放时根本不出数据包**，事件也就不来，所以「拿到第一包之后就停了」。AudioGraph 不支持从输出设备采集，报 `DeviceNotAvailable` 是预期的。

**做法**：

1. **采集线程**：一路声音一个专用线程，`CoInitializeEx(MTA)`，`AvSetMmThreadCharacteristics("Audio")` 提优先级。
2. **系统声音（回环）**：
   - `IMMDeviceEnumerator.GetDefaultAudioEndpoint(eRender, eConsole)` → `Activate(IAudioClient)` → `GetMixFormat`（一般是 48 kHz、float32、立体声；5.1 的机器是 6 声道）；
   - `Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 缓冲 200 ms, 0, mixFormat, null)`，**不带** `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`；
   - `GetService(IAudioCaptureClient)` → `Start()`。
3. **轮询**：循环里等停止事件 10 ms（`WaitOne(10)`），醒来就 `while (GetNextPacketSize() > 0)`：
   - `GetBuffer(out data, out frames, out flags, out devPos, out qpcPos)`；
   - `flags` 带 `AUDCLNT_BUFFERFLAGS_SILENT` 时按 `frames` 补零，不读 `data`；
   - 拷出来之后 `ReleaseBuffer(frames)`。
4. **补静音（关键）**：
   - 每一路记「下一帧应该落在什么时刻」，按 QPC 推：`qpcPos` 的单位是 100 ns。
   - 包上的 `qpcPos` 比预期晚了超过 10 ms（`AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY`，或者没声音时根本没包来），中间补零。
   - 一轮轮询下来一个包都没有、而墙钟已经过了 20 ms，也按墙钟补零，保证音频的时间轴和墙钟一样长。
   - 不补的话，没声音的那几段会被「吃掉」，音画越录越不同步。
5. **麦克风**：
   - `GetDefaultAudioEndpoint(eCapture, eConsole)`，同样轮询加补静音，不带回环标志；
   - `Activate` 返回 `E_ACCESSDENIED` = 系统隐私设置里没允许桌面应用用麦克风，照现在录音那套提示，并打开 `ms-settings:privacy-microphone`；
   - 录的过程中麦克风被拔掉（`AUDCLNT_E_DEVICE_INVALIDATED`）：不停录，这一路后面全补零，HUD 计时后面出橙字「麦克风断开了」（照 mac）。
6. **转格式、混音**（都放 Core 的纯函数，带单测）：
   - 多声道下混到立体声：L = FL + 0.707·C + 0.707·SL，R 对称，LFE 丢掉，再按峰值归一，防止削波。
   - 采样率不一样时线性插值重采样到 48 kHz，写 `// ponytail:`：上限是语音和提示音够用，要更好的音质再换系统的 Resampler DSP。
   - 两路按时间戳对齐后相加，软限幅：`x / (1 + |x|)` 只压超过 0.9 的部分。
   - float32 转 int16：AAC 编码器只收 16 位 PCM。
7. **写进同一个 SinkWriter**：
   - 再 `AddStream` 一路音频：输出 `MFAudioFormat_AAC`，48000 Hz、2 声道、16 位，`MF_MT_AUDIO_AVG_BYTES_PER_SECOND = 20000`（160 kbps）；输入 `MFAudioFormat_PCM`，48000 Hz、2 声道、16 位。
   - 样本时间 = `qpcPos` − 开录时刻，和视频同一个时钟。
   - 每 10–20 ms 写一个样本。
   - 写样本只在编码线程上做：采集线程把 PCM 放进队列，编码线程取出来写。SinkWriter 不能同时从几个线程写。
8. **录制条**：
   - 把「系统声音」「麦克风」两个开关打开（去掉灰色和「这一版没做」的提示）；
   - 默认值、开录那一刻才读来源、录的过程中不能改，都照 mac（`macos/KittyTools/Screenshot/ScreenRecorder.swift` 文件头和录制条的设置）；
   - 两个都关 = 只有画面，MP4 里不建音轨。

**验收**：

- 测试窗口每秒一声 1 kHz 提示音、画面上每秒闪一次白，录 60 s：抽音轨，每声提示音的起点和对应那一闪的帧的时刻差 < 50 ms，第 60 s 和第 1 s 一样准；
- 中间静音 20 s（测试窗口有开关）：总时长还是 60 s ± 0.5 s，静音之后照样同步；
- 麦克风 + 系统声音一起开：两路都在，不削波（峰值 < 0 dBFS）；
- 麦克风权限关掉时的提示；录的过程中拔掉 USB 麦克风（没有就写「没测」）；
- 5.1 声道输出的下混走单测。

### 第 3 批：录屏后处理换 MP4、删 AVI，录音补齐

1. **删掉 AVI 那一套**：
   - 删这些文件：`AviWriter`、`AviReader`、`AviRecorder`、`JpegEncoder`、`JpegDecoder`、`VideoTranscoder`（AVI 转 MP4 的中间步骤）；
   - 删这些设置：「直接录 MP4」「停止后另存 MP4」；
   - 删托盘的「转成 MP4」，删 `--mp4=` 调试参数；
   - 删 `RecordingEffects` 里的点阵字形（第 1 批已经不用了）。
2. **压缩**：`MediaTranscoder` 把 MP4 重编一遍，码率降到原来的 45%（目标是不超过原文件 60%）。分辨率、帧率、音轨不变，输出「原名 (压缩).mp4」。进度显示在托盘那一项后面（「压缩中 43%」），能取消。
3. **转 GIF**：
   - 用 `MFCreateSourceReaderFromURL` 读 MP4，属性里开 `MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING`，输出类型设成 RGB32、长边 800 的尺寸，由系统缩放。
   - 按 10 fps 取帧：读到的样本按时间戳挑，不 seek。交给现有的 GIF 编码器，流式写出。
   - 调色板换成**每帧八叉树量化**（Core 纯函数 + 单测，最多 256 色）。现在固定的 216 色立方 + 40 灰阶，截图里的渐变和抗锯齿文字色带很重。体积不超过现在的 1.3 倍，超了就把相邻帧的调色板合并。
   - 进度和取消同压缩。
4. **录音补齐**（照 mac `macos/KittyTools/Screenshot/AudioRecorder.swift` 文件头，行为一样，界面按 Windows 的胶囊样式）：
   - **待录**：按快捷键先出录音控制条 `[系统声音][麦克风] | [✕][●]`，不录、不建文件；点 ● 或再按一次快捷键才开始。设置里加「按快捷键后立即开始录音」（默认关）。
   - **来源**：麦克风 / 系统声音 / 两者，用第 2 批那套采集和混音，SinkWriter 只建一路 AAC 音轨，输出 `.m4a`（`MFTranscodeContainerType_MPEG4`，录音不长，用普通 MP4 容器）。录音原来那套 `MediaCapture` 删掉。
   - **暂停 / 继续**：暂停期间不往 SinkWriter 写样本，后面的时间戳减去暂停的总时长；计时不算暂停的时间。
   - **电平**：每 50 ms 算一次 RMS（dBFS），给控制条画电平条。开头 5 s 一直低于 −70 dB 就提示「没听到声音」，有声音了就收起；只录系统声音时不提示（照 mac）。
   - **中断**：系统睡眠时停止并保存；锁屏照录；保存卷剩余不到 1 GB 时停止并保存。
5. **验收**：
   - 第 1 批录的 60 s 文件：压缩后 ≤ 60%、能放；
   - 转 GIF：10 s → 100 帧左右，文件 < 8 MB，色带肉眼可见地比现在少（截两张对比图，只截 GIF 的内容）；
   - 录音：三种来源各 10 s、暂停一次，时长对、能放；电平和「没听到声音」的提示；
   - `grep -ri "avi" windows/KittyTools` 只剩和本功能无关的结果。

### 第 4 批：启动器的文件搜索走 Windows 搜索索引（OLE DB）

**现状**：R17 改成了 WinRT 的 `StorageFolder` 查询，实测一次 **880 ms**，比扫目录的退路（33 ms，被截断）还慢。启动器每打一个字都要等，不能用。WinRT 这条路慢在它要给每个结果建 `StorageFile` 对象。

**做法：照 PowerToys Command Palette 的 Indexer 扩展**（MIT，也是 AOT）：

- 路径 `src/modules/cmdpal/ext/Microsoft.CmdPal.Ext.Indexer/Indexer/`：`SearchQuery.cs`、`DataSourceManager.cs`、`SystemSearch/`、`OleDB/`、`Utils/`。
- 它用 `[GeneratedComInterface]` 声明这些接口：`ISearchManager`、`ISearchCatalogManager`、`ISearchQueryHelper`、`IDBInitialize`、`IDBCreateSession`、`IDBCreateCommand`、`ICommandText`、`IRowset`、`IGetRow`、`IPropertyStore`。
- 照抄接口声明可以，文件头写上来源和 MIT。

1. `ISearchManager` → `GetCatalog("SystemIndex")` → `GetQueryHelper()`，拿连接串（`get_ConnectionString`）。
2. **连接只建一次、一直留着**：照 `DataSourceManager`，第一次打开启动器时预热（空闲回收时也不丢）。每次查询只建 command。
3. SQL 自己拼，不用 `GenerateSQLFromUserQuery`（它会把中文分词搞乱）：

   ```sql
   SELECT TOP 30 System.ItemPathDisplay, System.ItemNameDisplay, System.DateModified, System.Kind
   FROM SystemIndex
   WHERE SCOPE='file:<用户目录>' AND System.FileName LIKE '%<词>%'
   ORDER BY System.DateModified DESC
   ```

   - 词里的 `'`、`%`、`_`、`[` 要转义；
   - 多个词就每个词一个 `LIKE`，用 AND 连起来；
   - SCOPE 用现在文件搜索的那几个根，用 `OR` 连起来。
4. 取行：照 Command Palette 用 `IRowset.GetNextRows` + `IGetRow.GetRowFromHROW` → `IPropertyStore`，取够 30 行就停。
5. **取消**：打下一个字时把上一个查询的结果丢掉。查询本身停不下来，但 `TOP 30` 很快。
6. 打分、排序、图标沿用现在的；WinRT 那条路删掉。
7. **退路**：Windows Search 服务没开（连接失败），或者某个根不在索引里，才退回扫目录：限 6 层、2000 个候选、300 ms，结果后面标「（没有索引）」。
8. **浏览器历史顺手修**：Edge 的 `History` 拷出来是 `malformed`，是因为拷的那一刻它正在写。拷之前先看文件最后修改时间，重试 3 次、每次间隔 200 ms；还不行这一轮跳过，15 s 后的下一次刷新再试。日志只记浏览器名和次数。

**验收**：

- 同一台机器、同一个词：**热查询 < 100 ms、冷查询（重启后第一次）< 400 ms**，各量 10 次取中位数，和 R17 的 880 ms 一起写进报告；
- 停掉 Windows Search 服务的情况只走代码路径，在报告里说明，**不去停用户的服务**；
- 中文文件名（如「报告.docx」）、带空格的、带 `'` 的都搜得到；
- Edge 历史至少有一次读成功（读不到写「没测」）。

### 第 5 批：内存、发布体积、AOT 选项

**现在的数**（全部完成报告 §2）：

| 场景 | 数字 |
|---|---|
| 空闲 | 41.8 MB |
| 四个功能各用一次 | 59.9 MB |
| 截图后 | 76.0 MB |
| 设置窗打开 | 78.6 MB |
| 发布 | 80.4 MB / 240 个文件，zip 30.6 MB |

1. **截图之后回落**：截完图、空闲两分钟后，要回到「四个功能各用一次」的水平 +5 MB 以内。
   - 先用内存探针分清多出来的 16 MB 是谁的：冻结帧位图、Win2D 的 `CanvasDevice` / `CanvasBitmap`、遮罩窗口、识字模型。报告里列出每一项。
   - 再在空闲回收里释放它们：冻结帧和 Win2D 资源 `Dispose`、`CanvasDevice.Trim()`，遮罩窗口隐藏时清掉画布内容。识字模型照 mac「空闲放模型」的做法。
2. **设置窗关掉后回落**：关掉设置窗、空闲两分钟后多出来的 < 3 MB。窗口关了要真释放（`Closed` 之后引用置空），页面里的事件订阅都要解开。
3. **录屏、录音之后回落**：停止后两分钟回到录之前 +5 MB 以内。D3D 设备、帧池、SinkWriter、采集线程都要释放。
4. **AOT 选项逐项量**（PLAN-v2 就要求了，一直没做）：
   - 下面每一项单独开，量**空闲内存、截图后内存、发布体积、冷启动**四个数，列一张表；
   - 只留「省了、而且不变慢」的；
   - `InvariantGlobalization` **不开**（PLAN-v2 §4 已定：中文排序要用）。

   | 选项 | 说明 |
   |---|---|
   | `<IlcOptimizationPreference>Size</IlcOptimizationPreference>` | |
   | `<ConcurrentGarbageCollection>false</ConcurrentGarbageCollection>` | 少一个后台 GC 线程 |
   | `<UseSystemResourceKeys>true</UseSystemResourceKeys>` | 异常消息变成资源键。界面上给用户看的都是自己写的中文，只影响日志 |
   | `<IlcFoldIdenticalMethodBodies>true</IlcFoldIdenticalMethodBodies>` | |
   | `System.GC.ConserveMemory`（runtimeconfig，取 5） | 让 GC 更积极地压缩大对象堆 |

5. **发布体积**：
   - 先看发布目录里有没有 Windows App SDK 带的一百多个语言文件夹（`af-ZA\`、`am-ET\`……，里面是 `.mui`）。有的话，在 `build-release.ps1` 打 zip 前删掉，只留 `en-US`、`zh-CN`、`zh-TW`、`zh-Hans`、`zh-Hant` 这几个：我们的界面只有中文。
   - 先在测试机上把系统显示语言换成英文和繁体中文各验一次（换不了就只验中文 + 英文的回退），确认 WinUI 自带控件的文字（如右键菜单的「复制」「粘贴」）不缺。
   - 报告列删之前和删之后的文件数和 MB。
   - 然后把整个发布目录按大小排序，前 20 个文件逐个看是不是真的用得上：比如 WebView2 的加载器，我们不用 WebView2 就去掉对应的引用。
6. **验收**：上面每一条的数字，列「之前 / 之后」两列；空闲 CPU 仍然是 0；单测全过。

### 第 6 批：质量（主题、多屏、无障碍、键盘、输入法）

1. **主题资源**：
   - R15 用写死的颜色绕过去了，长期还是要用系统的主题资源，否则高对比度主题下这些颜色全是错的。
   - 把代码里 `Theme.Brush(...)` 设上去的颜色，能写进 XAML 的改成 `{ThemeResource ...}`。设置窗的卡片、次要文字、分隔线优先改。
   - 代码里建的元素：放进一个 `ResourceDictionary` 里的 `Style`，用 `Style = (Style)Resources["..."]` 套上去，样式里写 `ThemeResource`，不要直接 new 画刷。
   - 改完：系统浅色 + 设置深色、系统深色 + 设置浅色、运行中切换外观，三种都截设置窗、翻译卡、剪贴板、启动器（只截窗口），推到 `windows-shots`。
   - 写死的颜色数量（`grep -c "Color.FromArgb"`）在报告里写「之前 / 之后」。
2. **多屏、混合 DPI**：
   - 所有算窗口位置和大小的地方，按**目标显示器**的 DPI 算：`MonitorFromPoint` / `MonitorFromRect` → `GetDpiForMonitor`，不用 `GetDpiForWindow(自己)`。窗口还在别的屏上时，拿到的是旧屏的 DPI。
   - 包括：剪贴板面板、启动器、翻译浮窗、轻提示、录屏 HUD、录音控制条、截图遮罩（每块屏一个）、钉图、飞入卡片。
   - 把这些计算抽成 Core 里的纯函数，单测覆盖「主屏 100%、副屏 150%、副屏在左边（坐标为负）、副屏竖放」四种情况。
   - 加调试参数 `--fake-dpi=150`：没有第二块屏也能看布局。真机多屏写「没测」。
3. **无障碍**：
   - 加调试参数 `--a11y-audit`：依次打开每个窗口和面板，遍历 UIA 树，列出**没有名字的可交互元素**和**键盘到不了的可交互元素**，结果写进日志。验收：两项都是 0。
   - 所有面板只用键盘能走完主流程：Tab / 方向键 / Enter / Esc；焦点框看得见（截一张焦点在按钮上的图）。
   - 读屏：每个面板打开时朗读面板名；列表项朗读「标题、来源、时间」。用系统自带的「讲述人」自己听一遍，报告里写听到了什么。
4. **输入法**：
   - 截图里直接打字、启动器、剪贴板搜索、翻译输入框，用系统自带的微软拼音各打一句中文：候选框贴着光标、上屏之前不触发搜索（组字期间不搜，上屏后才搜，否则每打一个拼音字母都搜一次）。
   - 加一个纯函数单测：组字状态下不发查询。
5. **长截图自动滚动**：
   - 现在每 600 ms 把光标挪到选区中间滚一格再挪回去。用户在这期间动了鼠标，就会和它抢光标。
   - 改成：检测到用户移动了鼠标（`GetCursorPos` 和我们上次放回去的位置不一样）就暂停自动滚动，提示「动鼠标就暂停了，按 A 继续」。
6. **R12 剩下的几项**：
   - 剪贴板和启动器的高度动画：用 Win+Shift+R 录 3–5 s（只录我们的窗口范围），逐帧看有没有闪黑、闪白。有闪就改成直接设到新高度、不做动画。
   - 翻译等待动画期间的 CPU：断网让请求停在等待状态，按 §0 的口径量。
   - 第二次截图后的内存：给内存探针加第二次截图那一步。
   - 卡片拖到资源管理器：用自动化拖不了的写「没测」。
7. **验收**：每一项的截图和数字；`--a11y-audit` 是 0。

### 第 7 批：发布前的收尾，0.6.0

1. **开始菜单快捷方式和卸载**：
   - 现在用户解压 zip 运行，退出之后没地方再打开，开始菜单里也搜不到。
   - 第一次运行时在「开始菜单 › 程序」里建 `Kitty Tools.lnk`：用 `IShellLinkW` + `IPersistFile`，快捷方式上的 `PKEY_AppUserModel_ID` 和进程的 AppUserModelID 设成同一个：程序已经调了 `SetCurrentProcessExplicitAppUserModelID` 就用那个，没调就两边都设成 `YyAdnBug.KittyTools`。这样任务栏、通知、开始菜单是同一个身份。更新换了目录也要指过去。
   - 设置 › 通用加一项「从这台电脑移除 Kitty Tools…」：确认后删掉开始菜单快捷方式、开机启动项、凭据管理器里我们的凭据，然后问「数据也删吗」（默认不删；删就把数据目录挪进回收站，用 `IFileOperation` 的 `FOFX_RECYCLEONDELETE`，不直接删），最后退出，并打开程序所在文件夹，告诉用户「把这个文件夹删掉就卸载完了」。
   - **测试只在 `.Dev` 那一套里做**，不碰用户正式版的快捷方式和数据。
2. **崩溃记录**：
   - `App.xaml.cs` 已经接了 `UnhandledException`，核对三个入口都接上了：`Application.UnhandledException`、`AppDomain.CurrentDomain.UnhandledException`、`TaskScheduler.UnobservedTaskException`。
   - 写 `logs\crash-<时间>.log`：版本、系统版本、异常类型和堆栈。不写剪贴板内容、原文、URL 这些（照红线）。
   - 下次启动发现有新的崩溃记录，弹一次轻提示「上次意外退出了，记录在 …」，点了打开所在文件夹。
   - 加调试参数 `--crash-test` 故意抛一次，验证整条链路。
3. **更新的端到端测试**：
   - 写一个脚本 `windows/tools/update-e2e.ps1`，全程在临时目录里，不碰用户装的那份：
     1. 用当前代码打两个版本号不同的包（如 0.6.0-e2e1 和 0.6.0-e2e2）；
     2. 起一个本地的假发布源（`--update-test` 已经有了）；
     3. 装旧版 → 检查更新 → 下载 → 校验 sha256 → 替换 → 重启；
     4. 新版启动后读自己的版本号，对就算过。
   - 再验两种失败：sha256 不对（不替换、提示）、替换中途有文件被占用（回滚到旧版、旧版还能起）。
4. **发版冒烟清单**：在 `HANDTEST.md` 最前面加「发版冒烟清单」，30 步以内，照 mac `macos/HANDTEST.md` 冒烟清单的写法。每个功能挑最常用、最容易坏的一两步，用户发版前花 15 分钟走完。
5. **文档**：更新 `STATUS.md`；`AGENTS.md` 的「常用命令」补上这一版新加的调试参数（`--test-pattern`、`--fake-dpi`、`--a11y-audit`、`--crash-test`、`update-e2e.ps1`）。
6. **版本**：`Directory.Build.props` 升 0.6.0，`changelog.json` 加 0.6.0（type 只用 feat / fix / perf / ui），跑 `build-release.ps1` 出 x64 / ARM64 的 zip 和 `.sha256`。**不发布**。

## 2. 要用户拍板的（agent 不做，也不用等）

- **代码签名**：现在的 exe 没签名，用户第一次运行会看到 SmartScreen 的「Windows 已保护你的电脑」，要点「更多信息 › 仍要运行」。
  - 想去掉这个提示，就要花钱买签名（如 Azure Trusted Signing，按月付费），要用户自己开账号。
  - 这一版不做；发布说明里像 mac 版那样固定写上「更多信息 › 仍要运行」的步骤（`build-release.ps1` 生成发布说明时加上）。
- **发布**：0.6.0 产物备好就停。发布由用户决定，一律 `--latest=false`。
- **真机手测**：`STATUS.md`「没测的」那一节，以及冒烟清单。

## 3. 不在这一版

- mac 有、Windows 没有的整块功能：便签、状态屏、启动台、程序坞预览。要做的话另出方案、用户拍板。
- 同步的另外三类（设置与快捷键、启动器收藏、状态屏的状态）：两边的设置项不一一对应，要先定映射，另出方案。
