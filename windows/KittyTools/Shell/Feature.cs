// 能单独关掉的功能（第三版 §2.3，照 mac 的 Shell/Feature.swift）：剪贴板、翻译、启动器、截图、录屏、便签（PLAN-v13）、状态屏（PLAN-v12 N5）、提醒（N6）。
// 关掉 = 热键不注册、托盘里不显示、后台工作停掉、设置里那一页变灰并写明「已关闭」；
// 数据层照常（库照开、每日备份照做），设置和快捷键原样留着，打开立即回来、不用重启。
// 没存过 = 开（PLAN-v10 D2，2026-10-29：启动器、录屏都对齐 mac 了，0.1.0 默认打开；发版冒烟里哪样过不了就只把它改回默认关）。
// 插件（PLAN-v20 K2，mac Feature.plugins / isPlugin，f48c5d2e）：也是一个 Feature，开关就是「添加 / 移除」；和功能的区别只在露不露面——
// 没存过 = 没添加（新装、升级都不添加），没添加的不进设置侧栏（也不进「已关闭」）、引导、「功能」列表、主界面的「N 个功能关着」；
// 添加了进侧栏「插件」一组、托盘、主界面、快捷键页、速查表、启动器。Windows 现在只有保持唤醒一个（mac 的七样改插件 Windows 不动，PLAN-v20 §0）。
using KittyTools.Infrastructure;

namespace KittyTools;

// 顺序 = 设置侧栏、通用页「功能」、引导、快捷键页的顺序（PLAN-v16 G2，同 mac M3）；存的是 Key，不是序号。
internal enum Feature
{
    Clipboard,
    Launcher,
    Translate,
    Screenshot,
    Recording,
    Notes,
    Reminders,
    StatusScreen,

    /// <summary>保持唤醒（插件，PLAN-v20 K1）。</summary>
    KeepAwake,
}

internal static class Features
{
    public static string Key(Feature feature) => feature switch
    {
        Feature.Clipboard => "clipboard",
        Feature.Translate => "translate",
        Feature.Launcher => "launcher",
        Feature.Recording => "recording",
        Feature.Notes => "notes",
        Feature.StatusScreen => "statusScreen",
        Feature.Reminders => "reminders",
        Feature.KeepAwake => "keepAwake",
        _ => "screenshot",
    };

    /// <summary>插件（没存过 = 没添加）；别的是功能。</summary>
    public static bool IsPlugin(Feature feature) => feature == Feature.KeepAwake;

    /// <summary>「功能」列表、引导、主界面关着几个、新装时写开关的那几个：不含插件。</summary>
    public static IEnumerable<Feature> Listed => Enum.GetValues<Feature>().Where(feature => !IsPlugin(feature));

    public static IEnumerable<Feature> Plugins => Enum.GetValues<Feature>().Where(IsPlugin);

    /// <summary>插件卡片上的两行（mac pluginFacts）：要的授权、后台做什么。</summary>
    public static (string Permission, string Background) PluginFacts(Feature feature) => feature switch
    {
        _ => ("不要", "开着时让系统别睡；没开时什么都不跑"),
    };

    /// <summary>启动器里打这些词（或名字）时，没添加的插件出「添加…插件」那一行（mac pluginWords）。</summary>
    public static IReadOnlyList<string> PluginWords(Feature feature) => feature switch
    {
        _ => new[] { "awake", "保持唤醒", "防息屏", "防止睡眠", "不睡眠", "唤醒", "咖啡因", "caffeinate" },
    };

    public static IEnumerable<KittyTools.Core.PluginInfo> PluginInfos
        => Plugins.Select(plugin => new KittyTools.Core.PluginInfo(Key(plugin), Title(plugin), Blurb(plugin), PluginWords(plugin)));

    public static string Title(Feature feature) => feature switch
    {
        Feature.Clipboard => "剪贴板",
        Feature.Translate => "翻译",
        Feature.Launcher => "启动器",
        Feature.Recording => "录屏",
        Feature.Notes => "便签",
        Feature.StatusScreen => "状态屏",
        Feature.Reminders => "提醒",
        Feature.KeepAwake => "保持唤醒",
        _ => "截图",
    };

    public static string Blurb(Feature feature) => feature switch
    {
        Feature.Clipboard => "记下复制过的文字、图片和文件，随时找回来粘贴",
        Feature.Translate => "划词、输入、截图翻译，复制即译",
        Feature.Launcher => "一个搜索框：打开应用、设置和网页，顺手算算式",
        Feature.Recording => "把屏幕录成视频（Alt+R 开始 / 停止）",
        Feature.Notes => "快速记一条，屏幕边缘的便签",
        Feature.StatusScreen => "盖住屏幕、拦住键盘鼠标的告示",
        Feature.Reminders => "到点提醒你：一次、每天、每周或每隔一阵",
        Feature.KeepAwake => "不让电脑睡、不让屏幕熄：手动开一段，或按时段自动开",
        _ => "框选截图、识别图中文字、钉在屏幕上",
    };

    /// <summary>功能的键（新装时写开关用；不含插件：插件新装也是没添加，靠「没存过」就够了）。</summary>
    public static IEnumerable<string> AllKeys => Listed.Select(Key);

    /// <summary>开着的功能的键（新功能标记：功能关着不标）。</summary>
    public static HashSet<string> EnabledKeys => Enum.GetValues<Feature>().Where(IsOn).Select(Key).ToHashSet();

    /// <summary>设置侧栏的页对应哪个功能（通用、快捷键、关于不是）。</summary>
    public static Feature? ForPage(string page) => page switch
    {
        "clipboard" => Feature.Clipboard,
        "launcher" => Feature.Launcher,
        "translate" => Feature.Translate,
        "screenshot" => Feature.Screenshot,
        "record" => Feature.Recording,
        "notes" => Feature.Notes,
        "reminders" => Feature.Reminders,
        "statusScreen" => Feature.StatusScreen,
        "keepAwake" => Feature.KeepAwake,
        _ => null,
    };

    /// <summary>没存过 = 开（插件是没添加）；拨过的照用户的。</summary>
    public static bool IsOn(Feature feature)
        => SettingsService.Current.Features is { } map && map.TryGetValue(Key(feature), out var on) ? on : !IsPlugin(feature);

    public static void Set(Feature feature, bool on)
    {
        SettingsService.Current.Features ??= new Dictionary<string, bool>();
        SettingsService.Current.Features[Key(feature)] = on;
        SettingsService.Save();
    }

    /// <summary>这个热键动作现在用得上：它归的功能开着；打开主界面不归哪个功能，一直在（同 mac HotKeyAction.feature 为 nil）。</summary>
    public static bool IsOnFor(string action) => action == HotKeyActions.Home || IsOn(ForHotKey(action));

    /// <summary>这个热键动作属于哪个功能（关掉那个功能就不注册它）；打开主界面不归哪个功能，看开没开用 IsOnFor。</summary>
    public static Feature ForHotKey(string action) => action switch
    {
        HotKeyActions.Clipboard => Feature.Clipboard,
        HotKeyActions.Launcher => Feature.Launcher,
        HotKeyActions.SelectionTranslate or HotKeyActions.InputTranslate or HotKeyActions.ScreenshotTranslate
            or HotKeyActions.TranslateReplace => Feature.Translate,
        HotKeyActions.Record or HotKeyActions.Audio => Feature.Recording,
        HotKeyActions.StatusScreen => Feature.StatusScreen,
        HotKeyActions.ReminderNew => Feature.Reminders,
        HotKeyActions.NoteCapture or HotKeyActions.NoteNew or HotKeyActions.NoteAll => Feature.Notes,
        HotKeyActions.KeepAwake => Feature.KeepAwake,
        _ => Feature.Screenshot,
    };
}
