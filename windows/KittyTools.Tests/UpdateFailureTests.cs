// PLAN-v26 G3：更新失败的分类——只有网络问题给重试，磁盘满、没权限各说各的。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class UpdateFailureTests
{
    [TestMethod]
    public void Classifies()
    {
        Assert.AreEqual(UpdateFailure.Kind.Network, UpdateFailure.Classify("HttpRequestException", 0));
        Assert.AreEqual(UpdateFailure.Kind.Network, UpdateFailure.Classify("TaskCanceledException", 0));
        Assert.AreEqual(UpdateFailure.Kind.DiskFull, UpdateFailure.Classify("IOException", unchecked((int)0x80070070)));
        Assert.AreEqual(UpdateFailure.Kind.Permission, UpdateFailure.Classify("UnauthorizedAccessException", 0));
        Assert.AreEqual(UpdateFailure.Kind.Permission, UpdateFailure.Classify("IOException", unchecked((int)0x80070005)));
        Assert.AreEqual(UpdateFailure.Kind.Other, UpdateFailure.Classify("InvalidDataException", 0));
        Assert.IsTrue(UpdateFailure.Message(UpdateFailure.Kind.Network).Detail.Contains("重试"));
    }
}
