// PLAN-v7 U5：强调色 8 档（跟随系统 + 蓝 / 紫 / 品牌粉 / 红 / 橙 / 黄 / 绿 / 石墨）。
// 纯数据 + 对比度计算，界面层（Theme）再变成 WinUI 的 Color / Brush，配单测。
//
// 浅色 / 深色取苹果系统色；「键帽 / 图标上的符号」用黑还是白由相对亮度决定，不靠人肉记，
// 保证 ≥ 3:1 的图形对比（正文的 4.5:1 在 Kitty.AccentText 上另外保证）。
namespace KittyTools.Core;

public sealed record AccentDefinition(string Key, string Name, uint Light, uint Dark, bool DarkTextOnAccent);

public static class AccentPalette
{
    public static IReadOnlyList<AccentDefinition> All { get; } = new[]
    {
        new AccentDefinition("blue", "蓝", 0x007AFF, 0x0A84FF, false),
        new AccentDefinition("purple", "紫", 0xAF52DE, 0xBF5AF2, false),
        new AccentDefinition("pink", "品牌粉", 0xFF4D7E, 0xFF375F, false),
        new AccentDefinition("red", "红", 0xFF3B30, 0xFF453A, false),
        new AccentDefinition("orange", "橙", 0xFF9500, 0xFF9F0A, true),
        new AccentDefinition("yellow", "黄", 0xFFCC00, 0xFFD60A, true),
        new AccentDefinition("green", "绿", 0x34C759, 0x30D158, true),
        new AccentDefinition("graphite", "石墨", 0x8E8E93, 0x98989D, true),
    };

    public static AccentDefinition Default => All.First(item => item.Key == "pink");

    public static AccentDefinition? Find(string? key)
        => key is null ? null : All.FirstOrDefault(item => string.Equals(item.Key, key, StringComparison.OrdinalIgnoreCase));

    /// <summary>设置里存的旧值（brand）当作品牌粉。</summary>
    public static AccentDefinition FromSetting(string? setting, bool dark)
    {
        if (string.Equals(setting, "brand", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(setting, "system", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(setting))
        {
            return Default;
        }

        return Find(setting) ?? Default;
    }

    public static uint Value(AccentDefinition definition, bool dark) => dark ? definition.Dark : definition.Light;

    /// <summary>WCAG 相对亮度。</summary>
    public static double RelativeLuminance(uint rgb)
    {
        static double Channel(uint value)
        {
            var channel = value / 255.0;
            return channel <= 0.03928 ? channel / 12.92 : Math.Pow((channel + 0.055) / 1.055, 2.4);
        }

        var r = Channel((rgb >> 16) & 0xFF);
        var g = Channel((rgb >> 8) & 0xFF);
        var b = Channel(rgb & 0xFF);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    /// <summary>WCAG 对比度（1–21）。</summary>
    public static double Contrast(uint a, uint b)
    {
        var la = RelativeLuminance(a);
        var lb = RelativeLuminance(b);
        var lighter = Math.Max(la, lb);
        var darker = Math.Min(la, lb);
        return (lighter + 0.05) / (darker + 0.05);
    }

    /// <summary>填充上面的符号色：深色字用 0x1A1A1A（不是纯黑，避免过硬）。</summary>
    public static uint OnAccent(uint background)
        => Contrast(background, 0x1A1A1Au) >= Contrast(background, 0xFFFFFFu) ? 0x1A1A1Au : 0xFFFFFFu;

    /// <summary>浅色背景上的强调文字：取比填充深一档的同色，保证 ≥ 4.5:1。</summary>
    public static uint AccentText(uint background, bool dark)
    {
        var target = dark ? 0x101010u : 0xFFFFFFu;
        for (var amount = 0.0; amount <= 0.8; amount += 0.05)
        {
            var candidate = Scale(background, 1 - amount);
            if (Contrast(candidate, target) >= 4.5)
            {
                return candidate;
            }
        }

        return background;
    }

    /// <summary>按比例混合到黑 / 白（0 = 不变，1 = 纯黑）。</summary>
    public static uint Scale(uint rgb, double factor)
    {
        var r = (uint)Math.Clamp(Math.Round(((rgb >> 16) & 0xFF) * factor), 0, 255);
        var g = (uint)Math.Clamp(Math.Round(((rgb >> 8) & 0xFF) * factor), 0, 255);
        var b = (uint)Math.Clamp(Math.Round((rgb & 0xFF) * factor), 0, 255);
        return (r << 16) | (g << 8) | b;
    }
}
