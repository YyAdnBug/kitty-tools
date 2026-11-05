// 屏幕边缘的便签（PLAN-v13 第 6 批，照 mac Notes/NoteEdge.swift + NoteDeck.swift + NoteDeckModel.swift；规则和状态机在 Core 的
// NoteDeckLayout / NoteDeckState，规矩在 mac-overlay-panel §12）。平时贴在屏幕边上的一条药丸，鼠标靠过去扇出一列标签，点一张，
// 便签从边缘出来直接打字。
// - NoteDeck（这个静态类）管「几块屏」：什么时候有（设置里开着、而且至少一条没归档没删的便签）、放哪（主显示器 / 所有 / 指定的那块，
//   右边 / 左边，两块屏相接的那条边不放）、只展开一块屏的、叫停（截图框选、长截图、录屏、状态屏）、新建便签、按住 Alt 拖药丸。
//   设置变了、屏幕变了、便签的条数和颜色变了重摆——都是现成的事件，没有定时器。
// - NoteDeckBay 是一块屏上的那叠：药丸、标签列、预览卡、打开的便签四扇窗（NoteDeckWindows.cs）。状态机变了按 EffectsOf 去做：
//   露出 / 收起、拿 / 还键盘、落盘。扇着、开着的时候每 150 ms 看一眼鼠标（离开热区、4 秒没动静；没拿键盘的便签点了别处），静置时没有计时器。
// **Windows 自己定的（PLAN-v13 §3.2）**：贴在那块屏的**工作区**边上（永远不挡任务栏）；透明窗口在用户机器上是白的，所以药丸、标签列、
// 预览卡、打开的便签各是一扇不透明的小窗，没有 mac 那块整屏高的透明面板；打开的便签要打字，所以拿前台。
// 别的程序全屏时（前台窗口盖满那块屏）药丸收起、不扇出，设置里可开（挂了前台切换的系统事件，不轮询）。
// 坐标：Core 的函数不管单位。放哪块屏、拖药丸用物理像素（几块屏一起比）；一块屏里的摆法用这块屏的 DIP（物理像素 ÷ 这块屏的缩放），
// 摆窗口时再乘回去。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Graphics;
using Windows.Win32;

namespace KittyTools;

internal static partial class NoteDeck
{
    /// <summary>叫停时打开着的便签怎么办（mac NoteEdge.Suspension）。</summary>
    public enum Suspension
    {
        /// <summary>留着：截图 / 录屏框选和倒数（它是内容，留在冻结帧和录屏里）。</summary>
        KeepsOpen,

        /// <summary>没固定的收：截图翻译、识字、长截图。</summary>
        UnlessPinned,

        /// <summary>都收：状态屏。</summary>
        All,
    }

    private static readonly List<NoteDeckBay> Bays = new();
    private static int[] _colors = Array.Empty<int>();
    private static NoteStore? _store;
    private static IntPtr _hook;

    public static NoteDeckOptions Options { get; private set; } = new();

    /// <summary>有展开着的（扇着、开着便签）：空闲回收看它。</summary>
    public static bool IsExpanded => Bays.Any(bay => bay.IsExpanded);

    /// <summary>读设置（功能开关关着时那叠也不出现）。</summary>
    public static NoteDeckOptions ReadOptions()
    {
        var s = SettingsService.Current;
        return NoteDeckOptions.Read(
            s.NotesDeckEnabled, Features.IsOn(Feature.Notes), s.NotesDeckEdge, s.NotesDeckDisplay, s.NotesDeckChosenDisplay,
            s.NotesDeckStyle, s.NotesDeckSize, s.NotesDeckSense, s.NotesDeckAlwaysFanned, s.NotesDeckHidesPill, s.NotesDeckPreview,
            s.NotesDeckOpensOnHover, s.NotesDeckOverFullScreen, s.NotesDeckNoteSize, s.NotesDeckPosition);
    }

    /// <summary>按现在的设置、屏幕、便签重摆：该有的建出来 / 挪到位，不该有的收掉。</summary>
    public static void Refresh()
    {
        if (NoteStore.Instance is not { } store)
        {
            CloseAll();
            return;
        }

        if (!ReferenceEquals(_store, store))
        {
            _store = store;
            store.Changed += StoreChanged;
        }

        Options = ReadOptions();
        _colors = store.Book.Active.Select(note => note.Color).ToArray();
        var screens = NoteFloats.Screens();
        var placements = Options.IsEnabled && _colors.Length > 0 ? NoteDeckLayout.Placements(screens, Options) : new List<NoteDeckPlacement>();
        var placed = new List<NoteDeckBay>();
        foreach (var placement in placements)
        {
            var screen = screens[placement.Screen];
            var bay = Bays.FirstOrDefault(item => item.ScreenName == screen.Name && !placed.Contains(item)) ?? new NoteDeckBay();
            bay.Place(screen, ScaleOf(screen), placement.Edge, Options);
            placed.Add(bay);
        }

        foreach (var old in Bays.Where(bay => !placed.Contains(bay)).ToList())
        {
            old.Close();
        }

        var appeared = Bays.Count == 0 && placed.Count > 0;
        Bays.Clear();
        Bays.AddRange(placed);
        UpdateHook();
        if (appeared)
        {
            HintIfFirst(placements[0].Edge);
        }
    }

    /// <summary>设置保存了（ShellRuntime.OnSettingsChanged）：那叠的选项真变了才重摆。</summary>
    public static void SettingsChanged()
    {
        if (NoteStore.Instance is not null && ReadOptions() != Options)
        {
            Refresh();
        }
    }

    private static void CloseAll()
    {
        foreach (var bay in Bays)
        {
            bay.Close();
        }

        Bays.Clear();
        UpdateHook();
    }

    private static void StoreChanged()
    {
        foreach (var bay in Bays)
        {
            bay.StoreChanged();
        }

        NoteFloats.Prune();
        if (_store is { } store && !store.Book.Active.Select(note => note.Color).SequenceEqual(_colors))
        {
            Refresh();
        }
    }

    private static double ScaleOf(NoteDeckScreen screen)
    {
        var scale = Displays.AtPoint((int)(screen.Frame.X + screen.Frame.Width / 2), (int)(screen.Frame.Y + screen.Frame.Height / 2)).Scale;
        return scale > 0 ? scale : 1;
    }

    /// <summary>每台电脑第一次出现时说一句在哪（说过了记在设置里，这个键不导出）。</summary>
    private static void HintIfFirst(NoteDeckEdge edge)
    {
        if (SettingsService.Current.NotesDeckHintShown)
        {
            return;
        }

        SettingsService.Current.NotesDeckHintShown = true;
        SettingsService.Save();
        NoticeHost.Show($"便签在屏幕{edge.Title()}边缘", "鼠标靠过去就能看到", NoticeTone.Normal);
    }

    // ---- 浮动便签、几叠之间 ----

    /// <summary>这条要浮到屏幕上了（NoteFloats.Float 调）：它正开在哪一叠里就从那叠里收掉（同一条便签不留两个正文框）。</summary>
    public static void Release(string id)
    {
        foreach (var bay in Bays.Where(bay => bay.OpenId == id))
        {
            bay.Send(NoteDeckEvent.Close);
        }
    }

    /// <summary>这条便签现在开在哪一叠里。</summary>
    public static bool IsOpen(string id) => Bays.Any(bay => bay.OpenId == id);

    /// <summary>一块屏的那叠要展开了：别的屏的让开（固定着的便签不收）。</summary>
    internal static void Expanding(NoteDeckBay from)
    {
        foreach (var bay in Bays.Where(bay => bay != from))
        {
            bay.Yield();
        }
    }

    /// <summary>「新建便签」：建一条并在鼠标所在屏的那叠里打开。false = 这边开不了（总开关关着、哪块屏都放不了），调用方去全部便签窗口。</summary>
    public static bool OpenNew() => Open(null);

    /// <summary>在鼠标所在屏的那叠里打开 id 这条（它正浮着就叫到前面）；null = 新建一条。</summary>
    public static bool Open(string? id)
    {
        var options = ReadOptions();
        if (NoteStore.Instance is not { } store || !options.IsEnabled || NoteDeckLayout.Placements(NoteFloats.Screens(), options).Count == 0)
        {
            return false;
        }

        if (id is not null && NoteFloats.IsFloating(id))
        {
            NoteFloats.Float(id, from: null, dragging: false);
            return true;
        }

        id ??= store.BlankOrNew().Id;
        Refresh();
        PInvoke.GetCursorPos(out var cursor);
        var home = Bays.FirstOrDefault(bay => bay.ContainsScreenPoint(cursor.X, cursor.Y)) ?? Bays.FirstOrDefault();
        if (home is null)
        {
            return false;
        }

        home.Send(NoteDeckEvent.Created(id));
        return true;
    }

    /// <summary>截图框选 / 长截图 / 录屏选区和倒数 / 状态屏开始时调：先落盘，扇着的当场收起。浮动便签不收（人自己放在屏幕上的内容）。</summary>
    public static void Suspend(Suspension kind)
    {
        NoteStore.Instance?.Flush();
        foreach (var bay in Bays)
        {
            bay.Suspend(kind);
        }
    }

    /// <summary>现在能不能扇出：没在截图框选 / 长截图 / 录屏倒数 / 状态屏。</summary>
    internal static bool CanFan()
        => !ScreenshotSession.IsActive && !ScrollingCapture.Active && !RecordingCountdown.Active && !StatusScreenHost.Active;

    // ---- 按住 Alt 拖药丸 ----

    /// <summary>跟着鼠标换边、换高度（「指定某一块」、而且那块真接着时还能换屏）；drops：松手了，记进设置再整个重摆。</summary>
    internal static void DragPill(NoteDeckBay bay, int x, int y, bool drops)
    {
        var screens = NoteFloats.Screens();
        var index = screens.FindIndex(screen => screen.Name == bay.ScreenName);
        if (index < 0)
        {
            return;
        }

        var crosses = NoteDeckLayout.CrossesScreens(Options.Display, screens);
        var height = NoteDeckLayout.PillHeight(_colors.Length, new NoteDeckMetrics(Options.Size.Scale())) * ScaleOf(screens[index]);
        if (NoteDeckLayout.Dragged(new PointD(x, y), screens, index, crosses, height) is not { } result)
        {
            return;
        }

        var target = screens[result.Placement.Screen];
        if (!drops)
        {
            bay.MovePill(target, ScaleOf(target), result.Placement.Edge, Options with { Position = result.Position });
            return;
        }

        var settings = SettingsService.Current;
        settings.NotesDeckEdge = result.Placement.Edge.Raw();
        settings.NotesDeckPosition = result.Position;
        if (crosses)
        {
            settings.NotesDeckChosenDisplay = target.Name;
        }

        SettingsService.Save();
        Refresh();
    }

    // ---- 全屏 ----

    /// <summary>不盖在全屏程序上（默认）且有那叠时，挂前台切换的系统事件（不轮询；进程外回调，在这条 UI 线程的消息循环里来）。</summary>
    private static unsafe void UpdateHook()
    {
        var wanted = Bays.Count > 0 && !Options.OverFullScreen;
        if (wanted && _hook == IntPtr.Zero)
        {
            _hook = SetWinEventHook(3 /* EVENT_SYSTEM_FOREGROUND */, 3, IntPtr.Zero, &OnForeground, 0, 0, 0 /* WINEVENT_OUTOFCONTEXT */);
            CheckFullScreen();
        }
        else if (!wanted && _hook != IntPtr.Zero)
        {
            UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
            foreach (var bay in Bays)
            {
                bay.SetCovered(false);
            }
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnForeground(IntPtr hook, uint e, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        try
        {
            CheckFullScreen();
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.deck-fullscreen-check-failed {ex.GetType().Name}");
        }
    }

    private static void CheckFullScreen()
    {
        var hwnd = PInvoke.GetForegroundWindow();
        foreach (var bay in Bays)
        {
            bay.SetCovered(IsFullScreen((IntPtr)hwnd.Value, bay));
        }
    }

    /// <summary>前台窗口盖满这块屏（不是桌面、不是我们自己的窗口）。</summary>
    private static unsafe bool IsFullScreen(IntPtr hwnd, NoteDeckBay bay)
    {
        if (hwnd == IntPtr.Zero || hwnd == GetShellWindow() || Foreground.IsOurs(new Windows.Win32.Foundation.HWND(hwnd)) || !GetWindowRect(hwnd, out var rect))
        {
            return false;
        }

        var buffer = stackalloc char[32];
        var length = GetClassName(hwnd, buffer, 32);
        var name = new string(buffer, 0, Math.Max(length, 0));
        if (name is "Progman" or "WorkerW" or "Shell_TrayWnd")
        {
            return false;
        }

        var frame = bay.ScreenFrame;
        return rect.Left <= frame.X && rect.Top <= frame.Y && rect.Right >= frame.Right && rect.Bottom >= frame.Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [LibraryImport("user32.dll")]
    private static unsafe partial IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr module, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int, int, uint, uint, void> callback,
        uint process, uint thread, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnhookWinEvent(IntPtr hook);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetShellWindow();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, out WinRect rect);

    [LibraryImport("user32.dll", EntryPoint = "GetClassNameW")]
    private static unsafe partial int GetClassName(IntPtr hwnd, char* buffer, int max);
}

/// <summary>一块屏上的那叠（mac NoteDeck + NoteDeckModel）。</summary>
internal sealed partial class NoteDeckBay
{
    private static readonly TimeSpan WatchInterval = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan PreviewDelay = TimeSpan.FromMilliseconds(180);
    private static readonly TimeSpan PreviewLinger = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan HoverOpenDelay = TimeSpan.FromMilliseconds(400);

    private NoteDeckState _state;
    private NoteDeckOptions _options = new();
    private NoteDeckScreen _screen;
    private RectD _screenPixels;
    private double _scale = 1;
    private NoteDeckEdge _edge;
    private RectD _panel;
    private double _pillCenter;
    private double? _openTop;
    private NoteDeckLayout? _layout;
    private NoteDeckPillWindow? _pill;
    private NoteDeckColumnWindow? _column;
    private NoteDeckPreviewWindow? _preview;
    private NoteDeckSheetWindow? _sheet;
    private DispatcherQueueTimer? _watch;
    private DispatcherQueueTimer? _hoverTimer;
    private Action? _hoverWork;
    private string? _hovered;
    private string? _previewId;
    private bool _covered;
    private bool _takesKey = true;
    private bool _buttonWasDown;
    private long _lastActivity;
    private long _outsideSince;
    private (int X, int Y) _lastCursor;
    private Windows.Win32.Foundation.HWND _previous;

    public string ScreenName => _screen.Name;

    /// <summary>这块屏的整块（物理像素）。</summary>
    public RectD ScreenFrame => _screenPixels;

    public string? OpenId => _state.OpenId;

    public bool IsExpanded => _state.IsExpanded;

    public NoteDeckState State => _state;

    public NoteDeckOptions Options => _options;

    public NoteDeckEdge Edge => _edge;

    public string? Hovered => _hovered;

    /// <summary>右键菜单正开着：这一列不收（不算没动静、鼠标出了热区也不算走了）。</summary>
    public bool MenuOpen { get; set; }

    private static NoteStore? Store => NoteStore.Instance;

    private static long Now => Environment.TickCount64;

    public bool ContainsScreenPoint(int x, int y)
        => x >= _screenPixels.X && x < _screenPixels.Right && y >= _screenPixels.Y && y < _screenPixels.Bottom;

    // ---- 这一列 ----

    /// <summary>没归档、没删的全部，按顺序。</summary>
    public IReadOnlyList<Note> Notes => Store?.Book.Active ?? (IReadOnlyList<Note>)Array.Empty<Note>();

    /// <summary>画出来的标签：平时最多 FanLimit 张，点了「+N」是全部。</summary>
    public IReadOnlyList<Note> Tabs => _state.ShowsAll ? Notes : Notes.Take(NoteDeckLayout.FanLimit).ToList();

    public NoteDeckLayout Layout()
    {
        var tabs = Tabs;
        var hidden = Notes.Count - tabs.Count;
        var longest = 0.0;
        if (NoteDeckLayout.MeasuresLongest(tabs.Count, hidden, _panel.Height, _options))
        {
            var font = new NoteDeckMetrics(_options.Size.Scale()).FontSize;
            longest = tabs.Select(note => NoteDeckLabel.Length(Store!.Book.SummaryOf(note).Title, run => NoteDeckColumnWindow.Advance(run, font)))
                .DefaultIfEmpty(0).Max();
        }

        _layout = new NoteDeckLayout(tabs.Count, hidden, longest, _panel.Height, _options);
        return _layout;
    }

    /// <summary>上次排的（每 150 ms 看鼠标时用，不重新量字）。</summary>
    private NoteDeckLayout CurrentLayout => _layout ?? Layout();

    public double ColumnTop(NoteDeckLayout layout) => NoteDeckLayout.ColumnTop(_pillCenter, layout.ColumnHeight, _panel.Height);

    private (double Width, double Height) NoteSize(NoteDeckLayout layout)
        => NoteDeckLayout.NoteSize(_options.NoteSize.Dimensions(), (_panel.Width, _panel.Height), layout.TabWidth);

    /// <summary>打开的便签的顶离面板顶多远：打开那一刻定住（对着它自己那张标签；不在这一列里就对着药丸）。</summary>
    private double NoteTop(NoteDeckLayout layout)
    {
        if (_openTop is { } top)
        {
            return top;
        }

        var tabs = Tabs;
        var index = tabs.ToList().FindIndex(note => note.Id == _state.OpenId);
        var center = index >= 0 ? ColumnTop(layout) + layout.TabCenter(index) : _pillCenter;
        return NoteDeckLayout.NoteTop(center, NoteSize(layout).Height, _panel.Height);
    }

    /// <summary>DIP（这块屏的）→ 物理像素。</summary>
    public RectInt32 Pixels(RectD rect)
        => new(
            (int)Math.Round(rect.X * _scale), (int)Math.Round(rect.Y * _scale),
            Math.Max((int)Math.Round(rect.Width * _scale), 1), Math.Max((int)Math.Round(rect.Height * _scale), 1));

    public double Scale => _scale;

    // ---- 摆放 ----

    /// <summary>摆到这块屏的这条边（设置、屏幕、便签条数变了都重摆一遍）。只摆窗口，不拿键盘。</summary>
    public void Place(NoteDeckScreen screen, double scale, NoteDeckEdge edge, NoteDeckOptions options)
    {
        _scale = scale;
        _screenPixels = screen.Frame;
        _screen = Dip(screen, scale);
        var count = Notes.Count;
        var pill = NoteDeckLayout.PillFrame(_screen, edge, count, options);
        var panel = NoteDeckLayout.PanelFrame(_screen, edge, options);
        var resized = panel != _panel || options.NoteSize != _options.NoteSize || options.Size != _options.Size || edge != _edge;
        _edge = edge;
        _panel = panel;
        _pillCenter = pill.Y + pill.Height / 2 - panel.Y;
        var always = options.AlwaysFanned != _state.AlwaysFanned;
        _options = options;
        if (options.AlwaysFanned)
        {
            _pill?.Close();
            _pill = null;
        }
        else
        {
            _pill ??= new NoteDeckPillWindow(this);
            _pill.Update(Pixels(pill), Notes.Select(note => note.Color).ToList(), options.HidesPill);
        }

        if (always)
        {
            var old = _state;
            _state.SetAlwaysFanned(options.AlwaysFanned);
            Transitioned(old);
        }

        if (resized && _state.OpenId is not null)
        {
            _openTop = null;
            _openTop = NoteTop(Layout());
        }

        Render();
    }

    /// <summary>按住 Alt 拖着的时候：只挪药丸，松手才写设置、整个重摆。</summary>
    public void MovePill(NoteDeckScreen screen, double scale, NoteDeckEdge edge, NoteDeckOptions options)
    {
        var frame = NoteDeckLayout.PillFrame(Dip(screen, scale), edge, Notes.Count, options);
        _pill?.Move(new RectInt32(
            (int)Math.Round(frame.X * scale), (int)Math.Round(frame.Y * scale),
            Math.Max((int)Math.Round(frame.Width * scale), 1), Math.Max((int)Math.Round(frame.Height * scale), 1)));
    }

    private static NoteDeckScreen Dip(NoteDeckScreen screen, double scale)
        => new(screen.Name, Divide(screen.Frame, scale), Divide(screen.WorkArea, scale));

    private static RectD Divide(RectD rect, double scale) => new(rect.X / scale, rect.Y / scale, rect.Width / scale, rect.Height / scale);

    /// <summary>仓库里的便签变了：打开着的那条没了就关；预览卡指着的那条没了也收；标签跟着重画。</summary>
    public void StoreChanged()
    {
        if (_state.OpenId is { } open && Store?.Book.Find(open) is not { IsActive: true })
        {
            Send(NoteDeckEvent.Close);
        }

        if (_previewId is { } preview && Tabs.All(note => note.Id != preview))
        {
            SetPreview(null);
        }

        Render();
    }

    /// <summary>这块屏不放了：都收掉。</summary>
    public void Close()
    {
        Store?.Flush();
        StopWatching();
        _hoverTimer?.Stop();
        _sheet?.CloseQuietly();
        _sheet = null;
        _column?.Close();
        _column = null;
        _preview?.Close();
        _preview = null;
        _pill?.Close();
        _pill = null;
    }

    /// <summary>别的程序全屏盖住了这块屏：药丸收起、扇着的收回；不盖了再露出来。</summary>
    public void SetCovered(bool covered)
    {
        if (_covered == covered)
        {
            return;
        }

        _covered = covered;
        if (covered)
        {
            Send(NoteDeckEvent.Suspend(closesOpen: false));
        }

        UpdatePill();
    }

    public void Suspend(NoteDeck.Suspension kind)
        => Send(NoteDeckEvent.Suspend(kind switch
        {
            NoteDeck.Suspension.KeepsOpen => false,
            NoteDeck.Suspension.UnlessPinned => Current?.IsPinned != true,
            _ => true,
        }));

    public void Yield() => Send(NoteDeckEvent.Yield(Current?.IsPinned ?? false));

    private Note? Current => _state.OpenId is { } id ? Store?.Book.Find(id) : null;

    // ---- 状态 ----

    public void Send(NoteDeckEvent e)
    {
        var old = _state;
        if (_state.Handle(e))
        {
            Transitioned(old);
        }
    }

    private void Transitioned(NoteDeckState old)
    {
        if (old.OpenId != _state.OpenId)
        {
            _openTop = null;
            if (_state.OpenId is not null)
            {
                _openTop = NoteTop(Layout());
            }

            if (old.OpenId is { } closed)
            {
                Store?.Left(closed);
            }
        }

        if (_state.Phase != NoteDeckPhase.Fanned)
        {
            ClearHover();
        }

        var effects = NoteDeckState.EffectsOf(old, _state);
        if (effects.HasFlag(NoteDeckEffects.Flush))
        {
            Store?.Flush();
        }

        if (effects.HasFlag(NoteDeckEffects.Expand))
        {
            NoteDeck.Expanding(this);
        }

        var sheetHadKey = _sheet?.HasKey == true;
        if (effects.HasFlag(NoteDeckEffects.Hide) || effects.HasFlag(NoteDeckEffects.ReleaseKey))
        {
            _sheet?.HideQuietly();
            if (sheetHadKey && _previous != default)
            {
                Foreground.Restore(_previous);
            }

            _previous = default;
        }

        if (effects.HasFlag(NoteDeckEffects.Focus) && _state.OpenId is { } id)
        {
            OpenSheet(id);
        }
        else if (_state.Phase == NoteDeckPhase.Open && _state.OpenId is { } same)
        {
            // 换了设置、大小：位置跟上
            _sheet?.Place(Pixels(SheetFrame()), same);
        }

        if (_state.Phase == NoteDeckPhase.Rest)
        {
            StopWatching();
            _column?.Hide();
            _preview?.Hide();
            IdleReclaimer.Schedule();
        }
        else
        {
            StartWatching();
        }

        UpdatePill();
        Render();
    }

    private void UpdatePill() => _pill?.SetShown(_state.Phase == NoteDeckPhase.Rest && !_covered);

    /// <summary>重画标签列（扇着、开着时露出来）、摆预览卡。</summary>
    private void Render()
    {
        if (_state.Phase == NoteDeckPhase.Rest || _covered)
        {
            _column?.Hide();
            return;
        }

        var layout = Layout();
        var top = ColumnTop(layout);
        var frame = NoteDeckLayout.ColumnFrame(_panel, _edge, top, layout.ColumnHeight, layout.TabWidth);
        _column ??= new NoteDeckColumnWindow(this);
        _column.Render(layout, Pixels(frame));
        if (_previewId is { } preview && Store?.Book.Find(preview) is { } note)
        {
            var index = Tabs.ToList().FindIndex(item => item.Id == preview);
            var center = top + (index >= 0 ? layout.TabCenter(index) : 0);
            var y = Math.Clamp(_panel.Y + center - NoteDeckLayout.PreviewHeight / 2, _panel.Y, _panel.Bottom - NoteDeckLayout.PreviewHeight);
            var x = _edge == NoteDeckEdge.Right
                ? frame.X - NoteDeckLayout.PreviewGap - NoteDeckLayout.PreviewWidth
                : frame.Right + NoteDeckLayout.PreviewGap;
            _preview ??= new NoteDeckPreviewWindow(this);
            _preview.Show(note, Pixels(new RectD(x, y, NoteDeckLayout.PreviewWidth, NoteDeckLayout.PreviewHeight)));
        }
        else
        {
            _preview?.Hide();
        }
    }

    private RectD SheetFrame(NoteDeckLayout? layout = null)
    {
        layout ??= CurrentLayout;
        return NoteDeckLayout.NoteFrame(_panel, _edge, NoteTop(layout), NoteSize(layout), layout.TabWidth);
    }

    private void OpenSheet(string id)
    {
        var foreground = Foreground.Get();
        if (_takesKey && !Foreground.IsOurs(foreground))
        {
            _previous = foreground;
        }

        _sheet ??= new NoteDeckSheetWindow(this);
        _sheet.Place(Pixels(SheetFrame()), id);
        _sheet.Present(_takesKey);
    }

    // ---- 标签上的动作（标签列的窗口调）----

    /// <summary>点了一张标签：打开它；打开着的就是它 = 关（回到扇出）。它正浮在屏幕上：把浮着的那张叫到前面。</summary>
    public void TapTab(string id)
    {
        Activity();
        if (NoteFloats.IsFloating(id))
        {
            NoteFloats.Float(id, from: null, dragging: false);
            return;
        }

        Send(NoteDeckEvent.Tab(id));
    }

    /// <summary>鼠标进出一张标签：停一会儿出预览卡（「悬停即打开」开着时是打开），离开一会儿收。</summary>
    public void Hover(string id, bool inside)
    {
        if (_state.Phase != NoteDeckPhase.Fanned)
        {
            return;
        }

        Activity();
        if (!inside)
        {
            if (_hovered != id)
            {
                return;
            }

            _hovered = null;
            if (_previewId is not null)
            {
                After(PreviewLinger, () => SetPreview(null));
            }
            else
            {
                _hoverTimer?.Stop();
            }

            return;
        }

        if (!NoteDeck.CanFan())
        {
            return;
        }

        _hovered = id;
        if (_options.OpensOnHover)
        {
            After(HoverOpenDelay, () => OpenFromHover(id));
        }
        else if (_options.ShowsPreview && _previewId != id)
        {
            After(PreviewDelay, () => SetPreview(id));
        }
        else
        {
            _hoverTimer?.Stop();
        }
    }

    /// <summary>悬停够久了：打开，但不拿键盘（点进正文才拿）。浮在屏幕上的那条不开。</summary>
    private void OpenFromHover(string id)
    {
        if (!NoteDeck.CanFan() || _state.Phase != NoteDeckPhase.Fanned || NoteFloats.IsFloating(id))
        {
            return;
        }

        _takesKey = false;
        try
        {
            Send(NoteDeckEvent.Tab(id));
        }
        finally
        {
            _takesKey = true;
        }
    }

    /// <summary>鼠标进出预览卡：停在卡上就不收。</summary>
    public void HoverPreview(bool inside)
    {
        Activity();
        _hoverTimer?.Stop();
        if (!inside && _previewId is not null)
        {
            After(PreviewLinger, () => SetPreview(null));
        }
    }

    private void SetPreview(string? id)
    {
        if (_previewId == id)
        {
            return;
        }

        _previewId = id;
        Activity();
        Render();
    }

    private void ClearHover()
    {
        _hoverTimer?.Stop();
        _hovered = null;
        if (_previewId is not null)
        {
            _previewId = null;
            _preview?.Hide();
        }
    }

    private void After(TimeSpan delay, Action work)
    {
        _hoverWork = work;
        if (_hoverTimer is null)
        {
            _hoverTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
            _hoverTimer.IsRepeating = false;
            _hoverTimer.Tick += (_, _) =>
            {
                if (_state.Phase == NoteDeckPhase.Fanned)
                {
                    _hoverWork?.Invoke();
                }
            };
        }

        _hoverTimer.Stop();
        _hoverTimer.Interval = delay;
        _hoverTimer.Start();
    }

    /// <summary>拖动排序开始 / 结束（标签列的窗口调；落到第几格由它按 DragTarget 算好）。</summary>
    public void DragBegan()
    {
        ClearHover();
        Send(NoteDeckEvent.DragBegan);
    }

    public void DragEnded(string id, int from, int target)
    {
        Send(NoteDeckEvent.DragEnded);
        if (target != from)
        {
            Store?.Move(id, target);
        }
    }

    /// <summary>「+」：建一条（有本机建的空白便签就用它）并在这叠里打开。</summary>
    public void Create()
    {
        if (Store is { } store)
        {
            Send(NoteDeckEvent.Created(store.BlankOrNew().Id));
        }
    }

    /// <summary>鼠标进了药丸 / 点了药丸。altDown：按着 Alt（要拖药丸，不扇出）。</summary>
    public void PillEntered(bool altDown)
    {
        if (_covered)
        {
            return;
        }

        Send(NoteDeckEvent.PillEntered(altDown, NoteDeck.CanFan()));
        Activity();
    }

    /// <summary>有动静（4 秒没动静才收回）。</summary>
    public void Activity() => _lastActivity = Now;

    // ---- 打开的便签（它的窗口调）----

    /// <summary>键盘关（Esc、Ctrl+W）= 连那一列一起收回；鼠标关（关闭钮）= 回到那一列。</summary>
    public void CloseSheet(bool byKeyboard) => Send(byKeyboard ? NoteDeckEvent.Dismiss : NoteDeckEvent.Close);

    /// <summary>打开的便签失去了前台（点了别处）：没固定的收起。</summary>
    public void SheetDeactivated()
    {
        if (_state.Phase == NoteDeckPhase.Open)
        {
            Send(NoteDeckEvent.ClickedOutside(Current?.IsPinned ?? false));
        }
    }

    /// <summary>浮到屏幕上（操作菜单的「浮在屏幕上」、按住头部拖出去）：从它现在的位置浮出去，这叠里的收掉（NoteFloats.Float 里 Release）。</summary>
    public void FloatOpen(bool dragging)
    {
        if (_state.OpenId is not { } id || _sheet is null)
        {
            return;
        }

        // 键盘交给浮出去的那张，不还给原来的程序（还回去再抢回来会被系统的前台锁拦住）
        _previous = default;
        NoteFloats.Float(id, from: _sheet.Frame, dragging);
    }

    // ---- 看着：离开热区、4 秒没动静、没拿键盘的便签点了别处 ----

    private void StartWatching()
    {
        if (_watch is null)
        {
            _watch = DispatcherQueue.GetForCurrentThread().CreateTimer();
            _watch.Interval = WatchInterval;
            _watch.Tick += (_, _) => Watch();
        }

        if (!_watch.IsRunning)
        {
            _lastActivity = Now;
            _outsideSince = 0;
            _buttonWasDown = true;
            _watch.Start();
        }
    }

    private void StopWatching() => _watch?.Stop();

    private void Watch()
    {
        if (_state.Phase == NoteDeckPhase.Rest)
        {
            StopWatching();
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        if ((cursor.X, cursor.Y) != _lastCursor)
        {
            _lastCursor = (cursor.X, cursor.Y);
            if (IsInside(cursor.X, cursor.Y))
            {
                Activity();
            }
        }

        var inside = IsInside(cursor.X, cursor.Y);
        var now = Now;
        if (_state.Phase == NoteDeckPhase.Fanned && !MenuOpen && !_state.IsDragging)
        {
            if (inside)
            {
                _outsideSince = 0;
            }
            else if (_outsideSince == 0)
            {
                _outsideSince = now;
            }
            else if (now - _outsideSince >= (long)NoteDeckState.LeaveDelay.TotalMilliseconds)
            {
                Send(NoteDeckEvent.Left);
                return;
            }

            if (now - _lastActivity >= (long)NoteDeckState.IdleDelay.TotalMilliseconds)
            {
                Send(NoteDeckEvent.Idle);
                return;
            }
        }

        // 悬停打开的（没拿键盘）：失去前台的事件来不了，这里看左键在别处按下
        var down = (GetAsyncKeyState(0x01 /* VK_LBUTTON */) & 0x8000) != 0;
        if (_state.Phase == NoteDeckPhase.Open && _sheet?.HasKey != true && down && !_buttonWasDown && !inside)
        {
            SheetDeactivated();
        }

        _buttonWasDown = down;
    }

    /// <summary>鼠标在热区（标签列四周 20、预览卡出着时连它）、药丸、打开的便签上。物理像素。</summary>
    private bool IsInside(int x, int y)
    {
        var point = new PointD(x / _scale, y / _scale);
        var layout = CurrentLayout;
        var zone = NoteDeckLayout.HotZone(_panel, _edge, ColumnTop(layout), layout.ColumnHeight, layout.TabWidth, _previewId is not null);
        if (NoteGeometry.Contains(zone, point))
        {
            return true;
        }

        return _state.Phase == NoteDeckPhase.Open && NoteGeometry.Contains(SheetFrame(layout), point);
    }

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int key);
}
