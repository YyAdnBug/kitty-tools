// 第三版第 2 批的纯函数单测：云厂商签名、语言码、查词判断、历史导出、快捷键/格式边界。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class TranslateSigningTests
{
    [TestMethod]
    public void BaiduSignIsMd5OfConcatenation()
    {
        Assert.AreEqual(
            "e96213d384c6cf4bb4473c6ed74451b5",
            TranslateSigning.BaiduSign("app123", "hello world", "987654", "secret"));
        Assert.AreEqual(
            "5d41402abc4b2a76b9719d911017c592",
            TranslateSigning.BaiduSign(string.Empty, "hello", string.Empty, string.Empty));
    }

    [TestMethod]
    public void YoudaoSignUsesShortInputRule()
    {
        // mac ProviderSigningTests 里的固定向量（前 10 字 + 字数 + 后 10 字）。
        var text = "这是一段超过二十个字的中文文本，用来测试有道签名的截断规则是否正确";
        Assert.AreEqual(
            "460d2560f033e6e5421c6dac276a5eedff8ff116a18054c0a1fb7c0caddde8ab",
            TranslateSigning.YoudaoSign("app123", text, "salt-789", "1790000000", "secret456"));
    }

    [TestMethod]
    public void HmacAndShaAreLowercaseHex()
    {
        Assert.AreEqual(
            "8b5f48702995c1598c573db1e21866a9b825d4a794d169d7060a03605796360b",
            TranslateSigning.HmacHex("secret"u8.ToArray(), "message"));
        Assert.AreEqual(
            "6186b9a6bb71c680cad0eabad38447c21c35e35fb4b8028cea6178c211d1cbfe",
            TranslateSigning.Sha256Hex("appKey中文测试abcdef"));
    }

    [TestMethod]
    public void VolcengineHeadersAreStableAndSigned()
    {
        // mac ProviderSigningTests 的固定向量。
        var body = "{\"TargetLanguage\":\"zh\",\"TextList\":[\"Hello\"]}"u8.ToArray();
        var date = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000).UtcDateTime;
        var headers = TranslateSigning.VolcengineHeaders("AKLTexample", "secretExample==", body, date);
        Assert.AreEqual("20260921T141320Z", headers["X-Date"]);
        Assert.AreEqual(
            "HMAC-SHA256 Credential=AKLTexample/20260921/cn-north-1/translate/request, " +
            "SignedHeaders=content-type;host;x-content-sha256;x-date, " +
            "Signature=b4cb639f34c3dfde96cf8f999f0b73c489dfdd13ddb97c584ac223d61aaa9de7",
            headers["Authorization"]);
    }

    [TestMethod]
    public void TencentHeadersFollowTc3()
    {
        // mac ProviderSigningTests 的固定向量。
        var body = "{\"SourceText\":\"Hello\",\"Source\":\"auto\",\"Target\":\"zh\",\"ProjectId\":0}"u8.ToArray();
        var headers = TranslateSigning.TencentHeaders("AKIDexample", "tencentSecret", body, 1_790_000_000);
        Assert.AreEqual(
            "TC3-HMAC-SHA256 Credential=AKIDexample/2026-09-21/tmt/tc3_request, " +
            "SignedHeaders=content-type;host, " +
            "Signature=b2508c75f3a556c695d9ad2be875ee2c23d68274afc02489fe9ea255693d9403",
            headers["Authorization"]);
        Assert.AreEqual("TextTranslate", headers["X-TC-Action"]);
        Assert.AreEqual("1790000000", headers["X-TC-Timestamp"]);
    }

    [TestMethod]
    public void LanguageCodesMatchTheProviders()
    {
        Assert.AreEqual("zh", TranslateSigning.BaiduCode("zh-Hans"));
        Assert.AreEqual("cht", TranslateSigning.BaiduCode("zh-Hant"));
        Assert.AreEqual("jp", TranslateSigning.BaiduCode("ja"));
        Assert.AreEqual("kor", TranslateSigning.BaiduCode("ko"));
        Assert.AreEqual("fra", TranslateSigning.BaiduCode("fr"));
        Assert.AreEqual("spa", TranslateSigning.BaiduCode("es"));
        Assert.AreEqual("auto", TranslateSigning.BaiduCode(null));

        Assert.AreEqual("zh-CHS", TranslateSigning.YoudaoCode("zh-Hans"));
        Assert.AreEqual("zh-CHT", TranslateSigning.YoudaoCode("zh-Hant"));
        Assert.AreEqual("zh", TranslateSigning.VolcengineCode("zh-Hans"));
        Assert.AreEqual("zh-TW", TranslateSigning.TencentCode("zh-Hant"));
    }
}

[TestClass]
public sealed class WordLookupTests
{
    [TestMethod]
    public void SingleWordsAndShortPhrases()
    {
        Assert.IsTrue(WordLookup.IsWord("swift"));
        Assert.IsTrue(WordLookup.IsWord("look up"));
        Assert.IsTrue(WordLookup.IsWord("a piece of"));
        Assert.IsTrue(WordLookup.IsWord("well-known"));
        Assert.IsTrue(WordLookup.IsWord("don't"));
        Assert.IsTrue(WordLookup.IsWord("雨"));
        Assert.IsTrue(WordLookup.IsWord("日本語"));
        Assert.IsTrue(WordLookup.IsWord("안녕"));
    }

    [TestMethod]
    public void SentencesAndSentencesWithPunctuationAreNot()
    {
        Assert.IsFalse(WordLookup.IsWord("this is a longer sentence"));
        Assert.IsFalse(WordLookup.IsWord("hello, world"));
        Assert.IsFalse(WordLookup.IsWord("你好，世界"));
        Assert.IsFalse(WordLookup.IsWord("12345"));
        Assert.IsFalse(WordLookup.IsWord("这是一句比较长的话"));
        Assert.IsFalse(WordLookup.IsWord(null));
        Assert.IsFalse(WordLookup.IsWord("   "));
    }
}

[TestClass]
public sealed class HistoryExportTests
{
    /// <summary>和 mac 的 exportCSVAndAnkiTSV 同一组输入、同样的输出（PLAN-v9-translate B12）。</summary>
    [TestMethod]
    public void CsvAndAnkiTsvMatchMac()
    {
        var shanghai = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");
        var entry = new HistoryRow("say \"hi\", ok\r\nline2", "-ing\t<b>&", "zh-Hans", "智谱", 0, true);
        var csv = HistoryExport.Csv(new[] { entry }, shanghai);
        StringAssert.StartsWith(csv, "原文,译文,目标语言,服务,时间,收藏\r\n");
        StringAssert.Contains(csv, "\"say \"\"hi\"\", ok\r\nline2\",");
        StringAssert.Contains(csv, ",'-ing\t<b>&,");
        StringAssert.Contains(csv, ",简体中文,智谱,");
        StringAssert.EndsWith(csv, ",1970-01-01 08:00:00,是\r\n");

        var tsv = HistoryExport.AnkiTsv(new[]
        {
            entry,
            new HistoryRow("# Getting Started", "a\rb\u2028c", "zh-Hans", string.Empty, 0, false),
        });
        Assert.AreEqual(
            "#separator:tab\n#html:true\n" +
            "\"say \"\"hi\"\", ok<br>line2\"\t-ing &lt;b&gt;&amp;\n" +
            "\"# Getting Started\"\ta<br>b<br>c\n",
            tsv);
    }
}

[TestClass]
public sealed class RetentionHistoryTests
{
    [TestMethod]
    public void HistoryRowTimeIsLocalMinutes()
    {
        var created = new DateTimeOffset(2026, 10, 25, 8, 30, 0, TimeSpan.Zero).ToUnixTimeMilliseconds();
        var text = HistoryExport.Time(created);
        StringAssert.StartsWith(text, "2026-10-25 ");
        StringAssert.Contains(text, ":");
    }
}
