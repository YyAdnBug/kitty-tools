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
    public const string Ocr = "ocr";
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
        new(HotKeyActions.Ocr, "识字", HotKeyModifiers.Alt, (uint)'O'),
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
