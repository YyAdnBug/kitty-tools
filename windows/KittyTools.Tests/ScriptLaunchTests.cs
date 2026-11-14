// 跑脚本的纯函数（PLAN-v18 L1）：cmd 的命令行、PATH 拼法、给脚本的环境。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScriptLaunchTests
{
    [TestMethod]
    public void CmdLineQuotesEverything()
    {
        Assert.AreEqual("/d /s /c \"\"C:\\my scripts\\a.cmd\" \"x & y\" \"say \"\"hi\"\"\"\"",
            ScriptLaunch.CmdArguments(@"C:\my scripts\a.cmd", new[] { "x & y", "say \"hi\"" }));
        Assert.AreEqual("/d /s /c \"\"a.bat\"\"", ScriptLaunch.CmdArguments("a.bat", Array.Empty<string>()));
        Assert.AreEqual("/d /s /c \"chcp 65001 >nul & \"a.bat\"\"", ScriptLaunch.CmdArguments("a.bat", Array.Empty<string>(), utf8: true));
    }

    [TestMethod]
    public void DetectsUtf8Files()
    {
        Assert.IsTrue(ScriptLaunch.LooksUtf8(new byte[] { 0xEF, 0xBB, 0xBF, 0x41 }));
        Assert.IsTrue(ScriptLaunch.LooksUtf8(System.Text.Encoding.UTF8.GetBytes("echo 中文")));
        Assert.IsFalse(ScriptLaunch.LooksUtf8(System.Text.Encoding.ASCII.GetBytes("echo hi")));
        // GBK 的「中文」是 D6 D0 CE C4：不是合法的 UTF-8
        Assert.IsFalse(ScriptLaunch.LooksUtf8(new byte[] { 0x65, 0x20, 0xD6, 0xD0, 0xCE, 0xC4 }));
        // 读到的开头截断在半个字上：不算错
        var cut = System.Text.Encoding.UTF8.GetBytes("中文");
        Assert.IsTrue(ScriptLaunch.LooksUtf8(cut.AsSpan(0, 4)));
    }

    [TestMethod]
    public void PathJoinsMachineThenUser()
    {
        // 重复的按去掉末尾 \ 比，留第一次出现的原样
        Assert.AreEqual(@"C:\Windows;C:\Tools\;C:\Users\me\bin",
            ScriptLaunch.JoinPath(@"C:\Windows;;C:\Tools\", @"c:\tools;C:\Users\me\bin;"));
        Assert.AreEqual(@"C:\a", ScriptLaunch.JoinPath(@"C:\a", null));
    }

    [TestMethod]
    public void EnvironmentAddsKittyValues()
    {
        var script = new ScriptCommand { Path = @"C:\s\a.py", Title = "a", Interpreter = new[] { "py.exe" } };
        var environment = ScriptLaunch.Environment(
            new Dictionary<string, string> { ["SystemRoot"] = @"C:\Windows", ["Path"] = "old" }, @"C:\new", script, @"C:\data", "0.3.0");
        Assert.AreEqual(@"C:\new", environment["PATH"]);
        Assert.AreEqual(@"C:\Windows", environment["SYSTEMROOT"]);
        Assert.AreEqual(@"C:\s", environment["KITTY_SCRIPT_DIR"]);
        Assert.AreEqual(@"C:\data", environment["KITTY_DATA_DIR"]);
        Assert.AreEqual("0.3.0", environment["KITTY_VERSION"]);
        Assert.AreEqual("utf-8", environment["PYTHONIOENCODING"]);
        Assert.IsTrue(ScriptLaunch.OutputIsUtf8(script, utf8File: false));
        Assert.IsTrue(ScriptLaunch.OutputIsUtf8(script with { Path = @"C:\s\a.cmd" }, utf8File: true));
        Assert.IsFalse(ScriptLaunch.OutputIsUtf8(script with { Path = @"C:\s\a.cmd" }, utf8File: false));
        Assert.IsFalse(ScriptLaunch.OutputIsUtf8(script with { Path = @"C:\s\a.ps1" }, utf8File: true));
        var ps = script with { Path = @"C:\s\a.ps1" };
        Assert.IsFalse(ScriptLaunch.Environment(new Dictionary<string, string>(), null, ps, "", "").ContainsKey("PYTHONIOENCODING"));
    }
}
