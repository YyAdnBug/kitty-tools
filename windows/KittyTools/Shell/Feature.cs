// 能单独关掉的功能（第三版 §2.3，照 mac 的 Shell/Feature.swift）：剪贴板、翻译、启动器、截图、录屏。
// 关掉 = 热键不注册、托盘里不显示、后台工作停掉、设置里那一页变灰并写明「已关闭」；
// 数据层照常（库照开、每日备份照做），设置和快捷键原样留着，打开立即回来、不用重启。
// 没存过 = 开（PLAN-v10 D2，2026-10-29：启动器、录屏都对齐 mac 了，0.1.0 默认打开；发版冒烟里哪样过不了就只把它改回默认关）。
using KittyTools.Infrastructure;

namespace KittyTools;

internal enum Feature
{
    Clipboard,
    Translate,
    Launcher,
    Screenshot,
    Recording,
}

internal static class Features
{
    public static string Key(Feature feature) => feature switch
    {
        Feature.Clipboard => "clipboard",
        Feature.Translate => "translate",
        Feature.Launcher => "launcher",
        Feature.Recording => "recording",
        _ => "screenshot",
    };

    public static string Title(Feature feature) => feature switch
    {
        Feature.Clipboard => "剪贴板",
        Feature.Translate => "翻译",
        Feature.Launcher => "启动器",
        Feature.Recording => "录屏",
        _ => "截图",
    };

    public static string Blurb(Feature feature) => feature switch
    {
        Feature.Clipboard => "记下复制过的文字、图片和文件，随时找回来粘贴",
        Feature.Translate => "划词、输入、截图翻译，复制即译",
        Feature.Launcher => "一个搜索框：打开应用、设置和网页，顺手算算式",
        Feature.Recording => "把屏幕录成视频（Alt+R 开始 / 停止）",
        _ => "框选截图、识别图中文字、钉在屏幕上",
    };

    /// <summary>没存过 = 开；拨过的照用户的。</summary>
    public static bool IsOn(Feature feature)
        => SettingsService.Current.Features is not { } map || !map.TryGetValue(Key(feature), out var on) || on;

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
        _ => Feature.Screenshot,
    };
}
