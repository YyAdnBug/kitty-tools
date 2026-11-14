// 一键打码（PLAN-v18 S17）的单测，样本照 mac RedactionTests（ee303f55）：一行字里认哪几段（手机号、邮箱、过 Luhn 的卡号、
// 过校验位的身份证号）、不认哪些（订单号、半截号码、紧挨着别的数字）；Windows 的词框怎么并成打码框、框怎么换成打码区域。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RedactionTests
{
    private static List<string> Found(string text)
        => Redaction.Ranges(text, 2026).Select(range => text.Substring(range.Start, range.Length)).ToList();

    [TestMethod]
    public void FindsPhonesEmailsCardsAndIds()
    {
        CollectionAssert.AreEqual(new[] { "138 0013 8000", "13800138000" }, Found("电话 138 0013 8000，备用 13800138000"));
        CollectionAssert.AreEqual(new[] { "+86 139-1234-5678" }, Found("+86 139-1234-5678"));
        CollectionAssert.AreEqual(new[] { "zhang.xm@example.com" }, Found("邮箱 zhang.xm@example.com 联系"));
        CollectionAssert.AreEqual(new[] { "4111 1111 1111 1111" }, Found("卡号 4111 1111 1111 1111"));
        CollectionAssert.AreEqual(new[] { "11010519491231002X" }, Found("身份证 11010519491231002X"));
        CollectionAssert.AreEqual(new[] { "a@b.co", "4111111111111111" }, Found("a@b.co 和 4111111111111111"));
    }

    [TestMethod]
    public void AdjacentNumbersAreBothCovered()
    {
        // mac 评审实测的漏洞：两个按空格分组的手机号挨着，不能连成一串「卡号」吃掉一个、另一个露出半截
        CollectionAssert.AreEqual(new[] { "138 0000 8000", "139 1820 5678" }, Found("138 0000 8000 139 1820 5678"));
        Assert.AreEqual(0, Found("6222 0212 3456 7890 123").Count, "19 位但过不了 Luhn");
        CollectionAssert.AreEqual(new[] { "4111-1111-1111-1111" }, Found("4111-1111-1111-1111"));
    }

    [TestMethod]
    public void LeavesOtherNumbersAlone()
    {
        foreach (var text in new[]
                 {
                     "1731395200123", // 13 位毫秒时间戳
                     "2026111200384756 2026111200384757 2026111200384758", // 2 开头的订单号
                     "100 200 300 400 500",
                     "icon@2x.png AppIcon@3x.png",
                     "110105194913310021", // 13 月
                     "910105194912310021", // 地区码 9 开头
                     "订单号 2026111200384756",
                     "验证码 482913，5 分钟内有效",
                     "12345678901", // 2 开头不是手机号段
                     "9138001380001", // 手机号前面紧挨着数字
                     "1380013800012345", // 16 位、过不了 Luhn，也不拆出手机号
                     "11010519491231002Y",
                     "110105194912310021", // 校验位不对
                     "Q1 ¥1200 +0%",
                 })
        {
            Assert.AreEqual(0, Found(text).Count, text);
        }
    }

    [TestMethod]
    public void Checksums()
    {
        int[] visa = { 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
        Assert.IsTrue(Redaction.PassesLuhn(visa));
        Assert.IsFalse(Redaction.PassesLuhn(visa[..^1].Append(2).ToArray()));
        Assert.IsFalse(Redaction.PassesLuhn(Array.Empty<int>()));
        Assert.IsTrue(Redaction.IsIDNumber("11010519491231002x", 2026));
        Assert.IsFalse(Redaction.IsIDNumber("110105202712310020", 2026), "出生年在今年之后");
        Assert.IsTrue(Redaction.IsCardNumber(visa));
        Assert.IsFalse(Redaction.IsCardNumber(new[] { 1, 7, 3, 1, 3, 9, 5, 2, 0, 0, 1, 2, 3, 4, 5, 6 }), "1 开头");
        Assert.IsFalse(Redaction.IsIDNumber("1101051949123100", 2026));
    }

    [TestMethod]
    public void WordsCoveredByARangeBecomeOneBox()
    {
        // Windows 识字：中文一个字一个词。「电话 138 0013 8000」→ 盖住后三个词并起来；订单号那行不盖；没有词框的行整行盖。
        static OcrWord Word(string text, double x) => new(text, new RectD(x, 10, text.Length * 8, 16));
        var phone = new OcrLine("电话1380013 8000", new RectD(0, 10, 200, 16), new[]
        {
            Word("电", 0), Word("话", 16), Word("138", 40), Word("0013", 72), Word("8000", 112),
        });
        var order = new OcrLine("订单号2026111200384756", new RectD(0, 40, 200, 16), new[] { Word("订", 0), Word("2026111200384756", 40) });
        var bare = new OcrLine("kitty@example.com", new RectD(0, 70, 150, 16));
        var boxes = Redaction.Boxes(new[] { phone, order, bare }, 2026);
        Assert.AreEqual(2, boxes.Count);
        Assert.AreEqual(RectD.FromLtrb(40, 10, 144, 26), boxes[0]);
        Assert.AreEqual(bare.Box, boxes[1]);
    }

    [TestMethod]
    public void BoxesBecomeAreas()
    {
        // 照 mac boxesBecomeAreas：四周放 pad、夹回区域；伸出区域的夹回来；太小的不要；已经被盖住的不叠第二层
        var area = new RectD(100, 200, 400, 100);
        var boxes = new[]
        {
            new RectD(140, 240, 100, 20),
            new RectD(460, 280, 80, 40), // 伸出区域
            new RectD(300, 250, 0.4, 0.4), // 太小
        };
        var areas = Redaction.Areas(boxes, area, Array.Empty<RectD>(), 3, 2);
        Assert.AreEqual(2, areas.Count);
        Assert.AreEqual(new RectD(137, 237, 106, 26), areas[0]);
        Assert.AreEqual(500, areas[1].Right);
        Assert.AreEqual(300, areas[1].Bottom);
        Assert.AreEqual(0, Redaction.Areas(boxes, area, areas, 3, 2).Count);
    }

    [TestMethod]
    public void TallImagesAreSlicedWithOwnedBands()
    {
        // PLAN-v20 A1：长图一条条识字，相邻两条叠一截，各管一半、首尾相接不漏不重。
        CollectionAssert.AreEqual(new[] { (0, 900, 0, 900) }, Redaction.Slices(900, 4000, 200));
        var slices = Redaction.Slices(10_000, 4000, 200);
        CollectionAssert.AreEqual(new[] { (0, 4000, 0, 3900), (3800, 4000, 3900, 7700), (7600, 2400, 7700, 10_000) }, slices);
        foreach (var height in new[] { 4001, 7801, 30_000 })
        {
            var all = Redaction.Slices(height, 4000, 200);
            Assert.AreEqual(0, all[0].OwnTop);
            Assert.AreEqual(height, all[^1].OwnBottom);
            for (var index = 1; index < all.Count; index++)
            {
                Assert.AreEqual(all[index - 1].OwnBottom, all[index].OwnTop, "管的那一段首尾相接");
                Assert.IsTrue(all[index].Top < all[index - 1].Top + all[index - 1].Rows, "相邻两条叠着");
            }

            Assert.IsTrue(all.All(slice => slice.Rows <= 4000 && slice.Top + slice.Rows <= height));
        }

        Assert.AreEqual(0, Redaction.Slices(0, 4000, 200).Count);
    }

    [TestMethod]
    public void SkewedOcrBoxesAreTurnedBack()
    {
        // PLAN-v20 A1 实测：1200 × 4000 的一条判成顺时针斜 1.3°，「138」报在 (85, 331)，实际在 (123, 320)。
        var straight = OcrScale.Unrotate(new RectD(85, 331, 46, 30), 1.3, 600, 2000);
        Assert.AreEqual(123, straight.X, 2);
        Assert.AreEqual(320, straight.Y, 2);
        Assert.IsTrue(straight.Width >= 46 && straight.Height >= 30, "外接矩形只会比原来大");
        Assert.AreEqual(new RectD(10, 20, 30, 40), OcrScale.Unrotate(new RectD(10, 20, 30, 40), 0, 600, 2000), "没斜就原样");
    }
}
