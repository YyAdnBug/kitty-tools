// 设置里收成一行的那几项的小字（PLAN-v18 L4，照 mac FeatureTests.featuresSummary、SettingsListTests.engineSummary）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsSummaryTests
{
    [TestMethod]
    public void FeaturesSummary()
    {
        var names = new[] { "剪贴板", "启动器", "翻译", "截图", "录制", "便签" };
        (string, bool)[] With(params string[] on) => names.Select(name => (name, on.Contains(name))).ToArray();
        Assert.AreEqual("6 个功能都开着", SettingsSummary.Features(With(names)));
        Assert.AreEqual("6 个功能都关着", SettingsSummary.Features(With()));
        Assert.AreEqual("开着 5 个；关着：便签", SettingsSummary.Features(With(names[..5])));
        Assert.AreEqual("开着：剪贴板、启动器；另外 4 个关着", SettingsSummary.Features(With("剪贴板", "启动器")));
    }

    [TestMethod]
    public void EngineSummary()
    {
        static SearchEngine Engine(string id, string name, string keyword, string url, bool fallback = false)
            => new() { Id = id, Name = name, Keyword = keyword, UrlTemplate = url, Fallback = fallback };
        var google = Engine("g", "Google", "g", "https://g.com/?q={query}", true);
        var bing = Engine("b", "Bing", "b", "https://b.com/?q={query}", true);
        var wiki = Engine("w", "维基", "w", "https://w.com/?q={query}");
        var docs = Engine("d", "文档", string.Empty, "https://d.com");
        Assert.AreEqual("还没有，点进去添加", WebSearch.Summary(Array.Empty<SearchEngine>()));
        Assert.AreEqual("3 个搜索、1 个快捷链接；兜底：Google、Bing", WebSearch.Summary(new[] { google, bing, wiki, docs }));
        Assert.AreEqual("1 个搜索，不兜底", WebSearch.Summary(new[] { wiki }));
        var more = Enumerable.Range(1, 4).Select(i => Engine($"e{i}", $"E{i}", $"k{i}", "https://e.com/?q={query}", true)).ToArray();
        Assert.AreEqual("4 个搜索；兜底：E1、E2、E3 等 4 个", WebSearch.Summary(more));
        var broken = Engine("x", "  ", string.Empty, "https://");
        Assert.AreEqual("1 个搜索、1 个快捷链接；兜底：Google；1 条要改一下", WebSearch.Summary(new[] { google, broken }));
    }
}
