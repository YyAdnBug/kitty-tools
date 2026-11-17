// 全部便签窗口（PLAN-v13 第 5 批，照 mac Notes/NotesWindow.swift + NotesWindowView.swift + NotesWallView.swift；规则在 Core 的
// NotesWindowRules / NoteWall）：普通窗口（进任务栏和 Alt+Tab，同设置窗；外壳跟 Windows：Mica、系统标题栏）。
// - 三个视图（全部 / 归档 / 最近删除）和搜索（标题 + 正文，同仓库的 Search）；两种显示方式：便签墙（默认）/ 列表，记住上次选的。
// - 列表：左边一列（纸色圆点、标题、摘要、任务进度、相对时间），右边是打开的那条（NoteSheetView）；「全部」里没在搜索时能拖动排序。
// - 便签墙：卡片一样宽、高随内容，瀑布流（NoteWall.Arrange），分「固定的 / 其他」两段；点一张在墙上盖一层、放大成编辑卡（Esc 收回）。
// - 最近删除里只读（令牌换成「[图片]」），工具栏是「放回」「永久删除…」「清空最近删除…」。
// - 右键菜单：颜色 ›、固定、归档、浮在屏幕上、删除（最近删除里是放回、永久删除）。删除 / 归档后提示里能撤销。
// - 按键：Ctrl+N 新建、Ctrl+F 搜索（焦点在正文里时是便签内查找）、Delete（列表拿着焦点时）删除、Esc 收回编辑卡。
// 落盘：打字走仓库（停手再落）；换一条、收回编辑卡、窗口失去激活、关窗口时 Flush。
// 便签墙的键盘（PLAN-v20 N3，mac NotesWallView）：墙拿着焦点时方向键在卡片之间挑（Core NoteWall.Neighbor：同一列上下、左右去最近的一列），
// 挑中的那张描一圈强调色、滚进视野；Enter / 空格放大成编辑卡，Esc 收回后焦点回到墙上、还是那张。
// 便签墙（R108，同 mac）：能拖动排序（「全部」里、没在搜索时；松手按 NoteWall.StoreIndex 写回顺序）；只建可见区附近的卡片，
// 往下的高在后面分批量（「便签墙」那一节的注释）；卡片上的列表符号是淡色的原符号、代码块垫代码的底。
using System.Numerics;
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI;

namespace KittyTools;

internal sealed class NotesWindow : Window
{
    private static NotesWindow? _instance;

    private readonly Grid _root;
    private readonly StackPanel _scopes;
    private readonly TextBox _search;
    private readonly StackPanel _actions;
    private readonly Grid _list;
    private readonly ListView _rows;
    private readonly NoteSheetView _sheet;
    private readonly Grid _wall;
    private readonly ScrollViewer _wallScroll;
    private readonly Canvas _wallCanvas;
    private readonly Grid _editCard;
    private readonly NoteSheetView _cardSheet;
    /// <summary>空状态（REVIEW G10，mac NotesWindowView.empty）：图标 + 标题 + 一行说明 / 键 /「清除搜索」。</summary>
    private readonly StackPanel _empty;
    private readonly FontIcon _emptyIcon;
    private readonly TextBlock _emptyTitle;
    private readonly StackPanel _emptyDetail;
    private NotesScope _scope = NotesScope.All;
    private string? _selection;
    private bool _wallMode;

    // 这次打开以来删进「最近删除」的（Ctrl+Z 一条条放回，同 mac）。
    private readonly List<string> _deleted = new();
    private bool _populating;

    private NotesWindow()
    {
        Title = "全部便签";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(1000 * Displays.SystemScale), (int)(680 * Displays.SystemScale)));
        if (File.Exists(Paths.AppIconFile))
        {
            AppWindow.SetIcon(Paths.AppIconFile);
        }

        _wallMode = SettingsService.Current.NotesWindowLayout != "list";
        _root = new Grid { RequestedTheme = Theme.ElementTheme };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // 工具栏：视图 ｜ 搜索 ｜ 操作
        var bar = new Grid { Padding = new Thickness(16, 10, 16, 10), ColumnSpacing = 12 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = 360 });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _scopes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        bar.Children.Add(_scopes);
        _search = new TextBox { PlaceholderText = "搜索标题和正文", VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_search, "搜索便签");
        _search.TextChanged += (_, _) => Populate();
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape && _search.Text.Length > 0)
            {
                _search.Text = string.Empty;
                e.Handled = true;
            }
        };
        Grid.SetColumn(_search, 1);
        bar.Children.Add(_search);
        _actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetColumn(_actions, 2);
        bar.Children.Add(_actions);
        _root.Children.Add(bar);

        // 列表
        _list = new Grid { ColumnSpacing = 0 };
        _list.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(320) });
        _list.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _rows = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            Padding = new Thickness(8, 0, 8, 8),
        };
        _rows.SelectionChanged += (_, _) =>
        {
            if (!_populating && _rows.SelectedItem is FrameworkElement { Tag: string id })
            {
                Select(id);
            }
        };
        _rows.DragItemsCompleted += OnRowsReordered;
        _rows.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Delete && _selection is { } id)
            {
                RemoveSelected(id);
                e.Handled = true;
            }
        };
        _list.Children.Add(_rows);
        _sheet = new NoteSheetView(new NoteSheetView.Host
        {
            Close = _ => { },
            ShowsClose = false,
            ToggleFloating = () => FloatSelected(),
            IsFloating = () => _selection is { } id && NoteFloats.IsFloating(id),
        });
        _sheet.View.Margin = new Thickness(8, 0, 16, 16);
        Grid.SetColumn(_sheet.View, 1);
        _list.Children.Add(_sheet.View);

        // 便签墙
        _wall = new Grid();
        _wallCanvas = new Canvas();
        _wallScroll = new ScrollViewer { Content = _wallCanvas, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, IsTabStop = true };
        _wallScroll.SizeChanged += (_, _) => ArrangeWall();
        // 滚动位置按段记：跨段才重排、建新露出来的卡片（R108）
        _wallScroll.ViewChanged += (_, _) =>
        {
            var band = NoteWall.Band(_wallScroll.VerticalOffset);
            if (band != _wallBand)
            {
                _wallBand = band;
                ArrangeWall();
            }
        };
        // 先于 ScrollViewer 自己处理方向键（不然方向键只是滚动）
        _wallScroll.PreviewKeyDown += OnWallKeyDown;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_wallScroll, "便签墙：方向键挑一张，Enter 打开");
        _wall.Children.Add(_wallScroll);
        _editCard = new Grid { Visibility = Visibility.Collapsed, Background = new SolidColorBrush(Color.FromArgb(64, 0, 0, 0)) };
        _editCard.PointerPressed += (_, e) =>
        {
            if (ReferenceEquals(e.OriginalSource, _editCard))
            {
                CollapseCard();
            }
        };
        _cardSheet = new NoteSheetView(new NoteSheetView.Host
        {
            Close = _ => CollapseCard(),
            ToggleFloating = () => FloatSelected(),
            IsFloating = () => _selection is { } id && NoteFloats.IsFloating(id),
        });
        _cardSheet.View.HorizontalAlignment = HorizontalAlignment.Center;
        _cardSheet.View.VerticalAlignment = VerticalAlignment.Center;
        _editCard.Children.Add(_cardSheet.View);
        _wall.Children.Add(_editCard);

        _emptyIcon = new FontIcon { FontSize = 32, Foreground = Theme.SecondaryText(), Margin = new Thickness(0, 0, 0, 4) };
        _emptyTitle = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Reading"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _emptyDetail = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        _empty = new StackPanel
        {
            Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            Children = { _emptyIcon, _emptyTitle, _emptyDetail },
        };
        Grid.SetRow(_list, 1);
        Grid.SetRow(_wall, 1);
        Grid.SetRow(_empty, 1);
        _root.Children.Add(_list);
        _root.Children.Add(_wall);
        _root.Children.Add(_empty);
        _root.KeyDown += OnKeyDown;
        Content = _root;

        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
            {
                NoteStore.Instance?.Flush();
            }
        };
        Closed += (_, _) =>
        {
            NoteStore.Instance?.Flush();
            if (_selection is { } id)
            {
                NoteStore.Instance?.Left(id);
            }

            if (NoteStore.Instance is { } store)
            {
                store.Changed -= OnStoreChanged;
            }

            _populateTimer?.Stop();
            _measureTimer?.Stop();
            _instance = null;
            IdleReclaimer.Schedule();
        };
        if (NoteStore.Instance is { } notes)
        {
            notes.Changed += OnStoreChanged;
        }

        BuildScopes();
        Populate();
    }

    /// <summary>打开（已经开着就拿到前面）。</summary>
    public static void ShowWindow()
    {
        if (NoteStore.Instance is null)
        {
            NoticeHost.Show("便签这次用不了", NotesRecovery.Unavailable ?? "便签的数据打不开", NoticeTone.Warning);
            return;
        }

        OverlayHost.Hide(restoreForeground: false);
        _instance ??= new NotesWindow();
        _instance.Activate();
        _instance.BringToFront();
    }

    /// <summary>便签功能关掉时：开着就关（同 mac：最小化着的也关）。</summary>
    public static void CloseIfOpen() => _instance?.Close();

    /// <summary>打开并选中这一条（属于哪个视图就切到哪个视图）。</summary>
    public static void ShowNote(string id)
    {
        ShowWindow();
        if (_instance is not { } window || NoteStore.Instance?.Book.Find(id) is not { } note)
        {
            return;
        }

        window._scope = note.DeletedAt is not null ? NotesScope.Trash : note.IsArchived ? NotesScope.Archive : NotesScope.All;
        window._search.Text = string.Empty;
        window._selection = id;
        window.BuildScopes();
        window.Populate();
        if (window._wallMode)
        {
            window.ExpandCard(id);
        }
        else
        {
            window._sheet.FocusBody();
        }
    }

    /// <summary>新建一条（复用本机建的空白便签）并在窗口里打开。</summary>
    public static void NewNote()
    {
        if (NoteStore.Instance is not { } store)
        {
            ShowWindow();
            return;
        }

        var note = store.BlankOrNew();
        ShowNote(note.Id);
    }

    private void BringToFront()
    {
        var hwnd = (Windows.Win32.Foundation.HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Foreground.Restore(hwnd);
    }

    // 仓库变了：攒 250 ms 再整页重排（打一个字就是一次变化；每次都重建列表 / 便签墙太重，列表还会跳回顶上）
    // ponytail: 还是整页重建；要更省就只换打字的那一行 / 那一张卡。
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _populateTimer;

    private void OnStoreChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (_populateTimer is null)
        {
            _populateTimer = DispatcherQueue.CreateTimer();
            _populateTimer.Interval = TimeSpan.FromMilliseconds(250);
            _populateTimer.IsRepeating = false;
            _populateTimer.Tick += (_, _) => Populate();
        }

        _populateTimer.Stop();
        _populateTimer.Start();
    });

    // ---- 视图、工具栏 ----

    private void BuildScopes()
    {
        _scopes.Children.Clear();
        foreach (var scope in new[] { NotesScope.All, NotesScope.Archive, NotesScope.Trash })
        {
            var count = NoteStore.Instance is { } store ? NotesWindowRules.List(store.Book, scope).Count : 0;
            var button = new ToggleButton
            {
                Content = count > 0 ? $"{NotesWindowRules.ScopeTitle(scope)} {count}" : NotesWindowRules.ScopeTitle(scope), // 0 条不写数字（同 mac，REVIEW R99）
                IsChecked = scope == _scope,
                Padding = new Thickness(10, 4, 10, 4),
            };
            button.Click += (_, _) =>
            {
                _scope = scope;
                CollapseCard();
                BuildScopes();
                Populate();
            };
            _scopes.Children.Add(button);
        }
    }

    private void BuildActions()
    {
        _actions.Children.Clear();
        var note = SelectedNote;
        if (_scope == NotesScope.Trash)
        {
            AddAction(Glyphs.Undo, NotesWindowRules.RestoreTitle, () => Run(id => NoteStore.Instance?.Restore(id)), note is not null);
            AddAction(Glyphs.Delete, NotesWindowRules.EraseTitle, () => _ = EraseSelectedAsync(), note is not null);
            AddAction("\uE74D", NotesWindowRules.EmptyTrashTitle, () => _ = EmptyTrashAsync(),
                NoteStore.Instance?.Book.Trashed.Count > 0);
        }
        else
        {
            AddAction(Glyphs.Add, NotesWindowRules.NewTitle + "（Ctrl+N）", NewNote, true);
            AddAction("\uE9D5", NotesWindowRules.TaskHelp, () => (_wallMode ? _cardSheet : _sheet).Editor.ToggleTask(),
                note is not null && (!_wallMode || _editCard.Visibility == Visibility.Visible));
            AddAction(note?.IsPinned == true ? Glyphs.Unpin : Glyphs.Pin, NotesWindowRules.PinTitle(note),
                () => Run(id => NoteStore.Instance?.SetPinned(id, note?.IsPinned != true)), note is not null);
            AddAction("\uE7B8", NotesWindowRules.ArchiveTitle(note), () => Run(ToggleArchive), note is not null);
            // 换颜色（REVIEW G10，mac 工具栏的调色板）：弹出和右键「颜色 ›」同一份纸色菜单
            Button? palette = null;
            palette = AddAction(Glyphs.Palette, "换颜色（Ctrl+. 换下一种）", () =>
            {
                if (SelectedNote is { } current && palette is not null)
                {
                    var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Bottom };
                    NoteSheetView.FillColors(menu.Items, current, _wallMode ? _wallScroll : _rows);
                    menu.ShowAt(palette);
                }
            }, note is not null);
            AddAction("\uE8A7", NotesWindowRules.FloatTitle(note is not null && NoteFloats.IsFloating(note.Id),
                SettingsService.Current.NotesDeckEnabled), FloatSelected, note is { IsActive: true });
            AddAction(Glyphs.Delete, NotesWindowRules.DeleteTitle, () => Run(RemoveSelected), note is not null);
        }

        AddAction(_wallMode ? "\uE8FD" : "\uF0E2", _wallMode ? "换成列表" : "换成便签墙", ToggleLayout, true);
        AddAction(Glyphs.Settings, NotesWindowRules.SettingsTitle, () => ShellRuntime.Instance?.ShowSettings(false, "notes"), true);
    }

    /// <summary>
    /// 空状态的字（REVIEW G10，mac NotesWindowView.empty）：搜不到「没有匹配的便签」+「清除搜索」；全部「还没有便签」+ 两个键；
    /// 归档「归档是空的」+ 一句说明；最近删除「最近删除是空的」+ 留几天。
    /// </summary>
    private void ShowEmpty()
    {
        _emptyDetail.Children.Clear();
        TextBlock Line(string text) => new()
        {
            Text = text,
            Foreground = Theme.SecondaryText(),
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 320,
            HorizontalAlignment = HorizontalAlignment.Center,
        };

        if (Core.Search.Tokens(_search.Text).Length > 0)
        {
            _emptyIcon.Glyph = Glyphs.Search;
            _emptyTitle.Text = "没有匹配的便签";
            var clear = new HyperlinkButton { Content = "清除搜索", HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(4, 2, 4, 2) };
            clear.Click += (_, _) => _search.Text = string.Empty;
            _emptyDetail.Children.Add(clear);
            return;
        }

        switch (_scope)
        {
            case NotesScope.All:
                _emptyIcon.Glyph = "";
                _emptyTitle.Text = "还没有便签";
                _emptyDetail.Children.Add(Line("在这里新建一条 · Ctrl+N"));
                if (ShellRuntime.Instance?.HotKeys.ShortcutFor(HotKeyActions.NoteCapture) is { } capture)
                {
                    _emptyDetail.Children.Add(Line($"在任何地方快速记一条 · {capture}"));
                }

                break;
            case NotesScope.Archive:
                _emptyIcon.Glyph = "";
                _emptyTitle.Text = "归档是空的";
                _emptyDetail.Children.Add(Line("暂时不看的便签可以归档，要用时再取消归档"));
                break;
            default:
                _emptyIcon.Glyph = Glyphs.Delete;
                _emptyTitle.Text = "最近删除是空的";
                _emptyDetail.Children.Add(Line($"删掉的便签在这里留 {NoteBook.TrashDays} 天"));
                break;
        }
    }

    private Button AddAction(string glyph, string name, Action action, bool enabled)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 16 },
            Width = 36,
            Height = 32,
            Padding = new Thickness(0),
            IsEnabled = enabled,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => action();
        _actions.Children.Add(button);
        return button;
    }

    private void Run(Action<string> action)
    {
        if (_selection is { } id)
        {
            action(id);
        }
    }

    private Note? SelectedNote
        => _selection is { } id && NoteStore.Instance?.Book.Find(id) is { } note && NotesWindowRules.Belongs(note, _scope) ? note : null;

    private List<Note> Notes
        => NoteStore.Instance is { } store
            ? store.Book.Search(_search.Text, NotesWindowRules.List(store.Book, _scope))
            : new List<Note>();

    private bool CanReorder => _scope == NotesScope.All && Core.Search.Tokens(_search.Text).Length == 0 && !_wallMode;

    /// <summary>列表 / 墙按现在的视图和搜索词重排；选中的还在就不动，不在了选第一条。</summary>
    private void Populate()
    {
        if (NoteStore.Instance is not { } store)
        {
            return;
        }

        var notes = Notes;
        var ids = notes.Select(note => note.Id).ToList();
        var previous = _selection;
        _selection = NotesWindowRules.SelectionKeeping(_selection, ids);
        if (previous is not null && previous != _selection)
        {
            store.Left(previous);
        }

        _list.Visibility = _wallMode ? Visibility.Collapsed : Visibility.Visible;
        _wall.Visibility = _wallMode ? Visibility.Visible : Visibility.Collapsed;
        _empty.Visibility = notes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (notes.Count == 0)
        {
            ShowEmpty();
        }
        if (_wallMode)
        {
            // 顺序变了（固定、删除、在别处挪了、搜索词筛掉了几张）：卡片滑到新位置（同 mac settle）；只是打字、换时间不动
            var before = _wallSections.SelectMany(section => section.Ids).ToList();
            BuildWallSections();
            ArrangeWall(animate: before.Count > 0 && !before.SequenceEqual(_wallSections.SelectMany(section => section.Ids)));
            if (_editCard.Visibility == Visibility.Visible)
            {
                _cardSheet.Show(SelectedNote?.Id);
                if (SelectedNote is null)
                {
                    CollapseCard();
                }
            }
        }
        else
        {
            FillRows(notes, store);
            _sheet.Show(_selection);
        }

        BuildActions();
        BuildScopes();
    }

    private void FillRows(List<Note> notes, NoteStore store)
    {
        _populating = true;
        try
        {
            _rows.CanReorderItems = CanReorder;
            _rows.AllowDrop = CanReorder;
            _rows.CanDragItems = CanReorder;
            _rows.Items.Clear();
            var dark = Theme.EffectiveTheme == ElementTheme.Dark;
            foreach (var note in notes)
            {
                var row = Row(note, store.Book.SummaryOf(note), dark);
                _rows.Items.Add(row);
                if (note.Id == _selection)
                {
                    _rows.SelectedItem = row;
                }
            }
        }
        finally
        {
            _populating = false;
        }
    }

    private FrameworkElement Row(Note note, NoteBook.Summary summary, bool dark)
    {
        var tone = NotePaper.Of(note).Tone(dark);
        var grid = new Grid { Tag = note.Id, Padding = new Thickness(4, 8, 4, 8), ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var dot = new Ellipse
        {
            Width = 12,
            Height = 12,
            Fill = new SolidColorBrush(Rgb(tone.Paper)),
            Stroke = new SolidColorBrush(Rgb(tone.Strip)),
            StrokeThickness = 1.5,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 4, 0, 0),
        };
        grid.Children.Add(dot);
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(new TextBlock
        {
            Text = summary.Title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        var preview = summary.Preview.Length > 0 ? summary.Preview : "没有更多内容";
        text.Children.Add(new TextBlock
        {
            Text = preview,
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 2,
            TextWrapping = TextWrapping.Wrap,
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var meta = new StackPanel { Spacing = 2, HorizontalAlignment = HorizontalAlignment.Right };
        meta.Children.Add(new TextBlock
        {
            Text = NotesWindowRules.Ago(note, NoteStore.Now, TimeZoneInfo.Local),
            FontSize = 11,
            Foreground = Theme.SecondaryText(),
            HorizontalAlignment = HorizontalAlignment.Right,
        });
        if (summary.Progress is { } progress)
        {
            var tasks = new TextBlock
            {
                Text = Note.ProgressText(progress),
                FontSize = 11,
                Foreground = Theme.SecondaryText(),
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(tasks, Note.ProgressSpoken(progress));
            meta.Children.Add(tasks);
        }

        if (note.IsPinned)
        {
            meta.Children.Add(new FontIcon { Glyph = Glyphs.Pin, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right });
        }

        Grid.SetColumn(meta, 2);
        grid.Children.Add(meta);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(grid, summary.Title);
        grid.ContextFlyout = ContextMenu(note);
        return grid;
    }

    private static Color Rgb(int rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    private void Select(string id)
    {
        if (_selection == id)
        {
            return;
        }

        NoteStore.Instance?.Flush();
        if (_selection is { } old)
        {
            NoteStore.Instance?.Left(old);
        }

        _selection = id;
        if (_wallMode)
        {
            // 编辑卡收着时不往里放（收着的编辑卡拿着编号，空白便签就删不掉）；放大时 ExpandCard 再放
            if (_editCard.Visibility == Visibility.Visible)
            {
                _cardSheet.Show(id);
            }
        }
        else
        {
            _sheet.Show(id);
            RevealSearchHit(_sheet);
        }

        BuildActions();
    }

    /// <summary>在搜着的时候换了一条：正文里标出第一处命中（mac revealSearchHit）。</summary>
    private void RevealSearchHit(NoteSheetView sheet)
    {
        var query = _search.Text;
        var tokens = Core.Search.Tokens(query);
        if (tokens.Length == 0)
        {
            return;
        }

        var body = sheet.Editor.Body;
        foreach (var token in tokens)
        {
            var index = body.IndexOf(token, StringComparison.CurrentCultureIgnoreCase);
            if (index >= 0)
            {
                // ponytail: 用存的正文里的位置（图片令牌在前面时会偏）；mac 去掉令牌和颜色标记再换算回来（NoteStore.firstMatch）。
                DispatcherQueue.TryEnqueue(() => sheet.Editor.Reveal(new NoteRange(index, token.Length)));
                return;
            }
        }
    }

    private void OnRowsReordered(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        if (NoteStore.Instance is not { } store || args.Items.FirstOrDefault() is not FrameworkElement { Tag: string id })
        {
            return;
        }

        var index = _rows.Items.IndexOf(args.Items[0]);
        if (index >= 0)
        {
            store.Move(id, index);
        }
    }

    // ---- 操作 ----

    /// <summary>自检（NotesUiProbe）用的几个口子。</summary>
    internal static NotesWindow? ProbeInstance => _instance;

    internal bool ProbeWall => _wallMode;

    internal void ProbeToggleLayout() => ToggleLayout();

    internal void ProbeExpand(string id) => ExpandCard(id);

    internal void ProbeCollapse() => CollapseCard();

    private void ToggleLayout()
    {
        _wallMode = !_wallMode;
        SettingsService.Current.NotesWindowLayout = _wallMode ? "wall" : "list";
        SettingsService.Save();
        CollapseCard();
        if (!_wallMode)
        {
            ClearWall();
        }

        Populate();
    }

    private void ToggleArchive(string id)
    {
        if (NoteStore.Instance is not { } store || store.Book.Find(id) is not { } note)
        {
            return;
        }

        var next = NotesWindowRules.SelectionAfterRemoving(id, Notes.Select(item => item.Id).ToList());
        var archiving = !note.IsArchived;
        store.SetArchived(id, archiving);
        _selection = next;
        CollapseCard();
        // 归档的按钮叫「取消归档」、连着归档的合并（同 mac，REVIEW R99）
        if (archiving)
        {
            NoteNotices.ShowArchived(id, note.DisplayTitle);
        }
        else
        {
            NoticeHost.Show("已取消归档", note.DisplayTitle, NoticeTone.Normal,
                new NoticeAction("撤销", () => store.SetArchived(id, true, toFront: false)));
        }
    }

    private void RemoveSelected(string id)
    {
        if (NoteStore.Instance is not { } store || store.Book.Find(id) is not { } note)
        {
            return;
        }

        var next = NotesWindowRules.SelectionAfterRemoving(id, Notes.Select(item => item.Id).ToList());
        if (note.DeletedAt is not null)
        {
            _ = EraseSelectedAsync();
            return;
        }

        store.Delete(id);
        _deleted.Add(id);
        _selection = next;
        CollapseCard();
        NoteNotices.ShowDeleted(id, undoKey: true);
    }

    private void FloatSelected()
    {
        if (_selection is { } id)
        {
            NoteFloats.Toggle(id);
            BuildActions();
        }
    }

    private async Task EraseSelectedAsync()
    {
        if (_selection is not { } id || NoteStore.Instance is not { } store || store.Book.Find(id) is not { } note)
        {
            return;
        }

        if (await ConfirmAsync($"永久删除「{note.DisplayTitle}」？", "这条便签会被永久删除，不能撤销。", "永久删除"))
        {
            var next = NotesWindowRules.SelectionAfterRemoving(id, Notes.Select(item => item.Id).ToList());
            store.Erase(id);
            _selection = next;
        }
    }

    private async Task EmptyTrashAsync()
    {
        if (NoteStore.Instance is not { } store || store.Book.Trashed.Count == 0)
        {
            return;
        }

        var count = store.Book.Trashed.Count;
        if (await ConfirmAsync("清空最近删除？", $"里面的 {count} 条便签会被永久删除，不能撤销。", "清空"))
        {
            store.EmptyTrash();
        }
    }

    private async Task<bool> ConfirmAsync(string title, string text, string verb)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = title,
            Content = text,
            PrimaryButtonText = verb,
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = _root.XamlRoot,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private MenuFlyout ContextMenu(Note note)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            if (NoteStore.Instance?.Book.Find(note.Id) is not { } current)
            {
                return;
            }

            void Add(string text, string glyph, Action action)
            {
                var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
                item.Click += (_, _) => action();
                menu.Items.Add(item);
            }

            if (current.DeletedAt is not null)
            {
                Add(NotesWindowRules.RestoreTitle, Glyphs.Undo, () => NoteStore.Instance?.Restore(current.Id));
                Add(NotesWindowRules.EraseTitle, Glyphs.Delete, () =>
                {
                    _selection = current.Id;
                    _ = EraseSelectedAsync();
                });
                return;
            }

            var colors = new MenuFlyoutSubItem { Text = NotesWindowRules.ColorTitle };
            NoteSheetView.FillColors(colors.Items, current, _wallMode ? _wallScroll : _rows);
            menu.Items.Add(colors);
            Add(NotesWindowRules.PinTitle(current), current.IsPinned ? Glyphs.Unpin : Glyphs.Pin,
                () => NoteStore.Instance?.SetPinned(current.Id, !current.IsPinned));
            Add(NotesWindowRules.ArchiveTitle(current), "\uE7B8", () => ToggleArchive(current.Id));
            if (current.IsActive)
            {
                Add(NotesWindowRules.FloatTitle(NoteFloats.IsFloating(current.Id), SettingsService.Current.NotesDeckEnabled), "\uE8A7",
                    () => NoteFloats.Toggle(current.Id));
            }

            Add(NotesWindowRules.SingleExportTitle, Glyphs.Save, () => _ = NotesTransfer.ExportOneAsync(current.Id, Content.XamlRoot));
            menu.Items.Add(new MenuFlyoutSeparator());
            Add(NotesWindowRules.DeleteTitle, Glyphs.Delete, () => RemoveSelected(current.Id));
        };
        return menu;
    }

    // ---- 便签墙 ----
    // 只建可见区附近的卡片（R108，mac NotesWallView + ListWindow）：位置全按排法算（NoteWall.Arrange），卡片的高按便签记下（_cardHeights：
    // 标题、正文、固定、删没删没变就不再量）；顶在可见区附近的（NoteWall.Reach）当场量，往下的先按 EstimatedHeight 排、在后面几轮分批量好
    // （一轮最多 8 ms，量完按真的高重排一次，挪的都在看不见的地方）。只建 NoteWall.Visible 那几张（加上方向键挑中的、正拖着的），
    // 滚动位置按段记，跨段才重算；卡片的视图按便签留着（_wallViews），滚出去的拆掉。
    // 拖动排序（R108，mac cardGesture）：按下就开始跟，挪过 4 才算拖（只在「全部」里、没在搜索时；触屏不拖，点一下照样开）；被拖的跟着指针走、
    // 立正，指针进到同一段里另一张的里面（四边各收 20%）时它让到那个位置，别的卡片滑开（glide）；落点只看拖动开始时那份排法
    // （NoteWall.DropTarget）；松手按 NoteWall.StoreIndex 写回仓库的顺序（NoteBook.Move：只改它自己的顺序值、记改顺序的时刻，同步照合）。
    // 拖到可见区外不会自己滚（同 mac 的 ponytail）。

    /// <summary>卡片的高看的东西：显示的标题、正文、固定（标题让出图钉的位置）、在不在最近删除（那里显示原文）。</summary>
    private readonly record struct CardKey(string Title, string Body, bool Pinned, bool Deleted);

    /// <summary>墙上建着的一张：外层 holder（摆在墙上、拖动让位时 Composition 挪它）、卡片本身（纸、倾斜、挑中时的描边）、底下那行小字（每次重排换一下时间）。
    /// Offset 是 holder 现在被挪向的位移（拖动让位时不为 0）。</summary>
    private sealed class WallCard(CardKey key, int color, bool dark, Grid holder, Border card, TextBlock footer)
    {
        public CardKey Key { get; } = key;
        public int Color { get; } = color;
        public bool Dark { get; } = dark;
        public Grid Holder { get; } = holder;
        public Border Card { get; } = card;
        public TextBlock Footer { get; } = footer;
        public Vector2 Offset { get; set; }
        public bool Placed { get; set; }
    }

    /// <summary>正拖着的那张：编号、拖动开始时那份排法里原来是第几张、现在让到第几张、按下时指针离卡片左上角多远。</summary>
    private sealed class WallDrag(string id, int from, Vector2 grab)
    {
        public string Id { get; } = id;
        public int From { get; } = from;
        public int To { get; set; } = from;
        public Vector2 Grab { get; } = grab;
    }

    private readonly Dictionary<string, (CardKey Key, double Height)> _cardHeights = new(StringComparer.Ordinal);
    private readonly Dictionary<string, WallCard> _wallViews = new(StringComparer.Ordinal);
    private readonly List<TextBlock> _wallHeaders = new();
    private readonly HashSet<string> _pendingHeights = new(StringComparer.Ordinal);
    private List<(string? Title, IReadOnlyList<string> Ids)> _wallSections = new();
    private Dictionary<string, Note> _wallNotes = new(StringComparer.Ordinal);
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _measureTimer;
    private int _wallBand;
    private double _wallWidth;

    /// <summary>拖动开始时那份排法（落点只看它）；拖着时墙上画的是让过位的那份（_wallLayout）。</summary>
    private NoteWall.Layout? _wallBase;
    private WallDrag? _wallDrag;

    // 按下了一张卡片（还没算拖）：哪张、按下的地方（墙的坐标）
    private string? _wallPressed;
    private Vector2 _wallPressedAt;

    /// <summary>能拖动排序：「全部」里、没在搜索（墙；列表另有 CanReorder）。</summary>
    private bool CanReorderWall => _scope == NotesScope.All && Core.Search.Tokens(_search.Text).Length == 0;

    private double WallViewport => _wallScroll.ViewportHeight > 0 ? _wallScroll.ViewportHeight : 600;

    /// <summary>按现在的视图、搜索词分好段（固定的在前，最近删除里不分）；仓库变了、换了视图 / 搜索词时调，之后 ArrangeWall。</summary>
    private void BuildWallSections()
    {
        var notes = Notes;
        _wallNotes = notes.ToDictionary(note => note.Id, StringComparer.Ordinal);
        var pinned = notes.Where(note => note.IsPinned && _scope != NotesScope.Trash).Select(note => note.Id).ToList();
        var others = notes.Where(note => !(note.IsPinned && _scope != NotesScope.Trash)).Select(note => note.Id).ToList();
        _wallSections = _scope == NotesScope.Trash || pinned.Count == 0
            ? new List<(string? Title, IReadOnlyList<string> Ids)> { (null, notes.Select(note => note.Id).ToList()) }
            : new List<(string? Title, IReadOnlyList<string> Ids)> { ("已固定", pinned), ("其他", others) };
        if (NoteStore.Instance is { } store)
        {
            // 不在了的便签不再记它的高
            foreach (var gone in _cardHeights.Keys.Where(id => store.Book.Find(id) is null).ToList())
            {
                _cardHeights.Remove(gone);
            }
        }
    }

    /// <summary>
    /// 排墙、建看得见的卡片。animate：位置变了的卡片从原来画在的地方滑过去（顺序变了、拖完落下；同 mac：窗口改宽、打字变高、滚动不动画）。
    /// 拖着一张时墙上是让过位的样子（各段的张数不变，只在同一段里挪）。
    /// </summary>
    private void ArrangeWall(bool animate = false)
    {
        if (!_wallMode || NoteStore.Instance is not { } store)
        {
            return;
        }

        var width = _wallScroll.ActualWidth > 0 ? _wallScroll.ActualWidth : 1000;
        animate &= Math.Abs(width - _wallWidth) < 0.5;
        _wallWidth = width;
        var ordered = _wallSections.SelectMany(section => section.Ids).ToList();
        var reach = NoteWall.Reach(_wallBand, WallViewport);
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var built = new Dictionary<string, WallCard>(StringComparer.Ordinal);
        _pendingHeights.Clear();
        var based = NoteWall.Arrange(_wallSections, width, (index, top) => HeightOf(store, ordered[index], top < reach, dark, built));
        _wallBase = based;
        var shown = based;
        if (_wallDrag is { } drag)
        {
            if (drag.From >= based.Ids.Count || based.Ids[drag.From] != drag.Id)
            {
                // 拖着的时候墙变了（它被删了、别处改了顺序）：当没拖
                _wallDrag = null;
            }
            else if (drag.To != drag.From)
            {
                shown = ArrangeMoved(drag, width);
            }
        }

        _wallLayout = shown;
        _wallIds = shown.Ids.ToList();
        _wallCanvas.Height = shown.Height;
        _wallCanvas.Width = width;
        PlaceHeaders(shown);
        Materialize(store, shown, dark, built, animate);
        MarkWallFocus(bringIntoView: false);
        if (_pendingHeights.Count > 0)
        {
            StartMeasuring();
        }
    }

    /// <summary>拖着时让过位的各段：第 from 张挪成第 to 张（同一段里），各段张数不变。</summary>
    private List<(string? Title, IReadOnlyList<string> Ids)> MovedSections(int from, int to)
    {
        var moved = NoteWall.Moved(_wallSections.SelectMany(section => section.Ids).ToList(), from, to);
        var result = new List<(string? Title, IReadOnlyList<string> Ids)>();
        var start = 0;
        foreach (var (title, ids) in _wallSections)
        {
            result.Add((title, moved.GetRange(start, ids.Count)));
            start += ids.Count;
        }

        return result;
    }

    /// <summary>拖着时让过位的那份排法：卡片的高只用记下的（没量过的按估计的），不当场量。</summary>
    private NoteWall.Layout ArrangeMoved(WallDrag drag, double width)
    {
        var sections = MovedSections(drag.From, drag.To);
        var ids = sections.SelectMany(section => section.Ids).ToList();
        return NoteWall.Arrange(sections, width,
            (index, _) => _cardHeights.TryGetValue(ids[index], out var cached) ? cached.Height : NoteWall.EstimatedHeight);
    }

    /// <summary>一张卡片的高：记下的（标题、正文、固定、删没删没变）；没有就看要不要当场量——顶在可见区附近的量（顺手把卡片建好留给 Materialize），
    /// 往下的先按估计的高、记进待量的。</summary>
    private double HeightOf(NoteStore store, string id, bool measureNow, bool dark, Dictionary<string, WallCard> built)
    {
        if (!_wallNotes.TryGetValue(id, out var note))
        {
            return NoteWall.EstimatedHeight;
        }

        var summary = store.Book.SummaryOf(note);
        var key = new CardKey(summary.Title, note.Body, note.IsPinned, note.DeletedAt is not null);
        if (_cardHeights.TryGetValue(id, out var cached) && cached.Key == key)
        {
            return cached.Height;
        }

        if (!measureNow)
        {
            // 往下的先不量：改过的按上次量的高（比估计的近），没量过的按估计的
            _pendingHeights.Add(id);
            return _cardHeights.TryGetValue(id, out var stale) ? stale.Height : NoteWall.EstimatedHeight;
        }

        var (card, height) = Card(note, summary, key, dark);
        _cardHeights[id] = (key, height);
        built[id] = card;
        return height;
    }

    /// <summary>往下那些按估计的高排着的：一轮最多量 8 ms（按墙上的顺序），都量好了按真的高重排一次。拖着的时候不量。</summary>
    private void StartMeasuring()
    {
        if (_measureTimer is null)
        {
            _measureTimer = DispatcherQueue.CreateTimer();
            _measureTimer.Interval = TimeSpan.FromMilliseconds(16);
            _measureTimer.Tick += (_, _) => MeasureSome();
        }

        if (!_measureTimer.IsRunning)
        {
            _measureTimer.Start();
        }
    }

    private void MeasureSome()
    {
        if (_wallDrag is not null || _wallPressed is not null)
        {
            return;
        }

        if (!_wallMode || NoteStore.Instance is not { } store || _pendingHeights.Count == 0)
        {
            _measureTimer?.Stop();
            return;
        }

        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        foreach (var id in _wallSections.SelectMany(section => section.Ids).Where(_pendingHeights.Contains).ToList())
        {
            _pendingHeights.Remove(id);
            if (_wallNotes.TryGetValue(id, out var note))
            {
                var summary = store.Book.SummaryOf(note);
                var key = new CardKey(summary.Title, note.Body, note.IsPinned, note.DeletedAt is not null);
                _cardHeights[id] = (key, Card(note, summary, key, dark).Height);
            }

            if (clock.ElapsedMilliseconds >= 8)
            {
                return;
            }
        }

        _measureTimer?.Stop();
        ArrangeWall();
    }

    private void PlaceHeaders(NoteWall.Layout layout)
    {
        foreach (var old in _wallHeaders)
        {
            _wallCanvas.Children.Remove(old);
        }

        _wallHeaders.Clear();
        foreach (var header in layout.Headers)
        {
            var label = new TextBlock { Text = header.Title, FontSize = 12, Foreground = Theme.SecondaryText() };
            Canvas.SetLeft(label, header.Frame.X);
            Canvas.SetTop(label, header.Frame.Y + 4);
            _wallCanvas.Children.Add(label);
            _wallHeaders.Add(label);
        }
    }

    /// <summary>建 NoteWall.Visible 那几张（留着的视图照用、换一下底下的时间；改过的重建），摆到排法给的位置，滚出去的拆掉。</summary>
    private void Materialize(NoteStore store, NoteWall.Layout layout, bool dark, Dictionary<string, WallCard> built, bool animate)
    {
        var visible = NoteWall.Visible(layout, _wallBand, WallViewport, new[] { _wallFocus, _wallDrag?.Id });
        var wanted = new HashSet<string>(StringComparer.Ordinal);
        foreach (var index in visible)
        {
            var id = layout.Ids[index];
            if (!_wallNotes.TryGetValue(id, out var note))
            {
                continue;
            }

            wanted.Add(id);
            var summary = store.Book.SummaryOf(note);
            var key = new CardKey(summary.Title, note.Body, note.IsPinned, note.DeletedAt is not null);
            if (!_wallViews.TryGetValue(id, out var view) || view.Key != key || view.Color != note.Color || view.Dark != dark)
            {
                if (view is not null)
                {
                    _wallCanvas.Children.Remove(view.Holder);
                }

                if (built.TryGetValue(id, out var fresh) && fresh.Key == key)
                {
                    view = fresh;
                }
                else
                {
                    var made = Card(note, summary, key, dark);
                    view = made.Card;
                    _cardHeights[id] = (key, made.Height);
                }

                _wallViews[id] = view;
                _wallCanvas.Children.Add(view.Holder);
            }
            else
            {
                view.Footer.Text = FooterText(note, summary);
            }

            var frame = layout.Frames[index];
            view.Holder.Width = frame.Width;
            view.Holder.Height = frame.Height;
            view.Card.Width = frame.Width;
            view.Card.Height = frame.Height;
            var dragged = _wallDrag?.Id == id;
            // 倾斜不是动效：系统关了动画效果也照样斜（同 mac）；拖着的那张立正
            view.Card.RenderTransform = new RotateTransform { Angle = dragged ? 0 : layout.Tilts[index] };
            Canvas.SetZIndex(view.Holder, dragged ? 10_000 : 0);
            if (dragged)
            {
                continue;
            }

            Put(view, new Vector2((float)frame.X, (float)frame.Y), animate);
        }

        foreach (var gone in _wallViews.Keys.Where(id => !wanted.Contains(id)).ToList())
        {
            _wallCanvas.Children.Remove(_wallViews[gone].Holder);
            _wallViews.Remove(gone);
        }
    }

    /// <summary>把一张摆到 target（墙的坐标）：animate 时从它现在画在的地方（位置 + 正被挪向的位移）滑过去（glide），不然直接到。</summary>
    private static void Put(WallCard view, Vector2 target, bool animate)
    {
        var current = new Vector2((float)Canvas.GetLeft(view.Holder), (float)Canvas.GetTop(view.Holder)) + view.Offset;
        Canvas.SetLeft(view.Holder, target.X);
        Canvas.SetTop(view.Holder, target.Y);
        var from = current - target;
        if (animate && view.Placed && from.Length() > 0.5f)
        {
            NoteMotion.SetTranslation(view.Holder, new Vector3(from, 0));
            NoteMotion.TranslateTo(view.Holder, Vector3.Zero, MotionCurve.Glide);
        }
        else if (view.Offset != Vector2.Zero)
        {
            NoteMotion.SetTranslation(view.Holder, Vector3.Zero);
        }

        view.Offset = Vector2.Zero;
        view.Placed = true;
    }

    // ---- 便签墙的拖动排序（R108）

    private void OnCardPressed(string id, Border card, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_wallCanvas);
        if (!point.Properties.IsLeftButtonPressed || e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touch
            || _editCard.Visibility == Visibility.Visible)
        {
            return;
        }

        _wallPressed = id;
        _wallPressedAt = new Vector2((float)point.Position.X, (float)point.Position.Y);
        card.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnCardMoved(string id, PointerRoutedEventArgs e)
    {
        if (_wallPressed != id)
        {
            return;
        }

        var position = e.GetCurrentPoint(_wallCanvas).Position;
        var point = new Vector2((float)position.X, (float)position.Y);
        if (_wallDrag is null)
        {
            if (!CanReorderWall || (point - _wallPressedAt).Length() < NoteWall.DragSlop || _wallBase is not { } based
                || based.IndexOf(id) is not { } from)
            {
                return;
            }

            var frame = based.Frames[from];
            _wallDrag = new WallDrag(id, from, _wallPressedAt - new Vector2((float)frame.X, (float)frame.Y));
            if (_wallViews.TryGetValue(id, out var lifted))
            {
                // 抬起来：立正、压在别的上面，跟着指针（不做动画）
                NoteMotion.SetTranslation(lifted.Holder, Vector3.Zero);
                lifted.Offset = Vector2.Zero;
                lifted.Card.RenderTransform = new RotateTransform { Angle = 0 };
                Canvas.SetZIndex(lifted.Holder, 10_000);
            }
        }

        if (_wallDrag is not { } drag)
        {
            return;
        }

        if (_wallViews.TryGetValue(id, out var view))
        {
            var origin = point - drag.Grab;
            Canvas.SetLeft(view.Holder, origin.X);
            Canvas.SetTop(view.Holder, origin.Y);
        }

        if (_wallBase is not { } baseLayout)
        {
            return;
        }

        var to = NoteWall.DropTarget(drag.From, drag.To, new PointD(point.X, point.Y), baseLayout);
        if (to == drag.To)
        {
            return;
        }

        // 让位：按让过位的那份排法，别的卡片滑到新位置（glide）；被拖的那张不跟着滑
        drag.To = to;
        var moved = to == drag.From ? baseLayout : ArrangeMoved(drag, _wallWidth);
        _wallLayout = moved;
        _wallIds = moved.Ids.ToList();
        for (var index = 0; index < moved.Ids.Count; index++)
        {
            if (moved.Ids[index] == id || !_wallViews.TryGetValue(moved.Ids[index], out var other))
            {
                continue;
            }

            var target = new Vector2((float)moved.Frames[index].X, (float)moved.Frames[index].Y)
                         - new Vector2((float)Canvas.GetLeft(other.Holder), (float)Canvas.GetTop(other.Holder));
            if (target != other.Offset)
            {
                other.Offset = target;
                NoteMotion.TranslateTo(other.Holder, new Vector3(target, 0), MotionCurve.Glide);
            }
        }
    }

    private void OnCardReleased(string id, Border card, PointerRoutedEventArgs e)
    {
        if (_wallPressed != id)
        {
            return;
        }

        var position = e.GetCurrentPoint(_wallCanvas).Position;
        var moved = (new Vector2((float)position.X, (float)position.Y) - _wallPressedAt).Length();
        var drag = _wallDrag;
        // 先清掉按着的状态再放开指针：放开时同步来的「丢了指针」就不再当成取消
        _wallPressed = null;
        _wallDrag = null;
        card.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
        if (drag is null)
        {
            // 没挪开：点了一下 = 打开编辑卡（双击的第二下落在编辑卡后面那层暗上，不再开一次）
            if (moved < NoteWall.DragSlop && _editCard.Visibility != Visibility.Visible)
            {
                ExpandCard(id);
            }

            return;
        }

        if (drag.To != drag.From && NoteStore.Instance is { } store && _wallBase is { } based && based.SectionOf(drag.From) is { } section
            && NoteWall.StoreIndex(drag.Id, NoteWall.Moved(based.Ids, drag.From, drag.To), based.Sections[section],
                store.Book.Active.Select(note => note.Id).ToList()) is { } at)
        {
            store.Move(drag.Id, at);
            BuildWallSections();
        }

        // 落下：被拖的那张从松手的地方、让过位的从让到的地方滑到排好的位置（glide）
        ArrangeWall(animate: true);
    }

    private void OnCardCaptureLost(string id)
    {
        if (_wallPressed != id)
        {
            return;
        }

        _wallPressed = null;
        if (_wallDrag is not null)
        {
            // 被系统取消了：当没拖，都滑回原位
            _wallDrag = null;
            ArrangeWall(animate: true);
        }
    }

    // ---- 便签墙的键盘（PLAN-v20 N3）

    private NoteWall.Layout? _wallLayout;
    private List<string> _wallIds = new();

    /// <summary>方向键挑中的那张（便签编号；墙重排后照样认得）。</summary>
    private string? _wallFocus;

    private void OnWallKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_wallMode || _editCard.Visibility == Visibility.Visible || _wallLayout is not { } layout || _wallIds.Count == 0)
        {
            return;
        }

        NoteWall.Direction? direction = e.Key switch
        {
            VirtualKey.Up => NoteWall.Direction.Up,
            VirtualKey.Down => NoteWall.Direction.Down,
            VirtualKey.Left => NoteWall.Direction.Left,
            VirtualKey.Right => NoteWall.Direction.Right,
            _ => null,
        };
        if (direction is { } way)
        {
            MoveWallFocus(way, layout);
            e.Handled = true;
        }
        else if (e.Key is VirtualKey.Enter or VirtualKey.Space && _wallFocus is { } id && _wallIds.Contains(id))
        {
            ExpandCard(id);
            e.Handled = true;
        }
        else if (e.Key is VirtualKey.Delete or VirtualKey.Back && _wallFocus is { } target && _wallIds.Contains(target))
        {
            // 墙上挑中的那张按 Delete / Backspace 删（同 mac ⌘⌫ / ⌫，REVIEW R99；以前只有列表认 Delete）
            RemoveSelected(target);
            _wallFocus = _selection;
            e.Handled = true;
        }
    }

    /// <summary>往 direction 挑下一张（还没挑过的先挑第一张）；走不动就不动。挑中的那张没建（在可见区外）就先建出来再滚过去。</summary>
    private void MoveWallFocus(NoteWall.Direction direction, NoteWall.Layout layout)
    {
        var current = _wallFocus is { } id ? _wallIds.IndexOf(id) : -1;
        var next = current < 0 ? 0 : NoteWall.Neighbor(current, direction, layout);
        if (next is not { } index || index >= _wallIds.Count)
        {
            return;
        }

        _wallFocus = _wallIds[index];
        if (!_wallViews.ContainsKey(_wallFocus))
        {
            ArrangeWall();
        }

        MarkWallFocus(bringIntoView: true);
    }

    /// <summary>挑中的那张描一圈强调色（别的去掉），要的话滚进视野；读屏念它的标题。</summary>
    private void MarkWallFocus(bool bringIntoView)
    {
        foreach (var (id, view) in _wallViews)
        {
            var focused = id == _wallFocus;
            view.Card.BorderBrush = focused ? new SolidColorBrush(Theme.AccentColor) : null;
            view.Card.BorderThickness = new Thickness(focused ? 2 : 0);
        }

        if (bringIntoView && _wallFocus is { } focus && _wallViews.TryGetValue(focus, out var target))
        {
            target.Holder.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = !Motion.Reduced, VerticalAlignmentRatio = 0.5 });
            Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_wallScroll)?.RaiseNotificationEvent(
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.ActionCompleted,
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.MostRecent,
                Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(target.Card), "notes-wall-focus");
        }
    }

    /// <summary>自检：在墙上按一下方向键（不发真按键，直接走同一条路），返回挑中的那张。</summary>
    internal string? ProbeWallKey(NoteWall.Direction direction)
    {
        if (_wallLayout is { } layout)
        {
            MoveWallFocus(direction, layout);
        }

        return _wallFocus;
    }

    /// <summary>离开便签墙（换成列表）：建着的卡片都拆掉（记下的高留着，换回来不用再量）。</summary>
    private void ClearWall()
    {
        _measureTimer?.Stop();
        _wallDrag = null;
        _wallPressed = null;
        foreach (var view in _wallViews.Values)
        {
            _wallCanvas.Children.Remove(view.Holder);
        }

        _wallViews.Clear();
    }

    /// <summary>墙上一张卡片底下那行：相对时间（最近删除里是删的时间），有任务的接着写进度。</summary>
    private static string FooterText(Note note, NoteBook.Summary summary)
        => NotesWindowRules.Ago(note, NoteStore.Now, TimeZoneInfo.Local) +
           (summary.Progress is { } progress ? " · " + Note.ProgressText(progress) : string.Empty);

    private static Color Shade(NoteShade shade, int paper) => Rgb(NotePaper.Mix(shade.Rgb, paper, shade.Opacity));

    /// <summary>
    /// 墙上的一张卡片：色条、标题（一两行）、开头几行字（截断）、底下的相对时间；量好的高。外面套一层 holder（摆在墙上、拖动让位时挪它），
    /// 卡片本身斜着（RenderTransform）。按下 / 拖动 / 松手走墙的拖动排序（OnCard*）；触屏不拖，点一下开编辑卡。
    /// </summary>
    private (WallCard Card, double Height) Card(Note note, NoteBook.Summary summary, CardKey key, bool dark)
    {
        var paper = NotePaper.Of(note);
        var tone = paper.Tone(dark);
        var ink = new SolidColorBrush(Rgb(tone.Ink));
        var secondary = new SolidColorBrush(Rgb(NotePaper.Mix(tone.Ink, tone.Paper, NotePaper.SecondaryOpacity)));
        var title = new TextBlock
        {
            Text = summary.Title,
            FontSize = NoteWall.TitleSize,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            LineHeight = NoteWall.TitleLine,
            MaxLines = NoteWall.TitleLines,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ink,
            Width = NoteWall.TitleWidthFor(note.IsPinned),
        };
        var body = note.DeletedAt is null ? CardBody(note, paper, tone, dark, ink) : DeletedBody(note, ink);
        title.Measure(new Windows.Foundation.Size(title.Width, double.PositiveInfinity));
        body?.Measure(new Windows.Foundation.Size(NoteWall.TextWidth, double.PositiveInfinity));
        var metrics = NoteWall.Card(note.IsPinned, title.DesiredSize.Height, body?.DesiredSize.Height ?? 0);
        var stack = new StackPanel { Spacing = NoteWall.TitleGap, Padding = new Thickness(NoteWall.Padding, NoteWall.TopInset, NoteWall.Padding, 0) };
        stack.Children.Add(title);
        if (body is not null)
        {
            // 超出卡片的截掉（露出 BodyRoom 那么高）
            body.MaxHeight = metrics.BodyRoom;
            body.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, NoteWall.TextWidth, metrics.BodyRoom) };
            stack.Children.Add(body);
        }

        var footer = new TextBlock
        {
            Text = FooterText(note, summary),
            FontSize = 11,
            Foreground = secondary,
            Margin = new Thickness(NoteWall.Padding, 0, NoteWall.Padding, NoteWall.BottomInset),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        var grid = new Grid { Tag = note.Id };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(NoteWall.StripHeight) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(new Border { Background = new SolidColorBrush(Rgb(tone.Strip)) });
        Grid.SetRow(stack, 1);
        grid.Children.Add(stack);
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);
        if (note.IsPinned)
        {
            var pin = new FontIcon
            {
                Glyph = Glyphs.Pin,
                FontSize = 12,
                Foreground = secondary,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 12, 10, 0),
            };
            Grid.SetRow(pin, 1);
            grid.Children.Add(pin);
        }

        var card = new Border
        {
            Background = new SolidColorBrush(Rgb(tone.Paper)),
            CornerRadius = new CornerRadius(6),
            Child = grid,
            Translation = new Vector3(0, 0, 8),
            Shadow = new ThemeShadow(),
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, summary.Title);
        var id = note.Id;
        card.PointerPressed += (_, e) => OnCardPressed(id, card, e);
        card.PointerMoved += (_, e) => OnCardMoved(id, e);
        card.PointerReleased += (_, e) => OnCardReleased(id, card, e);
        card.PointerCaptureLost += (_, _) => OnCardCaptureLost(id);
        // 鼠标、笔的点开在松手时认（OnCardReleased：和拖动排序是同一个手势）；触屏不拖，点一下照样开
        card.Tapped += (_, e) =>
        {
            if (e.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touch)
            {
                ExpandCard(id);
            }
        };
        card.ContextFlyout = ContextMenu(note);
        var holder = new Grid { Children = { card } };
        return (new WallCard(key, note.Color, dark, holder, card, footer), metrics.Height);
    }

    /// <summary>
    /// 卡片上那段字：标题之后的开头几行（NoteWall.CardLines，PLAN-v16 V2）——标题按几级标题的字号加粗（同正文编辑器）、
    /// 无序列表的符号照原样画成淡色（R108，同 mac「列表符号变淡」：墨的 50%，高对比度 75%）、别的行去掉行内标记；
    /// 代码块里的行用等宽字、垫代码的底（R108，同 mac：逐行铺满字的宽，墨的 8%；不是正文编辑器里那块圆角的底）。
    /// 连着的普通行排在一个 TextBlock 里，连着的代码行排在一块垫了底的 TextBlock 里，从上到下摞起来。没有字返回 null。
    /// </summary>
    private static StackPanel? CardBody(Note note, NotePaper paper, NoteTone tone, bool dark, Brush ink)
    {
        var contrast = Theme.IsHighContrast;
        var faded = new SolidColorBrush(Shade(paper.FadedInk(dark, contrast), tone.Paper));
        var codeFill = new SolidColorBrush(Shade(paper.CodeFill(dark), tone.Paper));
        var mono = new FontFamily("Cascadia Mono, Consolas");
        var panel = new StackPanel { Width = NoteWall.TextWidth };
        TextBlock? text = null;
        TextBlock? code = null;
        foreach (var line in NoteWall.CardLines(note))
        {
            if (line.Kind == NoteWall.CardLineKind.Code)
            {
                text = null;
                if (code is null)
                {
                    code = new TextBlock { FontSize = NoteWall.BodySize, FontFamily = mono, TextWrapping = TextWrapping.Wrap, Foreground = ink };
                    panel.Children.Add(new Border { Background = codeFill, Child = code });
                }
                else
                {
                    code.Inlines.Add(new Microsoft.UI.Xaml.Documents.LineBreak());
                }

                code.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = line.Text });
                continue;
            }

            code = null;
            if (text is null)
            {
                text = new TextBlock { FontSize = NoteWall.BodySize, TextWrapping = TextWrapping.Wrap, Foreground = ink };
                panel.Children.Add(text);
            }
            else
            {
                text.Inlines.Add(new Microsoft.UI.Xaml.Documents.LineBreak());
            }

            switch (line.Kind)
            {
                case NoteWall.CardLineKind.Heading:
                    text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run
                    {
                        Text = line.Text,
                        FontSize = NoteStyles.HeadingSize(line.Level, NoteWall.BodySize),
                        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    });
                    break;
                case NoteWall.CardLineKind.Bullet:
                    text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = new string(' ', line.Indent) + line.Lead, Foreground = faded });
                    text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = line.Text });
                    break;
                default:
                    text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = line.Text });
                    break;
            }
        }

        return panel.Children.Count > 0 ? panel : null;
    }

    /// <summary>最近删除里的卡片：原文（令牌换成「[图片]」），不加样式。没有字返回 null。</summary>
    private static StackPanel? DeletedBody(Note note, Brush ink)
        => NoteImages.Display(note.Body) is { Length: > 0 } text
            ? new StackPanel
            {
                Width = NoteWall.TextWidth,
                Children = { new TextBlock { Text = text, FontSize = NoteWall.BodySize, TextWrapping = TextWrapping.Wrap, Foreground = ink } },
            }
            : null;

    private void ExpandCard(string id)
    {
        Select(id);
        _wallFocus = id;
        var size = NoteWall.EditorSize((_wall.ActualWidth > 0 ? _wall.ActualWidth : 1000, _wall.ActualHeight > 0 ? _wall.ActualHeight : 600));
        _cardSheet.View.Width = size.Width;
        _cardSheet.View.Height = size.Height;
        _cardSheet.Show(id);
        _editCard.Visibility = Visibility.Visible;
        Motion.Entrance(_cardSheet.View);
        DispatcherQueue.TryEnqueue(() =>
        {
            _cardSheet.FocusBody();
            RevealSearchHit(_cardSheet);
        });
        BuildActions();
    }

    private void CollapseCard()
    {
        if (_editCard.Visibility != Visibility.Visible)
        {
            return;
        }

        NoteStore.Instance?.Flush();
        _editCard.Visibility = Visibility.Collapsed;
        // 放掉编辑卡里的那条（落盘、Left 都在 Show(null) 里）：收起来的编辑卡还拿着编号的话，空白便签删不掉
        _wallFocus = _cardSheet.NoteId ?? _wallFocus;
        _cardSheet.Show(null);
        BuildActions();
        // 焦点回到墙上，方向键接着从这张走（PLAN-v20 N3）
        _wallScroll.Focus(FocusState.Keyboard);
        MarkWallFocus(bringIntoView: false);
    }

    // ---- 按键 ----

    private static bool Down(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = Down(VirtualKey.Control);
        if (control && e.Key == VirtualKey.N)
        {
            NewNote();
            e.Handled = true;
        }
        else if (control && e.Key == VirtualKey.F && !(_sheet.Editor.HasFocus || _cardSheet.Editor.HasFocus))
        {
            _search.Focus(FocusState.Keyboard);
            _search.SelectAll();
            e.Handled = true;
        }
        else if (control && e.Key is VirtualKey.Number1 or VirtualKey.Number2)
        {
            // Ctrl+1 便签墙、Ctrl+2 列表（同工具栏上的切换）。
            if (_wallMode != (e.Key == VirtualKey.Number1))
            {
                ToggleLayout();
            }

            e.Handled = true;
        }
        else if (control && e.Key == VirtualKey.Z && !Down(VirtualKey.Shift) && FocusManager.GetFocusedElement(Content.XamlRoot) is not TextBox
                 && !(_sheet.Editor.HasFocus || _cardSheet.Editor.HasFocus) && _deleted.Count > 0)
        {
            // 焦点不在输入框里：放回刚删的那条（连着删了几条就一条条放回）。
            var id = _deleted[^1];
            _deleted.RemoveAt(_deleted.Count - 1);
            NoteStore.Instance?.Restore(id);
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape && _editCard.Visibility == Visibility.Visible)
        {
            CollapseCard();
            e.Handled = true;
        }
        else if (control && e.Key == VirtualKey.W && _editCard.Visibility != Visibility.Visible)
        {
            // 没开编辑卡时 Ctrl+W 关窗（同 mac ⌘W，REVIEW R99）
            Close();
            e.Handled = true;
        }
    }
}
