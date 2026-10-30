// 启动器里本 App 自己的动作（PLAN-v9-launcher R12 = PLAN-v9 L8，照 mac LauncherItem.actions）：和托盘菜单同名同序——
// 剪贴板历史、暂停记录剪贴板（副标题写正在记录 / 已暂停）｜输入翻译、复制即译（已开启 / 已关闭）｜截图、截图翻译、截取上次区域、
// 识字、截图历史、钉住剪贴板里的图、隐藏 / 显示全部钉图和关闭全部钉图（有钉图时，PLAN-v9 S10）、录屏、录音｜打开主界面（PLAN-v10 §5）、设置、快捷键速查表、
// 关于 Kitty Tools、检查更新（有新版本时「更新到 x」）、退出 Kitty Tools。
// 关着的功能那一节不列（Feature）；启动器自己、划词翻译不列（点了启动器，原来的程序就不在前台了，取不到选中的字，同托盘 G1）。
// 副标题只写「Kitty Tools」，英文名和拼音只进匹配；对得上全局快捷动作的，选中时右边显示它的键帽。
// 退出排在最后（同系统命令），避免回车误退；退出不记使用。老的 9 个 id 不改（使用记录按 id 累计）。
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
    public const string Ocr = "action:ocr";
    public const string ShotHistory = "action:shot-history";
    public const string PinClipboard = "action:pin-clipboard";
    public const string PinsToggle = "action:pins-toggle";
    public const string PinsClose = "action:pins-close";
    public const string Record = "action:record";
    public const string Audio = "action:audio";
    public const string Home = "action:home";
    public const string Settings = "action:settings";
    public const string Shortcuts = "action:shortcuts";
    public const string About = "action:about";
    public const string Update = "action:update";
    public const string Quit = "action:quit";

    /// <summary>一个内置动作：标题、英文别名、图标、家族色、对得上的全局快捷动作。</summary>
    private sealed record Definition(string Target, string Title, string English, string Glyph, string Family, string? HotKey = null);

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
            items.Add(Item(
                new(CopyTranslate, "复制即译", "Copy to Translate", Glyphs.Translate, "translate"),
                SettingsService.Current.CopyTranslate ? "已开启" : "已关闭"));
        }

        if (Features.IsOn(Feature.Screenshot))
        {
            items.Add(Item(new(Screenshot, "截图", "Screenshot Capture", FeatureIcons.Screenshot, "capture", HotKeyActions.Screenshot)));
            if (Features.IsOn(Feature.Translate))
            {
                items.Add(Item(new(ScreenshotTranslate, "截图翻译", "Screenshot Translate", FeatureIcons.TranslateScreenshot, "capture",
                    HotKeyActions.ScreenshotTranslate)));
            }

            items.Add(Item(new(ScreenshotLast, "截取上次区域", "Capture Last Region", FeatureIcons.ScreenshotLast, "capture", HotKeyActions.ScreenshotLast)));
            items.Add(Item(new(Ocr, "识字", "OCR Recognize Text", FeatureIcons.ScreenshotText, "capture", HotKeyActions.Ocr)));
            items.Add(Item(new(ShotHistory, "截图历史", "Screenshot History", FeatureIcons.ScreenshotHistory, "capture", HotKeyActions.ShotHistory)));
            items.Add(Item(new(PinClipboard, "钉住剪贴板里的图", "Pin Clipboard Image", FeatureIcons.Pin, "capture",
                HotKeyActions.PinClipboard)));
            if (PinHost.Count > 0)
            {
                items.Add(Item(new(PinsToggle, PinHost.AllHidden ? "显示全部钉图" : "隐藏全部钉图", "Show Hide All Pins",
                    Glyphs.Pin, "capture")));
                items.Add(Item(new(PinsClose, "关闭全部钉图", "Close All Pins", Glyphs.Pin, "capture")));
            }
        }

        if (Features.IsOn(Feature.Recording))
        {
            items.Add(Item(new(Record, RecordingHost.IsRecording ? "停止录屏" : "录屏", "Screen Recording Record Video", FeatureIcons.Record,
                "capture", HotKeyActions.Record)));
            items.Add(Item(new(Audio, AudioHost.IsRecording ? "停止录音" : "录音", "Audio Recording Record Voice Microphone",
                FeatureIcons.RecordAudio, "capture", HotKeyActions.Audio)));
        }

        items.Add(Item(new(Home, "打开主界面", "Home Panel All Features", FeatureIcons.Home, "general", HotKeyActions.Home)));
        items.Add(Item(new(Settings, "设置", "Settings Preferences", Glyphs.Settings, "general")));
        items.Add(Item(new(Shortcuts, "快捷键速查表", "Keyboard Shortcuts", Glyphs.Keyboard, "shortcut")));
        items.Add(Item(new(About, "关于 Kitty Tools", "About Kitty Tools", Glyphs.Info, "general")));
        items.Add(Item(new(Update,
            UpdateService.AvailableVersion is { } available ? $"更新到 {available}" : "检查更新",
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
        About => Glyphs.Info,
        Update => Glyphs.Update,
        Quit => Glyphs.Close,
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
            case Home:
                HomePanel.ShowAtCursor();
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
                if (UpdateService.AvailableVersion is not null)
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
                runtime?.Exit();
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
            }.Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).Distinct().ToList(),
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
