// 便携软件（PLAN-v18 §6 A3 A5）：UserAssist 的 ROT13、72 字节、已知文件夹 GUID；不收卸载 / 安装 / 更新这类 exe（7zFM 这类不误伤）；
// 同一个文件夹里说明一样的只留 64 位那个。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PortableAppsTests
{
    private static byte[] Value(uint count, DateTime? last)
    {
        var value = new byte[72];
        BitConverter.GetBytes(count).CopyTo(value, 4);
        if (last is { } time)
        {
            BitConverter.GetBytes(time.ToFileTimeUtc()).CopyTo(value, 60);
        }

        return value;
    }

    [TestMethod]
    public void DecodesUserAssistEntries()
    {
        Assert.AreEqual(@"D:\Tools\Everything\Everything.exe", PortableApps.Rot13(@"Q:\Gbbyf\Rirelguvat\Rirelguvat.rkr"));
        Assert.AreEqual("abc XYZ 中文 123", PortableApps.Rot13(PortableApps.Rot13("abc XYZ 中文 123")));
        var when = new DateTime(2026, 11, 10, 8, 30, 0, DateTimeKind.Utc);
        var entry = PortableApps.Parse(@"Q:\Gbbyf\Rirelguvat\Rirelguvat.rkr", Value(7, when), _ => null);
        Assert.AreEqual(new UserAssistEntry(@"D:\Tools\Everything\Everything.exe", 7, when), entry);
        // 开头是已知文件夹的 GUID（{6D809377-…} = Program Files）：换成真路径；换不出来跳过
        var programFiles = Guid.Parse("6D809377-6AF0-444B-8957-A3773F02200E");
        var mapped = PortableApps.Parse(PortableApps.Rot13(@"{6D809377-6AF0-444B-8957-A3773F02200E}\7-Zip\7zFM.exe"), Value(2, null),
            guid => guid == programFiles ? @"C:\Program Files" : null);
        Assert.AreEqual(@"C:\Program Files\7-Zip\7zFM.exe", mapped?.Path);
        Assert.IsNull(mapped?.LastRunUtc);
        Assert.IsNull(PortableApps.Parse(PortableApps.Rot13(@"{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}\x.exe"), Value(1, null), _ => null));
        // 没运行过、长度不对的不要
        Assert.IsNull(PortableApps.Parse("n.rkr", Value(0, when), _ => null));
        Assert.IsNull(PortableApps.Parse("n.rkr", new byte[16], _ => null));
    }

    [TestMethod]
    public void SkipsInstallersAndSystemPrograms()
    {
        foreach (var junk in new[] { "unins000.exe", "Uninstall.exe", "setup.exe", "updater.exe", "AutoUpdate.exe", "CrashReporter.exe", "elevate.exe", "vc_redist.x64.exe" })
        {
            Assert.IsTrue(PortableApps.IsJunk(@"D:\Tools\x\" + junk, null), junk);
        }

        foreach (var good in new[] { "7zFM.exe", "Everything.exe", "notepad++.exe", "PotPlayerMini64.exe", "obs64.exe", "Snipaste.exe" })
        {
            Assert.IsFalse(PortableApps.IsJunk(@"D:\Tools\x\" + good, "程序"), good);
        }

        Assert.IsTrue(PortableApps.IsJunk(@"D:\Tools\x\tool.exe", "Foo 卸载程序"));
        Assert.IsTrue(PortableApps.IsCandidate(@"D:\Tools\a.exe", @"C:\Windows", @"C:\Program Files\Kitty Tools"));
        Assert.IsFalse(PortableApps.IsCandidate(@"C:\Windows\System32\cmd.exe", @"C:\Windows", @"C:\Program Files\Kitty Tools"));
        Assert.IsFalse(PortableApps.IsCandidate(@"C:\Program Files\Kitty Tools\KittyTools.exe", @"C:\Windows", @"C:\Program Files\Kitty Tools"));
        Assert.IsFalse(PortableApps.IsCandidate(@"D:\Tools\readme.txt", @"C:\Windows", string.Empty));
        Assert.IsFalse(PortableApps.IsCandidate(@"Microsoft.Windows.Explorer", @"C:\Windows", string.Empty));
        Assert.IsTrue(PortableApps.IsCandidate(@"C:\WindowsApps2\x.exe", @"C:\Windows", string.Empty), "只看整段目录");
    }

    [TestMethod]
    public void KeepsOnePerDescriptionPreferring64Bit()
    {
        var kept = PortableApps.OnePerDescription(new (string, string?)[]
        {
            (@"D:\Tools\Pot\PotPlayerMini.exe", "PotPlayer"),
            (@"D:\Tools\Pot\PotPlayerMini64.exe", "PotPlayer"),
            (@"D:\Tools\Pot\KillPot.exe", null),
            (@"D:\Tools\Other\PotPlayerMini.exe", "PotPlayer"),
        });
        CollectionAssert.AreEqual(
            new[] { @"D:\Tools\Pot\PotPlayerMini64.exe", @"D:\Tools\Pot\KillPot.exe", @"D:\Tools\Other\PotPlayerMini.exe" }, kept);
    }
}
