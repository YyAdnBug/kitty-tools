// 全部输出那一页的终端颜色（PLAN-v18 L1，照 mac ScriptTerminalTests）：SGR 改笔、256 色和 24 位、重来、别的控制码去掉、截在一半的不显示。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScriptTerminalTests
{
    [TestMethod]
    public void ColorsAndStyles()
    {
        var spans = ScriptTerminal.Spans("plain \u001B[1;32mok\u001B[0m \u001B[38;5;208morange\u001B[39m \u001B[48;2;10;20;30mbg\u001B[m end");
        CollectionAssert.AreEqual(new[] { "plain ", "ok", " ", "orange", " ", "bg", " end" }, spans.Select(span => span.Text).ToArray());
        Assert.AreEqual(TerminalPen.Plain, spans[0].Pen);
        Assert.IsTrue(spans[1].Pen.Bold && spans[1].Pen.Foreground == 2);
        Assert.AreEqual(208, spans[3].Pen.Foreground);
        Assert.AreEqual(TerminalPen.RgbFlag | 0x0A141E, spans[5].Pen.Background);
        Assert.AreEqual(TerminalPen.Plain, spans[6].Pen);
        // 亮色 90–97、关掉粗体
        Assert.AreEqual(9, ScriptTerminal.Apply("91", TerminalPen.Plain).Foreground);
        Assert.IsFalse(ScriptTerminal.Apply("22", TerminalPen.Plain with { Bold = true }).Bold);
    }

    [TestMethod]
    public void OtherEscapesAndPartialOnesAreDropped()
    {
        var spans = ScriptTerminal.Spans("a\u001B]0;title\u0007b\u001B[2Kc\u001B[1");
        Assert.AreEqual("abc", string.Concat(spans.Select(span => span.Text)));
        Assert.AreEqual("x", ScriptTerminal.DroppingPartialEscape("x\u001B[3"));
        Assert.AreEqual("x\u001B[3m", ScriptTerminal.DroppingPartialEscape("x\u001B[3m"));
        // 进度条：单独的回车盖掉这一行
        Assert.AreEqual("100%\ndone\n", string.Concat(ScriptTerminal.Spans("10%\r100%\ndone\n").Select(span => span.Text)));
    }

    [TestMethod]
    public void PaletteFollowsXterm()
    {
        Assert.AreEqual(0x000000, ScriptTerminal.PaletteRgb(16));
        Assert.AreEqual(0xFF0000, ScriptTerminal.PaletteRgb(196));
        Assert.AreEqual(0x080808, ScriptTerminal.PaletteRgb(232));
        Assert.AreEqual(0xEEEEEE, ScriptTerminal.PaletteRgb(255));
    }
}
