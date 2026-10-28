// PLAN-v9-clipboard 6a 的纯函数单测：内容形态、透镜定高表、标题显示全的判断、列表前缀和 / 吸顶 / 跟随滚动、
// 列表顺序（导入按时间插）、取消留下后是否超期。期望值能搬的照 mac ContentFormTests / SettingsArchiveTests 原样搬。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ClipboardAlignTests
{
    /// <summary>假的量字：汉字 14、其余 7（14 号 Segoe 大致的比例）。</summary>
    private static double Measure(string text) => text.Sum(ch => ch > 0x2E80 ? 14.0 : 7.0);

    private static double Body(string text, bool rich = false, bool snippet = false, bool favorite = false)
        => ClipLens.BodyHeight(
            ClipKind.Text,
            ContentForms.Detect(text),
            text,
            ClipLens.ShowsWholeText(text, rich, snippet, favorite, Measure));

    [TestMethod]
    public void ColorsParseLikeMac()
    {
        Assert.AreEqual(new Rgba(1, 0, 0, 1), ContentForms.Color(" #f00 "));
        Assert.AreEqual(0x80 / 255.0, ContentForms.Color("#00ff0080")!.Value.Alpha, 1e-9);
        Assert.AreEqual(new Rgba(0, 0, 1, 0.5), ContentForms.Color("rgba(0, 0, 255, 0.5)"));
        var green = ContentForms.Color("hsl(120, 100%, 50%)")!.Value;
        Assert.IsTrue(Math.Abs(green.Green - 1) < 0.001 && green.Red < 0.001);
        Assert.IsNull(ContentForms.Color("#12345"));
        Assert.IsNull(ContentForms.Color("rgb(1, 2)"));
        Assert.AreEqual(ContentForm.Color, ContentForms.Detect("#ABCDEF"));
    }

    [TestMethod]
    public void JsonLinkCodeLikeMac()
    {
        Assert.AreEqual(ContentForm.Json, ContentForms.Detect("{\"a\": [1, 2]}"));
        Assert.AreNotEqual(ContentForm.Json, ContentForms.Detect("{not json"));
        Assert.AreEqual(ContentForm.Link, ContentForms.Detect("https://example.com/a?b=1"));
        Assert.IsNull(ContentForms.Detect("看这个 https://example.com"));
        Assert.AreEqual("example.com", ContentForms.FirstLink("看这个 https://example.com/x。")?.Host);
        Assert.AreEqual(ContentForm.Code, ContentForms.Detect("import SwiftUI\nstruct A {}"));
        Assert.AreEqual(ContentForm.Code, ContentForms.Detect("SELECT *\nFROM t"));
        Assert.IsNull(ContentForms.Detect("今天天气不错\n明天也是"));
    }

    [TestMethod]
    public void LensHeightsLikeMac()
    {
        // 行标题已经原样显示全的一行字没有正文区：首尾空白、末尾的换行不算差别。
        Assert.AreEqual(0, Body("  一句短话  "));
        Assert.AreEqual(0, Body("git status\n"));
        Assert.AreEqual(70, ClipLens.Height(ClipKind.Text, null, "一句短话", showsWholeText: true));
        // 一行但标题列放不下、或者标题把连续空白压成了一个空格：两行高的正文。
        Assert.AreEqual(36, Body(new string('长', 60)));
        Assert.AreEqual(36, Body("a\tb"));
        Assert.AreEqual(90, Body(new string('长', 61)));
        Assert.AreEqual(90, Body("两行\n文本"));
        Assert.AreEqual(128, ClipLens.BodyHeight(ClipKind.Text, ContentForm.Code, "x", false));
        Assert.AreEqual(128, ClipLens.BodyHeight(ClipKind.Text, ContentForm.Json, "{}", false));
        Assert.AreEqual(72, ClipLens.BodyHeight(ClipKind.Text, ContentForm.Color, "#fff", false));
        Assert.AreEqual(90, ClipLens.BodyHeight(ClipKind.Text, ContentForm.Link, "https://a.com", false));
        Assert.AreEqual(108, ClipLens.BodyHeight(ClipKind.Image, null, null, false));
        Assert.AreEqual(76, ClipLens.BodyHeight(ClipKind.Files, null, null, false));
        Assert.AreEqual(198, ClipLens.Height(ClipKind.Text, ContentForm.Json, "{}", false));
    }

    [TestMethod]
    public void WholeTitleBudgetMatchesMac()
    {
        // 按宽度量、不按字数（原来只认 30 字以内）：45 个字母的一行放得下（315），25 个汉字也放得下（350）。
        Assert.AreEqual(0, Body("dotnet publish -c Release -r win-x64 --no-res"));
        // 截图里那句 60 字的 SQL 在最窄的标题列里放不下（420），照 mac 给两行高的正文。
        Assert.AreEqual(36, Body("SELECT id, text FROM clips ORDER BY copied_at DESC LIMIT 20;"));
        // 标记占地方：带格式 + 片段 + 收藏一共 34 + 26 + 26。
        Assert.AreEqual(86, ClipLens.MarkersWidth(rich: true, snippet: true, favorite: true));
        var tight = new string('字', 25); // 350，标题列最窄 352
        Assert.IsTrue(ClipLens.ShowsWholeText(tight, false, false, false, Measure));
        Assert.IsFalse(ClipLens.ShowsWholeText(tight, false, false, favorite: true, Measure));
        Assert.AreEqual("a b c", ClipLens.TextTitle("  a \n\t b   c "));
    }

    [TestMethod]
    public void LayoutIsAPrefixSum()
    {
        // 两天：今天 3 条、昨天 2 条；第 1 条（下标 1）展开透镜 198。
        var days = new long[] { 2, 2, 2, 1, 1 };
        var layout = new ClipListLayout(days, lensItem: 1, lensHeight: 198);
        Assert.AreEqual(7, layout.Entries.Count);
        CollectionAssert.AreEqual(new[] { 3, 2 }, layout.SectionCounts.ToArray());
        Assert.AreEqual(24, layout.RowTop(0));
        Assert.AreEqual(64, layout.RowTop(1));
        Assert.AreEqual(64 + 198, layout.RowTop(2));
        Assert.AreEqual(64 + 198 + 40, layout.SectionTops[1]);
        Assert.AreEqual(24 * 2 + 40 * 4 + 198, layout.TotalHeight);
        // 透镜换到别的行，总高不变（窗口不跟着动）。
        Assert.AreEqual(layout.TotalHeight, new ClipListLayout(days, 4, 198).TotalHeight);

        // 片段范围第一行「＋ 新建片段」。
        var snippets = new ClipListLayout(new long[] { 5 }, -1, 0, newSnippetRow: true);
        Assert.AreEqual(ClipListEntryKind.NewSnippet, snippets.Entries[0].Kind);
        Assert.AreEqual(40 + 24, snippets.RowTop(0));
    }

    [TestMethod]
    public void StickyHeaderIsPushedUpByTheNextOne()
    {
        var layout = new ClipListLayout(new long[] { 2, 2, 2, 1, 1 }, -1, 0);
        // 第二组标题在 24 + 3 × 40 = 144。
        Assert.AreEqual(144, layout.SectionTops[1]);
        Assert.AreEqual((-1, 0.0), layout.Sticky(0));
        Assert.AreEqual((0, 50.0), layout.Sticky(50 + ClipListLayout.Inset));
        // 滚到 130：第二组的标题（144）离顶只有 14，把第一组的推上去 10。
        Assert.AreEqual((0, 120.0), layout.Sticky(130 + ClipListLayout.Inset));
        Assert.AreEqual((1, 150.0), layout.Sticky(150 + ClipListLayout.Inset));
    }

    [TestMethod]
    public void WindowAndRevealFollowPrefixSums()
    {
        var days = Enumerable.Repeat(1L, 5000).ToArray();
        var layout = new ClipListLayout(days, 4000, 198);
        var top = layout.RowTop(4000);
        var (first, end) = layout.Window(top, 400);
        Assert.IsTrue(layout.Entries[first].Kind == ClipListEntryKind.Header || layout.Top(first) <= top - 320);
        Assert.IsTrue(end - first < 40, $"只实例化可见区附近的项（{end - first}）");

        // 往下：行底对齐、留出下内缩。
        var down = layout.Reveal(4000, 0, 400)!.Value;
        Assert.AreEqual(top + ClipListLayout.Inset + 198 + ClipListLayout.Inset - 400, down, 1e-9);
        // 往上：行的上面让出吸顶标题 24。
        var up = layout.Reveal(4000, top + 500, 400)!.Value;
        Assert.AreEqual(top + ClipListLayout.Inset - ClipListLayout.HeaderHeight, up, 1e-9);
        // 看得见就不滚；第一条往上滚到顶。
        Assert.IsNull(layout.Reveal(4000, down, 400));
        Assert.AreEqual(0, layout.Reveal(0, 300, 400));
    }

    [TestMethod]
    public void AdoptedClipsKeepFileOrderForEqualTimestamps()
    {
        // 照 mac adoptKeepsFileOrderForEqualTimestamps：文件里同一秒的 A、B、C（新→旧），已有一条更新的 X、一条更旧的 Y。
        var items = new List<(long Time, long Id, string Name)> { (2000, 1, "X"), (500, 2, "Y") };
        var file = new[] { ("A", 1000L), ("B", 1000L), ("C", 1000L) };
        var nextId = 3L;
        foreach (var (name, time) in file.Reverse().OrderBy(clip => clip.Item2))
        {
            var id = nextId++;
            items.Insert(ClipOrder.InsertIndex(items, item => item.Time, item => item.Id, time, id), (time, id, name));
        }

        CollectionAssert.AreEqual(new[] { "X", "A", "B", "C", "Y" }, items.Select(item => item.Name).ToArray());
        // 和库里 copied_at DESC, rowid DESC 读回来的一样。
        var fromDatabase = items.OrderByDescending(item => item.Time).ThenByDescending(item => item.Id).Select(item => item.Name);
        CollectionAssert.AreEqual(items.Select(item => item.Name).ToArray(), fromDatabase.ToArray());
    }

    [TestMethod]
    public void UnretainedClipExpiresOnlyPastTheRetentionDays()
    {
        var limits = new RetentionLimits(7, 0);
        var now = 100L * 86_400_000;
        Assert.IsTrue(Retention.IsExpired(now - 8L * 86_400_000, limits, now));
        Assert.IsFalse(Retention.IsExpired(now - 6L * 86_400_000, limits, now));
        Assert.IsFalse(Retention.IsExpired(0, new RetentionLimits(0, 0), now));
        // 备份只留「留下的」：片段没收藏也留（同 mac retainedSQL）。
        StringAssert.Contains(BackupPlan.DroppedStatements(true)[0], "snippet = 1");
    }
}
