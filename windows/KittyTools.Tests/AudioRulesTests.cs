// R14 录屏声音的纯函数单测：时间戳换帧号、混音的相加 / 限幅 / 越过已取出段、浮点转 16 位 PCM。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AudioRulesTests
{
    [TestMethod]
    public void FramesAtUsesHundredNanosecondClock()
    {
        Assert.AreEqual(0, AudioRules.FramesAt(5_000_000, 5_000_000));
        Assert.AreEqual(48_000, AudioRules.FramesAt(15_000_000, 5_000_000));
        Assert.AreEqual(24, AudioRules.FramesAt(5_005_000, 5_000_000));
        Assert.AreEqual(0, AudioRules.FramesAt(4_999_999, 5_000_000), "早于起点的算第 0 帧");
    }

    [TestMethod]
    public void Pcm16ClampsAndRoundsAwayFromZero()
    {
        Assert.AreEqual((short)-32768, AudioRules.ToPcm16(-2f));
        Assert.AreEqual((short)32767, AudioRules.ToPcm16(2f));
        Assert.AreEqual((short)16384, AudioRules.ToPcm16(0.5f));
        Assert.AreEqual((short)-16384, AudioRules.ToPcm16(-0.5f));
        Assert.AreEqual((short)0, AudioRules.ToPcm16(float.NaN));
    }

    [TestMethod]
    public void MixAddsOverlappingSourcesAndClamps()
    {
        var buffer = new AudioMixBuffer(48_000);
        var left = new float[] { 0.4f, 0.4f, 0.2f, 0.2f, 0.9f, 0.9f, 0.9f, 0.9f };
        var right = new float[] { 0.4f, 0.4f, 0.2f, 0.2f, 0.9f, 0.9f, 0.9f, 0.9f };
        Assert.IsTrue(buffer.Add(10, left));
        Assert.IsTrue(buffer.Add(11, right));

        var skip = new byte[AudioRules.PcmBlockAlign * 10];
        Assert.AreEqual(10, buffer.DrainPcm16(10, skip, 10));
        var destination = new byte[AudioRules.PcmBlockAlign * 4];
        var frames = buffer.DrainPcm16(14, destination, 4);
        Assert.AreEqual(4, frames);
        Assert.AreEqual(14L, buffer.Flushed);

        // 第 10 帧只有 left（双声道都是 0.4）；第 11 帧 0.2 + 0.4；第 12 帧 0.9 + 0.2；第 13 帧 0.9 + 0.9。
        Assert.AreEqual(AudioRules.ToPcm16(0.4f), Read(destination, 0));
        Assert.AreEqual(AudioRules.ToPcm16(0.4f), Read(destination, 1));
        Assert.AreEqual(AudioRules.ToPcm16(0.6f), Read(destination, 2));
        Assert.AreEqual(AudioRules.ToPcm16(0.6f), Read(destination, 3));
        Assert.AreEqual((short)32767, Read(destination, 4));
        Assert.AreEqual((short)32767, Read(destination, 5));
        Assert.AreEqual((short)32767, Read(destination, 6));
        Assert.AreEqual((short)32767, Read(destination, 7));
    }

    [TestMethod]
    public void LateChunkIsIgnoredInsteadOfRewinding()
    {
        var buffer = new AudioMixBuffer(48_000);
        var sample = new float[] { 0.5f, 0.5f, 0.5f, 0.5f };
        Assert.IsTrue(buffer.Add(0, sample));

        var destination = new byte[AudioRules.PcmBlockAlign * 10];
        Assert.AreEqual(2, buffer.DrainPcm16(2, destination, 10));

        // 第 0–1 帧已经交出去了，晚到的这一段整段在已取出的范围里，直接返回 true，不改缓冲。
        Assert.IsTrue(buffer.Add(0, sample));
        Assert.AreEqual(2L, buffer.Flushed);
        Assert.AreEqual(2L, buffer.Written);
    }

    [TestMethod]
    public void MissingFramesComeOutAsSilence()
    {
        var buffer = new AudioMixBuffer(48_000);
        var sample = new float[] { 0.5f, -0.5f, 0.5f, -0.5f };
        Assert.IsTrue(buffer.Add(100, sample));

        var destination = new byte[AudioRules.PcmBlockAlign * 4];
        Assert.AreEqual(4, buffer.DrainPcm16(104, destination, 4));
        Assert.AreEqual((short)0, Read(destination, 0), "第 100 帧之前的都补静音");
        Assert.AreEqual((short)0, Read(destination, 1));
        Assert.AreEqual((short)0, Read(destination, 2));
        Assert.AreEqual((short)0, Read(destination, 3));
    }

    [TestMethod]
    public void ChunkBeyondCapacityIsRejected()
    {
        var buffer = new AudioMixBuffer(48_000);
        var sample = new float[] { 0.1f, 0.1f };
        Assert.IsTrue(buffer.Add(0, sample));
        Assert.IsFalse(buffer.Add(48_001, sample));
    }

    private static short Read(byte[] bytes, int frameChannel)
    {
        var offset = frameChannel * 2;
        return (short)(bytes[offset] | (bytes[offset + 1] << 8));
    }
}
