// 默认快捷键改成和 mac 一样（2026-11-18 用户：「快捷键和 macos 保持一致」，三个都对齐）：
// 截图 Alt+X → Alt+A（⌥A）、截取上次区域 Ctrl+Alt+Z → Alt+X（⌥X）、划词翻译 Alt+E → Alt+D（⌥D）。
// 已经装过的电脑只换还是旧默认值的那几个，用户自己改过的不动；新键已经被别的动作占着的也不换（不让两个动作撞在一个键上）。
// 设置加载时跑一次（Settings.Version 2 → 3），纯函数，单测在 HotKeyDefaultsMigrationTests。
namespace KittyTools.Core;

public static class HotKeyDefaultsMigration
{
    public readonly record struct Binding(HotKeyModifiers Modifiers, uint VirtualKey);

    public sealed record Change(string Action, Binding From, Binding To);

    /// <summary>
    /// 要换的三个。先后有讲究：截图先让出 Alt+X，截取上次区域才换得过去。
    /// </summary>
    public static readonly Change[] ToMacDefaults =
    {
        new("screenshot", new(HotKeyModifiers.Alt, 'X'), new(HotKeyModifiers.Alt, 'A')),
        new("screenshotLast", new(HotKeyModifiers.Control | HotKeyModifiers.Alt, 'Z'), new(HotKeyModifiers.Alt, 'X')),
        new("selectionTranslate", new(HotKeyModifiers.Alt, 'E'), new(HotKeyModifiers.Alt, 'D')),
    };

    /// <summary>
    /// stored：现在存着的每个动作的键（没设键的是 VirtualKey 0）。返回要改成什么（动作 → 新键），没有要改的就是空的。
    /// </summary>
    public static IReadOnlyDictionary<string, Binding> Plan(IReadOnlyDictionary<string, Binding> stored)
    {
        var current = new Dictionary<string, Binding>(stored, StringComparer.Ordinal);
        var changes = new Dictionary<string, Binding>(StringComparer.Ordinal);
        foreach (var change in ToMacDefaults)
        {
            if (!current.TryGetValue(change.Action, out var binding) || binding != change.From)
            {
                continue;
            }

            var taken = current.Any(pair => pair.Key != change.Action && pair.Value.VirtualKey != 0 && pair.Value == change.To);
            if (taken)
            {
                continue;
            }

            current[change.Action] = change.To;
            changes[change.Action] = change.To;
        }

        return changes;
    }
}
