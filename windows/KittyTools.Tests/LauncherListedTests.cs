// 浏览器里删掉的书签不再以「用过的网址」搜到（PLAN-v16 L2，issue #10，mac 619d3a0 的 deletedBookmarkStaysGone）：
// 书签、快捷链接打开的使用记录标 listed，不当用过的网址找回来；「常用」里只从现在的书签 / 快捷链接里取。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherListedTests
{
    private static readonly HashSet<string> NoBookmarks = new(StringComparer.OrdinalIgnoreCase);

    [TestMethod]
    public void DeletedBookmarkStaysGone()
    {
        // 从书签打开过（listed），浏览器里删了：不再当用过的网址回来
        Assert.IsFalse(LauncherHome.IsUsedLocation(string.Empty, "url", "https://example.com/a", listed: true, NoBookmarks));
        // 手输打开的网址、浏览历史行打开的（没标 listed）照旧
        Assert.IsTrue(LauncherHome.IsUsedLocation(string.Empty, "url", "https://example.com/a", listed: false, NoBookmarks));
        // 还是书签：只留书签那一行
        var bookmarked = new HashSet<string>(new[] { "https://example.com/a" }, StringComparer.OrdinalIgnoreCase);
        Assert.IsFalse(LauncherHome.IsUsedLocation(string.Empty, "url", "HTTPS://example.com/a", listed: false, bookmarked));
        // 查询那一行、应用不算
        Assert.IsFalse(LauncherHome.IsUsedLocation("ex", "url", "https://example.com/a", listed: false, NoBookmarks));
        Assert.IsFalse(LauncherHome.IsUsedLocation(string.Empty, "app", "notepad", listed: false, NoBookmarks));
    }

    [TestMethod]
    public void FrequentOnlyComesFromTheCurrentList()
    {
        var bookmark = new LauncherItem { Kind = LauncherKind.Url, Target = "https://example.com/a", Title = "A", Subtitle = "书签 · Edge" };
        Assert.AreEqual("书签 · Edge", LauncherHome.RestoreListed(LauncherKind.Url, "https://example.com/a", new[] { bookmark })?.Subtitle);
        Assert.IsNull(LauncherHome.RestoreListed(LauncherKind.Url, "https://example.com/a", System.Array.Empty<LauncherItem>()));
        Assert.IsNull(LauncherHome.RestoreListed(LauncherKind.Path, "https://example.com/a", new[] { bookmark }));
    }
}
