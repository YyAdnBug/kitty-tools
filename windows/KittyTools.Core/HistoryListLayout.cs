// 翻译历史列表的分组和几何（纯函数，配单测；照 mac HistoryView.sections / dayTitle / rowTime / Layout，PLAN-v9-translate 8d）：
// 条目新→旧，按 今天 / 昨天 / M月d日 / yyyy年M月d日 分组；分组标题 24、行 44，前缀和一次算好每一项的顶。
// 列表就按它摆，高亮、选中跟随滚动也从这里算，所以算出来的位置就是画出来的位置。
using System.Globalization;

namespace KittyTools.Core;

public sealed class HistoryListLayout
{
    public const double HeaderHeight = 24;
    public const double RowHeight = 44;

    /// <summary>列表底下的内缩（同结果区卡片堆底下的留白）；选中跟随滚动时上下都留这么多。</summary>
    public const double ScrollMargin = 12;

    private readonly double[] _rowTops;
    private readonly bool[] _firstInGroup;

    /// <param name="times">每条的本地时间（新→旧）。</param>
    public HistoryListLayout(IReadOnlyList<DateTime> times, DateTime now)
    {
        _rowTops = new double[times.Count];
        _firstInGroup = new bool[times.Count];
        var headers = new List<(string Title, double Top)>();
        var y = 0.0;
        DateTime? day = null;
        for (var index = 0; index < times.Count; index++)
        {
            var date = times[index].Date;
            if (day != date)
            {
                day = date;
                var title = DayTitle(times[index], now);
                // 同一个标题（时钟往回拨过这类）不再另起一组
                if (headers.Count == 0 || headers[^1].Title != title)
                {
                    headers.Add((title, y));
                    y += HeaderHeight;
                    _firstInGroup[index] = true;
                }
            }

            _rowTops[index] = y;
            y += RowHeight;
        }

        Headers = headers;
        TotalHeight = y;
    }

    public IReadOnlyList<(string Title, double Top)> Headers { get; }

    public double TotalHeight { get; }

    public int Count => _rowTops.Length;

    public double Top(int row) => row >= 0 && row < _rowTops.Length ? _rowTops[row] : TotalHeight;

    /// <summary>选中跟随滚动要露出来的区间：这一行；它是一组的第一条时连分组标题一起。</summary>
    public (double Top, double Bottom) Span(int row)
    {
        var top = Top(row);
        var header = row >= 0 && row < _firstInGroup.Length && _firstInGroup[row] ? HeaderHeight : 0;
        return (top - header, top + RowHeight);
    }

    /// <summary>要露出第 row 行时滚到哪（上下各留 ScrollMargin）；已经整个看得见就是 null。</summary>
    public double? Reveal(int row, double offset, double viewport)
    {
        if (row < 0 || row >= Count || viewport <= 0)
        {
            return null;
        }

        var (top, bottom) = Span(row);
        if (top - ScrollMargin < offset)
        {
            return Math.Max(0, top - ScrollMargin);
        }

        if (bottom + ScrollMargin > offset + viewport)
        {
            return bottom + ScrollMargin - viewport;
        }

        return null;
    }

    /// <summary>分组标题：今天 / 昨天 / 10月28日（今年）/ 2025年10月28日。</summary>
    public static string DayTitle(DateTime date, DateTime now)
    {
        if (date.Date == now.Date)
        {
            return "今天";
        }

        if (date.Date == now.Date.AddDays(-1))
        {
            return "昨天";
        }

        return date.Year == now.Year
            ? date.ToString("M月d日", CultureInfo.InvariantCulture)
            : date.ToString("yyyy年M月d日", CultureInfo.InvariantCulture);
    }

    /// <summary>行右侧的时间（分组已写日期，只写时:分，两位）。</summary>
    public static string RowTime(DateTime date) => date.ToString("HH:mm", CultureInfo.InvariantCulture);
}
