// 设置同步的对照表（PLAN-v21 §1、第 1 批）：哪些设置跟着同步、记录编号是什么、Windows 的值和记录里的值怎么互换。
// - Shared（A、B 组）：和 mac 互认，编号 "pref:<mac 偏好键>"，值是 mac 那边的写法（mac Prefs.defaults 里那个键的类型和取值）；
//   走 settings 一类（等文件夹里有了 Mac 的那份才写，PLAN-v21 D3），在那之前也在 windows-settings 里走。
// - Windows 独有（C 组）：编号 "pref:<Windows 设置名>"、全局快捷键 "hotkey:<动作>"、截图工具栏的键 "shotkey:<键>"，只走 windows-settings。
// - 不在表里的（D 组 mac 独有、E 组留在本机）不同步；mac 的那几项在 settings 一类里原样透传（SettingsSync）。
// 收的时候先过 mac 收设置的那道检查（SettingsArchive.Kind.plist：整数 0…100 万、文字 4096 字、一组文字 1000 条每条 512 字），
// 再过 Windows 自己的取值（选项只认认得的那几个）；落不下的不落、进透传。发的时候也核一遍：对面落不下的不发（同 mac）。
// Field 是 App 那边绑定用的名字（AppSettings 的属性名；功能开关 "feature.<名>"；快捷键 "hotkey.<动作>"、"shotkey.<键>"），
// App/Storage/SettingsSyncFields.cs 一项一项接上读写。
namespace KittyTools.Core.Sync;

public sealed class SettingKey
{
    private readonly Func<SettingValue, SettingValue?> _outgoing;
    private readonly Func<SettingValue, SettingValue?> _incoming;

    internal SettingKey(string id, string field, SettingType type, bool shared,
        Func<SettingValue, SettingValue?> outgoing, Func<SettingValue, SettingValue?> incoming)
    {
        Id = id;
        Field = field;
        Type = type;
        Shared = shared;
        _outgoing = outgoing;
        _incoming = incoming;
    }

    /// <summary>同步记录的编号。</summary>
    public string Id { get; }

    /// <summary>App 那边的名字。</summary>
    public string Field { get; }

    /// <summary>Windows 这边的值的类型（App 读出来、写进去的就是这种）。</summary>
    public SettingType Type { get; }

    /// <summary>和 mac 互认（A、B 组）。</summary>
    public bool Shared { get; }

    /// <summary>本机的值 → 记录里的那一段；对面落不下的（超出 mac 的范围）给 null，不发。</summary>
    public string? Outgoing(SettingValue local)
        => local.Type == Type && _outgoing(local) is { } wire && SettingsSyncMap.FitsMac(wire) &&
           // mac 偏好里的文字（.string）只收 4096 字
           !(Shared && wire.Type == SettingType.Text && wire.Text.Length > SettingsSyncMap.MaxString)
            ? wire.Encode()
            : null;

    /// <summary>记录里的那一段 → 本机的值；解不开、不是这一版认得的写法、落不下的给 null（进透传）。</summary>
    public SettingValue? Incoming(string text)
        => SettingValue.Decode(text) is { } wire && SettingsSyncMap.FitsMac(wire) && _incoming(wire) is { } local &&
           local.Type == Type
            ? local
            : null;
}

public static class SettingsSyncMap
{
    public const string PrefPrefix = "pref:";
    public const string HotKeyPrefix = "hotkey:";
    public const string ShotKeyPrefix = "shotkey:";

    /// <summary>mac 收设置时的范围（SettingsArchive.Kind.plist）。</summary>
    public const long MaxInt = 1_000_000;
    public const int MaxString = 4096;
    public const int MaxText = 65_536;
    public const int MaxListCount = 1000;
    public const int MaxListItem = 512;

    private static readonly string[] Positions = { "top", "mouse", "last" };

    /// <summary>A、B 组：和 mac 互认。</summary>
    public static IReadOnlyList<SettingKey> Shared { get; } = BuildShared();

    /// <summary>C 组的设置（快捷键另算，见 HotKey / ShotKey）。</summary>
    public static IReadOnlyList<SettingKey> WindowsOnly { get; } = BuildWindowsOnly();

    private static readonly Dictionary<string, SettingKey> SharedById = Shared.ToDictionary(key => key.Id, StringComparer.Ordinal);
    private static readonly Dictionary<string, SettingKey> WindowsById = WindowsOnly.ToDictionary(key => key.Id, StringComparer.Ordinal);

    public static SettingKey? FindShared(string id) => SharedById.GetValueOrDefault(id);

    public static SettingKey? FindWindows(string id) => WindowsById.GetValueOrDefault(id);

    /// <summary>mac 收设置的那道检查（SettingsArchive.Kind.plist；.text 那种放宽到 64 KB 的这里统一按 64 KB 算，
    /// 4096 字那道在各个键自己的 Windows 取值里）。</summary>
    public static bool FitsMac(SettingValue value) => value.Type switch
    {
        SettingType.Int => value.Number is >= 0 and <= MaxInt,
        SettingType.Double => double.IsFinite(value.Real),
        SettingType.Text => value.Text.Length <= MaxText,
        SettingType.Texts => value.Texts.Count <= MaxListCount && value.Texts.All(item => item.Length <= MaxListItem),
        SettingType.Map => value.Map.Count <= MaxListCount && value.Map.All(pair => pair.Key.Length <= MaxListItem && pair.Value.Length <= MaxString),
        _ => true,
    };

    /// <summary>全局快捷键的那一条（windows-settings）：值是「Alt+C」这种写法（HotKeyRules.Format），清除了的是空字符串。
    /// 收的时候能不能当全局热键用由 App 判断（HotKeyRules），这里只管形状。</summary>
    public static SettingKey HotKey(string action)
        => new(HotKeyPrefix + action, "hotkey." + action, SettingType.Text, false, Same, ShortText);

    /// <summary>截图工具栏的一个键（windows-settings）：同上，ShotKeys 的写法。</summary>
    public static SettingKey ShotKey(string key)
        => new(ShotKeyPrefix + key, "shotkey." + key, SettingType.Text, false, Same, ShortText);

    private static List<SettingKey> BuildShared()
    {
        var keys = new List<SettingKey>();

        void Flag(string mac, string field) => keys.Add(new(PrefPrefix + mac, field, SettingType.Bool, true, Same, Same));

        void Number(string mac, string field) => keys.Add(new(PrefPrefix + mac, field, SettingType.Int, true, Same, Same));

        void Choice(string mac, string field, params string[] values)
            => keys.Add(new(PrefPrefix + mac, field, SettingType.Text, true, Same, value => values.Contains(value.Text) ? value : null));

        // 外观
        Choice("appearance", "Theme", "system", "light", "dark");
        // 强调色：同一套调色板（AccentPalette = mac AccentChoice）；Windows 旧的默认值 brand 就是品牌粉
        keys.Add(new(PrefPrefix + "accent", "Accent", SettingType.Text, true,
            value => value.Text == "brand" ? SettingValue.Of("pink") : value,
            value => value.Text is "system" or "blue" or "purple" or "pink" or "red" or "orange" or "yellow" or "green" or "graphite"
                ? value
                : null));
        Flag("updateAutoCheck", "AutoCheckUpdates");
        Flag("panelSqueezeEntrance", "PanelSqueezeEntrance");

        // 剪贴板
        Number("clipboardHistoryRetentionDays", "ClipboardRetentionDays");
        Number("clipboardImageCacheMaxMb", "ClipboardImageBudgetMB");
        Flag("clipboardBlockSensitive", "ClipboardBlockSensitive");
        Flag("clipboardPastePlainByDefault", "ClipboardPastePlain");
        Flag("clipboardImageOcr", "ClipboardImageOcr");
        Flag("clipboardClearOnExit", "ClipboardClearOnQuit");
        Flag("clipboardClearOnLock", "ClipboardClearOnLock");
        Flag("clipboardShowPreview", "ClipboardShowLens");
        Flag("clipboardLinkPreview", "LinkPreviews");
        Flag("clipboardPasteOnClick", "ClipboardPasteOnClick");
        Choice("clipboardPanelPosition", "ClipboardPanelPosition", Positions);

        // 启动器
        Choice("launcherPanelPosition", "LauncherPanelPosition", Positions);
        Flag("launcherShowsFrequent", "LauncherShowsFrequent");
        Flag("launcherFallbackAlways", "LauncherFallbackAlways");
        Flag("launcherRomanInput", "LauncherRomanInput");
        Flag("launcherScripts", "LauncherScripts");

        // 翻译
        Language("translateNativeLang", "TranslateFirstLanguage", keys);
        Language("translateForeignLang", "TranslateSecondLanguage", keys);
        // 浮窗顶上选的源 / 目标语言：mac 没注册默认值，存过才有；不认识的代码两边都当「自动」，照文字收
        keys.Add(new(PrefPrefix + "translateSourceLang", "TranslateSource", SettingType.Text, true, Same, ShortText));
        keys.Add(new(PrefPrefix + "translateTargetLang", "TranslateTarget", SettingType.Text, true, Same, ShortText));
        Flag("translateDeleteNewline", "TranslateJoinLines");
        Flag("autoCopy", "TranslateAutoCopy");
        Flag("translateCopyRecognized", "TranslateCopyRecognized");
        Flag("translateScreenshotOverlay", "TranslateScreenshotOverlay");
        Flag("translateHistoryEnabled", "TranslateHistoryEnabled");
        Number("translateHistoryLimit", "TranslateHistoryLimit");
        Choice("translatePanelPosition", "TranslateWindowPosition", Positions);
        Flag("translateClipboardMonitor", "CopyTranslate");
        Flag("translateWordMode", "TranslateWordLookup");
        Flag("translateWordRecording", "TranslateWordRecording");
        Choice("translateWordAccent", "TranslateWordAccent", "us", "uk");
        keys.Add(new(PrefPrefix + "translateFontScale", "TranslateFontScale", SettingType.Double, true, Same,
            value => value.Real is >= 0.5 and <= 3 ? SettingValue.Of(value.Real) : null));
        // 折起来的服务卡：mac 是换行隔开的一段文字，Windows 是一组服务 id
        keys.Add(new(PrefPrefix + "translateCollapsedServices", "TranslateCollapsedServices", SettingType.Texts, true,
            value => value.Texts.Any(id => id.Contains('\n')) ? null : SettingValue.Of(string.Join('\n', value.Texts)),
            value => value.Text.Length <= MaxString
                ? SettingValue.Of(value.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                : null));
        Flag("ocrJoinLines", "OcrJoinLines");

        // 截图
        Flag("screenshotShutterSound", "ScreenshotShutterSound");
        // 截完放哪：Windows 的「卡片」就是 mac 的「角落的缩略图」；晾衣绳 Windows 没有，落不下
        keys.Add(new(PrefPrefix + "screenshotPlacement", "ShotPlacement", SettingType.Text, true,
            value => value.Text switch { "card" => SettingValue.Of("corner"), "none" => value, _ => null },
            value => value.Text switch { "corner" => SettingValue.Of("card"), "none" => value, _ => null }));
        Choice("screenshotToolbarAlign", "ScreenshotToolbarAlign", "right", "center");
        Choice("screenshotCopyAs", "ScreenshotCopyAs", "image", "file");
        Choice("scrollCaptureSpeed", "ScrollCaptureSpeed", "slow", "normal", "fast");
        Flag("screenshotKeepsColors", "ScreenshotKeepsColors");
        Flag("screenshotFindsElements", "ScreenshotFindsElements");
        Flag("shotHistory", "ShotHistory");
        Number("shotHistoryDays", "ShotHistoryDays");
        Number("shotHistoryMegabytes", "ShotHistoryMegabytes");

        // 录制（要不要录麦克风、录音的来源、显示按键跟着这台电脑的授权走，留在本机，同 mac localKeys）
        Number("screenRecordFrameRate", "RecordFps");
        Number("screenRecordCountdown", "RecordCountdown");
        Flag("screenRecordShowsCursor", "RecordCursor");
        Choice("screenRecordSharpness", "RecordSharpness", "original", "standard");
        Flag("screenRecordKeysShortcutsOnly", "RecordKeysShortcutsOnly");
        Flag("screenRecordSystemAudio", "RecordSystemSound");
        Flag("screenRecordShowsClicks", "RecordClicks");
        Flag("audioRecordStartsImmediately", "RecordInstantStart");

        // 状态屏、提醒
        Flag("statusScreenExitHint", "StatusScreenExitHint");
        Flag("statusScreenHotKeyEntersFirst", "StatusScreenHotKeyEntersFirst");
        Flag("statusScreenAnimations", "StatusScreenAnimations");
        Number("remindersSnoozeMinutes", "RemindersSnoozeMinutes");

        // 便签（放在哪块屏幕留在本机）
        Number("notesFontSize", "NotesFontSize");
        Flag("notesMarkdown", "NotesMarkdown");
        Choice("notesLineSpacing", "NotesLineSpacing", "compact", "standard", "relaxed");
        Flag("notesDeckEnabled", "NotesDeckEnabled");
        Choice("notesDeckEdge", "NotesDeckEdge", "left", "right");
        Choice("notesDeckStyle", "NotesDeckStyle", "tabs", "chips");
        Choice("notesDeckSize", "NotesDeckSize", "small", "standard", "large");
        Number("notesDeckSense", "NotesDeckSense");
        Flag("notesDeckAlwaysFanned", "NotesDeckAlwaysFanned");
        Flag("notesDeckHidesPill", "NotesDeckHidesPill");
        Flag("notesDeckPreview", "NotesDeckPreview");
        Flag("notesDeckOpensOnHover", "NotesDeckOpensOnHover");
        Flag("notesDeckOverFullScreen", "NotesDeckOverFullScreen");
        Choice("notesDeckNoteSize", "NotesDeckNoteSize", "small", "medium", "large", "extraLarge");

        // 功能开关：mac 的键 → Windows Features 里的键（录制 mac 叫 record）。截图在 Windows 上不能关、没有这个开关，和启动台、
        // 程序坞预览、访达右键、刘海岛一样透传；保持唤醒 mac 0.9.0 拿掉了，归 C 组
        foreach (var (mac, windows) in new[]
                 {
                     ("clipboard", "clipboard"), ("launcher", "launcher"), ("translate", "translate"), ("record", "recording"),
                     ("notes", "notes"), ("reminders", "reminders"), ("statusScreen", "statusScreen"),
                 })
        {
            keys.Add(new(PrefPrefix + "feature." + mac, "feature." + windows, SettingType.Bool, true, Same, Same));
        }

        return keys;
    }

    private static List<SettingKey> BuildWindowsOnly()
    {
        var keys = new List<SettingKey>();

        void Flag(string field) => keys.Add(new(PrefPrefix + field, field, SettingType.Bool, false, Same, Same));

        void List(string field) => keys.Add(new(PrefPrefix + field, field, SettingType.Texts, false, Same, Same));

        void Table(string field) => keys.Add(new(PrefPrefix + field, field, SettingType.Map, false, Same, Same));

        List("ClipboardExcludedApps");
        List("HotKeyBlockedApps");
        Flag("HotKeyBlockFullscreen");
        Table("LauncherCommandAliases");
        List("LauncherCommandsOff");
        Table("LauncherCommandHotKeys");
        Table("LauncherAppAliases");
        Flag("LauncherRecentPrograms");
        List("LauncherBookmarkBrowsers");
        List("LauncherHistoryBrowsers");
        Flag("ScreenshotCursor");
        Flag("CaptureHideDesktopIcons");
        Flag("UpdateInstallOnQuit");
        // 保持唤醒：开关和「屏幕也不熄」同步，定时每台的作息不一样、不同步（PLAN-v20 D3）
        Flag("KeepAwakeDisplay");
        keys.Add(new(PrefPrefix + "feature.keepAwake", "feature.keepAwake", SettingType.Bool, false, Same, Same));
        return keys;
    }

    private static void Language(string mac, string field, List<SettingKey> keys)
        => keys.Add(new(PrefPrefix + mac, field, SettingType.Text, true, Same,
            value => Langs.FromCode(value.Text) is not null ? value : null));

    private static SettingValue? Same(SettingValue value) => value;

    private static SettingValue? ShortText(SettingValue value) => value.Text.Length <= MaxString ? value : null;
}
