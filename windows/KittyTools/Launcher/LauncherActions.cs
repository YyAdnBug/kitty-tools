// 启动器里本 App 自己的动作（PLAN-v9-launcher R12 = PLAN-v9 L8，照 mac LauncherItem.actions）：和托盘菜单同名同序——
// 剪贴板历史、暂停记录剪贴板（副标题写正在记录 / 已暂停）｜输入翻译、复制即译（已开启 / 已关闭）｜截图、截图翻译、截取上次区域、
// 识字、截图历史、钉住剪贴板内容、隐藏 / 显示全部钉图和关闭全部钉图（有钉图时，PLAN-v9 S10）、录屏、录音｜打开主界面（PLAN-v10 §5）、设置、快捷键速查表、
// 关于 Kitty Tools、检查更新（有新版本时「更新到 x」）、退出 Kitty Tools。
// 关着的功能那一节不列（Feature）；启动器自己、划词翻译不列（点了启动器，原来的程序就不在前台了，取不到选中的字，同托盘 G1）。
// 副标题只写「Kitty Tools」，英文名和拼音只进匹配；对得上全局快捷动作的，选中时右边显示它的键帽。
// 退出排在最后（同系统命令），避免回车误退；退出不记使用。老的 9 个 id 不改（使用记录按 id 累计）。
// 状态屏（PLAN-v12 N5，mac LauncherItem.statusPreset）：每个状态一行，id 是「statusScreen:」+ 状态的 id（收藏按它认），标题是状态的标题、
// 右侧小字「状态屏」，输标题、「状态屏」、拼音都搜得到；Enter 直接进入、不确认，所以同分时排在别的结果后面、也不记使用。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class LauncherActions
{
    public const string Clipboard = "action:clipboard";
    public const string PauseClipboard = "action:pause-clipboard";
    public const string Translate = "action:translate";
    public const string CopyTranslate = "action:copy-translate";
    public const string Screenshot = "action:screenshot";
    public const string ScreenshotTranslate = "action:screenshot-translate";
    public const string ScreenshotLast = "action:screenshot-last";
    public const string DelayedScreenshot = "action:delayed-screenshot";
    public const string Ocr = "action:ocr";
    public const string ShotHistory = "action:shot-history";
    public const string PinClipboard = "action:pin-clipboard";
    public const string PinsToggle = "action:pins-toggle";
    public const string PinsClose = "action:pins-close";
    public const string Record = "action:record";
    public const string Audio = "action:audio";
    public const string RecordPause = "action:record-pause";
    public const string NoteCapture = "action:note-capture";
    public const string NoteNew = "action:note-new";
    public const string NoteAll = "action:note-all";
    public const string NoteDeck = "action:note-deck";
    public const string KeepAwake = "action:keep-awake";
    public const string Home = "action:home";
    public const string Settings = "action:settings";
    public const string Shortcuts = "action:shortcuts";
    public const string About = "action:about";
    public const string Update = "action:update";
    public const string Quit = "action:quit";

    /// <summary>新建提醒、新建脚本、复制给 AI 的脚本写法说明（mac 内置动作 reminderNew、scripts-new、scripts-ai-guide，REVIEW R92）。</summary>
    public const string ReminderNew = "action:reminder-new";

    public const string ScriptNew = "action:scripts-new";

    public const string ScriptGuide = "action:scripts-ai-guide";

    /// <summary>状态屏的一个状态：后面接 StatusPreset.Id。</summary>
    public const string StatusPrefix = "statusScreen:";

    public static bool IsStatusPreset(string target) => target.StartsWith(StatusPrefix, StringComparison.Ordinal);

    /// <summary>一个内置动作：标题、英文别名、图标、家族色、对得上的全局快捷动作。</summary>
    private sealed record Definition(
        string Target, string Title, string English, string Glyph, string Family, string? HotKey = null, string[]? Aliases = null);

    /// <summary>按此刻的状态列（暂停没有、复制即译开没开、在不在录、有没有新版本、哪些功能开着）。</summary>
    public static List<LauncherItem> Items()
    {
        var runtime = ShellRuntime.Instance;
        var items = new List<LauncherItem>();
        if (Features.IsOn(Feature.Clipboard))
        {
            items.Add(Item(new(Clipboard, "剪贴板历史", "Clipboard History", FeatureIcons.Clipboard, "clipboard", HotKeyActions.Clipboard)));
            items.Add(Item(
                new(PauseClipboard, "暂停记录剪贴板", "Pause Clipboard", Glyphs.Pause, "clipboard"),
                runtime?.Clipboard?.Paused == true ? "已暂停" : "正在记录"));
        }

        if (Features.IsOn(Feature.Translate))
        {
            items.Add(Item(new(Translate, "输入翻译", "Translate Input", FeatureIcons.TranslateInput, "translate", HotKeyActions.InputTranslate)));
            // 截图翻译归翻译（mac HotKeyAction.feature / color），截图关着照样在（REVIEW R90）
            items.Add(Item(new(ScreenshotTranslate, "截图翻译", "Screenshot Translate", FeatureIcons.TranslateScreenshot, "translate",
                HotKeyActions.ScreenshotTranslate)));
            items.Add(Item(
                new(CopyTranslate, "复制即译", "Copy to Translate", Glyphs.Translate, "translate"),
                SettingsService.Current.CopyTranslate ? "已开启" : "已关闭"));
        }

        // 截图与录制的先后同 mac（截图、截取上次区域、识字、录屏、录音、钉住剪贴板内容、截图历史、钉图两项，REVIEW R90）
        var screenshot = Features.IsOn(Feature.Screenshot);
        if (screenshot)
        {
            items.Add(Item(new(Screenshot, "截图", "Screenshot Capture", FeatureIcons.Screenshot, "capture", HotKeyActions.Screenshot)));
            items.Add(Item(new(ScreenshotLast, "截取上次区域", "Capture Last Region", FeatureIcons.ScreenshotLast, "capture", HotKeyActions.ScreenshotLast)));
            items.Add(Item(new(DelayedScreenshot, "延时截图", "Delayed Screenshot Timer", FeatureIcons.Screenshot, "capture", HotKeyActions.DelayedScreenshot)));
            items.Add(Item(new(Ocr, "识字", "OCR Recognize Text", FeatureIcons.ScreenshotText, "capture", HotKeyActions.Ocr)));
        }

        if (Features.IsOn(Feature.Recording))
        {
            items.Add(Item(new(Record, RecordingHost.IsRecording ? "停止录屏" : "录屏", "Screen Recording Record Video", FeatureIcons.Record,
                "capture", HotKeyActions.Record)));
            items.Add(Item(new(Audio, AudioHost.IsRecording ? "停止录音" : "录音", "Audio Recording Record Voice Microphone",
                FeatureIcons.RecordAudio, "capture", HotKeyActions.Audio)));
            // 暂停 / 继续录制（PLAN-v26 V2）：在录屏或录音时才列
            var paused = RecordingHost.IsRecording ? RecordingHost.IsPaused : AudioHost.IsPaused;
            if (RecordingHost.IsRecording || (AudioHost.IsRecording && !AudioHost.IsArmed))
            {
                items.Add(Item(new(RecordPause, paused ? "继续录制" : "暂停录制", "Pause Resume Recording", FeatureIcons.Record,
                    "capture", HotKeyActions.RecordPause)));
            }
        }

        if (screenshot)
        {
            // 搜「钉图」「贴图」也找得到它（标题是「钉住…」；别家把钉文字叫贴图，mac 同）
            items.Add(Item(new(PinClipboard, "钉住剪贴板内容", "Pin Clipboard Image Text", FeatureIcons.Pin, "capture",
                HotKeyActions.PinClipboard, new[] { "钉图", "贴图" })));
            items.Add(Item(new(ShotHistory, "截图历史", "Screenshot History", FeatureIcons.ScreenshotHistory, "capture", HotKeyActions.ShotHistory)));
            if (PinHost.Count > 0)
            {
                items.Add(Item(new(PinsToggle, PinHost.AllHidden ? "显示全部钉图" : "隐藏全部钉图", "Show Hide All Pins",
                    Glyphs.Pin, "capture")));
                items.Add(Item(new(PinsClose, "关闭全部钉图", "Close All Pins", Glyphs.Pin, "capture")));
            }
        }

        // 便签（PLAN-v13，同 mac 启动器里那三项：名字和托盘、快捷键页同名）。
        if (Features.IsOn(Feature.Notes))
        {
            items.Add(Item(new(NoteCapture, "快速记一条", "Quick Note Capture", FeatureIcons.NotesCapture, "notes", HotKeyActions.NoteCapture)));
            items.Add(Item(new(NoteNew, "新建便签", "New Note Sticky", FeatureIcons.NotesNew, "notes", HotKeyActions.NoteNew)));
            items.Add(Item(new(NoteAll, "全部便签", "All Notes Sticky", FeatureIcons.Notes, "notes", HotKeyActions.NoteAll)));
            items.Add(Item(new(NoteDeck, "屏幕边缘的便签", "Notes Edge Deck Sticky", FeatureIcons.Notes, "notes", HotKeyActions.NoteDeck)));
        }

        // 提醒（mac 内置动作 reminderNew，排在状态屏前面）：同它的快捷键，打开启动器填好「提醒 」（REVIEW R92）
        if (Features.IsOn(Feature.Reminders))
        {
            items.Add(Item(new(ReminderNew, "新建提醒", "New Reminder Alarm Timer", FeatureIcons.Reminders, "reminders", HotKeyActions.ReminderNew)));
        }

        if (Features.IsOn(Feature.StatusScreen))
        {
            // 设置里开了「直接进入」时，第一个状态右边写状态屏的快捷键（按它进的就是这个）。
            var entersFirst = SettingsService.Current.StatusScreenHotKeyEntersFirst;
            var presets = StatusScreenHost.Presets;
            var family = Pinyin.For("状态屏");
            for (var index = 0; index < presets.Count; index++)
            {
                var item = Item(
                    new(StatusPrefix + presets[index].Id, presets[index].Title, "Status Screen", FeatureIcons.StatusScreen, "statusScreen",
                        entersFirst && index == 0 ? HotKeyActions.StatusScreen : null),
                    priority: 1);
                item.Names.Add(LauncherMatch.Fold("状态屏"));
                if (family is { } spelled)
                {
                    item.Names.Add(spelled.Full);
                    item.Initials.Add(spelled.Initials);
                }

                var symbol = presets[index].Symbol;
                items.Add(item with { Note = "状态屏", Emoji = symbol.Length > 0 ? symbol : null });
            }
        }

        // 保持唤醒（插件，PLAN-v20 K1）：只打关键词时是这一行（按一下开无限期、开着时停）；「awake 2小时」这类走 KeepAwakeLauncher
        if (Features.IsOn(Feature.KeepAwake))
        {
            items.Add(Item(new(KeepAwake, KeepAwakeHost.HasSession ? "停止保持唤醒" : "保持唤醒", "Keep Awake caffeinate", FeatureIcons.KeepAwake,
                    "keepAwake", HotKeyActions.KeepAwake, new[] { "awake", "防息屏", "防止睡眠", "不睡眠" }),
                KeepAwakeHost.IsActive ? "保持唤醒中 · " + KeepAwakeHost.Status() : "Kitty Tools"));
        }

        // 脚本命令的两条（mac LauncherItem.scriptActions）：脚本命令关着时不列
        if (Features.IsOn(Feature.Launcher) && SettingsService.Current.LauncherScripts)
        {
            items.Add(Item(new(ScriptNew, "新建脚本", "New Script Command 脚本命令", Glyphs.Add, "launcher")));
            items.Add(Item(new(ScriptGuide, "复制脚本写法说明（给 AI）", "Copy Script Guide AI 脚本写法 提示词", Glyphs.Copy, "launcher")));
        }

        items.Add(Item(new(Home, "打开主界面", "Home Panel All Features", FeatureIcons.Home, "general", HotKeyActions.Home)));
        items.Add(Item(new(Settings, "设置", "Settings Preferences", Glyphs.Settings, "general")));
        items.Add(Item(new(Shortcuts, "快捷键速查表", "Keyboard Shortcuts", Glyphs.Keyboard, "shortcut")));
        items.Add(Item(new(About, "关于 Kitty Tools", "About Kitty Tools", Glyphs.Info, "general")));
        items.Add(Item(new(Update,
            UpdateService.OfferedVersion is { } available ? $"更新到 {available}" : "检查更新",
            "Check for Updates", Glyphs.Update, "general")));
        items.Add(Item(new(Quit, "退出 Kitty Tools", "Quit Kitty Tools", Glyphs.Close, "general"), priority: 1));
        return items;
    }

    /// <summary>收藏、常用按 id 还原；关着的功能的动作还原不出来，收藏只是藏起来、不删（打开功能就回来，同 mac）。</summary>
    public static LauncherItem? Find(string target) => Items().FirstOrDefault(item => item.Target == target);

    /// <summary>行里色块的家族色（mac：跟着菜单里所在那一节）。</summary>
    public static string FamilyOf(string target) => target switch
    {
        Clipboard or PauseClipboard => "clipboard",
        Translate or CopyTranslate => "translate",
        Screenshot or ScreenshotTranslate or ScreenshotLast or Ocr or ShotHistory or PinClipboard or PinsToggle or PinsClose
            or Record or Audio => "capture",
        Shortcuts => "shortcut",
        NoteCapture or NoteNew or NoteAll or NoteDeck => "notes",
        ReminderNew => "reminders",
        ScriptNew or ScriptGuide => "launcher",
        KeepAwake => "keepAwake",
        _ when KeepAwakeLauncher.IsKeepAwake(target) => "keepAwake",
        _ when target.StartsWith(PluginOffers.Prefix, StringComparison.Ordinal) => "keepAwake",
        _ when IsStatusPreset(target) => "statusScreen",
        _ when ReminderLauncher.IsReminder(target) => "reminders",
        _ => "general",
    };

    /// <summary>
    /// 行里色块的符号。对得上全局快捷动作的用和 mac 共用的功能图标（同快捷键页，mac HotKeyAction.symbol）；
    /// 其余（暂停记录、复制即译、钉图开关、设置、速查表、关于、更新、退出）照旧是 Segoe 字形（mac 也是系统符号）。
    /// </summary>
    public static string GlyphOf(string target) => target switch
    {
        Clipboard => FeatureIcons.Clipboard,
        PauseClipboard => Glyphs.Pause,
        Translate => FeatureIcons.TranslateInput,
        CopyTranslate => Glyphs.Translate,
        Screenshot => FeatureIcons.Screenshot,
        ScreenshotLast => FeatureIcons.ScreenshotLast,
        ScreenshotTranslate => FeatureIcons.TranslateScreenshot,
        Ocr => FeatureIcons.ScreenshotText,
        ShotHistory => FeatureIcons.ScreenshotHistory,
        PinClipboard => FeatureIcons.Pin,
        PinsToggle or PinsClose => Glyphs.Pin,
        Record => FeatureIcons.Record,
        Audio => FeatureIcons.RecordAudio,
        Shortcuts => Glyphs.Keyboard,
        Home => FeatureIcons.Home,
        NoteCapture => FeatureIcons.NotesCapture,
        NoteNew => FeatureIcons.NotesNew,
        NoteAll or NoteDeck => FeatureIcons.Notes,
        KeepAwake => FeatureIcons.KeepAwake,
        _ when KeepAwakeLauncher.IsKeepAwake(target) => FeatureIcons.KeepAwake,
        _ when target.StartsWith(PluginOffers.Prefix, StringComparison.Ordinal) => FeatureIcons.KeepAwake,
        About => Glyphs.Info,
        Update => Glyphs.Update,
        Quit => Glyphs.Close,
        _ when IsStatusPreset(target) => FeatureIcons.StatusScreen,
        _ when ReminderLauncher.IsReminder(target) => FeatureIcons.Reminders,
        _ => Glyphs.Settings,
    };

    /// <summary>执行（启动器已经收起）。截图、录屏这类要拍屏幕的晚 200 ms 开始，免得拍到正在淡出的启动器。</summary>
    public static void Execute(string target)
    {
        var runtime = ShellRuntime.Instance;
        switch (target)
        {
            case Clipboard:
                OverlayHost.Show(OverlayKind.Clipboard);
                break;
            case PauseClipboard:
                runtime?.TogglePauseClipboard();
                break;
            case Translate:
                TranslateHost.ShowInput();
                break;
            case CopyTranslate:
                runtime?.ToggleCopyTranslate();
                break;
            case Screenshot:
                StartLater(() => ScreenshotSession.Start(ScreenshotMode.Capture));
                break;
            case ScreenshotTranslate:
                StartLater(() => ScreenshotSession.Start(ScreenshotMode.Translate));
                break;
            case ScreenshotLast:
                StartLater(ScreenshotSession.StartLast);
                break;
            case DelayedScreenshot:
                DelayedShot.Toggle();
                break;
            case Ocr:
                StartLater(() => ScreenshotSession.Start(ScreenshotMode.Ocr));
                break;
            case ShotHistory:
                ShotHistoryWindow.ShowWindow();
                break;
            case PinClipboard:
                _ = PinHost.PinClipboardAsync();
                break;
            case PinsToggle:
                PinHost.ToggleHidden();
                break;
            case PinsClose:
                PinHost.CloseAll();
                break;
            case Record:
                StartLater(RecordingHost.Toggle);
                break;
            case Audio:
                AudioHost.Toggle();
                break;
            case RecordPause:
                RecordingHost.TogglePauseAny();
                break;
            case Home:
                HomePanel.ShowAtCursor();
                break;
            case NoteCapture:
                NoteCaptureWindow.Toggle();
                break;
            case NoteNew:
                NotesHost.NewNote();
                break;
            case NoteDeck:
                // 先收起启动器、把前台还回去，再叫出那一列（它要拿键盘）
                StartLater(KittyTools.NoteDeck.Summon);
                break;
            case NoteAll:
                NotesWindow.ShowWindow();
                break;
            case KeepAwake:
                KeepAwakeHost.Toggle();
                break;
            case ReminderNew:
                runtime?.NewReminder();
                break;
            case ScriptNew:
                runtime?.NewScript();
                break;
            case ScriptGuide:
                Paster.WriteText(ScriptTemplates.AIGuide);
                NoticeHost.Show("已复制脚本写法说明", "贴给你常用的 AI，在最后一段写上想做什么", NoticeTone.Normal);
                break;
            case Settings:
                runtime?.ShowSettings(welcome: false);
                break;
            case Shortcuts:
                runtime?.ShowShortcutsSheet();
                break;
            case About:
                runtime?.ShowSettings(welcome: false, "about");
                break;
            case Update:
                if (UpdateService.OfferedVersion is not null)
                {
                    if (!AutoUpdater.IsBusy)
                    {
                        _ = AutoUpdater.StartAsync();
                    }
                }
                else
                {
                    _ = UpdateService.CheckAsync(userInitiated: true);
                }

                break;
            case Quit:
                runtime?.Exit(installUpdate: true);
                break;
            default:
                if (IsStatusPreset(target))
                {
                    // 启动器先收起、键盘还回去，再盖上来。
                    StartLater(() => StatusScreenHost.Enter(target[StatusPrefix.Length..]));
                }

                break;
        }
    }

    /// <summary>
    /// 启动器先收起再开截图 / 录屏：同一拍里开的话，冻结帧和录制的第一帧会拍到启动器自己
    /// （以前这三项一直是「第 5 批接上」的占位，PLAN-v8 顺手接上）。
    /// </summary>
    private static async void StartLater(Action start)
    {
        await Task.Delay(200);
        start();
    }

    private static LauncherItem Item(Definition definition, string subtitle = "Kitty Tools", int priority = 0)
    {
        var pinyin = Pinyin.For(definition.Title);
        return new LauncherItem
        {
            Kind = LauncherKind.Action,
            Target = definition.Target,
            Title = definition.Title,
            Subtitle = subtitle,
            Names = new[]
            {
                LauncherMatch.Fold(definition.Title),
                LauncherMatch.Fold(definition.English),
                pinyin?.Full,
            }.Concat((definition.Aliases ?? System.Array.Empty<string>())
                    .SelectMany(alias => new[] { LauncherMatch.Fold(alias), Pinyin.For(alias)?.Full }))
            .Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).Distinct().ToList(),
            Initials = new[]
            {
                LauncherMatch.Initials(definition.English),
                pinyin?.Initials,
            }.Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
            Priority = priority,
            HotKeyAction = definition.HotKey,
        };
    }
}
