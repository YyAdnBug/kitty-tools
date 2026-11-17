// 识字时认二维码 / 条码（REVIEW R105，对齐 mac 识字的「二维码优先」：mac 用 Vision 的 DetectBarcodesRequest，
// WinRT 没有认静态图片里条码的公开接口、依赖又只许用微软的包，所以自己写，纯 C#、只用 BCL）。
// 认：二维码（版本 1–40、四个纠错等级、数字 / 字母数字 / 字节 / 汉字模式、ECI、镜像、反色、转一点、透视、一图多码），
// 一维码 EAN-13、EAN-8、UPC-A、UPC-E、Code 128、Code 39、ITF。DataMatrix、PDF417、Aztec 不认（MAC-DIFF「长期例外」）。
// 流程：BGRA → 灰度 → 块自适应二值化；大图（超过 400 万像素）先在缩小的图上找定位图案、到原图上取样，没找到再在原图上找一遍；
// 二维码在前，一维码在后，重复的去掉。有时间上限（默认 1.5 秒），到点就把已经读出来的交出去（一个都没有就当没码）。
// 纯函数，在后台线程调；单测用 windows/tools/barcode-fixtures.swift 在 Mac 上生成的图（Fixtures/barcodes/）。
using System.Diagnostics;

namespace KittyTools.Core.Barcodes;

public static class BarcodeReader
{
    public const int DefaultBudgetMilliseconds = 1500;

    /// <summary>超过这么多像素的图，先在缩小的图上找定位图案。</summary>
    private const int DetectionPixels = 4_000_000;

    /// <summary>
    /// 图里所有码的内容（二维码在前，同样的只留一个）；没有码返回空表。
    /// bgra 是一行接一行、每像素 4 字节、不预乘的 alpha（透明当白底）。
    /// </summary>
    public static IReadOnlyList<string> Read(ReadOnlySpan<byte> bgra, int width, int height, int budgetMilliseconds = DefaultBudgetMilliseconds)
    {
        if (width < 8 || height < 8 || bgra.Length < (long)width * height * 4)
        {
            return Array.Empty<string>();
        }

        var deadline = new Deadline(budgetMilliseconds);
        var gray = BarcodeImage.Luma(bgra, width, height);
        if (BarcodeImage.Binarize(gray, width, height) is not { } full)
        {
            return Array.Empty<string>();
        }

        var results = new List<string>();
        void Add(IEnumerable<string> texts)
        {
            foreach (var text in texts)
            {
                if (text.Length > 0 && !results.Contains(text))
                {
                    results.Add(text);
                }
            }
        }

        // 大图：缩到 400 万像素以内找定位图案，在原图上取样
        var detectionGray = gray;
        var detectionWidth = width;
        var detectionHeight = height;
        var factor = 1;
        while ((long)detectionWidth * detectionHeight > DetectionPixels)
        {
            (detectionGray, detectionWidth, detectionHeight) = BarcodeImage.Halve(detectionGray, detectionWidth, detectionHeight);
            factor *= 2;
        }

        if (factor > 1 && BarcodeImage.Binarize(detectionGray, detectionWidth, detectionHeight) is { } coarse)
        {
            Add(QrDetector.Detect(coarse, full, factor, deadline));
        }

        // ponytail: 缩小的图上找到了就不再到原图上找更小的码；一张大图里同时有大码和缩小后看不清的小码时，只认得出大的
        if (results.Count == 0 && !deadline.Expired)
        {
            Add(QrDetector.Detect(full, full, 1, deadline));
        }

        if (!deadline.Expired)
        {
            Add(LinearBarcodes.Detect(full, deadline));
        }

        return results;
    }
}

/// <summary>时间上限：到点之后各个循环尽快收手。</summary>
internal readonly struct Deadline
{
    private readonly long _end;

    public Deadline(int milliseconds) => _end = Stopwatch.GetTimestamp() + milliseconds * Stopwatch.Frequency / 1000;

    public bool Expired => Stopwatch.GetTimestamp() >= _end;
}
