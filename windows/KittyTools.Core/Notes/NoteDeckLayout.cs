// 屏幕边缘那叠（PLAN-v13 第 6 批要用的纯函数；照 mac Notes/NoteDeckOptions.swift、NoteDeckLayout.swift、NoteDeckState.swift，
// 和 NoteDeck.swift 里的 effects）：
// - NoteDeckOptions：设置 › 便签「屏幕边缘」的选项、默认值、设置里的键名、读设置时把怪值按默认算；
// - NoteDeckMetrics：药丸和标签的各个尺寸，按大小档（0.85 / 1 / 1.25）一起缩放、取整到整点（叠着的标签不出缝）；
// - NoteDeckLayout：一列标签怎么排（每张露出多长、要不要压短、「+N」、放不下时在视口里滚），药丸多高、放哪块屏哪条边
//   （两块屏相接的那条边不放）、药丸 / 那叠 / 打开的便签摆在哪、拖药丸落在哪、拖动排序落在第几格、热区；
// - NoteDeckLabel：竖排的标题——哪些字正着放、怎么分段、太长怎么截（每段多长由窗口代码量好传进来）；
// - NoteDeckState：静置 / 扇出 / 打开的状态机，和状态变了该做哪几件事（Effects）。
// **坐标（和 mac 不一样）**：Windows 的屏幕坐标原点在左上、y 向下（mac 是左下、y 向上），这里的函数一律按 y 向下写。
// 屏幕给的是那块屏的整块（Frame）和**工作区**（WorkArea：去掉任务栏的矩形，相当于 mac 的 visibleFrame），由调用方传进来，
// 单位由调用方定（全局 DIP 或全局像素，一套里别混）。「离面板顶多远」这类距离（ColumnTop、NoteTop、TabCenter）mac 也是从顶往下量的，
// 数值和 mac 一样。竖直方向上的绝对位置取整时 .5 往上取（y 小的那边）：mac 在 y 向上的坐标里 .5 往上取，是同一个位置。
using System.Globalization;
using System.Text;

namespace KittyTools.Core.Notes;

// ---- 设置 ----

public enum NoteDeckEdge
{
    Right,
    Left,
}

/// <summary>设置里存的「显示器」那一项：主显示器 / 所有 / 指定的那一块（是哪块在另一个键里，这台电脑自己的状态）。</summary>
public enum NoteDeckDisplayMode
{
    Main,
    All,
    Chosen,
}

/// <summary>标签的样式：带标题的标签（默认）/ 只有色块。</summary>
public enum NoteDeckTabStyle
{
    Tabs,
    Chips,
}

public enum NoteDeckSize
{
    Small,
    Standard,
    Large,
}

/// <summary>打开的便签多大（连它带着的那张标签一起算）。</summary>
public enum NoteDeckNoteSize
{
    Small,
    Medium,
    Large,
    ExtraLarge,
}

/// <summary>放在哪块显示器：主显示器 / 所有 / 指定的那一块（按名字认，它不在时退回主显示器）。</summary>
public readonly record struct NoteDeckDisplay(NoteDeckDisplayMode Mode, string? Name = null)
{
    public static NoteDeckDisplay Main => new(NoteDeckDisplayMode.Main);

    public static NoteDeckDisplay All => new(NoteDeckDisplayMode.All);

    public static NoteDeckDisplay Named(string name) => new(NoteDeckDisplayMode.Chosen, name);
}

/// <summary>几个枚举在设置里存的字（和 mac 的 rawValue 一样）、界面上的叫法、对应的数。</summary>
public static class NoteDeckEnums
{
    public static NoteDeckEdge Opposite(this NoteDeckEdge edge) => edge == NoteDeckEdge.Right ? NoteDeckEdge.Left : NoteDeckEdge.Right;

    /// <summary>界面上的叫法（「便签在屏幕右边缘」）。</summary>
    public static string Title(this NoteDeckEdge edge) => edge == NoteDeckEdge.Right ? "右" : "左";

    public static double Scale(this NoteDeckSize size) => size switch
    {
        NoteDeckSize.Small => 0.85,
        NoteDeckSize.Large => 1.25,
        _ => 1,
    };

    public static (double Width, double Height) Dimensions(this NoteDeckNoteSize size) => size switch
    {
        NoteDeckNoteSize.Small => (400, 320),
        NoteDeckNoteSize.Large => (560, 470),
        NoteDeckNoteSize.ExtraLarge => (680, 560),
        _ => (460, 380),
    };

    public static string Raw(this NoteDeckEdge edge) => edge == NoteDeckEdge.Right ? "right" : "left";

    public static string Raw(this NoteDeckDisplayMode mode) => mode switch
    {
        NoteDeckDisplayMode.All => "all",
        NoteDeckDisplayMode.Chosen => "chosen",
        _ => "main",
    };

    public static string Raw(this NoteDeckTabStyle style) => style == NoteDeckTabStyle.Chips ? "chips" : "tabs";

    public static string Raw(this NoteDeckSize size) => size switch
    {
        NoteDeckSize.Small => "small",
        NoteDeckSize.Large => "large",
        _ => "standard",
    };

    public static string Raw(this NoteDeckNoteSize size) => size switch
    {
        NoteDeckNoteSize.Small => "small",
        NoteDeckNoteSize.Large => "large",
        NoteDeckNoteSize.ExtraLarge => "extraLarge",
        _ => "medium",
    };
}

/// <summary>设置 › 便签「屏幕边缘」：读一次设置、之后都传值。默认值照 mac。</summary>
public sealed record NoteDeckOptions
{
    /// <summary>设置里的键名（和 mac 的偏好键同名）。前 12 个是设置（跟着设置的导出走）；Position、ChosenDisplay、HintShown 是这台电脑
    /// 自己的状态（不导出）。</summary>
    public static class Keys
    {
        public const string Enabled = "notesDeckEnabled";
        public const string Edge = "notesDeckEdge";
        public const string Display = "notesDeckDisplay";
        public const string Style = "notesDeckStyle";
        public const string Size = "notesDeckSize";
        public const string Sense = "notesDeckSense";
        public const string AlwaysFanned = "notesDeckAlwaysFanned";
        public const string HidesPill = "notesDeckHidesPill";
        public const string Preview = "notesDeckPreview";
        public const string OpensOnHover = "notesDeckOpensOnHover";
        public const string OverFullScreen = "notesDeckOverFullScreen";
        public const string NoteSize = "notesDeckNoteSize";
        public const string Position = "notesDeckPosition";
        public const string ChosenDisplay = "notesDeckChosenDisplay";
        public const string HintShown = "notesDeckHintShown";
    }

    /// <summary>感应范围的档位：窄 / 标准 / 宽 / 很宽。</summary>
    public static readonly int[] SenseChoices = { 8, 14, 28, 44 };

    public bool IsEnabled { get; init; } = true;

    public NoteDeckEdge Edge { get; init; } = NoteDeckEdge.Right;

    public NoteDeckDisplay Display { get; init; } = NoteDeckDisplay.Main;

    public NoteDeckTabStyle Style { get; init; } = NoteDeckTabStyle.Tabs;

    public NoteDeckSize Size { get; init; } = NoteDeckSize.Standard;

    /// <summary>鼠标离屏幕边缘多近就扇出。</summary>
    public double Sense { get; init; } = 14;

    public bool AlwaysFanned { get; init; }

    public bool HidesPill { get; init; }

    public bool ShowsPreview { get; init; } = true;

    public bool OpensOnHover { get; init; }

    public bool OverFullScreen { get; init; }

    public NoteDeckNoteSize NoteSize { get; init; } = NoteDeckNoteSize.Medium;

    /// <summary>药丸的纵向位置：0 = 工作区最上，1 = 最下。</summary>
    public double Position { get; init; } = 0.5;

    /// <summary>读设置。没存过的（null）、不在档位里的都按默认算（导入的文件、手改的设置都可能带进怪值）。
    /// featureOn：便签这个功能开着（功能开关关着时那叠也不出现）。chosenDisplay：display 是 "chosen" 时指定的是哪块；只说了「指定」
    /// 没说是哪块 = 主显示器。</summary>
    public static NoteDeckOptions Read(
        bool? enabled = null, bool featureOn = true, string? edge = null, string? display = null, string? chosenDisplay = null,
        string? style = null, string? size = null, int? sense = null, bool? alwaysFanned = null, bool? hidesPill = null,
        bool? preview = null, bool? opensOnHover = null, bool? overFullScreen = null, string? noteSize = null, double? position = null)
    {
        var shown = display switch
        {
            "all" => NoteDeckDisplay.All,
            "chosen" when chosenDisplay is not null => NoteDeckDisplay.Named(chosenDisplay),
            _ => NoteDeckDisplay.Main,
        };
        var ratio = position ?? 0.5;
        return new NoteDeckOptions
        {
            IsEnabled = (enabled ?? true) && featureOn,
            Edge = edge == "left" ? NoteDeckEdge.Left : NoteDeckEdge.Right,
            Display = shown,
            Style = style == "chips" ? NoteDeckTabStyle.Chips : NoteDeckTabStyle.Tabs,
            Size = size switch
            {
                "small" => NoteDeckSize.Small,
                "large" => NoteDeckSize.Large,
                _ => NoteDeckSize.Standard,
            },
            Sense = sense is { } value && SenseChoices.Contains(value) ? value : 14,
            AlwaysFanned = alwaysFanned ?? false,
            HidesPill = hidesPill ?? false,
            ShowsPreview = preview ?? true,
            OpensOnHover = opensOnHover ?? false,
            OverFullScreen = overFullScreen ?? false,
            NoteSize = noteSize switch
            {
                "small" => NoteDeckNoteSize.Small,
                "large" => NoteDeckNoteSize.Large,
                "extraLarge" => NoteDeckNoteSize.ExtraLarge,
                _ => NoteDeckNoteSize.Medium,
            },
            Position = double.IsFinite(ratio) ? Math.Clamp(ratio, 0, 1) : 0.5,
        };
    }
}

// ---- 尺寸 ----

/// <summary>各个尺寸（DIP）。写的是标准大小时的值，统一乘上大小档再取整：整点上叠着的标签才不出缝。
/// mac 的 font / glyphAdvance（量字）不在这里：标签上的字用 FontSize（半粗），正着放的一个字占多高由窗口代码按字体量。</summary>
public readonly record struct NoteDeckMetrics(double Scale)
{
    private double Scaled(double value) => Math.Round(value * Scale, MidpointRounding.AwayFromZero);

    public double PillWidth => Scaled(12);
    public double PillMinHeight => Scaled(28);
    public double PillPadding => Scaled(6);
    public double DashWidth => Scaled(6);
    public double DashHeight => Scaled(10);
    public double DashGap => Scaled(4);

    /// <summary>带标题的标签：30 宽，一张压一张（下一张盖住上一张 Lap 这么多），露出的一截在 StripMin…StripMax 之间跟着最长的标题走，
    /// 放不下时最小压到 StripFloor。</summary>
    public double TabWidth => Scaled(30);
    public double Lap => Scaled(40);
    public double StripMin => Scaled(56);
    public double StripMax => Scaled(106);
    public double StripFloor => Scaled(36);

    /// <summary>露出的一截 = 最长的标题 + LabelPadding；标题排在那一截里上下一共让出 LabelInset。</summary>
    public double LabelPadding => Scaled(20);
    public double LabelInset => Scaled(12);

    public double ChipHeight => Scaled(24);
    public double ChipGap => Scaled(6);

    public double MoreHeight => Scaled(30);
    public double MoreGap => Scaled(7);
    public double PlusSize => Scaled(26);
    public double PlusGap => Scaled(10);

    /// <summary>标签朝屏幕边多画出去的一截（在屏幕外、被窗口裁掉）：标签斜着放时贴边那一侧的上下角会离开屏幕边。</summary>
    public double TiltBleed => Scaled(14);

    /// <summary>标签上的字（最小 10）。</summary>
    public double FontSize => Math.Max(10, Scaled(12));
}

// ---- 屏幕 ----

/// <summary>一块显示器：名字（同型号的已经由 UniqueNames 加过序号）、整块、工作区（去掉任务栏）。坐标 y 向下。</summary>
public readonly record struct NoteDeckScreen(string Name, RectD Frame, RectD WorkArea);

/// <summary>放在第几块屏的哪条边。</summary>
public readonly record struct NoteDeckPlacement(int Screen, NoteDeckEdge Edge);

/// <summary>几何的小工具（y 向下）。</summary>
internal static class NoteGeometry
{
    /// <summary>点在不在矩形里：左、上边算，右、下边不算（同 Windows 的 RECT；mac CGRect.contains 也是半开的）。</summary>
    public static bool Contains(RectD rect, PointD point)
        => point.X >= rect.X && point.X < rect.Right && point.Y >= rect.Y && point.Y < rect.Bottom;

    public static double OverlapArea(RectD a, RectD b)
    {
        var width = Math.Min(a.Right, b.Right) - Math.Max(a.X, b.X);
        var height = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y);
        return width > 0 && height > 0 ? width * height : 0;
    }

    public static RectD Inset(RectD rect, double dx, double dy)
        => new(rect.X + dx, rect.Y + dy, rect.Width - 2 * dx, rect.Height - 2 * dy);

    /// <summary>竖直方向上的绝对位置取整：.5 往上（y 小的那边），和 mac 在 y 向上的坐标里 .5 往上取是同一个位置。</summary>
    public static double RoundY(double y) => Math.Round(y, MidpointRounding.ToNegativeInfinity);

    public static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);
}

// ---- 排法 ----

/// <summary>一列标签的排法，和那叠的各种位置。</summary>
public sealed record NoteDeckLayout
{
    /// <summary>药丸上最多画几道色条（再多的合成一道灰的）、一次最多扇出几张（其余收进「+N」）。</summary>
    public const int MaxDashes = 14;
    public const int FanLimit = 5;

    /// <summary>那一列最多占工作区高度的这么多。</summary>
    public const double HeightBudget = 0.68;

    /// <summary>鼠标离开标签列再往外这么远才算走了。</summary>
    public const double HotMargin = 20;

    /// <summary>打开的便签离标签列多远、面板在便签外侧给阴影留多少、便签离面板上下边至少多少、标签列离上下边至少多少。</summary>
    public const double NoteGap = 8;
    public const double PanelMargin = 40;
    public const double NoteInset = 10;
    public const double ColumnInset = 12;

    /// <summary>药丸离工作区上下边至少多少。</summary>
    public const double PillMargin = 8;

    /// <summary>预览卡多宽、离标签列多远、最高大约多高。</summary>
    public const double PreviewWidth = 220;
    public const double PreviewGap = 10;
    public const double PreviewHeight = 130;

    /// <summary>按着标签挪过这么多才算拖动排序（没到就是点了一下）。</summary>
    public const double DragSlop = 5;

    /// <summary>每张标签斜多少度。</summary>
    public const double TiltDegrees = 3;

    /// <summary>标签斜多少度（顺时针为正；绕贴屏幕边那一侧的中点转）：右边缘时逆时针、左边缘时顺时针；isOn 是 false（列里打开的那张）
    /// 就是 0。只是画面上的变换：布局、点击区、悬停区、拖动排序都按不斜的算。</summary>
    public static double Tilt(NoteDeckEdge edge, bool isOn) => !isOn ? 0 : edge == NoteDeckEdge.Right ? -TiltDegrees : TiltDegrees;

    public NoteDeckMetrics Metrics { get; }

    public NoteDeckTabStyle Style { get; }

    /// <summary>画出来几张；「+N」里收着几条（0 = 没有「+N」）。</summary>
    public int Count { get; }

    public int Hidden { get; }

    /// <summary>相邻两张顶边差多少（带标题的 = 露出的那一截）、每张多高。</summary>
    public double Step { get; }

    public double ItemHeight { get; }

    /// <summary>标签那一段一共多高；比预算高时（「+N」展开之后）给一个视口，在里面滚。</summary>
    public double StackHeight { get; }

    public double? Viewport { get; }

    /// <param name="longestLabel">这一列里最长的标题竖着排多长（NoteDeckLabel.Length；只有色块时不用）。</param>
    /// <param name="height">面板（那块屏的工作区）多高。</param>
    public NoteDeckLayout(int count, int hidden, double longestLabel, double height, NoteDeckOptions options)
    {
        var metrics = new NoteDeckMetrics(options.Size.Scale());
        count = Math.Max(count, 0);
        hidden = Math.Max(hidden, 0);
        var budget = Budget(hidden, height, options);
        if (options.Style == NoteDeckTabStyle.Chips)
        {
            ItemHeight = metrics.ChipHeight;
            Step = metrics.ChipHeight + metrics.ChipGap;
        }
        else
        {
            var strip = Math.Min(Math.Max(longestLabel + metrics.LabelPadding, metrics.StripMin), metrics.StripMax);
            // 一共占的高度超了预算：把露出的那一截压短，最短到 StripFloor
            if (count > 0 && count * strip + metrics.Lap > budget)
            {
                strip = Math.Max(metrics.StripFloor, Math.Floor((budget - metrics.Lap) / count));
                // 压到最短还是放不下（「+N」展开之后）：反正要在视口里滚，就不压了
                if (count * strip + metrics.Lap > budget)
                {
                    strip = metrics.StripMin;
                }
            }

            ItemHeight = strip + metrics.Lap;
            Step = strip;
        }

        Metrics = metrics;
        Style = options.Style;
        Count = count;
        Hidden = hidden;
        StackHeight = count == 0 ? 0 : (count - 1) * Step + ItemHeight;
        Viewport = count > 0 && StackHeight > budget ? Math.Max(budget, ItemHeight) : null;
    }

    /// <summary>标签那一段的高度预算：屏高的 0.68（取整到整点），扣掉「+N」和「+」占的。</summary>
    public static double Budget(int hidden, double height, NoteDeckOptions options)
    {
        var metrics = new NoteDeckMetrics(options.Size.Scale());
        var reserved = (hidden > 0 ? metrics.MoreGap + metrics.MoreHeight : 0) + metrics.PlusGap + metrics.PlusSize;
        return Math.Max(Math.Floor(height * HeightBudget) - reserved, 0);
    }

    /// <summary>这一列的排法要不要先量最长的标题：只有色块的不用；露出一截压到最短也放不下时（「+N」展开成上千张）也不用——
    /// 那时排法跟最长标题无关，调用方省掉几千次量字。</summary>
    public static bool MeasuresLongest(int count, int hidden, double height, NoteDeckOptions options)
    {
        if (options.Style != NoteDeckTabStyle.Tabs)
        {
            return false;
        }

        var metrics = new NoteDeckMetrics(options.Size.Scale());
        return Math.Max(count, 0) * metrics.StripFloor + metrics.Lap <= Budget(hidden, height, options);
    }

    public double TabWidth => Metrics.TabWidth;

    /// <summary>标签在竖排的栈里的间距（带标题的是负的：下一张压住上一张）。</summary>
    public double Spacing => Step - ItemHeight;

    /// <summary>标签那一段在列里占多高（要滚的时候是视口的高）。</summary>
    public double TabsHeight => Viewport ?? StackHeight;

    /// <summary>整列多高：标签 +「+N」+ 最下面的「+」。</summary>
    public double ColumnHeight
        => TabsHeight + (Hidden > 0 ? Metrics.MoreGap + Metrics.MoreHeight : 0) + Metrics.PlusGap + Metrics.PlusSize;

    /// <summary>第 index 张露在外面的那一截多长（最后一张没人压，整张露着）。</summary>
    public double Strip(int index) => index >= Count - 1 ? ItemHeight : Step;

    /// <summary>标题排在每张顶上多高的一截里：带标题的是露出的那一截，色块是整块。</summary>
    public double LabelHeight => Style == NoteDeckTabStyle.Tabs ? Step : ItemHeight;

    /// <summary>第 index 张那一截的中线离这一列的顶多远（打开的便签对着它摆；滚动过的不算，夹在视口里）。</summary>
    public double TabCenter(int index) => Math.Min(index * Step + LabelHeight / 2, TabsHeight);

    // ---- 药丸 ----

    /// <summary>药丸多高：一条便签一道色条，超过 MaxDashes 条的合成一道。</summary>
    public static double PillHeight(int count, NoteDeckMetrics metrics)
    {
        var dashes = (double)Math.Max(Math.Min(count, MaxDashes) + (count > MaxDashes ? 1 : 0), 1);
        return Math.Max(metrics.PillMinHeight, metrics.PillPadding * 2 + dashes * metrics.DashHeight + (dashes - 1) * metrics.DashGap);
    }

    /// <summary>药丸那块窗口的位置：贴着工作区的那条边，宽 = 感应范围（比药丸还窄时至少装得下药丸），高 = 药丸高，纵向按 Position 摆
    /// （0 = 最上、1 = 最下，各留 PillMargin）。</summary>
    public static RectD PillFrame(NoteDeckScreen screen, NoteDeckEdge edge, int count, NoteDeckOptions options)
    {
        var metrics = new NoteDeckMetrics(options.Size.Scale());
        var visible = screen.WorkArea;
        var height = Math.Min(PillHeight(count, metrics), Math.Max(visible.Height - 2 * PillMargin, 1));
        var width = Math.Max(options.Sense, metrics.PillWidth + 1);
        var highest = visible.Y + PillMargin;
        var lowest = visible.Bottom - PillMargin - height;
        var y = NoteGeometry.RoundY(highest + options.Position * Math.Max(lowest - highest, 0));
        return new RectD(edge == NoteDeckEdge.Right ? visible.Right - width : visible.X, y, width, height);
    }

    // ---- 放哪块屏、哪条边 ----

    /// <summary>这块屏的这条边是不是和别的屏相接（那边贴着另一块屏、纵向有重叠）：相接的边鼠标一过就到了另一块屏，不放。</summary>
    public static bool IsJoined(NoteDeckEdge edge, int index, IReadOnlyList<NoteDeckScreen> screens)
    {
        var own = screens[index].Frame;
        var x = edge == NoteDeckEdge.Right ? own.Right : own.X;
        for (var offset = 0; offset < screens.Count; offset++)
        {
            var other = screens[offset].Frame;
            var facing = edge == NoteDeckEdge.Right ? other.X : other.Right;
            if (offset != index && Math.Abs(facing - x) < 1 && other.Y < own.Bottom && other.Bottom > own.Y)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>想放 edge：它和别的屏相接就换另一侧，两侧都相接这块屏不放（null）。</summary>
    public static NoteDeckEdge? FreeEdge(int index, IReadOnlyList<NoteDeckScreen> screens, NoteDeckEdge preferring)
    {
        if (!IsJoined(preferring, index, screens))
        {
            return preferring;
        }

        return IsJoined(preferring.Opposite(), index, screens) ? null : preferring.Opposite();
    }

    /// <summary>每块屏放不放、放哪边。screens 的第一块是主显示器。</summary>
    public static List<NoteDeckPlacement> Placements(IReadOnlyList<NoteDeckScreen> screens, NoteDeckOptions options)
    {
        var placements = new List<NoteDeckPlacement>();
        if (screens.Count == 0)
        {
            return placements;
        }

        IEnumerable<int> targets = options.Display.Mode switch
        {
            NoteDeckDisplayMode.All => Enumerable.Range(0, screens.Count),
            NoteDeckDisplayMode.Chosen => new[] { Math.Max(IndexOf(screens, options.Display.Name), 0) },
            _ => new[] { 0 },
        };
        foreach (var index in targets)
        {
            if (FreeEdge(index, screens, options.Edge) is { } edge)
            {
                placements.Add(new NoteDeckPlacement(index, edge));
            }
        }

        return placements;
    }

    private static int IndexOf(IReadOnlyList<NoteDeckScreen> screens, string? name)
    {
        for (var index = 0; index < screens.Count; index++)
        {
            if (screens[index].Name == name)
            {
                return index;
            }
        }

        return -1;
    }

    /// <summary>显示器的名字去重：同名的第二块起加序号（「DELL」「DELL 2」「DELL 3」），顺序不变。设置页的菜单和「指定某一块」认的都是
    /// 去重后的名字。ponytail: 按接着的顺序认，两块同型号的换了接口可能对调；要认死得换成显示器的设备路径。</summary>
    public static List<string> UniqueNames(IReadOnlyList<string> names)
    {
        var seen = new Dictionary<string, int>(StringComparer.Ordinal);
        var unique = new List<string>(names.Count);
        foreach (var name in names)
        {
            var count = (seen.TryGetValue(name, out var before) ? before : 0) + 1;
            seen[name] = count;
            unique.Add(count == 1 ? name : $"{name} {count}");
        }

        return unique;
    }

    /// <summary>拖药丸能不能拖到别的屏：只有「指定某一块」、而且指定的那块真接着的时候（它不在时药丸是退回主显示器的，这时拖只换边和高度，
    /// 不改写「指定的是哪块」）。</summary>
    public static bool CrossesScreens(NoteDeckDisplay display, IReadOnlyList<NoteDeckScreen> screens)
        => display.Mode == NoteDeckDisplayMode.Chosen && IndexOf(screens, display.Name) >= 0;

    /// <summary>按住修饰键拖药丸到 mouse：贴鼠标所在那一半的边（那条边和别的屏相接就换另一侧），高度跟着鼠标（药丸的中线对着鼠标）。
    /// crossesScreens：能不能拖到别的屏；鼠标所在的屏两侧都放不了就留在原来那块屏。原来那块屏也放不了时是 null。</summary>
    public static (NoteDeckPlacement Placement, double Position)? Dragged(
        PointD mouse, IReadOnlyList<NoteDeckScreen> screens, int from, bool crossesScreens, double pillHeight)
    {
        if (from < 0 || from >= screens.Count)
        {
            return null;
        }

        var targets = new List<int>();
        if (crossesScreens)
        {
            for (var index = 0; index < screens.Count; index++)
            {
                if (NoteGeometry.Contains(screens[index].Frame, mouse))
                {
                    targets.Add(index);
                    break;
                }
            }
        }

        targets.Add(from);
        foreach (var target in targets)
        {
            var wanted = mouse.X < screens[target].Frame.MidX ? NoteDeckEdge.Left : NoteDeckEdge.Right;
            if (FreeEdge(target, screens, wanted) is not { } edge)
            {
                continue;
            }

            var visible = screens[target].WorkArea;
            var highest = visible.Y + PillMargin;
            var span = visible.Bottom - PillMargin - pillHeight - highest;
            var ratio = span > 0 ? (mouse.Y - pillHeight / 2 - highest) / span : 0.5;
            return (new NoteDeckPlacement(target, edge), Math.Clamp(ratio, 0, 1));
        }

        return null;
    }

    // ---- 那叠 ----

    /// <summary>那叠的面板：贴着工作区的那条边，宽 = 便签宽 + 间隔 + 标签列 + 给阴影的余量（不超过工作区），高 = 工作区高。</summary>
    public static RectD PanelFrame(NoteDeckScreen screen, NoteDeckEdge edge, NoteDeckOptions options)
    {
        var visible = screen.WorkArea;
        var tab = new NoteDeckMetrics(options.Size.Scale()).TabWidth;
        var width = Math.Min(options.NoteSize.Dimensions().Width + NoteGap + tab + PanelMargin, visible.Width);
        return new RectD(edge == NoteDeckEdge.Right ? visible.Right - width : visible.X, visible.Y, width, visible.Height);
    }

    /// <summary>标签列的顶离面板顶多远：整列对着药丸的中线居中，夹在面板里。</summary>
    public static double ColumnTop(double pillCenter, double columnHeight, double panelHeight)
    {
        var lowest = Math.Max(panelHeight - columnHeight - ColumnInset, ColumnInset);
        return NoteGeometry.Round(Math.Min(Math.Max(pillCenter - columnHeight / 2, ColumnInset), lowest));
    }

    /// <summary>打开的便签多大（屏幕太小时夹进面板）。</summary>
    public static (double Width, double Height) NoteSize(
        (double Width, double Height) size, (double Width, double Height) panel, double tabWidth)
        => (Math.Min(size.Width, Math.Max(panel.Width - tabWidth - NoteGap, 1)),
            Math.Min(size.Height, Math.Max(panel.Height - 2 * NoteInset, 1)));

    /// <summary>打开的便签的顶离面板顶多远：对着它那张标签露出的一截居中，夹在面板里。</summary>
    public static double NoteTop(double tabCenter, double noteHeight, double panelHeight)
    {
        var lowest = Math.Max(panelHeight - noteHeight - NoteInset, NoteInset);
        return NoteGeometry.Round(Math.Min(Math.Max(tabCenter - noteHeight / 2, NoteInset), lowest));
    }

    /// <summary>贴着边的一竖条在屏幕上的位置：宽 width，顶离面板顶 top，高 height。</summary>
    public static RectD ColumnFrame(RectD panel, NoteDeckEdge edge, double top, double height, double width)
        => new(edge == NoteDeckEdge.Right ? panel.Right - width : panel.X, panel.Y + top, width, height);

    /// <summary>打开的便签在屏幕上的位置：挨着标签列（隔 NoteGap），顶离面板顶 top。</summary>
    public static RectD NoteFrame(RectD panel, NoteDeckEdge edge, double top, (double Width, double Height) size, double tabWidth)
    {
        var offset = tabWidth + NoteGap;
        return new RectD(
            edge == NoteDeckEdge.Right ? panel.Right - offset - size.Width : panel.X + offset, panel.Y + top, size.Width, size.Height);
    }

    /// <summary>热区：标签列四周再往外 HotMargin；预览卡出着时连它一起算（鼠标要能挪过去点它）。</summary>
    public static RectD HotZone(
        RectD panel, NoteDeckEdge edge, double columnTop, double columnHeight, double tabWidth, bool showsPreview)
        => NoteGeometry.Inset(
            ColumnFrame(panel, edge, columnTop, columnHeight, tabWidth + (showsPreview ? PreviewGap + PreviewWidth : 0)),
            -HotMargin, -HotMargin);

    /// <summary>拖动排序：从第 index 格拖了 offset（往下为正），落在第几格。要拖过一格的 60% 才换位，两头夹住。</summary>
    public static int DragTarget(int from, double offset, double step, int count)
    {
        if (count <= 0 || step <= 0)
        {
            return from;
        }

        var raw = offset / step;
        var moved = raw > 0 ? Math.Floor(raw + 0.4) : Math.Ceiling(raw - 0.4);
        return Math.Min(Math.Max(from + (int)moved, 0), count - 1);
    }
}

// ---- 竖排的标题 ----

/// <summary>竖排的标题：中日韩文字、全角符号、表情正着放、一字一格；别的文字（拉丁字母、数字）整段转 90°，一个词不拆成一摞字母。
/// 「字」按字位簇数（StringInfo，同 Swift 的 Character）。</summary>
public static class NoteDeckLabel
{
    /// <summary>一段：正着放的一格（一个字），或者转着放的一段。</summary>
    public readonly record struct Run(string Text, bool IsUpright);

    public const string Ellipsis = "…";

    /// <summary>这个字（一个字位簇）竖排时正着放吗：里面有一个码位落在下面这些范围里、是默认按表情画的、或者带了「按表情画」的 FE0F。</summary>
    public static bool IsUpright(string character)
    {
        foreach (var rune in character.EnumerateRunes())
        {
            if (IsUprightScalar(rune.Value))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsUprightScalar(int value) => value is 0xFE0F
        or >= 0x1100 and <= 0x11FF // 谚文字母
        or >= 0x2E80 and <= 0x303F // 部首、中日韩符号和标点
        or >= 0x3040 and <= 0x31FF // 假名、注音
        or >= 0x3200 and <= 0x4DBF // 带圈的、兼容用的中日韩字符，扩展 A
        or >= 0x4E00 and <= 0x9FFF // 汉字
        or >= 0xA960 and <= 0xA97F or >= 0xAC00 and <= 0xD7FF // 谚文
        or >= 0xF900 and <= 0xFAFF // 兼容汉字
        or >= 0xFE10 and <= 0xFE1F or >= 0xFE30 and <= 0xFE6F // 竖排用的标点、小写变体
        or >= 0xFF01 and <= 0xFF60 or >= 0xFFE0 and <= 0xFFE6 // 全角字母、数字、符号
        or >= 0x1F000 and <= 0x1FAFF // 表情和图形符号
        or >= 0x20000 and <= 0x3134F // 汉字扩展 B 起
        // mac 另认 Unicode 的 Emoji_Presentation（.NET 没有这个属性）：1F000 以下默认按表情画的那些码位（Unicode 15 的 emoji-data.txt）
        or 0x231A or 0x231B or >= 0x23E9 and <= 0x23EC or 0x23F0 or 0x23F3 or 0x25FD or 0x25FE or 0x2614 or 0x2615
        or >= 0x2648 and <= 0x2653 or 0x267F or 0x2693 or 0x26A1 or 0x26AA or 0x26AB or 0x26BD or 0x26BE or 0x26C4 or 0x26C5
        or 0x26CE or 0x26D4 or 0x26EA or 0x26F2 or 0x26F3 or 0x26F5 or 0x26FA or 0x26FD or 0x2705 or 0x270A or 0x270B or 0x2728
        or 0x274C or 0x274E or >= 0x2753 and <= 0x2755 or 0x2757 or >= 0x2795 and <= 0x2797 or 0x27B0 or 0x27BF or 0x2B1B
        or 0x2B1C or 0x2B50 or 0x2B55;

    private static bool IsWhite(string character) => character.Length > 0 && char.IsWhiteSpace(character[0]);

    private static List<string> Characters(string text)
    {
        var characters = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            characters.Add(enumerator.GetTextElement());
        }

        return characters;
    }

    /// <summary>分段。空白：挨着转着放的字就跟着那一段转（「buy milk」是一段），夹在两个正立的字中间才是竖着的一格空。</summary>
    public static List<Run> Runs(string title)
    {
        var characters = Characters(title);
        var runs = new List<Run>();
        var rotated = new StringBuilder();
        void Flush()
        {
            if (rotated.Length > 0)
            {
                runs.Add(new Run(rotated.ToString(), false));
            }

            rotated.Clear();
        }

        for (var index = 0; index < characters.Count; index++)
        {
            var character = characters[index];
            bool upright;
            if (IsWhite(character))
            {
                string? next = null;
                for (var later = index + 1; later < characters.Count; later++)
                {
                    if (!IsWhite(characters[later]))
                    {
                        next = characters[later];
                        break;
                    }
                }

                upright = rotated.Length == 0 && (next is null || IsUpright(next));
            }
            else
            {
                upright = IsUpright(character);
            }

            if (upright)
            {
                Flush();
                runs.Add(new Run(character, true));
            }
            else
            {
                rotated.Append(character);
            }
        }

        Flush();
        return runs;
    }

    /// <summary>排得下就原样；排不下从后面截，末尾加「…」（跟着转着的那段一起转，前面是正立的字就单独一段——转过来正好是竖着的三个点）。
    /// advance：一段占多长（正着放的一格是一个字的高，转着放的是这段字横排的宽；窗口代码按标签的字体量，单测传固定的数）。</summary>
    public static List<Run> Fitted(string title, double limit, Func<Run, double> advance)
    {
        var all = Runs(title);
        if (all.Sum(advance) <= limit)
        {
            return all;
        }

        var dots = new Run(Ellipsis, false);
        var room = limit - advance(dots);
        var kept = new List<Run>();
        var used = 0.0;
        foreach (var run in all)
        {
            var length = advance(run);
            if (used + length <= room)
            {
                kept.Add(run);
                used += length;
                continue;
            }

            if (run.IsUpright)
            {
                break;
            }

            // 转着放的这一段放不全：一个字一个字试，连省略号一起量
            var head = new StringBuilder();
            foreach (var character in Characters(run.Text))
            {
                if (used + advance(new Run(head.ToString() + character + Ellipsis, false)) > limit)
                {
                    break;
                }

                head.Append(character);
            }

            var trimmed = head.ToString().TrimEnd();
            if (trimmed.Length > 0)
            {
                kept.Add(new Run(trimmed + Ellipsis, false));
                return kept;
            }

            break;
        }

        // 连一个字加省略号都放不下（标签压得很短）：只留打头的那一截、不加省略号
        if (kept.Count == 0 && all.Count > 0)
        {
            var first = all[0];
            if (first.IsUpright)
            {
                if (advance(first) <= limit)
                {
                    return new List<Run> { first };
                }
            }
            else
            {
                var head = new StringBuilder();
                foreach (var character in Characters(first.Text))
                {
                    if (advance(new Run(head.ToString() + character, false)) > limit)
                    {
                        break;
                    }

                    head.Append(character);
                }

                var trimmed = head.ToString().TrimEnd();
                if (trimmed.Length > 0)
                {
                    return new List<Run> { new(trimmed, false) };
                }
            }
        }

        // 末尾是竖着的空格就不留了
        while (kept.Count > 0 && kept[^1].IsUpright && kept[^1].Text.All(char.IsWhiteSpace))
        {
            kept.RemoveAt(kept.Count - 1);
        }

        if (kept.Count > 0 && !kept[^1].IsUpright)
        {
            kept[^1] = kept[^1] with { Text = kept[^1].Text.TrimEnd() + Ellipsis };
        }
        else
        {
            kept.Add(dots);
        }

        return kept;
    }

    /// <summary>整个标题竖着排多长。</summary>
    public static double Length(string title, Func<Run, double> advance) => Runs(title).Sum(advance);
}

// ---- 状态机 ----

public enum NoteDeckPhase
{
    /// <summary>静置：只有边上的药丸。</summary>
    Rest,

    /// <summary>扇出：一列标签。</summary>
    Fanned,

    /// <summary>打开着某一条便签（OpenId）。</summary>
    Open,
}

public enum NoteDeckEventKind
{
    PillEntered,
    Left,
    Idle,
    Tab,
    ShowAll,
    Close,
    Dismiss,
    ClickedOutside,
    Created,
    DragBegan,
    DragEnded,
    Suspend,
    Yield,
}

/// <summary>来了一件事。用下面的工厂建：Flag 在 PillEntered 是「按着修饰键（要拖药丸）」、ClickedOutside / Yield 是「打开的这条固定着」、
/// Suspend 是「打开着的便签也收」；Allowed 只有 PillEntered 用（现在能不能扇出）。</summary>
public readonly record struct NoteDeckEvent(NoteDeckEventKind Kind, string? Id = null, bool Flag = false, bool Allowed = true)
{
    /// <summary>鼠标进了药丸。dragKeyDown：按着拖药丸的那个修饰键；allowed：现在能不能扇出（截图框选、录屏选区、状态屏时不能）。</summary>
    public static NoteDeckEvent PillEntered(bool dragKeyDown, bool allowed) => new(NoteDeckEventKind.PillEntered, Flag: dragKeyDown, Allowed: allowed);

    /// <summary>鼠标离开热区，过一会儿确认了还在外面。</summary>
    public static NoteDeckEvent Left => new(NoteDeckEventKind.Left);

    /// <summary>4 秒没动静。</summary>
    public static NoteDeckEvent Idle => new(NoteDeckEventKind.Idle);

    /// <summary>点了一张标签（或者在上面停够久了）。</summary>
    public static NoteDeckEvent Tab(string id) => new(NoteDeckEventKind.Tab, id);

    /// <summary>点了「+N」。</summary>
    public static NoteDeckEvent ShowAll => new(NoteDeckEventKind.ShowAll);

    /// <summary>用鼠标关便签（关闭按钮、它带着的那张标签）；归档、删除之后：回到那一列。</summary>
    public static NoteDeckEvent Close => new(NoteDeckEventKind.Close);

    /// <summary>用键盘关（Esc、Ctrl+W）：便签连那一列一起收回。</summary>
    public static NoteDeckEvent Dismiss => new(NoteDeckEventKind.Dismiss);

    /// <summary>点了别处。pinned：打开的这条是不是固定着。</summary>
    public static NoteDeckEvent ClickedOutside(bool pinned) => new(NoteDeckEventKind.ClickedOutside, Flag: pinned);

    /// <summary>新建了一条，要在这叠里打开。</summary>
    public static NoteDeckEvent Created(string id) => new(NoteDeckEventKind.Created, id);

    public static NoteDeckEvent DragBegan => new(NoteDeckEventKind.DragBegan);

    public static NoteDeckEvent DragEnded => new(NoteDeckEventKind.DragEnded);

    /// <summary>被叫停。closesOpen：打开着的便签也收。</summary>
    public static NoteDeckEvent Suspend(bool closesOpen) => new(NoteDeckEventKind.Suspend, Flag: closesOpen);

    /// <summary>别的屏的那叠要展开了。pinned：这块屏打开的这条是不是固定着（固定的不收）。</summary>
    public static NoteDeckEvent Yield(bool pinned) => new(NoteDeckEventKind.Yield, Flag: pinned);
}

/// <summary>状态变了该做的事（mac NoteDeck.Effects）。</summary>
[Flags]
public enum NoteDeckEffects
{
    None = 0,

    /// <summary>攒着的改动落盘（关掉、换一条、收起）。</summary>
    Flush = 1 << 0,

    /// <summary>这块屏要展开了：让别的屏的那叠让开。</summary>
    Expand = 1 << 1,

    /// <summary>露出面板（没有就建）。</summary>
    Present = 1 << 2,

    /// <summary>收起面板。</summary>
    Hide = 1 << 3,

    /// <summary>把键盘还给原来的 App（面板留着）。</summary>
    ReleaseKey = 1 << 4,

    /// <summary>焦点进正文，并拿键盘（悬停打开的那一次不拿）。</summary>
    Focus = 1 << 5,

    /// <summary>开始看着：离开热区、4 秒没动静。</summary>
    Watch = 1 << 6,
}

/// <summary>屏幕边缘那叠的状态机（一块屏一份；值类型，拷一份就是一个快照）。三种样子：静置 → 扇出 → 打开；另记「+N」展没展开、
/// 是不是正拖着标签排序、「一直展开」开没开（开着时没有静置这一档，「收回」就是回到扇出那一列）。</summary>
public record struct NoteDeckState
{
    /// <summary>扇出后多久没动静收回、鼠标离开热区多久后再确认一次、收起时标签滑回去给多久。</summary>
    public static readonly TimeSpan IdleDelay = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan LeaveDelay = TimeSpan.FromMilliseconds(150);
    public static readonly TimeSpan HideDuration = TimeSpan.FromMilliseconds(140);

    public NoteDeckPhase Phase { get; private set; }

    /// <summary>打开着的便签（Phase 是 Open 时才有）。</summary>
    public string? OpenId { get; private set; }

    /// <summary>「+N」展开了：列出全部没归档的。</summary>
    public bool ShowsAll { get; private set; }

    /// <summary>正拖着一张标签排序。</summary>
    public bool IsDragging { get; private set; }

    /// <summary>设置里的「一直展开」：改它由 SetAlwaysFanned。</summary>
    public bool AlwaysFanned { get; private set; }

    private readonly NoteDeckPhase Home => AlwaysFanned ? NoteDeckPhase.Fanned : NoteDeckPhase.Rest;

    /// <summary>展开着：比「收回」之后的样子多出来了（一直展开时静置的那一列不算，打开着便签才算）。空闲回收看它。</summary>
    public readonly bool IsExpanded => Phase != Home;

    /// <summary>开关「一直展开」：打开时静置的直接成了扇出；关掉时还扇着的不动，等鼠标离开 / 没动静时照常收。</summary>
    public void SetAlwaysFanned(bool always)
    {
        AlwaysFanned = always;
        if (always && Phase == NoteDeckPhase.Rest)
        {
            Phase = NoteDeckPhase.Fanned;
        }
    }

    /// <summary>来了一件事。返回状态变没变。</summary>
    public bool Handle(NoteDeckEvent e)
    {
        var old = this;
        switch (e.Kind)
        {
            case NoteDeckEventKind.PillEntered when Phase == NoteDeckPhase.Rest:
                if (!e.Flag && e.Allowed)
                {
                    Phase = NoteDeckPhase.Fanned;
                }

                break;
            case NoteDeckEventKind.Left or NoteDeckEventKind.Idle when Phase == NoteDeckPhase.Fanned:
                if (!IsDragging)
                {
                    Collapse();
                }

                break;
            case NoteDeckEventKind.Tab when Phase == NoteDeckPhase.Fanned:
                if (!IsDragging)
                {
                    Open(e.Id);
                }

                break;
            case NoteDeckEventKind.Tab when Phase == NoteDeckPhase.Open:
                if (e.Id == OpenId)
                {
                    Phase = NoteDeckPhase.Fanned;
                    OpenId = null;
                }
                else
                {
                    Open(e.Id);
                }

                break;
            case NoteDeckEventKind.ShowAll when Phase != NoteDeckPhase.Rest:
                ShowsAll = true;
                break;
            case NoteDeckEventKind.Close when Phase == NoteDeckPhase.Open:
                Phase = NoteDeckPhase.Fanned;
                OpenId = null;
                break;
            case NoteDeckEventKind.Dismiss when Phase != NoteDeckPhase.Rest:
                Collapse();
                break;
            case NoteDeckEventKind.ClickedOutside when Phase == NoteDeckPhase.Open:
                if (!e.Flag)
                {
                    Collapse();
                }

                break;
            case NoteDeckEventKind.Created:
                IsDragging = false;
                Open(e.Id);
                break;
            case NoteDeckEventKind.DragBegan when Phase == NoteDeckPhase.Fanned:
                IsDragging = true;
                break;
            case NoteDeckEventKind.DragEnded:
                IsDragging = false;
                break;
            case NoteDeckEventKind.Suspend when Phase == NoteDeckPhase.Fanned || (Phase == NoteDeckPhase.Open && e.Flag):
            case NoteDeckEventKind.Yield when Phase == NoteDeckPhase.Fanned || (Phase == NoteDeckPhase.Open && !e.Flag):
                Collapse();
                break;
        }

        return this != old;
    }

    private void Open(string? id)
    {
        Phase = NoteDeckPhase.Open;
        OpenId = id ?? string.Empty;
    }

    private void Collapse()
    {
        Phase = Home;
        OpenId = null;
        ShowsAll = false;
        IsDragging = false;
    }

    /// <summary>状态从 old 变成 next 该做哪几件事：只有**新打开 / 换了一条**才拿键盘、聚焦（别的变化不许抢键盘）；任何一条「打开 → 扇出」
    /// 的路都当场把键盘还回去（面板留着）；回到静置是整块收走。</summary>
    public static NoteDeckEffects EffectsOf(NoteDeckState old, NoteDeckState next)
    {
        var effects = NoteDeckEffects.None;
        var opened = next.OpenId is not null && old.OpenId != next.OpenId;
        if (old.OpenId is not null && old.OpenId != next.OpenId)
        {
            effects |= NoteDeckEffects.Flush;
        }

        if (next.Phase != NoteDeckPhase.Rest && (old.Phase == NoteDeckPhase.Rest || opened))
        {
            effects |= NoteDeckEffects.Expand;
        }

        switch (next.Phase)
        {
            case NoteDeckPhase.Rest:
                effects |= NoteDeckEffects.Hide;
                break;
            case NoteDeckPhase.Fanned:
                if (old.Phase == NoteDeckPhase.Rest)
                {
                    effects |= NoteDeckEffects.Present;
                }

                if (old.OpenId is not null)
                {
                    effects |= NoteDeckEffects.ReleaseKey;
                }

                effects |= NoteDeckEffects.Watch;
                break;
            default:
                if (old.Phase == NoteDeckPhase.Rest)
                {
                    effects |= NoteDeckEffects.Present;
                }

                if (opened)
                {
                    effects |= NoteDeckEffects.Focus;
                }

                break;
        }

        return effects;
    }
}
