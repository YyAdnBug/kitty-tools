// 启动器脚本命令（PLAN-v18 L1，照 mac ScriptCommandTests 改成 Windows 的）：头部两种写法、Windows 的注释（::、REM）、按扩展名选
// 解释器（.py 要 py.exe、.sh 不认）、图标 / 参数 / 确认、输出的收拾、「关键词 空格 文字」怎么切、列表输出怎么读、看不见的字。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScriptCommandTests
{
    private static ScriptCommand Parse(string text, string name = "test.ps1", bool python = true)
    {
        var result = ScriptCommand.Parse(text, @"C:\scripts\" + name, python);
        Assert.IsNotNull(result);
        Assert.IsNull(result.Value.Problem, result.Value.Problem?.ToString());
        return result.Value.Script!;
    }

    [TestMethod]
    public void ParsesOwnFields()
    {
        var script = Parse("""
            # @kitty.title 生成 UUID
            # @kitty.keyword UUID
            # @kitty.icon 🆔
            # @kitty.mode paste
            # @kitty.description 生成一个小写的 UUID
            # @kitty.timeout 5
            # @kitty.argument1 前缀
            # @kitty.argument2 {"placeholder": "个数", "optional": true}
            [guid]::NewGuid().ToString()
            """);
        Assert.AreEqual("生成 UUID", script.Title);
        Assert.AreEqual("uuid", script.Keyword);
        Assert.AreEqual(new ScriptIcon.Emoji("🆔"), script.Icon);
        Assert.AreEqual(ScriptMode.Paste, script.Mode);
        Assert.AreEqual("生成一个小写的 UUID", script.Summary);
        Assert.AreEqual(5, script.Limit);
        Assert.AreEqual("powershell.exe", script.Interpreter[0]);
        CollectionAssert.AreEqual(new[] { new ScriptArgument("前缀"), new ScriptArgument("个数", IsOptional: true) }, script.Arguments.ToArray());
        Assert.IsNull(script.Confirmation);
    }

    [TestMethod]
    public void ReadsCommunityFieldsAndWindowsComments()
    {
        var script = Parse("""
            #!/usr/bin/env python3
            # @raycast.schemaVersion 1
            # @raycast.title Toggle Dark Mode
            # @raycast.mode silent
            # @raycast.packageName System
            # @raycast.icon images/dark.png
            # @raycast.needsConfirmation true
            # @raycast.argument1 { "type": "text", "placeholder": "Query", "optional": true }
            """, "dark.py");
        Assert.AreEqual("Toggle Dark Mode", script.Title);
        Assert.AreEqual(ScriptMode.Island, script.Mode);
        Assert.AreEqual("System", script.Package);
        Assert.AreEqual(new ScriptIcon.Image(@"C:\scripts\images\dark.png"), script.Icon);
        Assert.AreEqual("再按 Enter 运行「Toggle Dark Mode」", script.Confirmation);
        CollectionAssert.AreEqual(new[] { new ScriptArgument("Query", IsOptional: true) }, script.Arguments.ToArray());
        CollectionAssert.AreEqual(new[] { "py.exe" }, script.Interpreter.ToArray());
        // fullOutput 是全文；自家的字段比社区的优先
        var full = Parse("# @raycast.mode fullOutput\n# @raycast.title A\n# @kitty.title B\n");
        Assert.IsTrue(full.Mode == ScriptMode.Full && full.Title == "B");
        // 批处理的注释：:: 和 REM
        Assert.AreEqual("静音", Parse("@echo off\n:: @kitty.title 静音\n", "m.cmd").Title);
        Assert.AreEqual("清理", Parse("@echo off\nREM @kitty.title 清理\nrem @kitty.keyword ql\n", "c.bat").Title);
        Assert.AreEqual("ql", Parse("@echo off\nrem @kitty.keyword ql\n", "c.bat").Keyword);
        CollectionAssert.AreEqual(new[] { "cmd.exe", "/d", "/c" }, Parse("echo hi", "a.cmd").Interpreter.ToArray());
    }

    [TestMethod]
    public void DefaultsAndSkips()
    {
        var plain = Parse("Write-Output hi\n", "say hi.ps1");
        Assert.IsTrue(plain.Title == "say hi" && plain.Mode == ScriptMode.Island && plain.Limit == 60);
        Assert.IsNull(ScriptCommand.Parse("x", @"C:\x\a.template.ps1", true));
        Assert.IsNull(ScriptCommand.Parse("x", @"C:\x\.hidden.ps1", true));
        Assert.IsNull(ScriptCommand.Parse("PNG...", @"C:\x\icon.png", true));
        Assert.AreEqual(ScriptProblem.Unsupported, ScriptCommand.Parse("#!/bin/sh\n", @"C:\x\a.sh", true)?.Problem);
        Assert.AreEqual(ScriptProblem.NeedsPython, ScriptCommand.Parse("print(1)", @"C:\x\a.py", false)?.Problem);
        var odd = Parse("# @kitty.mode bogus\n# @kitty.timeout 99999\n# @kitty.confirm 真的要清空？\n");
        Assert.IsTrue(odd.Mode == ScriptMode.Island && odd.Timeout == 3600 && odd.Confirmation == "真的要清空？");
        Assert.IsNull(Parse("# @kitty.confirm false\n").Confirmation);
        Assert.AreEqual(ScriptProblem.ConfirmInList,
            ScriptCommand.Parse("# @kitty.mode list\n# @kitty.confirm\n", @"C:\x\l.ps1", true)?.Problem);
        var filter = Parse("# @kitty.mode list\n# @kitty.filter\n# @kitty.argument1 词\n");
        Assert.IsTrue(filter.Filters && filter.Arguments.Count == 0);
    }

    [TestMethod]
    public void Icons()
    {
        Assert.AreEqual(new ScriptIcon.Emoji("⏱\uFE0F"), ScriptCommand.IconFor("⏱ 计时", @"C:\s"));
        Assert.AreEqual(new ScriptIcon.Emoji("🆔"), ScriptCommand.IconFor("🆔", @"C:\s"));
        Assert.AreEqual(new ScriptIcon.Symbol("Clock"), ScriptCommand.IconFor("Clock", @"C:\s"));
        Assert.AreEqual(new ScriptIcon.Image(@"C:\s\icon.png"), ScriptCommand.IconFor("icon.png", @"C:\s"));
        Assert.AreEqual(new ScriptIcon.Image(@"D:\abs\a.png"), ScriptCommand.IconFor(@"D:\abs\a.png", @"C:\s"));
        Assert.AreEqual(new ScriptIcon.Remote("https://x.com/a.png"), ScriptCommand.IconFor("https://x.com/a.png", @"C:\s"));
        Assert.IsNull(ScriptCommand.IconFor("http://x.com/a.png", @"C:\s"));
        Assert.IsNull(ScriptCommand.IconFor("  ", @"C:\s"));
    }

    [TestMethod]
    public void CleansOutput()
    {
        var colored = "\u001B[1;32mok\u001B[0m\r\nsecond\u001B]0;title\u0007\n\n";
        Assert.AreEqual("ok\nsecond\n\n", ScriptText.Clean(colored));
        Assert.AreEqual("second", ScriptText.LastLine(colored));
        Assert.IsNull(ScriptText.LastLine("  \n\n"));
        Assert.AreEqual("a\n  b", ScriptText.Payload("a\n  b\n\n"));
        // 进度条一帧帧地重画：只留最后一帧
        Assert.AreEqual("100%\ndone\n", ScriptText.Clean("10%\r50%\r100%\ndone\n"));
        // 只有 \r 的老式换行
        Assert.AreEqual("a\nb", ScriptText.Clean("a\rb"));
    }

    [TestMethod]
    public void Invocations()
    {
        ScriptCommand Script(string title, string? keyword, int args = 1, bool optional = false, bool list = false) => new()
        {
            Path = $@"C:\s\{title}.ps1",
            Title = title,
            Keyword = keyword,
            Interpreter = new[] { "powershell.exe" },
            Arguments = Enumerable.Range(0, args).Select(index => new ScriptArgument($"参数{index + 1}", optional)).ToList(),
            Mode = list ? ScriptMode.List : ScriptMode.Island,
        };
        var weather = Script("天气", "tq");
        var pair = Script("Unix 时间戳", "t", args: 2);
        var plain = Script("说你好", "hi", args: 0);
        var b64 = Script("Base64", "b64", args: 0, list: true);
        var scripts = new[] { weather, pair, plain, b64 };
        string? Alias(ScriptCommand script) => script.Keyword;
        var tq = ScriptText.InvocationFor("TQ  北京 海淀", scripts, Alias);
        Assert.IsTrue(tq?.Script == weather && tq.Keyword == "TQ");
        CollectionAssert.AreEqual(new[] { "北京 海淀" }, tq!.Arguments.ToArray());
        var unix = ScriptText.InvocationFor("unix 时间戳 1700000000 毫秒 本地", scripts, Alias);
        Assert.AreEqual(pair, unix?.Script);
        CollectionAssert.AreEqual(new[] { "1700000000", "毫秒 本地" }, unix!.Arguments.ToArray());
        Assert.IsNull(ScriptText.InvocationFor("tq", scripts, Alias));
        Assert.IsNull(ScriptText.InvocationFor("tqx 北京", scripts, Alias));
        Assert.IsNull(ScriptText.InvocationFor("hi there", scripts, Alias));
        CollectionAssert.AreEqual(new[] { "aGk=" }, ScriptText.InvocationFor("b64 aGk=", scripts, Alias)!.Arguments.ToArray());
        var empty = ScriptText.InvocationFor("tq ", scripts, Alias);
        Assert.IsTrue(empty!.Arguments.Count == 0 && empty.IsMissing);
        Assert.IsFalse(ScriptText.InvocationFor("b64 ", scripts, Alias)!.IsMissing);
        Assert.IsNull(ScriptText.InvocationFor("tq 北京", scripts, _ => "w"));
        CollectionAssert.AreEqual(new[] { "a", "b c" }, ScriptText.Split("a  b c", 2).ToArray());
        Assert.AreEqual(0, ScriptText.Split("  ", 3).Count);
        // 引号括起来的算一段；没配上的引号拿走剩下的全部
        CollectionAssert.AreEqual(new[] { "New York", "London" }, ScriptText.Split("\"New York\" London", 2).ToArray());
        Assert.IsTrue(ScriptText.Tokens("\"New ", 2).Open);
        Assert.AreEqual("\"a b\"", ScriptText.Quoted("a b"));
        Assert.AreEqual("ab", ScriptText.Quoted("ab"));
    }

    [TestMethod]
    public void ChoicesAndEncoding()
    {
        var script = new ScriptCommand
        {
            Path = @"C:\s\a.ps1",
            Title = "a",
            Interpreter = new[] { "powershell.exe" },
            Arguments = new[]
            {
                new ScriptArgument("单位", Options: new[] { new ScriptOption("毫秒", "ms"), new ScriptOption("秒", "s") }),
                new ScriptArgument("查询", IsPercentEncoded: true),
            },
        };
        CollectionAssert.AreEqual(new[] { "ms", "a b&c" == "" ? "" : "a%20b%26c" }, script.Passed(new[] { "毫秒", "a b&c" }).ToArray());
        Assert.AreEqual(0, script.InvalidChoice(new[] { "分钟" }));
        Assert.IsNull(script.InvalidChoice(new[] { "s" }));
        var json = ScriptCommand.ArgumentsFrom(new Dictionary<string, string>
        {
            ["argument1"] = """{"type": "dropdown", "placeholder": "单位", "data": [{"title": "毫秒", "value": "ms"}, {"value": "s"}]}""",
            ["argument2"] = """{"type": "password", "placeholder": "密码"}""",
        });
        CollectionAssert.AreEqual(new[] { new ScriptOption("毫秒", "ms"), new ScriptOption("s", "s") }, json[0].Choices.ToArray());
        Assert.IsTrue(json[1].IsSecret);
    }

    [TestMethod]
    public void ListLines()
    {
        var lines = ScriptText.Lines("YUdrPQ==\t编码\n\nhi\t解码\n  只有标题  \n");
        CollectionAssert.AreEqual(new[] { new ScriptLine("YUdrPQ==", "编码"), new ScriptLine("hi", "解码"), new ScriptLine("只有标题") }, lines.ToArray());
        var json = """
            {"items": [
              {"title": "第一条", "subtitle": "说明", "arg": "要粘贴的", "uid": "x"},
              {"title": "不能选", "valid": false},
              {"title": "数组", "arg": ["a", "b"]},
              {"subtitle": "没有标题的不要"},
              {"title": "网址", "url": "https://example.com"},
              {"title": "文件", "type": "file", "arg": "notes.txt"}
            ]}
            """;
        var parsed = ScriptText.Lines(json, @"C:\s");
        Assert.AreEqual(5, parsed.Count);
        Assert.AreEqual("要粘贴的", parsed[0].Value);
        Assert.IsFalse(parsed[1].IsValid);
        Assert.AreEqual("a\nb", parsed[2].Arg);
        Assert.AreEqual("https://example.com", parsed[3].OpensUrl);
        Assert.AreEqual(@"C:\s\notes.txt", parsed[4].OpensFile);
        Assert.AreEqual(200, ScriptText.Lines(string.Concat(Enumerable.Repeat("x\n", 500))).Count);
    }

    [TestMethod]
    public void HiddenCharactersAreShown()
    {
        var (text, hidden) = ScriptText.Revealed("echo hi\u200B # 注释");
        Assert.IsTrue(hidden);
        StringAssert.Contains(text, "⟦U+200B⟧");
        Assert.IsTrue(ScriptText.Revealed("a\u202Eb").HasHidden, "双向控制符");
        Assert.IsTrue(ScriptText.Revealed("a\rb").HasHidden, "单独的回车");
        Assert.IsFalse(ScriptText.Revealed("a\r\nb").HasHidden);
        var (marked, blocked) = ScriptText.Revealed("a\u3000b");
        Assert.IsFalse(blocked);
        StringAssert.Contains(marked, "⟦U+3000⟧");
        Assert.IsFalse(ScriptText.Revealed("⚠️ 👨‍👩‍👧 中文").HasHidden, "emoji 里的 ZWJ、变体选择符不算");
    }
}
