// 长截图自动滚动的步子（纯函数配单测；2026-11-04 用户反馈「自动滚动太快」）。
// 以前每拍固定发一格滚轮（120）：一格滚多少像素各个程序不一样（浏览器约 100 DIP 再乘缩放、聊天窗口一格好几条、
// 系统设成「一次滚一屏」就是整屏），选区矮时一格就滚出了选区，两帧没有重叠，之后一直对不上、页面照滚、长图不长。
// 现在照 mac ScrollCapture.autoScroll 的做法（同类产品也是自己按画面控速，不让用户调「每次滚几格」）：
// 按上一步实际拼上的行数换算「一个滚轮单位滚几像素」，下一步只发够滚出选区高度一个比例的量（WHEEL_DELTA 的分数，
// 支持高精度滚轮的程序按比例滚）；比例就是设置 › 截图「自动滚动速度」的慢 / 标准 / 快（这一项 mac 没有，MAC-DIFF.md）。
// 滚过头（对不上）往回退半步、步子减半，连着 4 次对不上停下；不到一格的量画面没动（老程序攒满 120 才滚）就加倍到一格；
// 整格发了 3 次都没动 = 到头了。
namespace KittyTools.Core;

public enum ScrollSpeed
{
    Slow,
    Normal,
    Fast,
}

/// <summary>自动滚动一步之后画面怎样（同 mac ScrollStitcher.Outcome 去掉 full）。</summary>
public enum ScrollStep
{
    /// <summary>拼上了新的行。</summary>
    Moved,

    /// <summary>画面没动，或者只有光标闪、小动画这类小变化。</summary>
    Unchanged,

    /// <summary>对不上：滚得太多没有重叠。</summary>
    Lost,
}

public enum ScrollStopReason
{
    None,

    /// <summary>整格滚了几次画面都不动：滚到底（顶）了。</summary>
    End,

    /// <summary>退了几次还是对不上。</summary>
    Lost,
}

public sealed class ScrollPacer
{
    /// <summary>滚轮一格（WHEEL_DELTA）。</summary>
    public const int Notch = 120;

    public const int MinDelta = 12;

    public const int MaxDelta = Notch * 10;

    private const int StallLimit = 3;
    private const int LostLimit = 4;

    private int _last;
    private int _stalls;
    private int _lost;

    public ScrollPacer(int selectionHeight, ScrollSpeed speed)
    {
        Target = TargetShift(selectionHeight, speed);
    }

    /// <summary>每步想滚出多少像素。</summary>
    public double Target { get; }

    /// <summary>往前一步发多少滚轮单位（正数）。还没量过时半格；第一拍（还没发过）Next 直接给它。</summary>
    public int Delta { get; private set; } = Notch / 2;

    public ScrollStopReason Stopped { get; private set; }

    /// <summary>设置里存的字符串 → 速度（认不出的按标准）。</summary>
    public static ScrollSpeed Parse(string? value) => value switch
    {
        "slow" => ScrollSpeed.Slow,
        "fast" => ScrollSpeed.Fast,
        _ => ScrollSpeed.Normal,
    };

    /// <summary>每步滚出选区高度的多少（快 = mac 的 40%）。</summary>
    public static double Fraction(ScrollSpeed speed) => speed switch
    {
        ScrollSpeed.Slow => 0.12,
        ScrollSpeed.Fast => 0.4,
        _ => 0.25,
    };

    public static double TargetShift(int height, ScrollSpeed speed) => Math.Max(1, height * Fraction(speed));

    /// <summary>暂停后接着滚：停着的时候用户可能自己滚过，下一拍不拿暂停前那一步量、计数清零（步子留着）。</summary>
    public void Reset()
    {
        _stalls = 0;
        _lost = 0;
        _last = 0;
        Stopped = ScrollStopReason.None;
    }

    /// <summary>
    /// 上一步的结果 → 这一步发多少滚轮单位：正数往前、负数往回退，0 = 停下（原因看 Stopped）。
    /// shift：Moved 时这一拍拼上了几行（像素）。
    /// </summary>
    public int Next(ScrollStep step, int shift)
    {
        var last = _last;
        if (step == ScrollStep.Lost)
        {
            if (++_lost >= LostLimit)
            {
                return Stop(ScrollStopReason.Lost);
            }

            // 往回退半步：画面回到拼过的那一截和新位置之间，下一拍多半就对上了（mac 同样）。
            Delta = Math.Max(Delta / 2, MinDelta);
            return _last = -Delta;
        }

        if (step == ScrollStep.Moved && shift > 0)
        {
            _stalls = 0;
            _lost = 0;
            if (last > 0)
            {
                // 这一步 last 个单位滚了 shift 像素：下一步按比例发够 Target 像素的量。
                Delta = Math.Clamp((int)Math.Round(last * Target / shift), MinDelta, MaxDelta);
            }

            return _last = Delta;
        }

        // 画面没动。刚开始 / 刚往回退过：不算。
        if (last > 0 && last < Notch)
        {
            // 不到一格：有的程序攒满一格才滚，加倍（最多一格）再看。
            Delta = Math.Min(last * 2, Notch);
        }
        else if (last >= Notch && ++_stalls >= StallLimit)
        {
            return Stop(ScrollStopReason.End);
        }

        return _last = Delta;
    }

    /// <summary>和上一次拼上的那帧逐行一样（一样就不用拿去拼：整片纯色时随便哪个重叠都对得上，会凭空长出空白）。</summary>
    public static bool Same(uint[]? previous, uint[] current)
        => previous is not null && previous.AsSpan().SequenceEqual(current);

    /// <summary>
    /// 拼过之后这一拍算哪种：拼上了却没长算没动；对不上但变的行不到一成（光标闪、悬停高亮）也算没动。
    /// previous：上一次拼上的那帧每行的哈希（第一帧之前是 null）。
    /// </summary>
    public static ScrollStep Classify(uint[]? previous, uint[] current, bool appended, int grown)
    {
        if (appended)
        {
            return grown > 0 ? ScrollStep.Moved : ScrollStep.Unchanged;
        }

        if (previous is null || previous.Length != current.Length)
        {
            return ScrollStep.Lost;
        }

        var changed = 0;
        for (var row = 0; row < current.Length; row++)
        {
            if (previous[row] != current[row])
            {
                changed++;
            }
        }

        return changed < current.Length * 0.1 ? ScrollStep.Unchanged : ScrollStep.Lost;
    }

    private int Stop(ScrollStopReason reason)
    {
        Stopped = reason;
        _last = 0;
        return 0;
    }
}
