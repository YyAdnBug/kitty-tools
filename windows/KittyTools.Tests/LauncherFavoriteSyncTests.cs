// PLAN-v21 第 3 批：启动器收藏的同步（只在 Windows 之间，windows-launcher）。照 mac LauncherUsage 的规矩：编号 = 类型 + 目标的哈希，
// 顺序单独一条，第一次合并在一起，不卡 8 个，解不开的整个不落。最后一条走真的 SyncRunner 和临时文件夹，两台各加、挪顺序、删。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherFavoriteSyncTests
{
    private static readonly SyncFavorite Code = new("App", @"C:\Program Files\Microsoft VS Code\Code.exe", "Visual Studio Code");
    private static readonly SyncFavorite Site = new("Url", "https://example.com/a/b", "示例");
    private static readonly SyncFavorite Dark = new("Command", "dark", "切换深色模式");

    [TestMethod]
    public void ValuesAreStableAndOrdered()
    {
        var values = LauncherFavoriteSync.Values(new[] { Code, Site, Code });
        Assert.AreEqual(3, values.Count, "两条 + 顺序；重复的只留第一个");
        var codeId = LauncherFavoriteSync.Id("App", Code.Target);
        Assert.AreEqual(32, codeId.Length);
        Assert.AreEqual("{\"kind\":\"App\",\"target\":\"C:\\\\Program Files\\\\Microsoft VS Code\\\\Code.exe\",\"title\":\"Visual Studio Code\"}", values[codeId]);
        Assert.AreEqual("{\"kind\":\"Url\",\"target\":\"https://example.com/a/b\",\"title\":\"示例\"}",
            values[LauncherFavoriteSync.Id("Url", Site.Target)], "斜杠、中文原样");
        Assert.AreEqual(SyncEngine.OrderValue(new[] { codeId, LauncherFavoriteSync.Id("Url", Site.Target) }), values[SyncEngine.OrderID]);
        Assert.AreNotEqual(codeId, LauncherFavoriteSync.Id("Path", Code.Target), "同一个目标、不同类型是两条");
    }

    [TestMethod]
    public void PlanFollowsTheOrderAndRefusesNewerWriting()
    {
        var codeId = LauncherFavoriteSync.Id(Code.Kind, Code.Target);
        var siteId = LauncherFavoriteSync.Id(Site.Kind, Site.Target);
        var darkId = LauncherFavoriteSync.Id(Dark.Kind, Dark.Target);
        var changes = new Dictionary<string, string?>
        {
            [darkId] = LauncherFavoriteSync.Encode(Dark),
            [codeId] = null,
            [SyncEngine.OrderID] = SyncEngine.OrderValue(new[] { darkId, siteId }),
        };
        var list = LauncherFavoriteSync.Plan(changes, new[] { Code, Site }, out var failure);
        Assert.IsNull(failure);
        CollectionAssert.AreEqual(new[] { Dark, Site }, list);

        // 不在顺序里的排在后面（按编号）；不卡 8 个
        var many = Enumerable.Range(0, 9).Select(index => new SyncFavorite("Url", "https://example.com/" + index, "第 " + index)).ToList();
        list = LauncherFavoriteSync.Plan(new Dictionary<string, string?>(), many, out _);
        Assert.AreEqual(9, list!.Count);

        // 更新版本写的（多了字段）、编号和内容对不上：整个不落
        foreach (var bad in new[]
                 {
                     "{\"kind\":\"Url\",\"pinned\":true,\"target\":\"https://example.com/a/b\",\"title\":\"示例\"}",
                     LauncherFavoriteSync.Encode(Dark),
                     "{\"title\":\"示例\",\"kind\":\"Url\",\"target\":\"https://example.com/a/b\"}",
                 })
        {
            Assert.IsNull(LauncherFavoriteSync.Plan(new Dictionary<string, string?> { [siteId] = bad }, new[] { Code }, out failure), bad);
            Assert.IsNotNull(failure);
        }
    }

    [TestMethod]
    public void TwoWindowsMergeReorderAndDelete()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var a = new SyncNode("WIN-A", temp.Sub("a"), new MemoryFavorites(Code, Site));
        var b = new SyncNode("WIN-B", temp.Sub("b"), new MemoryFavorites(Dark, Site));
        long now = 0;
        a.Round(folder, ref now);
        b.Round(folder, ref now);
        a.Round(folder, ref now);
        var fa = a.Source<MemoryFavorites>();
        var fb = b.Source<MemoryFavorites>();
        CollectionAssert.AreEquivalent(new[] { Code, Site, Dark }, fa.List, "第一次合并在一起，同一个网址只一条");
        CollectionAssert.AreEqual(fa.List, fb.List, "两边顺序一样");

        // A 把最后一个挪到最前，B 删掉网址
        fa.List.Insert(0, fa.List[^1]);
        fa.List.RemoveAt(fa.List.Count - 1);
        fb.List.Remove(Site);
        a.Round(folder, ref now);
        b.Round(folder, ref now);
        a.Round(folder, ref now);
        CollectionAssert.AreEqual(fa.List, fb.List);
        CollectionAssert.DoesNotContain(fa.List, Site);
        Assert.AreEqual(2, fa.List.Count);
    }

    private sealed class MemoryFavorites(params SyncFavorite[] initial) : MemorySource
    {
        public List<SyncFavorite> List { get; set; } = initial.ToList();

        public override string Kind => LauncherFavoriteSync.Kind;

        public override string? JoinKey(string value) => null;

        protected override Dictionary<string, string> Encode() => LauncherFavoriteSync.Values(List);

        protected override string? Land(IReadOnlyDictionary<string, string?> changes)
        {
            var list = LauncherFavoriteSync.Plan(changes, List, out var failure);
            if (list is null)
            {
                return failure;
            }

            List = list;
            return null;
        }
    }
}
