// 长截图「在动的那一块」（PLAN-v20 W1，照 mac 外部 PR #20 de3fae37 + 审查 b9e96dea 的 ScrollStitcherTests / ScrollSpeedTests）：
// 页面里只嵌着一块小滚动区时，量出来的是那一块、不是整个选区；零星变的几行（光标、秒表）连不成一段；没滚时原地变的不记；
// 自动滚动的领先上限、对不上时的退让、光标落点都跟着这一块走。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollBandTests
{
    private const int Width = 64;
    private const int Height = 200;
    private const int White = unchecked((int)0xFFF5F5F5);

    private static uint Mix(int a, int b) => (((uint)a * 2654435761u) ^ (uint)(b * 40503)) >> 13;

    /// <summary>页面第 row 行第 x 列：每 20 行里 14 行是字（随机的深色点），其余是留白行（同 mac 的样本：一段字、6 行空白）。</summary>
    private static int Page(int row, int x)
        => row % 20 < 14 && Mix(row, x) % 8 < 3 ? unchecked((int)(0xFF000000u | (Mix(row + 7, x) & 0x3F3F3Fu))) : White;

    /// <summary>选区 200 行高，其中 band 那几行在滚（内容照页面第 offset 行起），其余原地不动的留白（同 mac nested）。</summary>
    private static ScrollFrame Nested(int offset, (int Start, int End) band, int columnsFrom = 0, int columnsTo = Width)
    {
        var pixels = new int[Width * Height];
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var inside = y >= band.Start && y < band.End && x >= columnsFrom && x < columnsTo;
                pixels[y * Width + x] = inside ? Page(offset + y - band.Start, x) : White;
            }
        }

        return new ScrollFrame(Width, Height, pixels);
    }

    [TestMethod]
    public void ReportsTheBlockThatActuallyMoves()
    {
        // 照 mac reportsTheBlockThatActuallyMoves：选区 200 行高，中间 80 行是那块小滚动区。
        var band = (Start: 60, End: 140);
        var measured = new ScrollBand(Width, Height);
        Assert.IsTrue(measured.MovingRows.IsEmpty, "还没滚过：不知道哪一块在动，会话按整个选区算");
        var previous = Nested(100, band);
        foreach (var offset in new[] { 140, 180 })
        {
            var next = Nested(offset, band);
            measured.NoteMoved(previous, next);
            previous = next;
        }

        // 在动的是中间那 80 行，不是整个选区；块里留白的几行滚过去还是白的、不算变过，量出来会短几行。
        Assert.IsTrue(measured.MovingRows.Count >= 80 * 9 / 10, $"量出 {measured.MovingRows}");
        Assert.IsTrue(measured.MovingRows.Count <= 80 + 2, $"量出 {measured.MovingRows}");
        Assert.IsTrue(measured.MovingRows.Start > 40 && measured.MovingRows.End < 160);
        // 手动滚时不算列；自动滚动打开后才有。
        Assert.IsTrue(measured.MovingColumns.IsEmpty);
        measured.TracksColumns = true;
        measured.NoteMoved(previous, Nested(220, band));
        Assert.IsTrue(measured.MovingColumns.Start < Width / 2 && measured.MovingColumns.End > Width / 2);
    }

    [TestMethod]
    public void ColumnsFollowTheBlockWhenItIsNarrower()
    {
        // 小滚动区只占中间 16..48 列：量出来的列也只是那几列（按 16 像素一段对齐）。
        var band = (Start: 40, End: 160);
        var measured = new ScrollBand(Width, Height) { TracksColumns = true };
        measured.NoteMoved(Nested(0, band, 16, 48), Nested(30, band, 16, 48));
        Assert.AreEqual(new PixelRun(16, 48), measured.MovingColumns);
    }

    [TestMethod]
    public void BandIgnoresChangesWithoutScrolling()
    {
        // 照 mac bandIgnoresChangesWithoutScrolling（b9e96dea）：没滚时原地变的几行（选区里的小动画、闪烁的光标）不算。
        // 会话只在这一帧算「拼上了、长了行」时才调 NoteMoved：这一帧拼完是 Unchanged。
        var band = (Start: 60, End: 140);
        var first = Nested(100, band);
        var animated = (int[])first.Pixels.Clone();
        for (var i = 10 * Width; i < 20 * Width; i++)
        {
            animated[i] = unchecked((int)0xFF000000);
        }

        var frame = new ScrollFrame(Width, Height, animated);
        var canvas = new ScrollCanvas(first);
        var before = canvas.Height;
        var appended = canvas.Append(frame, ScrollDirection.Down);
        Assert.AreEqual(
            ScrollStep.Unchanged, ScrollPacer.Classify(first.Hashes, frame.Hashes, appended, canvas.Height - before),
            "原地变的 10 行不算滚过");
        var measured = new ScrollBand(Width, Height);
        Assert.IsTrue(measured.MovingRows.IsEmpty, "没滚过，量不出");
        // 真滚了才量出来，量出来的是那块小滚动区。
        measured.NoteMoved(first, Nested(140, band));
        Assert.IsTrue(measured.MovingRows.Start >= band.Start - 2, $"量出 {measured.MovingRows}");
    }

    [TestMethod]
    public void BandIgnoresIsolatedChangedRows()
    {
        // 照 mac bandIgnoresIsolatedChangedRows。
        static PixelRun Run(IEnumerable<int> rows, int gap = 4)
        {
            var moved = new bool[600];
            foreach (var row in rows)
            {
                moved[row] = true;
            }

            return ScrollBand.LargestRun(moved, gap);
        }

        static IEnumerable<int> Range(int from, int to) => Enumerable.Range(from, to - from);

        Assert.AreEqual(new PixelRun(0, 0), Run([]), "一帧都没滚过");
        Assert.AreEqual(new PixelRun(200, 400), Run(Range(200, 400)));
        Assert.AreEqual(new PixelRun(200, 400), Run(Range(200, 400).Append(590)), "页脚的光标在闪，孤零零一行");
        Assert.AreEqual(new PixelRun(300, 320), Run(new[] { 3 }.Concat(Range(300, 320)).Append(590)), "取最长的一段，不是最靠上的");
        // 中间隔几行没变连起来；隔得远的（换了一块、页脚的光标）断开。
        Assert.AreEqual(new PixelRun(200, 400), Run(Range(200, 300).Concat(Range(304, 400))));
        Assert.AreEqual(new PixelRun(200, 400), Run(Range(100, 160).Concat(Range(200, 400))));
        // 实际用的那档间隔：块里每 20 行一段字、中间 6 行留白滚过去不变，照样连成一整块（不然会量小一半）。
        var spacing = Enumerable.Range(0, 10).SelectMany(i => Range(200 + i * 20, 214 + i * 20));
        Assert.AreEqual(new PixelRun(200, 394), Run(spacing, ScrollBand.BandGap), "两段字之间隔着 6 行就断开的话就量错了");
    }

    [TestMethod]
    public void LeadIsCappedAtHalfTheMovingBlock()
    {
        // 照 mac leadIsCappedAtHalfTheMovingBlock（单位换成滚轮单位：1 个单位滚 gain 像素）。
        Assert.AreEqual(250, ScrollPacer.Room(0, 1000, 2), 1e-9);
        Assert.AreEqual(50, ScrollPacer.Room(0, 200, 2), 1e-9, "只有一小块在动：领先上限跟着那一块走");
        Assert.AreEqual(5, ScrollPacer.Room(45, 200, 2), 1e-9);
        Assert.AreEqual(12.5, ScrollPacer.Room(0, 100, 4), 1e-9);
        // 会话里：领先封在这一块的一半。
        const int height = 1000;
        var pacer = new ScrollPacer(height, 1, ScrollSpeed.Fast) { Band = 400 };
        pacer.Begin();
        for (var frame = 0; frame < 120; frame++)
        {
            pacer.Frame(1 / 60.0);
        }

        Assert.IsTrue((pacer.Posted - pacer.PostedAtReference) * pacer.Gain <= 400 * ScrollPacer.MaxLead + 1e-6);
        // 没量出来（0）、比选区还高时按选区高。
        pacer.Band = 0;
        Assert.AreEqual(height, pacer.Band);
        pacer.Band = 5000;
        Assert.AreEqual(height, pacer.Band);
    }

    [TestMethod]
    public void LostBacksOffToHalfTheBlock()
    {
        // 照 mac .lost：退回发的一半；领先得比这块还多时（块是后来才量出来的）退到这块的一半以内。
        Assert.AreEqual(50, ScrollPacer.BackOff(100, 1000, 1), "领先没到上限：退一半");
        // 块 200 像素、1 单位 1 像素：允许领先 100；已经领先 400 → 退到 50 以内，退 350。
        Assert.AreEqual(350, ScrollPacer.BackOff(400, 200, 1));
        Assert.AreEqual(0, ScrollPacer.BackOff(0, 200, 1));
    }

    [TestMethod]
    public void BandRectFollowsTheMovingBlock()
    {
        // 照 mac bandRectFollowsTheMovingBlock（Windows 的选区和光标都是物理像素、y 朝下，不用换算）。
        Assert.AreEqual((100, 200, 200, 300), ScrollBand.BandRect(100, 200, 200, 300, default, default), "还不知道哪一块在动：整个选区");
        Assert.AreEqual((100, 300, 200, 100), ScrollBand.BandRect(100, 200, 200, 300, new PixelRun(100, 200), default));
        Assert.AreEqual((140, 300, 100, 100), ScrollBand.BandRect(100, 200, 200, 300, new PixelRun(100, 200), new PixelRun(40, 140)));
        // 算出选区外：夹在选区里。
        var clamped = ScrollBand.BandRect(100, 200, 200, 300, new PixelRun(100, 200), new PixelRun(40, 600));
        Assert.AreEqual(300, clamped.Left + clamped.Width);
    }

    /// <summary>mac 离线复现的那个场景：选区 rows 行高、中间 band 在滚、其余留白。</summary>
    private static ScrollFrame Tall(int rows, int offset, (int Start, int End) band, bool stillText = false)
    {
        var pixels = new int[Width * rows];
        for (var y = 0; y < rows; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                pixels[y * Width + x] = y >= band.Start && y < band.End
                    ? Page(offset + y - band.Start, x)
                    : stillText ? Page(5000 + y, x) : White;
            }
        }

        return new ScrollFrame(Width, rows, pixels);
    }

    [TestMethod]
    public void BlockBetweenStillTextJoinsAndKeepsTheFooterOnce()
    {
        // mac de3fae37 的离线复现那个版面：选区 600 行、中间 200 行在滚，上下 200 行是不动的页面（有字：页头、输入框）。
        // 整帧对不上（上下的字原地不动），去掉头和脚只拿中间找：每帧滚 100 行（这块的一半）5/5 接上，长图 = 头 + 内容 + 脚各一份。
        var band = (Start: 200, End: 400);
        var canvas = new ScrollCanvas(Tall(600, 0, band, stillText: true));
        for (var step = 1; step <= 5; step++)
        {
            Assert.IsTrue(canvas.Append(Tall(600, step * 100, band, stillText: true), ScrollDirection.Down), $"第 {step} 帧（滚 100 行）没接上");
        }

        Assert.AreEqual(200 + (200 + 500) + 200, canvas.Height);
        var image = canvas.Compose();
        for (var y = 0; y < image.Height; y += 7)
        {
            var expected = y < 200 ? Page(5000 + y, 3) : y < 900 ? Page(y - 200, 3) : Page(5000 + y - 500, 3);
            Assert.AreEqual(expected, image.Pixels[y * Width + 3], $"第 {y} 行");
        }

        // 一次滚过整块（两帧之间这块没有重叠）：接不上——按选区高算领先上限（300 行）时就是这样丢帧的。
        Assert.IsFalse(new ScrollCanvas(Tall(600, 0, band, true)).Append(Tall(600, 200, band, true), ScrollDirection.Down));
        Assert.IsFalse(new ScrollCanvas(Tall(600, 0, band, true)).Append(Tall(600, 300, band, true), ScrollDirection.Down));
        Assert.AreEqual(100, ScrollPacer.Room(0, 200, 1), 1e-9, "1 单位 1 像素时，按这一块最多领先 100 行");
    }

    [TestMethod]
    public void BlockBetweenStillTextJoinsUpward()
    {
        // 往上翻（聊天记录）：长图 = 头 + 新露出来的内容 + 原来的内容 + 脚各一份。
        var band = (Start: 200, End: 400);
        var canvas = new ScrollCanvas(Tall(600, 500, band, stillText: true));
        for (var step = 1; step <= 3; step++)
        {
            Assert.IsTrue(canvas.Append(Tall(600, 500 - step * 100, band, stillText: true), ScrollDirection.Up), $"第 {step} 帧没接上");
        }

        Assert.AreEqual(200 + (200 + 300) + 200, canvas.Height);
        var image = canvas.Compose();
        for (var y = 0; y < image.Height; y += 7)
        {
            var expected = y < 200 ? Page(5000 + y, 3) : y < 700 ? Page(200 + y - 200, 3) : Page(5000 + y - 300, 3);
            Assert.AreEqual(expected, image.Pixels[y * Width + 3], $"第 {y} 行");
        }
    }

    [TestMethod]
    public void StitcherJoinsAFrameWhereOnlyTheInnerBlockScrolled()
    {
        // 只嵌着一块小滚动区、滚了这块的一半（40 行）：拼接得接上（不然量不出这一块，W1 的节奏无从谈起）。
        var band = (Start: 60, End: 140);
        var canvas = new ScrollCanvas(Nested(100, band));
        var before = canvas.Height;
        Assert.IsTrue(canvas.Append(Nested(140, band), ScrollDirection.Down), "滚这块的一半没接上");
        Assert.IsTrue(canvas.Height > before);
    }
}
