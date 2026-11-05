// 便签纸色（Core/Notes/NotePaper.cs）的单测，照 mac：
// - NoteCustomPaperTests.swift：presetsDeriveToThemselves、everyCustomPaperPassesTheThresholds、lightPicksAreKeptAndDarkOnesLifted、
//   customPapersHaveSpokenNames、colorValuesInMemory、recentColorsKeepTheLatestEight、pickedColorsBecomePaperValues（只留 Note.Picked 那一半）、
//   colorMenuHasCustomColorsAndOtherColors（菜单条目换成纯函数 ColorChoices）。
// - NotesWindowTests.swift：paperTable（动态色在两种外观下取到的值换成 NoteShade；另加增强对比度那一档——mac 那边验不了）、
//   colorMenuHasADotForEveryPaper 里纯函数的那一半。
// - NoteDeckTests.swift：tabTintKeepsInkReadable（纸色的门槛，放在这里）。
// 跳过的（mac 测的东西 Windows 这一层没有，或要库 / 窗口 / 系统取色面板）：
// - databaseKeepsTheTintBesideThePreset、oldDatabasesGetTheColumn、newNotesRotateThroughPresets（便签库）；
// - exportFilesCarryTheTint、markdownHeaderCarriesTheTint、markdownExportImportKeepsTheTint（导出文件、Markdown 文件头）；
// - liveColorChangesWaitForTheQuietSave、deckMenuPicksOtherColors、windowMenuPicksOtherColors、colorPickerStateFollowsItsOwner、
//   sheetChangeClosesThePicker、bodyIgnoresColorPanelChanges（取色面板、那叠和窗口的模型、正文编辑器）；
// - pickedColorsBecomePaperValues 里 NSColor → 色值那一半（P3 / 灰度的换算是 AppKit 的）；recentColorsKeepTheLatestEight 里
//   「偏好里存的不是一组字」那一条（Windows 设置里是 List<string>，存不进别的类型）、注册默认值那一条；
// - colorValuesInMemory 里 NotesWindowModel.nextColor；paperTable 里 swatch（菜单圆点的图）。
using KittyTools.Core;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NotePaperTests
{
    // ---- 门槛（对任意一张纸）----

    /// <summary>HSB 的色相（度；灰的是 0），同 mac NSColor.hueComponent × 360。</summary>
    private static double Hue(int hex)
    {
        var (r, g, b) = PaperMath.Channels(hex);
        var max = Math.Max(r, Math.Max(g, b));
        var delta = max - Math.Min(r, Math.Min(g, b));
        if (delta == 0)
        {
            return 0;
        }

        var hue = max == r ? (g - b) / delta : max == g ? (b - r) / delta + 2 : (r - g) / delta + 4;
        hue *= 60;
        return hue < 0 ? hue + 360 : hue;
    }

    private static double HueGap(int a, int b)
    {
        var gap = Math.Abs(Hue(a) - Hue(b));
        return Math.Min(gap, 360 - gap);
    }

    /// <summary>这张纸过不了的门槛（空 = 全过）。和锁预设的几条测试同一组数（mac NoteCustomPaperTests.problems）。</summary>
    private static List<string> Problems(NotePaper paper)
    {
        static double C(int a, int b) => NotePaper.Contrast(a, b);
        var found = new List<string>();
        foreach (var (tone, name, isDark) in new[] { (paper.Light, "浅", false), (paper.Dark, "深", true) })
        {
            if (C(tone.Ink, tone.Paper) < 7)
            {
                found.Add($"{name} 墨");
            }

            if (C(NotePaper.Mix(tone.Ink, tone.Paper, NotePaper.SecondaryOpacity), tone.Paper) < 4.5)
            {
                found.Add($"{name} 次要");
            }

            if (C(tone.Strip, tone.Paper) < 1.5)
            {
                found.Add($"{name} 色条");
            }

            if (C(tone.Ink, NotePaper.Mix(tone.Ink, tone.Paper, NotePaper.CodeFillOpacity)) < 7)
            {
                found.Add($"{name} 代码");
            }

            if (C(tone.Ink, NotePaper.Mix(tone.Strip, tone.Paper, NotePaper.TabTint)) < 4.5)
            {
                found.Add($"{name} 标签");
            }

            if (C(NotePaper.Mix(tone.Ink, tone.Paper, NotePaper.TaskStrokeOpacity), tone.Paper) < 3)
            {
                found.Add($"{name} 方框描边");
            }

            if (C(NotePaper.Mark(tone.Strip, paper.Light.Ink), tone.Strip) < 3)
            {
                found.Add($"{name} 对勾");
            }

            var red = isDark ? NoteColors.Dark(NoteColor.Red) : NoteColors.Light(NoteColor.Red);
            if (C(NotePaper.Mark(red, paper.Light.Ink), red) < 3)
            {
                found.Add($"{name} 感叹号");
            }

            foreach (var color in NoteColors.All)
            {
                if (C(isDark ? NoteColors.Dark(color) : NoteColors.Light(color), tone.Paper) < 4.5)
                {
                    found.Add($"{name} 文字颜色 {NoteColors.Name(color)}");
                }
            }
        }

        if (NotePaper.Luminance(paper.Light.Paper) <= 0.6)
        {
            found.Add("浅纸太暗");
        }

        if (NotePaper.Luminance(paper.Dark.Paper) >= 0.08)
        {
            found.Add("深纸太亮");
        }

        // 同一个色相：两套的色条在 HSB 里的色相差 ≤ 25°
        if (HueGap(paper.Light.Strip, paper.Dark.Strip) > 25)
        {
            found.Add($"色相差 {(int)HueGap(paper.Light.Strip, paper.Dark.Strip)}");
        }

        return found;
    }

    // ---- 推导 ----

    /// <summary>8 张预设：浅纸进去出来一模一样，也认得出自己是哪一种；预设本身也过同一组门槛。</summary>
    [TestMethod]
    public void PresetsDeriveToThemselves()
    {
        for (var index = 0; index < NotePaper.All.Count; index++)
        {
            var preset = NotePaper.All[index];
            Assert.AreEqual(preset.Light.Paper, NotePaper.Derived(preset.Light.Paper).Light.Paper, preset.Name);
            Assert.AreEqual(index, NotePaper.NearestPreset(preset.Light.Paper), preset.Name);
            var problems = Problems(preset);
            Assert.AreEqual(0, problems.Count, $"{preset.Name} {string.Join("、", problems)}");
        }
    }

    /// <summary>网格（色相每 2°、8 档彩度、6 档亮度）：每一张推出来的纸都过全部门槛；挑的本来就是一张合格的浅纸时一个色值都不改。</summary>
    [TestMethod]
    public void EveryCustomPaperPassesTheThresholds()
    {
        var failures = new List<string>();
        var (kept, count) = (0, 0);
        for (var hue = 0.0; hue < 360; hue += 2)
        {
            foreach (var chroma in new[] { 0, 0.02, 0.05, 0.08, 0.12, 0.16, 0.2, 0.3 })
            {
                foreach (var lightness in new[] { 0.3, 0.6, 0.85, 0.9, 0.95, 0.98 })
                {
                    var picked = PaperMath.Gamut(lightness, chroma, hue);
                    var paper = NotePaper.Derived(picked);
                    count++;
                    if (paper.Light.Paper == picked)
                    {
                        kept++;
                    }

                    var problems = Problems(paper);
                    if (problems.Count > 0 && failures.Count < 20)
                    {
                        failures.Add($"#{picked:X6} {string.Join("、", problems)}");
                    }
                }
            }
        }

        Assert.AreEqual(8640, count);
        Assert.AreEqual(0, failures.Count, string.Join("；", failures));
        // 原型里是 3834：浅色、不太艳的那一大片原样
        Assert.IsTrue(kept > 3000, $"原样的 {kept}");
        foreach (var extreme in new[] { 0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF })
        {
            var problems = Problems(NotePaper.Derived(extreme));
            Assert.AreEqual(0, problems.Count, $"#{extreme:X6} {string.Join("、", problems)}");
        }
    }

    /// <summary>挑的是浅色、不太艳：浅纸就是它；太深的往浅里提，色相不变。</summary>
    [TestMethod]
    public void LightPicksAreKeptAndDarkOnesLifted()
    {
        foreach (var pick in new[] { 0xFFE0F0, 0xE0F0FF, 0xF2F2E6, 0xFFF3C4 })
        {
            Assert.AreEqual(pick, NotePaper.Derived(pick).Light.Paper, $"#{pick:X6}");
        }

        const int navy = 0x203040;
        var lifted = NotePaper.Derived(navy).Light.Paper;
        Assert.IsTrue(NotePaper.Luminance(lifted) >= 0.62);
        var gap = Math.Abs(PaperMath.Oklch(lifted).H - PaperMath.Oklch(navy).H);
        Assert.IsTrue(Math.Min(gap, 360 - gap) < 3, "色相不变");
    }

    /// <summary>名字：按色相 12 个词，很灰的叫灰；缓存的和现推的一样。</summary>
    [TestMethod]
    public void CustomPapersHaveSpokenNames()
    {
        var cases = new (int Rgb, string Word)[]
        {
            (0xFF0000, "红"), (0xFFC0CB, "粉"), (0xFFA500, "橙"), (0xFFFF00, "黄"), (0x9ACD32, "黄绿"),
            (0x00FF00, "绿"), (0xB4E8D0, "青绿"), (0x00FFFF, "青"), (0x0000FF, "蓝"), (0x6A5ACD, "靛"),
            (0x8000FF, "紫"), (0xFF00FF, "品红"), (0x808080, "灰"), (0x000000, "灰"), (0xFFFFFF, "灰"),
        };
        foreach (var (rgb, word) in cases)
        {
            Assert.AreEqual($"自定义 · {word}", NotePaper.CustomName(rgb), $"#{rgb:X6}");
        }

        var paper = NotePaper.Of(Note.Custom(0xBEDDFA));
        Assert.AreEqual("自定义 · 蓝", paper.Name);
        Assert.AreEqual(0xBEDDFA, paper.Light.Paper);
        Assert.AreEqual(paper, NotePaper.Of(Note.Custom(0xBEDDFA)), "缓存的和现推的一样");
        Assert.AreEqual(paper, NotePaper.Derived(0xBEDDFA));
    }

    // ---- 内存里的写法（Note.cs 里的几个函数，和纸色是一起的）----

    [TestMethod]
    public void ColorValuesInMemory()
    {
        var custom = Note.Custom(0x12ABEF);
        Assert.AreEqual(0x12ABEF, Note.CustomRgb(custom));
        Assert.IsNull(Note.CustomRgb(3));
        Assert.IsNull(Note.CustomRgb(-1));
        Assert.IsNull(Note.CustomRgb(2 << 24));
        Assert.IsNull(Note.CustomRgb(int.MaxValue));
        Assert.AreEqual(custom, Note.Clamped(custom), "自定义的原样");
        Assert.AreEqual(7, Note.Clamped(99));
        Assert.AreEqual(0, Note.Clamped(-5));
        // 落盘的那个下标、读回来合起来
        var sky = Note.Custom(0xC2DFF8);
        Assert.AreEqual(4, Note.StoredPreset(sky), "最接近天蓝");
        Assert.AreEqual(5, Note.StoredPreset(5));
        Assert.AreEqual(7, Note.StoredPreset(42));
        // 文件里：色值合法就是自定义的
        Assert.AreEqual(sky, Note.ColorFrom(4, 0xC2DFF8));
        Assert.AreEqual(sky, Note.ColorFrom(0, 0xC2DFF8));
        Assert.AreEqual(4, Note.ColorFrom(4, null));
        Assert.AreEqual(4, Note.ColorFrom(4, 0x1000000));
        Assert.AreEqual(4, Note.ColorFrom(4, -1));
        Assert.AreEqual(7, Note.ColorFrom(99, null));
        // 库里：tint 记着写入时的预设，和 color 列对得上才算（不重算推导）
        const int packed = 4 << 24 | 0xC2DFF8;
        Assert.AreEqual(packed, Note.StoredTint(sky));
        Assert.IsNull(Note.StoredTint(4));
        Assert.AreEqual(sky, Note.ColorFromStored(4, packed));
        Assert.AreEqual(5, Note.ColorFromStored(5, packed), "对不上：旧版本换过颜色，按它换的");
        Assert.AreEqual(4, Note.ColorFromStored(4, null));
        Assert.AreEqual(4, Note.ColorFromStored(4, -1));
        // Ctrl+. 和新建便签只在预设里轮：自定义的从最接近的那种往下
        Assert.AreEqual(5, Note.NextPreset(sky));
        Assert.AreEqual(0, Note.NextPreset(7));
        // 文件里的写法
        Assert.AreEqual("#0A0B0C", Note.Hex(0x0A0B0C));
        Assert.AreEqual(0x0A0B0C, Note.RgbFromHex("#0a0B0c"));
        foreach (var bad in new[] { "0A0B0C", "#0A0B0", "#0A0B0C0", "#GG0000", "#+12345", "#-12345", "", "#" })
        {
            Assert.IsNull(Note.RgbFromHex(bad), bad);
        }
    }

    /// <summary>最近用过：挑一次挪到最前、去重、最多 8 个，写坏的跳过。</summary>
    [TestMethod]
    public void RecentColorsKeepTheLatestEight()
    {
        List<string>? stored = null;
        Assert.AreEqual(0, NotePaper.RecentColors(stored).Count);
        for (var rgb = 0; rgb < 10; rgb++)
        {
            stored = NotePaper.Remembered(0x100000 + rgb, stored);
        }

        CollectionAssert.AreEqual(Enumerable.Range(2, 8).Reverse().Select(rgb => 0x100000 + rgb).ToList(), NotePaper.RecentColors(stored));
        stored = NotePaper.Remembered(0x100004, stored);
        var list = NotePaper.RecentColors(stored);
        Assert.AreEqual(0x100004, list[0]);
        Assert.AreEqual(8, list.Count);
        Assert.AreEqual(8, list.Distinct().Count());
        CollectionAssert.AreEqual(new[] { 0xABCDEF }, NotePaper.RecentColors(new[] { "#zz", "#ABCDEF" }));
    }

    /// <summary>挑的正好是哪种预设的浅纸就是那种预设，不然是自定义的。</summary>
    [TestMethod]
    public void PickedColorsBecomePaperValues()
    {
        for (var index = 0; index < NotePaper.All.Count; index++)
        {
            Assert.AreEqual(index, Note.Picked(NotePaper.All[index].Light.Paper), NotePaper.All[index].Name);
        }

        Assert.AreEqual(Note.Custom(0xC2DFF8), Note.Picked(0xC2DFF8));
    }

    /// <summary>颜色菜单（所有选颜色的地方共用一份）：8 种预设｜自定义的（这条现在用的排第一个，再是最近用过的，去重、最多 8 个）｜其他颜色…；
    /// 现在的那种打勾。</summary>
    [TestMethod]
    public void ColorMenuHasCustomColorsAndOtherColors()
    {
        var sky = Note.Custom(0xC2DFF8);
        var recent = new[] { 0xFFE0F0, 0xC2DFF8 }.Concat(Enumerable.Range(0, 10).Select(offset => 0x200000 + offset)).ToList();
        var items = NotePaper.ColorChoices(sky, recent, other: true);
        Assert.AreEqual(Note.ColorCount + NotePaper.RecentLimit + 1, items.Count);
        var custom = items.Where(item => item.Section == 1).ToList();
        Assert.AreEqual(NotePaper.RecentLimit, custom.Count);
        Assert.AreEqual("自定义 · 蓝", custom[0].Title);
        Assert.IsTrue(custom[0].IsChecked);
        Assert.AreEqual("自定义 · 粉", custom[1].Title);
        Assert.IsTrue(custom.Skip(1).All(item => !item.IsChecked));
        Assert.IsTrue(items.Take(Note.ColorCount).All(item => !item.IsChecked));
        Assert.AreEqual(items.Count, items.Select(item => item.Id).Distinct().Count());
        Assert.AreEqual(Note.Custom(0xFFE0F0), custom[1].Color, "点了换成它");
        Assert.AreEqual(NotePaper.OtherColorTitle, items[^1].Title);
        Assert.AreEqual(2, items[^1].Section);
        Assert.IsNull(items[^1].Color);
        // 预设的、没有最近用过的：中间那一节是空的
        var plain = NotePaper.ColorChoices(3, Array.Empty<int>(), other: true);
        CollectionAssert.AreEqual(Enumerable.Repeat(0, Note.ColorCount).Append(2).ToList(), plain.Select(item => item.Section).ToList());
    }

    /// <summary>mac NotesWindowTests.colorMenuHasADotForEveryPaper 的纯函数那一半：8 种纸色各一项、现在的那种打勾；没给 other 就没有「其他颜色…」。</summary>
    [TestMethod]
    public void ColorMenuListsEveryPaper()
    {
        var items = NotePaper.ColorChoices(5);
        CollectionAssert.AreEqual(NotePaper.All.Select(paper => paper.Name).ToList(), items.Select(item => item.Title).ToList());
        CollectionAssert.AreEqual(Enumerable.Range(0, Note.ColorCount).Select(index => index == 5).ToList(), items.Select(item => item.IsChecked).ToList());
        Assert.AreEqual(Note.ColorCount, items.Select(item => item.Id).Distinct().Count());
        CollectionAssert.AreEqual(Enumerable.Range(0, Note.ColorCount).ToList(), items.Select(item => item.Color ?? -1).ToList());
    }

    // ---- 纸色表（mac NotesWindowTests.paperTable）----

    /// <summary>不取整的混色（mac paperTable 里的 mix：NSColor 的通道是小数）。</summary>
    private static (double R, double G, double B) MixExact(int top, int bottom, double opacity)
    {
        var (a, b) = (PaperMath.Channels(top), PaperMath.Channels(bottom));
        return (a.R * opacity + b.R * (1 - opacity), a.G * opacity + b.G * (1 - opacity), a.B * opacity + b.B * (1 - opacity));
    }

    /// <summary>WCAG 对比度（通道 0–1 的小数，阈值 0.03928，同 mac AccentPalette / NoteDeckTests.tabTintKeepsInkReadable）。</summary>
    private static double ContrastExact((double R, double G, double B) a, (double R, double G, double B) b)
    {
        static double Luminance((double R, double G, double B) color)
        {
            static double Linear(double value) => value <= 0.03928 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
            return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
        }

        var (x, y) = (Luminance(a), Luminance(b));
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }

    /// <summary>8 种纸色、名字不重；浅色那套是说明里给的值；墨对纸 ≥ 7:1、次要的字 ≥ 4.5:1、色条对纸 ≥ 1.5:1、墨压在代码的底上 ≥ 7:1；
    /// 各处取到的那一档；深纸深、浅纸浅；两套的色条同一个色相；越界的下标不崩。</summary>
    [TestMethod]
    public void PaperTable()
    {
        var papers = NotePaper.All;
        Assert.AreEqual(Note.ColorCount, papers.Count);
        CollectionAssert.AreEqual(new[] { "柠檬", "桃", "玫瑰", "丁香", "天蓝", "薄荷", "沙", "石板" }, papers.Select(paper => paper.Name).ToList());
        Assert.AreEqual(new NoteTone(0xFCE795, 0xE0AD08, 0x3A3008), papers[0].Light);
        Assert.AreEqual(new NoteTone(0xCBD6E2, 0x4E6579, 0x1A242E), papers[7].Light);
        // mac 这里还比了几个不透明度常量（0.35 / 0.6 / 0.08 / 0.75）：C# 里是 const，比它们是编译期就定了的断言（分析器会报），
        // 改成下面按外观取到的 NoteShade 里核对同样的几个数
        foreach (var paper in papers)
        {
            foreach (var (tone, name) in new[] { (paper.Light, "浅"), (paper.Dark, "深") })
            {
                var (ink, sheet) = (PaperMath.Channels(tone.Ink), PaperMath.Channels(tone.Paper));
                Assert.IsTrue(ContrastExact(ink, sheet) >= 7, $"{paper.Name} {name}");
                Assert.IsTrue(ContrastExact(MixExact(tone.Ink, tone.Paper, NotePaper.SecondaryOpacity), sheet) >= 4.5, $"{paper.Name} {name} 次要");
                Assert.IsTrue(ContrastExact(PaperMath.Channels(tone.Strip), sheet) >= 1.5, $"{paper.Name} {name} 色条");
                Assert.IsTrue(ContrastExact(ink, MixExact(tone.Ink, tone.Paper, NotePaper.CodeFillOpacity)) >= 7, $"{paper.Name} {name} 代码");
            }

            // 平时（没开增强对比度）两种外观下取到的：代码的底是墨的 8%、标记是墨的 35%、引用的竖线是色条色、引用的字是墨的 75%
            foreach (var dark in new[] { false, true })
            {
                var tone = paper.Tone(dark);
                var label = $"{paper.Name} {(dark ? "深" : "浅")}";
                Assert.AreEqual(new NoteShade(tone.Ink, 0.08), paper.CodeFill(dark), $"{label} 代码的底");
                Assert.AreEqual(new NoteShade(tone.Ink, 0.35), paper.MarkerInk(dark, false), $"{label} 标记");
                Assert.AreEqual(new NoteShade(tone.Strip, 1), paper.QuoteBar(dark, false), $"{label} 竖线");
                Assert.AreEqual(new NoteShade(tone.Ink, 0.75), paper.SecondaryInk(dark, false), $"{label} 引用");
                // 增强对比度那一档（mac 这一档在单测里取不到，这里直接验）：标记 60%、竖线换成墨、引用的字就是墨、代码的底不加深
                Assert.AreEqual(new NoteShade(tone.Ink, 0.6), paper.MarkerInk(dark, true), $"{label} 标记（增强对比度）");
                Assert.AreEqual(new NoteShade(tone.Ink, 1), paper.QuoteBar(dark, true), $"{label} 竖线（增强对比度）");
                Assert.AreEqual(new NoteShade(tone.Ink, 1), paper.SecondaryInk(dark, true), $"{label} 引用（增强对比度）");
                Assert.AreEqual(new NoteShade(tone.Ink, 0.5), paper.FadedInk(dark, false), $"{label} 做完");
                Assert.AreEqual(new NoteShade(tone.Ink, 0.75), paper.FadedInk(dark, true), $"{label} 做完（增强对比度）");
                Assert.AreEqual(tone.Paper, paper.TaskDoneMark(dark, true), $"{label} 对勾（增强对比度）");
            }

            // 深色外观下纸是深的、字是浅的
            Assert.IsTrue(AccentPalette.RelativeLuminance((uint)paper.Dark.Paper) < 0.08, paper.Name);
            Assert.IsTrue(AccentPalette.RelativeLuminance((uint)paper.Light.Paper) > 0.6, paper.Name);
            // 同一个色相（石板、沙这种灰的也在 25° 以内）
            Assert.IsTrue(HueGap(paper.Light.Strip, paper.Dark.Strip) <= 25, $"{paper.Name} 色相差 {HueGap(paper.Light.Strip, paper.Dark.Strip)}");
        }

        // 越界的下标不崩
        Assert.AreEqual(papers[7], NotePaper.Of(new Note { Id = "n", Color = 99 }));
        Assert.AreEqual(papers[0], NotePaper.Of(new Note { Id = "n", Color = -1 }));
        Assert.AreEqual(0x80FCE795u, new NoteShade(0xFCE795, 0.5).Argb);
    }

    /// <summary>打开的便签带着的那张标签（纸上叠一层色条色）：墨在上面仍够 4.5:1，两套都是（mac NoteDeckTests.tabTintKeepsInkReadable）。</summary>
    [TestMethod]
    public void TabTintKeepsInkReadable()
    {
        foreach (var paper in NotePaper.All)
        {
            foreach (var tone in new[] { paper.Light, paper.Dark })
            {
                var tinted = MixExact(tone.Strip, tone.Paper, NotePaper.TabTint);
                Assert.IsTrue(ContrastExact(tinted, PaperMath.Channels(tone.Ink)) >= 4.5, paper.Name);
            }

            Assert.AreEqual(NotePaper.Mix(paper.Light.Strip, paper.Light.Paper, NotePaper.TabTint), paper.TabFill(false));
        }
    }
}
