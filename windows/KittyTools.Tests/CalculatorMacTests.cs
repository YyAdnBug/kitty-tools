// mac 版计算器的单测原样搬过来（期望值一字不改，每个方法上面写 mac 的出处），外加一组在 macOS 上跑 mac 的
// Calculator.swift 得到的参考输出（四舍六入五成双、-0、温度、很大很小的数、进制的边：mac 单测没覆盖到的排法）。
// mac 里靠 LauncherModel 的那条（LauncherBatch6Tests › calculationActionsListExtraCopies，⌘K 动作列表）不搬：
// Windows 的 LauncherModel 在 WinUI 工程里；它列的就是 Result.Copies，Copies 下面已经逐条比过。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class CalculatorMacTests
{
    private static double? Value(string text) => Calculator.Evaluate(text);

    private static string? Display(string query) => Calculator.ResultFor(query)?.Display;

    private static string? Payload(string query) => Calculator.ResultFor(query)?.Payload;

    // mac: LauncherTests.swift › calculator()
    [TestMethod]
    public void CalculatorBasics()
    {
        Assert.AreEqual(7, Value("1+2*3"));
        Assert.AreEqual(9, Value("(1+2)*3"));
        Assert.AreEqual(512, Value("2^3^2")); // 幂右结合
        Assert.AreEqual(1024, Value("2**10"));
        Assert.AreEqual(-4, Value("-2^2"));
        // % 是百分号，取模改用 mod
        Assert.AreEqual(30, Value("200*15%"));
        Assert.AreEqual(110, Value("100+10%"));
        Assert.AreEqual(90, Value("100-10%"));
        Assert.AreEqual(0.5, Value("50%"));
        Assert.AreEqual(160, Value("80/50%"));
        Assert.AreEqual(0.02, Value("(1+1)%"));
        Assert.AreEqual(1, Value("10 mod 3"));
        Assert.AreEqual(Math.PI % 3, Value("pi mod 3"));
        Assert.IsNull(Value("10%3"));
        Assert.AreEqual("30", Calculator.ItemFor("200*15%")?.Payload);
        Assert.AreEqual("1", Calculator.ItemFor("10 mod 3")?.Payload);
        // 中文输入法打出来的：全角括号 / 数字、× ÷、千分位逗号；算式那一栏照常是原文
        Assert.AreEqual(9, Value("（1+2）×3"));
        Assert.AreEqual(3897, Value("1,299*3"));
        Assert.AreEqual(3, Value("１＋２"));
        Assert.AreEqual(3, Value("9÷3"));
        Assert.AreEqual("（1+2）×3", Calculator.ItemFor("（1+2）×3")?.Target);
        Assert.AreEqual("3", Calculator.ItemFor("１＋２")?.Payload);
        Assert.AreEqual(5, Value("sqrt(16)+abs(-1)"));
        Assert.AreEqual(19, Value("0x10+0b11"));
        Assert.IsNull(Value("1/0"));
        Assert.IsNull(Value("1+"));
        Assert.IsNull(Value("sqrt(")); // 半截表达式不能崩
        Assert.AreEqual("0.3", Calculator.Format(0.1 + 0.2));
        Assert.AreEqual("6.28318530718", Calculator.Format(2 * Math.PI));
        Assert.AreEqual("9007199254740992", Calculator.Format(Math.Pow(2, 53))); // 能精确表示的整数原样
        Assert.IsTrue(Calculator.Format(Math.Pow(2, 60)).Contains('E')); // 更大的用科学计数，不显示成补 0 的「精确」整数
        Assert.AreEqual("3", Calculator.ItemFor("1+2")?.Payload);
        // Tab 写回的科学计数要能接着算；单独的 e 仍是常数
        Assert.AreEqual(2.30584300922e18, Calculator.Evaluate("1.15292150461e18*2"));
        Assert.AreEqual(1.009, Calculator.Evaluate("9e-3+1"));
        Assert.AreEqual(2 * Math.E, Calculator.Evaluate("2*e"));
        Assert.IsNull(Calculator.ItemFor("2024-01-01")); // 日期不当算式
        Assert.IsNull(Calculator.ItemFor("abc"));
        Assert.IsNull(Calculator.ItemFor("12"));
    }

    // mac: LauncherTests.swift › tabCompletionAndAlternates()（只搬计算那一条；目录 / 文件 / App / 网址的补全不归计算器）
    [TestMethod]
    public void TabCompletionWritesTheResultBack()
    {
        Assert.AreEqual("37", Calculator.ItemFor("12*3+1")?.Completion); // 结果写回输入框接着算
    }

    // mac: LauncherBatch6Tests.swift › unitConversions()
    [TestMethod]
    public void UnitConversions()
    {
        var km = Calculator.ResultFor("10 km to mi");
        Assert.AreEqual("6.2137 mi", km?.Display);
        Assert.AreEqual("6.2137 mi", km?.Payload);
        CollectionAssert.AreEqual(new[] { new CalcCopy("复制原始数字", "6.2137") }, km?.Copies.ToArray());
        Assert.AreEqual("86 °F", Display("30 摄氏度 转 华氏度"));
        Assert.AreEqual("86 °F", Display("30摄氏度转华氏度")); // 中文不带空格
        Assert.AreEqual("37.7778 °C", Display("100°F in C"));
        Assert.AreEqual("1,500 MB", Display("1.5GB in MB"));
        Assert.AreEqual("1500 MB", Payload("1.5GB in MB")); // 粘贴 / 写回的不分组
        Assert.AreEqual("500 g", Display("1 斤 = g"));
        Assert.AreEqual("120 min", Display("2 hours to min"));
        Assert.AreEqual("666.6667 m²", Display("1 亩 to m2"));
        Assert.AreEqual("16.6667 m/s", Display("60 km/h to m/s"));
        Assert.AreEqual("0.453592 kg", Display("1 lb to kg")); // 小于 1 的留 6 位有效数字
        Assert.AreEqual("236.588 mL", Display("8 fl oz to ml")); // 系统的液盎司取 29.5735 mL
        Assert.AreEqual("25.4 cm", Display("10 in to cm")); // in 既是英寸又是分隔词
        Assert.AreEqual("300 s", Display("5 min to s"));
        // 不同类的量、不认识的单位、不是换算的：都不算
        Assert.IsNull(Calculator.ResultFor("10 km to kg"));
        Assert.IsNull(Calculator.ResultFor("10 foo to bar"));
        Assert.IsNull(Calculator.ItemFor("3 to 5"));
        // 卡片：算式那一栏是原文，大字是结果；Tab 写回的是结果
        var item = Calculator.ItemFor("10 km to mi");
        Assert.AreEqual("10 km to mi", item?.Target);
        Assert.AreEqual("6.2137 mi", item?.Title);
        Assert.AreEqual("6.2137 mi", item?.Completion);
    }

    // mac: LauncherBatch6Tests.swift › radixAndGrouping()
    [TestMethod]
    public void RadixAndGrouping()
    {
        var hex = Calculator.ResultFor("255 in hex");
        Assert.AreEqual("0xFF", hex?.Display);
        Assert.AreEqual("0xFF", hex?.Payload);
        CollectionAssert.AreEqual(
            new[] { new CalcCopy("复制十进制", "255"), new CalcCopy("复制二进制", "0b11111111") },
            hex?.Copies.ToArray());
        Assert.AreEqual("255", Display("0xff in dec"));
        Assert.AreEqual("0b11111111", Payload("255 转 二进制"));
        Assert.AreEqual("0o10", Payload("8 in oct"));
        Assert.AreEqual("-0xFF", Payload("-255 in hex"));
        Assert.AreEqual("0b10001", Payload("0x10+1 in bin")); // 左边可以是算式
        Assert.IsNull(Calculator.ResultFor("2.5 in hex")); // 不是整数
        // 写回输入框的还能接着算
        Assert.AreEqual(255, Calculator.Evaluate("0xFF"));
        Assert.AreEqual(15, Calculator.Evaluate("0o17"));
        Assert.AreEqual(-5, Calculator.Evaluate("-0b101"));
        // 输入里有 0x / 0b：多「复制十六进制 / 二进制」；单独一个字面量也出十进制
        var sum = Calculator.ResultFor("0xff+1");
        Assert.AreEqual("256", sum?.Display);
        CollectionAssert.AreEqual(new[] { "0x100", "0b100000000" }, sum?.Copies.Select(copy => copy.Text).ToArray());
        Assert.AreEqual("255", Calculator.ItemFor("0xff")?.Title);
        // 千分位：大字分组，粘贴的不分组，多一条「复制原始数字」
        var big = Calculator.ItemFor("1234567*3");
        Assert.AreEqual("3,703,701", big?.Title);
        Assert.AreEqual("3703701", big?.Payload);
        CollectionAssert.AreEqual(
            new[] { new CalcCopy("复制原始数字", "3703701") },
            Calculator.ResultFor("1234567*3")?.Copies.ToArray());
        Assert.AreEqual(0, Calculator.ResultFor("1+2")?.Copies.Count); // 分不分组一样时不多这一行
        Assert.AreEqual("1,234.5", Calculator.Format(1234.5, grouped: true));
        Assert.IsTrue(Calculator.Format(Math.Pow(2, 60), grouped: true).Contains('E'));
    }

    // 不是 mac 单测：2026-10-28 在 macOS 27 上跑 mac 的 Calculator.swift 得到的输出，钉住 mac 单测没覆盖到的排法
    [TestMethod]
    public void MatchesMacOutputs()
    {
        Assert.AreEqual("1E20", Calculator.Format(1e20));
        Assert.AreEqual("1.15292150461E18", Calculator.Format(Math.Pow(2, 60)));
        Assert.AreEqual("1E-10", Calculator.Format(1e-10));
        Assert.AreEqual("123456789012", Calculator.Format(123456789012.5)); // 五成双：舍
        Assert.AreEqual("123456789014", Calculator.Format(123456789013.5)); // 五成双：入
        Assert.AreEqual("0.123456789012", Calculator.Format(0.1234567890125)); // 按最短的十进制数字取舍，不按二进制精确值
        Assert.AreEqual("1000000000000000", Calculator.Format(999999999999999.9));
        Assert.AreEqual("-1,234,567.25", Calculator.Format(-1234567.25, grouped: true));
        Assert.AreEqual("0", Calculator.Format(-0.0));
        Assert.AreEqual("1", Calculator.Quantity(1.00005, grouped: false));
        Assert.AreEqual("1.0002", Calculator.Quantity(1.00015, grouped: false));
        Assert.AreEqual("1E-9", Calculator.Quantity(9.99999999999e-10, grouped: false));
        Assert.AreEqual("1E15", Calculator.Quantity(1e15, grouped: false));
        Assert.AreEqual("999,999,999,999,999.9", Calculator.Quantity(999999999999999.9, grouped: true));
        Assert.AreEqual("0.000000123456", Calculator.Quantity(1.234565e-07, grouped: false));
        Assert.AreEqual("-0", Calculator.Quantity(-0.0, grouped: false));
        Assert.AreEqual("1,430.5115 MiB", Display("1.5 GB 转换成 MiB"));
        Assert.AreEqual("22.2222 °C", Display("72 °F → C"));
        Assert.AreEqual("-273.15 °C", Display("0 k to c"));
        Assert.AreEqual("-0 m", Payload("-0 m to m")); // 同一个单位原样，-0 也留着
        Assert.AreEqual("1E29 nm", Display("1e20 m to nm"));
        Assert.AreEqual("5,000 KB", Display("5 Mb to kb"));
        Assert.AreEqual("7 天", Display("1 week to d"));
        Assert.AreEqual("6.2137 mi", Display("１０ｋｍ to mi"));
        Assert.AreEqual("0x20000000000000", Payload("2^53 in hex"));
        Assert.IsNull(Calculator.ResultFor("2^54 in hex"));
        Assert.AreEqual("-0x8000000000000000", Calculator.Radix(long.MinValue, 16));
        Assert.AreEqual(-3, Value("round(-2.5)"));
        Assert.IsNull(Value("0b1f"));
        Assert.IsNull(Value("0xffffffffffffffff")); // 超出 Int64
        Assert.AreEqual("0", Display("1/1e400"));
        Assert.AreEqual("(1+2)*3\u3000+4", Calculator.Normalize("（１＋２）＊３\u3000＋４")); // 全角空格不动
        CollectionAssert.AreEqual(
            new[] { new CalcCopy("复制十六进制", "0xA"), new CalcCopy("复制二进制", "0b1010") },
            Calculator.ResultFor("0b1010")?.Copies.ToArray());
    }
}
