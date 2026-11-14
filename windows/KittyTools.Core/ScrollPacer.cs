// 长截图自动滚动的速度和校准（纯函数配单测；照 mac ScrollCapture 389289d4：跟着屏幕刷新匀速顺滑地滚）。
// 2026-11-04 用户反馈太快、11-05 嫌「一顿一顿」：现在屏幕每刷新一帧（CompositionTarget.Rendering）发一小段滚轮（Frame），
// 速度是面板上的「慢 / 标准 / 快」= 每秒滚出 0.3 / 0.6 / 1.2 个选区高；抓帧照旧一帧接一帧（自动滚动时 160 ms），每帧拼完
// 把「这段时间发了多少滚轮」和「画面实际滚了几像素」对账（After），校准一个滚轮单位滚几像素（Gain）。
// 对不上（滚过头）退回自上次接上以来发的一半、先放慢一半，连着 4 帧对不上停下；发了滚轮画面却连着 3 帧不动 = 到头了。
// Windows 和 mac 不一样的两处：
// - 单位是滚轮单位（WHEEL_DELTA 120 = 一格），不是像素：一格滚多远各程序不一样，支持高精度滚轮的按比例滚，老程序攒满一格才滚。
//   所以算「到头」时还要自上次接上以来发满一格（不然老程序攒着那几十个单位会被当成到头）。
// 封顶（mac 176ad8b1，PLAN-v18 S1）：匀速滚动不等拼接，两帧之间滚多远 = 速度 × 抓帧、算帧、拼接的时间，后者跟着选区面积涨；
// 选区大了两帧之间滚过一整屏，对不上 → 退回、放慢 → 接上又全速再滚过头，反反复复。所以比上次接上的那一帧最多领先半个选区高
// （MaxLead），到顶就停发，下一帧接上了再接着滚；到顶时一帧可能一点没发，自上次接上以来发过、画面没动照样算到头。
// 「半个选区高」里的高是**在动的那一块**的高（Band，PLAN-v20 W1，mac PR #20）：选区里只嵌着一块小滚动区时能接上的位移只和它有关；
// 对不上时退回自上次接上以来发的一半，领先得比这块还多时退到这块的一半以内（只退一半还是接不上）。还没量出来时就是选区高。
// - 不翻滚轮正负号（mac 的 wheelSign）：SendInput 的滚轮方向是定的，没有「自然滚动」对合成事件怎么处理的问题；
//   Windows 的拼接按方向接（ScrollCanvas.Append），反方向滚只会对不上，走退回那一路。
namespace KittyTools.Core;

public enum ScrollSpeed
{
    Slow,
    Normal,
    Fast,
}

/// <summary>抓到的这一帧拼完后画面怎样（同 mac ScrollStitcher.Outcome 去掉 full）。</summary>
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

    /// <summary>发了滚轮画面却连着几帧不动：滚到底（顶）了。</summary>
    End,

    /// <summary>连着几帧对不上。</summary>
    Lost,
}

public sealed class ScrollPacer
{
    /// <summary>滚轮一格（WHEEL_DELTA）。</summary>
    public const int Notch = 120;

    /// <summary>比上次接上的那一帧开抓时最多领先「在动的那一块」高的几倍（同 mac ScrollCapture.maxLead）。</summary>
    public const double MaxLead = 0.5;

    private const int StallLimit = 3;
    private const int LostLimit = 4;

    /// <summary>发得比这少的那一段不拿来校准（滚轮发出去到画面画出来有延迟，太短的段不准）。</summary>
    private const double MinCalibrationUnits = Notch / 10.0;

    private readonly int _height;
    private readonly double _scale;
    private double _carry;
    private int _stalls;
    private int _lost;

    /// <param name="height">选区高（物理像素）。</param>
    /// <param name="scale">选区所在那块屏的缩放（1.0 = 100%）：开头按它猜一个滚轮单位滚几像素。</param>
    public ScrollPacer(int height, double scale, ScrollSpeed speed)
    {
        _height = Math.Max(1, height);
        _scale = scale <= 0 ? 1 : scale;
        _band = _height;
        // 开头按「一格约 100 DIP」猜（浏览器、大多数新程序）；之后按实测校准。
        Gain = InitialGain(_scale);
        Speed = speed;
        Velocity = VelocityFor(speed, _height, Gain);
    }

    public ScrollSpeed Speed { get; private set; }

    /// <summary>选区里在动的那一块有多高（像素，ScrollBand.MovingRows）：领先上限按它算；没量出来（0）、比选区高时按选区高。</summary>
    public int Band
    {
        get => _band;
        set => _band = value <= 0 ? _height : Math.Min(value, _height);
    }

    private int _band;

    /// <summary>发出去 1 个滚轮单位，画面实际滚几像素（校准过的）。</summary>
    public double Gain { get; private set; }

    /// <summary>现在每秒发多少滚轮单位（沿滚动方向）。</summary>
    public double Velocity { get; private set; }

    /// <summary>这一轮一共发了多少单位（沿方向为正、往回退为负，只增减不清零）；和下面三个时刻的值相减就是两帧之间发了多少。</summary>
    public double Posted { get; private set; }

    /// <summary>这一帧、上一帧开抓时 Posted 是多少；长图上一次接上的那一帧（拼接的参照帧）开抓时是多少。</summary>
    public double PostedAtCapture { get; private set; }

    public double PostedAtPreviousCapture { get; private set; }

    public double PostedAtReference { get; private set; }

    public ScrollStopReason Stopped { get; private set; }

    /// <summary>设置里存的字符串 → 速度（认不出的按标准）。</summary>
    public static ScrollSpeed Parse(string? value) => value switch
    {
        "slow" => ScrollSpeed.Slow,
        "fast" => ScrollSpeed.Fast,
        _ => ScrollSpeed.Normal,
    };

    public static string Name(ScrollSpeed speed) => speed switch
    {
        ScrollSpeed.Slow => "slow",
        ScrollSpeed.Fast => "fast",
        _ => "normal",
    };

    /// <summary>
    /// 手动滚时下一帧隔多久抓（毫秒；PLAN-v18 S2，同 mac ScrollCapture.interval + c7756c75）：画面在动（上一帧拼上了或对不上，quietFrames = 0）
    /// 拼完立刻抓，不睡——两帧之间滚了多远 = 手的速度 × 一轮的时间，原来固定 600 ms，一甩就滚过一整屏；静止 40 ms；连着 5 帧静止（停着看、
    /// 去拿鼠标）放宽到 200 ms，一有变化就回到不睡。
    /// </summary>
    public static int ManualDelayMs(int quietFrames) => quietFrames <= 0 ? 0 : quietFrames >= 5 ? 200 : 40;

    /// <summary>手动滚对不上时状态行的话（同 mac）。</summary>
    public const string LostText = "对不上了：往回滚一点，再慢慢滚";

    /// <summary>每秒滚出几个选区高（同 mac Prefs.ScrollSpeed.heightsPerSecond）。</summary>
    public static double HeightsPerSecond(ScrollSpeed speed) => speed switch
    {
        ScrollSpeed.Slow => 0.3,
        ScrollSpeed.Fast => 1.2,
        _ => 0.6,
    };

    /// <summary>开头猜的倍率：一格约 100 DIP。</summary>
    public static double InitialGain(double scale) => 100.0 * (scale <= 0 ? 1 : scale) / Notch;

    /// <summary>每秒发多少单位：每秒要滚出 speed 个选区高（像素）除以倍率；最少每秒 10 个单位，最多每秒 30 格。</summary>
    public static double VelocityFor(ScrollSpeed speed, int height, double gain)
        => Math.Clamp(HeightsPerSecond(speed) * height / Math.Max(gain, 0.001), 10, Notch * 30);

    /// <summary>
    /// 按这一段实测校准倍率：发了 sent 个单位、画面滚了 shift 像素。发得太少、画面没往前走都不算；新旧各取一半
    /// （滚轮发出去到画面画出来有延迟，单看一段会偏），夹在开头猜的 1/20 到 20 倍之间（一格几像素到「一次滚一屏」）。
    /// </summary>
    public static double Calibrated(double gain, double shift, double sent, double scale)
    {
        if (sent < MinCalibrationUnits || shift <= 0)
        {
            return gain;
        }

        var guess = InitialGain(scale);
        return Math.Clamp((gain + shift / sent) / 2, guess / 20, guess * 20);
    }

    /// <summary>
    /// 这一帧发几个单位：速度 × 这一帧的时长再加上次的零头，发整数，零头留到下一帧；一帧最多按 50 ms 算（卡了一下不猛冲一大段）；
    /// 最多发 room 个（领先到顶了：发不完的扔掉，零头清零）。
    /// </summary>
    public static (int Units, double Carry) FrameUnits(double velocity, double seconds, double carry, double room = double.PositiveInfinity)
    {
        var amount = velocity * Math.Clamp(seconds, 0, 0.05) + carry;
        var whole = Math.Truncate(amount);
        var allowed = Math.Truncate(Math.Max(room, 0));
        if (whole > allowed)
        {
            return ((int)allowed, 0);
        }

        return ((int)whole, amount - whole);
    }

    /// <summary>
    /// 还能再发几个单位：lead 是自上次接上的那一帧开抓以来发了多少（退回过可以是负数），换算成像素不超过 MaxLead 个 band 高
    /// （band = 在动的那一块的高，没量出来时是选区高）。
    /// </summary>
    public static double Room(double lead, int band, double gain) => Math.Max(MaxLead * band / Math.Max(gain, 0.001) - lead, 0);

    /// <summary>
    /// 对不上时往回退几个单位（同 mac 的 .lost）：自上次接上以来发的一半；领先得比在动那块还多时（块是后来才量出来的）
    /// 退到这块的一半以内。
    /// </summary>
    public static int BackOff(double lead, int band, double gain)
        => (int)Math.Round(Math.Max(lead / 2, lead - Room(0, band, gain) / 2));

    /// <summary>开始 / 暂停后接着滚：清计数和零头；停着时没发过滚轮，参照帧开抓时就是现在这个数。</summary>
    public void Begin()
    {
        _stalls = 0;
        _lost = 0;
        _carry = 0;
        PostedAtReference = Posted;
        Stopped = ScrollStopReason.None;
        Velocity = VelocityFor(Speed, _height, Gain);
    }

    /// <summary>面板上换了速度：下一帧就按新的速度发。</summary>
    public void SetSpeed(ScrollSpeed speed)
    {
        Speed = speed;
        Velocity = VelocityFor(speed, _height, Gain);
    }

    /// <summary>屏幕刷新了一帧（离上一帧 seconds 秒）：这一帧要发几个单位（0 = 这一帧不发），已经记进 Posted。</summary>
    public int Frame(double seconds)
    {
        var (units, carry) = FrameUnits(Velocity, seconds, _carry, Room(Posted - PostedAtReference, _band, Gain));
        _carry = carry;
        Posted += units;
        return units;
    }

    /// <summary>开抓这一帧之前调：记下这时一共发了多少（拼完 After 拿它对账）。</summary>
    public void Captured()
    {
        PostedAtPreviousCapture = PostedAtCapture;
        PostedAtCapture = Posted;
    }

    /// <summary>
    /// 这一帧拼完：校准、判断要不要退回或停下。shift：Moved 时这一帧拼上了几行（像素）。
    /// 返回要往回退几个单位（正数，0 = 不退，已经记进 Posted）；Stopped 不是 None 就是该停了。
    /// </summary>
    public int After(ScrollStep step, int shift)
    {
        // 自上次接上以来发了多少。
        var sent = PostedAtCapture - PostedAtReference;
        switch (step)
        {
            case ScrollStep.Moved:
                PostedAtReference = PostedAtCapture;
                _stalls = 0;
                _lost = 0;
                Gain = Calibrated(Gain, shift, sent, _scale);
                Velocity = VelocityFor(Speed, _height, Gain);
                return 0;
            case ScrollStep.Lost:
                if (++_lost >= LostLimit)
                {
                    Stopped = ScrollStopReason.Lost;
                    return 0;
                }

                var back = BackOff(Posted - PostedAtReference, _band, Gain);
                Velocity /= 2;
                if (back <= 0)
                {
                    return 0;
                }

                Posted -= back;
                return back;
            default:
                // 自上次接上以来没发满一格不算（刚开始；老程序攒满一格才滚）。这一帧没发也算：领先到顶时一帧一点没发、画面也没动，
                // 就是到头了（S1）。光标停在面板上时根本不调 After（ScrollingCapture）。
                if (sent < Notch)
                {
                    return 0;
                }

                if (++_stalls >= StallLimit)
                {
                    Stopped = ScrollStopReason.End;
                }

                return 0;
        }
    }

    /// <summary>和上一次拼上的那帧逐行一样（一样就不用拿去拼：整片纯色时随便哪个重叠都对得上，会凭空长出空白）。</summary>
    public static bool Same(uint[]? previous, uint[] current)
        => previous is not null && previous.AsSpan().SequenceEqual(current);

    /// <summary>
    /// 拼过之后这一帧算哪种：拼上了却没长算没动；对不上但变的行不到一成（光标闪、悬停高亮）也算没动。
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
}
