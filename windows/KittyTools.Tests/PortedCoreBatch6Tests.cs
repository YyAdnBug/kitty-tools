// 第二版第 6 批：把 mac 那边常见、Windows 这边还没覆盖到的纯函数用例补一批
// （计算器、网页搜索、撤销栈、识字的段落整理）。期望值按 PLAN §8 / PLAN-v3 §1.5 的规则手写。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class CalculatorPortedTests
{
    [TestMethod]
    public void PrecedenceAndParentheses()
    {
        Assert.AreEqual(7, Calculator.Evaluate("1+2*3"));
        Assert.AreEqual(9, Calculator.Evaluate("(1+2)*3"));
        Assert.AreEqual(-5, Calculator.Evaluate("-1-4"));
        Assert.AreEqual(2, Calculator.Evaluate("10/5"));
        Assert.AreEqual(0.75, Calculator.Evaluate("3/4"));
    }

    [TestMethod]
    public void PercentFollowsMacSemantics()
    {
        // 200*15% = 30、100+10% = 110、50% = 0.5（同 macOS 计算器）。
        Assert.AreEqual(30, Calculator.Evaluate("200*15%"));
        Assert.AreEqual(110, Calculator.Evaluate("100+10%"));
        Assert.AreEqual(0.5, Calculator.Evaluate("50%"));
    }

    [TestMethod]
    public void PowerIsRightAssociative()
    {
        Assert.AreEqual(512, Calculator.Evaluate("2^3^2"));
        Assert.AreEqual(8, Calculator.Evaluate("2**3"));
    }

    [TestMethod]
    public void RejectsDatesIncompleteAndJunk()
    {
        // 日期本身能算成数字（2024-1-1），但启动器不当它是算式。
        Assert.AreEqual(2022, Calculator.Evaluate("2024-01-01"));
        Assert.IsNull(Calculator.ResultFor("2024-01-01"));
        Assert.IsNull(Calculator.Evaluate("1+"));
        Assert.IsNull(Calculator.Evaluate("hello"));
        Assert.IsNull(Calculator.Evaluate("1/0"));
        Assert.IsNull(Calculator.ResultFor("42"));
    }

    [TestMethod]
    public void NormalizesFullWidthAndThousands()
    {
        Assert.AreEqual("(1+2)*3", Calculator.Normalize("（１＋２）＊３"));
        Assert.AreEqual(3000, Calculator.Evaluate("1,000+2,000"));
        Assert.AreEqual(9, Calculator.Evaluate("3×3")!.Value);
        Assert.AreEqual(3, Calculator.Evaluate("9÷3")!.Value);
    }

    [TestMethod]
    public void FormatsWithoutFloatNoise()
    {
        Assert.AreEqual("0.3", Calculator.Format(0.1 + 0.2));
        Assert.AreEqual("30", Calculator.Format(30.000));
        Assert.AreEqual("1E20", Calculator.Format(1e20)); // 同 mac（Foundation 的科学计数不带 +）
    }
}

[TestClass]
public sealed class WebSearchPortedTests
{
    [TestMethod]
    public void PresetIdsMatchTheSyncContract()
    {
        var ids = WebSearch.Presets.Select(engine => engine.Id).ToArray();
        CollectionAssert.AreEqual(
            new[]
            {
                "google", "bing", "baidu", "github", "zhihu", "bilibili", "wikipedia", "youtube",
                "maps", "taobao", "jd", "douban", "mdn",
            },
            ids);
        // 默认只带前 8 个，兜底只有一个。
        var defaults = WebSearch.Defaults();
        Assert.AreEqual(8, defaults.Count);
        Assert.AreEqual(1, defaults.Count(engine => engine.Fallback));
    }

    [TestMethod]
    public void KeywordSearchBuildsUrl()
    {
        var engines = WebSearch.Defaults();
        var item = WebSearch.KeywordItem("g swift concurrency", engines);
        Assert.IsNotNull(item);
        Assert.AreEqual("https://www.google.com/search?q=swift%20concurrency", item!.Target);
        Assert.IsNull(WebSearch.KeywordItem("g", engines));
        Assert.IsNull(WebSearch.KeywordItem("nokeyword swift", engines));
    }

    [TestMethod]
    public void FallbackNeedsTwoCharacters()
    {
        var engines = WebSearch.Defaults();
        Assert.AreEqual(0, WebSearch.FallbackItems("a", engines).Count);
        Assert.AreEqual(1, WebSearch.FallbackItems("swift", engines).Count);
    }

    [TestMethod]
    public void MapsUsesMacSchemeButOpensWithWindowsMaps()
    {
        var maps = WebSearch.Presets.First(engine => engine.Id == "maps");
        Assert.AreEqual("maps://?q=%E5%92%96%E5%95%A1", WebSearch.Url(maps, "咖啡"));
        Assert.AreEqual("bingmaps:?q=%E5%92%96%E5%95%A1", WebSearch.OpenUrl(WebSearch.Url(maps, "咖啡")));
        Assert.AreEqual("https://example.com", WebSearch.OpenUrl("https://example.com"));
    }
}

[TestClass]
public sealed class UndoStackPortedTests
{
    [TestMethod]
    public void TakesMatchAndDropsEmptyBatch()
    {
        var first = new List<string> { "a" };
        var second = new List<string> { "b", "c" };
        var batches = new List<List<string>> { first, second };

        Assert.AreEqual("c", UndoStack.Take(batches, item => item == "c"));
        Assert.AreEqual(1, first.Count);
        Assert.AreEqual(1, second.Count);

        Assert.AreEqual("a", UndoStack.Take(batches, item => item == "a"));
        Assert.AreEqual(1, batches.Count);
        Assert.AreSequenceEqual(new[] { "b" }, batches[0]);

        Assert.IsNull(UndoStack.Take(batches, item => item == "missing"));
    }
}

[TestClass]
public sealed class OcrTextPortedTests
{
    [TestMethod]
    public void EmptyInputIsEmpty()
    {
        Assert.AreEqual(0, OcrText.Paragraphs(Array.Empty<OcrLine>()).Count);
    }

    [TestMethod]
    public void CloseLinesJoinIntoOneParagraph()
    {
        var lines = new[]
        {
            new OcrLine("Hello", new RectD(0, 0, 200, 20)),
            new OcrLine("world", new RectD(0, 22, 200, 20)),
        };
        var paragraphs = OcrText.Paragraphs(lines);
        Assert.AreEqual(1, paragraphs.Count);
        Assert.AreEqual("Hello world", string.Join(" ", paragraphs[0]));
    }

    [TestMethod]
    public void BigGapStartsNewParagraph()
    {
        var lines = new[]
        {
            new OcrLine("First.", new RectD(0, 0, 100, 20)),
            new OcrLine("Second", new RectD(0, 200, 100, 20)),
        };
        Assert.AreEqual(2, OcrText.Paragraphs(lines).Count);
    }
}
