// 启动器纯函数单测：拼音、匹配分档、计算器、网址 / 路径直达、网页搜索、使用分衰减。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherMatchTests
{
    [TestMethod]
    public void PinyinAndInitials()
    {
        var pinyin = Pinyin.For("活动监视器");
        Assert.IsNotNull(pinyin);
        Assert.AreEqual("huodongjianshiqi", pinyin.Value.Full);
        Assert.AreEqual("hdjsq", pinyin.Value.Initials);
        Assert.IsNull(Pinyin.For("Safari"));
        Assert.AreEqual("vsc", LauncherMatch.Initials("Visual Studio Code"));
        Assert.AreEqual("ac", LauncherMatch.Initials("AppCleaner"));
        Assert.AreEqual("wo", LauncherMatch.Initials("WPS Office"));
    }

    [TestMethod]
    public void MatchTiers()
    {
        var code = App("Visual Studio Code");
        Assert.AreEqual(100, Score(code, "visual studio code"));
        Assert.AreEqual(80, Score(code, "vis"));
        Assert.AreEqual(60, Score(code, "stu"));
        Assert.AreEqual(50, Score(code, "vsc"));
        Assert.AreEqual(40, Score(code, "dio"));
        Assert.AreEqual(60, Score(code, "visual code"));
        Assert.AreEqual(0, Score(code, "xyz"));
        Assert.AreEqual(0, Score(code, "visual xyz"));

        var monitor = App("Activity Monitor", chinese: "活动监视器");
        Assert.AreEqual(80, Score(monitor, "活动"));
        Assert.AreEqual(80, Score(monitor, "huodong"));
        Assert.AreEqual(50, Score(monitor, "hdjsq"));
        Assert.AreEqual(60, Score(monitor, "monitor"));
    }

    [TestMethod]
    public void RankBreaksTiesByPriorityThenTitleLength()
    {
        var app = App("Slack");
        var command = new LauncherItem
        {
            Kind = LauncherKind.Command,
            Title = "睡眠",
            Names = new List<string> { "睡眠", "shuimian", "sleep" },
            Initials = new List<string> { "sm" },
            Priority = 1,
        };
        var ranked = LauncherMatch.Rank(new[] { app, command }, "sl");
        Assert.AreEqual("Slack", ranked[0].Title);

        var chrome = App("Google Chrome");
        var chroma = App("Chroma");
        var byLength = LauncherMatch.Rank(new[] { chrome, chroma }, "chrom");
        Assert.AreEqual("Chroma", byLength[0].Title);
    }

    [TestMethod]
    public void UsageBoostBreaksTies()
    {
        var chrome = App("Google Chrome");
        var chess = App("Chess");
        var ranked = LauncherMatch.Rank(new[] { chrome, chess }, "ch", item =>
            item.Title == "Chess" ? new LauncherBoost(0, 1) : default);
        Assert.AreEqual("Chess", ranked[0].Title);
    }

    private static double Score(LauncherItem item, string query) => LauncherMatch.Score(query, item);

    private static LauncherItem App(string title, string? chinese = null)
    {
        var names = new List<string> { LauncherMatch.Fold(title) };
        var initials = new List<string> { LauncherMatch.Initials(title) };
        if (chinese is not null)
        {
            names.Add(LauncherMatch.Fold(chinese));
            if (Pinyin.For(chinese) is { } pinyin)
            {
                names.Add(pinyin.Full);
                initials.Add(pinyin.Initials);
            }
        }

        return new LauncherItem
        {
            Kind = LauncherKind.App,
            Title = title,
            Target = title,
            Names = names.Distinct().ToList(),
            Initials = initials.Distinct().ToList(),
        };
    }
}

[TestClass]
public sealed class LauncherCalculatorTests
{
    private static double? Value(string text) => Calculator.Evaluate(text);

    [TestMethod]
    public void Arithmetic()
    {
        Assert.AreEqual(7, Value("1+2*3"));
        Assert.AreEqual(9, Value("(1+2)*3"));
        Assert.AreEqual(512, Value("2^3^2"));
        Assert.AreEqual(1024, Value("2**10"));
        Assert.AreEqual(-4, Value("-2^2"));
        Assert.AreEqual(30, Value("200*15%"));
        Assert.AreEqual(110, Value("100+10%"));
        Assert.AreEqual(90, Value("100-10%"));
        Assert.AreEqual(0.5, Value("50%"));
        Assert.AreEqual(160, Value("80/50%"));
        Assert.AreEqual(0.02, Value("(1+1)%"));
        Assert.AreEqual(9, Value("（1+2）×3"));
        Assert.AreEqual(3897, Value("1,299*3"));
        Assert.AreEqual(3, Value("１＋２"));
        Assert.AreEqual(3, Value("9÷3"));
        Assert.IsNull(Value("1/0"));
        Assert.IsNull(Value("1+"));
        Assert.IsNull(Value("sqrt("));
        Assert.IsNull(Calculator.ItemFor("2024-01-01"));
        Assert.IsNull(Calculator.ItemFor("abc"));
        Assert.IsNull(Calculator.ItemFor("12"));
    }

    [TestMethod]
    public void Formatting()
    {
        Assert.AreEqual("3", Calculator.ItemFor("1+2")?.Payload);
        Assert.AreEqual("0.3", Calculator.Format(0.1 + 0.2));
        Assert.AreEqual("6.28318530718", Calculator.Format(2 * Math.PI));
        Assert.AreEqual("9007199254740992", Calculator.Format(Math.Pow(2, 53)));
    }
}

[TestClass]
public sealed class DirectItemsTests
{
    [TestMethod]
    public void Urls()
    {
        string? Url(string text) => DirectItems.UrlFrom(text);
        Assert.AreEqual("https://a.com/x", Url("https://a.com/x"));
        Assert.AreEqual("https://linux.do", Url("linux.do"));
        Assert.AreEqual("https://ui.shadcn.com/docs", Url("ui.shadcn.com/docs"));
        Assert.AreEqual("http://localhost:3000", Url("localhost:3000"));
        Assert.AreEqual("http://10.10.33.176:8089/app", Url("10.10.33.176:8089/app"));
        Assert.AreEqual("https://www.example.app", Url("www.example.app"));
        Assert.IsNull(Url("Safari.app"));
        Assert.IsNull(Url("file.txt"));
        Assert.IsNull(Url("install.sh"));
        Assert.IsNull(Url("hello world.com"));
        Assert.IsNull(Url("1.2.3"));
        Assert.AreEqual("https://docs.rs/serde", Url("docs.rs/serde"));
        Assert.AreEqual("https://bun.sh/docs", Url("bun.sh/docs"));
        Assert.AreEqual("https://example.test:8080", Url("example.test:8080"));
        Assert.IsNull(Url("Package.swift"));
        Assert.IsNull(Url("libfoo.so"));
        Assert.IsNull(Url("README.md:x"));
    }

    [TestMethod]
    public void DisplayNames()
    {
        Assert.AreEqual("linux.do/latest", DirectItems.DisplayName("https://linux.do/latest"));
        Assert.AreEqual("10.10.33.176:8089/app/",
            DirectItems.DisplayName("http://10.10.33.176:8089/app/"));
        Assert.AreEqual("zh.wikipedia.org/wiki/苹果",
            DirectItems.DisplayName("https://zh.wikipedia.org/wiki/%E8%8B%B9%E6%9E%9C"));
    }

    [TestMethod]
    public void Paths()
    {
        var directory = Path.Combine(Path.GetTempPath(), "kitty-launcher-test");
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "file.txt");
        File.WriteAllText(file, "x");
        try
        {
            Assert.AreEqual(Path.GetFullPath(file), DirectItems.ExistingPathFrom(file));
            Assert.AreEqual(Path.GetFullPath(directory), DirectItems.ExistingPathFrom(directory));
            Assert.AreEqual(
                Path.GetFullPath(file),
                DirectItems.ExistingPathFrom(@"%TEMP%\kitty-launcher-test\file.txt"));
            Assert.IsNull(DirectItems.ExistingPathFrom("./file.txt"));
            Assert.IsNull(DirectItems.ExistingPathFrom(@"C:\no\such\kitty\path"));
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            Assert.AreEqual(Path.GetFullPath(home), DirectItems.ExistingPathFrom("~"));
        }
        finally
        {
            File.Delete(file);
            Directory.Delete(directory);
        }
    }
}

[TestClass]
public sealed class WebSearchTests
{
    [TestMethod]
    public void DefaultsAndKeywords()
    {
        var engines = WebSearch.Defaults();
        Assert.AreEqual(8, engines.Count);
        Assert.AreEqual(1, engines.Count(engine => engine.Fallback));
        Assert.AreEqual("bing", engines.First(engine => engine.Fallback).Id);

        var item = WebSearch.KeywordItem("g swift", engines);
        Assert.IsNotNull(item);
        Assert.IsTrue(item.Target.StartsWith("https://www.google.com/search?q=swift", StringComparison.Ordinal));
        Assert.IsNull(WebSearch.KeywordItem("nope swift", engines));

        var fallback = WebSearch.FallbackItems("hello", engines);
        Assert.AreEqual(1, fallback.Count);
        Assert.AreEqual("Bing", fallback[0].Title.Contains("Bing") ? "Bing" : fallback[0].Title);
        Assert.IsTrue(fallback[0].Target.Contains("hello", StringComparison.Ordinal));
        Assert.AreEqual("bing", WebSearch.Primary(engines)?.Id);
    }

    [TestMethod]
    public void EncodesQuery()
    {
        var engine = WebSearch.Presets[0];
        Assert.AreEqual("https://www.google.com/search?q=a%20b%26c", WebSearch.Url(engine, "a b&c"));
    }
}

[TestClass]
public sealed class LauncherUsageMathTests
{
    [TestMethod]
    public void DecaysAndBoosts()
    {
        var day = 86_400_000L;
        var global = LauncherUsageMath.Decayed(1, 0, 14 * day, LauncherUsageMath.GlobalTimeConstantDays) + 1;
        Assert.IsTrue(Math.Abs(global - (1 / Math.E + 1)) < 1e-9);
        var query = LauncherUsageMath.Decayed(1, 0, 14 * day, LauncherUsageMath.QueryTimeConstantDays) + 1;
        Assert.IsTrue(Math.Abs(query - (1 + Math.Exp(-14.0 / 3))) < 1e-9);
        Assert.AreEqual("it", LauncherUsageMath.NormalizeQuery("  IT "));
        Assert.IsTrue(LauncherUsageMath.Multiplier(0, 0) == 1);
        Assert.IsTrue(LauncherUsageMath.Multiplier(1000, 1000) < 2.5);
    }
}
