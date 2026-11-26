// 屏幕边缘那叠的四扇窗（PLAN-v13 第 6 批，照 mac Notes/NoteDeckPill.swift + NoteDeckView.swift + NoteDeckPanel.swift；逻辑在 NoteDeck.cs 的 NoteDeckBay）：
// - 药丸：贴边隔 1 的一小条，12 宽（PLAN-v16 V1：没有系统边框，圆角交给 DWM，亚克力底；不拿前台、置顶、不进 Alt+Tab），一条便签一道色块，
//   超过 14 条合成一道；感应范围另由一条看不见的窗口管（NoteDeckSense，压在药丸下面）。鼠标进来 / 点一下扇出，按住 Alt 拖 = 换边、换高度。
//   「不显示药丸」时药丸收起、只留那条看不见的感应条（同 mac）。
// - 标签列：一张接一张往下压的纸色标签（标题竖排：中日韩文字正着、别的整段转 90°，排不下截断加「…」），「+N」展开全部、「+」新建；
//   点一张打开、停一会儿出预览卡、按着上下拖排序；右键标签 = 这条的操作，右键空白处 / 「+」/ 药丸 = 新建便签、全部便签、设置…。
// - 预览卡：标签旁边的一张小纸（标题 + 开头几行），鼠标挪上去不收、点它打开。
// - 打开的便签：挨着标签列，里面是 NoteSheetView（同全部便签窗口、浮动便签）。要打字，所以拿前台；失去前台 = 点了别处（没固定的收起）。
//   按住头部空白处往外拖过一段 = 浮到屏幕上（NoteFloats，接着由系统挪窗口）。
// 只用到系统画的东西：圆角、阴影是 DWM 的（药丸和标签列用 NoteDeckUi.Shell；预览卡、打开的便签用系统边框的外壳），都不要 DWM 那圈细边框
// （NoteDeckUi.NoOutline，同 mac 没有描边），菜单是 MenuFlyout。
// 动效（R108，照 mac NoteDeckView）：标签一张接一张从边外滑出来、收回时一起滑回去淡掉，标签斜 3°（打开的那张立正、探出 8，停着 / 拖着的探出 4），
// 拖动排序时别的让位，打开的便签从边缘那侧滑出来、淡入，它自己带着一张标签（NoteSheetView 的 TabSide），预览卡里的字从边那侧偏 8 淡入（snap）。**窗口都不挪**：每扇窗摆在动画的终点，
// 动的是里面的内容（NoteMotion，Composition，合成器线程上跑）——窗口的外缘就是工作区的边，标签从外缘之外滑进来，看上去就是从屏幕边上出来。
// 不按显示器刷新挪窗口：滑到工作区外会压到任务栏 / 隔壁那块屏，每帧 SetWindowPos 在主线程上，打开便签那一下主线程正排正文，最容易掉帧。
// 代价：标签列那扇窗（亚克力）一露出来就是整条，标签随后滑进来；打开的便签、预览卡那扇窗先出纸，里面的东西随后滑进来、淡入（mac 是整张纸一起）；
// 窗口退场照旧不淡出（PLAN-v7 §1）。
using System.Numerics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.UI;
using Windows.Win32;

namespace KittyTools;

/// <summary>几扇窗共用的小件。</summary>
internal static partial class NoteDeckUi
{
    public static Color Rgb(int rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    public static SolidColorBrush Brush(int rgb) => new(Rgb(rgb));

    public static NoteTone Tone(Note note) => NotePaper.Of(note).Tone(Theme.EffectiveTheme == ElementTheme.Dark);

    /// <summary>不拿前台的窗口里读不到这条线程的键盘状态，按键一律看系统的。</summary>
    public static bool KeyDown(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    public static Grid Root() => new() { Background = new SolidColorBrush(Colors.Transparent), RequestedTheme = Theme.ElementTheme };

    /// <summary>一段字占多长（正着放的一格按这个字的宽算——中日韩文字是方的；转着放的是这段横排的宽）。</summary>
    public static double Advance(NoteDeckLabel.Run run, double fontSize) => Measure(run.Text, fontSize).Width;

    private static Windows.Foundation.Size Measure(string text, double fontSize)
    {
        var block = new TextBlock { Text = text, FontSize = fontSize, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
        block.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return block.DesiredSize;
    }

    /// <summary>
    /// 竖排的标题（列里的标签和打开的便签带着的那张标签共用，mac NoteTabLabel）：正着放的字一字一格，别的整段转 90°（从上往下读），
    /// 排不下截断加「…」（NoteDeckLabel.Fitted）。length 是能排多长；横向居中，竖直方向和外边距由调用方定；不接鼠标。
    /// </summary>
    public static FrameworkElement Label(string title, double length, double fontSize, int ink)
    {
        var runs = NoteDeckLabel.Fitted(title, length, run => Advance(run, fontSize));
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false };
        var brush = Brush(ink);
        foreach (var run in runs)
        {
            var block = new TextBlock
            {
                Text = run.Text,
                FontSize = fontSize,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = brush,
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            if (run.IsUpright)
            {
                stack.Children.Add(block);
                continue;
            }

            // 转 90°（从上往下读）：RenderTransform 不转布局，先按横排量好，再按竖着的尺寸占位
            var size = Measure(run.Text, fontSize);
            block.RenderTransform = new RotateTransform { Angle = 90 };
            var holder = new Canvas { Width = size.Height, Height = size.Width, HorizontalAlignment = HorizontalAlignment.Center };
            Canvas.SetLeft(block, size.Height);
            holder.Children.Add(block);
            stack.Children.Add(holder);
        }

        return stack;
    }

    /// <summary>右键药丸、标签列的空白处、「+」（三处同一份）：新建便签（就在这一叠里打开）、全部便签、设置…</summary>
    public static void ShowEdgeMenu(NoteDeckBay bay, FrameworkElement anchor, Windows.Foundation.Point? at)
    {
        var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
        Add(menu.Items, NotesWindowRules.NewTitle, Glyphs.Add, bay.Create);
        Add(menu.Items, "全部便签", "\uE8A5", NotesWindow.ShowWindow);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(menu.Items, "设置…", Glyphs.Settings, () => ShellRuntime.Instance?.ShowSettings(false, "notes"));
        Show(bay, menu, anchor, at);
    }

    /// <summary>右键一张标签：这条的操作，不用先打开它（mac tabItems）：固定、颜色 ›、浮在屏幕上 / 收回边缘｜归档、删除。</summary>
    public static void ShowTabMenu(NoteDeckBay bay, Note note, FrameworkElement anchor, Windows.Foundation.Point? at)
    {
        var store = NoteStore.Instance;
        var id = note.Id;
        var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
        Add(menu.Items, NotesWindowRules.PinTitle(note), note.IsPinned ? Glyphs.Unpin : Glyphs.Pin, () => store?.SetPinned(id, !note.IsPinned));
        var colors = new MenuFlyoutSubItem { Text = NotesWindowRules.ColorTitle, Icon = new FontIcon { Glyph = "\uE790" } };
        NoteSheetView.FillColors(colors.Items, note, anchor);
        menu.Items.Add(colors);
        Add(menu.Items, NotesWindowRules.FloatTitle(NoteFloats.IsFloating(id)), "\uE8A7", () =>
        {
            if (id == bay.OpenId)
            {
                bay.FloatOpen(dragging: false);
            }
            else
            {
                NoteFloats.Toggle(id);
            }
        });
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(menu.Items, NotesWindowRules.ArchiveTitle(note), "\uE7B8", () =>
        {
            store?.SetArchived(id, true);
            NoteNotices.ShowArchived(id, note.DisplayTitle);
        });
        var delete = Add(menu.Items, NotesWindowRules.DeleteTitle, Glyphs.Delete, () =>
        {
            store?.Delete(id);
            NoteNotices.ShowDeleted(id, undoKey: false);
        });
        delete.Foreground = Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28));
        Show(bay, menu, anchor, at);
    }

    private static void Show(NoteDeckBay bay, MenuFlyout menu, FrameworkElement anchor, Windows.Foundation.Point? at)
    {
        // 菜单开着时这一列不收（不算没动静、鼠标出了热区也不算走了）；关了算一次动静
        menu.Opened += (_, _) => bay.MenuOpen = true;
        menu.Closed += (_, _) =>
        {
            bay.MenuOpen = false;
            bay.Activity();
        };
        if (at is { } point)
        {
            menu.ShowAt(anchor, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt(anchor);
        }
    }

    private static MenuFlyoutItem Add(IList<MenuFlyoutItemBase> items, string text, string glyph, Action action)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => action();
        items.Add(item);
        return item;
    }

    /// <summary>
    /// 药丸和标签列的外壳（PLAN-v16 V1）：没有系统边框和标题栏（带边框、内容伸进标题栏的窗口有系统和 WinUI 定的最小宽，
    /// 12 宽的药丸会被撑成一张小卡、三十来宽的标签列会撑到七十、往屏幕外伸）；置顶、不能改大小、不进 Alt+Tab、不抢焦点，
    /// DWM 的圆角和阴影、不要细边框（NoOutline），最小宽高放开（NoteDeckTiny）。返回窗口句柄。
    /// </summary>
    public static IntPtr Shell(Window window, bool small)
    {
        window.AppWindow.IsShownInSwitchers = false;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        window.AppWindow.SetPresenter(presenter);
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x08000000 /* WS_EX_NOACTIVATE */);
        // small：药丸只有 12 宽，DWM 的大圆角（8）超过了一半宽，用小圆角（4）；标签列用大圆角
        var round = small ? 3 /* DWMWCP_ROUNDSMALL */ : 2 /* DWMWCP_ROUND */;
        DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
        NoOutline(hwnd);
        NoteDeckTiny.Allow(hwnd);
        return hwnd;
    }

    /// <summary>
    /// 不要 DWM 在 Windows 11 上给圆角窗口画的那圈 1 像素细边框：深色下是一圈发白的线、四个角最明显（2026-11-12 用户反馈，
    /// mac 的便签没有）。圆角和阴影还在。便签的几扇窗（药丸、标签列、预览卡、打开的便签、浮动便签、快速记一条）都用。
    /// </summary>
    public static void NoOutline(IntPtr hwnd)
    {
        var none = unchecked((int)0xFFFFFFFE); // DWMWA_COLOR_NONE
        DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, ref none, sizeof(int));
    }

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int key);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);

    [LibraryImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}

/// <summary>边上的药丸。</summary>
internal sealed class NoteDeckPillWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly Grid _root;
    private readonly StackPanel _dashes;
    private readonly IntPtr _hwnd;
    private readonly IntPtr _sense;
    private RectInt32 _senseFrame;
    private bool _shown;
    private bool _hides;
    private bool _dragging;

    public NoteDeckPillWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        _hwnd = NoteDeckUi.Shell(this, small: true);
        _sense = NoteDeckSense.Create(() =>
        {
            if (!_dragging)
            {
                _bay.PillEntered(NoteDeckUi.KeyDown(0x12 /* VK_MENU */));
            }
        });
        Closed += (_, _) => NoteDeckSense.Destroy(_sense);
        _dashes = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _root = NoteDeckUi.Root();
        _root.Children.Add(_dashes);
        AutomationProperties.SetName(_root, "便签：鼠标靠过来展开，按住 Alt 拖动换位置");
        _root.PointerEntered += (_, _) =>
        {
            if (!_dragging)
            {
                _bay.PillEntered(NoteDeckUi.KeyDown(0x12 /* VK_MENU */));
            }
        };
        _root.PointerPressed += OnPressed;
        _root.PointerMoved += OnMoved;
        _root.PointerReleased += OnReleased;
        _root.PointerCaptureLost += (_, _) => _dragging = false;
        _root.RightTapped += (_, e) =>
        {
            e.Handled = true;
            NoteDeckUi.ShowEdgeMenu(_bay, _root, e.GetPosition(_root));
        };
        Content = _root;
        // 亚克力放在 Content 之后：AcrylicBackdrop 连上时按内容的 ActualTheme 定深浅、挂主题变化；先设它的话那时还没有内容，深色下也是浅的（Windows 核验 PLAN-v13）
        SystemBackdrop = new AcrylicBackdrop();
    }

    /// <summary>摆好（sense：感应范围那块，body：药丸本身，物理像素）、画上每条便签的色块（hides：不显示药丸，只留看不见的感应条）。</summary>
    public void Update(RectInt32 sense, RectInt32 body, IReadOnlyList<int> colors, bool hides)
    {
        _hides = hides;
        _senseFrame = sense;
        AppWindow.MoveAndResize(body);
        ApplyShown();
        _dashes.Children.Clear();
        if (hides)
        {
            return;
        }

        var metrics = new NoteDeckMetrics(_bay.Options.Size.Scale());
        _dashes.Spacing = metrics.DashGap;
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var shown = Math.Min(colors.Count, NoteDeckLayout.MaxDashes);
        for (var index = 0; index < shown + (colors.Count > NoteDeckLayout.MaxDashes ? 1 : 0); index++)
        {
            // 超过的那些合成一道：用灰的（mac 也是一道中性色）
            var fill = index < shown ? NotePaper.Of(colors[index]).Tone(dark).Strip : (dark ? 0x8A8A8A : 0x9A9A9A);
            _dashes.Children.Add(new Border
            {
                Width = metrics.DashWidth,
                Height = metrics.DashHeight,
                CornerRadius = new CornerRadius(metrics.DashWidth / 2),
                Background = NoteDeckUi.Brush(fill),
            });
        }
    }

    /// <summary>按住 Alt 拖着的时候：只挪（显示 / 收起不动）。</summary>
    public void Move(RectInt32 sense, RectInt32 body)
    {
        _senseFrame = sense;
        AppWindow.MoveAndResize(body);
        NoteDeckSense.Place(_sense, _senseFrame, _hwnd, _shown);
    }

    public void SetShown(bool shown)
    {
        if (shown == _shown)
        {
            return;
        }

        _shown = shown;
        ApplyShown();
    }

    private void ApplyShown()
    {
        var visible = _shown && !_hides;
        if (visible && !AppWindow.IsVisible)
        {
            AppWindow.Show(activateWindow: false);
        }
        else if (!visible && AppWindow.IsVisible)
        {
            AppWindow.Hide();
        }

        NoteDeckSense.Place(_sense, _senseFrame, _hwnd, _shown);
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(_root).Properties.IsLeftButtonPressed)
        {
            return;
        }

        if (NoteDeckUi.KeyDown(0x12 /* VK_MENU */))
        {
            _dragging = _root.CapturePointer(e.Pointer);
        }
        else
        {
            // 点一下也扇出（读屏、触屏没有「靠过来」）
            _bay.PillEntered(altDown: false);
        }

        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging)
        {
            PInvoke.GetCursorPos(out var cursor);
            NoteDeck.DragPill(_bay, cursor.X, cursor.Y, drops: false);
        }
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        _dragging = false;
        _root.ReleasePointerCapture(e.Pointer);
        PInvoke.GetCursorPos(out var cursor);
        NoteDeck.DragPill(_bay, cursor.X, cursor.Y, drops: true);
    }
}

/// <summary>
/// 扇出的那一列标签。动效（R108，照 mac NoteDeckView；做法见 NoteMotion）：这扇窗摆在终点不动、外缘贴着工作区的边，
/// 动的是里面的东西——标签从窗口外缘之外滑进来，看上去就是从屏幕边上出来的。每张标签两层：外层（slot）管出场 / 收回（左右滑、淡入淡出）
/// 和拖动排序时的让位（上下），里层那张纸管探出（打开的 8、停着 / 拖着的 4）和倾斜（3°，打开的那张立正）。
/// 这扇窗比标签宽 ColumnRoom（朝屏幕里面），装得下探出来的那一截和斜着的角；纸朝屏幕边多画出去 TiltBleed，那一截在窗口外、被裁掉。
/// </summary>
internal sealed class NoteDeckColumnWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly Grid _root;
    private readonly List<Tab> _tabs = new();
    private readonly List<FrameworkElement> _buttons = new();
    private DispatcherQueueTimer? _hideTimer;
    private bool _shown;
    private bool _concealing;

    /// <summary>这一次出场从什么时候开始（Environment.TickCount64）：出场途中整列重建时，新建的标签从这一刻算接着走（NoteDeckLayout.RevealAt）。</summary>
    private long _revealedAt;

    /// <summary>被拖的那张跟着手的位移：一个用到底，只改 Y（松手、取消时摘下来）。</summary>
    private readonly TranslateTransform _dragTransform = new();

    // 按着一张标签：哪张、按下时鼠标的纵坐标（物理像素）、拖没拖起来、让位让到第几格
    private Tab? _pressed;
    private int _startY;
    private bool _dragging;
    private int _target;
    private NoteDeckLayout? _layout;
    private double _builtStep;

    // 上次建的那一列（标签的编号、颜色、标题、排法、哪条边、深浅）：一样就不重建，只更新开着 / 浮着 / 停着这些状态（带动画）——
    // 重建会拆掉正按着的那张标签（拖动排序、按下后才出的预览卡都会让它丢掉指针），打字时标题没变也不白重建
    private string? _drawn;

    /// <summary>一张标签：外层 slot、里层的纸、朝里那条边上的竖条（开着 / 浮着），和它现在让到哪、探出多少、斜多少、鼠标在不在上面。</summary>
    private sealed class Tab(string id, int index, Grid slot, Border paper, Border mark)
    {
        public string Id { get; } = id;
        public int Index { get; } = index;
        public Grid Slot { get; } = slot;
        public Border Paper { get; } = paper;
        public Border Mark { get; } = mark;
        public double Shift { get; set; }
        public double Reach { get; set; } = double.NaN;
        public double Tilt { get; set; } = double.NaN;
        public bool Hovered { get; set; }
    }

    public NoteDeckColumnWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        // 一列标签只有三十来宽：用带边框的外壳（HudFrame）时窗口被撑到七十（以前一百三十六）、往屏幕外伸，居中的标签整列落到屏幕外面，
        // 边上只剩一块空的亚克力（2026-11-08 用户反馈「便签看不到、点不了」）
        NoteDeckUi.Shell(this, small: false);
        _root = NoteDeckUi.Root();
        _root.RightTapped += (_, e) =>
        {
            if (!e.Handled)
            {
                e.Handled = true;
                NoteDeckUi.ShowEdgeMenu(_bay, _root, e.GetPosition(_root));
            }
        };
        _root.PointerMoved += (_, _) => _bay.Activity();
        // 快捷键叫出来时（PLAN-v26 N5）：这一列拿键盘，↑↓ / Enter / Esc 交给 NoteDeckBay.ColumnKey；丢了前台就不算叫出来的
        _root.IsTabStop = true;
        _root.KeyDown += (_, e) => e.Handled = _bay.ColumnKey(e.Key);
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated)
            {
                _bay.ColumnDeactivated();
            }
        };
        Content = _root;
        // 亚克力放在 Content 之后：AcrylicBackdrop 连上时按内容的 ActualTheme 定深浅、挂主题变化；先设它的话那时还没有内容，深色下也是浅的（Windows 核验 PLAN-v13）
        SystemBackdrop = new AcrylicBackdrop();
        // 关掉了（这块屏不放了）：收回动画的计时别再来碰已经关了的窗口
        Closed += (_, _) =>
        {
            _hideTimer?.Stop();
            _shown = false;
        };
    }

    /// <summary>拿键盘（N5）：激活这一列、焦点放到根上。</summary>
    public void TakeKeys()
    {
        Activate();
        _root.Focus(FocusState.Programmatic);
    }

    /// <summary>键盘选中的那张（N5）：同鼠标停着的样子（探出来）；null = 都不选。</summary>
    public void MarkKeyed(string? id)
    {
        foreach (var tab in _tabs)
        {
            tab.Hovered = tab.Id == id;
        }

        UpdateStates(animated: true);
    }

    private bool OnRight => _bay.Edge == NoteDeckEdge.Right;

    /// <summary>朝屏幕边的 x 方向（右边缘 +1）。</summary>
    private float Outward => (float)NoteDeckLayout.Outward(_bay.Edge);

    /// <summary>
    /// 摆好、画上这一列。窗口没露着（或者正在收回）时这一下是出场：标签（连「+N」「+」）一张接一张从边外滑进来、淡入（每张晚 45 ms，pop）；
    /// 系统关了动画效果时直接出现。
    /// </summary>
    public void Render(NoteDeckLayout layout, RectInt32 frame)
    {
        _layout = layout;
        var position = AppWindow.Position;
        var size = AppWindow.Size;
        if (position.X != frame.X || position.Y != frame.Y || size.Width != frame.Width || size.Height != frame.Height)
        {
            AppWindow.MoveAndResize(frame);
        }

        var fromHidden = !_shown;
        var revealing = fromHidden || _concealing;
        _hideTimer?.Stop();
        _concealing = false;
        // 出场还没放完（最后一张还没停稳）
        var elapsed = TimeSpan.FromMilliseconds(Math.Clamp(Environment.TickCount64 - _revealedAt, 0, 60_000));
        var entering = !revealing && MotionCurves.Of(MotionCurve.Pop) is { } pop && elapsed < NoteDeckLayout.RevealLength(pop);
        var rebuilt = false;
        var signature = Signature(layout);
        if (signature != _drawn && _pressed is null)
        {
            _drawn = signature;
            Rebuild(layout, slides: !revealing && !entering);
            rebuilt = true;
        }

        UpdateStates(animated: !revealing);
        if (revealing)
        {
            _revealedAt = Environment.TickCount64;
            Reveal(fromHidden, TimeSpan.Zero);
        }
        else if (rebuilt && entering)
        {
            // 出场途中整列重建了（比如新建的便签一打字，标题就变了）：新建的这批从「一直都在」的进度接着走，不从头再来、也不跳到终点
            Reveal(fromHidden: true, elapsed);
        }

        // 先把出场的起点设好再露出来：第一帧就是藏在边外的样子，不闪一下终点
        if (fromHidden)
        {
            _shown = true;
            AppWindow.Show(activateWindow: false);
        }
    }

    /// <summary>收起。animated：标签一起淡出、滑回边外（fadeOut 0.10 s，easeIn），0.14 s 后窗口收走（同 mac）；
    /// 被叫停、被全屏盖住、系统关了动画效果时当场收走。</summary>
    public void Conceal(bool animated)
    {
        if (!_shown)
        {
            return;
        }

        if (!animated || Motion.Reduced)
        {
            HideNow();
            return;
        }

        if (_concealing)
        {
            return;
        }

        _concealing = true;
        var away = new Vector3(Outward * (float)(_layout?.RevealDistance ?? 54), 0, 0);
        foreach (var element in Animated())
        {
            NoteMotion.TranslateOut(element, away, MotionCurves.FadeOutSeconds);
            NoteMotion.FadeTo(element, 0, MotionCurves.FadeOutSeconds, easeIn: true);
        }

        if (_hideTimer is null)
        {
            _hideTimer = DispatcherQueue.CreateTimer();
            _hideTimer.IsRepeating = false;
            _hideTimer.Tick += (_, _) => HideNow();
        }

        _hideTimer.Interval = NoteDeckState.HideDuration;
        _hideTimer.Start();
    }

    /// <summary>正在收回的话当场收走（叫停时：截图的冻结帧里不留半截，同 mac）。</summary>
    public void FinishConceal()
    {
        if (_concealing)
        {
            HideNow();
        }
    }

    private void HideNow()
    {
        _hideTimer?.Stop();
        _concealing = false;
        if (!_shown)
        {
            return;
        }

        _shown = false;
        AppWindow.Hide();
        // 收起时鼠标多半在别处、离开的事件不一定来：停着的都算走了，下次出场从不探出开始
        foreach (var tab in _tabs)
        {
            tab.Hovered = false;
        }

        CancelPress();
        UpdateStates(animated: false);
    }

    /// <summary>
    /// 按着一张标签时这一列被收走了（「丢了指针」不一定来，R108 审查）：当没拖——放开指针、被拖的和让过位的都直接回原位（窗口已经收了，不放动画），
    /// 拖着的话告诉那叠拖完了。不清的话 _pressed 一直不为空，这一列再也不重建。
    /// </summary>
    private void CancelPress()
    {
        if (_pressed is not { } tab)
        {
            return;
        }

        var dragged = _dragging;
        _pressed = null;
        _dragging = false;
        tab.Slot.ReleasePointerCaptures();
        tab.Slot.RenderTransform = null;
        _dragTransform.Y = 0;
        Canvas.SetZIndex(tab.Slot, tab.Index);
        foreach (var other in _tabs.Where(other => other.Shift != 0))
        {
            other.Shift = 0;
            NoteMotion.SetTranslation(other.Slot, Vector3.Zero);
        }

        _target = -1;
        if (dragged)
        {
            _bay.Send(NoteDeckEvent.DragEnded);
        }
    }

    /// <summary>出场要动的：标签的外层、「+N」、「+」，从上到下。</summary>
    private IEnumerable<FrameworkElement> Animated() => _tabs.Select(tab => (FrameworkElement)tab.Slot).Concat(_buttons);

    /// <summary>
    /// 出场。fromHidden：先摆到出场进行到 elapsed 时该在的样子（elapsed 是 0 = 全在边外、透明），再走到位；不是的话（收回到一半又靠过来）
    /// 从现在画在的地方接着走。每张晚 45 ms（RevealDelay，第 7 张封顶），pop；系统关了动画效果时直接到位。
    /// </summary>
    private void Reveal(bool fromHidden, TimeSpan elapsed)
    {
        var index = 0;
        var away = Outward * (float)(_layout?.RevealDistance ?? 54);
        var spring = MotionCurves.Effective(MotionCurve.Pop, Motion.Reduced);
        foreach (var element in Animated())
        {
            if (spring is not { } pop)
            {
                NoteMotion.SetTranslation(element, Vector3.Zero);
                NoteMotion.SetOpacity(element, 1);
                continue;
            }

            var (wait, distance, opacity) = NoteDeckLayout.RevealAt(index++, fromHidden ? elapsed : TimeSpan.Zero, pop, MotionCurves.FadeInSeconds);
            if (fromHidden)
            {
                NoteMotion.SetTranslation(element, new Vector3(away * (float)distance, 0, 0));
                NoteMotion.SetOpacity(element, (float)opacity);
            }

            NoteMotion.TranslateTo(element, Vector3.Zero, MotionCurve.Pop, wait);
            NoteMotion.FadeTo(element, 1, MotionCurves.FadeInSeconds, easeIn: false, wait);
        }
    }

    /// <summary>每张标签现在的样子：开着的立正、探出 8、带竖条；浮着的带竖条、不探出；停着 / 拖着的探出 4；别的斜 3°。</summary>
    private void UpdateStates(bool animated)
    {
        if (_layout is not { } layout)
        {
            return;
        }

        var pivot = new Vector2((float)layout.TabSlot(_bay.Edge).Pivot, (float)(layout.ItemHeight / 2));
        var book = NoteStore.Instance?.Book;
        foreach (var tab in _tabs)
        {
            var open = tab.Id == _bay.OpenId;
            var floating = NoteFloats.IsFloating(tab.Id);
            var lifted = _dragging && ReferenceEquals(_pressed, tab);
            tab.Mark.Visibility = open || floating ? Visibility.Visible : Visibility.Collapsed;
            var title = book is not null && book.Find(tab.Id) is { } note ? book.SummaryOf(note).Title : string.Empty;
            AutomationProperties.SetName(tab.Paper, floating ? title + "（浮在屏幕上）" : open ? title + "（打开着）" : title);

            var reach = NoteDeckLayout.Reach(open, tab.Hovered || lifted);
            if (reach != tab.Reach)
            {
                var target = new Vector3(-Outward * (float)reach, 0, 0);
                if (animated && !double.IsNaN(tab.Reach))
                {
                    NoteMotion.TranslateTo(tab.Paper, target, MotionCurve.Glide);
                }
                else
                {
                    NoteMotion.SetTranslation(tab.Paper, target);
                }

                tab.Reach = reach;
            }

            var tilt = NoteDeckLayout.Tilt(_bay.Edge, !open);
            if (tilt != tab.Tilt)
            {
                NoteMotion.RotateTo(tab.Paper, (float)tilt, pivot, MotionCurve.Glide, animated && !double.IsNaN(tab.Tilt));
                tab.Tilt = tilt;
            }
        }
    }

    /// <summary>一段字占多长（正着放的一格按这个字的宽算——中日韩文字是方的；转着放的是这段横排的宽）。</summary>
    public static double Advance(NoteDeckLabel.Run run, double fontSize) => NoteDeckUi.Advance(run, fontSize);

    /// <summary>
    /// 重建这一列。slides：这一列露着时换了顺序 / 增删——还在的标签从它原来画在的地方（连让位、拖着的那一截）滑到新格子（settle，同 mac「增删、
    /// 换了顺序后剩下的滑到新位置」）；拖动排序松手后让过位的那几张已经在新格子上，只有被拖的那张从松手的地方落进去。
    /// </summary>
    private void Rebuild(NoteDeckLayout layout, bool slides)
    {
        var last = slides ? _tabs.ToDictionary(tab => tab.Id, tab => tab.Index * _builtStep + tab.Shift) : null;
        _tabs.Clear();
        _buttons.Clear();
        _root.Children.Clear();
        _builtStep = layout.Step;
        var right = OnRight;
        var slot = layout.TabSlot(_bay.Edge);
        var column = new StackPanel { Width = layout.ColumnWidth, HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left };
        var notes = _bay.Tabs;
        var host = new Canvas { Width = layout.ColumnWidth, Height = layout.StackHeight };
        for (var index = 0; index < notes.Count; index++)
        {
            var tab = MakeTab(notes[index], index, layout, slot);
            // 外层连朝里多出来的 ColumnRoom 一起占（接点击：探出来的那一截也点得到，R108 审查）
            Canvas.SetLeft(tab.Slot, right ? slot.Left - NoteDeckLayout.ColumnRoom : slot.Left);
            Canvas.SetTop(tab.Slot, index * layout.Step);
            Canvas.SetZIndex(tab.Slot, index);
            host.Children.Add(tab.Slot);
            _tabs.Add(tab);
            if (last is not null && last.TryGetValue(tab.Id, out var was) && Math.Abs(was - index * layout.Step) > 0.5)
            {
                NoteMotion.SetTranslation(tab.Slot, new Vector3(0, (float)(was - index * layout.Step), 0));
                NoteMotion.TranslateTo(tab.Slot, Vector3.Zero, MotionCurve.Settle);
            }
        }

        column.Children.Add(layout.Viewport is { } viewport
            ? new ScrollViewer
            {
                Width = layout.ColumnWidth,
                Height = viewport,
                Content = host,
                VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            }
            : host);
        var metrics = layout.Metrics;
        var edgeSide = right ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        if (layout.Hidden > 0)
        {
            var more = new Button
            {
                Content = $"+{layout.Hidden}",
                Width = layout.TabWidth,
                Height = metrics.MoreHeight,
                Padding = new Thickness(0),
                FontSize = metrics.FontSize,
                HorizontalAlignment = edgeSide,
                Margin = new Thickness(0, metrics.MoreGap, 0, 0),
            };
            AutomationProperties.SetName(more, $"还有 {layout.Hidden} 条，全部展开");
            more.Click += (_, _) =>
            {
                _bay.Activity();
                _bay.Send(NoteDeckEvent.ShowAll);
            };
            column.Children.Add(more);
            _buttons.Add(more);
        }

        // 「+」在标签那一截里居中（不算朝里多出来的 ColumnRoom）
        var inset = (layout.TabWidth - metrics.PlusSize) / 2;
        var plus = new Button
        {
            Content = new FontIcon { Glyph = Glyphs.Add, FontSize = metrics.FontSize },
            Width = metrics.PlusSize,
            Height = metrics.PlusSize,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(metrics.PlusSize / 2),
            HorizontalAlignment = edgeSide,
            Margin = new Thickness(right ? 0 : inset, metrics.PlusGap, right ? inset : 0, 0),
        };
        AutomationProperties.SetName(plus, NotesWindowRules.NewTitle);
        ToolTipService.SetToolTip(plus, NotesWindowRules.NewTitle);
        plus.Click += (_, _) => _bay.Create();
        plus.RightTapped += (_, e) =>
        {
            e.Handled = true;
            NoteDeckUi.ShowEdgeMenu(_bay, plus, null);
        };
        column.Children.Add(plus);
        _buttons.Add(plus);
        _root.Children.Add(column);
    }

    private string Signature(NoteDeckLayout layout)
    {
        var builder = new System.Text.StringBuilder();
        builder.Append(layout.Count).Append('|').Append(layout.Hidden).Append('|').Append(layout.Step).Append('|').Append(layout.ItemHeight)
            .Append('|').Append(layout.Viewport).Append('|').Append(layout.Style).Append('|').Append(_bay.Edge).Append('|')
            .Append(layout.TabWidth).Append('|').Append(Theme.EffectiveTheme).Append('|').Append(Theme.IsHighContrast);
        var book = NoteStore.Instance?.Book;
        foreach (var note in _bay.Tabs)
        {
            builder.Append('\n').Append(note.Id).Append(',').Append(note.Color).Append(',').Append(note.IsPinned).Append(',')
                .Append(book?.SummaryOf(note).Title ?? note.DisplayTitle);
        }

        return builder.ToString();
    }

    private Tab MakeTab(Note note, int index, NoteDeckLayout layout, (double Left, double Width, double Pivot, double Label) slot)
    {
        var tone = NoteDeckUi.Tone(note);
        var right = OnRight;
        var title = NoteStore.Instance?.Book.SummaryOf(note).Title ?? note.DisplayTitle;
        var inward = right ? new CornerRadius(6, 0, 0, 6) : new CornerRadius(0, 6, 6, 0);
        var face = new Grid();
        // 标题、固定的小点排在不算多画那一截的标签宽里
        var area = new Grid
        {
            Width = layout.TabWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(slot.Label, 0, 0, 0),
            IsHitTestVisible = false,
        };
        face.Children.Add(area);
        if (layout.Style == NoteDeckTabStyle.Tabs)
        {
            var label = NoteDeckUi.Label(title, layout.LabelHeight - layout.Metrics.LabelInset, layout.Metrics.FontSize, tone.Ink);
            label.VerticalAlignment = VerticalAlignment.Top;
            label.Margin = new Thickness(0, layout.Metrics.LabelInset / 2, 0, 0);
            area.Children.Add(label);
        }

        if (note.IsPinned)
        {
            // 固定的：贴边那一侧的上角一个 5 的色条色小点（同 mac，不跟大小档缩放）
            area.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = 5,
                Height = 5,
                Fill = NoteDeckUi.Brush(tone.Strip),
                HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(5),
            });
        }

        // 开着 / 浮着的：朝里那条边上一道 3 宽的色条色竖条（不用强调色；同 mac）
        var chips = layout.Style == NoteDeckTabStyle.Chips;
        var mark = new Border
        {
            Width = 3,
            Height = Math.Max(layout.LabelHeight - 12, 6),
            CornerRadius = new CornerRadius(1.5),
            Background = NoteDeckUi.Brush(tone.Strip),
            HorizontalAlignment = right ? HorizontalAlignment.Left : HorizontalAlignment.Right,
            VerticalAlignment = chips ? VerticalAlignment.Center : VerticalAlignment.Top,
            Margin = new Thickness(right ? 3 : 0, chips ? 0 : 6, right ? 0 : 3, 0),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        face.Children.Add(mark);
        // 描边（同 mac）：带标题的描一道墨 14% 的发丝线（高对比度 45%），只有色块的描 1.5 的色条色（只有底的话浅纸在浅色桌面上看不见）
        var paperColor = NotePaper.Of(note);
        var rule = paperColor.Rule(Theme.EffectiveTheme == ElementTheme.Dark, Theme.IsHighContrast);
        var paper = new Border
        {
            Width = slot.Width,
            Height = layout.ItemHeight,
            Background = NoteDeckUi.Brush(tone.Paper),
            BorderBrush = NoteDeckUi.Brush(chips ? tone.Strip : NotePaper.Mix(rule.Rgb, tone.Paper, rule.Opacity)),
            BorderThickness = new Thickness(chips ? 1.5 : 1),
            CornerRadius = inward,
            Child = face,
            HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left,
        };
        // 外层（slot）比纸宽 ColumnRoom、垫一层透明的底：探出是 Composition 的位移，点击区不跟着走，探出来的那一截靠它接住点击和悬停
        var holder = new Grid
        {
            Width = slot.Width + NoteDeckLayout.ColumnRoom,
            Height = layout.ItemHeight,
            Background = new SolidColorBrush(Colors.Transparent),
            Children = { paper },
        };
        var tab = new Tab(note.Id, index, holder, paper, mark);
        Wire(tab);
        return tab;
    }

    /// <summary>点击、悬停、拖动、右键都挂在外层（slot）上：它比纸宽出朝里的 ColumnRoom，探出来的那一截也接得住。</summary>
    private void Wire(Tab tab)
    {
        var hit = tab.Slot;
        var id = tab.Id;
        hit.PointerEntered += (_, _) =>
        {
            tab.Hovered = true;
            if (!_dragging)
            {
                UpdateStates(animated: true);
            }

            _bay.Hover(id, true);
        };
        hit.PointerExited += (_, _) =>
        {
            tab.Hovered = false;
            if (!_dragging)
            {
                UpdateStates(animated: true);
            }

            _bay.Hover(id, false);
        };
        hit.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(hit).Properties.IsLeftButtonPressed)
            {
                return;
            }

            PInvoke.GetCursorPos(out var cursor);
            _pressed = tab;
            _startY = cursor.Y;
            _dragging = false;
            _target = tab.Index;
            hit.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        hit.PointerMoved += (_, _) => Dragged(tab);
        hit.PointerReleased += (_, e) =>
        {
            if (!ReferenceEquals(_pressed, tab))
            {
                return;
            }

            // 先把按着的状态清掉再放开指针：放开时同步来的「丢了指针」就不再当成取消
            var dragged = _dragging;
            var offset = Clamped(tab);
            _pressed = null;
            _dragging = false;
            hit.ReleasePointerCapture(e.Pointer);
            e.Handled = true;
            if (dragged && _layout is { } current)
            {
                var target = NoteDeckLayout.DragTarget(tab.Index, offset, current.Step, current.Count);
                Drop(tab, offset);
                // 换了格子：仓库改顺序 → 同步来的 Render 重建这一列，被拖的那张从松手的地方落进新格子
                _bay.DragEnded(id, tab.Index, target);
            }
            else
            {
                _bay.TapTab(id);
            }
        };
        hit.PointerCaptureLost += (_, _) =>
        {
            if (!ReferenceEquals(_pressed, tab))
            {
                return;
            }

            var dragged = _dragging;
            var offset = Clamped(tab);
            _pressed = null;
            _dragging = false;
            if (dragged)
            {
                // 被系统取消了（别的窗口抢了指针）：当没拖，都滑回原位
                Drop(tab, offset);
                Settle();
                _bay.Send(NoteDeckEvent.DragEnded);
            }
        };
        hit.RightTapped += (_, e) =>
        {
            e.Handled = true;
            if (NoteStore.Instance?.Book.Find(id) is { IsActive: true } current)
            {
                NoteDeckUi.ShowTabMenu(_bay, current, hit, e.GetPosition(hit));
            }
        };
    }

    /// <summary>按着挪：过了 DragSlop 才算拖动排序；被拖的跟着手（不做动画，夹在这一列里），别的让一格（glide）。</summary>
    private void Dragged(Tab tab)
    {
        if (!ReferenceEquals(_pressed, tab) || _layout is not { } layout)
        {
            return;
        }

        _bay.Activity();
        var offset = Offset();
        if (!_dragging && Math.Abs(offset) > NoteDeckLayout.DragSlop && _bay.State.Phase == NoteDeckPhase.Fanned)
        {
            _dragging = true;
            _bay.DragBegan();
            UpdateStates(animated: true);
        }

        if (!_dragging)
        {
            return;
        }

        if (!ReferenceEquals(tab.Slot.RenderTransform, _dragTransform))
        {
            tab.Slot.RenderTransform = _dragTransform;
        }

        _dragTransform.Y = Clamped(tab);
        Canvas.SetZIndex(tab.Slot, 10_000);
        var target = NoteDeckLayout.DragTarget(tab.Index, offset, layout.Step, layout.Count);
        if (target == _target)
        {
            return;
        }

        _target = target;
        foreach (var other in _tabs.Where(other => !ReferenceEquals(other, tab)))
        {
            var shift = NoteDeckLayout.Shift(other.Index, tab.Index, target, layout.Step);
            if (shift != other.Shift)
            {
                other.Shift = shift;
                NoteMotion.TranslateTo(other.Slot, new Vector3(0, (float)shift, 0), MotionCurve.Glide);
            }
        }
    }

    /// <summary>松手（或被取消）：跟着手的那一截换成 Composition 的位移、记成它现在画在的地方（下面重建时从这里落进新格子；没换格子就由 Settle 滑回去）。</summary>
    private void Drop(Tab tab, double offset)
    {
        tab.Slot.RenderTransform = null;
        _dragTransform.Y = 0;
        Canvas.SetZIndex(tab.Slot, tab.Index);
        NoteMotion.SetTranslation(tab.Slot, new Vector3(0, (float)offset, 0));
        tab.Shift = offset;
        if (_layout is { } layout && NoteDeckLayout.DragTarget(tab.Index, offset, layout.Step, layout.Count) == tab.Index)
        {
            Settle();
        }
    }

    /// <summary>让过位的、被拖的都滑回自己的格子。</summary>
    private void Settle()
    {
        foreach (var tab in _tabs.Where(tab => tab.Shift != 0))
        {
            tab.Shift = 0;
            NoteMotion.TranslateTo(tab.Slot, Vector3.Zero, MotionCurve.Settle);
        }

        _target = -1;
    }

    /// <summary>按下之后鼠标往下挪了多少（这块屏的 DIP）。</summary>
    private double Offset()
    {
        PInvoke.GetCursorPos(out var cursor);
        return (cursor.Y - _startY) / _bay.Scale;
    }

    /// <summary>被拖的那张跟着手挪多少：夹在这一列里，不拖出窗口。</summary>
    private double Clamped(Tab tab)
    {
        if (_layout is not { } layout)
        {
            return 0;
        }

        var lowest = (layout.Count - 1 - tab.Index) * layout.Step;
        return Math.Clamp(Offset(), -tab.Index * layout.Step, Math.Max(lowest, 0));
    }
}

/// <summary>标签旁边的预览卡。</summary>
internal sealed class NoteDeckPreviewWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly Border _paper;
    private readonly StackPanel _content;
    private readonly TextBlock _title;
    private readonly TextBlock _body;
    private string? _id;
    private bool _shown;

    public NoteDeckPreviewWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        HudFrame.Apply(this);
        NoteDeckUi.NoOutline(WinRT.Interop.WindowNative.GetWindowHandle(this));
        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        };
        _body = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 5 };
        _content = new StackPanel { Spacing = 4, Children = { _title, _body } };
        _paper = new Border { Padding = new Thickness(12, 10, 12, 10), Child = _content };
        var root = NoteDeckUi.Root();
        root.Children.Add(_paper);
        root.PointerEntered += (_, _) => _bay.HoverPreview(true);
        root.PointerExited += (_, _) => _bay.HoverPreview(false);
        root.Tapped += (_, _) =>
        {
            if (_id is { } id)
            {
                _bay.TapTab(id);
            }
        };
        Content = root;
    }

    public void Show(Note note, RectInt32 frame)
    {
        // 露出来 / 换了一条（R108，mac snap：淡入 + 从边那侧偏 8）：纸（这扇窗）不动，动里面的字（同打开的便签，见文件头）
        if (!_shown || _id != note.Id)
        {
            if (NoteMotion.Animates(MotionCurve.Snap))
            {
                NoteMotion.SetTranslation(_content, new Vector3((float)NoteDeckLayout.Outward(_bay.Edge) * 8, 0, 0));
                NoteMotion.SetOpacity(_content, 0);
                NoteMotion.TranslateTo(_content, Vector3.Zero, MotionCurve.Snap);
                NoteMotion.FadeTo(_content, 1, MotionCurves.FadeInSeconds, easeIn: false);
            }
            else
            {
                NoteMotion.SetTranslation(_content, Vector3.Zero);
                NoteMotion.SetOpacity(_content, 1);
            }
        }

        _id = note.Id;
        var tone = NoteDeckUi.Tone(note);
        _paper.Background = NoteDeckUi.Brush(tone.Paper);
        var ink = NoteDeckUi.Brush(tone.Ink);
        var summary = NoteStore.Instance?.Book.SummaryOf(note);
        _title.Text = summary?.Title ?? note.DisplayTitle;
        _title.Foreground = ink;
        _body.Text = summary?.Preview ?? note.Preview;
        _body.Foreground = ink;
        _body.Opacity = NotePaper.SecondaryOpacity;
        AutomationProperties.SetName(_paper, _title.Text);
        AppWindow.MoveAndResize(frame);
        if (!_shown)
        {
            _shown = true;
            AppWindow.Show(activateWindow: false);
        }
    }

    public void Hide()
    {
        if (_shown)
        {
            _shown = false;
            AppWindow.Hide();
        }
    }
}

/// <summary>从边缘打开的那条便签。</summary>
internal sealed partial class NoteDeckSheetWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly IntPtr _hwnd;
    private string? _id;
    private bool _closing;
    private DispatcherQueueTimer? _grip;
    private PointD _gripStart;
    private bool _gripFromTab;

    public NoteDeckSheetWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        ExtendsContentIntoTitleBar = true;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        NoteDeckUi.NoOutline(_hwnd);
        Sheet = new NoteSheetView(new NoteSheetView.Host
        {
            Close = byKeyboard => _bay.CloseSheet(byKeyboard),
            ToggleFloating = () => _bay.FloatOpen(dragging: false),
            IsFloating = () => false,
            GripPressed = _ => StartGrip(fromTab: false),
            TabPressed = _ => StartGrip(fromTab: true),
        });
        var root = new Grid { RequestedTheme = Theme.ElementTheme };
        root.Children.Add(Sheet.View);
        root.PointerMoved += (_, _) => _bay.Activity();
        Content = root;
        AppWindow.Closing += (_, args) =>
        {
            if (!_closing)
            {
                args.Cancel = true;
                _bay.CloseSheet(byKeyboard: false);
            }
        };
        Activated += (_, args) =>
        {
            HasKey = args.WindowActivationState != WindowActivationState.Deactivated;
            if (!HasKey)
            {
                NoteStore.Instance?.Flush();
                _bay.SheetDeactivated();
            }
        };
    }

    public NoteSheetView Sheet { get; }

    /// <summary>拿着前台（键盘在它这儿）。</summary>
    public bool HasKey { get; private set; }

    /// <summary>在屏幕上的位置（物理像素）。</summary>
    public RectD Frame => new(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);

    public void Place(RectInt32 frame, string id)
    {
        // 它带着的那张标签在朝屏幕里面的那一侧（右边缘时在左）
        Sheet.SetTab(
            _bay.Edge == NoteDeckEdge.Right ? NoteSheetView.TabSide.Leading : NoteSheetView.TabSide.Trailing,
            new NoteDeckMetrics(_bay.Options.Size.Scale()));
        AppWindow.MoveAndResize(frame);
        if (_id != id)
        {
            _id = id;
            Sheet.Show(id);
        }
    }

    /// <summary>露出来；takesKey：拿前台、焦点进正文（悬停打开的不拿）。</summary>
    public void Present(bool takesKey)
    {
        Emerge();
        if (!takesKey)
        {
            AppWindow.Show(activateWindow: false);
            return;
        }

        AppWindow.Show(activateWindow: true);
        Activate();
        Foreground.Restore(new Windows.Win32.Foundation.HWND(_hwnd));
        Sheet.FocusBody();
    }

    /// <summary>
    /// 出场（mac NoteEmerge）：里面的东西从边缘那侧偏 24 滑回原位（glide）、淡入（0.12 s）——纸（这扇窗）本身不动，见文件头；
    /// mac 还从 0.97 放大，Windows 全 App 不做从小放大。系统关了动画效果时直接出现。换一条便签时也来一遍（同 mac：一条一块）。
    /// </summary>
    private void Emerge()
    {
        var target = Sheet.MotionTarget;
        if (!NoteMotion.Animates(MotionCurve.Glide))
        {
            NoteMotion.SetTranslation(target, Vector3.Zero);
            NoteMotion.SetOpacity(target, 1);
            return;
        }

        NoteMotion.SetTranslation(target, new Vector3((float)(NoteDeckLayout.Outward(_bay.Edge) * NoteDeckLayout.EmergeOffset), 0, 0));
        NoteMotion.SetOpacity(target, 0);
        NoteMotion.TranslateTo(target, Vector3.Zero, MotionCurve.Glide);
        NoteMotion.FadeTo(target, 1, MotionCurves.FadeInSeconds, easeIn: false);
    }

    /// <summary>收起（留着下次用）。里面的便签放掉：藏着的窗口里的编辑器仍算「开着」，空白便签就删不掉了。</summary>
    public void HideQuietly()
    {
        _grip?.Stop();
        _id = null;
        Sheet.Show(null);
        HasKey = false;
        AppWindow.Hide();
    }

    public void CloseQuietly()
    {
        _closing = true;
        _grip?.Stop();
        Close();
    }

    /// <summary>按住头部空白处 / 它带着的那张标签：往外拖过一段（NoteFloatLayout.Detaches）就浮到屏幕上，接着由系统挪窗口；
    /// 没拖开就松手：头部是什么都不做，标签上没挪开（NoteFloatLayout.Moved）= 点了一下 = 关掉、回到那一列（同 mac）。</summary>
    private void StartGrip(bool fromTab)
    {
        _gripFromTab = fromTab;
        PInvoke.GetCursorPos(out var start);
        if (_grip is null)
        {
            _grip = DispatcherQueue.CreateTimer();
            _grip.Interval = TimeSpan.FromMilliseconds(16);
        }

        _grip.Tick -= OnGripTick;
        _gripStart = new PointD(start.X / _bay.Scale, start.Y / _bay.Scale);
        _grip.Tick += OnGripTick;
        _grip.Start();
    }

    private void OnGripTick(DispatcherQueueTimer timer, object args)
    {
        PInvoke.GetCursorPos(out var now);
        if (!NoteDeckUi.KeyDown(0x01 /* VK_LBUTTON */))
        {
            timer.Stop();
            if (_gripFromTab && !NoteFloatLayout.Moved(_gripStart, new PointD(now.X / _bay.Scale, now.Y / _bay.Scale)))
            {
                _bay.CloseSheet(byKeyboard: false);
            }

            return;
        }

        if (NoteFloatLayout.Detaches(_gripStart, new PointD(now.X / _bay.Scale, now.Y / _bay.Scale)))
        {
            timer.Stop();
            _bay.FloatOpen(dragging: true);
        }
    }
}

/// <summary>
/// 药丸和标签列的窗口过程补两件事：
/// - 放开系统给顶层窗口定的最小宽（约 136，PLAN-v16 V1）：没边框、PreferredMinimumWidth 设 1 都还被撑大，只好接 WM_GETMINMAXINFO，
///   先让后面的窗口过程填完，再把最小跟踪尺寸改成 1 × 1。
/// - 不要非客户区：SetBorderAndTitleBar(false, false) 之后 WinUI 还给窗口留着 WS_DLGFRAME（自己改样式它又加回来），四边各 3 像素
///   系统画的浅色框，深色下是一圈白线、12 宽的药丸客户区只剩 6（2026-11-12 屏上实测）。WM_NCCALCSIZE 直接答「客户区 = 整扇窗」。
/// </summary>
internal static unsafe partial class NoteDeckTiny
{
    private const uint WmGetMinMaxInfo = 0x0024;
    private const uint WmNcCalcSize = 0x0083;

    public static void Allow(IntPtr hwnd) => SetWindowSubclass(hwnd, &Proc, 1, 0);

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr Proc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        if (message == WmNcCalcSize && wParam != IntPtr.Zero)
        {
            // 建议的窗口矩形原样当客户区：没有任何边框
            return IntPtr.Zero;
        }

        var result = DefSubclassProc(hwnd, message, wParam, lParam);
        if (message == WmGetMinMaxInfo && lParam != IntPtr.Zero)
        {
            // MINMAXINFO：ptReserved、ptMaxSize、ptMaxPosition、ptMinTrackSize（第 4 个 POINT，偏移 24）、ptMaxTrackSize
            var info = (int*)lParam;
            info[6] = 1;
            info[7] = 1;
        }

        return result;
    }

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(
        IntPtr hwnd, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, UIntPtr, UIntPtr, IntPtr> proc, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    private static partial IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
