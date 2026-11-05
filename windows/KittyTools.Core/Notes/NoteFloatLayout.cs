// 浮动便签（PLAN-v13 第 6 批要用的纯函数；照 mac Notes/NoteFloatLayout.swift、NoteFloatState.swift、NoteFloat.swift 里的 effects、
// NoteFloats.swift 里的集合规则）：
// - 拖出来：按着把手挪过多远算脱出、没挪开算点了一下、脱出那一刻摆在哪（带着标签的那一侧的上角不动）、之后怎么跟着鼠标走；
// - 落下、屏幕变了：算在哪块屏、整块夹进那块屏的工作区；人放下它的地方连那块屏的名字一起记，拔了那块屏被挤到别处时只挪窗口、
//   不改记录，那块屏回来就放回原处；
// - 不靠拖浮出来时摆在哪、按菜单浮出来的和已经浮着的错开、收回时替身朝哪边滑；哪些便签能浮着；
// - 记下的大小、固定着的每一张的位置（设置里存的格式见 Place / StoredSize）；
// - 状态机（一张一份）和状态变了该做的事；同时浮几张（上限 5，再浮一张时最久没碰的收回）。
// **坐标**：y 向下（同 NoteDeckLayout 文件头）；屏幕给的是 Frame 和工作区（WorkArea）。
using System.Globalization;

namespace KittyTools.Core.Notes;

public static class NoteFloatLayout
{
    /// <summary>按着把手往外拖，挪过这么远（哪个方向都算）才脱出来；以内松手 = 没拖。</summary>
    public const double DetachDistance = 40;

    /// <summary>浮动便签最小多大（连它带着的那张标签）。</summary>
    public static readonly (double Width, double Height) MinSize = (320, 220);

    /// <summary>不靠拖浮出来的：比它在那叠里的位置再往屏幕里面挪这么多。</summary>
    public const double FloatInset = 48;

    /// <summary>收回边缘时朝那条边滑多远（边滑边淡；屏幕边缘没有那叠时不滑）。</summary>
    public const double TuckSlide = 48;

    // ---- 拖出来 ----

    /// <summary>按着把手从 start 挪到 point：脱没脱出来。</summary>
    public static bool Detaches(PointD start, PointD point) => Distance(start, point) >= DetachDistance;

    /// <summary>挪没挪开（没挪开就松手 = 点了一下；和标签拖动排序同一个量）。</summary>
    public static bool Moved(PointD start, PointD point) => Distance(start, point) > NoteDeckLayout.DragSlop;

    private static double Distance(PointD a, PointD b) => double.Hypot(b.X - a.X, b.Y - a.Y);

    /// <summary>脱出那一刻浮动面板摆在哪。sheet 是这条便签在那叠里的位置：带着标签的那一侧的上角不动（把手就在那一侧和顶上）；
    /// 大小换成 size（记下的那个；没记过就是它在那叠里的大小，一点都不跳）。</summary>
    public static RectD Lifted(RectD sheet, (double Width, double Height) size, bool tabOnLeading)
        => new(tabOnLeading ? sheet.X : sheet.Right - size.Width, sheet.Y, size.Width, size.Height);

    /// <summary>跟着鼠标走：grab 是开始拖的那一刻鼠标离面板**左上角**多远（mac 是左下角），给出面板的左上角。</summary>
    public static PointD Origin((double Width, double Height) grab, PointD pointer)
        => new(pointer.X - grab.Width, pointer.Y - grab.Height);

    // ---- 落下、屏幕变了 ----

    /// <summary>这块面板算在哪块屏上：给了鼠标（松手的地方）就是鼠标所在的那块，否则是和它重叠最多的那块；哪块都不沾就是第一块（主显示器）。
    /// 一块屏都没有是 null。</summary>
    public static int? Home(RectD frame, PointD? pointer, IReadOnlyList<NoteDeckScreen> screens)
    {
        if (screens.Count == 0)
        {
            return null;
        }

        if (pointer is { } point)
        {
            for (var index = 0; index < screens.Count; index++)
            {
                if (NoteGeometry.Contains(screens[index].Frame, point))
                {
                    return index;
                }
            }
        }

        var (best, bestArea) = (0, 0.0);
        for (var index = 0; index < screens.Count; index++)
        {
            var area = NoteGeometry.OverlapArea(screens[index].Frame, frame);
            if (area > bestArea)
            {
                (best, bestArea) = (index, area);
            }
        }

        return best;
    }

    /// <summary>夹进工作区：整块都在里面，位置取整到整点。大小不小于 MinSize；比工作区还大的缩到工作区那么大（顶边不动地改大小）。</summary>
    public static RectD Clamped(RectD frame, RectD visible)
    {
        var width = NoteGeometry.Round(Math.Min(Math.Max(frame.Width, MinSize.Width), visible.Width));
        var height = NoteGeometry.Round(Math.Min(Math.Max(frame.Height, MinSize.Height), visible.Height));
        var top = Math.Max(Math.Min(frame.Y, visible.Bottom - height), visible.Y);
        var x = Math.Min(Math.Max(frame.X, visible.X), visible.Right - width);
        return new RectD(NoteGeometry.Round(x), NoteGeometry.RoundY(top), width, height);
    }

    /// <summary>落下、屏幕变了之后该在哪：算出在哪块屏，整块夹进它的工作区。一块屏都没有时原样返回。</summary>
    public static RectD Settled(RectD frame, PointD? pointer, IReadOnlyList<NoteDeckScreen> screens)
        => Home(frame, pointer, screens) is { } index ? Clamped(frame, screens[index].WorkArea) : frame;

    /// <summary>这块面板算在哪块屏上，那块屏的名字（同那叠「指定的那一块」的认法）；一块屏都没有是 null。</summary>
    public static string? Display(RectD frame, PointD? pointer, IReadOnlyList<NoteDeckScreen> screens)
        => Home(frame, pointer, screens) is { } index ? screens[index].Name : null;

    /// <summary>人放下它的地方（frame，在 display 那块屏上）现在该摆在哪：那块屏还接着就回到它上面（夹进它的工作区）；不在了按 Settled
    /// 挤到别的屏——调用方不改记录，那块屏插回来再算一遍就回到原处。没记屏的同 Settled。</summary>
    public static RectD Placed(RectD frame, string? display, IReadOnlyList<NoteDeckScreen> screens)
    {
        if (display is not null)
        {
            foreach (var screen in screens)
            {
                if (screen.Name == display)
                {
                    return Clamped(frame, screen.WorkArea);
                }
            }
        }

        return Settled(frame, null, screens);
    }

    /// <summary>不靠拖浮出来（操作菜单、全部便签窗口）摆在哪：从那叠里出来的（sheet 是它在那叠里的位置）比原处往屏幕里面挪 FloatInset；
    /// 没有原处的摆在鼠标所在屏工作区的正中。都夹进工作区。</summary>
    public static RectD Placed(
        (double Width, double Height) size, RectD? sheet, NoteDeckEdge edge, PointD mouse, IReadOnlyList<NoteDeckScreen> screens)
    {
        if (sheet is { } origin)
        {
            var start = Lifted(origin, size, edge == NoteDeckEdge.Right);
            return Settled(start.Offset(edge == NoteDeckEdge.Right ? -FloatInset : FloatInset, 0), null, screens);
        }

        static RectD Centered(RectD area, (double Width, double Height) box)
            => new(area.MidX - box.Width / 2, area.MidY - box.Height / 2, box.Width, box.Height);

        if (Home(new RectD(0, 0, 0, 0), mouse, screens) is not { } index)
        {
            return Centered(new RectD(0, 0, 0, 0), size);
        }

        var work = screens[index].WorkArea;
        return Clamped(Centered(work, size), work);
    }

    /// <summary>按菜单浮出来的新一张和已经浮着的错开：左上角和哪一张相距不到 near，就往右下挪 step 再看；挪出了工作区，回到起点那一列、
    /// 往下一行再接着往右下挪。挪满 limit 次都挤着、连起点那一列都放不下了，就用起点（宁可叠着也不乱跑）。拖出来的不走这里。</summary>
    public static RectD Cascaded(RectD frame, IReadOnlyList<RectD> others, RectD visible, double step = 24, double near = 8, int limit = 60)
    {
        bool Crowded(RectD candidate)
        {
            foreach (var other in others)
            {
                if (Math.Abs(other.X - candidate.X) < near && Math.Abs(other.Y - candidate.Y) < near)
                {
                    return true;
                }
            }

            return false;
        }

        bool Fits(RectD candidate) => candidate.Right <= visible.Right + 0.5 && candidate.Bottom <= visible.Bottom + 0.5;

        var (row, column) = (0, 0);
        for (var attempt = 0; attempt < limit; attempt++)
        {
            var candidate = frame.Offset(step * column, step * (column + row));
            if (!Fits(candidate))
            {
                if (column == 0)
                {
                    break;
                }

                (row, column) = (row + 1, 0);
                continue;
            }

            if (!Crowded(candidate))
            {
                return candidate;
            }

            column++;
        }

        return frame;
    }

    /// <summary>收回时替身朝哪边滑多远（x 方向）：朝那叠所在的那条边；屏幕边缘没有那叠（null）就不滑、只淡。</summary>
    public static double TuckOffset(NoteDeckEdge? edge) => edge switch
    {
        NoteDeckEdge.Right => TuckSlide,
        NoteDeckEdge.Left => -TuckSlide,
        _ => 0,
    };

    // ---- 哪些能浮着 ----

    /// <summary>这条便签能不能浮着：还在、没归档、没进最近删除。</summary>
    public static bool Floats(Note? note) => note?.IsActive ?? false;

    // ---- 记下的 ----

    /// <summary>记下的大小在设置里的样子：「宽,高」（不变区域的数字，如「520.4,610.6」；mac 是 NSStringFromSize 的「{520.4, 610.6}」）。</summary>
    public static string SizeText((double Width, double Height) size)
        => string.Join(',', Number(size.Width), Number(size.Height));

    /// <summary>记下的大小（拉过大小之后写）：没记过、读不出来就用 fallback；不小于 MinSize。给了 limit（它要出现的那块屏的工作区）就不大过它。</summary>
    public static (double Width, double Height) StoredSize(
        string? stored, (double Width, double Height) fallback, (double Width, double Height)? limit = null)
    {
        var size = fallback;
        if (Numbers(stored, 2) is { } read && double.IsFinite(read[0]) && double.IsFinite(read[1]) && read[0] > 0 && read[1] > 0)
        {
            size = (read[0], read[1]);
        }

        var maxWidth = limit?.Width ?? double.PositiveInfinity;
        var maxHeight = limit?.Height ?? double.PositiveInfinity;
        return (NoteGeometry.Round(Math.Min(Math.Max(size.Width, MinSize.Width), maxWidth)),
            NoteGeometry.Round(Math.Min(Math.Max(size.Height, MinSize.Height), maxHeight)));
    }

    /// <summary>位置在设置里的样子：「x,y,宽,高」（y 向下；不变区域的数字。mac 是 NSStringFromRect 的「{{x, y}, {w, h}}」，y 向上——两边不互通，
    /// 这是这台电脑自己的状态，不同步、不导出）。</summary>
    public static string FrameText(RectD frame)
        => string.Join(',', Number(frame.X), Number(frame.Y), Number(frame.Width), Number(frame.Height));

    /// <summary>读位置：四个有限的数、宽高都大于 0；不是这个样子的给 null。</summary>
    public static RectD? ParseFrame(string? text)
        => Numbers(text, 4) is { } values && values.All(double.IsFinite) && values[2] > 0 && values[3] > 0
            ? new RectD(values[0], values[1], values[2], values[3])
            : null;

    private static string Number(double value) => value.ToString(CultureInfo.InvariantCulture);

    private static double[]? Numbers(string? text, int count)
    {
        if (text is null)
        {
            return null;
        }

        var parts = text.Split(',');
        if (parts.Length != count)
        {
            return null;
        }

        var values = new double[count];
        for (var index = 0; index < count; index++)
        {
            if (!double.TryParse(parts[index], NumberStyles.Float, CultureInfo.InvariantCulture, out values[index]))
            {
                return null;
            }
        }

        return values;
    }

    /// <summary>固定着浮在屏幕上的一张：哪条便签、在哪、在哪块屏上（设置里存一组，这台电脑自己的状态、不导出）。
    /// 存的样子（ToStored）：{"id": 编号, "frame": FrameText(位置), "display": 屏的名字（没有就不写）}——同 mac 的那一组字典。</summary>
    public readonly record struct Place(string Id, RectD Frame, string? Display = null)
    {
        /// <summary>读设置里的一项。不是这个样子的（没有编号、位置读不出来、宽高不大于 0）是 null。</summary>
        public static Place? FromStored(IReadOnlyDictionary<string, string>? stored)
        {
            if (stored is null || !stored.TryGetValue("id", out var id) || id.Length == 0 ||
                !stored.TryGetValue("frame", out var text) || ParseFrame(text) is not { } frame)
            {
                return null;
            }

            var display = stored.TryGetValue("display", out var name) && name.Length > 0 ? name : null;
            return new Place(id, frame, display);
        }

        public Dictionary<string, string> ToStored()
        {
            var stored = new Dictionary<string, string> { ["id"] = Id, ["frame"] = FrameText(Frame) };
            if (Display is not null)
            {
                stored["display"] = Display;
            }

            return stored;
        }
    }

    /// <summary>现在该记什么：浮着、已经落下、而且这条便签固定着，就记它在哪（人放下它的地方和那块屏）；别的时候不记（null = 把记着的删掉）。
    /// mac NoteFloatLayout.place。</summary>
    public static Place? Remembered(string? id, bool isDragging, Note? note, RectD frame, string? display = null)
    {
        if (id is null || isDragging || note is null || note.Id != id || !Floats(note) || !note.IsPinned)
        {
            return null;
        }

        return new Place(id, frame, display);
    }

    /// <summary>重启后要不要让它回来、回到哪：记着的那条便签还在、没归档没删、还固定着才回来；记着的那块屏接着就回到它上面，不在了挤到现在
    /// 看得见的屏幕上（记录不改）。不回来是 null。</summary>
    public static RectD? Restored(Place? place, Note? note, IReadOnlyList<NoteDeckScreen> screens)
    {
        if (place is not { } stored || note is null || note.Id != stored.Id || !Floats(note) || !note.IsPinned || screens.Count == 0)
        {
            return null;
        }

        return Placed(stored.Frame, stored.Display, screens);
    }
}

// ---- 状态机（一张浮动便签一份）----

public enum NoteFloatEventKind
{
    /// <summary>从那叠里拖出来，过了阈值（鼠标还按着）。</summary>
    Detach,

    /// <summary>不靠拖浮出来：操作菜单、全部便签窗口、重启后恢复。</summary>
    Float,

    /// <summary>松手，落下。</summary>
    Drop,

    /// <summary>收回（关闭钮、它带着的那张标签、Esc、Ctrl+W、菜单里的「收回边缘」）。</summary>
    Tuck,

    /// <summary>这条便签不在了（删除、归档、进了最近删除）：直接关。</summary>
    Remove,
}

public readonly record struct NoteFloatEvent(NoteFloatEventKind Kind, string? Id = null)
{
    public static NoteFloatEvent Detach(string id) => new(NoteFloatEventKind.Detach, id);

    public static NoteFloatEvent Float(string id) => new(NoteFloatEventKind.Float, id);

    public static NoteFloatEvent Drop => new(NoteFloatEventKind.Drop);

    public static NoteFloatEvent Tuck => new(NoteFloatEventKind.Tuck);

    public static NoteFloatEvent Remove => new(NoteFloatEventKind.Remove);
}

/// <summary>状态变了该做的事（mac NoteFloat.Effects）。</summary>
[Flags]
public enum NoteFloatEffects
{
    None = 0,

    /// <summary>攒着的改动落盘（前一张要走了）。</summary>
    Flush = 1 << 0,

    /// <summary>前一张收回边缘（面板当场收走，替身朝那条边滑着淡掉）。</summary>
    TuckOld = 1 << 1,

    /// <summary>前一张直接淡掉（这条便签不在了）。</summary>
    DropOld = 1 << 2,

    /// <summary>建面板、露出来（不拿键盘）。</summary>
    Show = 1 << 3,

    /// <summary>落下：拿键盘、焦点进正文（拖出来的还要夹进工作区）。</summary>
    Land = 1 << 4,
}

/// <summary>浮动便签的状态机（一张一份）。没有 → 拖着（Detach）→ 浮着（Drop）；没有 → 浮着（Float）；浮着 → 没有（Tuck / Remove）。
/// 拖着的时候不接 Float、Tuck（鼠标还按着）。</summary>
public record struct NoteFloatState
{
    /// <summary>浮着的那条便签（null = 没有）。</summary>
    public string? NoteId { get; private set; }

    /// <summary>正被拖出来、还没松手。</summary>
    public bool IsDragging { get; private set; }

    /// <summary>来了一件事。返回状态变没变。</summary>
    public bool Handle(NoteFloatEvent e)
    {
        var old = this;
        switch (e.Kind)
        {
            case NoteFloatEventKind.Detach:
                NoteId = e.Id;
                IsDragging = true;
                break;
            case NoteFloatEventKind.Float:
                if (!IsDragging)
                {
                    NoteId = e.Id;
                }

                break;
            case NoteFloatEventKind.Drop:
                IsDragging = false;
                break;
            case NoteFloatEventKind.Tuck:
                if (!IsDragging)
                {
                    NoteId = null;
                }

                break;
            case NoteFloatEventKind.Remove:
                NoteId = null;
                IsDragging = false;
                break;
        }

        return this != old;
    }

    /// <summary>来了 e、状态从 old 变成 next，该做哪几件事。</summary>
    public static NoteFloatEffects EffectsOf(NoteFloatEvent e, NoteFloatState old, NoteFloatState next)
    {
        var effects = NoteFloatEffects.None;
        var changed = old.NoteId != next.NoteId;
        if (changed && old.NoteId is not null)
        {
            effects |= NoteFloatEffects.Flush | (e.Kind == NoteFloatEventKind.Remove ? NoteFloatEffects.DropOld : NoteFloatEffects.TuckOld);
        }

        if (changed && next.NoteId is not null)
        {
            effects |= NoteFloatEffects.Show;
        }

        if (next.NoteId is not null && !next.IsDragging && (changed || old.IsDragging))
        {
            effects |= NoteFloatEffects.Land;
        }

        return effects;
    }
}

// ---- 同时浮几张（mac NoteFloats 的集合规则）----

/// <summary>同时浮在屏幕上的几张：顺序是「最久没碰的在前」（编号）。「碰」= 拿到键盘、被叫到前面、按着把手挪、刚浮出来。
/// 浮着的那条再浮一次 = 叫到前面（Touched），不另建一张；拖着一张的时候别的不浮。</summary>
public static class NoteFloatSet
{
    /// <summary>最多同时浮几张。</summary>
    public const int Limit = 5;

    /// <summary>超过上限收回一张时的轻提示。</summary>
    public static (string Title, string Detail) EvictionNotice(string title) => ($"最多同时浮 {Limit} 张", $"「{title}」收回了边缘");

    /// <summary>碰了一下：挪到最后（最近碰过的）。</summary>
    public static List<string> Touched(IReadOnlyList<string> order, string id)
    {
        var list = order.ToList();
        var index = list.IndexOf(id);
        if (index >= 0 && index != list.Count - 1)
        {
            list.RemoveAt(index);
            list.Add(id);
        }

        return list;
    }

    /// <summary>新浮起来一张：加到最后；多过上限，从最久没碰的起收回边缘（不收它自己、不收正拖着的那张）。给出新的顺序和要收回的编号
    /// （按收回的先后）。</summary>
    public static (List<string> Order, List<string> Evicted) Admitted(IReadOnlyList<string> order, string id, string? dragging = null)
    {
        var list = order.ToList();
        list.Add(id);
        var evicted = new List<string>();
        while (list.Count > Limit)
        {
            var oldest = list.FindIndex(other => other != id && other != dragging);
            if (oldest < 0)
            {
                break;
            }

            evicted.Add(list[oldest]);
            list.RemoveAt(oldest);
        }

        return (list, evicted);
    }

    /// <summary>重启后要回来的那几张：设置里记的那一组按顺序读，读不出来的、编号重复的扔掉。调用方逐条用 NoteFloatLayout.Restored 算
    /// 回不回来、回到哪，回来了的满 Limit 张就停（便签不在了的那几条不占名额）。</summary>
    public static List<NoteFloatLayout.Place> Restorable(IEnumerable<IReadOnlyDictionary<string, string>?>? stored)
    {
        var places = new List<NoteFloatLayout.Place>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in stored ?? Array.Empty<IReadOnlyDictionary<string, string>?>())
        {
            if (NoteFloatLayout.Place.FromStored(item) is { } place && seen.Add(place.Id))
            {
                places.Add(place);
            }
        }

        return places;
    }
}
