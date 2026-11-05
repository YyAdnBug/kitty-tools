// 屏幕边缘那叠的四扇窗（PLAN-v13 第 6 批，照 mac Notes/NoteDeckPill.swift + NoteDeckView.swift + NoteDeckPanel.swift；逻辑在 NoteDeck.cs 的 NoteDeckBay）：
// - 药丸：贴边的一小条（不拿前台、置顶、不进 Alt+Tab，亚克力底），一条便签一道色块，超过 14 条合成一道；鼠标进来 / 点一下扇出，
//   按住 Alt 拖 = 换边、换高度。「不显示药丸」时只留亚克力的那一条（Windows 没有透明窗口）。
// - 标签列：一张接一张往下压的纸色标签（标题竖排：中日韩文字正着、别的整段转 90°，排不下截断加「…」），「+N」展开全部、「+」新建；
//   点一张打开、停一会儿出预览卡、按着上下拖排序；右键标签 = 这条的操作，右键空白处 / 「+」/ 药丸 = 新建便签、全部便签、设置…。
// - 预览卡：标签旁边的一张小纸（标题 + 开头几行），鼠标挪上去不收、点它打开。
// - 打开的便签：挨着标签列，里面是 NoteSheetView（同全部便签窗口、浮动便签）。要打字，所以拿前台；失去前台 = 点了别处（没固定的收起）。
//   按住头部空白处往外拖过一段 = 浮到屏幕上（NoteFloats，接着由系统挪窗口）。
// 只用到系统画的东西：圆角、阴影、边框是 DWM 的（HudFrame），菜单是 MenuFlyout。动效没有（Windows 的窗口退场不淡出，PLAN-v7 §1）。
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
            NoticeHost.Show(NotesWindowRules.ArchivedTitle(1), note.DisplayTitle, NoticeTone.Normal,
                new NoticeAction("取消归档", () => store?.SetArchived(id, false, toFront: false)));
        });
        var delete = Add(menu.Items, NotesWindowRules.DeleteTitle, Glyphs.Delete, () =>
        {
            store?.Delete(id);
            NoticeHost.Show(NotesWindowRules.DeletedTitle(1), "在全部便签的「最近删除」里留 30 天", NoticeTone.Normal,
                new NoticeAction("撤销", () => store?.Restore(id)));
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

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int key);
}

/// <summary>边上的药丸。</summary>
internal sealed class NoteDeckPillWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly Grid _root;
    private readonly StackPanel _dashes;
    private bool _shown;
    private bool _dragging;

    public NoteDeckPillWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        HudFrame.Apply(this);
        SystemBackdrop = new AcrylicBackdrop();
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
    }

    /// <summary>摆好、画上每条便签的色块（hides：不显示药丸，只留那一条底）。</summary>
    public void Update(RectInt32 frame, IReadOnlyList<int> colors, bool hides)
    {
        AppWindow.MoveAndResize(frame);
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

    public void Move(RectInt32 frame) => AppWindow.MoveAndResize(frame);

    public void SetShown(bool shown)
    {
        if (shown == _shown)
        {
            return;
        }

        _shown = shown;
        if (shown)
        {
            AppWindow.Show(activateWindow: false);
        }
        else
        {
            AppWindow.Hide();
        }
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

/// <summary>扇出的那一列标签。</summary>
internal sealed class NoteDeckColumnWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly Grid _root;
    private bool _shown;

    // 按着一张标签：哪张、从第几格、按下时鼠标的纵坐标（物理像素）、拖没拖起来、那张的视图
    private string? _pressed;
    private int _from;
    private int _startY;
    private bool _dragging;
    private FrameworkElement? _pressedView;
    private NoteDeckLayout? _layout;

    public NoteDeckColumnWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        HudFrame.Apply(this);
        SystemBackdrop = new AcrylicBackdrop();
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
        Content = _root;
    }

    /// <summary>一段字占多长（正着放的一格按这个字的宽算——中日韩文字是方的；转着放的是这段横排的宽）。</summary>
    public static double Advance(NoteDeckLabel.Run run, double fontSize) => Measure(run.Text, fontSize).Width;

    private static Windows.Foundation.Size Measure(string text, double fontSize)
    {
        var block = new TextBlock { Text = text, FontSize = fontSize, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
        block.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return block.DesiredSize;
    }

    public void Render(NoteDeckLayout layout, RectInt32 frame)
    {
        _layout = layout;
        AppWindow.MoveAndResize(frame);
        if (!_shown)
        {
            _shown = true;
            AppWindow.Show(activateWindow: false);
        }

        _root.Children.Clear();
        var column = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        var tabs = _bay.Tabs;
        var host = new Canvas { Width = layout.TabWidth, Height = layout.StackHeight };
        for (var index = 0; index < tabs.Count; index++)
        {
            var view = Tab(tabs[index], index, layout);
            Canvas.SetTop(view, index * layout.Step);
            Canvas.SetZIndex(view, index);
            host.Children.Add(view);
        }

        column.Children.Add(layout.Viewport is { } viewport
            ? new ScrollViewer { Height = viewport, Content = host, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden }
            : host);
        var metrics = layout.Metrics;
        if (layout.Hidden > 0)
        {
            var more = new Button
            {
                Content = $"+{layout.Hidden}",
                Width = layout.TabWidth,
                Height = metrics.MoreHeight,
                Padding = new Thickness(0),
                FontSize = metrics.FontSize,
                Margin = new Thickness(0, metrics.MoreGap, 0, 0),
            };
            AutomationProperties.SetName(more, $"还有 {layout.Hidden} 条，全部展开");
            more.Click += (_, _) =>
            {
                _bay.Activity();
                _bay.Send(NoteDeckEvent.ShowAll);
            };
            column.Children.Add(more);
        }

        var plus = new Button
        {
            Content = new FontIcon { Glyph = Glyphs.Add, FontSize = metrics.FontSize },
            Width = metrics.PlusSize,
            Height = metrics.PlusSize,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(metrics.PlusSize / 2),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, metrics.PlusGap, 0, 0),
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
        _root.Children.Add(column);
    }

    public void Hide()
    {
        if (_shown)
        {
            _shown = false;
            AppWindow.Hide();
        }
    }

    private FrameworkElement Tab(Note note, int index, NoteDeckLayout layout)
    {
        var tone = NoteDeckUi.Tone(note);
        var isOpen = note.Id == _bay.OpenId;
        var floating = NoteFloats.IsFloating(note.Id);
        var title = NoteStore.Instance?.Book.SummaryOf(note).Title ?? note.DisplayTitle;
        var inward = _bay.Edge == NoteDeckEdge.Right ? new CornerRadius(6, 0, 0, 6) : new CornerRadius(0, 6, 6, 0);
        var tab = new Border
        {
            Width = layout.TabWidth,
            Height = layout.ItemHeight,
            Background = NoteDeckUi.Brush(tone.Paper),
            BorderBrush = NoteDeckUi.Brush(tone.Strip),
            BorderThickness = new Thickness(isOpen ? 2 : 1),
            CornerRadius = layout.Style == NoteDeckTabStyle.Chips ? new CornerRadius(6) : inward,
            // 浮在屏幕上的那条淡一点（点它是把浮着的那张叫到前面）
            Opacity = floating ? 0.6 : 1,
        };
        if (layout.Style == NoteDeckTabStyle.Tabs)
        {
            tab.Child = Label(title, layout, tone.Ink);
        }

        AutomationProperties.SetName(tab, floating ? title + "（浮在屏幕上）" : isOpen ? title + "（打开着）" : title);
        var id = note.Id;
        tab.PointerEntered += (_, _) => _bay.Hover(id, true);
        tab.PointerExited += (_, _) => _bay.Hover(id, false);
        tab.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(tab).Properties.IsLeftButtonPressed)
            {
                return;
            }

            PInvoke.GetCursorPos(out var cursor);
            _pressed = id;
            _from = index;
            _startY = cursor.Y;
            _dragging = false;
            _pressedView = tab;
            tab.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        tab.PointerMoved += (_, _) =>
        {
            if (_pressed != id || _layout is not { } current)
            {
                return;
            }

            _bay.Activity();
            var offset = Offset();
            if (!_dragging && Math.Abs(offset) > NoteDeckLayout.DragSlop && _bay.State.Phase == NoteDeckPhase.Fanned)
            {
                _dragging = true;
                _bay.DragBegan();
            }

            if (_dragging && _pressedView is { } view)
            {
                // 夹在这一列里，不拖出窗口
                var lowest = (current.Count - 1 - _from) * current.Step;
                view.RenderTransform = new TranslateTransform { Y = Math.Clamp(offset, -_from * current.Step, lowest) };
                Canvas.SetZIndex(view, 10_000);
            }
        };
        tab.PointerReleased += (_, e) =>
        {
            if (_pressed != id)
            {
                return;
            }

            tab.ReleasePointerCapture(e.Pointer);
            var dragged = _dragging;
            var offset = Offset();
            _pressed = null;
            _dragging = false;
            _pressedView = null;
            if (dragged && _layout is { } current)
            {
                _bay.DragEnded(id, _from, NoteDeckLayout.DragTarget(_from, offset, current.Step, current.Count));
            }
            else
            {
                _bay.TapTab(id);
            }

            e.Handled = true;
        };
        tab.PointerCaptureLost += (_, _) =>
        {
            if (_pressed == id && _dragging)
            {
                _bay.Send(NoteDeckEvent.DragEnded);
            }

            if (_pressed == id)
            {
                _pressed = null;
                _dragging = false;
                _pressedView = null;
            }
        };
        tab.RightTapped += (_, e) =>
        {
            e.Handled = true;
            if (NoteStore.Instance?.Book.Find(id) is { IsActive: true } current)
            {
                NoteDeckUi.ShowTabMenu(_bay, current, tab, e.GetPosition(tab));
            }
        };
        return tab;
    }

    /// <summary>按下之后鼠标往下挪了多少（这块屏的 DIP）。</summary>
    private double Offset()
    {
        PInvoke.GetCursorPos(out var cursor);
        return (cursor.Y - _startY) / _bay.Scale;
    }

    /// <summary>竖排的标题：排在每张顶上露出的那一截里（上下让出 LabelInset）。</summary>
    private static FrameworkElement Label(string title, NoteDeckLayout layout, int ink)
    {
        var font = layout.Metrics.FontSize;
        var runs = NoteDeckLabel.Fitted(title, layout.LabelHeight - layout.Metrics.LabelInset, run => Advance(run, font));
        var stack = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, layout.Metrics.LabelInset / 2, 0, 0),
            IsHitTestVisible = false,
        };
        var brush = NoteDeckUi.Brush(ink);
        foreach (var run in runs)
        {
            var block = new TextBlock
            {
                Text = run.Text,
                FontSize = font,
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
            var size = Measure(run.Text, font);
            block.RenderTransform = new RotateTransform { Angle = 90 };
            var holder = new Canvas { Width = size.Height, Height = size.Width, HorizontalAlignment = HorizontalAlignment.Center };
            Canvas.SetLeft(block, size.Height);
            holder.Children.Add(block);
            stack.Children.Add(holder);
        }

        return stack;
    }
}

/// <summary>标签旁边的预览卡。</summary>
internal sealed class NoteDeckPreviewWindow : Window
{
    private readonly NoteDeckBay _bay;
    private readonly Border _paper;
    private readonly TextBlock _title;
    private readonly TextBlock _body;
    private string? _id;
    private bool _shown;

    public NoteDeckPreviewWindow(NoteDeckBay bay)
    {
        _bay = bay;
        Title = Paths.ProductName + " 便签";
        HudFrame.Apply(this);
        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        };
        _body = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 5 };
        _paper = new Border
        {
            Padding = new Thickness(12, 10, 12, 10),
            Child = new StackPanel { Spacing = 4, Children = { _title, _body } },
        };
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
        Sheet = new NoteSheetView(new NoteSheetView.Host
        {
            Close = byKeyboard => _bay.CloseSheet(byKeyboard),
            ToggleFloating = () => _bay.FloatOpen(dragging: false),
            IsFloating = () => false,
            GripPressed = _ => StartGrip(),
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

    /// <summary>按住头部空白处：往外拖过一段（NoteFloatLayout.Detaches）就浮到屏幕上，接着由系统挪窗口；没拖开就松手是什么都不做。</summary>
    private void StartGrip()
    {
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
        if (!NoteDeckUi.KeyDown(0x01 /* VK_LBUTTON */))
        {
            timer.Stop();
            return;
        }

        PInvoke.GetCursorPos(out var now);
        if (NoteFloatLayout.Detaches(_gripStart, new PointD(now.X / _bay.Scale, now.Y / _bay.Scale)))
        {
            timer.Stop();
            _bay.FloatOpen(dragging: true);
        }
    }
}
