// 文件搜索 SQL 的纯函数单测（PLAN-v6 第 4 批；PLAN-v25 起范围是整个索引、默认 500 条）：生成的语句、ItemUrl → 本地路径。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class FileSearchSqlTests
{
    [TestMethod]
    public void BuildsNameLikeWithTopAndOrder()
    {
        var sql = FileSearchSql.Build(new[] { "jpg" }, 20);
        StringAssert.Contains(sql, "SELECT TOP 20 System.ItemUrl, System.FileName FROM SYSTEMINDEX");
        StringAssert.Contains(sql, "System.FileName LIKE '%jpg%'");
        StringAssert.Contains(sql, "ORDER BY System.DateModified DESC");
    }

    [TestMethod]
    public void SearchesTheWholeIndexForFiles()
    {
        // PLAN-v25 F2：不再只查七个根目录；SCOPE='file:' 只要文件系统里的（不要邮件这类别的协议）
        var sql = FileSearchSql.Build(new[] { "报告" });
        StringAssert.Contains(sql, "SCOPE='file:'");
        Assert.IsFalse(sql.Contains("SCOPE='file:C:", StringComparison.Ordinal));
        StringAssert.Contains(sql, "SELECT TOP 500 ");
    }

    [TestMethod]
    public void DoublesQuotesAndCombinesTokens()
    {
        var sql = FileSearchSql.Build(new[] { "o'neil", "report" });
        StringAssert.Contains(sql, "System.FileName LIKE '%o''neil%'");
        StringAssert.Contains(sql, "System.FileName LIKE '%report%'");
        StringAssert.Contains(sql, " AND ");
    }

    [TestMethod]
    public void EscapesLikeWildcards()
    {
        var sql = FileSearchSql.Build(new[] { "[草稿]", "50%", "a_b" });
        StringAssert.Contains(sql, "LIKE '%[[]草稿]%'");
        StringAssert.Contains(sql, "LIKE '%50[%]%'");
        StringAssert.Contains(sql, "LIKE '%a[_]b%'");
    }

    [TestMethod]
    public void LimitsTokensAndFallsBackToEmpty()
    {
        var sql = FileSearchSql.Build(new[] { "a", "b", "c", "d", "e" });
        StringAssert.Contains(sql, "LIKE '%d%'");
        Assert.IsFalse(sql.Contains("LIKE '%e%'", StringComparison.Ordinal));
        Assert.AreEqual(string.Empty, FileSearchSql.Build(Array.Empty<string>()));
        Assert.AreEqual(string.Empty, FileSearchSql.Build(new[] { "  " }));
    }

    [TestMethod]
    public void ConvertsItemUrlToLocalPath()
    {
        Assert.AreEqual(@"C:\Users\YY\a%20b\1.jpg", FileSearchSql.LocalPathFromItemUrl("file:C:/Users/YY/a%20b/1.jpg"));
        Assert.AreEqual(@"C:\a\b.txt", FileSearchSql.LocalPathFromItemUrl("file:///C:/a/b.txt"));
        Assert.AreEqual(@"C:\a\b.txt", FileSearchSql.LocalPathFromItemUrl(@"C:\a\b.txt"));
        Assert.IsNull(FileSearchSql.LocalPathFromItemUrl(null));
        Assert.IsNull(FileSearchSql.LocalPathFromItemUrl("  "));
    }
}
