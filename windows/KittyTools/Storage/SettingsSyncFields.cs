// 设置同步的读写（PLAN-v21 第 2 批）：Core 的对照表（SettingsSyncMap）里每一项在 Settings 上怎么读、怎么写。
// 读出来的是 Windows 这边的值（换算在 Core）；写 null = 回到本机默认（新装时的那个值，Defaults）。
// 功能开关存在 Features 表里（没存过 = 本机默认）；全局快捷键存在 HotKeys 里（「Alt+C」这种写法，没设 = 空字符串）；
// 截图工具栏的键存在 ScreenshotKeys 里（没存过 = 默认，空字符串 = 清除了，同 ShotKeys）。
// 对照表里有、这里没接上的会被 Missing 列出来（--sync-settings-probe 和 Debug 启动时查）。
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class SettingsSyncFields
{
    private sealed record Field(Func<Settings, SettingValue?> Get, Action<Settings, SettingValue?> Set);

    private static readonly Dictionary<string, Field> Fields = Build();

    /// <summary>新装时的设置（默认值从这里读）。</summary>
    private static readonly Settings Defaults = CreateDefaults();

    /// <summary>windows-settings 里的全部：Shared + WindowsOnly + 每个全局快捷键 + 截图工具栏的每个键。</summary>
    public static IReadOnlyList<SettingKey> WindowsKeys { get; } = SettingsSyncMap.Shared
        .Concat(SettingsSyncMap.WindowsOnly)
        .Concat(SettingsDefaults.DefaultHotKeys.Select(entry => SettingsSyncMap.HotKey(entry.Action)))
        .Concat(ShotKeys.All.Select(entry => SettingsSyncMap.ShotKey(entry.Id)))
        .ToList();

    private static readonly Dictionary<string, SettingKey> WindowsById = WindowsKeys.ToDictionary(key => key.Id, StringComparer.Ordinal);

    public static SettingKey? FindWindows(string id) => WindowsById.GetValueOrDefault(id);

    /// <summary>对照表里有、没接上读写的（应当是空的）。</summary>
    public static IEnumerable<string> Missing => WindowsKeys.Where(key => !Fields.ContainsKey(key.Field)).Select(key => key.Field);

    public static SettingValue? Read(Settings settings, SettingKey key)
        => Fields.TryGetValue(key.Field, out var field) ? field.Get(settings) : null;

    public static SettingValue? Default(SettingKey key) => Read(Defaults, key);

    /// <summary>写一项；null = 回到本机默认。</summary>
    public static void Write(Settings settings, SettingKey key, SettingValue? value)
    {
        if (Fields.TryGetValue(key.Field, out var field))
        {
            field.Set(settings, value);
        }
    }

    private static Settings CreateDefaults()
    {
        var settings = new Settings();
        SettingsDefaults.Apply(settings);
        return settings;
    }

    private static Dictionary<string, Field> Build()
    {
        var fields = new Dictionary<string, Field>(StringComparer.Ordinal);

        void Flag(string name, Func<Settings, bool> get, Action<Settings, bool> set)
            => fields[name] = new(settings => SettingValue.Of(get(settings)),
                (settings, value) => set(settings, value?.Flag ?? get(Defaults)));

        void Number(string name, Func<Settings, int> get, Action<Settings, int> set)
            => fields[name] = new(settings => SettingValue.Of(get(settings)),
                (settings, value) => set(settings, value is null ? get(Defaults) : (int)value.Number));

        void Text(string name, Func<Settings, string?> get, Action<Settings, string?> set)
            => fields[name] = new(settings => get(settings) is { } text ? SettingValue.Of(text) : null,
                (settings, value) => set(settings, value is null ? get(Defaults) : value.Text));

        void List(string name, Func<Settings, List<string>?> get, Action<Settings, List<string>?> set)
            => fields[name] = new(settings => get(settings) is { } list ? SettingValue.Of(list) : null,
                (settings, value) => set(settings, value is null ? get(Defaults)?.ToList() : value.Texts.ToList()));

        void Table(string name, Func<Settings, Dictionary<string, string>?> get, Action<Settings, Dictionary<string, string>?> set)
            => fields[name] = new(settings => get(settings) is { } map ? SettingValue.Of(map) : null,
                (settings, value) => set(settings, value is null
                    ? get(Defaults) is { } fallback ? new Dictionary<string, string>(fallback) : null
                    : new Dictionary<string, string>(value.Map)));

        // 外观、通用
        Text("Theme", s => s.Theme, (s, v) => s.Theme = v ?? "system");
        Text("Accent", s => s.Accent, (s, v) => s.Accent = v ?? "brand");
        Flag("AutoCheckUpdates", s => s.AutoCheckUpdates, (s, v) => s.AutoCheckUpdates = v);
        Flag("PanelSqueezeEntrance", s => s.PanelSqueezeEntrance, (s, v) => s.PanelSqueezeEntrance = v);
        Flag("UpdateInstallOnQuit", s => s.UpdateInstallOnQuit, (s, v) => s.UpdateInstallOnQuit = v);

        // 剪贴板
        Number("ClipboardRetentionDays", s => s.ClipboardRetentionDays, (s, v) => s.ClipboardRetentionDays = v);
        Number("ClipboardImageBudgetMB", s => s.ClipboardImageBudgetMB, (s, v) => s.ClipboardImageBudgetMB = v);
        Flag("ClipboardBlockSensitive", s => s.ClipboardBlockSensitive, (s, v) => s.ClipboardBlockSensitive = v);
        Flag("ClipboardPastePlain", s => s.ClipboardPastePlain, (s, v) => s.ClipboardPastePlain = v);
        Flag("ClipboardImageOcr", s => s.ClipboardImageOcr, (s, v) => s.ClipboardImageOcr = v);
        Flag("ClipboardClearOnQuit", s => s.ClipboardClearOnQuit, (s, v) => s.ClipboardClearOnQuit = v);
        Flag("ClipboardClearOnLock", s => s.ClipboardClearOnLock, (s, v) => s.ClipboardClearOnLock = v);
        Flag("ClipboardShowLens", s => s.ClipboardShowLens, (s, v) => s.ClipboardShowLens = v);
        Flag("LinkPreviews", s => s.LinkPreviews, (s, v) => s.LinkPreviews = v);
        Flag("ClipboardPasteOnClick", s => s.ClipboardPasteOnClick, (s, v) => s.ClipboardPasteOnClick = v);
        Text("ClipboardPanelPosition", s => s.ClipboardPanelPosition, (s, v) => s.ClipboardPanelPosition = v ?? "top");
        List("ClipboardExcludedApps", s => s.ClipboardExcludedApps, (s, v) => s.ClipboardExcludedApps = v ?? new List<string>());

        // 启动器
        Text("LauncherPanelPosition", s => s.LauncherPanelPosition, (s, v) => s.LauncherPanelPosition = v ?? "top");
        Flag("LauncherShowsFrequent", s => s.LauncherShowsFrequent, (s, v) => s.LauncherShowsFrequent = v);
        Flag("LauncherFallbackAlways", s => s.LauncherFallbackAlways, (s, v) => s.LauncherFallbackAlways = v);
        Flag("LauncherRomanInput", s => s.LauncherRomanInput, (s, v) => s.LauncherRomanInput = v);
        Flag("LauncherScripts", s => s.LauncherScripts, (s, v) => s.LauncherScripts = v);
        Flag("LauncherRecentPrograms", s => s.LauncherRecentPrograms, (s, v) => s.LauncherRecentPrograms = v);
        Table("LauncherCommandAliases", s => s.LauncherCommandAliases, (s, v) => s.LauncherCommandAliases = v);
        List("LauncherCommandsOff", s => s.LauncherCommandsOff, (s, v) => s.LauncherCommandsOff = v);
        Table("LauncherCommandHotKeys", s => s.LauncherCommandHotKeys, (s, v) => s.LauncherCommandHotKeys = v);
        Table("LauncherAppAliases", s => s.LauncherAppAliases, (s, v) => s.LauncherAppAliases = v);
        List("LauncherBookmarkBrowsers", s => s.LauncherBookmarkBrowsers, (s, v) => s.LauncherBookmarkBrowsers = v);
        List("LauncherHistoryBrowsers", s => s.LauncherHistoryBrowsers, (s, v) => s.LauncherHistoryBrowsers = v);
        List("HotKeyBlockedApps", s => s.HotKeyBlockedApps, (s, v) => s.HotKeyBlockedApps = v ?? new List<string>());
        Flag("HotKeyBlockFullscreen", s => s.HotKeyBlockFullscreen, (s, v) => s.HotKeyBlockFullscreen = v);

        // 翻译
        Text("TranslateFirstLanguage", s => s.TranslateFirstLanguage, (s, v) => s.TranslateFirstLanguage = v);
        Text("TranslateSecondLanguage", s => s.TranslateSecondLanguage, (s, v) => s.TranslateSecondLanguage = v);
        Text("TranslateSource", s => s.TranslateSource, (s, v) => s.TranslateSource = v);
        Text("TranslateTarget", s => s.TranslateTarget, (s, v) => s.TranslateTarget = v);
        Flag("TranslateJoinLines", s => s.TranslateJoinLines, (s, v) => s.TranslateJoinLines = v);
        Flag("TranslateAutoCopy", s => s.TranslateAutoCopy, (s, v) => s.TranslateAutoCopy = v);
        Flag("TranslateCopyRecognized", s => s.TranslateCopyRecognized, (s, v) => s.TranslateCopyRecognized = v);
        Flag("TranslateScreenshotOverlay", s => s.TranslateScreenshotOverlay, (s, v) => s.TranslateScreenshotOverlay = v);
        Flag("TranslateHistoryEnabled", s => s.TranslateHistoryEnabled, (s, v) => s.TranslateHistoryEnabled = v);
        Number("TranslateHistoryLimit", s => s.TranslateHistoryLimit, (s, v) => s.TranslateHistoryLimit = v);
        Text("TranslateWindowPosition", s => s.TranslateWindowPosition, (s, v) => s.TranslateWindowPosition = v ?? "top");
        Flag("CopyTranslate", s => s.CopyTranslate, (s, v) => s.CopyTranslate = v);
        Flag("TranslateWordLookup", s => s.TranslateWordLookup, (s, v) => s.TranslateWordLookup = v);
        Flag("TranslateWordRecording", s => s.TranslateWordRecording, (s, v) => s.TranslateWordRecording = v);
        Text("TranslateWordAccent", s => s.TranslateWordAccent, (s, v) => s.TranslateWordAccent = v ?? "us");
        fields["TranslateFontScale"] = new(s => SettingValue.Of(s.TranslateFontScale),
            (s, v) => s.TranslateFontScale = v?.Real ?? Defaults.TranslateFontScale);
        fields["TranslateSpeechSpeed"] = new(s => SettingValue.Of(SpeechSpeed.Nearest(s.TranslateSpeechSpeed)),
            (s, v) => s.TranslateSpeechSpeed = SpeechSpeed.Nearest(v?.Real ?? Defaults.TranslateSpeechSpeed));
        List("TranslateCollapsedServices", s => s.TranslateCollapsedServices ?? new List<string>(),
            (s, v) => s.TranslateCollapsedServices = v is { Count: > 0 } ? v : null);
        Flag("OcrJoinLines", s => s.OcrJoinLines, (s, v) => s.OcrJoinLines = v);

        // 截图
        Flag("ScreenshotShutterSound", s => s.ScreenshotShutterSound, (s, v) => s.ScreenshotShutterSound = v);
        Text("ShotPlacement", s => s.ShotPlacement, (s, v) => s.ShotPlacement = v ?? "card");
        Text("ScreenshotToolbarAlign", s => s.ScreenshotToolbarAlign, (s, v) => s.ScreenshotToolbarAlign = v ?? "right");
        Text("ScreenshotCopyAs", s => s.ScreenshotCopyAs, (s, v) => s.ScreenshotCopyAs = v ?? "image");
        Text("ScrollCaptureSpeed", s => s.ScrollCaptureSpeed, (s, v) => s.ScrollCaptureSpeed = v ?? "normal");
        Flag("ScreenshotKeepsColors", s => s.ScreenshotKeepsColors, (s, v) => s.ScreenshotKeepsColors = v);
        Flag("ScreenshotFindsElements", s => s.ScreenshotFindsElements, (s, v) => s.ScreenshotFindsElements = v);
        Flag("ShotHistory", s => s.ShotHistory, (s, v) => s.ShotHistory = v);
        Number("ShotHistoryDays", s => s.ShotHistoryDays, (s, v) => s.ShotHistoryDays = v);
        Number("ShotHistoryMegabytes", s => s.ShotHistoryMegabytes, (s, v) => s.ShotHistoryMegabytes = v);
        Flag("ScreenshotCursor", s => s.ScreenshotCursor, (s, v) => s.ScreenshotCursor = v);
        Flag("CaptureHideDesktopIcons", s => s.CaptureHideDesktopIcons, (s, v) => s.CaptureHideDesktopIcons = v);

        // 录制
        Number("RecordFps", s => s.RecordFps, (s, v) => s.RecordFps = v);
        Number("RecordCountdown", s => s.RecordCountdown, (s, v) => s.RecordCountdown = v);
        Flag("RecordCursor", s => s.RecordCursor, (s, v) => s.RecordCursor = v);
        Text("RecordSharpness", s => s.RecordSharpness, (s, v) => s.RecordSharpness = v ?? "original");
        Flag("RecordKeysShortcutsOnly", s => s.RecordKeysShortcutsOnly, (s, v) => s.RecordKeysShortcutsOnly = v);
        Flag("RecordSystemSound", s => s.RecordSystemSound, (s, v) => s.RecordSystemSound = v);
        Flag("RecordClicks", s => s.RecordClicks, (s, v) => s.RecordClicks = v);
        Flag("RecordInstantStart", s => s.RecordInstantStart, (s, v) => s.RecordInstantStart = v);

        // 状态屏、提醒、保持唤醒
        Flag("StatusScreenExitHint", s => s.StatusScreenExitHint, (s, v) => s.StatusScreenExitHint = v);
        Flag("StatusScreenHotKeyEntersFirst", s => s.StatusScreenHotKeyEntersFirst, (s, v) => s.StatusScreenHotKeyEntersFirst = v);
        Flag("StatusScreenAnimations", s => s.StatusScreenAnimations, (s, v) => s.StatusScreenAnimations = v);
        Number("RemindersSnoozeMinutes", s => s.RemindersSnoozeMinutes, (s, v) => s.RemindersSnoozeMinutes = v);
        Flag("EmojiPackDownloads", s => s.EmojiPackDownloads, (s, v) => s.EmojiPackDownloads = v);
        Flag("KeepAwakeDisplay", s => s.KeepAwakeDisplay, (s, v) => s.KeepAwakeDisplay = v);

        // 便签
        Number("NotesFontSize", s => s.NotesFontSize, (s, v) => s.NotesFontSize = v);
        Flag("NotesMarkdown", s => s.NotesMarkdown, (s, v) => s.NotesMarkdown = v);
        Text("NotesLineSpacing", s => s.NotesLineSpacing, (s, v) => s.NotesLineSpacing = v ?? "standard");
        Flag("NotesDeckEnabled", s => s.NotesDeckEnabled, (s, v) => s.NotesDeckEnabled = v);
        Text("NotesDeckEdge", s => s.NotesDeckEdge, (s, v) => s.NotesDeckEdge = v ?? "right");
        Text("NotesDeckStyle", s => s.NotesDeckStyle, (s, v) => s.NotesDeckStyle = v ?? "tabs");
        Text("NotesDeckSize", s => s.NotesDeckSize, (s, v) => s.NotesDeckSize = v ?? "standard");
        Number("NotesDeckSense", s => s.NotesDeckSense, (s, v) => s.NotesDeckSense = v);
        Flag("NotesDeckAlwaysFanned", s => s.NotesDeckAlwaysFanned, (s, v) => s.NotesDeckAlwaysFanned = v);
        Flag("NotesDeckHidesPill", s => s.NotesDeckHidesPill, (s, v) => s.NotesDeckHidesPill = v);
        Flag("NotesDeckPreview", s => s.NotesDeckPreview, (s, v) => s.NotesDeckPreview = v);
        Flag("NotesDeckOpensOnHover", s => s.NotesDeckOpensOnHover, (s, v) => s.NotesDeckOpensOnHover = v);
        Flag("NotesDeckOverFullScreen", s => s.NotesDeckOverFullScreen, (s, v) => s.NotesDeckOverFullScreen = v);
        Text("NotesDeckNoteSize", s => s.NotesDeckNoteSize, (s, v) => s.NotesDeckNoteSize = v ?? "medium");

        // 功能开关：没存过 = 本机默认（Features.IsOn 的那条：插件没添加、功能开着）；写 null = 删掉这一项
        foreach (var feature in Enum.GetValues<Feature>())
        {
            var key = Features.Key(feature);
            var fallback = !Features.IsPlugin(feature);
            fields["feature." + key] = new(
                s => SettingValue.Of(s.Features is { } map && map.TryGetValue(key, out var on) ? on : fallback),
                (s, v) =>
                {
                    if (v is null)
                    {
                        s.Features?.Remove(key);
                    }
                    else
                    {
                        s.Features ??= new Dictionary<string, bool>();
                        s.Features[key] = v.Flag;
                    }
                });
        }

        // 全局快捷键
        foreach (var entry in SettingsDefaults.DefaultHotKeys)
        {
            var action = entry.Action;
            fields["hotkey." + action] = new(
                s => SettingValue.Of(Display(SettingsDefaults.BindingFor(s, action))),
                (s, v) =>
                {
                    if (v is null)
                    {
                        SettingsDefaults.ResetBinding(s, action);
                    }
                    else if (v.Text.Length == 0)
                    {
                        SettingsDefaults.SetBinding(s, action, new HotKeyBinding(0, HotKeyModifiers.None));
                    }
                    else if (HotKeyRules.TryParse(v.Text, out var key, out var modifiers))
                    {
                        SettingsDefaults.SetBinding(s, action, new HotKeyBinding(key, modifiers));
                    }
                });
        }

        // 截图工具栏的键
        foreach (var entry in ShotKeys.All)
        {
            var id = entry.Id;
            fields["shotkey." + id] = new(
                s => SettingValue.Of(ShotKeys.Current(id, s.ScreenshotKeys)?.Display ?? string.Empty),
                (s, v) =>
                {
                    var binding = v is null
                        ? entry.Default
                        : HotKeyRules.TryParse(v.Text, out var key, out var modifiers) ? new ShotKeyBinding(key, modifiers) : (ShotKeyBinding?)null;
                    var stored = ShotKeys.Set(s.ScreenshotKeys, id, binding);
                    s.ScreenshotKeys = stored.Count == 0 ? null : stored;
                });
        }

        return fields;
    }

    private static string Display(HotKeyBinding binding)
        => binding.VirtualKey == 0 ? string.Empty : HotKeyRules.Format(binding.VirtualKey, binding.Modifiers);

    /// <summary>收到的快捷键能不能落：空的（清除）照落；全局快捷键要能注册（HotKeyRules.Validate），截图的键要是能用的（ShotKeys.IsUsable）。</summary>
    public static bool Accept(SettingKey key, SettingValue value)
    {
        if (key.Id.StartsWith(SettingsSyncMap.HotKeyPrefix, StringComparison.Ordinal))
        {
            return value.Text.Length == 0 ||
                   (HotKeyRules.TryParse(value.Text, out var vk, out var modifiers) && HotKeyRules.Validate(vk, modifiers).Ok);
        }

        if (key.Id.StartsWith(SettingsSyncMap.ShotKeyPrefix, StringComparison.Ordinal))
        {
            return value.Text.Length == 0 ||
                   (HotKeyRules.TryParse(value.Text, out var vk, out var modifiers) && ShotKeys.IsUsable(new ShotKeyBinding(vk, modifiers)));
        }

        return true;
    }
}
