// 便签正文里的图片令牌（Core/Notes/NoteImages.cs）的单测，照 mac NoteImagesTests.swift 全部移植，期望值原样：拼 / 认 / 写坏的不认 /
// 宽度越界当没写 / 宽度五档 / 一行里好几张 / 摘要里换「[图片]」/ 只有图片的行 / 找引用的编号 / 插图的落点 / 标题和摘要里的图片 / 随机往返。
// 和 mac 不一样的一处：randomTextRoundTrips 的伪随机数还是同一个 LCG、同一个种子，但「取几段、取哪一段、宽度多少」的取法和 Swift 的
// Int.random(in:using:) / randomElement 不一样，所以生成的那 3000 条不是 mac 那 3000 条——验的规则（认出来再拼回去逐字一样、Display 每段
// 换成 4 个字）照搬。没有跳过的用例。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteImagesTests
{
    private static readonly Guid Id = Guid.Parse("11111111-2222-3333-4444-555555555555");
    private static readonly Guid Other = Guid.Parse("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE");

    private static string Token(Guid id, string ext = "png", int? width = null) => NoteImages.Token(new NoteImages.Image(id, ext, width));

    private static Note Make(string body, string title = "") => new() { Id = "n", Title = title, Body = body };

    // ---- 拼和认 ----

    [TestMethod]
    public void TokenRoundTrips()
    {
        var plain = Token(Id);
        Assert.AreEqual("![image](kitty-note-image://11111111-2222-3333-4444-555555555555.png)", plain);
        var sized = Token(Id, "jpg", 240);
        Assert.AreEqual("![image|240](kitty-note-image://11111111-2222-3333-4444-555555555555.jpg)", sized);
        foreach (var text in new[] { plain, sized })
        {
            var found = NoteImages.Matches(text);
            Assert.AreEqual(1, found.Count);
            Assert.AreEqual(text, NoteImages.Token(found[0].Image));
        }

        Assert.AreEqual(Id, NoteImages.Matches(plain)[0].Image.Id);
        Assert.AreEqual(240, NoteImages.Matches(sized)[0].Image.Width);
        Assert.AreEqual("jpg", NoteImages.Matches(sized)[0].Image.Ext);
    }

    [TestMethod]
    public void WidthOutOfRangeCountsAsNoWidth()
    {
        // 写坏了（< 40 或 > 4000）的宽度按没写处理，但令牌本身照认
        foreach (var width in new[] { 0, 1, 39, 4001, 999999, 123_456_789 })
        {
            var found = NoteImages.Matches($"![image|{width}](kitty-note-image://{NoteImages.IdText(Id)}.png)");
            Assert.AreEqual(1, found.Count, $"宽度 {width} 应该还认得出是令牌");
            Assert.IsNull(found[0].Image.Width, $"宽度 {width} 应该当没写");
        }

        Assert.AreEqual(40, NoteImages.Width(40));
        Assert.AreEqual(4000, NoteImages.Width(4000));
        Assert.IsNull(NoteImages.Width(39));
        Assert.IsNull(NoteImages.Width(null));
    }

    /// <summary>宽度五档：存的是点数，铺满 = 上限 4000、原始大小 = 不记；拖出来的宽度不是任何一档。</summary>
    [TestMethod]
    public void WidthPresets()
    {
        CollectionAssert.AreEqual(new[] { "小", "中", "大", "铺满", "原始大小" }, NoteImages.Presets.Select(NoteImages.Title).ToList());
        CollectionAssert.AreEqual(new int?[] { 120, 240, 360, 4000, null }, NoteImages.Presets.Select(NoteImages.WidthOf).ToList());
        foreach (var preset in NoteImages.Presets)
        {
            Assert.AreEqual(preset, NoteImages.PresetOf(NoteImages.WidthOf(preset)));
            // 每一档的宽度都认得出、拼回去不变
            Assert.AreEqual(NoteImages.WidthOf(preset), NoteImages.Matches(Token(Id, width: NoteImages.WidthOf(preset)))[0].Image.Width);
        }

        Assert.IsNull(NoteImages.PresetOf(200));
        Assert.IsNull(NoteImages.PresetOf(3999));
    }

    [TestMethod]
    public void MalformedTokensArePlainText()
    {
        var bad = new[]
        {
            "![image](kitty-note-image://11111111-2222-3333-4444-555555555555)", // 没有扩展名
            "![image](kitty-note-image://11111111-2222-3333-4444-55555555555.png)", // UUID 短一位
            "![image](kitty-note-image://11111111-2222-3333-4444-55555555555g.png)", // UUID 里有 g
            "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.PNG)", // 大写的扩展名
            "![image](kitty-note-image://11111111222233334444555555555555.png)", // UUID 没有短横线
            "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.png", // 少了右括号
            "[image](kitty-note-image://11111111-2222-3333-4444-555555555555.png)", // 少了感叹号
            "![image](kitty-note-image:/11111111-2222-3333-4444-555555555555.png)", // 地址前缀不对
            "![image|](kitty-note-image://11111111-2222-3333-4444-555555555555.png)", // 空宽度
            "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.abcdefghijk)", // 扩展名太长
            "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.p-ng)", // 扩展名里有短横线
        };
        foreach (var text in bad)
        {
            // ContainsToken 只是便宜的预筛（认不认由 Match 决定），所以只比 Matches
            Assert.AreEqual(0, NoteImages.Matches(text).Count, text);
            Assert.AreEqual(0, NoteImages.Ids(text).Count, text);
            Assert.AreEqual(text, NoteImages.Display(text), text);
        }

        // 令牌后面紧跟着别的字照认（令牌到右括号为止，后面的是普通文字）
        var followed = $"![image](kitty-note-image://{NoteImages.IdText(Id)}.png)x";
        Assert.AreEqual(1, NoteImages.Matches(followed).Count);
        Assert.AreEqual("[图片]x", NoteImages.Display(followed));
        // 小写 UUID 也不认（存的一律大写）
        Assert.AreEqual(0, NoteImages.Matches("![image](kitty-note-image://11111111-2222-3333-4444-55555555555a.png)").Count);
    }

    [TestMethod]
    public void FindsSeveralTokensInOneLine()
    {
        var text = $"前面{Token(Id)}中间{Token(Other, "gif", 80)}后面";
        var found = NoteImages.Matches(text);
        Assert.AreEqual(2, found.Count);
        CollectionAssert.AreEqual(new[] { Id, Other }, found.Select(match => match.Image.Id).ToList());
        Assert.IsTrue(NoteImages.Ids(text).SetEquals(new[] { Id, Other }));
        Assert.AreEqual(Id, NoteImages.First(text)?.Id);
        Assert.IsTrue(NoteImages.ContainsToken(text));
        Assert.IsFalse(NoteImages.ContainsToken("没有图片的一段话"));
        Assert.AreEqual(0, NoteImages.Ids("没有图片").Count);
        Assert.IsNull(NoteImages.First("没有图片"));
    }

    [TestMethod]
    public void ImageCoveringAnIndex()
    {
        var text = $"ab{Token(Id)}cd";
        Assert.IsNull(NoteImages.ImageCovering(text, 0));
        Assert.AreEqual(Id, NoteImages.ImageCovering(text, 2)?.Id); // 令牌的第一个字
        Assert.AreEqual(Id, NoteImages.ImageCovering(text, 20)?.Id); // 令牌中间
        Assert.IsNull(NoteImages.ImageCovering(text, text.Length - 1));
    }

    [TestMethod]
    public void DisplayReplacesTokens()
    {
        var text = $"第一行\n{Token(Id)}\n前面{Token(Other, "jpg", 120)}后面";
        Assert.AreEqual("第一行\n[图片]\n前面[图片]后面", NoteImages.Display(text));
        Assert.AreEqual("没有图片", NoteImages.Display("没有图片"));
        Assert.AreEqual("[图片]", NoteImages.Display(Token(Id)));
    }

    [TestMethod]
    public void ImageOnlyLines()
    {
        Assert.IsTrue(NoteImages.IsImageOnly(Token(Id)));
        Assert.IsTrue(NoteImages.IsImageOnly($"  {Token(Id)}  "));
        Assert.IsTrue(NoteImages.IsImageOnly(Token(Id) + Token(Other)));
        Assert.IsFalse(NoteImages.IsImageOnly($"文字{Token(Id)}"));
        Assert.IsFalse(NoteImages.IsImageOnly($"{Token(Id)}文字"));
        Assert.IsFalse(NoteImages.IsImageOnly("普通的行"));
        Assert.IsFalse(NoteImages.IsImageOnly("![image](写坏的)"));
    }

    /// <summary>墙卡片那段字：只有图片的行整行去掉（连换行）、行内的令牌换成「[图片]」——在截取之前做。</summary>
    [TestMethod]
    public void DisplayLinesDropsImageOnlyLines()
    {
        var body = $"买菜\n{Token(Id)}\n前面{Token(Other)}后面\n\n末行";
        Assert.AreEqual("买菜\n前面[图片]后面\n\n末行", NoteImages.DisplayLines(body));
        // 整条只有图：出来是空的
        Assert.AreEqual(string.Empty, NoteImages.DisplayLines($"{Token(Id)}\n{Token(Other)}"));
        Assert.AreEqual("没有图片", NoteImages.DisplayLines("没有图片"));
        // 令牌紧贴行尾 / 行首
        Assert.AreEqual("[图片]买菜", NoteImages.DisplayLines($"{Token(Id)}买菜"));
        Assert.AreEqual("买菜[图片]", NoteImages.DisplayLines($"买菜{Token(Id)}"));
        // 去掉令牌（字数、搜索用）
        Assert.AreEqual("前面后面", NoteImages.Stripping($"前面{Token(Id)}后面"));
        Assert.AreEqual(string.Empty, NoteImages.Stripping(Token(Id)));
        Assert.AreEqual("没有图片", NoteImages.Stripping("没有图片"));
    }

    /// <summary>宽度写法被规范化：`|0040` 认得出、拼回去是 `|40`；`|39` 越界当没写、拼回去没有那一段。</summary>
    [TestMethod]
    public void WidthNotationIsNormalised()
    {
        var found = NoteImages.Matches($"![image|0040](kitty-note-image://{NoteImages.IdText(Id)}.png)");
        Assert.AreEqual(1, found.Count);
        Assert.AreEqual(40, found[0].Image.Width);
        Assert.AreEqual(Token(Id, width: 40), NoteImages.Token(found[0].Image));
        var tooSmall = NoteImages.Matches($"![image|39](kitty-note-image://{NoteImages.IdText(Id)}.png)");
        Assert.IsNull(tooSmall[0].Image.Width);
        Assert.AreEqual(Token(Id), NoteImages.Token(tooSmall[0].Image));
    }

    // ---- 插图插在哪 ----

    private static NoteImages.Insertion Plan(string text, int location, int count, int length = 0)
        => NoteImages.InsertionPlan(text, new NoteRange(location, length), count);

    [TestMethod]
    public void InsertionOnItsOwnLine()
    {
        const string text = "第一行\n第二行\n第三行";
        // 行首：前面不用换行；图后面总要有一个换行
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan(text, 4, 1));
        // 行中：前后都要换行
        Assert.AreEqual(new NoteImages.Insertion(true, true, 3), Plan(text, 6, 1));
        // 行尾（换行之前）：前面要换行、后面也补一个换行
        Assert.AreEqual(new NoteImages.Insertion(true, true, 3), Plan(text, 7, 1));
        // 连插三张：1 个前导换行 + 3 个附件字符 + 2 个图之间的换行 + 末尾 1 个换行
        Assert.AreEqual(new NoteImages.Insertion(true, true, 7), Plan(text, 7, 3));
    }

    [TestMethod]
    public void InsertionReplacesSelectionAndHandlesEmptyText()
    {
        // 有选区：整段换掉，图后面补一个换行
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan("abc", 0, 1, length: 3));
        // 空的正文
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan(string.Empty, 0, 1));
        // 只有空白的一行：不改出多余的空行
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan("   ", 2, 1));
    }

    /// <summary>光标夹在 \r\n 两个字中间时：不许算出负的长度、不许越界。</summary>
    [TestMethod]
    public void InsertionBetweenCarriageReturnAndNewline()
    {
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan("a\r\nb", 2, 1));
        for (var at = 0; at <= 4; at++)
        {
            _ = Plan("a\r\nb", at, 2);
        }

        Assert.AreEqual(2, Plan("\r\n", 1, 1).Caret);
    }

    /// <summary>任务行里可以贴图：行首的方框 / 列表符号不算「前面有字」。</summary>
    [TestMethod]
    public void InsertionAfterATaskBoxGoesOnTheSameLine()
    {
        const string text = "☐ 买菜";
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan(text, 1, 1));
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan(text, 2, 1));
        Assert.AreEqual(new NoteImages.Insertion(true, true, 3), Plan(text, 4, 1));
        Assert.AreEqual(new NoteImages.Insertion(false, true, 2), Plan("- 一", 2, 1));
        Assert.IsFalse(NoteImages.HasContent("☐ "));
        Assert.IsTrue(NoteImages.HasContent("☐ 买"));
        Assert.IsTrue(NoteImages.HasContent("买菜"));
        Assert.IsFalse(NoteImages.HasContent("  "));
    }

    // ---- 标题和摘要里的图片 ----

    [TestMethod]
    public void TitlesAndPreviewsShowImages()
    {
        var image = Token(Id);
        // 整条便签只有图片：标题是「[图片]」
        Assert.AreEqual(NoteImages.Placeholder, Make(image).DisplayTitle);
        Assert.AreEqual(NoteImages.Placeholder, Make($"{image}\n{Token(Other)}").DisplayTitle);
        // 只有图片的行跳过，标题用下一行有字的
        Assert.AreEqual("买菜", Make($"{image}\n买菜").DisplayTitle);
        Assert.AreEqual("第一行", Make($"第一行\n{image}\n第三行").DisplayTitle);
        // 和字同一行的图：标题里整个去掉，留下的连串空白收成一个
        Assert.AreEqual("前面后面", Make($"前面{image}后面").DisplayTitle);
        Assert.AreEqual("测试图片 123", Make($"测试图片 {image} [123]{{orange}}").DisplayTitle);
        Assert.AreEqual("标题行", Make("标题行").DisplayTitle);
        // 摘要：图片写成「[图片]」；第一行是图时先跳过只有图片的行、再跳过标题那一行
        Assert.AreEqual("[图片] 牛奶", Make($"{image}\n买菜\n牛奶").Preview);
        Assert.AreEqual("[图片] 牛奶", Make($"买菜\n{image}\n牛奶").Preview, "图片行照留，标题那一行不重复");
        Assert.AreEqual("[图片]后面", Make($"买菜\n{image}后面").Preview);
        Assert.AreEqual("[图片]", Make($"买菜\n{image}").Preview);
        // 整条只有图片：标题已经是「[图片]」，摘要空着
        Assert.AreEqual(string.Empty, Make(image).Preview);
        Assert.AreEqual(string.Empty, Make($"{image}\n{Token(Other)}").Preview);
        // 写坏的令牌当普通文字（原样去标记）
        Assert.AreEqual("![image](写坏的)", Make("![image](写坏的)").DisplayTitle);
        // 代码块内容行里的令牌也不许露原文
        Assert.AreEqual(NoteImages.Placeholder, Make($"```\n{image}\n```").DisplayTitle);
        Assert.AreEqual("买菜", Make($"```\n买菜{image}\n```").DisplayTitle);
        // 最近删除里只读的那份正文（令牌换成「[图片]」）
        Assert.AreEqual(NoteImages.Placeholder, Make(image).ReadOnlyBody);
        Assert.AreEqual("前面[图片]后面\n第二行", Make($"前面{image}后面\n第二行").ReadOnlyBody);
        // 自己起了标题就用自己起的
        Assert.AreEqual("我起的", Make(image, "我起的").DisplayTitle);
    }

    // ---- 随机往返 ----

    [TestMethod]
    public void RandomTextRoundTrips()
    {
        // 固定种子（同 mac SeededRandom：state = seed | 1，LCG）：失败了能照着同一个种子复现
        var state = 20_261_016UL | 1;
        ulong Next()
        {
            state = unchecked(state * 6_364_136_223_846_793_005UL + 1_442_695_040_888_963_407UL);
            return state;
        }

        int Between(int low, int high) => low + (int)(Next() % (ulong)(high - low + 1));
        bool Coin() => Next() >> 63 == 1;

        var pieces = new[] { "abc", "中文", "\n", " ", "![", "](", "kitty-note-image://", "**粗**", "- [ ] ", "2*3*4", "（《", "\U0001F600" };
        var extensions = new[] { "png", "jpg", "gif", "heic" };
        for (var step = 0; step < 3000; step++)
        {
            var text = string.Empty;
            for (var piece = Between(0, 8); piece > 0; piece--)
            {
                text += Coin()
                    ? Token(Guid.NewGuid(), extensions[Between(0, extensions.Length - 1)], Coin() ? Between(40, 4000) : null)
                    : pieces[Between(0, pieces.Length - 1)];
            }

            var found = NoteImages.Matches(text);
            // 认出来的令牌拼回去，和原文一模一样（认出来的位置互不相交、按顺序）
            var rebuilt = new System.Text.StringBuilder();
            var last = 0;
            foreach (var (range, image) in found)
            {
                Assert.IsTrue(range.Location >= last, $"第 {step} 条：区间应该从前到后");
                rebuilt.Append(text, last, range.Location - last).Append(NoteImages.Token(image));
                last = range.End;
            }

            rebuilt.Append(text, last, text.Length - last);
            Assert.AreEqual(text, rebuilt.ToString(), $"第 {step} 条：往返不一样");
            // Display 把每一段令牌都换成「[图片]」（4 个 UTF-16）
            Assert.AreEqual(text.Length - found.Sum(match => match.Range.Length - 4), NoteImages.Display(text).Length);
        }
    }
}
