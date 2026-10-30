// 录屏效果的类型和时序常量（PLAN-v6 第 3 批起只保留数据；画由 WgcEffects 在 GPU 纹理上做）；
// 「显示按键」那一颗胶囊写什么（KeycapText，PLAN-v9 R4，同 mac InputOverlay）。
namespace KittyTools.Core;

public readonly record struct ClickRing(int X, int Y, bool Right, long DownAt, long UpAt);

public readonly record struct Keycap(string Text, long At);

public static class RecordingOverlay
{
    public const int RingDurationMs = 400;

    public const int KeycapDurationMs = 1500;

    public const int RingMaxRadius = 24;

    public const int KeycapHeight = 34;

    /// <summary>
    /// 按下一个键时胶囊上写什么；null = 不显示。name 是键名（修饰键本身、认不得的键是 null）；function 是 F1–F24；escape 是 Esc。
    /// 全部按键（默认，同 mac）：每一下都显示，带着修饰键连着写；只显示快捷键：带 Ctrl / Alt / Win 的组合、Esc 和 F 键才显示，
    /// 打字（包括 Shift + 字母）不进画面。
    /// </summary>
    public static string? KeycapText(
        string? name, bool ctrl, bool alt, bool shift, bool win, bool function, bool escape, bool shortcutsOnly)
    {
        if (name is null || (shortcutsOnly && !(ctrl || alt || win || function || escape)))
        {
            return null;
        }

        var parts = new List<string>(5);
        if (ctrl)
        {
            parts.Add("Ctrl");
        }

        if (alt)
        {
            parts.Add("Alt");
        }

        if (shift)
        {
            parts.Add("Shift");
        }

        if (win)
        {
            parts.Add("Win");
        }

        parts.Add(name);
        return string.Join(" + ", parts);
    }
}