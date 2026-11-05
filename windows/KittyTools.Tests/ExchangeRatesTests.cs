// PLAN-v12 N1：启动器汇率换算（ExchangeRates）——各种写法、不误伤算式和单位、小数位、默认目标、候选、用过的货币、汇率表的验和存。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ExchangeRatesTests
{
    private static readonly ExchangeRates.Table Rates = new(
        "2026-11-03",
        0,
        new Dictionary<string, double>
        {
            ["USD"] = 1, ["CNY"] = 7, ["JPY"] = 150, ["KRW"] = 1400, ["EUR"] = 0.5, ["KWD"] = 0.25,
        });

    private static void AssertRequest(string query, double amount, string from, string? to)
    {
        var request = ExchangeRates.RequestFor(query);
        Assert.IsNotNull(request, query);
        Assert.AreEqual(amount, request.Amount, 1e-9, query);
        Assert.AreEqual(from, request.From, query);
        Assert.AreEqual(to, request.To, query);
    }

    [TestMethod]
    public void ParsesTheUsualWritings()
    {
        AssertRequest("100 usd", 100, "USD", null);
        AssertRequest("100 美元 转 日元", 100, "USD", "JPY");
        AssertRequest("$100 in jpy", 100, "USD", "JPY");
        AssertRequest("100刀", 100, "USD", null);
        AssertRequest("usd 100", 100, "USD", null);
        AssertRequest("100万日元", 1_000_000, "JPY", null);
        AssertRequest("1.5k usd", 1500, "USD", null);
        AssertRequest("(100+50) 美元", 150, "USD", null);
        AssertRequest("100 美元是多少人民币", 100, "USD", "CNY");
        AssertRequest("100 usd to cny", 100, "USD", "CNY");
        AssertRequest("1 mop", 1, "MOP", null);
        // 只问汇率：按 1 算
        AssertRequest("美元兑人民币", 1, "USD", "CNY");
        AssertRequest("USD/CNY", 1, "USD", "CNY");
        AssertRequest("usd cny", 1, "USD", "CNY");
        AssertRequest("美元汇率", 1, "USD", null);
        // 繁体、英文名
        AssertRequest("100 港幣", 100, "HKD", null);
        AssertRequest("100 Japanese Yen", 100, "JPY", null);
    }

    [TestMethod]
    public void LeavesMathUnitsAndWordsAlone()
    {
        foreach (var query in new[] { "100/3", "1+1", "2024-01-01", "10 km", "5m", "all to try", "pen cup", "hello", "汇率" })
        {
            Assert.IsNull(ExchangeRates.RequestFor(query), query);
        }

        // 算式、单位换算照旧
        Assert.AreEqual("25", Calculator.ResultFor("100/4", Rates, "CNY")?.Display);
        Assert.IsNotNull(Calculator.ResultFor("10 km to m", Rates, "CNY"));
        Assert.IsTrue(Calculator.IsUnit("km"));
        Assert.IsFalse(Calculator.IsUnit("usd"));
    }

    [TestMethod]
    public void ConvertsWithTheCurrencysDigits()
    {
        var cny = ExchangeRates.Result(new ExchangeRates.Request(100, "USD", "CNY"), Rates, "CNY")!;
        Assert.AreEqual("700.00 CNY", cny.Display);
        Assert.AreEqual("700.00 CNY", cny.Payload);
        Assert.AreEqual("人民币 · 11-03 汇率", cny.Note);

        var yen = ExchangeRates.Result(new ExchangeRates.Request(10_000, "USD", "JPY"), Rates, "CNY")!;
        Assert.AreEqual("1,500,000 JPY", yen.Display);
        Assert.AreEqual("1500000 JPY", yen.Payload);

        // 科威特第纳尔 3 位小数；不到 1 的按 4 位有效数字
        Assert.AreEqual("2.500 KWD", ExchangeRates.Result(new ExchangeRates.Request(10, "USD", "KWD"), Rates, "CNY")!.Payload);
        Assert.AreEqual("0.07143 USD", ExchangeRates.Result(new ExchangeRates.Request(100, "KRW", "USD"), Rates, "CNY")!.Payload);

        // 金额是 1：在看汇率，按汇率的精度；Ctrl+K 有「复制汇率」
        var rate = ExchangeRates.Result(new ExchangeRates.Request(1, "USD", "CNY"), Rates, "CNY")!;
        Assert.AreEqual("7 CNY", rate.Payload);
        Assert.AreEqual("1 USD = 7 CNY", rate.Copies.Single(copy => copy.Title == "复制汇率").Text);

        // 表里没有的货币算不出来
        Assert.IsNull(ExchangeRates.Result(new ExchangeRates.Request(1, "USD", "GBP"), Rates, "CNY"));
    }

    [TestMethod]
    public void OnlyOneCurrencyGoesToTheHomeCurrency()
    {
        Assert.AreEqual("CNY", ExchangeRates.Target(new ExchangeRates.Request(5, "USD", null), "CNY"));
        Assert.AreEqual("USD", ExchangeRates.Target(new ExchangeRates.Request(5, "CNY", null), "CNY"));
        Assert.AreEqual("EUR", ExchangeRates.Target(new ExchangeRates.Request(5, "USD", null), "USD"));
        Assert.AreEqual("CNY", ExchangeRates.HomeOr("XYZ"));
        Assert.AreEqual("JPY", ExchangeRates.HomeOr("jpy"));
    }

    [TestMethod]
    public void CalculatorNeedsATableForMoney()
    {
        Assert.AreEqual("700.00 CNY", Calculator.ResultFor("100 usd to cny", Rates, "CNY")?.Display);
        Assert.AreEqual("700.00 CNY", Calculator.ResultFor("100 usd", Rates, "CNY")?.Display);
        Assert.IsNull(Calculator.ResultFor("100 usd"));
        var item = Calculator.ItemFor("100 usd", Rates, "CNY")!;
        Assert.AreEqual("人民币 · 11-03 汇率", item.Note);
        Assert.AreEqual("700.00 CNY", item.Completion);
        Assert.IsNull(Calculator.ItemFor("1+1")!.Note);

        var placeholder = ExchangeRates.Placeholder("100 usd", failed: false);
        Assert.IsNull(placeholder.Payload);
        Assert.AreEqual("正在取汇率…", placeholder.Title);
    }

    [TestMethod]
    public void KnowsNamesInAllThreeScripts()
    {
        Assert.AreEqual("HKD", ExchangeRates.CurrencyCode("港幣"));
        Assert.AreEqual("JPY", ExchangeRates.CurrencyCode("japanese yen"));
        Assert.AreEqual("USD", ExchangeRates.CurrencyCode("美金"));
        Assert.AreEqual("CNY", ExchangeRates.CurrencyCode("¥"));
        Assert.IsNull(ExchangeRates.CurrencyCode("pound"));
        Assert.AreEqual("新台币", ExchangeRates.Name("TWD"));
        Assert.AreEqual(159, ExchangeRates.IsoCodes.Count);
    }

    [TestMethod]
    public void SuggestsCurrenciesWhileTyping()
    {
        var english = ExchangeRates.Suggestions("100 美元 转 英");
        Assert.AreEqual("currency-GBP", english[0].Target);
        Assert.AreEqual("100 美元 转 英镑", english[0].Completion);

        var code = ExchangeRates.Suggestions("100 usd to gb");
        Assert.AreEqual("currency-GBP", code[0].Target);
        Assert.AreEqual("100 usd to GBP", code[0].Completion);

        // 「转」后面还没打：用过的在前，再常用的，不列左边那种
        var empty = ExchangeRates.Suggestions("100 美元 转", new[] { "JPY" });
        Assert.AreEqual(6, empty.Count);
        Assert.AreEqual("currency-JPY", empty[0].Target);
        Assert.AreEqual("100 美元 转 日元", empty[0].Completion);
        Assert.IsFalse(empty.Any(item => item.Target == "currency-USD"));

        Assert.AreEqual("currency-USD", ExchangeRates.Suggestions("100 u")[0].Target);
        // 单位、已经是货币、不是钱：不出
        Assert.AreEqual(0, ExchangeRates.Suggestions("10 km").Count);
        Assert.AreEqual(0, ExchangeRates.Suggestions("100 usd").Count);
        Assert.AreEqual(0, ExchangeRates.Suggestions("hello").Count);
    }

    [TestMethod]
    public void RemembersBothCurrenciesTargetFirst()
    {
        CollectionAssert.AreEqual(
            new[] { "JPY", "USD", "CNY" }, ExchangeRates.Remembering("100 usd to jpy", new[] { "CNY" }, "CNY"));
        CollectionAssert.AreEqual(new[] { "CNY", "USD" }, ExchangeRates.Remembering("100 usd", new[] { "USD" }, "CNY"));
        CollectionAssert.AreEqual(new[] { "CNY" }, ExchangeRates.Remembering("hello", new[] { "CNY" }, "CNY"));
    }

    [TestMethod]
    public void PromptShowsForTheKeyword()
    {
        Assert.AreEqual(1, ExchangeRates.PromptItems("汇率").Exact.Count);
        Assert.AreEqual(1, ExchangeRates.PromptItems("Currency").Exact.Count);
        Assert.AreEqual(1, ExchangeRates.PromptItems("curr").Partial.Count);
        Assert.AreEqual(1, ExchangeRates.PromptItems("汇").Partial.Count);
        Assert.AreEqual(0, ExchangeRates.PromptItems("c").Partial.Count);
        Assert.AreEqual("100 美元 转 日元", ExchangeRates.PromptItems("汇率").Exact[0].Completion);
    }

    [TestMethod]
    public void RepliesAreCheckedAndTablesRoundTrip()
    {
        var codes = new[]
        {
            "usd", "cny", "jpy", "eur", "gbp", "hkd", "twd", "krw", "aud", "cad", "sgd", "chf", "mop", "thb", "myr", "rub", "inr",
            "nzd", "vnd", "php", "idr",
        };
        string Reply(string date, IEnumerable<string> keys) =>
            "{\"date\":\"" + date + "\",\"usd\":{" + string.Join(",", keys.Select((key, index) => $"\"{key}\":{index + 1}.5")) +
            ",\"btc\":0.00001,\"zzz\":-1}}";

        var table = ExchangeRates.FromReply(Reply("2026-11-03", codes), 1234)!;
        Assert.AreEqual(21, table.Rates.Count);
        Assert.IsFalse(table.Rates.ContainsKey("BTC"));
        Assert.AreEqual(1.5, table.Rates["USD"]);

        Assert.IsNull(ExchangeRates.FromReply(Reply("11/03/2026", codes), 0));
        Assert.IsNull(ExchangeRates.FromReply(Reply("2026-11-03", codes.Take(10)), 0));
        Assert.IsNull(ExchangeRates.FromReply(Reply("2026-11-03", codes.Skip(1)), 0));
        Assert.IsNull(ExchangeRates.FromReply("<html>login</html>", 0));

        var back = ExchangeRates.Decode(ExchangeRates.Encode(table))!;
        Assert.AreEqual(table.Date, back.Date);
        Assert.AreEqual(1234, back.FetchedAt);
        CollectionAssert.AreEquivalent(table.Rates.ToList(), back.Rates.ToList());
        Assert.IsNull(ExchangeRates.Decode("{}"));
    }

    [TestMethod]
    public void StaleAfterSixHoursOrWhenTheClockWentBack()
    {
        var table = Rates with { FetchedAt = 1_000_000 };
        Assert.IsFalse(ExchangeRates.IsStale(table, 1_000_000 + 3600_000));
        Assert.IsTrue(ExchangeRates.IsStale(table, 1_000_000 + ExchangeRates.MaxAgeMs));
        Assert.IsTrue(ExchangeRates.IsStale(table, 999_999));
    }
}
