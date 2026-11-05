// 状态屏的纯逻辑（PLAN-v12 N5，照 mac StatusScreen/ExitHold.swift、Passcode.swift 和 StatusScreen.swift 里的静态函数），配单测：
// - ExitHold：退出判断。只按着 Esc（不带 Ctrl / Alt / Shift / Win、不是连发、此刻没有别的键按着）或左键按在退出提示上开始计时，
//   满 2 秒完成；计时中松开、或又来了别的触碰（别的键、修饰键、别的鼠标键）就取消，要松开重按——抹布一把抹过去、猫踩过去都不会退出。
//   滚动不取消。顺带数「触碰」：除了开始按住的那一下，其余按下（不算连发）各算一次，滚动每秒最多算一次。
// - Passcode：退出密码（4–8 位数字）。数字按键位认（扫描码：主键盘那一排和小键盘；不看输入法、键盘布局、NumLock 和 Shift——
//   键盘被拦着的时候换不了输入法，认字符的话布局一变就再也输不对），打满位数当场比；Backspace 删一位，Esc 取消；
//   同一个键 50 ms 内的第二次按下当成同一下；每错满 5 次收起，要重新按住两秒。
// - StatusScreenRules：小字、结束时的一句话、防残影、眼睛探头、字号、提示的位置。
// 时刻都是注入的毫秒（Environment.TickCount64）；坐标是物理像素、原点左上。
namespace KittyTools.Core;

public enum StatusInputKind
{
    KeyDown,
    KeyUp,
    LeftDown,
    LeftUp,

    /// <summary>别的鼠标键（右键、中键、侧键）按下。</summary>
    Touch,
    Scroll,
}

/// <summary>拦下来的一个输入（InputBlock 交给会话）。Key 是虚拟键码，Scan / Extended 是扫描码（密码按键位认）。</summary>
public readonly record struct StatusInput(
    StatusInputKind Kind, int Key = 0, int Scan = 0, bool Extended = false, bool IsRepeat = false, bool HasModifiers = false,
    int X = 0, int Y = 0);

public enum HoldSource
{
    Key,
    Mouse,
}

public sealed class ExitHold
{
    /// <summary>按住多久算数（毫秒；画面上的进度环也按它走满）。</summary>
    public const long DurationMs = 2000;

    public const long ScrollGapMs = 1000;

    /// <summary>
    /// 记着「按着」的键这么久没有新动静就不再算数：松开的那一下万一没收到（钩子被系统摘过），不能让一个「松不开」的键永远挡着 Esc。
    /// ponytail: 靠连发判断还按没按着——不连发的键（修饰键、关了按键重复时）按住超过 5 秒会被当成松开；要准就问 GetAsyncKeyState。
    /// </summary>
    public const long StaleAfterMs = 5000;

    public const int Escape = 0x1B;

    private readonly Dictionary<int, long> _keysDown = new();
    private bool _leftDown;
    private long? _lastScroll;

    /// <summary>正在按住：哪一种、从什么时候起。</summary>
    public (HoldSource Source, long Since)? Holding { get; private set; }

    /// <summary>来了一个事件，返回算不算一次触碰。hints：这时看得见的退出提示在各屏上的范围（没显示着就是空的）。</summary>
    public bool Handle(StatusInput input, long now, IReadOnlyList<PixelRect>? hints = null)
    {
        switch (input.Kind)
        {
            case StatusInputKind.KeyDown:
            {
                var others = _keysDown.Any(pair => pair.Key != input.Key && now - pair.Value < StaleAfterMs);
                _keysDown[input.Key] = now;
                if (input.IsRepeat)
                {
                    return false;
                }

                if (input.Key == Escape && !input.HasModifiers && !others)
                {
                    // 已经在按住 Esc 时又来一下：接着算，不重来、不取消。
                    if (Holding?.Source == HoldSource.Key)
                    {
                        return false;
                    }

                    if (Holding is null)
                    {
                        Holding = (HoldSource.Key, now);
                        return false;
                    }
                }

                Holding = null;
                return true;
            }

            case StatusInputKind.KeyUp:
                _keysDown.Remove(input.Key);
                if (input.Key == Escape && Holding?.Source == HoldSource.Key)
                {
                    Holding = null;
                }

                return false;
            case StatusInputKind.LeftDown:
                _leftDown = true;
                if (Holding is null && hints is not null && hints.Any(hint => Contains(hint, input.X, input.Y)))
                {
                    Holding = (HoldSource.Mouse, now);
                    return false;
                }

                Holding = null;
                return true;
            case StatusInputKind.LeftUp:
                _leftDown = false;
                if (Holding?.Source == HoldSource.Mouse)
                {
                    Holding = null;
                }

                return false;
            case StatusInputKind.Touch:
                Holding = null;
                return true;
            default:
                if (_lastScroll is { } last && now - last < ScrollGapMs)
                {
                    return false;
                }

                _lastScroll = now;
                return true;
        }
    }

    /// <summary>按住还差多久（null = 没在按住，≤ 0 = 满了）。</summary>
    public long? Remaining(long now) => Holding is { } holding ? DurationMs - (now - holding.Since) : null;

    public bool IsComplete(long now) => Remaining(now) is { } rest && rest <= 0;

    /// <summary>还有键 / 左键按着（退出之后拦截留到它们松开）。</summary>
    public bool IsAnythingDown(long now) => _leftDown || _keysDown.Values.Any(at => now - at < StaleAfterMs);

    /// <summary>只取消进行中的按住，按着的键照记（密码框开着时：按键归它，但退出后拦截还要等这些键松开）。</summary>
    public void Cancel() => Holding = null;

    /// <summary>取消进行中的按住、忘掉按着的键（锁屏：之后松开的那一下收不到）。</summary>
    public void Reset()
    {
        Holding = null;
        _keysDown.Clear();
        _leftDown = false;
    }

    private static bool Contains(PixelRect rect, int x, int y) => x >= rect.X && x < rect.Right && y >= rect.Y && y < rect.Bottom;
}

public enum PasscodeOutcome
{
    /// <summary>不归输入框管：别的键、鼠标、连发、松开。</summary>
    Ignored,

    /// <summary>打了一位、删了一位。</summary>
    Edited,

    /// <summary>打满了、不对：清空重来。</summary>
    Wrong,

    /// <summary>又错满 MaxMisses 次：该收起了。</summary>
    GaveUp,
    Matched,

    /// <summary>按了 Esc：不输了。</summary>
    Cancelled,
}

public sealed class Passcode
{
    public const int MinLength = 4;
    public const int MaxLength = 8;
    public const int MaxMisses = 5;

    /// <summary>输入框开着、这么久没按键就收起（毫秒）。</summary>
    public const long IdleMs = 10_000;

    /// <summary>同一个键隔得比这还近的两次按下当成同一下。</summary>
    public const long EchoMs = 50;

    /// <summary>凭据管理器里的条目名（Credentials 自己加前缀；不进设置文件、不跟导出备份走）。</summary>
    public const string Account = "statusScreenPasscode";

    private const int Backspace = 0x08;

    private readonly int[] _digits;
    private readonly List<int> _typed = new();
    private (int Key, long At)? _last;

    private Passcode(int[] digits, int typed, int misses)
    {
        _digits = digits;
        _typed.AddRange(digits.Take(typed));
        Misses = misses;
        Missed = misses > 0 && typed == 0;
    }

    public int Length => _digits.Length;

    public int Typed => _typed.Count;

    /// <summary>这次会话一共错了几次：只增不减（画面的圆点每变一次晃一下）。</summary>
    public int Misses { get; private set; }

    /// <summary>刚输错、还没接着打：提示写「密码不对」。</summary>
    public bool Missed { get; private set; }

    /// <summary>存着的 / 设置里填的文字 → 密码；不是 4–8 位 ASCII 数字就是 null。typed、misses 是截图自检摆样子用的。</summary>
    public static Passcode? Parse(string? text, int typed = 0, int misses = 0)
    {
        if (text is null || text.Length < MinLength || text.Length > MaxLength || !text.All(c => c is >= '0' and <= '9'))
        {
            return null;
        }

        return new Passcode(text.Select(c => c - '0').ToArray(), Math.Clamp(typed, 0, text.Length), Math.Max(0, misses));
    }

    /// <summary>设置里填的两遍有什么问题（null = 可以存）。</summary>
    public static string? Problem(string text, string confirmation)
    {
        if (Parse(text) is null)
        {
            return $"密码是 {MinLength}–{MaxLength} 位数字";
        }

        return text == confirmation ? null : "再输一次，两次要一样";
    }

    /// <summary>扫描码 → 数字：主键盘那一排（不看布局）和小键盘（不看 NumLock；带扩展标志的是方向键这些，不算）。</summary>
    public static int? Digit(int scan, bool extended)
    {
        if (scan is >= 0x02 and <= 0x0B)
        {
            return scan == 0x0B ? 0 : scan - 1;
        }

        if (extended)
        {
            return null;
        }

        return scan switch
        {
            0x52 => 0,
            0x4F => 1,
            0x50 => 2,
            0x51 => 3,
            0x4B => 4,
            0x4C => 5,
            0x4D => 6,
            0x47 => 7,
            0x48 => 8,
            0x49 => 9,
            _ => null,
        };
    }

    /// <summary>输入框打开：从头输。</summary>
    public void Begin()
    {
        _typed.Clear();
        Missed = false;
        _last = null;
    }

    /// <summary>输入框开着时来了一个事件。数字带不带 Shift 都认（有的键盘布局数字要按着 Shift 打）。</summary>
    public PasscodeOutcome Handle(StatusInput input, long now)
    {
        if (input.Kind != StatusInputKind.KeyDown || input.IsRepeat)
        {
            return PasscodeOutcome.Ignored;
        }

        if (_last is { } last && last.Key == input.Key && now - last.At < EchoMs)
        {
            return PasscodeOutcome.Ignored;
        }

        _last = (input.Key, now);
        if (input.Key == ExitHold.Escape)
        {
            return input.HasModifiers ? PasscodeOutcome.Ignored : PasscodeOutcome.Cancelled;
        }

        if (input.Key == Backspace)
        {
            if (_typed.Count == 0)
            {
                return PasscodeOutcome.Ignored;
            }

            _typed.RemoveAt(_typed.Count - 1);
            return PasscodeOutcome.Edited;
        }

        if (Digit(input.Scan, input.Extended) is not { } digit)
        {
            return PasscodeOutcome.Ignored;
        }

        _typed.Add(digit);
        Missed = false;
        if (_typed.Count < _digits.Length)
        {
            return PasscodeOutcome.Edited;
        }

        if (_typed.SequenceEqual(_digits))
        {
            return PasscodeOutcome.Matched;
        }

        _typed.Clear();
        Misses++;
        Missed = true;
        return Misses % MaxMisses == 0 ? PasscodeOutcome.GaveUp : PasscodeOutcome.Wrong;
    }
}

public enum StatusExitReason
{
    Held,
    AutoEnd,
    Unlocked,
    Quit,
}

public enum PeekEdge
{
    Top,
    Bottom,
    Left,
    Right,
}

/// <summary>眼睛从哪儿探出来：屏幕的哪条边、沿着边的哪儿（0–1：上下两条边从左往右，左右两条边从上往下；0 和 1 贴着角）。</summary>
public readonly record struct Peek(PeekEdge Edge, double Along);

public static class StatusScreenRules
{
    /// <summary>退出提示浮出来留多久（毫秒）。</summary>
    public const long HintDwellMs = 3000;

    /// <summary>鼠标一阵里累计挪过这么远（DIP）就浮出退出提示。</summary>
    public const double MouseTravelDip = 40;

    /// <summary>退出之后拦截最多再留多久（毫秒）。</summary>
    public const long LingerLimitMs = 2000;

    /// <summary>退出提示胶囊的大小、离屏幕底边多远（DIP）；鼠标按住的命中按它外扩 8。</summary>
    public const double HintWidth = 148;

    public const double HintHeight = 40;
    public const double HintBottom = 56;
    public const double HintSlop = 8;

    /// <summary>眼睛那张图露出屏幕边几成。</summary>
    public const double EyesShown = 0.8;

    /// <summary>没人碰时眼睛隔多久自己冒一次（毫秒，每次在这个范围里随机）。</summary>
    public const int PeekGapMinMs = 15_000;

    public const int PeekGapMaxMs = 45_000;

    /// <summary>上下两条边正中有东西时让开的那一段（沿边的比例）：底边正中是退出提示。</summary>
    public const double PeekMiddleLow = 0.35;

    public const double PeekMiddleHigh = 0.65;

    /// <summary>时长：「不到 1 分钟」「5 分钟」「1 小时」「1 小时 23 分」。</summary>
    public static string Span(int seconds)
    {
        var minutes = seconds / 60;
        if (minutes < 1)
        {
            return "不到 1 分钟";
        }

        if (minutes < 60)
        {
            return $"{minutes} 分钟";
        }

        return minutes % 60 == 0 ? $"{minutes / 60} 小时" : $"{minutes / 60} 小时 {minutes % 60} 分";
    }

    /// <summary>小字里的时长，精确到秒：「5 秒」「3 分 05 秒」「1 小时 23 分 05 秒」（前面有更大的单位时补成两位，宽度不跳）。</summary>
    public static string Clock(int seconds)
    {
        seconds = Math.Max(0, seconds);
        var (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60);
        if (hours > 0)
        {
            return $"{hours} 小时 {minutes:00} 分 {rest:00} 秒";
        }

        return minutes > 0 ? $"{minutes} 分 {rest:00} 秒" : $"{rest} 秒";
    }

    /// <summary>小字里每秒在变的那个数：定了自动结束的是还剩几秒（倒数），没定的是已经过了几秒。</summary>
    public static int Reading(int elapsed, int autoEndMinutes)
        => autoEndMinutes > 0 ? Math.Max(0, autoEndMinutes * 60 - elapsed) : elapsed;

    /// <summary>画面上那行小字：「14:02 开始 · 已 1 小时 23 分 05 秒」；定了自动结束的倒数：「14:02 开始 · 还剩 4 分 32 秒」。</summary>
    public static string Footer(string started, int seconds, int autoEndMinutes = 0)
        => $"{started} 开始 · {(autoEndMinutes > 0 ? "还剩" : "已")} {Clock(Reading(seconds, autoEndMinutes))}";

    /// <summary>怎么退出的一句话（进入时的播报、整屏的读屏名字）。</summary>
    public static string ExitWording(bool passcode) => passcode ? "按住 Esc 两秒，再输入密码退出" : "按住 Esc 两秒退出";

    /// <summary>结束时提示的详情：「持续 1 小时 23 分 · 挡下 12 次触碰」；自动结束的写「到 5 分钟自动结束」；没有触碰就不写后半句。</summary>
    public static string Summary(StatusExitReason reason, int seconds, int touches, int autoEndMinutes)
    {
        var lasted = reason == StatusExitReason.AutoEnd
            ? $"到 {Span(autoEndMinutes * 60)}自动结束"
            : "持续" + (seconds < 60 ? string.Empty : " ") + Span(seconds);
        return touches > 0 ? $"{lasted} · 挡下 {touches} 次触碰" : lasted;
    }

    /// <summary>
    /// 防残影：第几分钟 → 告示那一列挪开多少（DIP）。「屏幕常亮」的状态一挂就是几小时：每分钟挪几个点，横向 ±12、纵向 ±8 以内，
    /// 两个方向周期不一样；第 0 分钟在正中（同 mac 的 offset，Y 向下）。
    /// </summary>
    public static (double X, double Y) Drift(int minute)
        => (Math.Round(12 * Math.Sin(minute * 0.9), MidpointRounding.AwayFromZero),
            Math.Round(8 * Math.Sin(minute * 0.55), MidpointRounding.AwayFromZero));

    /// <summary>标题字号（DIP）：屏高 × 0.075，夹在 44–96。</summary>
    public static double TitleSize(double screenHeightDip) => Math.Clamp(screenHeightDip * 0.075, 44, 96);

    /// <summary>告示上的表情有多大：边长 = 标题字号 × 1.3。</summary>
    public static double EmojiSide(double title) => title * 1.3;

    /// <summary>退出提示在一块屏上的范围（物理像素）：底部居中，离底边 56 DIP。</summary>
    public static PixelRect HintRect(PixelRect screen, double scale, double widthDip = HintWidth)
    {
        var width = MonitorLayout.Pixels(widthDip, scale);
        var height = MonitorLayout.Pixels(HintHeight, scale);
        return new PixelRect(
            screen.X + (screen.Width - width) / 2, screen.Bottom - MonitorLayout.Pixels(HintBottom, scale) - height, width, height);
    }

    /// <summary>鼠标按住退出提示的命中范围：提示外扩 8 DIP。</summary>
    public static PixelRect HintHitRect(PixelRect screen, double scale)
    {
        var hint = HintRect(screen, scale);
        var slop = MonitorLayout.Pixels(HintSlop, scale);
        return new PixelRect(hint.X - slop, hint.Y - slop, hint.Width + 2 * slop, hint.Height + 2 * slop);
    }

    /// <summary>
    /// 眼睛探出来之后在一块屏上的左上角（DIP，屏幕左上为原点）：贴着那条边，两成在屏幕外；沿着边从这个角到那个角，整只都在这条边上。
    /// side：眼睛的边长（= 那块屏的标题字号）。
    /// </summary>
    public static (double X, double Y) EyesOrigin(double width, double height, double side, Peek peek)
    {
        var outside = side - side * EyesShown;
        var x = (width - side) * peek.Along;
        var y = (height - side) * peek.Along;
        return peek.Edge switch
        {
            PeekEdge.Bottom => (x, height - side + outside),
            PeekEdge.Top => (x, -outside),
            PeekEdge.Left => (-outside, y),
            _ => (width - side + outside, y),
        };
    }

    /// <summary>图要转多少度：图的下边朝着那条边（从底边探出来是原样，从顶边是倒着的）。</summary>
    public static double EyesDegrees(PeekEdge edge) => edge switch
    {
        PeekEdge.Bottom => 0,
        PeekEdge.Left => 90,
        PeekEdge.Top => 180,
        _ => -90,
    };

    /// <summary>往屏幕外挪 distance 是多少（缩回去时整个挪出那条边；Y 向下）。</summary>
    public static (double X, double Y) Outward(PeekEdge edge, double distance) => edge switch
    {
        PeekEdge.Top => (0, -distance),
        PeekEdge.Bottom => (0, distance),
        PeekEdge.Left => (-distance, 0),
        _ => (distance, 0),
    };

    /// <summary>
    /// 随机挑一处探头（随机数传进来）：四条边里挑一条，不连着两次同一条；沿着边整条都可能。底边正中这会儿是退出提示
    /// （clearOfHint）时让开正中那一段、挪到两边去。Windows 没有刘海，顶边不用让。
    /// </summary>
    public static Peek RandomPeek(PeekEdge? last, bool clearOfHint, Random random)
    {
        var edges = Enum.GetValues<PeekEdge>().Where(edge => edge != last).ToArray();
        var edge = edges[random.Next(edges.Length)];
        var along = random.NextDouble();
        if (edge == PeekEdge.Bottom && clearOfHint && along >= PeekMiddleLow && along <= PeekMiddleHigh)
        {
            // 正中那一段对半挪到左右两头，仍然是均匀的。
            var width = PeekMiddleHigh - PeekMiddleLow;
            along += along < 0.5 ? -width : width;
        }

        return new Peek(edge, along);
    }

    /// <summary>告示上的动画现在做不做：设置里的总开关开着，而且系统没关动画效果。</summary>
    public static bool Animates(bool enabled, bool reduceMotion) => enabled && !reduceMotion;

    /// <summary>冒不冒眼睛：动画做着才冒；熄屏要保持纯黑；透出不冒（Windows 的透出画在不透明的小窗里，眼睛没法透出后面的窗口）。</summary>
    public static bool Peeks(string style, bool animates) => animates && style == StatusPresets.Sign;

    /// <summary>进入时要加载哪些表情的帧：这个状态自己的（选了才有、熄屏不要）和眼睛（冒眼睛时）；动画不做时一个都不加载。</summary>
    public static IReadOnlyList<string> EmojiToLoad(StatusPreset preset, bool animates)
    {
        if (!animates || preset.Style == StatusPresets.Blackout)
        {
            return Array.Empty<string>();
        }

        var ids = new List<string>();
        if (preset.Symbol.Length > 0)
        {
            ids.Add(preset.Symbol);
        }

        if (Peeks(preset.Style, animates))
        {
            ids.Add(StatusEmojiCatalog.Eyes);
        }

        return ids;
    }

    /// <summary>选状态的面板 / 快捷键：下一张（转一圈回到第一张）。</summary>
    public static int NextIndex(int current, int count) => count <= 0 ? 0 : (current + 1) % count;

    /// <summary>选状态的面板默认选中哪张：上次进入的那个，找不到就第一张。</summary>
    public static int DefaultIndex(IReadOnlyList<StatusPreset> presets, string? lastId)
        => Math.Max(0, presets.ToList().FindIndex(preset => preset.Id == lastId));
}

/// <summary>
/// 告示出场的时间表（PLAN-v12 第 7 批，照 mac StatusEntrance；时刻 = 画面出现后过了几秒）：标题从 TitleStart 起逐字浮现，
/// 字与字错开 Step、每个字走 GlyphSpan（三次方缓出）；说明和小字等最后一个字浮到一半时淡入（RestSpan）。
/// </summary>
public readonly record struct StatusEntrance(int Glyphs)
{
    public const double TitleStart = 0.06;
    public const double GlyphSpan = 0.28;
    public const double Stagger = 0.045;
    public const double StaggerLimit = 0.9;
    public const double RestSpan = 0.28;

    /// <summary>字与字错开多少；标题长的时候压到整个标题在 StaggerLimit 秒内都开始浮现。</summary>
    public double Step => Glyphs > 1 ? Math.Min(Stagger, StaggerLimit / (Glyphs - 1)) : 0;

    /// <summary>说明和小字从什么时候开始淡入：最后一个字浮到一半。</summary>
    public double RestStart => TitleStart + Step * Math.Max(Glyphs - 1, 0) + GlyphSpan / 2;

    /// <summary>整个出场多久。</summary>
    public double End => RestStart + RestSpan;

    /// <summary>第 index 个字浮现到哪了（0–1，先快后慢）。</summary>
    public double Glyph(int index, double time)
    {
        var start = TitleStart + Step * Math.Min(index, Math.Max(Glyphs - 1, 0));
        return Eased((time - start) / GlyphSpan);
    }

    private static double Eased(double value) => 1 - Math.Pow(1 - Math.Clamp(value, 0, 1), 3);
}
