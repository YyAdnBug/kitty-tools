// 热键录制规则（纯函数）。PLAN §5.3：
// - 至少带一个 Ctrl 或 Alt，或者单独一个 F1–F24；
// - 不收 Win 组合；
// - 拒绝通用键（Ctrl+C/V/X/Z/Y/A/S/F/W/T/N/P、Alt+F4/Tab/Esc、Ctrl+Esc 等）。
using System.Text;

namespace KittyTools.Core;

[Flags]
public enum HotKeyModifiers : uint
{
    None = 0,
    Control = 1,
    Alt = 2,
    Shift = 4,
    Win = 8,
}

public readonly record struct HotKeyValidation(bool Ok, string? Reason)
{
    public static HotKeyValidation Pass => new(true, null);

    public static HotKeyValidation Fail(string reason) => new(false, reason);
}

public static class HotKeyRules
{
    public const uint VkBack = 0x08;
    public const uint VkTab = 0x09;
    public const uint VkReturn = 0x0D;
    public const uint VkEscape = 0x1B;
    public const uint VkSpace = 0x20;
    public const uint VkLeft = 0x25;
    public const uint VkUp = 0x26;
    public const uint VkRight = 0x27;
    public const uint VkDown = 0x28;
    public const uint VkDelete = 0x2E;
    public const uint VkF1 = 0x70;
    public const uint VkF24 = 0x87;

    private static readonly HashSet<uint> GenericCtrlKeys = new()
    {
        'C', 'V', 'X', 'Z', 'Y', 'A', 'S', 'F', 'W', 'T', 'N', 'P',
    };

    public static HotKeyValidation Validate(uint virtualKey, HotKeyModifiers modifiers)
    {
        if (virtualKey == 0)
        {
            return HotKeyValidation.Fail("没有按键");
        }

        if ((modifiers & HotKeyModifiers.Win) != 0)
        {
            return HotKeyValidation.Fail("不能使用 Win 键组合");
        }

        if (IsModifierKey(virtualKey))
        {
            return HotKeyValidation.Fail("只能按修饰键本身");
        }

        var hasCtrl = (modifiers & HotKeyModifiers.Control) != 0;
        var hasAlt = (modifiers & HotKeyModifiers.Alt) != 0;

        if (!hasCtrl && !hasAlt)
        {
            if (modifiers != HotKeyModifiers.None)
            {
                return HotKeyValidation.Fail("要带 Ctrl 或 Alt，或者单独一个 F1–F24");
            }

            if (virtualKey is < VkF1 or > VkF24)
            {
                return HotKeyValidation.Fail("单独一个键只允许 F1–F24");
            }
        }

        if (hasCtrl && IsGenericCtrlKey(virtualKey))
        {
            return HotKeyValidation.Fail($"{Format(virtualKey, modifiers)} 是应用里的通用快捷键");
        }

        if (hasAlt && virtualKey is 0x73 or VkTab or VkEscape) // F4 / Tab / Esc
        {
            return HotKeyValidation.Fail($"{Format(virtualKey, modifiers)} 是系统快捷键");
        }

        if (hasCtrl && virtualKey == VkEscape)
        {
            return HotKeyValidation.Fail("Ctrl+Esc 是系统快捷键");
        }

        if (hasCtrl && hasAlt && virtualKey == VkDelete)
        {
            return HotKeyValidation.Fail("Ctrl+Alt+Delete 是系统保留组合");
        }

        if (hasCtrl && (modifiers & HotKeyModifiers.Shift) != 0 && virtualKey == VkEscape)
        {
            return HotKeyValidation.Fail("Ctrl+Shift+Esc 是系统快捷键");
        }

        return HotKeyValidation.Pass;
    }

    public static bool IsModifierKey(uint virtualKey)
        => virtualKey is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or >= 0xA0 and <= 0xA5;

    public static bool IsGenericCtrlKey(uint virtualKey) => GenericCtrlKeys.Contains(virtualKey);

    public static string Format(uint virtualKey, HotKeyModifiers modifiers)
    {
        var sb = new StringBuilder(24);
        if ((modifiers & HotKeyModifiers.Control) != 0) sb.Append("Ctrl+");
        if ((modifiers & HotKeyModifiers.Alt) != 0) sb.Append("Alt+");
        if ((modifiers & HotKeyModifiers.Shift) != 0) sb.Append("Shift+");
        if ((modifiers & HotKeyModifiers.Win) != 0) sb.Append("Win+");
        sb.Append(KeyName(virtualKey));
        return sb.ToString();
    }

    public static string KeyName(uint virtualKey) => virtualKey switch
    {
        >= 0x30 and <= 0x39 => ((char)virtualKey).ToString(),
        >= 0x41 and <= 0x5A => ((char)virtualKey).ToString(),
        >= VkF1 and <= VkF24 => $"F{virtualKey - VkF1 + 1}",
        VkSpace => "Space",
        VkTab => "Tab",
        VkReturn => "Enter",
        VkEscape => "Esc",
        VkBack => "Backspace",
        VkDelete => "Delete",
        VkLeft => "Left",
        VkUp => "Up",
        VkRight => "Right",
        VkDown => "Down",
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => $"VK{virtualKey:X2}",
    };
}
