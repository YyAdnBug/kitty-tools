// PLAN-v10 §5 主界面：分节合并、折行、面板高、选中怎么移动、任务栏在哪条边、贴着托盘摆在哪（照 mac HomePanel 的单测）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class HomeLayoutTests
{
    private static HomeTile Tile(string id) => new(id, id, string.Empty, "general");

    private static HomeSection Section(string? title, params string[] ids) => new(title, ids.Select(Tile).ToList());

    [TestMethod]
    public void SingleTileSectionsMergeIntoOneUntitledRow()
    {
        var sections = HomeLayout.Sections(new[]
        {
            Section("剪贴板与启动器", "clipboard", "launcher"),
            Section("翻译"),
            Section("截图", "screenshot"),
            Section("录屏", "record"),
        });
        Assert.AreEqual(2, sections.Count);
        Assert.AreEqual("剪贴板与启动器", sections[0].Title);
        Assert.IsNull(sections[1].Title);
        CollectionAssert.AreEqual(new[] { "screenshot", "record" }, sections[1].Tiles.Select(tile => tile.Id).ToArray());
    }

    [TestMethod]
    public void SingleTileAfterTitledSectionStartsItsOwnRow()
    {
        var sections = HomeLayout.Sections(new[]
        {
            Section(null, "a"),
            Section("两格", "b", "c"),
            Section(null, "d"),
        });
        Assert.AreEqual(3, sections.Count);
        Assert.IsNull(sections[2].Title);
    }

    [TestMethod]
    public void RowsWrapPerSection()
    {
        var rows = HomeLayout.Rows(new[]
        {
            Section("七格", "1", "2", "3", "4", "5", "6", "7"),
            Section("两格", "8", "9"),
        });
        Assert.AreEqual(3, rows.Count);
        CollectionAssert.AreEqual(new[] { 0, 1, 2, 3, 4 }, rows[0]);
        CollectionAssert.AreEqual(new[] { 5, 6 }, rows[1]);
        CollectionAssert.AreEqual(new[] { 7, 8 }, rows[2]);
    }

    [TestMethod]
    public void HeightCountsTitlesRowsNoteAndBar()
    {
        var sections = new[] { Section("七格", "1", "2", "3", "4", "5", "6", "7"), Section(null, "8") };
        var expected = HomeLayout.Top + HomeLayout.Bottom +
                       HomeLayout.TitleHeight + 2 * HomeLayout.TileHeight + HomeLayout.Gap +
                       HomeLayout.UntitledGap + HomeLayout.TileHeight +
                       HomeLayout.BarHeight;
        Assert.AreEqual(expected, HomeLayout.Height(sections, 0), 1e-9);
        Assert.AreEqual(expected + HomeLayout.NoteHeight, HomeLayout.Height(sections, 2), 1e-9);
    }

    [TestMethod]
    public void MovesWrapHorizontallyAndKeepColumnVertically()
    {
        // 第 0 行 0–4，第 1 行 5–6，第 2 行 7–8。
        var rows = new List<int[]> { new[] { 0, 1, 2, 3, 4 }, new[] { 5, 6 }, new[] { 7, 8 } };
        Assert.AreEqual(0, HomeLayout.Moved(null, HomeMove.Down, rows));
        Assert.AreEqual(8, HomeLayout.Moved(0, HomeMove.Left, rows));
        Assert.AreEqual(0, HomeLayout.Moved(8, HomeMove.Right, rows));
        // 第 4 格往下：下一行短，落在最后一格。
        Assert.AreEqual(6, HomeLayout.Moved(4, HomeMove.Down, rows));
        Assert.AreEqual(1, HomeLayout.Moved(6, HomeMove.Up, rows));
        Assert.AreEqual(2, HomeLayout.Moved(2, HomeMove.Up, rows));
        Assert.AreEqual(8, HomeLayout.Moved(8, HomeMove.Down, rows));
        Assert.IsNull(HomeLayout.Moved(null, HomeMove.Right, new List<int[]>()));
    }

    [TestMethod]
    public void EdgeFollowsWhereTheWorkAreaIsShorter()
    {
        var monitor = new WorkArea(0, 0, 1920, 1080);
        Assert.AreEqual(TaskbarEdge.Bottom, HomeLayout.Edge(monitor, new WorkArea(0, 0, 1920, 1032), 1800, 1060));
        Assert.AreEqual(TaskbarEdge.Top, HomeLayout.Edge(monitor, new WorkArea(0, 48, 1920, 1080), 1800, 20));
        Assert.AreEqual(TaskbarEdge.Left, HomeLayout.Edge(monitor, new WorkArea(60, 0, 1920, 1080), 30, 1000));
        Assert.AreEqual(TaskbarEdge.Right, HomeLayout.Edge(monitor, new WorkArea(0, 0, 1860, 1080), 1890, 1000));
        // 自动隐藏：工作区就是整块屏，按图标离哪条边近。
        Assert.AreEqual(TaskbarEdge.Bottom, HomeLayout.Edge(monitor, monitor, 1800, 1075));
    }

    [TestMethod]
    public void NearTrayHugsTheTaskbarAndTheIcon()
    {
        var work = new WorkArea(0, 0, 1920, 1032);
        // 底部任务栏，图标 1700–1724：右边对着图标右边，底边离任务栏 12。
        Assert.AreEqual((1724 - 548, 1032 - 12 - 400), HomeLayout.NearTray(work, TaskbarEdge.Bottom, 1700, 1040, 1724, 1064, 548, 400, 12));
        // 图标太靠左：夹回工作区。
        Assert.AreEqual((12, 1032 - 12 - 400), HomeLayout.NearTray(work, TaskbarEdge.Bottom, 100, 1040, 124, 1064, 548, 400, 12));
        // 左边的任务栏：左边离任务栏 12，底边对着图标底边。
        var left = new WorkArea(60, 0, 1920, 1080);
        Assert.AreEqual((72, 1000 - 400), HomeLayout.NearTray(left, TaskbarEdge.Left, 18, 976, 42, 1000, 548, 400, 12));
    }
}
