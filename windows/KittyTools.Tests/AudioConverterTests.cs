// R14 / PLAN-v6 第 2 批：设备混音格式 → 48 kHz 双声道 float32 的转换单测
// （48 kHz 双声道直通、单声道复制、5.1 下混、44.1 kHz 线性重采样、16 / 24 位 PCM）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Runtime.InteropServices;

namespace KittyTools.Tests;

[TestClass]
public sealed class AudioConverterTests
{
    [TestMethod]
    public void Stereo48kFloatIsPassedThrough()
    {
        var converter = new AudioConverter(48_000, 2, isFloat: true, bitsPerSample: 32);
        var samples = new float[] { 0.1f, -0.2f, 0.3f, -0.4f };
        var bytes = MemoryMarshal.AsBytes(samples.AsSpan());

        var result = converter.Convert(bytes, 2);

        CollectionAssert.AreEqual(samples, result.ToArray());
    }

    [TestMethod]
    public void MonoPcm16IsDuplicatedToBothChannels()
    {
        var converter = new AudioConverter(48_000, 1, isFloat: false, bitsPerSample: 16);
        var pcm = new short[] { 16384, -16384 };
        var bytes = MemoryMarshal.AsBytes(pcm.AsSpan());

        var result = converter.Convert(bytes, 2).ToArray();

        Assert.AreEqual(0.5f, result[0], 0.0001f);
        Assert.AreEqual(0.5f, result[1], 0.0001f);
        Assert.AreEqual(-0.5f, result[2], 0.0001f);
        Assert.AreEqual(-0.5f, result[3], 0.0001f);
    }

    [TestMethod]
    public void SixChannelsDownmixWithCenterAndSides()
    {
        var converter = new AudioConverter(48_000, 6, isFloat: true, bitsPerSample: 32);
        var frame = new float[]
        {
            0.4f, 0.1f, // FL FR
            0.2f, 0.9f, // FC LFE（LFE 丢掉）
            0.1f, 0.2f, // SL SR
        };
        var bytes = MemoryMarshal.AsBytes(frame.AsSpan());

        var result = converter.Convert(bytes, 1).ToArray();

        Assert.AreEqual(0.4f + 0.707f * 0.2f + 0.707f * 0.1f, result[0], 0.001f);
        Assert.AreEqual(0.1f + 0.707f * 0.2f + 0.707f * 0.2f, result[1], 0.001f);
    }

    [TestMethod]
    public void DownmixNormalizesWhenSumExceedsOne()
    {
        var converter = new AudioConverter(48_000, 6, isFloat: true, bitsPerSample: 32);
        var frame = new float[] { 1f, 1f, 1f, 0f, 1f, 1f };
        var bytes = MemoryMarshal.AsBytes(frame.AsSpan());

        var result = converter.Convert(bytes, 1).ToArray();

        Assert.IsTrue(result[0] <= 1f && result[1] <= 1f);
        Assert.AreEqual(1f, result[0], 0.001f);
    }

    [TestMethod]
    public void FortyFourOneResamplesToFortyEight()
    {
        var converter = new AudioConverter(44_100, 2, isFloat: true, bitsPerSample: 32);
        const int inputFrames = 441;
        var samples = new float[inputFrames * 2];
        Array.Fill(samples, 0.25f);
        var bytes = MemoryMarshal.AsBytes(samples.AsSpan());

        var result = converter.Convert(bytes, inputFrames).ToArray();

        Assert.AreEqual(480, result.Length / 2, 2);
        for (var index = 0; index < result.Length; index++)
        {
            Assert.AreEqual(0.25f, result[index], 0.0001f);
        }
    }

    [TestMethod]
    public void Pcm24IsReadAsSignedLittleEndian()
    {
        var converter = new AudioConverter(48_000, 2, isFloat: false, bitsPerSample: 24);
        var bytes = new byte[]
        {
            0x00, 0x00, 0x40, // 0.5
            0x00, 0x00, 0xC0, // -0.5
        };

        var result = converter.Convert(bytes, 1).ToArray();

        Assert.AreEqual(0.5f, result[0], 0.0001f);
        Assert.AreEqual(-0.5f, result[1], 0.0001f);
    }
}
