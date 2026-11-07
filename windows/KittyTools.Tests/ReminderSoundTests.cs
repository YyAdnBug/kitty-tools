// 提醒的提示音文件（PLAN-v16 E2，照 mac ReminderSound.importFile）：拷进来的名字、同名不同内容的编号、编号只认一段文件名、自定义催促的范围。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ReminderSoundTests
{
    [TestMethod]
    public void ImportedNamesAreOneSafeSegment()
    {
        Assert.AreEqual("下课铃", Reminders.ChimeStem("下课铃"));
        Assert.AreEqual("a b", Reminders.ChimeStem("a:b"));
        Assert.AreEqual("a b c", Reminders.ChimeStem("a/b\\c"));
        Assert.AreEqual("提示音", Reminders.ChimeStem(" .. "));
        Assert.AreEqual("提示音", Reminders.ChimeStem(string.Empty));
        Assert.AreEqual("x", Reminders.ChimeStem(".x."));
        Assert.AreEqual(60, Reminders.ChimeStem(new string('长', 80)).Length);

        Assert.AreEqual("下课铃.mp3", Reminders.ChimeCandidate("下课铃", "MP3", 1));
        Assert.AreEqual("下课铃 2.mp3", Reminders.ChimeCandidate("下课铃", "mp3", 2));
        // 拷进来的名字拼成编号都认（编号会跟着同步到 mac）
        foreach (var stem in new[] { "下课铃", "a:b", "a/b\\c", " .. ", new string('长', 80) })
        {
            var id = Reminders.ChimeFilePrefix + Reminders.ChimeCandidate(Reminders.ChimeStem(stem), "wav", 3);
            Assert.IsTrue(Reminders.IsValidChime(id), id);
            Assert.IsNotNull(Reminders.ChimeFileName(id), id);
        }
    }

    [TestMethod]
    public void FileNamesComeOnlyFromValidIds()
    {
        Assert.AreEqual("下课铃.mp3", Reminders.ChimeFileName("file:下课铃.mp3"));
        foreach (var id in new[] { "Glass", "file:../x.mp3", "file:a/b.mp3", "file:a\\b.mp3", "file:x.exe", "file:", "file:.mp3", "file:a*b.mp3", "file:a?.mp3" })
        {
            Assert.IsNull(Reminders.ChimeFileName(id), id);
        }

        // 这台有那个文件：只写文件名；没有：注明放通知声（和以前一样）
        Assert.AreEqual("下课铃", Reminders.ChimeTitle("file:下课铃.mp3", available: true));
        Assert.AreEqual("下课铃（这台电脑放通知声）", Reminders.ChimeTitle("file:下课铃.mp3", available: false));
        Assert.AreEqual("叮", Reminders.ChimeTitle("Ping", available: true));
    }

    [TestMethod]
    public void CustomNagRange()
    {
        Assert.IsTrue(Reminders.IsValidNag(0) && Reminders.IsValidNag(1) && Reminders.IsValidNag(7) && Reminders.IsValidNag(Reminders.MaxNag));
        Assert.IsFalse(Reminders.IsValidNag(-1) || Reminders.IsValidNag(Reminders.MaxNag + 1));
    }
}
