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

    /// <summary>钉住剪贴板内容（PLAN-v9 F3；PLAN-v16 S3 文字也能钉，改了名、id 不变），默认不设键（同 mac pinClipboard）。</summary>
    public const string PinClipboard = "pinClipboard";

    /// <summary>打开主界面（PLAN-v10 §5），默认不设键、不归哪个功能（同 mac home）；托盘菜单里不放。</summary>
    public const string Home = "home";

    /// <summary>状态屏（PLAN-v12 N5），默认不设键（同 mac statusScreen）：先出选状态的面板，设置里开了就直接进排在最前面的。</summary>
    public const string StatusScreen = "statusScreen";

    /// <summary>新建提醒（PLAN-v12 N6），默认不设键（同 mac reminderNew）：打开启动器填好「提醒 」，启动器关着时打开 设置 › 提醒。</summary>
    public const string ReminderNew = "reminderNew";

    /// <summary>便签（PLAN-v13，名字同 mac）：快速记一条默认 Alt+N（mac ⌥N）；新建便签、全部便签不设默认键。</summary>
    public const string NoteCapture = "noteCapture";

    public const string NoteNew = "noteNew";

    public const string NoteAll = "noteAll";
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
        new(HotKeyActions.PinClipboard, "钉住剪贴板内容", HotKeyModifiers.None, 0),
        new(HotKeyActions.Home, "打开主界面", HotKeyModifiers.None, 0),
        new(HotKeyActions.StatusScreen, "状态屏", HotKeyModifiers.None, 0),
        new(HotKeyActions.ReminderNew, "新建提醒", HotKeyModifiers.None, 0),
        new(HotKeyActions.NoteCapture, "快速记一条", HotKeyModifiers.Alt, (uint)'N'),
        new(HotKeyActions.NoteNew, "新建便签", HotKeyModifiers.None, 0),
        new(HotKeyActions.NoteAll, "全部便签", HotKeyModifiers.None, 0),
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

    /// <summary>
    /// 快捷键页、速查表里这一行的名字（mac HotKeyAction.rowTitle，PLAN-v12 第 7 批）：状态屏的键照它实际做的事写——
    /// 默认「选一个状态进入」，设置 › 状态屏开了直接进入时「进入排在最前面的状态」；别的同 DisplayName。
    /// </summary>
    public static string RowTitle(string action)
        => action == HotKeyActions.StatusScreen
            ? SettingsService.Current.StatusScreenHotKeyEntersFirst ? "进入排在最前面的状态" : "选一个状态进入"
            : Find(action)?.DisplayName ?? action;

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
