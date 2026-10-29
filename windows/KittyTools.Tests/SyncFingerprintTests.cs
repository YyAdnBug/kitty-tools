// REVIEW R49：同步什么都没变时跳过整轮，靠的是 SyncDisk.Fingerprint——要读的文件动了它就变，别的文件动了它不变。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncFingerprintTests
{
    private const string Device = "11111111-1111-4111-8111-111111111111";

    [TestMethod]
    public void ChangesOnlyWhenAFileARoundReadsChanges()
    {
        using var temp = new TempFolder();
        var disk = new SyncDisk(temp.Path);
        File.WriteAllText(Path.Combine(temp.Path, SyncFolderRules.MarkerFile), "{}");
        var device = temp.Sub(Path.Combine(SyncFolderRules.DevicesFolder, Device));
        File.WriteAllText(Path.Combine(device, SyncFolderRules.DeviceFile), "{}");
        File.WriteAllText(Path.Combine(device, SyncFolderRules.FileName(ClipSync.Kind)), "[]");
        var kinds = new[] { ClipSync.Kind, VocabularySync.Kind };

        var first = disk.Fingerprint(kinds);
        Assert.AreEqual(first, disk.Fingerprint(kinds));

        // 没勾的那一类、文件夹里别的东西（mac 的便签）动了：不算。
        File.WriteAllText(Path.Combine(device, SyncFolderRules.FileName(EngineSync.Kind)), "[]");
        File.WriteAllText(Path.Combine(temp.Path, "notes.json"), "[]");
        Assert.AreEqual(first, disk.Fingerprint(kinds));

        // 勾着的那一类多了一个文件、改了一个文件：都算。
        File.WriteAllText(Path.Combine(device, SyncFolderRules.FileName(VocabularySync.Kind)), "[]");
        var second = disk.Fingerprint(kinds);
        Assert.AreNotEqual(first, second);
        File.WriteAllText(Path.Combine(device, SyncFolderRules.FileName(ClipSync.Kind)), "[1, 2]");
        Assert.AreNotEqual(second, disk.Fingerprint(kinds));

        // 来了一台新电脑：算。
        var third = disk.Fingerprint(kinds);
        var other = temp.Sub(Path.Combine(SyncFolderRules.DevicesFolder, "99999999-9999-4999-8999-999999999999"));
        File.WriteAllText(Path.Combine(other, SyncFolderRules.DeviceFile), "{}");
        Assert.AreNotEqual(third, disk.Fingerprint(kinds));
    }
}
