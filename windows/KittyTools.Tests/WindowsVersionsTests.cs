// 支持哪些 Windows（PLAN-v27 W2）：Win10 2004（19041）起；22000 起算 Win11；20348 以前录屏有黄框。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class WindowsVersionsTests
{
    [TestMethod]
    public void Windows10From2004()
    {
        Assert.IsFalse(WindowsVersions.IsSupported(new Version(10, 0, 17763)), "1809");
        Assert.IsFalse(WindowsVersions.IsSupported(new Version(10, 0, 18363)), "1909");
        Assert.IsTrue(WindowsVersions.IsSupported(new Version(10, 0, 19041)), "2004");
        Assert.IsTrue(WindowsVersions.IsSupported(new Version(10, 0, 19045)), "22H2");
        Assert.IsTrue(WindowsVersions.IsSupported(new Version(10, 0, 26100)));
        Assert.IsFalse(WindowsVersions.IsSupported(new Version(6, 3, 9600)), "8.1");
    }

    [TestMethod]
    public void Windows11AndTheCaptureBorder()
    {
        Assert.IsFalse(WindowsVersions.IsWindows11(new Version(10, 0, 19045)));
        Assert.IsTrue(WindowsVersions.IsWindows11(new Version(10, 0, 22000)));
        Assert.IsTrue(WindowsVersions.ShowsCaptureBorder(new Version(10, 0, 19045)));
        Assert.IsFalse(WindowsVersions.ShowsCaptureBorder(new Version(10, 0, 22621)));
    }

    [TestMethod]
    public void Windows11FontsFallBackOnWindows10()
    {
        var ten = new Version(10, 0, 19045);
        var eleven = new Version(10, 0, 22631);
        Assert.AreEqual("Segoe UI Variable Text", WindowsVersions.FontFor(eleven, "Segoe UI Variable Text"));
        Assert.AreEqual("Segoe UI", WindowsVersions.FontFor(ten, "Segoe UI Variable Display"));
        Assert.AreEqual("Consolas", WindowsVersions.FontFor(ten, "Cascadia Mono"));
        Assert.AreEqual("Cascadia Mono", WindowsVersions.FontFor(eleven, "Cascadia Mono"));
    }
}
