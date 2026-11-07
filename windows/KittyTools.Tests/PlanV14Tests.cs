// PLAN-v14（翻译反馈四条）的纯函数：有道词典的词条怎么写成单词卡（照 mac FreeServicesTests，样本 JSON 照抄）、
// 词典类服务不当主结果、卡片喇叭读哪段字 / 读音行 / 真人录音地址（照 mac SpeakerTests）、拖边改大小的行数换算和翻译浮窗的上限
// （照 mac PanelSizeTests）。
using System.Text.Json;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class YoudaoDictTests
{
    /// <summary>有道词典接口返回的英汉词条（mac 2026-11-05 真实返回里摘的几段，结构原样）。</summary>
    private const string Stuff = """
        {
          "ec": {
            "word": [{
              "usphone": "stʌf", "ukphone": "stʌf",
              "trs": [
                {"tr": [{"l": {"i": ["n. 东西，物品；基本特征，特质"]}}]},
                {"tr": [{"l": {"i": ["v. 塞进，填进；填满，装满"]}}]}
              ],
              "wfs": [
                {"wf": {"name": "现在分词", "value": "stuffing"}},
                {"wf": {"name": "过去式", "value": "stuffed"}}
              ]
            }]
          },
          "blng_sents_part": {
            "sentence-pair": [{
              "sentence": "It's amazing how people collect so much stuff over the years.",
              "sentence-translation": "人们这些年下来竟能收集到这么多东西，真令人惊奇。"
            }]
          }
        }
        """;

    private static string? Entry(string json)
    {
        using var document = JsonDocument.Parse(json);
        return YoudaoDict.Entry(document.RootElement);
    }

    [TestMethod]
    public void EnglishEntryLooksLikeAWordCard()
    {
        var entry = Entry(Stuff);
        Assert.AreEqual(
            "美 /stʌf/  英 /stʌf/\n" +
            "n. 东西，物品；基本特征，特质\n" +
            "v. 塞进，填进；填满，装满\n" +
            "变形：现在分词 stuffing；过去式 stuffed\n" +
            "例：It's amazing how people collect so much stuff over the years. 人们这些年下来竟能收集到这么多东西，真令人惊奇。",
            entry);
        // 第一行是读音行：卡片上换成带小喇叭的一行；右上角的喇叭读第一条释义
        Assert.AreEqual(2, SpeechText.PhoneticLine(entry!)?.Phonetics.Count);
        Assert.AreEqual("东西，物品；基本特征，特质", SpeechText.ForCard(entry!, wordStyle: true));
    }

    [TestMethod]
    public void ChineseEntryAndMisses()
    {
        const string name = """
            {"ce": {"word": [{
              "phone": "míng zì",
              "trs": [
                {"tr": [{"l": {"pos": "n.", "i": ["", {"#text": "name", "@action": "link"}]}}]},
                {"tr": [{"l": {"pos": "n.", "i": ["", {"#text": "monicker"}]}}]}
              ]
            }]}}
            """;
        Assert.AreEqual("míng zì\nn. name\nn. monicker", Entry(name));
        // 没查到（空、只有读音没有释义）
        Assert.IsNull(Entry("{}"));
        Assert.IsNull(Entry("""{"ec": {"word": [{"usphone": "x"}]}}"""));
        Assert.IsNull(Entry("[]"));
    }

    [TestMethod]
    public void RequestOnlyAsksForThreeSections()
    {
        var url = YoudaoDict.RequestUrl(" stuff ").AbsoluteUri;
        StringAssert.StartsWith(url, "https://dict.youdao.com/jsonapi?q=stuff&dicts=");
        Assert.AreEqual("{\"count\":99,\"dicts\":[[\"ec\",\"ce\",\"blng_sents_part\"]]}",
            Uri.UnescapeDataString(url[(url.IndexOf("dicts=", StringComparison.Ordinal) + 6)..]));
    }

    [TestMethod]
    public void PhrasesAreTwoToThreeWords()
    {
        Assert.IsTrue(WordLookup.IsPhrase("ice cream"));
        Assert.IsTrue(WordLookup.IsPhrase("look it up"));
        Assert.IsTrue(WordLookup.IsPhrase("don't worry"));
        Assert.IsFalse(WordLookup.IsPhrase("stuff"));
        Assert.IsFalse(WordLookup.IsPhrase("How are you doing today?"));
        Assert.IsFalse(WordLookup.IsPhrase("a b c d"));
        Assert.IsFalse(WordLookup.IsPhrase("ice\ncream"));
        Assert.IsFalse(WordLookup.IsPhrase("3 apples"));
        // 单词模式的判断不变：2–3 个词照旧走普通翻译（第四轮体检 U2）
        Assert.IsFalse(WordLookup.IsWord("ice cream"));
    }

    [TestMethod]
    public void DictionaryCardsAreNeverPrimary()
    {
        // 有道词典排在前面、先出来：主结果跳过它，认后面那张翻译卡
        var cards = new List<(CardState, string, bool)>
        {
            (CardState.Done, "美 /stʌf/\nn. 东西", true),
            (CardState.Done, "东西", false),
        };
        Assert.AreEqual(1, TranslateSession.Primary(cards));
        // 词典卡还在跑：不挡后面的
        cards[0] = (CardState.Running, string.Empty, true);
        Assert.AreEqual(1, TranslateSession.Primary(cards));
        // 只有词典卡：没有主结果
        Assert.AreEqual(-1, TranslateSession.Primary(new List<(CardState, string, bool)> { (CardState.Done, "x", true) }));
    }
}

[TestClass]
public sealed class SpeechTextTests
{
    [TestMethod]
    public void WordCardsReadOnlyTheMeaning()
    {
        const string card = "美 /neɪm/  英 /neɪm/\nn. 名字；名称；名声\nv. 命名；任命\n例：What is your name? 你叫什么名字？";
        Assert.AreEqual("名字；名称；名声", SpeechText.ForCard(card, wordStyle: true));
        // 不是单词卡：整段，只去掉 Markdown 记号
        Assert.AreEqual("发布吧\n上线", SpeechText.ForCard("**发布**吧\n- 上线", wordStyle: false));
        // 汉译英：第一行是拼音，跳过
        const string apple = "píngguǒ\nn. apple; apple tree\nExample: 我每天吃一个苹果。 I eat an apple every day.";
        Assert.AreEqual("apple; apple tree", SpeechText.ForCard(apple, wordStyle: true));
        // 粗体的词性记号、只有读音行时退回整段
        Assert.AreEqual("跑；运转", SpeechText.ForCard("美 /rʌn/\n**v.** 跑；运转", wordStyle: true));
        Assert.AreEqual("美 /rʌn/", SpeechText.ForCard("美 /rʌn/", wordStyle: true));
        // adj. & adv. 这种两个词性连写
        Assert.AreEqual("快；快地", SpeechText.ForCard("美 /fæst/\nadj. & adv. 快；快地", wordStyle: true));
    }

    [TestMethod]
    public void PhoneticLineIsSplitOff()
    {
        var line = SpeechText.PhoneticLine("美 /rʌn/  英 /rʌn/\nv. 跑");
        Assert.IsNotNull(line);
        CollectionAssert.AreEqual(
            new[] { new Phonetic(Accent.Us, "rʌn"), new Phonetic(Accent.Uk, "rʌn") }, line.Value.Phonetics.ToArray());
        Assert.AreEqual("v. 跑", line.Value.Body);
        // 方括号写法也认；第一行还没出完、第一行不全是读音都不拆
        Assert.AreEqual(Accent.Uk, SpeechText.PhoneticLine("英 [neɪm] 美 [neɪm]\nn. 名字")?.Phonetics[0].Accent);
        Assert.IsNull(SpeechText.PhoneticLine("美 /rʌn/  英 /rʌ"));
        Assert.IsNull(SpeechText.PhoneticLine("美国 /rʌn/ 是\nv. 跑"));
        Assert.IsNull(SpeechText.PhoneticLine("v. 跑；运转\n例：…"));
        // 粗体记号去掉再看
        Assert.IsNotNull(SpeechText.PhoneticLine("**美 /rʌn/**\nv. 跑"));
    }

    [TestMethod]
    public void RecordingsOnlyForEnglishWords()
    {
        Assert.AreEqual("https://dict.youdao.com/dictvoice?audio=stuff&type=1", SpeechText.RecordingUrl("stuff", Accent.Uk)?.AbsoluteUri);
        Assert.AreEqual("?audio=ice%20cream&type=2", SpeechText.RecordingUrl("ice cream", Accent.Us)?.Query);
        Assert.IsNotNull(SpeechText.RecordingUrl("don't", Accent.Us));
        Assert.IsNull(SpeechText.RecordingUrl("名字", Accent.Us));
        Assert.IsNull(SpeechText.RecordingUrl("café", Accent.Us));
        Assert.IsNull(SpeechText.RecordingUrl("a b c d", Accent.Us));
        Assert.IsNull(SpeechText.RecordingUrl(new string('a', 41), Accent.Us));
        Assert.AreNotEqual(SpeechText.Key("run", Accent.Us), SpeechText.Key("run", Accent.Uk));
        Assert.AreEqual(Accent.Uk, SpeechText.ParseAccent("uk"));
        Assert.AreEqual(Accent.Us, SpeechText.ParseAccent("xx"));
        Assert.AreEqual(Accent.Us, SpeechText.ParseAccent(null));
    }

    [TestMethod]
    public void EnglishWordsOnly()
    {
        Assert.AreEqual("stuff", SpeechText.EnglishWord(" stuff ", Lang.En));
        Assert.AreEqual("stuff", SpeechText.EnglishWord("stuff", null));
        Assert.IsNull(SpeechText.EnglishWord("stuff", Lang.De));
        Assert.IsNull(SpeechText.EnglishWord("ice cream", Lang.En));
        Assert.IsNull(SpeechText.EnglishWord("苹果", Lang.ZhHans));
        Assert.IsNull(SpeechText.EnglishWord("café", null));
    }

    [TestMethod]
    public void MarkdownIsStrippedBeforeReading()
    {
        Assert.AreEqual("标题\n引用\n一项\n链接 代码", SpeechText.WithoutMarkdown("# 标题\n> 引用\n* 一项\n[链接](https://a.b) `代码`"));
        Assert.AreEqual("let a = 1", SpeechText.WithoutMarkdown("```\nlet a = 1\n```"));
    }
}

[TestClass]
public sealed class PanelSizeTests
{
    [TestMethod]
    public void ClipboardRowsFollowTheDraggedHeight()
    {
        // 默认 8.5 行就是原来的 428，null / 0 = 默认
        Assert.AreEqual(PanelMetrics.ClipboardListMax, PanelMetrics.ClipboardListMaxFor(null));
        Assert.AreEqual(PanelMetrics.ClipboardListMax, PanelMetrics.ClipboardListMaxFor(0));
        Assert.AreEqual(PanelMetrics.ClipboardListMax, PanelMetrics.ClipboardListMaxFor(8.5));
        Assert.AreEqual(PanelMetrics.MaxHeightDip, PanelMetrics.ClipboardMaxHeight(null));
        for (var rows = 6.5; rows <= 14.5; rows += 1)
        {
            var height = PanelMetrics.ClipboardMaxHeight(rows);
            Assert.AreEqual(rows, PanelMetrics.ClipboardRowsFor(height));
            // 拖到两行之间：吸到最近的半行
            Assert.AreEqual(rows, PanelMetrics.ClipboardRowsFor(height + ClipListLayout.RowHeight * 0.3));
        }

        // 夹在 6.5–14.5 里；拖的范围和它对得上
        Assert.AreEqual(6.5, PanelMetrics.ClipboardRowsFor(0));
        Assert.AreEqual(14.5, PanelMetrics.ClipboardRowsFor(5000));
        var (min, max) = PanelMetrics.ClipboardHeightRange();
        Assert.AreEqual(6.5, PanelMetrics.ClipboardRowsFor(min));
        Assert.AreEqual(14.5, PanelMetrics.ClipboardRowsFor(max));
        // 拖出来的行数封顶面板高度
        Assert.AreEqual(PanelMetrics.ClipboardMaxHeight(10.5), PanelMetrics.ClipboardHeightFor(200, 3, maxRows: 10.5));
        Assert.IsTrue(PanelMetrics.ClipboardHeightFor(200, 3, maxRows: 10.5) > PanelMetrics.ClipboardHeightFor(200, 3));
    }

    [TestMethod]
    public void LauncherRowsFollowTheDraggedHeight()
    {
        var (min, max) = LauncherListLayout.HeightRange(groups: 2);
        Assert.AreEqual(6.5, LauncherListLayout.RowsFor(min, 2));
        Assert.AreEqual(14.5, LauncherListLayout.RowsFor(max, 2));
        Assert.AreEqual(8.5, LauncherListLayout.RowsFor(min + 2.2 * LauncherListLayout.RowHeight, 2));
        Assert.AreEqual(14.5, LauncherListLayout.RowsFor(10_000, 2));
        // 默认 8.5 行和原来一样；拖到 10.5 行就多露两行
        var rows = Enumerable.Repeat(LauncherListLayout.RowHeight, 30).ToList();
        Assert.AreEqual(2 * 6 + 8.5 * 40, LauncherListLayout.ListHeight(rows, 0));
        Assert.AreEqual(2 * 6 + 10.5 * 40, LauncherListLayout.ListHeight(rows, 0, 10.5));
        // 计算卡那种高行照实际高度
        var mixed = new List<double> { 64 }.Concat(Enumerable.Repeat(40.0, 20)).ToList();
        Assert.AreEqual(2 * 6 + 64 + 5 * 40 + 20, LauncherListLayout.ListHeight(mixed, 0, 6.5));
    }

    [TestMethod]
    public void TranslateCapWins()
    {
        const double visible = 1000;
        // 没拖过：照旧（85%、放得下前三张卡）
        Assert.AreEqual(850, TranslateSession.PanelHeight(2000, 0, visible));
        Assert.AreEqual(920, TranslateSession.PanelHeight(2000, 920, visible));
        // 拖过：照它（前三张卡也不例外，卡片区里滚）；内容少时照样变矮；夹在最矮和可见区减 24 之间
        Assert.AreEqual(400, TranslateSession.PanelHeight(2000, 920, visible, cap: 400));
        Assert.AreEqual(300, TranslateSession.PanelHeight(300, 0, visible, cap: 400));
        Assert.AreEqual(220, TranslateSession.PanelHeight(2000, 0, visible, cap: 100));
        Assert.AreEqual(976, TranslateSession.PanelHeight(2000, 0, visible, cap: 5000));
    }

    [TestMethod]
    public void WidthsAreClamped()
    {
        Assert.AreEqual(720, PanelMetrics.PanelWidth(null, 1920));
        Assert.AreEqual(560, PanelMetrics.PanelWidth(100, 1920));
        Assert.AreEqual(1200, PanelMetrics.PanelWidth(5000, 1920));
        // 也不超过那块屏工作区的宽
        Assert.AreEqual(640, PanelMetrics.PanelWidth(900, 640));
        Assert.IsNull(PanelMetrics.StoredRows(3));
        Assert.AreEqual(10.5, PanelMetrics.StoredRows(10.5));
    }
}
