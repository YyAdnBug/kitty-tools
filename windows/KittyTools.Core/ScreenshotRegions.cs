// 截图翻译的容器范围（对齐复查 R103，照 mac Translate/ScreenshotRegions.swift，d829b1b1）：只在近似纯色、闭合的背景区域里排字，
// 认出气泡、按钮和描边标签。坐标同 ScreenshotOverlay：像素、原点左下。原创实现，不依赖第三方。
// 一张图一个实例：同一块背景只走一遍，后面的字框落在已经走过的区域里直接拿结果。
namespace KittyTools.Core;

public sealed class ScreenshotRegions
{
    /// <summary>和字框的底色差不到这么多算同一块背景。</summary>
    private const double SameBackground = 0.065;

    private readonly int _width;
    private readonly int _height;
    private readonly ushort[] _labels;
    private readonly List<OverlayRect?> _regions = new();

    // ponytail: 每张图最多走两百万个背景像素；渐变、大图或不闭合的区域不加容器约束，照原来的文章排法。
    // 以后要覆盖大幅复杂图片再单独做区域分割；不在截图路径上无界扫描。
    private int _remaining = 2_000_000;

    public ScreenshotRegions(int width, int height)
    {
        _width = Math.Max(0, width);
        _height = Math.Max(0, height);
        _labels = new ushort[_width * _height];
    }

    /// <summary>
    /// 从字框四周找同底色的连通背景，取能包住字框的最小闭合区域（描边标签和外层气泡可能同色）；没有可靠边界时 null。
    /// color(x, y) 按左下原点取像素。
    /// </summary>
    public OverlayRect? Container(OverlayRect box, double lineHeight, OverlayRgb background, Func<int, int, OverlayRgb> color)
    {
        var gap = Math.Max(1, lineHeight * 0.08);
        var seeds = new (double X, double Y)[]
        {
            (box.MidX, box.MaxY + gap),
            (box.MidX, box.MinY - gap),
            (box.MinX - gap, box.MidY),
            (box.MaxX + gap, box.MidY),
        };
        var inner = OverlayRect.FromEdges(box.MinX + 1, box.MinY + 1, box.MaxX - 1, box.MaxY - 1);
        OverlayRect? found = null;
        foreach (var (seedX, seedY) in seeds)
        {
            // 同 mac 的 Int(…)：向零截断
            var x = (int)seedX;
            var y = (int)seedY;
            if (x < 0 || x >= _width || y < 0 || y >= _height || color(x, y).Distance(background) >= SameBackground)
            {
                continue;
            }

            if (Region(x, y, background, color) is not { } rect || !rect.Contains(inner) || rect.Height < lineHeight * 1.1)
            {
                continue;
            }

            if (found is not { } previous || rect.Width * rect.Height < previous.Width * previous.Height)
            {
                found = rect;
            }
        }

        return found;
    }

    /// <summary>同一背景区域只走一次。碰到图边或预算用完就停，不把没有边界的页面背景当按钮。</summary>
    private OverlayRect? Region(int x, int y, OverlayRgb background, Func<int, int, OverlayRgb> color)
    {
        var start = y * _width + x;
        if (_labels[start] > 0)
        {
            return _regions[_labels[start] - 1];
        }

        if (_remaining <= 0 || _regions.Count >= ushort.MaxValue)
        {
            return null;
        }

        var id = (ushort)(_regions.Count + 1);
        _regions.Add(null);
        _labels[start] = id;
        var queue = new List<int> { start };
        var cursor = 0;
        int minX = x, maxX = x, minY = y, maxY = y;
        while (cursor < queue.Count)
        {
            if (_remaining <= 0)
            {
                return null;
            }

            _remaining--;
            var index = queue[cursor];
            cursor++;
            var px = index % _width;
            var py = index / _width;
            if (px <= 0 || px >= _width - 1 || py <= 0 || py >= _height - 1)
            {
                return null;
            }

            minX = Math.Min(minX, px);
            maxX = Math.Max(maxX, px);
            minY = Math.Min(minY, py);
            maxY = Math.Max(maxY, py);
            for (var direction = 0; direction < 4; direction++)
            {
                var next = direction switch
                {
                    0 => index - 1,
                    1 => index + 1,
                    2 => index - _width,
                    _ => index + _width,
                };
                if (_labels[next] != 0 || color(next % _width, next / _width).Distance(background) >= SameBackground)
                {
                    continue;
                }

                _labels[next] = id;
                queue.Add(next);
            }
        }

        var rect = new OverlayRect(minX, minY, maxX - minX + 1, maxY - minY + 1);
        // 背景得占区域的大半：字母里的孔、复杂纹理不当容器
        if (queue.Count < rect.Width * rect.Height * 0.5)
        {
            return null;
        }

        _regions[id - 1] = rect;
        return rect;
    }
}
