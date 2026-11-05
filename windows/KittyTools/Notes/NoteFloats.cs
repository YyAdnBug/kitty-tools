// 浮动便签（PLAN-v13 第 6 批，照 mac Notes/NoteFloat.swift + NoteFloatPanel.swift + NoteFloats.swift；规则在 Core 的 NoteFloatLayout / NoteFloatSet）：
// - 一张一扇窗：没有标题栏、系统边框能拉大小、置顶、不进 Alt+Tab；里面画的是 NoteSheetView（和那叠、全部便签窗口同一套）。
//   要打字，所以点了会拿前台（Windows 没有「当键盘焦点又不激活」）；Esc / Ctrl+W 收回（只收这一张）。
// - 同时最多 5 张（NoteFloatSet.Limit）：再浮一张时最久没碰的那张收回边缘（轻提示说是哪张）；按菜单浮出来的和已经浮着的错开 24 往右下
//   （NoteFloatLayout.Cascaded），从那叠里拖出来的就落在鼠标那儿。
// - 按住头部空白处拖 = 系统的挪窗口（WM_NCLBUTTONDOWN + HTCAPTION，同标题栏）；松手后夹进那块屏的工作区（Settled）。
// - **固定着的每一张重启后回到原处**（NotesFloatPlaces，这台电脑自己的状态，不导出）；拉过的大小记在 NotesFloatSize。
// 坐标一律物理像素（屏幕的整块、工作区都是）；尺寸是 DIP × 那块屏的缩放。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using Windows.Win32;

namespace KittyTools;

internal static partial class NoteFloats
{
    private static readonly Dictionary<string, NoteFloatWindow> Windows = new(StringComparer.Ordinal);
    private static List<string> _order = new();

    public static bool IsFloating(string id) => Windows.ContainsKey(id);

    public static IReadOnlyCollection<string> Floating => Windows.Keys;

    /// <summary>屏幕们（物理像素）。</summary>
    public static List<NoteDeckScreen> Screens()
        => Displays.All().Select(display => new NoteDeckScreen(
            display.Name,
            new RectD(display.Bounds.Left, display.Bounds.Top, display.Bounds.Width, display.Bounds.Height),
            new RectD(display.Work.Left, display.Work.Top, display.Work.Width, display.Work.Height))).ToList();

    /// <summary>浮着就收回，没浮就浮出来（菜单、工具栏的「浮在屏幕上 / 收回边缘」）。</summary>
    public static void Toggle(string id)
    {
        if (IsFloating(id))
        {
            Tuck(id);
        }
        else
        {
            Float(id, from: null, dragging: false);
        }
    }

    /// <summary>浮出来。from：从那叠里拖出来时它原来的位置（物理像素，落在鼠标那儿）；null = 按菜单浮出来（错开摆）。
    /// dragging：按着鼠标拖出来的（接着交给系统挪窗口）。</summary>
    public static void Float(string id, RectD? from, bool dragging)
    {
        if (NoteStore.Instance?.Book.Find(id) is not { } note || !NoteFloatLayout.Floats(note))
        {
            return;
        }

        if (Windows.TryGetValue(id, out var existing))
        {
            existing.Activate();
            _order = NoteFloatSet.Touched(_order, id);
            return;
        }

        NoteDeck.Release(id);
        var screens = Screens();
        PInvoke.GetCursorPos(out var cursor);
        var pointer = new PointD(cursor.X, cursor.Y);
        var display = Displays.AtPoint(cursor.X, cursor.Y);
        var scale = display.Scale <= 0 ? 1 : display.Scale;
        var stored = NoteFloatLayout.StoredSize(SettingsService.Current.NotesFloatSize,
            NoteDeckOptions.Read(noteSize: SettingsService.Current.NotesDeckNoteSize).NoteSize.Dimensions());
        var size = (stored.Width * scale, stored.Height * scale);
        RectD frame;
        if (from is { } sheet)
        {
            frame = NoteFloatLayout.Settled(new RectD(sheet.X, sheet.Y, size.Item1, size.Item2), pointer, screens);
        }
        else
        {
            var visible = screens.FirstOrDefault(screen => Contains(screen.Frame, pointer)).WorkArea;
            if (visible.Width <= 0)
            {
                visible = screens[0].WorkArea;
            }

            var start = new RectD(
                visible.X + (visible.Width - size.Item1) / 2, visible.Y + (visible.Height - size.Item2) / 3, size.Item1, size.Item2);
            var others = Windows.Values.Select(window => window.Frame).ToList();
            frame = NoteFloatLayout.Cascaded(start, others, visible, step: 24 * scale);
        }

        var (order, evicted) = NoteFloatSet.Admitted(_order, id);
        _order = order;
        foreach (var old in evicted)
        {
            if (NoteStore.Instance?.Book.Find(old) is { } gone)
            {
                var (title, detail) = NoteFloatSet.EvictionNotice(gone.DisplayTitle);
                NoticeHost.Show(title, detail, NoticeTone.Normal);
            }

            Tuck(old);
        }

        var window = new NoteFloatWindow(id);
        Windows[id] = window;
        window.Place(frame);
        window.Activate();
        window.Sheet.FocusBody();
        if (dragging)
        {
            window.BeginMove();
        }

        Remember(id);
        NoteDeck.Refresh();
    }

    /// <summary>收回（关掉这一张的窗口；那叠里照旧有它）。</summary>
    public static void Tuck(string id)
    {
        if (!Windows.Remove(id, out var window))
        {
            return;
        }

        _order.Remove(id);
        NoteStore.Instance?.Flush();
        window.CloseQuietly();
        Forget(id);
        NoteStore.Instance?.Left(id);
        NoteDeck.Refresh();
    }

    /// <summary>便签被归档、删了：浮着的那张收回（mac 浮动便签跟着仓库变）。</summary>
    public static void Prune()
    {
        if (NoteStore.Instance is not { } store)
        {
            return;
        }

        foreach (var id in Windows.Keys.ToList())
        {
            if (!NoteFloatLayout.Floats(store.Book.Find(id)))
            {
                Tuck(id);
            }
            else
            {
                Remember(id);
            }
        }
    }

    public static void Touch(string id) => _order = NoteFloatSet.Touched(_order, id);

    /// <summary>便签功能关了 / 退出：全部收起（固定着的位置留着，下次回来）。</summary>
    public static void CloseAll()
    {
        foreach (var window in Windows.Values.ToList())
        {
            window.CloseQuietly();
        }

        Windows.Clear();
        _order.Clear();
    }

    /// <summary>启动时：固定着的每一张回到原处（不拿键盘）。</summary>
    public static void RestoreAtLaunch()
    {
        if (NoteStore.Instance is not { } store || !Features.IsOn(Feature.Notes))
        {
            return;
        }

        var screens = Screens();
        var restored = 0;
        foreach (var place in NoteFloatSet.Restorable(SettingsService.Current.NotesFloatPlaces))
        {
            if (restored >= NoteFloatSet.Limit)
            {
                break;
            }

            if (NoteFloatLayout.Restored(place, store.Book.Find(place.Id), screens) is not { } frame || Windows.ContainsKey(place.Id))
            {
                continue;
            }

            var window = new NoteFloatWindow(place.Id);
            Windows[place.Id] = window;
            _order.Add(place.Id);
            window.Place(frame);
            window.ShowInactive();
            restored++;
        }
    }

    /// <summary>记下这一张在哪（固定着才记；没固定就把记着的删掉）、拉过的大小。</summary>
    public static void Remember(string id)
    {
        if (!Windows.TryGetValue(id, out var window) || NoteStore.Instance?.Book.Find(id) is not { } note)
        {
            return;
        }

        var screens = Screens();
        var frame = window.Frame;
        var center = new PointD(frame.X + frame.Width / 2, frame.Y + frame.Height / 2);
        var display = NoteFloatLayout.Display(frame, center, screens);
        var place = NoteFloatLayout.Remembered(id, false, note, frame, display);
        var list = (SettingsService.Current.NotesFloatPlaces ?? new List<Dictionary<string, string>>())
            .Where(item => !item.TryGetValue("id", out var stored) || stored != id).ToList();
        if (place is { } value)
        {
            list.Add(value.ToStored());
        }

        var scale = Displays.AtPoint((int)center.X, (int)center.Y).Scale;
        var size = NoteFloatLayout.SizeText((frame.Width / scale, frame.Height / scale));
        var settings = SettingsService.Current;
        // 没变就不存：Prune 跟着仓库每变一次都来一趟（打一个字一次），每次都写设置文件、发「设置变了」太重（PLAN-v13 复查）
        if (SamePlaces(settings.NotesFloatPlaces, list) && settings.NotesFloatSize == size)
        {
            return;
        }

        settings.NotesFloatPlaces = list.Count == 0 ? null : list;
        settings.NotesFloatSize = size;
        SettingsService.Save();
    }

    private static bool SamePlaces(List<Dictionary<string, string>>? stored, List<Dictionary<string, string>> next)
    {
        if ((stored?.Count ?? 0) != next.Count)
        {
            return false;
        }

        for (var index = 0; index < next.Count; index++)
        {
            var a = stored![index];
            var b = next[index];
            if (a.Count != b.Count || a.Any(pair => !b.TryGetValue(pair.Key, out var value) || value != pair.Value))
            {
                return false;
            }
        }

        return true;
    }

    private static void Forget(string id)
    {
        if (SettingsService.Current.NotesFloatPlaces is not { } list)
        {
            return;
        }

        list.RemoveAll(item => item.TryGetValue("id", out var stored) && stored == id);
        SettingsService.Current.NotesFloatPlaces = list.Count == 0 ? null : list;
        SettingsService.Save();
    }

    private static bool Contains(RectD rect, PointD point)
        => point.X >= rect.X && point.X < rect.X + rect.Width && point.Y >= rect.Y && point.Y < rect.Y + rect.Height;
}

/// <summary>一张浮动便签的窗口。</summary>
internal sealed partial class NoteFloatWindow : Window
{
    private readonly string _id;
    private readonly IntPtr _hwnd;
    private bool _closing;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _settle;

    public NoteFloatWindow(string id)
    {
        _id = id;
        Title = Paths.ProductName + " 便签";
        ExtendsContentIntoTitleBar = true;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = true;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Sheet = new NoteSheetView(new NoteSheetView.Host
        {
            Close = _ => NoteFloats.Tuck(_id),
            ToggleFloating = () => NoteFloats.Tuck(_id),
            IsFloating = () => true,
            GripPressed = _ => BeginMove(),
        });
        Content = new Microsoft.UI.Xaml.Controls.Grid { RequestedTheme = Theme.ElementTheme, Children = { Sheet.View } };
        Sheet.Show(id);
        AppWindow.Closing += (_, args) =>
        {
            if (!_closing)
            {
                args.Cancel = true;
                NoteFloats.Tuck(_id);
            }
        };
        AppWindow.Changed += (_, args) =>
        {
            if (args.DidPositionChange || args.DidSizeChange)
            {
                ScheduleSettle();
            }
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated)
            {
                NoteFloats.Touch(_id);
            }
            else
            {
                NoteStore.Instance?.Flush();
            }
        };
    }

    public NoteSheetView Sheet { get; }

    public RectD Frame => new(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);

    public void Place(RectD frame)
    {
        var minimum = NoteFloatLayout.MinSize;
        var scale = Displays.AtPoint((int)frame.X + 1, (int)frame.Y + 1).Scale;
        AppWindow.MoveAndResize(new RectInt32(
            (int)Math.Round(frame.X), (int)Math.Round(frame.Y),
            (int)Math.Round(Math.Max(frame.Width, minimum.Width * scale)),
            (int)Math.Round(Math.Max(frame.Height, minimum.Height * scale))));
    }

    /// <summary>重启后回到原处的那几张：露出来，不拿键盘。</summary>
    public void ShowInactive() => AppWindow.Show(activateWindow: false);

    /// <summary>按住头部 = 系统的挪窗口（同按住标题栏）。</summary>
    public void BeginMove()
    {
        ReleaseCapture();
        SendMessage(_hwnd, 0x00A1 /* WM_NCLBUTTONDOWN */, 2 /* HTCAPTION */, IntPtr.Zero);
    }

    /// <summary>挪完 / 拉完大小停手 300 ms：夹进那块屏的工作区，记下位置和大小。</summary>
    private void ScheduleSettle()
    {
        if (_closing)
        {
            return;
        }

        _settle ??= CreateSettleTimer();
        _settle.Stop();
        _settle.Start();
    }

    private Microsoft.UI.Dispatching.DispatcherQueueTimer CreateSettleTimer()
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(300);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_closing)
            {
                return;
            }

            PInvoke.GetCursorPos(out var cursor);
            var settled = NoteFloatLayout.Settled(Frame, new PointD(cursor.X, cursor.Y), NoteFloats.Screens());
            if (Math.Abs(settled.X - Frame.X) > 0.5 || Math.Abs(settled.Y - Frame.Y) > 0.5)
            {
                Place(settled);
            }

            NoteFloats.Remember(_id);
        };
        return timer;
    }

    public void CloseQuietly()
    {
        _closing = true;
        _settle?.Stop();
        Close();
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ReleaseCapture();

    [LibraryImport("user32.dll", EntryPoint = "SendMessageW")]
    private static partial IntPtr SendMessage(IntPtr hwnd, uint message, nint wParam, IntPtr lParam);
}
