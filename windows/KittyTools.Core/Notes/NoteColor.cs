// 正文里的六种文字颜色（PLAN-v13 第 1 批，照 mac Notes/NotePaper.swift 的 NoteColor）：一种颜色浅色、深色外观各一个值，
// 每个值对 8 张纸（同一外观）的对比度都 ≥ 4.5:1。存的形式是正文里的 `[字]{名字}`，名字全小写。
// 文字颜色不是强调色、也不是纸色：不跟设置里的强调色变。
namespace KittyTools.Core.Notes;

public enum NoteColor
{
    Red,
    Orange,
    Green,
    Blue,
    Purple,
    Gray,
}

public static class NoteColors
{
    public static readonly NoteColor[] All =
        { NoteColor.Red, NoteColor.Orange, NoteColor.Green, NoteColor.Blue, NoteColor.Purple, NoteColor.Gray };

    /// <summary>正文里 `]{名字}` 的那个名字（全小写；只有这几个算）。</summary>
    public static string Name(NoteColor color) => color switch
    {
        NoteColor.Red => "red",
        NoteColor.Orange => "orange",
        NoteColor.Green => "green",
        NoteColor.Blue => "blue",
        NoteColor.Purple => "purple",
        _ => "gray",
    };

    public static string Title(NoteColor color) => color switch
    {
        NoteColor.Red => "红",
        NoteColor.Orange => "橙",
        NoteColor.Green => "绿",
        NoteColor.Blue => "蓝",
        NoteColor.Purple => "紫",
        _ => "灰",
    };

    /// <summary>浅色外观下的值（0xRRGGBB，sRGB）。</summary>
    public static int Light(NoteColor color) => color switch
    {
        NoteColor.Red => 0xA11A14,
        NoteColor.Orange => 0x8A4100,
        NoteColor.Green => 0x18602A,
        NoteColor.Blue => 0x1D4FB8,
        NoteColor.Purple => 0x6E2FB0,
        _ => 0x50555C,
    };

    public static int Dark(NoteColor color) => color switch
    {
        NoteColor.Red => 0xFF9C94,
        NoteColor.Orange => 0xFFB86B,
        NoteColor.Green => 0x7EDC8F,
        NoteColor.Blue => 0x8CB8FF,
        NoteColor.Purple => 0xD0A8FF,
        _ => 0xB4BAC2,
    };

    /// <summary>名字 → 颜色：只认全小写的这 6 个。</summary>
    public static NoteColor? Named(string name)
    {
        foreach (var color in All)
        {
            if (Name(color) == name)
            {
                return color;
            }
        }

        return null;
    }

    /// <summary>色值 → 颜色：导出文件里只认这 6 个。</summary>
    public static NoteColor? Value(int hex)
    {
        foreach (var color in All)
        {
            if (Light(color) == hex || Dark(color) == hex)
            {
                return color;
            }
        }

        return null;
    }
}
