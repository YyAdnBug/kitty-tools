// REVIEW R77 / PLAN-v20 M2：同步文件夹里还没下载的文件（占位）进指纹——下载完大小、时间不变，只有这一位变，下一轮才会重读；
// 不在云盘里的文件夹不设「始终保留在此设备上」。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncKeepLocalTests
{
    [TestMethod]
    public void PlaceholderChangesTheStamp()
    {
        var folder = Path.Combine(Path.GetTempPath(), "kitty-keep-local-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "device.json");
        File.WriteAllText(file, "{}");
        try
        {
            var here = SyncDisk.Stamp(new FileInfo(file));
            File.SetAttributes(file, File.GetAttributes(file) | FileAttributes.Offline);
            var offline = SyncDisk.Stamp(new FileInfo(file));
            Assert.AreEqual(here + ":p", offline, "同样大小、同样时间，只差还没下载");
            Assert.AreEqual("-", SyncDisk.Stamp(new FileInfo(Path.Combine(folder, "none.json"))));
            Assert.IsFalse(SyncDisk.KeepLocal(folder), "普通文件夹不是云盘：不设");
            Assert.AreEqual((FileAttributes)0, File.GetAttributes(folder) & (FileAttributes)0x80000);
        }
        finally
        {
            File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(folder, recursive: true);
        }
    }
}
