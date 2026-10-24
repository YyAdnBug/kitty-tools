// 5000 条的搜索耗时（PLAN §6.2 / 第 2 批验收要写进报告）。
// 第一次搜索要折叠正文（建缓存），之后只比较字节；只过滤、不排序。
using System.Diagnostics;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SearchPerformanceTests
{
    [TestMethod]
    public void FiveThousandEntriesStayFast()
    {
        var entries = new List<string>(5000);
        for (var i = 0; i < 5000; i++)
        {
            entries.Add(i % 97 == 0
                ? $"第 {i} 条：会议纪要，讨论启动器和剪贴板的性能 json"
                : $"第 {i} 条：普通正文 plus some English words {i}");
        }

        var tokens = Search.Tokens("json 性能");
        var foldedTokens = Search.FoldTokens(tokens);
        var folded = new byte[entries.Count][];

        var cold = Stopwatch.StartNew();
        var coldHits = 0;
        for (var i = 0; i < entries.Count; i++)
        {
            folded[i] = Search.FoldBytes(entries[i]);
            if (Search.Matches(folded[i], foldedTokens))
            {
                coldHits++;
            }
        }

        cold.Stop();

        var warm = Stopwatch.StartNew();
        var warmHits = 0;
        var rounds = 20;
        for (var round = 0; round < rounds; round++)
        {
            warmHits = 0;
            foreach (var item in folded)
            {
                if (Search.Matches(item, foldedTokens))
                {
                    warmHits++;
                }
            }
        }

        warm.Stop();
        var perSearch = warm.Elapsed.TotalMilliseconds / rounds;
        Console.WriteLine(
            $"5000 条：首次（含折叠缓存）{cold.Elapsed.TotalMilliseconds:F1} ms（命中 {coldHits}）；" +
            $"之后每次 {perSearch:F2} ms（命中 {warmHits}）");

        Assert.AreEqual(coldHits, warmHits);
        Assert.IsTrue(coldHits > 0);
        Assert.IsTrue(perSearch < 15, $"5000 条一次搜索 {perSearch:F1} ms，太慢");
    }
}
