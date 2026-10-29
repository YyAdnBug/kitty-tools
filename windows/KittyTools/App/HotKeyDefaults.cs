// 热键的默认表和 action 名字。设置里只存覆盖过的项，缺的用默认值补上。
using KittyTools.Core;

namespace KittyTools.Infrastructure;

internal static class HotKeyActions
{
    public const string Clipboard = "clipboard";
    public const string Launcher = "launcher";
    public const string SelectionTranslate = "selectionTranslate";
    public const string InputTranslate = "inputTranslate";
    public const string ScreenshotTranslate = "screenshotTranslate";
    public const string Screenshot = "screenshot";
    public const string ScreenshotLast = "screenshotLast";
    public const string Record = "record";
    public const string Ocr = "ocr";

    /// <summary>截图历史（PLAN-v8），默认不设键。</summary>
    public const string ShotHistory = "shotHistory";

    /// <summary>划词翻译并替换（不开浮窗，PLAN-v9-translate F7），默认不设键；名字同 mac。</summary>
    public const string TranslateReplace = "translateReplace";

    /// <summary>录音（PLAN-v9 F2），默认不设键；录着时按是停止，待录时按是开始（同 mac audioRecord）。</summary>
    public const string Audio = "audioRecord";

    /// <summary>钉住剪贴板里的图（PLAN-v9 F3），默认不设键（同 mac pinClipboard）。</summary>
    public const string PinClipboard = "pinClipboard";

    /// <summary>打开主界面（PLAN-v10 §5），默认不设键、不归哪个功能（同 mac home）；托盘菜单里不放。</summary>
    public const string Home = "home";
}

internal sealed record HotKeyDefault(
    string Action,
    string DisplayName,
    HotKeyModifiers Modifiers,
    uint VirtualKey);

internal static class SettingsDefaults
{
    public static readonly HotKeyDefault[] DefaultHotKeys =
    {
        new(HotKeyActions.Clipboard, "剪贴板历史", HotKeyModifiers.Alt, (uint)'C'),
        new(HotKeyActions.Launcher, "启动器", HotKeyModifiers.Alt, 0x20),
        new(HotKeyActions.SelectionTranslate, "划词翻译", HotKeyModifiers.Alt, (uint)'E'),
        new(HotKeyActions.InputTranslate, "输入翻译", HotKeyModifiers.Alt, (uint)'T'),
        new(HotKeyActions.ScreenshotTranslate, "截图翻译", HotKeyModifiers.Alt, (uint)'S'),
        new(HotKeyActions.Screenshot, "截图", HotKeyModifiers.Alt, (uint)'X'),
        new(HotKeyActions.ScreenshotLast, "截取上次区域", HotKeyModifiers.Control | HotKeyModifiers.Alt, (uint)'Z'),
        new(HotKeyActions.Record, "录屏（再按一次停止）", HotKeyModifiers.Alt, (uint)'R'),
        new(HotKeyActions.Ocr, "识字", HotKeyModifiers.Alt, (uint)'O'),
        // 新动作只加在最后（快捷键页和速查表按这张表的顺序排）。
        new(HotKeyActions.ShotHistory, "截图历史", HotKeyModifiers.None, 0),
        new(HotKeyActions.TranslateReplace, "划词翻译并替换", HotKeyModifiers.None, 0),
        new(HotKeyActions.Audio, "录音（再按一次停止）", HotKeyModifiers.None, 0),
        new(HotKeyActions.PinClipboard, "钉住剪贴板里的图", HotKeyModifiers.None, 0),
        new(HotKeyActions.Home, "打开主界面", HotKeyModifiers.None, 0),
    };

    public static void Apply(Settings settings)
    {
        foreach (var definition in DefaultHotKeys)
        {
            if (settings.HotKeys.All(h => h.Action != definition.Action))
            {
                settings.HotKeys.Add(new HotKeySetting
                {
                    Action = definition.Action,
                    Modifiers = (uint)definition.Modifiers,
                    VirtualKey = definition.VirtualKey,
                });
            }
        }

        settings.HotKeys.RemoveAll(h => DefaultHotKeys.All(d => d.Action != h.Action));
    }

    public static HotKeyDefault? Find(string action)
        => DefaultHotKeys.FirstOrDefault(d => d.Action == action);

    public static HotKeyBinding BindingFor(Settings settings, string action)
    {
        var stored = settings.HotKeys.FirstOrDefault(h => h.Action == action);
        if (stored is not null)
        {
            return new HotKeyBinding(stored.VirtualKey, (HotKeyModifiers)stored.Modifiers);
        }

        var definition = Find(action);
        return definition is null
            ? default
            : new HotKeyBinding(definition.VirtualKey, definition.Modifiers);
    }

    public static void SetBinding(Settings settings, string action, HotKeyBinding binding)
    {
        var stored = settings.HotKeys.FirstOrDefault(h => h.Action == action);
        if (stored is null)
        {
            stored = new HotKeySetting { Action = action };
            settings.HotKeys.Add(stored);
        }

        stored.Modifiers = (uint)binding.Modifiers;
        stored.VirtualKey = binding.VirtualKey;
    }

    public static void ResetBinding(Settings settings, string action)
    {
        settings.HotKeys.RemoveAll(h => h.Action == action);
        SettingsDefaults.Apply(settings);
    }
}

internal readonly record struct HotKeyBinding(uint VirtualKey, HotKeyModifiers Modifiers);
