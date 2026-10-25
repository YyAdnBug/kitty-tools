// 录屏点按圈 / 按键胶囊的绘制单测：画了和没画、圈的两种颜色、胶囊区域、过期不画。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RecordingOverlayTests
{
    private static byte[] Canvas(int width, int height)
    {
        var bgra = new byte[width * height * 4];
        for (var index = 0; index < bgra.Length; index += 4)
        {
            bgra[index] = 40;
            bgra[index + 1] = 40;
            bgra[index + 2] = 40;
            bgra[index + 3] = 255;
        }

        return bgra;
    }

    [TestMethod]
    public void NoEffectsLeavesCanvasAlone()
    {
        var bgra = Canvas(200, 120);
        var copy = bgra.ToArray();
        RecordingOverlay.Render(bgra, 200, 120, 1000, Array.Empty<ClickRing>(), null);
        CollectionAssert.AreEqual(copy, bgra);
    }

    [TestMethod]
    public void RingChangesPixelsAroundThePoint()
    {
        var bgra = Canvas(200, 120);
        var copy = bgra.ToArray();
        var rings = new[] { new ClickRing(100, 60, false, 1000, 0) };
        RecordingOverlay.Render(bgra, 200, 120, 1100, rings, null);
        Assert.IsTrue(Changed(bgra, copy) > 0);

        // 左键偏粉（红分量大），右键偏蓝。
        var left = Canvas(200, 120);
        RecordingOverlay.Render(left, 200, 120, 1100, rings, null);
        var right = Canvas(200, 120);
        RecordingOverlay.Render(right, 200, 120, 1100, new[] { new ClickRing(100, 60, true, 1000, 0) }, null);
        Assert.IsTrue(RedSum(left, copy) > BlueSum(left, copy));
        Assert.IsTrue(BlueSum(right, copy) > RedSum(right, copy));
    }

    private static int Changed(byte[] after, byte[] before)
    {
        var count = 0;
        for (var index = 0; index < after.Length; index += 4)
        {
            if (after[index] != before[index] || after[index + 2] != before[index + 2])
            {
                count++;
            }
        }

        return count;
    }

    private static long RedSum(byte[] after, byte[] before)
    {
        long sum = 0;
        for (var index = 0; index < after.Length; index += 4)
        {
            sum += Math.Abs(after[index + 2] - before[index + 2]);
        }

        return sum;
    }

    private static long BlueSum(byte[] after, byte[] before)
    {
        long sum = 0;
        for (var index = 0; index < after.Length; index += 4)
        {
            sum += Math.Abs(after[index] - before[index]);
        }

        return sum;
    }

    [TestMethod]
    public void RingFadesAndExpires()
    {
        var rings = new[] { new ClickRing(100, 60, false, 1000, 0) };
        var late = Canvas(200, 120);
        RecordingOverlay.Render(late, 200, 120, 1000 + RecordingOverlay.RingDurationMs + 1, rings, null);
        CollectionAssert.AreEqual(Canvas(200, 120), late);
    }

    [TestMethod]
    public void KeycapDrawsAtBottomCenter()
    {
        var bgra = Canvas(400, 200);
        var copy = bgra.ToArray();
        RecordingOverlay.Render(bgra, 400, 200, 1000, Array.Empty<ClickRing>(),
            new Keycap("Ctrl + Shift + S", 900));
        var y = 200 - RecordingOverlay.KeycapHeight / 2 - 10;
        var changed = false;
        for (var x = 0; x < 400; x++)
        {
            var offset = (y * 400 + x) * 4;
            if (bgra[offset] != copy[offset] || bgra[offset + 2] != copy[offset + 2])
            {
                changed = true;
                break;
            }
        }

        Assert.IsTrue(changed);
    }

    [TestMethod]
    public void KeycapExpires()
    {
        var bgra = Canvas(400, 200);
        RecordingOverlay.Render(bgra, 400, 200, 1000 + RecordingOverlay.KeycapDurationMs + 1,
            Array.Empty<ClickRing>(), new Keycap("Ctrl + S", 1000));
        CollectionAssert.AreEqual(Canvas(400, 200), bgra);
    }
}
