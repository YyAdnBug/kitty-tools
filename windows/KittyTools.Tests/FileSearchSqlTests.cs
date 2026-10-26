// 文件搜索 SQL 的纯函数单测（PLAN-v6 第 4 批）：生成的语句、根目录过滤、ItemUrl → 本地路径。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class FileSearchSqlTests
{
    [TestMethod]
    public void BuildsNameLikeWithTopAndOrder()
    {
        var sql = FileSearchSql.Build(new[] { "jpg" }, new[] { @"C:\Users\YY\Downloads" }, 20);
        StringAssert.Contains(sql, "SELECT TOP 20 System.ItemUrl, System.FileName FROM SYSTEMINDEX");
        StringAssert.Contains(sql, "System.FileName LIKE '%jpg%'");
        StringAssert.Contains(sql, "System.ItemUrl LIKE 'file:C:/Users/YY/Downloads/%'");
        StringAssert.Contains(sql, "ORDER BY System.DateModified DESC");
    }

    [TestMethod]
    public void DoublesQuotesAndCombinesTokens()
    {
        var sql = FileSearchSql.Build(new[] { "o'neil", "report" }, Array.Empty<string>());
        StringAssert.Contains(sql, "System.FileName LIKE '%o''neil%'");
        StringAssert.Contains(sql, "System.FileName LIKE '%report%'");
        StringAssert.Contains(sql, " AND ");
        Assert.IsFalse(sql.Contains("System.ItemUrl LIKE", StringComparison.Ordinal),
            "没有根目录时不应该加路径过滤");
    }

    [TestMethod]
    public void LimitsTokensAndFallsBackToEmpty()
    {
        var sql = FileSearchSql.Build(new[] { "a", "b", "c", "d", "e" }, Array.Empty<string>());
        StringAssert.Contains(sql, "LIKE '%d%'");
        Assert.IsFalse(sql.Contains("LIKE '%e%'", StringComparison.Ordinal));
        Assert.AreEqual(string.Empty, FileSearchSql.Build(Array.Empty<string>(), Array.Empty<string>()));
    }

    [TestMethod]
    public void RootFilterHandlesSeveralRootsAndTrailingSlashes()
    {
        var filter = FileSearchSql.RootFilter(new[] { @"C:\Users\YY\Desktop\", @"D:\Media" });
        StringAssert.Contains(filter, "file:C:/Users/YY/Desktop/%");
        StringAssert.Contains(filter, "file:D:/Media/%");
        StringAssert.Contains(filter, " OR ");
        Assert.AreEqual(string.Empty, FileSearchSql.RootFilter(Array.Empty<string>()));
    }

    [TestMethod]
    public void ConvertsItemUrlToLocalPath()
    {
        Assert.AreEqual(@"C:\Users\YY\a b\1.jpg", FileSearchSql.LocalPathFromItemUrl("file:C:/Users/YY/a%20b/1.jpg"));
        Assert.AreEqual(@"C:\a\b.txt", FileSearchSql.LocalPathFromItemUrl("file:///C:/a/b.txt"));
        Assert.AreEqual(@"C:\a\b.txt", FileSearchSql.LocalPathFromItemUrl(@"C:\a\b.txt"));
        Assert.IsNull(FileSearchSql.LocalPathFromItemUrl(null));
        Assert.IsNull(FileSearchSql.LocalPathFromItemUrl("  "));
    }
}
