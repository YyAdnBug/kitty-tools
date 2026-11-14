// 自带的七条命令（PLAN-v18 D8）：头部同 mac 那几个、时间戳、JSON、进制、URL、Base64、正则（含超时和写错）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class BuiltinToolsTests
{
    private static readonly TimeZoneInfo Beijing = TimeZoneInfo.CreateCustomTimeZone("cst", TimeSpan.FromHours(8), "cst", "cst");

    private static (int Code, string Output) Run(string id, params string[] arguments)
        => BuiltinTools.Run("kitty-builtin:" + id, arguments, clipboard: "剪贴板 abc 123", new DateTimeOffset(2026, 11, 14, 2, 0, 0, TimeSpan.Zero), Beijing);

    [TestMethod]
    public void CommandsMatchMac()
    {
        CollectionAssert.AreEqual(new[] { "time", "json", "uuid", "bcvt", "url", "b64", "regt" },
            BuiltinTools.Commands.Select(command => command.Keyword).ToArray());
        Assert.IsTrue(BuiltinTools.Commands.All(command => command.IsBundled && BuiltinTools.IsBuiltin(command)));
        Assert.AreEqual(ScriptMode.Paste, BuiltinTools.Commands[2].Mode);
        Assert.AreEqual(2, BuiltinTools.Commands[6].Arguments.Count);
    }

    [TestMethod]
    public void DarkModeFlips()
    {
        Assert.AreEqual((0, "已切换到深色模式"), BuiltinTools.DarkModeToggle(null));
        Assert.AreEqual((0, "已切换到深色模式"), BuiltinTools.DarkModeToggle(1));
        Assert.AreEqual((1, "已切换到浅色模式"), BuiltinTools.DarkModeToggle(0));
    }

    [TestMethod]
    public void Timestamps()
    {
        var now = ScriptText.Lines(Run("time").Output);
        Assert.AreEqual("1794621600", now[0].Title);
        Assert.AreEqual("2026-11-14 10:00:00", now[2].Title);
        Assert.AreEqual("2026-11-14T02:00:00Z", now[3].Title);
        Assert.AreEqual("1700000000000", ScriptText.Lines(Run("time", "1700000000").Output)[1].Title);
        Assert.AreEqual("1700000000", ScriptText.Lines(Run("time", "1700000000123").Output)[0].Title);
        Assert.AreEqual("认不出", ScriptText.Lines(Run("time", "下周").Output)[0].Title);
    }

    [TestMethod]
    public void JsonAndNumbersAndText()
    {
        var json = Run("json", "{\"a\":[1,2],\"中\":\"文\"}");
        Assert.AreEqual(0, json.Code);
        StringAssert.Contains(json.Output, "\"中\": \"文\"");
        Assert.AreEqual(1, Run("json", "{oops").Code);
        var numbers = ScriptText.Lines(Run("bcvt", "0xff").Output).Select(line => line.Title).ToArray();
        CollectionAssert.AreEqual(new[] { "255", "0xff", "0b11111111", "0o377" }, numbers);
        Assert.AreEqual("-0b1010", ScriptText.Lines(Run("bcvt", "-10").Output)[2].Title);
        Assert.AreEqual(1, Run("bcvt", "12z").Code);
        var url = ScriptText.Lines(Run("url", "a b&c").Output);
        Assert.AreEqual("a%20b%26c", url[0].Title);
        var b64 = ScriptText.Lines(Run("b64", "aGk=").Output);
        Assert.AreEqual("YUdrPQ==", b64[0].Title);
        Assert.AreEqual("hi", b64[1].Title);
        Assert.AreEqual(1, ScriptText.Lines(Run("b64", "中文!").Output).Count, "解不出来的只列编码");
        Assert.AreEqual(36, Run("uuid").Output.Length);
    }

    [TestMethod]
    public void RegexMatchesGroupsAndErrors()
    {
        var lines = ScriptText.Lines(Run("regt", @"(?<word>\w+)-(\d)", "a-1 b-2").Output);
        Assert.AreEqual("a-1", lines[0].Title);
        // .NET 的分组号：没名字的在前、有名字的排在后面
        Assert.AreEqual("1", lines[1].Title);
        Assert.AreEqual("a", lines[2].Title);
        StringAssert.Contains(lines[2].Subtitle, "word");
        Assert.AreEqual("b-2", lines[3].Title);
        // 没写文字：拿剪贴板的
        Assert.AreEqual("123", ScriptText.Lines(Run("regt", @"\d+").Output)[0].Title);
        Assert.AreEqual(1, Run("regt", "(").Code);
        Assert.AreEqual("没有匹配", ScriptText.Lines(Run("regt", "xyz", "abc").Output)[0].Title);
    }
}
