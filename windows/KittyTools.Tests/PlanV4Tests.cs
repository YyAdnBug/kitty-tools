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
        Assert.AreEqual("录屏 2026-10-25 18.15.46.mp4", RecorderRules.FileName(now));
        Assert.AreEqual("录音 2026-10-25 18.15.46.m4a", RecorderRules.FileName(now, audio: true));

        var temporary = RecorderRules.TemporaryPath(@"C:\Users\Y\Videos\Screen Recordings");
        Assert.AreEqual(@"C:\", Path.GetPathRoot(temporary));
        Assert.IsTrue(temporary.EndsWith(".mp4", StringComparison.Ordinal));
        Assert.AreNotEqual(temporary, RecorderRules.TemporaryPath(@"C:\Users\Y\Videos\Screen Recordings"));
    }

    [TestMethod]
    public void KeycapsShowEverythingOrOnlyShortcuts()
    {
        // 全部按键（默认）：打字也显示，修饰键连着写。
        Assert.AreEqual("A", RecordingOverlay.KeycapText("A", false, false, false, false, false, false, shortcutsOnly: false));
        Assert.AreEqual("Shift + A", RecordingOverlay.KeycapText("A", false, false, true, false, false, false, false));
        Assert.AreEqual("Ctrl + Alt + Shift + Win + K", RecordingOverlay.KeycapText("K", true, true, true, true, false, false, false));
        // 只显示快捷键：Shift + 字母、单个字母不显示；Ctrl 组合、Esc、F 键显示。
        Assert.IsNull(RecordingOverlay.KeycapText("A", false, false, false, false, false, false, shortcutsOnly: true));
        Assert.IsNull(RecordingOverlay.KeycapText("A", false, false, true, false, false, false, true));
        Assert.AreEqual("Ctrl + S", RecordingOverlay.KeycapText("S", true, false, false, false, false, false, true));
        Assert.AreEqual("Esc", RecordingOverlay.KeycapText("Esc", false, false, false, false, false, true, true));
        Assert.AreEqual("F5", RecordingOverlay.KeycapText("F5", false, false, false, false, true, false, true));
        // 认不得的键、修饰键本身：都不显示。
        Assert.IsNull(RecordingOverlay.KeycapText(null, true, false, false, false, false, false, false));
    }

    [TestMethod]
    public void FrameRateIsThirtyOrSixty()
    {
        // DefaultFps 是常量，分析器认为这条恒真（MSTEST0032）；留着它是为了有人改默认帧率时这里先红。
#pragma warning disable MSTEST0032
        Assert.AreEqual(30, RecorderRules.DefaultFps);
#pragma warning restore MSTEST0032
        Assert.AreEqual(30, RecorderRules.NormalizeFps(15));
        Assert.AreEqual(30, RecorderRules.NormalizeFps(30));
        Assert.AreEqual(30, RecorderRules.NormalizeFps(59));
        Assert.AreEqual(60, RecorderRules.NormalizeFps(60));
        Assert.AreEqual(60, RecorderRules.NormalizeFps(120));
    }

    [TestMethod]
    public void AudioSourceDefaultsToMicrophone()
    {
        Assert.AreEqual((false, true), RecorderRules.AudioSource("microphone"));
        Assert.AreEqual((true, false), RecorderRules.AudioSource("system"));
        Assert.AreEqual((true, true), RecorderRules.AudioSource("both"));
        Assert.AreEqual((false, true), RecorderRules.AudioSource(null));
        Assert.AreEqual((false, true), RecorderRules.AudioSource("speaker"));
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
