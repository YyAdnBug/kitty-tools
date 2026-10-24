// 计算器的更多用例（从 mac 版 LauncherTests 的 calculator 那一组搬）：
// 全角 / 乘号 / 上标、百分比、千分位、除零与不完整的表达式。
// 第二版 §2 P3 最后一条：先把 mac 有的、Windows 缺的用例补上。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class CalculatorCasesTests
{
    private static string? Eval(string input)
        => Calculator.Evaluate(input) is { } value ? Calculator.Format(value) : null;

    [TestMethod]
    public void FourOperationsAndParentheses()
    {
        Assert.AreEqual("7", Eval("1+2*3"));
        Assert.AreEqual("9", Eval("(1+2)*3"));
        Assert.AreEqual("9", Eval("（1+2）×3"));
        Assert.AreEqual("512", Eval("2^3^2"));
        Assert.AreEqual("110", Eval("100+10%"));
        Assert.AreEqual("30", Eval("200*15%"));
        Assert.AreEqual("3897", Eval("1,299*3"));
        Assert.AreEqual("0.5", Eval("1/2"));
        Assert.AreEqual("-1", Eval("1-2"));
        Assert.AreEqual("2.5", Eval("5/2"));
    }

    [TestMethod]
    public void RejectsWhatIsNotMath()
    {
        Assert.IsNull(Eval("1/0"));
        Assert.IsNull(Eval("1+"));
        Assert.IsNull(Calculator.ItemFor("2024-01-01"));
        Assert.IsNull(Calculator.ItemFor("12"));
        Assert.IsNull(Eval("abc"));
    }

    [TestMethod]
    public void NormalizesFullWidthAndSymbols()
    {
        Assert.AreEqual("1+2*3", Calculator.Normalize("１＋２×３"));
        Assert.AreEqual("1299*3", Calculator.Normalize("1,299*3"));
        Assert.IsTrue(Calculator.LooksLikeMath("1+2*3"));
        Assert.IsFalse(Calculator.LooksLikeMath("chrome"));
        Assert.IsNotNull(Calculator.ItemFor("1+2*3"));
        Assert.IsNull(Calculator.ItemFor("chrome"));
    }

    [TestMethod]
    public void FormatKeepsIntegersShort()
    {
        Assert.AreEqual("7", Calculator.Format(7.0));
        Assert.AreEqual("7.5", Calculator.Format(7.5));
        Assert.AreEqual("0.333333333333", Calculator.Format(1.0 / 3));
        Assert.AreEqual("0.3", Calculator.Format(0.1 + 0.2));
    }
}
