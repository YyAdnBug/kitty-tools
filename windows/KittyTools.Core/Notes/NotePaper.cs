// 便签的纸色（PLAN-v13 第 1 批，照 mac Notes/NotePaper.swift 的纯函数部分；颜色菜单那一份的条目和「最近用过」照 NoteColorPicker.swift、
// 任务方框的几样颜色照 NoteTaskBox.swift）：
// - 8 种预设，Note.Color 是这张表的下标。每种三样——纸（便签的底）、色条（纸顶上那一条、圆点的圈）、墨（纸上的字）——浅色、
//   深色外观各一套（0xRRGGBB，sRGB）。墨对纸 ≥ 7:1、次要的字（墨的 75%）≥ 4.5:1（NotePaperTests 锁住）。
// - 自定义纸色（Note.Custom）：从挑的颜色按 OKLCH 推出整张纸（Derived，按色值缓存），落盘时 color 写最接近的预设（NearestPreset）。
// - mac 的动态色（NSColor 按外观取色）这里没有：各处要的颜色写成「这个外观（dark）、开没开增强对比度（contrast）下取哪个值、
//   多大不透明度」（NoteShade），窗口代码自己看系统的主题和高对比度开关来问。
// 纸色是内容的颜色，不是强调色：不跟设置里的强调色变。
using System.Collections.Concurrent;

namespace KittyTools.Core.Notes;

/// <summary>一套颜色（0xRRGGBB，sRGB）。</summary>
public readonly record struct NoteTone(int Paper, int Strip, int Ink);

/// <summary>一种颜色画出来的样子：0xRRGGBB + 不透明度（0–1；叠在纸上画）。</summary>
public readonly record struct NoteShade(int Rgb, double Opacity)
{
    /// <summary>0xAARRGGBB（WinUI 的 Color.FromArgb 用）。</summary>
    public uint Argb => (uint)Math.Round(Math.Clamp(Opacity, 0, 1) * 255, MidpointRounding.AwayFromZero) << 24 |
                        (uint)(Rgb & 0xFFFFFF);
}

public sealed record NotePaper(string Name, NoteTone Light, NoteTone Dark)
{
    /// <summary>次要的字（「改于…」那一行、占位）用墨的这么多。</summary>
    public const double SecondaryOpacity = 0.75;

    /// <summary>做完的任务的字用墨的这么多；增强对比度时回到 SecondaryOpacity。</summary>
    public const double DoneOpacity = 0.5;

    /// <summary>正文里露出来的 Markdown 标记用墨的这么多；增强对比度时 MarkerContrastOpacity。</summary>
    public const double MarkerOpacity = 0.35;

    public const double MarkerContrastOpacity = 0.6;

    /// <summary>行内代码的底：墨的这么多。增强对比度时不加深（加到 16% 深色那 8 套墨对底都不到 7:1）。</summary>
    public const double CodeFillOpacity = 0.08;

    /// <summary>打开的便签带着的那张标签：纸上叠这么浓的色条色。</summary>
    public const double TabTint = 0.16;

    /// <summary>纸的描边、纸上的分隔线：墨的 14%，增强对比度时 45%。</summary>
    public const double RuleOpacity = 0.14;

    public const double RuleContrastOpacity = 0.45;

    /// <summary>任务方框（待办、进行中）的描边：墨的这么多，增强对比度时是墨（mac NoteTaskBox.strokeOpacity）。</summary>
    public const double TaskStrokeOpacity = 0.72;

    /// <summary>颜色菜单末尾那一项的名字（打开系统取色）。</summary>
    public const string OtherColorTitle = "其他颜色…";

    /// <summary>颜色菜单里自定义的那一节最多几个（这条现在用的 + 最近用过的；mac NoteColorPicker.recentLimit）。</summary>
    public const int RecentLimit = 8;

    public static IReadOnlyList<NotePaper> All { get; } = new NotePaper[]
    {
        new("柠檬", new NoteTone(0xFCE795, 0xE0AD08, 0x3A3008), new NoteTone(0x4A4012, 0xF2C230, 0xFBEFB8)),
        new("桃", new NoteTone(0xFBCFA6, 0xE2762A, 0x422413), new NoteTone(0x4F3320, 0xF08A45, 0xFCE0C6)),
        new("玫瑰", new NoteTone(0xFAC4D1, 0xDC4570, 0x40161F), new NoteTone(0x4E2330, 0xF06A8E, 0xFBD5DE)),
        new("丁香", new NoteTone(0xD9C7FA, 0x7C4DEE, 0x2A1B44), new NoteTone(0x35285A, 0x9D7CF5, 0xE6DAFC)),
        new("天蓝", new NoteTone(0xBEDDFA, 0x2280D6, 0x13293A), new NoteTone(0x1D3A54, 0x4DA3EC, 0xD3E8FB)),
        new("薄荷", new NoteTone(0xB4E8D0, 0x0E9B6E, 0x0F2E23), new NoteTone(0x17402F, 0x2DBE8D, 0xC8F0DD)),
        new("沙", new NoteTone(0xE3D3B4, 0xA37B3C, 0x372C18), new NoteTone(0x453A26, 0xC39A58, 0xEEE2CA)),
        new("石板", new NoteTone(0xCBD6E2, 0x4E6579, 0x1A242E), new NoteTone(0x2C3742, 0x7E97AD, 0xDCE4EC)),
    };

    /// <summary>推出来的纸按色值缓存：便签墙几百张卡片、那叠的标签每次重画都来取。</summary>
    private static readonly ConcurrentDictionary<int, NotePaper> DerivedCache = new();

    /// <summary>自定义纸色的名字：按 OKLCH 色相分的词，每个词管到的色相上界（度）；红之前、品红之后的都是粉。</summary>
    private static readonly (double UpTo, string Word)[] HueWords =
    {
        (15, "粉"), (45, "红"), (80, "橙"), (118, "黄"), (138, "黄绿"), (158, "绿"), (183, "青绿"),
        (215, "青"), (272, "蓝"), (290, "靛"), (320, "紫"), (340, "品红"), (360, "粉"),
    };

    public static NotePaper Of(Note note) => Of(note.Color);

    /// <summary>纸色（Note.Color 的值）→ 这张纸：预设的查表（越界的夹回来），自定义的从色值推（按色值缓存）。
    /// **取纸色一律走这里**，别拿 Note.Color 直接当 All 的下标（自定义的值不是下标）。</summary>
    public static NotePaper Of(int color)
    {
        if (Note.CustomRgb(color) is not { } rgb)
        {
            return All[Math.Clamp(color, 0, All.Count - 1)];
        }

        if (DerivedCache.TryGetValue(rgb, out var cached))
        {
            return cached;
        }

        var paper = Derived(rgb);
        // ponytail: 满了整个清掉，不按最近用过淘汰；一台电脑上用到的自定义色不会多到哪去
        if (DerivedCache.Count >= 256)
        {
            DerivedCache.Clear();
        }

        DerivedCache[rgb] = paper;
        return paper;
    }

    public NoteTone Tone(bool dark) => dark ? Dark : Light;

    // ---- 各处要的颜色（mac 的动态色：dark = 深色外观，contrast = 系统开着增强对比度 / 高对比度）----

    /// <summary>做完 / 取消的任务的字：墨的 50%，增强对比度时 75%。</summary>
    public NoteShade FadedInk(bool dark, bool contrast) => new(Tone(dark).Ink, contrast ? SecondaryOpacity : DoneOpacity);

    /// <summary>正文编辑器里次要的墨（引用的字）：墨的 75%，增强对比度时就是墨。
    /// （mac SwiftUI 那边的 secondaryInk——「改于」那一行、占位——不看增强对比度，一律 75%：那种用 contrast: false 来取。）</summary>
    public NoteShade SecondaryInk(bool dark, bool contrast) => new(Tone(dark).Ink, contrast ? 1 : SecondaryOpacity);

    /// <summary>露出来的 Markdown 标记：墨的 35%，增强对比度时 60%。</summary>
    public NoteShade MarkerInk(bool dark, bool contrast) => new(Tone(dark).Ink, contrast ? MarkerContrastOpacity : MarkerOpacity);

    /// <summary>行内代码、代码块的底：墨的 8%（增强对比度时一样）。</summary>
    public NoteShade CodeFill(bool dark) => new(Tone(dark).Ink, CodeFillOpacity);

    /// <summary>引用左边的竖线、完成的任务方框的底：色条色；增强对比度时用墨。</summary>
    public NoteShade QuoteBar(bool dark, bool contrast) => new(contrast ? Tone(dark).Ink : Tone(dark).Strip, 1);

    /// <summary>纸的描边、纸上的分隔线：墨的 14%，增强对比度时 45%。</summary>
    public NoteShade Rule(bool dark, bool contrast) => new(Tone(dark).Ink, contrast ? RuleContrastOpacity : RuleOpacity);

    /// <summary>永远深色的底上用的色条色（屏幕边缘的药丸，不跟外观变）：深色那套的色条。</summary>
    public int BrightStrip => Dark.Strip;

    /// <summary>打开的便签带着的那张标签的底：纸上叠 16% 的色条色（不透明）。</summary>
    public int TabFill(bool dark) => Mix(Tone(dark).Strip, Tone(dark).Paper, TabTint);

    /// <summary>待办、进行中的方框描边：墨的 72%，增强对比度时是墨。</summary>
    public NoteShade TaskStroke(bool dark, bool contrast) => new(Tone(dark).Ink, contrast ? 1 : TaskStrokeOpacity);

    /// <summary>完成的方框的底（同引用的竖线）。</summary>
    public NoteShade TaskDone(bool dark, bool contrast) => QuoteBar(dark, contrast);

    /// <summary>完成的方框上的对勾：白和浅色那套的墨里对底对比度高的；增强对比度时底是墨，勾用纸色。</summary>
    public int TaskDoneMark(bool dark, bool contrast) => contrast ? Tone(dark).Paper : Mark(Tone(dark).Strip, Light.Ink);

    /// <summary>紧急的方框（文字颜色的红底）上的感叹号：同上取色（增强对比度时也一样）。</summary>
    public int TaskUrgentMark(bool dark)
        => Mark(dark ? NoteColors.Dark(NoteColor.Red) : NoteColors.Light(NoteColor.Red), Light.Ink);

    /// <summary>正文里的文字颜色（mac NoteColor.color / fadedColor）：faded = 在完成 / 取消的任务里（同墨的 50%，增强对比度时 75%）。</summary>
    public static NoteShade TextColor(NoteColor color, bool dark, bool faded, bool contrast)
        => new(dark ? NoteColors.Dark(color) : NoteColors.Light(color),
            faded ? (contrast ? SecondaryOpacity : DoneOpacity) : 1);

    // ---- 对比度、混色 ----

    /// <summary>WCAG 相对亮度（0xRRGGBB；阈值 0.04045，同 mac NoteTaskBox / PaperMath）。</summary>
    public static double Luminance(int hex) => PaperMath.Luminance(hex);

    /// <summary>WCAG 对比度（1–21）。</summary>
    public static double Contrast(int a, int b)
    {
        var (x, y) = (Luminance(a), Luminance(b));
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }

    /// <summary>记号（对勾、感叹号）压在 fill 这个底上用什么色：白色和 ink 里对底对比度高的那个（一样高取白）。</summary>
    public static int Mark(int fill, int ink) => Contrast(0xFFFFFF, fill) >= Contrast(ink, fill) ? 0xFFFFFF : ink;

    /// <summary>top 以 opacity 叠在 bottom 上，混出来的不透明颜色（每个通道四舍五入）。</summary>
    public static int Mix(int top, int bottom, double opacity)
    {
        var result = 0;
        foreach (var shift in new[] { 16, 8, 0 })
        {
            var value = ((top >> shift) & 0xFF) * opacity + ((bottom >> shift) & 0xFF) * (1 - opacity);
            result |= (int)Math.Round(value, MidpointRounding.AwayFromZero) << shift;
        }

        return result;
    }

    // ---- 自定义纸色 ----

    /// <summary>从一个颜色推出整张纸：**挑的颜色就是浅色外观的纸**（色相、彩度照它，彩度上限 0.12；挑的本来就是合格的浅纸时一个
    /// 色值都不改）；太深的才往浅里提，提到亮度 ≥ 0.62。色条、墨和深色那套按 OKLCH 推：色条 = 纸的 L − 0.25（上限 0.70）、彩度两倍；
    /// 深纸 L 0.34（亮度超过 0.06 再往暗里压）。每样都是 sRGB 里取整之后的值。</summary>
    public static NotePaper Derived(int rgb)
    {
        var picked = PaperMath.Oklch(rgb);
        var chroma = Math.Min(picked.C, 0.12);
        if (chroma < 0.012)
        {
            chroma = 0;
        }

        var stripChroma = chroma > 0 ? Math.Min(chroma * 2, 0.19) : 0;
        var hue = picked.H;
        var lightness = Math.Max(picked.L, 0.84);
        var paper = PaperMath.Gamut(lightness, chroma, hue);
        // 挑的本来就是一张合格的浅纸：原样用（推回来的可能差 1/255）
        if (chroma == picked.C && lightness == picked.L && PaperMath.Luminance(rgb) >= 0.62)
        {
            paper = rgb & 0xFFFFFF;
        }

        while (PaperMath.Luminance(paper) < 0.62 && lightness < 0.985)
        {
            lightness += 0.005;
            paper = PaperMath.Gamut(lightness, chroma, hue);
        }

        var strip = PaperMath.Gamut(Math.Min(lightness - 0.25, 0.70), stripChroma, hue);
        var ink = PaperMath.Gamut(0.28, Math.Min(stripChroma * 0.35, 0.07), hue);
        var darkChroma = Math.Min(stripChroma * 0.4, 0.08);
        var darkLightness = 0.34;
        var darkPaper = PaperMath.Gamut(darkLightness, darkChroma, hue);
        while (PaperMath.Luminance(darkPaper) > 0.06 && darkLightness > 0.2)
        {
            darkLightness -= 0.005;
            darkPaper = PaperMath.Gamut(darkLightness, darkChroma, hue);
        }

        return new NotePaper(
            CustomName(paper),
            new NoteTone(paper, strip, ink),
            new NoteTone(darkPaper, PaperMath.Gamut(0.73, stripChroma, hue),
                PaperMath.Gamut(0.92, Math.Min(stripChroma * 0.3, 0.05), hue)));
    }

    /// <summary>和哪种预设最近：推出来的浅纸和 8 张预设浅纸在 OKLab 里的距离（一样近取靠前的）。落盘时 color 写它，
    /// 读回来时也拿它对一遍（Note.StoredPreset），两处必须是同一个函数。</summary>
    public static int NearestPreset(int rgb)
    {
        var paper = PaperMath.Oklab(Of(Note.Custom(rgb)).Light.Paper);
        var (best, bestDistance) = (0, double.PositiveInfinity);
        for (var index = 0; index < All.Count; index++)
        {
            var other = PaperMath.Oklab(All[index].Light.Paper);
            var distance = Math.Pow(paper.L - other.L, 2) + Math.Pow(paper.A - other.A, 2) + Math.Pow(paper.B - other.B, 2);
            if (distance < bestDistance)
            {
                (best, bestDistance) = (index, distance);
            }
        }

        return best;
    }

    /// <summary>自定义纸色的名字（菜单、读屏念它）：「自定义 · 蓝」——按 OKLCH 的色相分 12 个词，彩度很低的叫「灰」。</summary>
    public static string CustomName(int rgb)
    {
        var color = PaperMath.Oklch(rgb);
        if (color.C < 0.02)
        {
            return "自定义 · 灰";
        }

        foreach (var (upTo, word) in HueWords)
        {
            if (color.H < upTo)
            {
                return "自定义 · " + word;
            }
        }

        return "自定义 · 粉";
    }

    // ---- 颜色菜单（所有选颜色的地方共用一份，mac NotePaper.colorItems）----

    /// <summary>颜色菜单的一项。Color 是 Note.Color 的值；null = 「其他颜色…」（打开系统取色）。
    /// Section：0 = 8 种预设，1 = 自定义的，2 = 「其他颜色…」。</summary>
    public readonly record struct ColorChoice(string Id, string Title, int? Color, bool IsChecked, int Section);

    /// <summary>颜色菜单：8 种预设各一项（现在的那种打勾）｜自定义的（这条现在用的自定义色排第一，再是最近用过的，去重、
    /// 最多 RecentLimit 个，名字「自定义 · 蓝」）｜「其他颜色…」（other 是 false 时不放）。每项前面画它的纸色圆点：纸色的底 +
    /// 色条色的圈（Of(Color).Tone(dark)）。</summary>
    public static List<ColorChoice> ColorChoices(int current, IReadOnlyList<int>? recent = null, bool other = false)
    {
        var items = new List<ColorChoice>();
        for (var index = 0; index < All.Count; index++)
        {
            items.Add(new ColorChoice($"color-{index}", All[index].Name, index, index == current, 0));
        }

        var candidates = new List<int>();
        if (Note.CustomRgb(current) is { } mine)
        {
            candidates.Add(mine);
        }

        candidates.AddRange(recent ?? Array.Empty<int>());
        var seen = new HashSet<int>();
        var custom = 0;
        foreach (var rgb in candidates)
        {
            if (custom >= RecentLimit)
            {
                break;
            }

            if (!seen.Add(rgb))
            {
                continue;
            }

            var color = Note.Custom(rgb);
            items.Add(new ColorChoice($"color-{Note.Hex(rgb)}", Of(color).Name, color, color == current, 1));
            custom++;
        }

        if (other)
        {
            items.Add(new ColorChoice("color-other", OtherColorTitle, null, false, 2));
        }

        return items;
    }

    /// <summary>最近用过的自定义纸色（设置里存的「#RRGGBB」一组，最近的在前）：写坏的跳过。这台电脑自己的状态，不跟导出走。</summary>
    public static List<int> RecentColors(IEnumerable<string>? stored)
    {
        var colors = new List<int>();
        foreach (var text in stored ?? Array.Empty<string>())
        {
            if (Note.RgbFromHex(text) is { } rgb)
            {
                colors.Add(rgb);
            }
        }

        return colors;
    }

    /// <summary>挑了一次自定义色：挪到最前、去重、留 RecentLimit 个；给出要存回设置的那一组「#RRGGBB」。</summary>
    public static List<string> Remembered(int rgb, IEnumerable<string>? stored)
    {
        rgb &= 0xFFFFFF;
        var list = new List<int> { rgb };
        list.AddRange(RecentColors(stored).Where(value => value != rgb));
        return list.Take(RecentLimit).Select(Note.Hex).ToList();
    }
}

/// <summary>纸色推导用的颜色换算（sRGB ↔ 线性 ↔ OKLab / OKLCH，Björn Ottosson 公布的矩阵；同 mac PaperMath）。只算数；单测拿它造网格上的颜色。</summary>
public static class PaperMath
{
    public static (double R, double G, double B) Channels(int hex)
        => (((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0);

    public static double Linear(double value) => value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);

    public static double Encoded(double value) => value <= 0.0031308 ? 12.92 * value : 1.055 * Math.Pow(value, 1 / 2.4) - 0.055;

    /// <summary>WCAG 的相对亮度。</summary>
    public static double Luminance(int hex)
    {
        var (r, g, b) = Channels(hex);
        return 0.2126 * Linear(r) + 0.7152 * Linear(g) + 0.0722 * Linear(b);
    }

    public static (double L, double A, double B) Oklab(int hex)
    {
        var (r, g, b) = Channels(hex);
        var (lr, lg, lb) = (Linear(r), Linear(g), Linear(b));
        var l = Math.Cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
        var m = Math.Cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
        var s = Math.Cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
    }

    /// <summary>亮度 0–1、彩度、色相（度，0..&lt;360）。</summary>
    public static (double L, double C, double H) Oklch(int hex)
    {
        var (l, a, b) = Oklab(hex);
        var hue = Math.Atan2(b, a) * 180 / Math.PI;
        return (l, Math.Sqrt(a * a + b * b), hue < 0 ? hue + 360 : hue);
    }

    /// <summary>OKLCH → 线性的 sRGB（可能出界）。</summary>
    public static (double R, double G, double B) LinearRgb(double l, double c, double h)
    {
        var a = c * Math.Cos(h * Math.PI / 180);
        var b = c * Math.Sin(h * Math.PI / 180);
        var l3 = Math.Pow(l + 0.3963377774 * a + 0.2158037573 * b, 3);
        var m3 = Math.Pow(l - 0.1055613458 * a - 0.0638541728 * b, 3);
        var s3 = Math.Pow(l - 0.0894841775 * a - 1.2914855480 * b, 3);
        return (
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3);
    }

    /// <summary>这个亮度、色相上 sRGB 放得下的颜色：彩度放不下就往小里收（二分 30 次），给取整好的 0xRRGGBB。</summary>
    public static int Gamut(double l, double c, double h)
    {
        static bool Fits((double R, double G, double B) rgb)
            => rgb.R is >= -1e-6 and <= 1 + 1e-6 && rgb.G is >= -1e-6 and <= 1 + 1e-6 && rgb.B is >= -1e-6 and <= 1 + 1e-6;

        var chroma = c;
        if (!Fits(LinearRgb(l, c, h)))
        {
            var (low, high) = (0.0, c);
            for (var step = 0; step < 30; step++)
            {
                var middle = (low + high) / 2;
                if (Fits(LinearRgb(l, middle, h)))
                {
                    low = middle;
                }
                else
                {
                    high = middle;
                }
            }

            chroma = low;
        }

        var (r, g, b) = LinearRgb(l, chroma, h);
        static int Channel(double value)
            => (int)Math.Round(Encoded(Math.Min(Math.Max(value, 0), 1)) * 255, MidpointRounding.AwayFromZero);

        return Channel(r) << 16 | Channel(g) << 8 | Channel(b);
    }
}
