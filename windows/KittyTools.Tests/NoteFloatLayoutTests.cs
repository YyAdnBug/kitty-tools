// 浮动便签的纯函数（Core/Notes/NoteFloatLayout.cs）的单测，照 mac NoteFloatTests.swift 里测纯函数的用例：detachingNeedsFortyPoints、
// liftingKeepsTheTabCornerInPlace、homeScreen、clampingKeepsTheWholeNoteVisible、placingWithoutADrag、onlyActiveNotesFloat、rememberedSize、
// placeRoundTrips、onlyAPinnedFloatIsRemembered、restoringNeedsALivePinnedNote、floatReturnsToItsDisplayAfterUnplugging、oneNoteAtATime、
// effectsOfEachTransition、cascadingAvoidsTheOthers；severalFloatsUpToTheLimit 和 pinnedFloatsAreRememberedAndReleased 里集合的规则
// （上限、最久没碰的先收、重复的记录只回来一张）改成对 NoteFloatSet 的纯函数测。
// **坐标换算**同 NoteDeckLayoutTests：矩形、点照 mac 测试里的数写，经 Mac()/MacPoint() 换成 y 向下（主屏高 900：矩形 y_win = 900 − y_mac − 高，
// 点 y_win = 900 − y_mac）；mac 只比某一条边（maxY / minY）的地方在旁边注释写了换算。只量距离的（脱出的阈值）换不换都一样，也照样换了。
// 设置里存的格式和 mac 不一样（mac 是 NSStringFromSize / NSStringFromRect）：大小「宽,高」、位置「x,y,宽,高」，下面的字符串跟着改了。
// 跳过的：floatStateIsMachineState（注册默认值）、menuFitsAShortNote（操作菜单）、placeRoundTrips 里「存的不是字典 / 值不是字」那两条
// （Windows 设置里是 Dictionary<string, string>，存不进别的类型）；floatingNoteClosesByTucking 起的其余用例（模型、面板、按键、焦点、
// 撤销栈、截图里算什么、替身）都要真的窗口或仓库。
using KittyTools.Core;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteFloatLayoutTests
{
    private const double MainHeight = 900;

    private static RectD Mac(double x, double y, double width, double height) => new(x, MainHeight - y - height, width, height);

    private static PointD MacPoint(double x, double y) => new(x, MainHeight - y);

    /// <summary>一块 1440 × 900 的屏（菜单栏 25），mac 的左下角在 (x, y)。</summary>
    private static NoteDeckScreen Screen(string name = "主屏", double x = 0, double y = 0, double width = 1440, double height = 900)
        => new(name, Mac(x, y, width, height), Mac(x, y, width, height - 25));

    private static Note Pinned(string id = "甲") => new() { Id = id, IsPinned = true };

    // ---- 几何 ----

    /// <summary>按着把手挪过 40（哪个方向都算）才脱出来；没挪开（5 以内）算点了一下。</summary>
    [TestMethod]
    public void DetachingNeedsFortyPoints()
    {
        var start = MacPoint(100, 100);
        Assert.IsFalse(NoteFloatLayout.Detaches(start, start));
        Assert.IsFalse(NoteFloatLayout.Detaches(start, MacPoint(61, 100)));
        Assert.IsTrue(NoteFloatLayout.Detaches(start, MacPoint(60, 100)));
        Assert.IsTrue(NoteFloatLayout.Detaches(start, MacPoint(140, 100)));
        Assert.IsTrue(NoteFloatLayout.Detaches(start, MacPoint(100, 59)));
        // 斜着走：量的是直线距离
        Assert.IsFalse(NoteFloatLayout.Detaches(start, MacPoint(128, 128)));
        Assert.IsTrue(NoteFloatLayout.Detaches(start, MacPoint(129, 129)));
        Assert.IsFalse(NoteFloatLayout.Moved(start, MacPoint(105, 100)));
        Assert.IsTrue(NoteFloatLayout.Moved(start, MacPoint(106, 100)));
        Assert.IsTrue(NoteFloatLayout.Moved(start, MacPoint(100, 94)));
    }

    /// <summary>脱出那一刻：带着标签的那一侧的上角不动；没记过大小就是原处原大小，一点都不跳。</summary>
    [TestMethod]
    public void LiftingKeepsTheTabCornerInPlace()
    {
        var sheet = Mac(900, 300, 460, 380); // = (900, 220, 460, 380)
        Assert.AreEqual(sheet, NoteFloatLayout.Lifted(sheet, (sheet.Width, sheet.Height), true));
        Assert.AreEqual(sheet, NoteFloatLayout.Lifted(sheet, (sheet.Width, sheet.Height), false));
        // mac 比的是 maxY（上边）不动：y 向下就是 Y 不动
        var left = NoteFloatLayout.Lifted(sheet, (600, 500), true);
        Assert.AreEqual(new RectD(sheet.X, sheet.Y, 600, 500), left);
        var right = NoteFloatLayout.Lifted(sheet, (600, 500), false);
        Assert.AreEqual(sheet.Right, right.Right);
        Assert.AreEqual(sheet.Y, right.Y);
        Assert.AreEqual((600.0, 500.0), (right.Width, right.Height));
        // 跟着鼠标走：鼠标离面板一角多远一直不变（mac 量的是左下角，这里是左上角；数照搬）
        Assert.AreEqual(new PointD(500, 500), NoteFloatLayout.Origin((12, 200), new PointD(512, 700)));
    }

    /// <summary>算在哪块屏：给了鼠标就是鼠标所在的那块；否则重叠最多的；哪块都不沾（那块屏拔了）是主显示器。</summary>
    [TestMethod]
    public void HomeScreen()
    {
        var screens = new[] { Screen(), Screen("副屏", x: 1440) };
        var straddling = Mac(1300, 200, 400, 300);
        Assert.AreEqual(1, NoteFloatLayout.Home(straddling, null, screens));
        Assert.AreEqual(0, NoteFloatLayout.Home(straddling.Offset(-100, 0), null, screens));
        Assert.AreEqual(0, NoteFloatLayout.Home(straddling, MacPoint(1400, 300), screens));
        // 鼠标不在任何一块屏上：按重叠算
        Assert.AreEqual(1, NoteFloatLayout.Home(straddling, MacPoint(9000, 0), screens));
        Assert.AreEqual(0, NoteFloatLayout.Home(Mac(9000, 9000, 400, 300), null, screens));
        Assert.IsNull(NoteFloatLayout.Home(straddling, null, Array.Empty<NoteDeckScreen>()));
    }

    /// <summary>夹进工作区：整块都在里面；出了哪边就贴哪边；比工作区大的缩进来（顶边不动）；不小于最小尺寸。</summary>
    [TestMethod]
    public void ClampingKeepsTheWholeNoteVisible()
    {
        var visible = Screen().WorkArea; // mac (0, 0, 1440, 875) = (0, 25, 1440, 875)
        var inside = Mac(200, 300, 460, 380);
        Assert.AreEqual(inside, NoteFloatLayout.Clamped(inside, visible));
        Assert.AreEqual(1440, NoteFloatLayout.Clamped(inside.Offset(1200, 0), visible).Right);
        Assert.AreEqual(0, NoteFloatLayout.Clamped(inside.Offset(-900, 0), visible).X);
        // 顶上不压进菜单栏（任务栏），底下不出工作区。mac 往上挪 400（dy +400）→ y 向下是 −400；mac maxY == 875 → 顶边 y = 900 − 875
        Assert.AreEqual(900 - 875, NoteFloatLayout.Clamped(inside.Offset(0, -400), visible).Y);
        // mac 往下挪 500、minY == 0 → 底边 y = 900
        Assert.AreEqual(900, NoteFloatLayout.Clamped(inside.Offset(0, 500), visible).Bottom);
        Assert.AreEqual(visible, NoteFloatLayout.Clamped(Mac(-50, -400, 3000, 2000), visible));
        // 太小的撑到最小尺寸，顶边不动（mac maxY == 680 → y = 900 − 680 = 220）
        var tiny = NoteFloatLayout.Clamped(Mac(200, 600, 100, 80), visible);
        Assert.AreEqual(NoteFloatLayout.MinSize, (tiny.Width, tiny.Height));
        Assert.AreEqual(900 - 680, tiny.Y);
        Assert.AreEqual(200, tiny.X);
        // 位置取整到整点：mac 挪 (0.4, 0.6)、原点 (200, 301) → y = 900 − 301 − 380 = 219
        var fractional = NoteFloatLayout.Clamped(inside.Offset(0.4, -0.6), visible);
        Assert.AreEqual(Mac(200, 301, 460, 380), fractional);
        // 落下：按松手那块屏夹；屏幕都没了原样返回
        var screens = new[] { Screen(), Screen("副屏", x: 1440) };
        var dropped = NoteFloatLayout.Settled(Mac(1300, 700, 460, 380), MacPoint(1500, 800), screens);
        Assert.AreEqual(Mac(1440, 495, 460, 380), dropped);
        Assert.AreEqual(inside, NoteFloatLayout.Settled(inside, null, Array.Empty<NoteDeckScreen>()));
    }

    /// <summary>不靠拖浮出来：从那叠里出来的比原处往屏幕里面挪 48；没有原处的在鼠标所在屏的正中。收回时朝那叠所在的边滑。</summary>
    [TestMethod]
    public void PlacingWithoutADrag()
    {
        var screens = new[] { Screen(), Screen("副屏", x: 1440) };
        var sheet = Mac(902, 300, 460, 380);
        (double, double) size = (500, 420);
        var fromRight = NoteFloatLayout.Placed(size, sheet, NoteDeckEdge.Right, new PointD(0, 0), new[] { Screen() });
        Assert.AreEqual(Mac(902 - 48, 300 - 40, 500, 420), fromRight);
        // 左边缘：标签在右边，右上角不动，再往里（右）挪 48
        var fromLeft = NoteFloatLayout.Placed(size, Mac(78, 300, 460, 380), NoteDeckEdge.Left, new PointD(0, 0), new[] { Screen() });
        Assert.AreEqual(Mac(538 - 500 + 48, 260, 500, 420), fromLeft);
        // 正中：mac (1910, 227.5) 取整到 228（.5 往上）→ y = 900 − 228 − 420 = 252
        var centered = NoteFloatLayout.Placed(size, null, NoteDeckEdge.Right, MacPoint(2000, 400), screens);
        Assert.AreEqual(Mac(1440 + 470, 228, 500, 420), centered);
        Assert.AreEqual(48, NoteFloatLayout.TuckOffset(NoteDeckEdge.Right));
        Assert.AreEqual(-48, NoteFloatLayout.TuckOffset(NoteDeckEdge.Left));
        Assert.AreEqual(0, NoteFloatLayout.TuckOffset(null));
    }

    /// <summary>只有没归档、没删的便签能浮着。</summary>
    [TestMethod]
    public void OnlyActiveNotesFloat()
    {
        var note = new Note { Id = "甲" };
        Assert.IsTrue(NoteFloatLayout.Floats(note));
        Assert.IsFalse(NoteFloatLayout.Floats(null));
        Assert.IsFalse(NoteFloatLayout.Floats(note with { IsArchived = true }));
        Assert.IsFalse(NoteFloatLayout.Floats(note with { DeletedAt = 1 }));
    }

    /// <summary>记下的大小：没记过、读不出来用给的那个；不小于最小尺寸；夹进它要出现的那块屏。</summary>
    [TestMethod]
    public void RememberedSize()
    {
        (double, double) fallback = (460, 380);
        Assert.AreEqual(fallback, NoteFloatLayout.StoredSize(null, fallback));
        Assert.AreEqual(fallback, NoteFloatLayout.StoredSize("不是大小", fallback));
        Assert.AreEqual(fallback, NoteFloatLayout.StoredSize("0,300", fallback));
        Assert.AreEqual(fallback, NoteFloatLayout.StoredSize("Infinity,300", fallback));
        Assert.AreEqual(fallback, NoteFloatLayout.StoredSize("1,2,3", fallback));
        Assert.AreEqual("520.4,610.6", NoteFloatLayout.SizeText((520.4, 610.6)));
        Assert.AreEqual((520.0, 611.0), NoteFloatLayout.StoredSize(NoteFloatLayout.SizeText((520.4, 610.6)), fallback));
        Assert.AreEqual(NoteFloatLayout.MinSize, NoteFloatLayout.StoredSize("100,90", fallback));
        Assert.AreEqual(NoteFloatLayout.MinSize, NoteFloatLayout.StoredSize(null, (10, 10)));
        // 夹进它要出现的那块屏
        (double, double) laptop = (1440, 875);
        Assert.AreEqual(laptop, NoteFloatLayout.StoredSize("2560,1440", fallback, laptop));
        Assert.AreEqual(laptop, NoteFloatLayout.StoredSize(NoteFloatLayout.SizeText((1e9, 1e9)), fallback, laptop));
        Assert.AreEqual((600.0, 500.0), NoteFloatLayout.StoredSize("600,500", fallback, laptop));
        Assert.AreEqual((1440.0, 220.0), NoteFloatLayout.StoredSize(null, (9000, 100), laptop));
    }

    /// <summary>固定着的那一张的位置：存取对得上；不是那个样子的读成 null。</summary>
    [TestMethod]
    public void PlaceRoundTrips()
    {
        var place = new NoteFloatLayout.Place("甲", Mac(-120.5, 300, 460, 380));
        Assert.AreEqual(place, NoteFloatLayout.Place.FromStored(place.ToStored()));
        Assert.AreEqual("-120.5,220,460,380", place.ToStored()["frame"]);
        Assert.IsFalse(place.ToStored().ContainsKey("display"), "没记屏就不写");
        Assert.IsNull(NoteFloatLayout.Place.FromStored(null));
        Assert.IsNull(NoteFloatLayout.Place.FromStored(new Dictionary<string, string> { ["id"] = "甲" }));
        Assert.IsNull(NoteFloatLayout.Place.FromStored(new Dictionary<string, string> { ["id"] = "", ["frame"] = "0,0,460,380" }));
        Assert.IsNull(NoteFloatLayout.Place.FromStored(new Dictionary<string, string> { ["id"] = "甲", ["frame"] = "乱写的" }));
        Assert.IsNull(NoteFloatLayout.Place.FromStored(new Dictionary<string, string> { ["id"] = "甲", ["frame"] = "0,0,0,380" }));
        Assert.IsNull(NoteFloatLayout.Place.FromStored(new Dictionary<string, string> { ["id"] = "甲", ["frame"] = "0,0,NaN,380" }));
    }

    /// <summary>该不该记：浮着、已经落下、固定着才记；没固定的不跨重启。</summary>
    [TestMethod]
    public void OnlyAPinnedFloatIsRemembered()
    {
        var frame = Mac(100, 100, 460, 380);
        var note = new Note { Id = "甲" };
        Assert.IsNull(NoteFloatLayout.Remembered("甲", false, note, frame));
        note = note with { IsPinned = true };
        Assert.AreEqual(new NoteFloatLayout.Place("甲", frame), NoteFloatLayout.Remembered("甲", false, note, frame));
        Assert.IsNull(NoteFloatLayout.Remembered("甲", true, note, frame));
        Assert.IsNull(NoteFloatLayout.Remembered(null, false, note, frame));
        Assert.IsNull(NoteFloatLayout.Remembered("乙", false, note, frame));
        Assert.IsNull(NoteFloatLayout.Remembered("甲", false, null, frame));
        Assert.IsNull(NoteFloatLayout.Remembered("甲", false, note with { IsArchived = true }, frame));
    }

    /// <summary>重启后回不回来：便签还在、没归档没删、还固定着才回来；位置夹进现在看得见的屏幕，那块屏不在了就到主显示器。</summary>
    [TestMethod]
    public void RestoringNeedsALivePinnedNote()
    {
        var screens = new[] { Screen() };
        var frame = Mac(300, 200, 460, 380);
        var note = Pinned();
        var place = new NoteFloatLayout.Place("甲", frame);
        Assert.AreEqual(frame, NoteFloatLayout.Restored(place, note, screens));
        Assert.IsNull(NoteFloatLayout.Restored(null, note, screens));
        Assert.IsNull(NoteFloatLayout.Restored(place, null, screens));
        Assert.IsNull(NoteFloatLayout.Restored(new NoteFloatLayout.Place("乙", frame), note, screens));
        Assert.IsNull(NoteFloatLayout.Restored(place, note, Array.Empty<NoteDeckScreen>()));
        // 原来在外接屏上、外接屏拔了：回到主显示器的工作区里（mac 挪 (3000, 500)，y 向下是 (3000, −500)）
        var away = new NoteFloatLayout.Place("甲", frame.Offset(3000, -500));
        Assert.AreEqual(Mac(1440 - 460, 875 - 380, 460, 380), NoteFloatLayout.Restored(away, note, screens));
        // 分辨率变小了、记着的比屏幕还大
        var small = new[] { Screen(width: 400, height: 325) };
        Assert.AreEqual(small[0].WorkArea, NoteFloatLayout.Restored(place, note, small));
        Assert.IsNull(NoteFloatLayout.Restored(place, note with { IsPinned = false }, screens));
        Assert.IsNull(NoteFloatLayout.Restored(place, note with { IsArchived = true }, screens));
        Assert.IsNull(NoteFloatLayout.Restored(place, note with { DeletedAt = 1 }, screens));
    }

    /// <summary>拔外接屏之后回原处：记着那块屏的名字；拔了挤到主屏（记录不改），插回来回到原处；没记屏的照旧按重叠算。</summary>
    [TestMethod]
    public void FloatReturnsToItsDisplayAfterUnplugging()
    {
        var laptop = Screen();
        var external = Screen("副屏", x: 1440);
        var both = new[] { laptop, external };
        var spot = Mac(2000, 300, 460, 380);
        Assert.AreEqual("副屏", NoteFloatLayout.Display(spot, null, both));
        Assert.AreEqual("主屏", NoteFloatLayout.Display(spot, MacPoint(10, 10), both));
        Assert.IsNull(NoteFloatLayout.Display(spot, null, Array.Empty<NoteDeckScreen>()));
        // 两块都在：就在原处
        Assert.AreEqual(spot, NoteFloatLayout.Placed(spot, "副屏", both));
        // 拔了：挤进主屏的工作区
        var squeezed = NoteFloatLayout.Placed(spot, "副屏", new[] { laptop });
        Assert.AreEqual(Mac(1440 - 460, 300, 460, 380), squeezed);
        // 插回来：同一个记录算出来的又是原处
        Assert.AreEqual(spot, NoteFloatLayout.Placed(spot, "副屏", both));
        // 插回来的那块屏换了位置（排在左边）：还是回到那块屏上（夹进它的工作区）
        var movedExternal = Screen("副屏", x: -1440);
        static bool Within(RectD outer, RectD inner)
            => inner.X >= outer.X && inner.Y >= outer.Y && inner.Right <= outer.Right && inner.Bottom <= outer.Bottom;
        Assert.IsTrue(Within(external.WorkArea, spot));
        Assert.IsTrue(Within(movedExternal.WorkArea, NoteFloatLayout.Placed(spot, "副屏", new[] { laptop, movedExternal })));
        // 重启时那块屏不在：先在主屏，记录照旧
        var note = Pinned();
        var place = new NoteFloatLayout.Place("甲", spot, "副屏");
        Assert.AreEqual(squeezed, NoteFloatLayout.Restored(place, note, new[] { laptop }));
        Assert.AreEqual(spot, NoteFloatLayout.Restored(place, note, both));
        Assert.AreEqual(place, NoteFloatLayout.Remembered("甲", false, note, spot, "副屏"));
        // 存取带着屏；没记屏的读出来是 null，算法同 Settled
        Assert.AreEqual(place, NoteFloatLayout.Place.FromStored(place.ToStored()));
        Assert.IsNull(NoteFloatLayout.Place.FromStored(new Dictionary<string, string> { ["id"] = "甲", ["frame"] = NoteFloatLayout.FrameText(spot) })?.Display);
        Assert.AreEqual(squeezed, NoteFloatLayout.Placed(spot, null, new[] { laptop }));
        Assert.AreEqual(spot, NoteFloatLayout.Placed(spot, "早就没了的屏", both));
    }

    // ---- 状态机 ----

    private static NoteFloatState State(params NoteFloatEvent[] events)
    {
        var state = new NoteFloatState();
        foreach (var e in events)
        {
            state.Handle(e);
        }

        return state;
    }

    /// <summary>一张一份：再浮一张就换成新的；拖着的时候不接「浮出来」「收回」。</summary>
    [TestMethod]
    public void OneNoteAtATime()
    {
        var state = new NoteFloatState();
        Assert.IsTrue(state.NoteId is null && !state.IsDragging);
        // 没有浮着的：松手、收回、便签没了都不变
        Assert.IsFalse(state.Handle(NoteFloatEvent.Drop));
        Assert.IsFalse(state.Handle(NoteFloatEvent.Tuck));
        Assert.IsFalse(state.Handle(NoteFloatEvent.Remove));
        Assert.IsTrue(state.Handle(NoteFloatEvent.Detach("甲")));
        Assert.IsTrue(state.NoteId == "甲" && state.IsDragging);
        // 拖着的时候不接「浮出来」「收回」
        Assert.IsFalse(state.Handle(NoteFloatEvent.Float("乙")));
        Assert.IsFalse(state.Handle(NoteFloatEvent.Tuck));
        Assert.IsTrue(state.Handle(NoteFloatEvent.Drop));
        Assert.IsTrue(state.NoteId == "甲" && !state.IsDragging);
        Assert.IsFalse(state.Handle(NoteFloatEvent.Float("甲")));
        Assert.IsTrue(state.Handle(NoteFloatEvent.Float("乙")));
        Assert.AreEqual("乙", state.NoteId);
        Assert.IsTrue(state.Handle(NoteFloatEvent.Detach("甲")));
        Assert.IsTrue(state.NoteId == "甲" && state.IsDragging);
        // 拖着的时候便签没了：直接关
        Assert.IsTrue(state.Handle(NoteFloatEvent.Remove));
        Assert.AreEqual(new NoteFloatState(), state);
        Assert.AreEqual(new NoteFloatState(), State(NoteFloatEvent.Float("甲"), NoteFloatEvent.Tuck));
        Assert.AreEqual(new NoteFloatState(), State(NoteFloatEvent.Float("甲"), NoteFloatEvent.Remove));
    }

    /// <summary>状态变化该做的事（mac NoteFloat.effects）。</summary>
    [TestMethod]
    public void EffectsOfEachTransition()
    {
        static NoteFloatEffects Effects(NoteFloatEvent e, NoteFloatState old)
        {
            var next = old;
            next.Handle(e);
            return NoteFloatState.EffectsOf(e, old, next);
        }

        var none = new NoteFloatState();
        // 拖出来：只露出来，还没落下
        Assert.AreEqual(NoteFloatEffects.Show, Effects(NoteFloatEvent.Detach("甲"), none));
        Assert.AreEqual(NoteFloatEffects.Land, Effects(NoteFloatEvent.Drop, State(NoteFloatEvent.Detach("甲"))));
        // 不靠拖：露出来就落下
        Assert.AreEqual(NoteFloatEffects.Show | NoteFloatEffects.Land, Effects(NoteFloatEvent.Float("甲"), none));
        // 换一张：前一张落盘、收回去
        var floating = State(NoteFloatEvent.Float("甲"));
        Assert.AreEqual(
            NoteFloatEffects.Flush | NoteFloatEffects.TuckOld | NoteFloatEffects.Show | NoteFloatEffects.Land, Effects(NoteFloatEvent.Float("乙"), floating));
        Assert.AreEqual(NoteFloatEffects.Flush | NoteFloatEffects.TuckOld | NoteFloatEffects.Show, Effects(NoteFloatEvent.Detach("乙"), floating));
        // 收回是朝边缘滑着淡掉，便签没了是直接淡掉
        Assert.AreEqual(NoteFloatEffects.Flush | NoteFloatEffects.TuckOld, Effects(NoteFloatEvent.Tuck, floating));
        Assert.AreEqual(NoteFloatEffects.Flush | NoteFloatEffects.DropOld, Effects(NoteFloatEvent.Remove, floating));
        Assert.AreEqual(NoteFloatEffects.Flush | NoteFloatEffects.DropOld, Effects(NoteFloatEvent.Remove, State(NoteFloatEvent.Detach("甲"))));
        // 没变的不做事
        Assert.AreEqual(NoteFloatEffects.None, Effects(NoteFloatEvent.Float("甲"), floating));
        Assert.AreEqual(NoteFloatEffects.None, Effects(NoteFloatEvent.Tuck, State(NoteFloatEvent.Detach("甲"))));
        Assert.AreEqual(NoteFloatEffects.None, Effects(NoteFloatEvent.Drop, floating));
    }

    // ---- 同时浮几张 ----

    /// <summary>错开：左上角和哪张相距不到 8 就往右下挪 24；挪出工作区回到起点那一列、往下一行；都挤着 / 一格都放不下用起点。
    /// mac 往右下是 (+24, −24)，y 向下是 (+24, +24)；下面照 mac 的数经 Mac() 换。</summary>
    [TestMethod]
    public void CascadingAvoidsTheOthers()
    {
        var visible = Mac(0, 0, 1000, 800);
        var start = Mac(300, 300, 400, 300);
        Assert.AreEqual(start, NoteFloatLayout.Cascaded(start, Array.Empty<RectD>(), visible));
        var near = Mac(305, 295, 400, 300);
        Assert.AreEqual(Mac(324, 276, 400, 300), NoteFloatLayout.Cascaded(start, new[] { near }, visible));
        // 第一、第二格都占了：第三格
        var two = new[] { start, Mac(324, 276, 400, 300) };
        Assert.AreEqual(Mac(348, 252, 400, 300), NoteFloatLayout.Cascaded(start, two, visible));
        // 右边放不下：回到起点那一列、往下一行
        var right = Mac(580, 300, 400, 300);
        Assert.AreEqual(Mac(580, 276, 400, 300), NoteFloatLayout.Cascaded(right, new[] { right }, visible));
        // 往下也放不下：用起点（叠着也不乱跑）
        var bottom = Mac(580, 0, 400, 300);
        Assert.AreEqual(bottom, NoteFloatLayout.Cascaded(bottom, new[] { bottom }, visible));
    }

    /// <summary>mac severalFloatsUpToTheLimit / pinnedFloatsAreRememberedAndReleased 里集合的规则：最多 5 张；浮着的再浮一次 = 叫到前面（算碰）；
    /// 第 6 张收回最久没碰的；拖着的那张不收；记着的位置里重复的只回来一张。</summary>
    [TestMethod]
    public void SeveralFloatsUpToTheLimit()
    {
        var ids = Enumerable.Range(1, 7).Select(index => $"第 {index} 条").ToArray();
        var order = new List<string>();
        foreach (var id in ids.Take(NoteFloatSet.Limit))
        {
            (order, var evicted) = NoteFloatSet.Admitted(order, id);
            Assert.AreEqual(0, evicted.Count);
        }

        Assert.AreEqual(NoteFloatSet.Limit, order.Count);
        // 浮着的再浮一次：叫到前面（挪到最后）
        order = NoteFloatSet.Touched(order, ids[0]);
        Assert.AreEqual(ids[0], order[^1]);
        // 第 6 张：最久没碰的（第 2 条，第 1 条刚被叫到前面过）收回去
        (order, var out1) = NoteFloatSet.Admitted(order, ids[5]);
        CollectionAssert.AreEqual(new[] { ids[1] }, out1);
        CollectionAssert.AreEquivalent(new[] { ids[0], ids[2], ids[3], ids[4], ids[5] }, order);
        // 叫到前面也算碰
        order = NoteFloatSet.Touched(order, ids[2]);
        Assert.AreEqual(ids[2], order[^1]);
        // 拖着的那张最久没碰也不收：收下一张
        var dragging = order[0];
        (var kept, var out2) = NoteFloatSet.Admitted(order, ids[6], dragging);
        Assert.AreEqual(NoteFloatSet.Limit, kept.Count);
        Assert.IsTrue(kept.Contains(dragging) && kept.Contains(ids[6]) && !out2.Contains(dragging));
        Assert.AreEqual(1, out2.Count);
        Assert.AreEqual(("最多同时浮 5 张", "「周报」收回了边缘"), NoteFloatSet.EvictionNotice("周报"));
        // 记着 8 条（有一条重复）、一条写坏的：读出 7 条，同一条只一张
        var frame = Mac(300, 300, 400, 300);
        var stored = ids.Append(ids[0])
            .Select(id => (IReadOnlyDictionary<string, string>?)new NoteFloatLayout.Place(id, frame).ToStored())
            .Append(new Dictionary<string, string> { ["id"] = "坏的" })
            .ToList();
        var places = NoteFloatSet.Restorable(stored);
        CollectionAssert.AreEqual(ids, places.Select(place => place.Id).ToList());
        Assert.AreEqual(0, NoteFloatSet.Restorable(null).Count);
    }
}
