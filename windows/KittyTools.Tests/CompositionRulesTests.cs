// 输入法组字状态的单测（PLAN-v6 第 6 批）：组字期间不查，上屏且非空才查。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class CompositionRulesTests
{
    [TestMethod]
    public void NoQueryWhileComposing()
    {
        Assert.IsFalse(CompositionRules.ShouldSearch(true, "zhong"));
        Assert.IsFalse(CompositionRules.ShouldSearch(true, "中文"));
        Assert.IsFalse(CompositionRules.ShouldSearch(false, null));
        Assert.IsFalse(CompositionRules.ShouldSearch(false, string.Empty));
        Assert.IsTrue(CompositionRules.ShouldSearch(false, "中文"));
        Assert.IsTrue(CompositionRules.ShouldSearch(false, "abc"));
    }
}
