// 设置侧栏搜索停在哪页（PLAN-v23 W4 W5，照 mac SettingsListTests 里 page(for:current:) / matching(hidden:) 那几条）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsSearchTests
{
    private static readonly HashSet<string> None = new();

    private static readonly SettingsSearchPage[] Pages =
    {
        new("general", "通用", new[] { "外观", "屏幕录制", "插件" }),
        new("clipboard", "剪贴板", new[] { "历史" }),
        new("record", "录制", new[] { "录屏", "只显示快捷键" }),
        new("keepAwake", "保持唤醒", new[] { "防止睡眠" }),
        new("hotkeys", "快捷键", new[] { "录制", "截图翻译" }),
        new("about", "关于", new[] { "欢迎", "引导" }),
    };

    [TestMethod]
    public void PageNameWinsOverEarlierKeywordMatches()
    {
        // 「录」：通用（屏幕录制）、录制、快捷键（录制）都对上，停在页名里有「录」的录制
        Assert.AreEqual("record", SettingsSearch.PageFor(Pages, "录", "about", None));
        Assert.AreEqual("record", SettingsSearch.PageFor(Pages, "录制", "general", None));
        // 「快捷键」也是录制页的「只显示快捷键」：停在快捷键页
        Assert.AreEqual("hotkeys", SettingsSearch.PageFor(Pages, "快捷键", "record", None));
    }

    [TestMethod]
    public void StaysOnTheCurrentPageWhenItStillMatches()
    {
        Assert.AreEqual("hotkeys", SettingsSearch.PageFor(Pages, "截图翻译", "hotkeys", None));
        Assert.AreEqual("hotkeys", SettingsSearch.PageFor(Pages, "截图翻译", "general", None));
        Assert.AreEqual("clipboard", SettingsSearch.PageFor(Pages, "", "clipboard", None));
        // 一页都没对上：不动
        Assert.AreEqual("clipboard", SettingsSearch.PageFor(Pages, "没有这个词", "clipboard", None));
        Assert.AreEqual(0, SettingsSearch.Matching(Pages, "没有这个词", None).Count);
    }

    [TestMethod]
    public void HiddenPluginsMatchAsTheGeneralPage()
    {
        var hidden = new HashSet<string> { "keepAwake" };
        CollectionAssert.AreEqual(new[] { "general" }, SettingsSearch.Matching(Pages, "唤醒", hidden));
        Assert.AreEqual("general", SettingsSearch.PageFor(Pages, "防止睡眠", "about", hidden));
        // 添加了：停在它自己那页，通用页不跟着对上
        CollectionAssert.AreEqual(new[] { "keepAwake" }, SettingsSearch.Matching(Pages, "唤醒", None));
        Assert.AreEqual("keepAwake", SettingsSearch.PageFor(Pages, "唤醒", "general", None));
        // 空搜索不列没添加的插件
        CollectionAssert.DoesNotContain(SettingsSearch.Matching(Pages, " ", hidden), "keepAwake");
    }

    [TestMethod]
    public void IgnoresCaseAndSurroundingSpaces()
    {
        var pages = new[] { new SettingsSearchPage("launcher", "启动器", new[] { "Chrome" }) };
        CollectionAssert.AreEqual(new[] { "launcher" }, SettingsSearch.Matching(pages, "  chrome ", None));
    }

    /// <summary>PLAN-v26 G1：搜「朗读」落到「朗读速度」那一行；标题没有就看说明；只是页的关键词对上的停在页顶。</summary>
    [TestMethod]
    public void RowForPrefersTitles()
    {
        var rows = new[] { ("翻译服务", "朗读用系统的声音"), ("朗读速度", "慢一点、快一点"), ("自动复制", string.Empty) };
        Assert.AreEqual(1, SettingsSearch.RowFor(rows, "朗读"));
        Assert.AreEqual(0, SettingsSearch.RowFor(rows, "系统的声音"));
        Assert.IsNull(SettingsSearch.RowFor(rows, "Chrome"));
        Assert.IsNull(SettingsSearch.RowFor(rows, "  "));
    }
}
