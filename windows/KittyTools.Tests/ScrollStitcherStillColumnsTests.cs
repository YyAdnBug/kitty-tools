// 长截图的容差比较只比在动的列、只让有字的行投票（照 mac 0ff55dd7「电脑上的移动端网页也接得上」）：
// 固定侧栏旁边的页面、两边灰底留白 + 小数像素重画的移动端版式。两个场景在旧算法上都失败（侧栏：一帧都接不上；
// 移动端：接成 191 行重叠，Python 移植比过），新算法都接成 130。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollStitcherStillColumnsTests
{
    private const int Height = 200;
    private const int Dark = unchecked((int)0xFF202020);

    /// <summary>小数像素重画后的字：差两级亮度，整行哈希就对不上了。</summary>
    private const int DarkShifted = unchecked((int)0xFF222222);

    private const int White = unchecked((int)0xFFFFFFFF);

    private static uint Mix(int a, int b) => (((uint)a * 2654435761u) ^ (uint)(b * 40503)) >> 13;

    /// <summary>页面第 row 行第 x 列：每 12 行里 5 行是字（随机的深色点），其余是空白行。</summary>
    private static int Page(int row, int x, bool shifted)
        => row % 12 < 5 && Mix(row, x) % 8 < 3 ? (shifted ? DarkShifted : Dark) : White;

    /// <summary>左边 16 列是固定侧栏（跟着屏幕行、不跟着滚），中间 32 列是页面，右边一条灰。</summary>
    private static ScrollFrame Sidebar(int offset)
    {
        const int width = 64;
        var pixels = new int[width * Height];
        for (var row = 0; row < Height; row++)
        {
            for (var x = 0; x < width; x++)
            {
                pixels[row * width + x] = x < 16
                    ? unchecked((int)(0xFF000000u | (Mix(row + 1000, x) & 0xFFFFFFu)))
                    : x < 48
                        ? Page(offset + row, x, shifted: false)
                        : unchecked((int)0xFFE0E0E0);
            }
        }

        return new ScrollFrame(width, Height, pixels);
    }

    /// <summary>移动端版式：中间 32 列是页面，两边 24 列灰底留白；shifted = 这一帧的字按小数像素重画过。</summary>
    private static ScrollFrame Mobile(int offset, bool shifted)
    {
        const int width = 80;
        var pixels = new int[width * Height];
        for (var row = 0; row < Height; row++)
        {
            for (var x = 0; x < width; x++)
            {
                pixels[row * width + x] = x is >= 24 and < 56 ? Page(offset + row, x, shifted) : unchecked((int)0xFFE8E8E8);
            }
        }

        return new ScrollFrame(width, Height, pixels);
    }

    [TestMethod]
    public void StitchesPageBesideFixedSidebar()
    {
        Assert.AreEqual((0, 130), ScrollStitcher.Plan(Sidebar(0), Sidebar(70), ScrollDirection.Down));
        Assert.AreEqual((0, 130), ScrollStitcher.Plan(Sidebar(70), Sidebar(0), ScrollDirection.Up));
        var stitched = ScrollStitcher.Append(Sidebar(0), Sidebar(70), ScrollDirection.Down);
        Assert.IsNotNull(stitched);
        Assert.AreEqual(270, stitched!.Height);
        // 拼出来的页面那几列是连续的：第 269 行就是页面第 269 行。
        for (var x = 16; x < 48; x++)
        {
            Assert.AreEqual(Page(269, x, shifted: false), stitched.Pixels[269 * 64 + x]);
        }
    }

    [TestMethod]
    public void StitchesMobileLayoutWithMarginsAndSubpixelText()
    {
        Assert.AreEqual((0, 130), ScrollStitcher.Plan(Mobile(0, false), Mobile(70, true), ScrollDirection.Down));
        Assert.AreEqual((0, 130), ScrollStitcher.Plan(Mobile(70, false), Mobile(0, true), ScrollDirection.Up));
    }
}
