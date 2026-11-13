// 设置：settings.json，带 version，源生成 JSON；写入走临时文件 + File.Replace；
// 读不出来时改名成 settings.broken-<时间>.json，再用默认值启动。
// Save 和 Changed 只许在 UI 线程上用（热键注册、XAML 资源都只认 UI 线程）；Debug 下断言，Release 下自动转回 UI 线程。
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.UI.Dispatching;

namespace KittyTools.Infrastructure;

internal sealed class Settings
{
    public int Version { get; set; } = 2;

    public bool StartWithWindows { get; set; } = true;

    public string Theme { get; set; } = "system";

    public string Accent { get; set; } = "brand";

    public bool AutoCheckUpdates { get; set; } = true;

    /// <summary>已经轻提示过的版本；每个版本只提示一次。</summary>
    public string? NotifiedUpdateVersion { get; set; }

    /// <summary>「跳过这个版本」跳过的那一版（PLAN-v11 F7）：托盘、主界面、启动器底栏不再挂「更新到 x」；更新的版本出来照常。</summary>
    public string? UpdateSkippedVersion { get; set; }

    /// <summary>有新版本时在后台下好，退出时装上，下次打开就是新版本（PLAN-v11 F7，mac X11）。关机 / 注销时不装。</summary>
    public bool UpdateInstallOnQuit { get; set; } = true;

    public bool CopyTranslate { get; set; }

    /// <summary>保留天数：1 / 7 / 30 / 90 / 365 / 0（永久）。</summary>
    public int ClipboardRetentionDays { get; set; } = 7;

    /// <summary>普通图片总占用上限（MB），0 = 不限。</summary>
    public int ClipboardImageBudgetMB { get; set; } = 512;

    public bool ClipboardBlockSensitive { get; set; } = true;

    /// <summary>链接预览（第三版 §5）：选中「只有一个网址」的文本时取标题 / 描述 / 头图。</summary>
    public bool LinkPreviews { get; set; } = true;

    // PLAN-v9-clipboard 6g（= PLAN-v9 C1，默认值照 mac Prefs）。字段名进了 settings.json，以后别改。

    /// <summary>显示透镜：选中的条目原地展开预览；关掉就是纯列表（mac clipboardShowPreview，默认开）。</summary>
    public bool ClipboardShowLens { get; set; } = true;

    /// <summary>单击条目直接粘贴（mac clipboardPasteOnClick，默认关）。</summary>
    public bool ClipboardPasteOnClick { get; set; }

    /// <summary>
    /// 剪贴板面板出现在哪（PLAN-v12 N2，mac clipboardPanelPosition b923b882，值也同 mac，跟着导出导入）：
    /// top = 鼠标所在屏的上方正中（默认）/ mouse = 光标右下（放不下翻到左边 / 上边）/ last = 上次拖到的地方（没拖过按屏幕上方）。
    /// 启动器同一套（LauncherPanelPosition）。
    /// </summary>
    public string ClipboardPanelPosition { get; set; } = "top";

    /// <summary>启动器出现在哪（mac launcherPanelPosition）：同 ClipboardPanelPosition。</summary>
    public string LauncherPanelPosition { get; set; } = "top";

    /// <summary>
    /// 剪贴板面板、启动器上次被拖到的左上角（物理像素；null = 没拖过）。这台电脑自己的状态，不在导出清单里
    /// （同 mac 的 frameName：只有用户拖过才记）。
    /// </summary>
    public int? ClipboardPanelLeft { get; set; }

    public int? ClipboardPanelTop { get; set; }

    public int? LauncherPanelLeft { get; set; }

    public int? LauncherPanelTop { get; set; }

    /// <summary>空搜索框里在收藏后面列「常用」（PLAN-v16 L1，mac launcherShowsFrequent，默认开，跟着导出导入）。</summary>
    public bool LauncherShowsFrequent { get; set; } = true;

    /// <summary>
    /// 三块主面板拖出来的大小（PLAN-v14 V11，同 mac 不注册默认值）：剪贴板 / 启动器的宽（DIP，560–1200）、最多露几行（x.5，6.5–14.5）、
    /// 翻译浮窗最高多高（DIP）。都是这台电脑自己的状态，不在导出清单里；null = 默认（720 宽、8.5 行、自动）。
    /// 翻译浮窗的宽照旧 TranslateWindowWidth。
    /// </summary>
    public double? ClipboardPanelWidth { get; set; }

    public double? LauncherPanelWidth { get; set; }

    public double? ClipboardPanelRows { get; set; }

    public double? LauncherPanelRows { get; set; }

    public double? TranslateWindowMaxHeight { get; set; }

    /// <summary>默认粘贴为纯文本：打开后 Enter 粘纯文本、Shift+Enter 保留格式（mac clipboardPastePlainByDefault，默认关）。</summary>
    public bool ClipboardPastePlain { get; set; }

    /// <summary>识别图片中的文字，用于搜索（mac clipboardImageOcr，默认开）。</summary>
    public bool ClipboardImageOcr { get; set; } = true;

    /// <summary>退出时 / 锁屏时清空普通历史（收藏、片段、收藏夹里的不清；mac 默认都关）。</summary>
    public bool ClipboardClearOnQuit { get; set; }

    public bool ClipboardClearOnLock { get; set; }

    public List<string> ClipboardExcludedApps { get; set; } = new()
    {
        "KeePass.exe",
        "KeePassXC.exe",
        "1Password.exe",
        "Bitwarden.exe",
    };

    // 翻译：语言、浮窗、服务列表。服务列表 null = 从没存过（默认只有智谱）；空列表 = 用户全删了。
    public string? TranslateFirstLanguage { get; set; } = "zh-Hans";

    public string? TranslateSecondLanguage { get; set; } = "en";

    /// <summary>浮窗上固定的源语言，null = 自动。</summary>
    public string? TranslateSource { get; set; }

    /// <summary>浮窗上固定的目标语言，null = 自动（第一 ⇄ 第二语言）。</summary>
    public string? TranslateTarget { get; set; }

    public bool TranslateAutoCopy { get; set; }

    /// <summary>
    /// 浮窗位置：top = 屏幕上方（默认，2026-10-29 用户要求：鼠标所在屏的上方正中，同启动器）；pointer = 跟随鼠标；last = 上次位置。
    /// 只管划词、复制即译、截图翻译、剪贴板「翻译」；输入翻译总在上次的位置（mac）。上次的位置（X / Y，像素）不管哪种都记。
    /// </summary>
    public string TranslateWindowPosition { get; set; } = "top";

    public double TranslateWindowX { get; set; }

    public double TranslateWindowY { get; set; }

    /// <summary>浮窗宽（DIP），最窄 420（mac 的默认宽，只能往宽里拖）。</summary>
    public double TranslateWindowWidth { get; set; } = 420;

    /// <summary>翻译前把同一段里的换行接起来（PDF 复制出来的段落；mac translateDeleteNewline，默认关）。</summary>
    public bool TranslateJoinLines { get; set; }

    /// <summary>截图翻译时把识别出的原文也写进剪贴板（默认只记进剪贴板历史；mac translateCopyRecognized）。</summary>
    public bool TranslateCopyRecognized { get; set; }

    /// <summary>译文字号倍数 0.8–1.6，一步 0.1（浮窗 Ctrl+= / Ctrl+- / Ctrl+0 和设置里的滑块同一个值）。</summary>
    public double TranslateFontScale { get; set; } = 1.0;

    /// <summary>折起来的服务卡（服务 id），重启后还折着。</summary>
    public List<string>? TranslateCollapsedServices { get; set; }

    public bool TranslatePinned { get; set; }

    /// <summary>翻译历史开关（第三版 §3.1）。</summary>
    public bool TranslateHistoryEnabled { get; set; } = true;

    /// <summary>普通历史保留条数：1000 / 5000 / 0（不限）；收藏的不算、永不淘汰。</summary>
    public int TranslateHistoryLimit { get; set; } = 5000;

    /// <summary>查词（单词模式）开关（第三版 §3.4）。</summary>
    public bool TranslateWordLookup { get; set; } = true;

    /// <summary>
    /// 截图翻译时把译文直接盖回截图上（PLAN-v16 S1，mac translateScreenshotOverlay，跟着导出导入）：截图翻译和截图工具栏的「翻译」
    /// 都留在截图页里、译文按原来的位置盖回图上。默认关：照旧在翻译浮窗里看（能对比几个服务、复制译文）。
    /// </summary>
    public bool TranslateScreenshotOverlay { get; set; }

    /// <summary>英文单词用真人发音（有道词典的录音；关掉或取不到时用系统声音，PLAN-v14 V8，键名同 mac translateWordRecording）。</summary>
    public bool TranslateWordRecording { get; set; } = true;

    /// <summary>英文单词的发音：us（美音，默认）/ uk（英音），同 mac translateWordAccent。</summary>
    public string TranslateWordAccent { get; set; } = "us";


    // 同步（第五版）：用户选的同步文件夹、开关和各类（PLAN-v12 加了提醒）。
    public bool SyncEnabled { get; set; }

    public string? SyncFolder { get; set; }

    /// <summary>连 WebDAV 服务器同步时（PLAN-v19）：服务器上同步的那个文件夹的网址（以 / 结尾）和用户名；密码在凭据管理器
    /// （Syncer.PasswordName）。这时 SyncFolder 指着数据目录里的镜像（sync-server/&lt;编号&gt;）。这台电脑自己的：
    /// 不进导出（ArchiveService 是一个键一个键手写的），Windows 也不同步设置。</summary>
    public string? SyncServer { get; set; }

    public string? SyncServerUser { get; set; }

    public bool SyncClips { get; set; } = true;

    public bool SyncVocabulary { get; set; } = true;

    public bool SyncEngines { get; set; } = true;

    public bool SyncServices { get; set; } = true;

    /// <summary>同步状态屏的状态列表（PLAN-v12 第 7 批）。</summary>
    public bool SyncStatuses { get; set; } = true;

    /// <summary>同步提醒列表（PLAN-v12 N6）。</summary>
    public bool SyncReminders { get; set; } = true;

    /// <summary>截图快速保存的文件夹；空 = 系统的「屏幕截图」文件夹。</summary>
    public string? ScreenshotSaveFolder { get; set; }

    /// <summary>保留截图历史（PLAN-v8 H3）：关掉后不再记、已记的留着。</summary>
    public bool ShotHistory { get; set; } = true;

    /// <summary>识字后把同一段里的换行接起来（PLAN-v9 V2，默认关，同 mac 的 ocrJoinLines）；截图翻译也看它（mac 的截图翻译总是接，0.1.0 用户要留原文换行）。</summary>
    public bool OcrJoinLines { get; set; }

    /// <summary>截图标注每个工具上次的样式（PLAN-v9-annotate Y8，同 mac 的 screenshotToolStyles）：工具存盘名 → 「颜色,粗细,选项」。</summary>
    public Dictionary<string, string>? ScreenshotToolStyles { get; set; }

    /// <summary>上一次截图的区域（物理像素，只在内存里，不进导出文件；第三版 §7）。</summary>
    public int ScreenshotLastX { get; set; }

    public int ScreenshotLastY { get; set; }

    public int ScreenshotLastWidth { get; set; }

    public int ScreenshotLastHeight { get; set; }

    /// <summary>呼出面板时挤压弹开（剪贴板、启动器、翻译浮窗共用，同 mac panelSqueezeEntrance，默认关）。</summary>
    public bool PanelSqueezeEntrance { get; set; }

    /// <summary>每天自动备份设置与数据（PLAN-v9 G2，默认开，同 mac）。这台电脑自己的状态，不跟着导出导入走。</summary>
    public bool DailyBackup { get; set; } = true;

    /// <summary>每天那份另存一份到这个文件夹（PLAN-v9 G2；null = 不另存）。</summary>
    public string? BackupCopyFolder { get; set; }

    /// <summary>截图历史留几天（PLAN-v9 S8）：7 / 30（默认）/ 90 / 0 = 一直留着。</summary>
    public int ShotHistoryDays { get; set; } = Core.ShotHistoryRules.DefaultDays;

    /// <summary>截图历史最多占用多少 MB（PLAN-v9 S8）：1024 / 2048（默认）/ 5120 / 0 = 不限。</summary>
    public int ShotHistoryMegabytes { get; set; } = 2048;

    /// <summary>截图时播放快门声（PLAN-v9 S6，默认开，同 mac）：拷贝、存储、钉图时响。</summary>
    public bool ScreenshotShutterSound { get; set; } = true;

    /// <summary>截图带上鼠标指针（PLAN-v11 F5，mac X8，默认关）：按快捷键那一刻的指针画进冻结帧。</summary>
    public bool ScreenshotCursor { get; set; }

    /// <summary>截图、录屏时隐藏桌面图标（PLAN-v11 F6，mac X9，默认关）：截的那一下、录的整段，完了显示回来。</summary>
    public bool CaptureHideDesktopIcons { get; set; }

    /// <summary>截完图放哪（PLAN-v9 S7）：card = 角落缩略图（默认）/ none = 都不要（照样进截图历史）。</summary>
    public string ShotPlacement { get; set; } = "card";

    /// <summary>
    /// 长截图自动滚动的速度（PLAN-v12 N3，mac scrollCaptureSpeed）：slow / normal（默认）/ fast = 每秒滚出 0.3 / 0.6 / 1.2 个选区高
    /// （Core ScrollPacer）。在长截图预览面板上换，记住上次；不在设置页里。
    /// </summary>
    public string ScrollCaptureSpeed { get; set; } = "normal";

    /// <summary>
    /// 截图工具栏、录屏的录制条贴选区哪边（PLAN-v12 N4，mac screenshotToolbarAlign 0f83c117，跟着导出导入）：
    /// right = 栏的右边线对齐选区右边线（默认：从左上往右下拖完，完成钮就在鼠标旁边）/ center = 选区下方居中。长图标注照旧居中。
    /// </summary>
    public string ScreenshotToolbarAlign { get; set; } = "right";

    /// <summary>
    /// 截图拷贝为（PLAN-v15，mac screenshotCopyAs 2026-11-06，跟着导出导入）：image = 剪贴板里放图像（默认）/ file = 放一个 PNG 文件，
    /// 同在资源管理器里复制一个文件——只搬文字和文件的跨电脑剪贴板（USB 对拷线的配套软件、有的远程工具）也传得过去。
    /// </summary>
    public string ScreenshotCopyAs { get; set; } = "image";

    /// <summary>
    /// 框选时保持屏幕原色（PLAN-v16 S2，mac screenshotKeepsColors，跟着导出导入）：打开后框选不压暗（整屏和洞外都不压）、
    /// 悬停的窗口只描边不填粉、放大镜的十字带只描线。默认关。截图、截图翻译 / 识字、录屏的框选都管。
    /// </summary>
    public bool ScreenshotKeepsColors { get; set; }

    // 录制（第四版）：帧率、保存目录、上次没写完的临时文件（闪退恢复用）。
    public int RecordFps { get; set; } = Core.RecorderRules.DefaultFps;

    public string? RecordDirectory { get; set; }

    public string? RecordingTempPath { get; set; }

    /// <summary>录音中的临时分段 MP4（闪退恢复用，R28）。</summary>
    public string? AudioTempPath { get; set; }

    /// <summary>录制中显示点按圈（第四版第 3 批，默认关）。</summary>
    public bool RecordClicks { get; set; }

    /// <summary>录制中显示快捷键胶囊（默认关）。</summary>
    public bool RecordKeys { get; set; }

    /// <summary>显示按键时只显示快捷键（PLAN-v9 R4）：默认 false = 全部按键（同 mac；打的字也会录进去）。</summary>
    public bool RecordKeysShortcutsOnly { get; set; }

    /// <summary>录屏的清晰度（PLAN-v9 R5）：original = 原样（默认）/ standard = 长边封顶 1920。</summary>
    public string RecordSharpness { get; set; } = "original";

    /// <summary>录屏开始前倒数几秒（PLAN-v9 R2）：0 / 3（默认）/ 5。</summary>
    public int RecordCountdown { get; set; } = 3;

    /// <summary>录屏里录不录鼠标光标（PLAN-v9 R3，默认录）。</summary>
    public bool RecordCursor { get; set; } = true;

    /// <summary>录屏时录系统声音（默认开，PLAN-v6 第 2 批）。</summary>
    public bool RecordSystemSound { get; set; } = true;

    /// <summary>录屏时录麦克风（默认关）。</summary>
    public bool RecordMicrophone { get; set; }

    /// <summary>
    /// 录屏用哪个麦克风（PLAN-v11 F12，mac X18）：WASAPI 的端点 Id，null = 跟随系统（默认）。只管录屏，录音照旧用系统默认的。
    /// 选的设备录的时候不在（拔了、关了）就用系统默认的，录制条上提示。
    /// </summary>
    public string? RecordMicrophoneDevice { get; set; }

    /// <summary>
    /// 按录音快捷键后立即开始；关着时先在屏幕底部出控制条，点「开始」或再按一次才录（REVIEW R28）。
    /// 默认关（PLAN-v9 V4，同 mac：先让人看见录的是哪一路、电平动不动）。
    /// </summary>
    public bool RecordInstantStart { get; set; }

    /// <summary>
    /// 录音录什么（PLAN-v9 V5）：microphone（默认，同 mac）/ system / both。和录屏的 RecordSystemSound / RecordMicrophone 分开；
    /// 选了麦克风却用不了（隐私设置里关着）时 AudioHost 改成 system 并提示。
    /// </summary>
    public string AudioSource { get; set; } = "microphone";

    public List<TranslateServiceConfig>? TranslateServices { get; set; }

    /// <summary>启动器的网页搜索列表；null = 从没存过（默认前 8 个，Bing 兜底）。</summary>
    public List<KittyTools.Core.SearchEngine>? LauncherSearchEngines { get; set; }

    // 启动器对齐 mac（PLAN-v9-launcher，2026-10-28）。字段名进了 settings.json、跟着设置导出，以后别改。

    /// <summary>呼出时切到英文输入法（mac launcherRomanInput，默认关；PLAN-v9 L1）。</summary>
    public bool LauncherRomanInput { get; set; }

    /// <summary>有本地结果时也显示兜底搜索（mac launcherFallbackAlways，默认关；PLAN-v9 L4）。</summary>
    public bool LauncherFallbackAlways { get; set; }

    /// <summary>书签开着的浏览器 id；null = 从没设过（Edge、Chrome，PLAN-v9 V1）。</summary>
    public List<string>? LauncherBookmarkBrowsers { get; set; }

    /// <summary>也搜浏览历史的浏览器 id（书签也开着才算）；null = 都没开。</summary>
    public List<string>? LauncherHistoryBrowsers { get; set; }

    /// <summary>
    /// 汇率换算用过的货币（PLAN-v12 N1，mac Prefs.launcherRecentCurrencies）：候选里排最前，最多 8 种。这台电脑自己的，
    /// 不在导出清单里（ArchiveService.PreferencesOf 是白名单）。
    /// </summary>
    public List<string>? LauncherRecentCurrencies { get; set; }

    // 状态屏（PLAN-v12 N5，mac Prefs.statusScreen*）。

    /// <summary>状态列表（Core 的 StatusPreset，键名同 mac：id / title / detail / symbol / style / power / autoEndMinutes）；null = 自带的三个。</summary>
    public List<KittyTools.Core.StatusPreset>? StatusScreenPresets { get; set; }

    /// <summary>有人碰键盘鼠标时显示怎么退出（默认开）。</summary>
    public bool StatusScreenExitHint { get; set; } = true;

    /// <summary>按状态屏的全局快捷键时直接进入排在最前面的状态（默认关：先出一排预览卡片，选一个再进）。</summary>
    public bool StatusScreenHotKeyEntersFirst { get; set; }

    /// <summary>告示上的动画（表情动、进入时的出场、甩一下、冒眼睛；默认开）。</summary>
    public bool StatusScreenAnimations { get; set; } = true;

    /// <summary>上次进入的状态（选状态的面板默认选中它）。这台电脑自己的状态，不导出。</summary>
    public string? StatusScreenLastPreset { get; set; }

    // 提醒（PLAN-v12 N6，mac Prefs.reminders / remindersState / remindersSnoozeMinutes）。

    /// <summary>提醒列表（Core 的 Reminder）；null = 没存过（三条示例，都关着）。</summary>
    public List<KittyTools.Core.Reminder>? Reminders { get; set; }

    /// <summary>每条处理到哪一刻、推到几点、暂停到几点：这台电脑自己的，不导出、不同步。</summary>
    public KittyTools.Core.ReminderState? RemindersState { get; set; }

    /// <summary>「稍后」推几分钟（5 / 10 / 15 / 30，默认 5）。</summary>
    public int RemindersSnoozeMinutes { get; set; } = 5;

    // 便签（PLAN-v13，键名同 mac Prefs.notes*；设置窗、那叠、浮动便签、全部便签窗口读它们）。

    /// <summary>正文字号（13 / 15 / 17 / 20，默认 15；不在档位里的按 15）。</summary>
    public int NotesFontSize { get; set; } = 15;

    /// <summary>Markdown 样式（默认开；关着时只认任务方框和文字颜色）。</summary>
    public bool NotesMarkdown { get; set; } = true;

    /// <summary>行距：compact 1.2 / standard 1.45（默认）/ relaxed 1.7。</summary>
    public string NotesLineSpacing { get; set; } = "standard";

    /// <summary>在屏幕边缘显示便签（默认开；有了第一条便签才出现）。</summary>
    public bool NotesDeckEnabled { get; set; } = true;

    /// <summary>right（默认）/ left。</summary>
    public string NotesDeckEdge { get; set; } = "right";

    /// <summary>main 主显示器（默认）/ all 所有显示器 / chosen 指定的那块（NotesDeckChosenDisplay）。</summary>
    public string NotesDeckDisplay { get; set; } = "main";

    /// <summary>tabs 带标题的标签（默认）/ chips 只有色块。</summary>
    public string NotesDeckStyle { get; set; } = "tabs";

    /// <summary>small / standard（默认）/ large。</summary>
    public string NotesDeckSize { get; set; } = "standard";

    /// <summary>鼠标离边多近算靠过去（DIP，默认 14）。</summary>
    public int NotesDeckSense { get; set; } = 14;

    public bool NotesDeckAlwaysFanned { get; set; }

    public bool NotesDeckHidesPill { get; set; }

    public bool NotesDeckPreview { get; set; } = true;

    public bool NotesDeckOpensOnHover { get; set; }

    public bool NotesDeckOverFullScreen { get; set; }

    /// <summary>打开的便签多大：small / medium（默认）/ large / extraLarge。</summary>
    public string NotesDeckNoteSize { get; set; } = "medium";

    // 下面这几样是这台电脑自己的状态（mac 不注册默认值、不跟导出走；ArchiveService 的导出清单是白名单，本来就不带）。

    /// <summary>药丸的纵向位置（0–1，工作区里从上往下的比例）；null = 默认（中间偏上）。</summary>
    public double? NotesDeckPosition { get; set; }

    /// <summary>指定的那块显示器（设备名）。</summary>
    public string? NotesDeckChosenDisplay { get; set; }

    /// <summary>「便签在屏幕右边缘」那句提示说过没有。</summary>
    public bool NotesDeckHintShown { get; set; }

    /// <summary>示例便签放过没有（只放一次）。</summary>
    public bool NotesSampleAdded { get; set; }

    /// <summary>浮动便签拉过的大小「宽,高」（DIP）。</summary>
    public string? NotesFloatSize { get; set; }

    /// <summary>固定着浮在屏幕上的每一张在哪：一组 {"id", "frame", "display"}（NoteFloatLayout.Place.ToStored / NoteFloatSet.Restorable，同 mac）。</summary>
    public List<Dictionary<string, string>>? NotesFloatPlaces { get; set; }

    /// <summary>最近用过的自定义纸色（「#RRGGBB」，最多 8 个；NotePaper.RecentColors 读）。</summary>
    public List<string>? NotesRecentColors { get; set; }

    /// <summary>全部便签窗口上次用的显示方式：wall 便签墙（默认）/ list 列表。</summary>
    public string? NotesWindowLayout { get; set; }

    /// <summary>同步便签（PLAN-v13 第 3 批；默认开，跟着便签功能开关）。</summary>
    public bool SyncNotes { get; set; } = true;

    public List<HotKeySetting> HotKeys { get; set; } = new();

    /// <summary>
    /// 功能开关（第三版 §2.3）：clipboard / translate / launcher / screenshot → 开没开。
    /// 没存过的当开；关掉只停入口和后台工作，数据层照常。
    /// </summary>
    public Dictionary<string, bool>? Features { get; set; }

    /// <summary>设置侧栏收起了的组（组标题；PLAN-v16 G2，这台电脑自己的，不导出不同步）。</summary>
    public List<string>? SettingsCollapsedGroups { get; set; }

    /// <summary>设置侧栏最底下「已关闭」那组展开着没有（默认收起）。</summary>
    public bool SettingsShowsOffFeatures { get; set; }

    /// <summary>
    /// 新功能标记的账（PLAN-v16 G3，这台电脑自己的，不导出不同步）：各版本第一次打开的时刻（Unix 毫秒，0 = 很久以前）、碰过哪几个；
    /// 上次运行的版本（升级上来才标，新装不标）。
    /// </summary>
    public Dictionary<string, long>? WhatsNewStarted { get; set; }

    public List<string>? WhatsNewTouched { get; set; }

    public string? LastRunVersion { get; set; }
}

/// <summary>一个翻译服务的非密钥配置（密钥在凭据管理器，字段名见 SecretField）。</summary>
internal sealed class TranslateServiceConfig
{
    public string Id { get; set; } = string.Empty;

    /// <summary>zhipu / google / deepl / microsoft / ai。</summary>
    public string Kind { get; set; } = "ai";

    public string Name { get; set; } = string.Empty;

    public bool Enabled { get; set; } = true;

    public string? Model { get; set; }

    public string? BaseUrl { get; set; }

    /// <summary>openai / azure / anthropic。</summary>
    public string? Protocol { get; set; } = "openai";

    /// <summary>微软翻译填了 key 时的区域。</summary>
    public string? Region { get; set; }

    /// <summary>DeepL 走自建 DeepLX；null = 从没写过（同步时要和 false 区分，R32）。</summary>
    public bool? UsesDeepLX { get; set; }
}

internal sealed class HotKeySetting
{
    public string Action { get; set; } = string.Empty;

    public uint Modifiers { get; set; }

    public uint VirtualKey { get; set; }
}

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    ReadCommentHandling = JsonCommentHandling.Skip,
    AllowTrailingCommas = true)]
[JsonSerializable(typeof(Settings))]
internal partial class SettingsJsonContext : JsonSerializerContext
{
}

internal static class SettingsService
{
    private static readonly object Gate = new();
    private static Settings _current = new();
    private static DispatcherQueue? _dispatcher;

    public static Settings Current => _current;

    public static bool IsNew { get; private set; }

    /// <summary>这次启动是新装（或设置文件坏了重来）：Save 不清它，欢迎引导和「上次运行的版本」都看它（R69：
    /// 启动时 WhatsNewHost.Adopt、示例便签都会先 Save，IsNew 到 ShellRuntime 看的时候已经是 false）。</summary>
    public static bool FirstRun { get; private set; }

    public static event Action? Changed;

    /// <summary>当前在不在 UI 线程上（没有 dispatcher 时当作在：Load 之前的调用都发生在启动线程上）。</summary>
    public static bool OnUiThread => _dispatcher is null || _dispatcher.HasThreadAccess;

    public static void Load()
    {
        _dispatcher ??= DispatcherQueue.GetForCurrentThread();
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.DataDirectory);
                if (!File.Exists(Paths.SettingsFile))
                {
                    _current = new Settings();
                    IsNew = true;
                    FirstRun = true;
                    SettingsDefaults.Apply(_current);
                    // 新装只开剪贴板、启动器、翻译、截图（PLAN-v16 G2，同 mac seedNewInstall）：默认值不变，把各个开关明写进设置。
                    // 测试档要 KITTY_SEED_FEATURES=1 才写（自检、截图的新档照旧全开）。
                    if (!Paths.IsTestProfile || Environment.GetEnvironmentVariable("KITTY_SEED_FEATURES") == "1")
                    {
                        _current.Features = Core.SettingsSidebar.SeedNewInstall(KittyTools.Features.AllKeys, _current.Features);
                    }

                    return;
                }

                var json = File.ReadAllText(Paths.SettingsFile);
                var loaded = JsonSerializer.Deserialize(json, SettingsJsonContext.Default.Settings);
                if (loaded is null)
                {
                    throw new JsonException("settings.json 反序列化结果是 null");
                }

                _current = loaded;
                SettingsDefaults.Apply(_current);
                IsNew = false;
                if (_current.Version < 1)
                {
                    _current.Version = 1;
                }

                // 0.6.0 之前没有「录屏系统声音」这个字段；JSON 里缺了会解成 false，这里补回默认开。
                if (_current.Version < 2)
                {
                    _current.RecordSystemSound = true;
                    _current.Version = 2;
                }

                // 帧率只剩 30 / 60（PLAN-v9 V3）：以前存的 15 读成 30。
                _current.RecordFps = Core.RecorderRules.NormalizeFps(_current.RecordFps);
            }
            catch (Exception ex)
            {
                IsNew = true;
                FirstRun = true;
                _current = new Settings();
                SettingsDefaults.Apply(_current);
                Log.Error("settings.load-failed", ex);
                QuarantineBrokenFile();
            }
        }
    }

    public static void Save()
    {
        // 第二版 §2 P0：Save 和 Changed 只许在 UI 线程上跑。更新检查的线程池回调以前直接 Save，
        // 结果热键从错的线程上重注册全部失效、改主题颜色还会跨线程访问 XAML 资源。
        if (!OnUiThread)
        {
            Log.Error("settings.save-off-ui-thread");
            Debug.Assert(false, "SettingsService.Save 只能在 UI 线程调用");
            _dispatcher?.TryEnqueue(Save);
            return;
        }

        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.DataDirectory);
                var json = JsonSerializer.Serialize(_current, SettingsJsonContext.Default.Settings);
                var temporary = Paths.SettingsFile + ".tmp";
                File.WriteAllText(temporary, json);
                if (File.Exists(Paths.SettingsFile))
                {
                    File.Replace(temporary, Paths.SettingsFile, null);
                }
                else
                {
                    File.Move(temporary, Paths.SettingsFile);
                }

                IsNew = false;
            }
            catch (Exception ex)
            {
                Log.Error("settings.save-failed", ex);
            }
        }

        Changed?.Invoke();
    }

    public static void MarkStarted()
    {
        if (IsNew)
        {
            IsNew = false;
            Save();
        }
    }

    private static void QuarantineBrokenFile()
    {
        try
        {
            if (!File.Exists(Paths.SettingsFile))
            {
                return;
            }

            var broken = Path.Combine(Paths.DataDirectory, $"settings.broken-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.Move(Paths.SettingsFile, broken, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Error("settings.quarantine-failed", ex);
        }
    }
}
