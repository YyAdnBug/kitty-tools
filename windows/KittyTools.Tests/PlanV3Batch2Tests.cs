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
        // ≤ 20 字：直接用整段文字
        Assert.AreEqual(
            "eeaf5a8f12fe7f63ca2fdaec2dba58c3f870a1bc7b76bdecbafc8c961f39e06b",
            TranslateSigning.YoudaoSign("appKey", "中文测试abcdef", "salt", "1700000000", "secret"));

        // > 20 字：前 10 字 + 字数 + 后 10 字
        var text = "0123456789ABCDEFGHIJ0123456789";
        var expected = TranslateSigning.Sha256Hex(
            "appKey" + "0123456789" + text.Length + "0123456789" + "salt" + "time" + "secret");
        Assert.AreEqual(expected, TranslateSigning.YoudaoSign("appKey", text, "salt", "time", "secret"));
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
        var body = "{\"TargetLanguage\":\"zh\",\"TextList\":[\"hello\"]}"u8.ToArray();
        var date = new DateTime(2026, 10, 25, 12, 0, 0, DateTimeKind.Utc);
        var first = TranslateSigning.VolcengineHeaders("AK", "SK", body, date);
        var second = TranslateSigning.VolcengineHeaders("AK", "SK", body, date);
        Assert.AreEqual(first["Authorization"], second["Authorization"]);
        Assert.AreEqual("20261025T120000Z", first["X-Date"]);
        Assert.AreEqual(TranslateSigning.Sha256Hex(body), first["X-Content-Sha256"]);
        StringAssert.StartsWith(first["Authorization"], "HMAC-SHA256 Credential=AK/20261025/cn-north-1/translate/request");
        StringAssert.Contains(first["Authorization"], "SignedHeaders=content-type;host;x-content-sha256;x-date");

        var other = TranslateSigning.VolcengineHeaders("AK", "SK2", body, date);
        Assert.AreNotEqual(first["Authorization"], other["Authorization"]);
    }

    [TestMethod]
    public void TencentHeadersFollowTc3()
    {
        var body = "{\"SourceText\":\"hello\",\"Source\":\"en\",\"Target\":\"zh\"}"u8.ToArray();
        var headers = TranslateSigning.TencentHeaders("SID", "SKEY", body, 1_790_000_000);
        Assert.AreEqual("TextTranslate", headers["X-TC-Action"]);
        Assert.AreEqual("2018-03-21", headers["X-TC-Version"]);
        Assert.AreEqual("1790000000", headers["X-TC-Timestamp"]);
        var date = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000).UtcDateTime.ToString("yyyy-MM-dd");
        StringAssert.Contains(headers["Authorization"], $"Credential=SID/{date}/tmt/tc3_request");
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
    [TestMethod]
    public void CsvQuotesCommasQuotesAndNewlines()
    {
        var text = HistoryExport.Csv(new[]
        {
            new HistoryRow("a,b", "say \"hi\"", "zh-Hans", "zhipu", 0, true),
            new HistoryRow("line1\nline2", "ok", "en", "google", 0, false),
        });
        StringAssert.Contains(text, "\"a,b\"");
        StringAssert.Contains(text, "\"say \"\"hi\"\"\"");
        StringAssert.Contains(text, "\"line1\nline2\"");
        Assert.IsTrue(text.Contains("原文,译文,目标语言,服务,时间,收藏", StringComparison.Ordinal));
    }

    [TestMethod]
    public void TsvIsOneLinePerField()
    {
        var text = HistoryExport.AnkiTsv(new[]
        {
            new HistoryRow("a\tb\nc", "d", "zh-Hans", "zhipu", 0, true),
        });
        Assert.AreEqual(1, text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length);
        StringAssert.Contains(text, "a b c\td");
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
