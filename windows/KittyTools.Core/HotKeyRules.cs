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

        // 连按两下 Ctrl / Alt / Shift（PLAN-v18 L9）：记成修饰键自己、不带修饰键
        if (IsDoubleTap(virtualKey, modifiers))
        {
            return HotKeyValidation.Pass;
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

    /// <summary>连按两下修饰键（PLAN-v18 L9 / D6）：Ctrl、Alt、Shift 自己的虚拟键、不带修饰键（Win 不认）。</summary>
    public static bool IsDoubleTap(uint virtualKey, HotKeyModifiers modifiers)
        => modifiers == HotKeyModifiers.None && virtualKey is 0x10 or 0x11 or 0x12;

    /// <summary>录上连按两下之后那一行下面的提醒（D6）；Ctrl 没有。</summary>
    public static string? DoubleTapHint(uint virtualKey) => virtualKey switch
    {
        0x12 => "很多软件里单按 Alt 会先激活菜单栏，连按两下会开了又关",
        0x10 => "中文输入法里单按 Shift 切中英文，连按两下会切过去再切回来",
        _ => null,
    };

    private static string DoubleTapName(uint virtualKey) => virtualKey switch
    {
        0x11 => "Ctrl",
        0x12 => "Alt",
        _ => "Shift",
    };

    public static bool IsModifierKey(uint virtualKey)
        => virtualKey is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or >= 0xA0 and <= 0xA5;

    public static bool IsGenericCtrlKey(uint virtualKey) => GenericCtrlKeys.Contains(virtualKey);

    public static string Format(uint virtualKey, HotKeyModifiers modifiers)
    {
        if (IsDoubleTap(virtualKey, modifiers))
        {
            // 「Ctrl+Ctrl」：键帽拆成两个 Ctrl，导出导入照这个写法读回来
            return DoubleTapName(virtualKey) + "+" + DoubleTapName(virtualKey);
        }

        var sb = new StringBuilder(24);
        if ((modifiers & HotKeyModifiers.Control) != 0) sb.Append("Ctrl+");
        if ((modifiers & HotKeyModifiers.Alt) != 0) sb.Append("Alt+");
        if ((modifiers & HotKeyModifiers.Shift) != 0) sb.Append("Shift+");
        if ((modifiers & HotKeyModifiers.Win) != 0) sb.Append("Win+");
        sb.Append(KeyName(virtualKey));
        return sb.ToString();
    }

    /// <summary>把 <see cref="Format"/> 写出来的「Ctrl+Alt+K」读回来（导入导出的文件里用这个写法）。</summary>
    public static bool TryParse(string text, out uint virtualKey, out HotKeyModifiers modifiers)
    {
        virtualKey = 0;
        modifiers = HotKeyModifiers.None;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var parts = text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0)
        {
            return false;
        }

        foreach (var part in parts[..^1])
        {
            modifiers |= part switch
            {
                "Ctrl" or "Control" => HotKeyModifiers.Control,
                "Alt" => HotKeyModifiers.Alt,
                "Shift" => HotKeyModifiers.Shift,
                "Win" => HotKeyModifiers.Win,
                _ => 0,
            };
        }

        var key = parts[^1];
        // 「Ctrl+Ctrl」：连按两下（前面只有同一个修饰键）
        if (parts.Length == 2 && key is "Ctrl" or "Alt" or "Shift" && parts[0] == key)
        {
            virtualKey = key switch { "Ctrl" => 0x11u, "Alt" => 0x12u, _ => 0x10u };
            modifiers = HotKeyModifiers.None;
            return true;
        }

        if (key.Length == 1 && char.IsAsciiLetterOrDigit(key[0]))
        {
            virtualKey = char.ToUpperInvariant(key[0]);
            return true;
        }

        if (key.Length is 2 or 3 && (key[0] is 'F' or 'f') &&
            int.TryParse(key[1..], out var function) && function is >= 1 and <= 24)
        {
            virtualKey = (uint)(VkF1 + function - 1);
            return true;
        }

        // KeyName 写出来的「VK6B」（小键盘这些没名字的键）读回去（截图时的键能录任意键，PLAN-v18 S3）
        if (key.Length == 4 && key.StartsWith("VK", StringComparison.Ordinal) &&
            uint.TryParse(key[2..], System.Globalization.NumberStyles.HexNumber, null, out var raw) && raw is > 0 and < 0x100)
        {
            virtualKey = raw;
            return true;
        }

        virtualKey = key switch
        {
            ";" => 0xBA,
            "=" => 0xBB,
            "," => 0xBC,
            "-" => 0xBD,
            "." => 0xBE,
            "/" => 0xBF,
            "`" => 0xC0,
            "[" => 0xDB,
            "\\" => 0xDC,
            "]" => 0xDD,
            "'" => 0xDE,
            "Space" => VkSpace,
            "Tab" => VkTab,
            "Enter" => VkReturn,
            "Esc" or "Escape" => VkEscape,
            "Backspace" => VkBack,
            "Delete" => VkDelete,
            "Left" => VkLeft,
            "Up" => VkUp,
            "Right" => VkRight,
            "Down" => VkDown,
            _ => 0,
        };
        return virtualKey != 0;
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
