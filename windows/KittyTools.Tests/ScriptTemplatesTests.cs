// 新建脚本的模板、两个样板、从剪贴板认脚本、写法说明（PLAN-v18 L1 第 8 批）：生成的都要读得回一条命令。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScriptTemplatesTests
{
    private static ScriptCommand Parsed(string text, string name)
        => ScriptCommand.Parse(text, @"C:\s\" + name, pythonAvailable: true) is { Script: { } script } ? script : throw new AssertFailedException("读不成：" + name);

    [TestMethod]
    public void TemplatesParseBack()
    {
        foreach (var language in Enum.GetValues<ScriptLanguage>())
        {
            foreach (var mode in Enum.GetValues<ScriptMode>())
            {
                var name = ScriptTemplates.NewFileName("你好", "hi", language);
                var script = Parsed(ScriptTemplates.Template("你好", "hi", mode, language), name);
                Assert.AreEqual("你好", script.Title);
                Assert.AreEqual("hi", script.Keyword);
                Assert.AreEqual(mode, script.Mode, $"{language} {mode}");
                Assert.IsNull(script.Confirmation, "模板里的确认只是提示，不是字段");
            }
        }

        Assert.IsTrue(ScriptTemplates.Template("x", null, ScriptMode.Island, ScriptLanguage.Batch).StartsWith("@echo off\n:: @kitty.title x"));
    }

    [TestMethod]
    public void FileNames()
    {
        Assert.AreEqual("short-url.ps1", ScriptTemplates.NewFileName("短链接", "short-url", ScriptLanguage.PowerShell));
        Assert.AreEqual("查 天气.cmd", ScriptTemplates.NewFileName("查 天气", "中文", ScriptLanguage.Batch));
        Assert.AreEqual("a-b.py", ScriptTemplates.NewFileName(".a/b", null, ScriptLanguage.Python));
        Assert.AreEqual("新脚本.ps1", ScriptTemplates.NewFileName("...", null, ScriptLanguage.PowerShell));
        var taken = new HashSet<string> { "x.ps1", "x 2.ps1" };
        Assert.AreEqual("x 3.ps1", ScriptTemplates.FreeName("x.ps1", taken.Contains));
        Assert.AreEqual("y.ps1", ScriptTemplates.FreeName("y.ps1", taken.Contains));
    }

    [TestMethod]
    public void ExamplesAndBytes()
    {
        var weather = Parsed(ScriptTemplates.Example, ScriptTemplates.ExampleName);
        Assert.AreEqual("tq", weather.Keyword);
        Assert.AreEqual(1, weather.Arguments.Count);
        Assert.AreEqual("zs", Parsed(ScriptTemplates.CountExample, ScriptTemplates.CountExampleName).Keyword);
        var ps1 = ScriptTemplates.Bytes("a\nb", ScriptLanguage.PowerShell);
        CollectionAssert.AreEqual(new byte[] { 0xEF, 0xBB, 0xBF, (byte)'a', 13, 10, (byte)'b' }, ps1);
        Assert.AreEqual((byte)'a', ScriptTemplates.Bytes("a", ScriptLanguage.Batch)[0], "批处理不带 BOM");
        StringAssert.Contains(ScriptTemplates.AIGuide, "# @kitty.keyword tq");
        StringAssert.Contains(ScriptTemplates.AIGuide, "{\"placeholder\": \"城市\", \"optional\": true}");
    }

    [TestMethod]
    public void FromClipboard()
    {
        var fenced = ScriptTemplates.FromClipboard("好的：\n```powershell\n# @kitty.title 短链\n# @kitty.keyword dl\n\"x\"\n```\n存成 dl.ps1 就行");
        Assert.AreEqual("# @kitty.title 短链\n# @kitty.keyword dl\n\"x\"\n", fenced!.Value.Text, "前后的话去掉，只要代码块");
        var ps = ScriptTemplates.FromClipboard("```powershell\r\n# @kitty.title 短链\r\n# @kitty.keyword dl\r\n\"x\"\r\n```");
        Assert.IsNotNull(ps);
        Assert.AreEqual(ScriptLanguage.PowerShell, ps.Value.Language);
        Assert.AreEqual("# @kitty.title 短链\n# @kitty.keyword dl\n\"x\"\n", ps.Value.Text);
        Assert.AreEqual("dl.ps1", ScriptTemplates.SuggestedName(ps.Value.Text, ps.Value.Language));
        var batch = ScriptTemplates.FromClipboard("@echo off\n:: @kitty.title 你好\necho hi");
        Assert.AreEqual(ScriptLanguage.Batch, batch!.Value.Language);
        Assert.AreEqual("新脚本.cmd", ScriptTemplates.SuggestedName(batch.Value.Text, batch.Value.Language));
        Assert.AreEqual(ScriptLanguage.Python, ScriptTemplates.FromClipboard("```py\n# @raycast.title 你好\nprint(1)\n```")!.Value.Language);
        Assert.IsNull(ScriptTemplates.FromClipboard("Get-Date"), "没写名字的不算脚本");
        Assert.IsNull(ScriptTemplates.FromClipboard("   "));
    }
}
