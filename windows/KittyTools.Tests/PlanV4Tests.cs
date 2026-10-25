// 第四版基础录屏的纯函数单测：宽高取偶、文件名、临时文件、剩余空间、时长格式。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RecorderRulesTests
{
    [TestMethod]
    public void SizesAreEven()
    {
        Assert.AreEqual(new RecordSize(2560, 1440), RecorderRules.Even(2560, 1440));
        Assert.AreEqual(new RecordSize(2560, 1440), RecorderRules.Even(2561, 1441));
        Assert.AreEqual(new RecordSize(2, 2), RecorderRules.Even(1, 1));
        Assert.AreEqual(new RecordSize(2, 2), RecorderRules.Even(0, 0));
    }

    [TestMethod]
    public void NamesAndTemporaryFiles()
    {
        var now = new DateTime(2026, 10, 25, 18, 15, 46);
        Assert.AreEqual("录屏 2026-10-25 18.15.46.avi", RecorderRules.FileName(now));
        Assert.AreEqual("录音 2026-10-25 18.15.46.m4a", RecorderRules.FileName(now, audio: true));

        var temporary = RecorderRules.TemporaryPath(@"C:\Users\Y\Videos\Screen Recordings");
        Assert.AreEqual(@"C:\", Path.GetPathRoot(temporary));
        Assert.IsTrue(temporary.EndsWith(".avi", StringComparison.Ordinal));
        Assert.AreNotEqual(temporary, RecorderRules.TemporaryPath(@"C:\Users\Y\Videos\Screen Recordings"));
    }

    [TestMethod]
    public void RoomAndDuration()
    {
        Assert.IsFalse(RecorderRules.HasRoom((1L << 30) - 1));
        Assert.IsTrue(RecorderRules.HasRoom(1L << 30));
        Assert.AreEqual("0:05", RecorderRules.Duration(5000));
        Assert.AreEqual("1:02", RecorderRules.Duration(62_000));
        Assert.AreEqual("0:00", RecorderRules.Duration(-1));
    }
}
