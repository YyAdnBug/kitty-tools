// 便签墙（Core/Notes/NoteWall.cs）的单测，照 mac NoteWallTests.swift 里测纯函数的用例：columnsFollowTheWidth、
// masonryPlacesIntoTheShortestColumn、sectionsStackWithHeaders、tiltIsStableAndAlternates、arrowKeysWalkTheWall、dragLandsWithinItsSection、
// dropTargetIsStable、dragWritesBackTheStoreOrder（仓库换成一个编号列表，挪法同 NoteStore.move）、editorSizeFollowsTheWindow、
// paperFollowsTheCardNow、excerptSkipsTheTitleLine（Excerpt 那一半）、cardTextAndHeight（高的那一半：量字的结果换成传进去的数）。
// 墙的坐标 mac 也是左上角为原点、y 向下，期望值原样，不用换算。
// 跳过的：arrowKeysMoveTheSelection、wallGroupsPinnedFirst、openingAndCollapsing、editingFollowsTheCurrentNote、focusWhenOpening、
// layoutPreference（全部便签窗口的模型）；arrivedImagesRebuildCards、cardsAreCachedPerNote、wallBuildsVisibleCardsFirst（仓库那一层的卡片缓存）；
// wallInTheWindow、collapsingReturnsFocusToTheWall、wallStaysPutWhileTheEditorOpens（真窗口）；excerptSkipsTheTitleLine 和 cardTextAndHeight 里
// 卡片上带样式的字（NoteStyles：删藏着的标记、粗体、代码的底、划线——那一步在窗口代码里）。
using KittyTools.Core;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteWallTests
{
    private static NoteWall.Section Section(string[] ids, double[] heights, string? title = null) => new(title, ids, heights);

    private static Note Make(string body, string title = "") => new() { Id = "n", Title = title, Body = body };

    private static readonly string Image = NoteImages.Token(
        new NoteImages.Image(Guid.Parse("11111111-2222-3333-4444-555555555555"), "png", null));

    // ---- 排 ----

    /// <summary>列宽固定：窗口宽一点就多一列；窄窗口两列、默认 940 三列、宽的四五列。</summary>
    [TestMethod]
    public void ColumnsFollowTheWidth()
    {
        Assert.AreEqual(1, NoteWall.ColumnCount(0));
        Assert.AreEqual(1, NoteWall.ColumnCount(300));
        Assert.AreEqual(2, NoteWall.ColumnCount(720));
        Assert.AreEqual(3, NoteWall.ColumnCount(940));
        Assert.AreEqual(4, NoteWall.ColumnCount(1200));
        Assert.AreEqual(5, NoteWall.ColumnCount(1280));
    }

    /// <summary>瀑布流：一张张放进当时最矮的那一列（一样矮取左边的），整块居中；墙的高 = 最高那列 + 底边。</summary>
    [TestMethod]
    public void MasonryPlacesIntoTheShortestColumn()
    {
        var layout = NoteWall.Arrange(new[] { Section(new[] { "a", "b", "c", "d", "e" }, new double[] { 100, 200, 150, 120, 80 }) }, 940);
        Assert.AreEqual(3, layout.ColumnCount);
        CollectionAssert.AreEqual(new[] { "a", "b", "c", "d", "e" }, layout.Ids.ToList());
        // 三列共 704 宽，(940 − 704) / 2 = 118
        CollectionAssert.AreEqual(new double[] { 118, 358, 598, 118, 598 }, layout.Frames.Select(frame => frame.X).ToList());
        CollectionAssert.AreEqual(new double[] { 20, 20, 20, 136, 186 }, layout.Frames.Select(frame => frame.Y).ToList());
        CollectionAssert.AreEqual(new double[] { 100, 200, 150, 120, 80 }, layout.Frames.Select(frame => frame.Height).ToList());
        Assert.IsTrue(layout.Frames.All(frame => frame.Width == NoteWall.CardWidth));
        CollectionAssert.AreEqual(new[] { 0, 1, 2, 0, 2 }, layout.Columns.ToList());
        Assert.AreEqual(286, layout.Height);
        Assert.AreEqual(0, layout.Headers.Count);
        CollectionAssert.AreEqual(new[] { new NoteRange(0, 5) }, layout.Sections.ToList());
        // 太窄：一列、贴着左边的边距
        var narrow = NoteWall.Arrange(new[] { Section(new[] { "a", "b" }, new double[] { 100, 100 }) }, 200);
        Assert.AreEqual(1, narrow.ColumnCount);
        CollectionAssert.AreEqual(new double[] { 20, 20 }, narrow.Frames.Select(frame => frame.X).ToList());
        CollectionAssert.AreEqual(new double[] { 20, 136 }, narrow.Frames.Select(frame => frame.Y).ToList());
        // 空的墙
        Assert.AreEqual(40, NoteWall.Arrange(Array.Empty<NoteWall.Section>(), 940).Height);
    }

    /// <summary>两段（固定的、其他）：各有一行小标题，第二段从第一段最低的那列下面再空一点开始；空的段连标题都不要。</summary>
    [TestMethod]
    public void SectionsStackWithHeaders()
    {
        var layout = NoteWall.Arrange(new[]
        {
            Section(new[] { "p" }, new double[] { 130 }, "已固定"), Section(Array.Empty<string>(), Array.Empty<double>(), "空的"),
            Section(new[] { "x", "y" }, new double[] { 100, 100 }, "其他"),
        }, 720);
        // 两列共 464 宽，(720 − 464) / 2 = 128
        CollectionAssert.AreEqual(new[] { "已固定", "其他" }, layout.Headers.Select(header => header.Title).ToList());
        Assert.AreEqual(new RectD(128, 20, 464, 24), layout.Headers[0].Frame);
        Assert.AreEqual(new PointD(128, 44), new PointD(layout.Frames[0].X, layout.Frames[0].Y));
        // 第一段到 44 + 130 = 174，再空 12：第二段的标题在 186、卡片从 210 起
        Assert.AreEqual(186, layout.Headers[1].Frame.Y);
        Assert.AreEqual(new PointD(128, 210), new PointD(layout.Frames[1].X, layout.Frames[1].Y));
        Assert.AreEqual(new PointD(368, 210), new PointD(layout.Frames[2].X, layout.Frames[2].Y));
        CollectionAssert.AreEqual(new[] { new NoteRange(0, 1), new NoteRange(1, 2) }, layout.Sections.ToList());
        Assert.AreEqual(330, layout.Height);
        Assert.AreEqual(0, layout.SectionOf(0));
        Assert.AreEqual(1, layout.SectionOf(2));
        Assert.IsNull(layout.SectionOf(9));
    }

    /// <summary>倾斜：大小按编号定（1–2°，每次一样），方向按位置交错——同一列上下挨着的、一段的第一排左右挨着的不同向。</summary>
    [TestMethod]
    public void TiltIsStableAndAlternates()
    {
        Assert.AreEqual(NoteWall.Tilt("A", 0, 0), NoteWall.Tilt("A", 0, 0));
        Assert.AreEqual(NoteWall.Tilt("A", 0, 0), -NoteWall.Tilt("A", 0, 1));
        var ids = Enumerable.Range(0, 200).Select(index => $"00000000-0000-0000-0000-{index:D12}").ToArray();
        var sizes = ids.Select(id => Math.Abs(NoteWall.Tilt(id, 0, 0))).ToList();
        Assert.IsTrue(sizes.All(size => size is >= 1 and <= 2));
        // 编号不同大小也不同（不是一个常数）
        Assert.IsTrue(sizes.Select(size => Math.Round(size * 100, MidpointRounding.AwayFromZero)).Distinct().Count() > 20);
        var layout = NoteWall.Arrange(
            new[] { Section(ids.Take(12).ToArray(), Enumerable.Range(0, 12).Select(index => 100.0 + index * 37 % 90).ToArray()) }, 940);
        for (var index = 0; index < layout.Ids.Count; index++)
        {
            // 同一列里下面紧挨着的那张
            int? below = null;
            for (var other = 0; other < layout.Ids.Count; other++)
            {
                if (layout.Columns[other] == layout.Columns[index] && layout.Frames[other].Y > layout.Frames[index].Y &&
                    (below is null || layout.Frames[other].Y < layout.Frames[below.Value].Y))
                {
                    below = other;
                }
            }

            if (below is { } next)
            {
                Assert.AreNotEqual(layout.Tilts[index] < 0, layout.Tilts[next] < 0);
            }
        }

        // 第一排左右挨着的不同向
        Assert.IsTrue(layout.Tilts[0] < 0 && layout.Tilts[1] > 0 && layout.Tilts[2] < 0);
    }

    // ---- 方向键 ----

    /// <summary>↑↓ 在同一列里走（这一列那边没有了去最近的列）；←→ 去旁边那列里竖直方向离得最近的；走不动是 null。</summary>
    [TestMethod]
    public void ArrowKeysWalkTheWall()
    {
        // a(列 0, 20–120) b(列 1, 20–220) c(列 2, 20–170) d(列 0, 136–256) e(列 2, 186–266)
        var layout = NoteWall.Arrange(new[] { Section(new[] { "a", "b", "c", "d", "e" }, new double[] { 100, 200, 150, 120, 80 }) }, 940);
        string? Go(string id, NoteWall.Direction direction)
            => NoteWall.Neighbor(layout.IndexOf(id)!.Value, direction, layout) is { } index ? layout.Ids[index] : null;

        Assert.AreEqual("d", Go("a", NoteWall.Direction.Down));
        Assert.AreEqual("e", Go("c", NoteWall.Direction.Down));
        Assert.AreEqual("d", Go("b", NoteWall.Direction.Down));
        Assert.AreEqual("e", Go("d", NoteWall.Direction.Down));
        Assert.IsNull(Go("e", NoteWall.Direction.Down));
        Assert.AreEqual("a", Go("d", NoteWall.Direction.Up));
        Assert.AreEqual("c", Go("e", NoteWall.Direction.Up));
        Assert.IsNull(Go("a", NoteWall.Direction.Up));
        Assert.AreEqual("b", Go("a", NoteWall.Direction.Right));
        Assert.AreEqual("b", Go("d", NoteWall.Direction.Right));
        Assert.AreEqual("c", Go("b", NoteWall.Direction.Right));
        Assert.AreEqual("b", Go("e", NoteWall.Direction.Left));
        Assert.AreEqual("a", Go("b", NoteWall.Direction.Left));
        Assert.IsNull(Go("a", NoteWall.Direction.Left));
        Assert.IsNull(Go("c", NoteWall.Direction.Right));
        Assert.IsNull(NoteWall.Neighbor(9, NoteWall.Direction.Down, layout));
    }

    // ---- 拖动排序 ----

    [TestMethod]
    public void CardLinesDrawHeadingsAndBulletsWithoutMarkers()
    {
        // PLAN-v16 V2：标题去掉 # 按几级画、列表符号换成圆点（缩进留着）、代码块的围栏行不要、块里的行原样、别的行去掉行内标记
        var lines = NoteWall.CardLines(Make("# 周末\n- 前端改两处\n  * 子项 **粗**\n## 行李\n> 记得同步\n```\ngit log -5\n```\n普通 `代码`\n", "会议纪要"));
        CollectionAssert.AreEqual(new[]
        {
            new NoteWall.CardLine(NoteWall.CardLineKind.Heading, "周末", Level: 1),
            new NoteWall.CardLine(NoteWall.CardLineKind.Bullet, "前端改两处"),
            new NoteWall.CardLine(NoteWall.CardLineKind.Bullet, "子项 粗", Indent: 2),
            new NoteWall.CardLine(NoteWall.CardLineKind.Heading, "行李", Level: 2),
            new NoteWall.CardLine(NoteWall.CardLineKind.Plain, "记得同步"),
            new NoteWall.CardLine(NoteWall.CardLineKind.Code, "git log -5"),
            new NoteWall.CardLine(NoteWall.CardLineKind.Plain, "普通 代码"),
        }, lines);
        // 没自己起标题时第一行当标题，卡片上不重复；「#标签」不是标题、任务行原样
        CollectionAssert.AreEqual(new[]
        {
            new NoteWall.CardLine(NoteWall.CardLineKind.Plain, "#标签"),
            new NoteWall.CardLine(NoteWall.CardLineKind.Plain, "☐ 买菜"),
        }, NoteWall.CardLines(Make("# 标题\n#标签\n☐ 买菜")));
    }

    private static NoteWall.Layout TwoSections() => NoteWall.Arrange(new[]
    {
        Section(new[] { "p", "q" }, new double[] { 100, 100 }, "已固定"), Section(new[] { "x", "y", "z" }, new double[] { 100, 100, 100 }),
    }, 940);

    /// <summary>指针下是哪张（拖动时四边往里收一点）；落点只在同一段里。</summary>
    [TestMethod]
    public void DragLandsWithinItsSection()
    {
        var layout = TwoSections();
        var x = layout.Frames[2];
        Assert.AreEqual(2, NoteWall.ItemAt(new PointD(x.MidX, x.MidY), layout));
        // 卡片边上（收进去的那一圈里）不算
        var edge = new PointD(x.X + 2, x.Y + 2);
        Assert.AreEqual(2, NoteWall.ItemAt(edge, layout));
        Assert.IsNull(NoteWall.ItemAt(edge, layout, NoteWall.DragInset));
        Assert.IsNull(NoteWall.ItemAt(new PointD(0, 0), layout));
        Assert.AreEqual(2, NoteWall.Landing(4, 2, layout));
        Assert.AreEqual(1, NoteWall.Landing(0, 1, layout));
        Assert.IsNull(NoteWall.Landing(0, 3, layout));
        Assert.IsNull(NoteWall.Landing(3, 1, layout));
        CollectionAssert.AreEqual(new[] { "c", "a", "b" }, NoteWall.Moved(new[] { "a", "b", "c" }, 2, 0));
        CollectionAssert.AreEqual(new[] { "b", "c", "a" }, NoteWall.Moved(new[] { "a", "b", "c" }, 0, 2));
        CollectionAssert.AreEqual(new[] { "a", "b", "c" }, NoteWall.Moved(new[] { "a", "b", "c" }, 0, 5));
    }

    /// <summary>拖动排序的落点只看拖动开始时那份排法：指针不动，怎么反复问都是同一个落点。随机的墙、指针停在随便哪张里面，连问 8 次。</summary>
    [TestMethod]
    public void DropTargetIsStable()
    {
        var seed = 7UL;
        int Next(int bound)
        {
            seed = unchecked(seed * 6_364_136_223_846_793_005UL + 1_442_695_040_888_963_407UL);
            return (int)(seed >> 33) % bound;
        }

        for (var round = 0; round < 4000; round++)
        {
            var count = 3 + Next(12);
            var ids = Enumerable.Range(0, count).Select(index => $"n{index}").ToArray();
            var heights = ids.Select(_ => NoteWall.MinHeight + Next(209)).ToArray();
            var based = NoteWall.Arrange(new[] { Section(ids, heights) }, 940);
            var from = Next(count);
            var card = based.Frames[Next(count)];
            var point = new PointD(card.X + Next((int)card.Width), card.Y + Next((int)card.Height));
            var to = from;
            var seen = new HashSet<int>();
            for (var ask = 0; ask < 8; ask++)
            {
                to = NoteWall.DropTarget(from, to, point, based);
                seen.Add(to);
            }

            Assert.AreEqual(1, seen.Count, $"from {from} at {point} heights {string.Join(",", heights)}");
        }

        // 落在同一段里另一张的里面：就是那张的位置；在别的段里、在空白处：不动
        var layout = TwoSections();
        var y = layout.Frames[3];
        Assert.AreEqual(3, NoteWall.DropTarget(2, 2, new PointD(y.MidX, y.MidY), layout));
        var q = layout.Frames[1];
        Assert.AreEqual(4, NoteWall.DropTarget(2, 4, new PointD(q.MidX, q.MidY), layout));
        Assert.AreEqual(4, NoteWall.DropTarget(2, 4, new PointD(0, 0), layout));
    }

    /// <summary>拖完写回仓库：仓库的顺序里固定的和没固定的混着排，照它在墙上同一段里紧挨着的那张放（mac 用真的仓库和模型；
    /// 这里仓库换成编号列表，挪法同 NoteStore.move：先拿掉、再插到给的下标）。</summary>
    [TestMethod]
    public void DragWritesBackTheStoreOrder()
    {
        var active = new List<string> { "A", "B", "C", "D", "E" };
        var pinned = new HashSet<string> { "B", "D" };
        List<List<string>> Wall() => new() { active.Where(pinned.Contains).ToList(), active.Where(id => !pinned.Contains(id)).ToList() };
        void Drag(int from, int to)
        {
            var order = Wall().SelectMany(group => group).ToList();
            var section = from < 2 ? new NoteRange(0, 2) : new NoteRange(2, 3);
            var id = order[from];
            if (NoteWall.StoreIndex(id, NoteWall.Moved(order, from, to), section, active) is { } at)
            {
                active.Remove(id);
                active.Insert(at, id);
            }
        }

        string Shown() => string.Join("|", Wall().Select(group => string.Concat(group)));

        Assert.AreEqual("BD|ACE", Shown());
        // E 拖到 A 上：放到 A 前面
        Drag(4, 2);
        Assert.AreEqual("BD|EAC", Shown());
        // A 拖到最后（C 上）：它是这一段最后一张，放到 C 后面
        Drag(3, 4);
        Assert.AreEqual("BD|ECA", Shown());
        // 固定的那段里：D 拖到 B 上
        Drag(1, 0);
        Assert.AreEqual("DB|ECA", Shown());
        Assert.IsNull(NoteWall.StoreIndex("x", new[] { "a" }, new NoteRange(0, 1), new[] { "a" }));
    }

    // ---- 编辑卡 ----

    /// <summary>编辑卡多大：墙的七八成，最大 680 × 560。</summary>
    [TestMethod]
    public void EditorSizeFollowsTheWindow()
    {
        Assert.AreEqual((562.0, 309.0), NoteWall.EditorSize((720, 368)));
        Assert.AreEqual((680.0, 444.0), NoteWall.EditorSize((940, 528)));
        Assert.AreEqual(NoteWall.EditorMax, NoteWall.EditorSize((1600, 1000)));
    }

    /// <summary>编辑卡那块纸从哪长出来 / 缩回哪：那张卡片现在在窗口里的位置（墙上的位置 − 滚过的 + 顶上那一条）；滚出了可见区、不在墙上的是
    /// null。收回时照收回那一刻的排法和滚动位置算。</summary>
    [TestMethod]
    public void PaperFollowsTheCardNow()
    {
        var layout = NoteWall.Arrange(new[] { Section(new[] { "a", "b", "c", "d" }, new double[] { 120, 300, 160, 140 }) }, 940);
        const double top = 45;
        const double viewport = 500;
        var a = layout.Frames[0];
        Assert.AreEqual(a.Offset(0, top), NoteWall.PaperRect(a, top, 0, viewport));
        Assert.AreEqual(a.Offset(0, top - 100), NoteWall.PaperRect(a, top, 100, viewport));
        Assert.IsNull(NoteWall.PaperRect(a, top, a.Bottom + 1, viewport));
        var d = layout.Frames[3];
        Assert.IsNull(NoteWall.PaperRect(d, top, 0, d.Y - 1));
        Assert.IsNull(NoteWall.PaperRect(null, top, 0, viewport));
        // 开着的时候它挪了：按新的排法算出来的是新的位置
        var moved = NoteWall.Arrange(new[] { Section(new[] { "d", "a", "b", "c" }, new double[] { 140, 120, 300, 160 }) }, 940);
        var now = moved.IndexOf("d")!.Value;
        Assert.AreEqual(moved.Frames[now].Offset(0, top), NoteWall.PaperRect(moved.Frames[now], top, 0, viewport));
        Assert.AreNotEqual(d, moved.Frames[now]);
    }

    // ---- 卡片上的字 ----

    /// <summary>卡片带正文的哪一段：自己起了标题就从头带；没起的，标题就是第一个有内容的行，跳过它（和前面的空行、围栏行）；最多 ExcerptLines 行；
    /// 代码块挪到这一段的坐标里；图片先处理再截。</summary>
    [TestMethod]
    public void ExcerptSkipsTheTitleLine()
    {
        Assert.AreEqual("第一行\n第二行", NoteWall.Excerpt(Make("第一行\n第二行", "T")).Text);
        Assert.AreEqual("第二行", NoteWall.Excerpt(Make("\n\n第一行\n\n第二行\n")).Text);
        Assert.AreEqual(string.Empty, NoteWall.Excerpt(Make("只有一行")).Text);
        Assert.AreEqual(string.Empty, NoteWall.Excerpt(Make(string.Empty)).Text);
        var lines = NoteWall.Excerpt(Make(string.Join("\n", Enumerable.Range(1, 40).Select(line => $"第 {line} 行")), "T")).Text.Split('\n');
        Assert.AreEqual(NoteWall.ExcerptLines, lines.Length);
        Assert.AreEqual($"第 {NoteWall.ExcerptLines} 行", lines[^1]);
        // 一整段没有换行的长字：截到 ExcerptLength 个字
        Assert.AreEqual(NoteWall.ExcerptLength, NoteWall.Excerpt(Make(new string('字', 5000), "T")).Text.Length);
        // 标题取自代码块里的一行：后面的收尾围栏不带
        Assert.AreEqual("后面的字", NoteWall.Excerpt(Make("```\nlet a = 1\n```\n后面的字")).Text);
        // 以代码块开头、没起标题：标题是块里的第一行，这一段从块里的第二行起——这一段的第一行是块里的字、不是围栏
        foreach (var (body, title) in new[] { ("```\nlet a = 1\nlet b = 2\nlet c = 3\n```\nafter", "let a = 1"), ("```\nA\nB\n```\nC", "A") })
        {
            Assert.AreEqual(title, Make(body).DisplayTitle);
            var cut = NoteWall.Excerpt(Make(body));
            Assert.AreEqual(NoteMarkdown.Role.Content, NoteMarkdown.RoleAt(0, cut.Blocks));
        }

        // 图片：只有图片的行整行不要、行内的写成「[图片]」（自己起了标题：这一段从正文开头带）
        Assert.AreEqual("买菜\n牛奶", NoteWall.Excerpt(Make($"买菜\n{Image}\n牛奶", "我的标题")).Text, "只有图片的行整行不要");
        Assert.AreEqual("买菜", NoteWall.Excerpt(Make($"{Image}\n买菜", "我的标题")).Text);
        Assert.AreEqual(string.Empty, NoteWall.Excerpt(Make(Image, "我的标题")).Text);
        Assert.AreEqual("前面[图片]后面", NoteWall.Excerpt(Make($"前面{Image}后面", "我的标题")).Text, "行内的写成「[图片]」");
        // 令牌在 ExcerptLength 处不截成两半、只有图片的行先去掉再数行
        var nearCut = NoteWall.Excerpt(Make(new string('字', NoteWall.ExcerptLength - 10) + Image, "我的标题")).Text;
        Assert.IsFalse(nearCut.Contains("kitty-note-image", StringComparison.Ordinal), "截取处不许露出令牌原文");
        Assert.IsTrue(nearCut.EndsWith("[图片]", StringComparison.Ordinal));
        Assert.AreEqual("买菜\n牛奶", NoteWall.Excerpt(Make($"{Image}\n买菜\n牛奶", "我的标题")).Text, "只有图片的行先去掉，不占 16 行的名额");
        // 令牌跨在 ExcerptScan 的截断处：截到令牌后面，不把它截成两半
        var straddling = NoteWall.Excerpt(Make(new string('\n', NoteWall.ExcerptScan - 20) + "前" + Image + "后", "我的标题")).Text;
        Assert.IsFalse(straddling.Contains("kitty-note-image", StringComparison.Ordinal), "截断处不许露出半截令牌");
        Assert.IsTrue(straddling.Contains("[图片]", StringComparison.Ordinal));
        // 代码块：挪到这一段的坐标里；截在尾上的照样是块
        var fenced = NoteWall.Excerpt(Make("```swift\nlet a = 1\n```\n后面", "T"));
        Assert.AreEqual(1, fenced.Blocks.Count);
        Assert.AreEqual(0, fenced.Blocks[0].Open.Location);
        var code = string.Join("\n", new[] { "```" }.Concat(Enumerable.Range(1, 30).Select(line => $"代码 {line}")).Append("```"));
        var open = NoteWall.Excerpt(Make(code, "T"));
        Assert.AreEqual(1, open.Blocks.Count);
        Assert.AreEqual(NoteMarkdown.Role.Content, NoteMarkdown.RoleAt(open.Text.IndexOf("代码 10", StringComparison.Ordinal), open.Blocks));
    }

    /// <summary>卡片的高（mac cardTextAndHeight 的高的那一半，cardTextAndHeight 里缩略图那几条）：只有标题的是最矮的那张，长的到上限、超出的截断；
    /// 标题最多两行；固定的给图钉让出一截；缩略图按比例、有上限、算进卡片的高。量字的结果直接给数（一行标题 19、一行正文按 17 算）。</summary>
    [TestMethod]
    public void CardHeight()
    {
        var shortCard = NoteWall.Card(false, NoteWall.TitleLine, 0);
        Assert.AreEqual(NoteWall.MinHeight, shortCard.Height);
        Assert.AreEqual(0, shortCard.BodyHeight);
        Assert.IsFalse(shortCard.Overflows);
        Assert.AreEqual(NoteWall.TitleLine, shortCard.TitleHeight);
        // 标题很长（排出来五行）：最多两行
        Assert.AreEqual(NoteWall.TitleLine * 2, NoteWall.Card(false, NoteWall.TitleLine * 5, 0).TitleHeight);
        // 固定的给图钉让出一截
        Assert.AreEqual(NoteWall.TextWidth - NoteWall.PinRoom, NoteWall.Card(true, NoteWall.TitleLine, 0).TitleWidth);
        Assert.AreEqual(NoteWall.TextWidth, NoteWall.Card(false, NoteWall.TitleLine, 0).TitleWidth);
        // 很长的正文：到上限、超出
        var tall = NoteWall.Card(false, NoteWall.TitleLine, 40 * 17);
        Assert.AreEqual(NoteWall.MaxHeight, tall.Height);
        Assert.IsTrue(tall.Overflows);
        Assert.AreEqual(tall.TitleHeight + NoteWall.TitleGap + tall.BodyRoom, tall.TextHeight);
        // 几行：高随内容，在上下限之间
        var some = NoteWall.Card(false, NoteWall.TitleLine, 3 * 17);
        Assert.IsTrue(some.Height > NoteWall.MinHeight && some.Height < NoteWall.MaxHeight && !some.Overflows);
        // 量出来的是小数：向上取整
        Assert.AreEqual(52, NoteWall.Card(false, NoteWall.TitleLine, 51.2).BodyHeight);
        // 缩略图：高按比例、有上限；卡片的高把它算进去；读不出尺寸不放
        var thumbnail = NoteWall.ThumbnailHeight(800, 400);
        Assert.AreEqual(Math.Min(NoteWall.ThumbnailMaxHeight, NoteWall.TextWidth / 2), thumbnail, "高按比例、有上限");
        Assert.AreEqual(NoteWall.ThumbnailMaxHeight, NoteWall.ThumbnailHeight(100, 4000));
        Assert.AreEqual(0, NoteWall.ThumbnailHeight(0, 0));
        var plain = NoteWall.Card(false, NoteWall.TitleLine, 17);
        var sized = NoteWall.Card(false, NoteWall.TitleLine, 17, thumbnail);
        Assert.IsTrue(sized.Height > plain.Height, "卡片的高把缩略图算进去");
        Assert.AreEqual(thumbnail, sized.ThumbnailHeight);
        // 行内的第一张图也算（缩略图是正文里找的第一张图，不是这一段里的）
        Assert.IsNotNull(NoteImages.First($"前{Image}后"));
    }
}
