// 第五版：同步文件夹的规矩（标记、device.json、编号、刹车）。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncFolderRuleTests
{
    [TestMethod]
    public void MarkerRoundTrips()
    {
        var library = "0F8FAD5B-D9CB-469F-A165-70867728950E";
        var text = SyncFolderRules.Marker(library);
        Assert.AreEqual(
            "{\"format\":1,\"kind\":\"kitty-notes-sync\",\"library\":\"0F8FAD5B-D9CB-469F-A165-70867728950E\"}",
            text);
        Assert.AreEqual(library, SyncFolderRules.ParseMarker(text));
        Assert.IsNull(SyncFolderRules.ParseMarker("{}"));
        Assert.IsNull(SyncFolderRules.ParseMarker("""{"format":2,"kind":"kitty-notes-sync","library":"A"}"""));
        Assert.IsNull(SyncFolderRules.ParseMarker("not json"));
    }

    [TestMethod]
    public void DeviceNamesAndFiles()
    {
        Assert.IsTrue(SyncFolderRules.IsDeviceName("WIN-1"));
        Assert.IsTrue(SyncFolderRules.IsDeviceName(new string('A', 64)));
        Assert.IsFalse(SyncFolderRules.IsDeviceName(string.Empty));
        Assert.IsFalse(SyncFolderRules.IsDeviceName(new string('A', 65)));
        Assert.IsFalse(SyncFolderRules.IsDeviceName("WIN_1"));

        var text = SyncFolderRules.DeviceJson(4, "我的电脑");
        Assert.AreEqual("{\"epoch\":4,\"format\":1,\"name\":\"我的电脑\"}", text);
        Assert.AreEqual((4, "我的电脑"), SyncFolderRules.ParseDevice(text));
        Assert.IsNull(SyncFolderRules.ParseDevice("{}"));

        Assert.AreEqual("clips.json", SyncFolderRules.FileName("clips"));
        Assert.IsTrue(SyncFolderRules.IsSyncedKind("services"));
        Assert.IsFalse(SyncFolderRules.IsSyncedKind("notes"));
    }

    [TestMethod]
    public void BrakeThresholds()
    {
        Assert.IsFalse(SyncFolderRules.ShouldBrake(20, 100));
        Assert.IsTrue(SyncFolderRules.ShouldBrake(21, 100));
        Assert.IsFalse(SyncFolderRules.ShouldBrake(1, 4));
        Assert.IsTrue(SyncFolderRules.ShouldBrake(2, 5));  // 40%
        Assert.IsFalse(SyncFolderRules.ShouldBrake(1, 10)); // 10%
        Assert.IsTrue(SyncFolderRules.ShouldBrake(3, 9));   // 33%
    }
}
