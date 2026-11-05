// 全部便签窗口（PLAN-v13 第 5 批，照 mac Notes/NotesWindow.swift + NotesWindowView.swift + NotesWallView.swift；规则在 Core 的
// NotesWindowRules / NoteWall）：普通窗口（进任务栏和 Alt+Tab，同设置窗；外壳跟 Windows：Mica、系统标题栏）。
// - 三个视图（全部 / 归档 / 最近删除）和搜索（标题 + 正文，同仓库的 Search）；两种显示方式：便签墙（默认）/ 列表，记住上次选的。
// - 列表：左边一列（纸色圆点、标题、摘要、任务进度、相对时间），右边是打开的那条（NoteSheetView）；「全部」里没在搜索时能拖动排序。
// - 便签墙：卡片一样宽、高随内容，瀑布流（NoteWall.Arrange），分「固定的 / 其他」两段；点一张在墙上盖一层、放大成编辑卡（Esc 收回）。
// - 最近删除里只读（令牌换成「[图片]」），工具栏是「放回」「永久删除…」「清空最近删除…」。
// - 右键菜单：颜色 ›、固定、归档、浮在屏幕上、删除（最近删除里是放回、永久删除）。删除 / 归档后提示里能撤销。
// - 按键：Ctrl+N 新建、Ctrl+F 搜索（焦点在正文里时是便签内查找）、Delete（列表拿着焦点时）删除、Esc 收回编辑卡。
// 落盘：打字走仓库（停手再落）；换一条、收回编辑卡、窗口失去激活、关窗口时 Flush。
// ponytail: 便签墙不能拖动排序（mac 能）、卡片一次全画（mac 可见区附近的先建、其余分批建）；几百条以内没事，要再说。
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
    private readonly TextBlock _empty;
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
        _wallScroll = new ScrollViewer { Content = _wallCanvas, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        _wallScroll.SizeChanged += (_, _) => ArrangeWall();
        _wall.Children.Add(_wallScroll);
        _editCard = new Grid { Visibility = Visibility.Collapsed, Background = new SolidColorBrush(Color.FromArgb(64, 0, 0, 0)) };
        _editCard.PointerPressed += (_, e) =>
        {
            if (e.OriginalSource == _editCard)
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

        _empty = new TextBlock
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.SecondaryText(),
            Visibility = Visibility.Collapsed,
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

    private void OnStoreChanged() => DispatcherQueue.TryEnqueue(Populate);

    // ---- 视图、工具栏 ----

    private void BuildScopes()
    {
        _scopes.Children.Clear();
        foreach (var scope in new[] { NotesScope.All, NotesScope.Archive, NotesScope.Trash })
        {
            var count = NoteStore.Instance is { } store ? NotesWindowRules.List(store.Book, scope).Count : 0;
            var button = new ToggleButton
            {
                Content = $"{NotesWindowRules.ScopeTitle(scope)} {count}",
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
        var note = Current;
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
            AddAction("\uE8A7", NotesWindowRules.FloatTitle(note is not null && NoteFloats.IsFloating(note.Id),
                SettingsService.Current.NotesDeckEnabled), FloatSelected, note is { IsActive: true });
            AddAction(Glyphs.Delete, NotesWindowRules.DeleteTitle, () => Run(RemoveSelected), note is not null);
        }

        AddAction(_wallMode ? "\uE8FD" : "\uF0E2", _wallMode ? "换成列表" : "换成便签墙", ToggleLayout, true);
        AddAction(Glyphs.Settings, NotesWindowRules.SettingsTitle, () => ShellRuntime.Instance?.ShowSettings(false, "notes"), true);
    }

    private void AddAction(string glyph, string name, Action action, bool enabled)
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
    }

    private void Run(Action<string> action)
    {
        if (_selection is { } id)
        {
            action(id);
        }
    }

    private Note? Current
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
        _empty.Text = Core.Search.Tokens(_search.Text).Length > 0
            ? "没有搜到"
            : _scope switch
            {
                NotesScope.All => "还没有便签：Ctrl+N 新建一条，或者按快速记一条的快捷键",
                NotesScope.Archive => "没有归档的便签",
                _ => "最近删除是空的：删掉的便签在这里留 30 天",
            };
        if (_wallMode)
        {
            ArrangeWall();
            if (_editCard.Visibility == Visibility.Visible)
            {
                _cardSheet.Show(Current?.Id);
                if (Current is null)
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
            _cardSheet.Show(id);
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

    private void ToggleLayout()
    {
        _wallMode = !_wallMode;
        SettingsService.Current.NotesWindowLayout = _wallMode ? "wall" : "list";
        SettingsService.Save();
        CollapseCard();
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
        NoticeHost.Show(archiving ? NotesWindowRules.ArchivedTitle(1) : "已取消归档", note.DisplayTitle, NoticeTone.Normal,
            new NoticeAction("撤销", () => store.SetArchived(id, note.IsArchived, toFront: false)));
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
        NoticeHost.Show(NotesWindowRules.DeletedTitle(1), "在「最近删除」里留 30 天", NoticeTone.Normal,
            new NoticeAction("撤销", () => store.Restore(id)));
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

        if (await ConfirmAsync($"永久删除「{note.DisplayTitle}」？", "永久删除后找不回来。", "永久删除"))
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
        if (await ConfirmAsync($"清空最近删除（{count} 条）？", "里面的便签会永久删除，找不回来。", "清空"))
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

    private void ArrangeWall()
    {
        if (!_wallMode || NoteStore.Instance is not { } store)
        {
            return;
        }

        var width = _wallScroll.ActualWidth > 0 ? _wallScroll.ActualWidth : 1000;
        var notes = Notes;
        var pinned = notes.Where(note => note.IsPinned && _scope != NotesScope.Trash).ToList();
        var others = notes.Where(note => !(note.IsPinned && _scope != NotesScope.Trash)).ToList();
        var sections = _scope == NotesScope.Trash || pinned.Count == 0
            ? new List<(string? Title, IReadOnlyList<string> Ids)> { (null, notes.Select(note => note.Id).ToList()) }
            : new List<(string? Title, IReadOnlyList<string> Ids)>
            {
                ("固定的", pinned.Select(note => note.Id).ToList()),
                ("其他", others.Select(note => note.Id).ToList()),
            };
        var ordered = sections.SelectMany(section => section.Ids).ToList();
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var cards = new List<FrameworkElement>();
        var layout = NoteWall.Arrange(sections, width, (index, _) =>
        {
            var note = store.Book.Find(ordered[index])!;
            var (card, height) = Card(note, store.Book.SummaryOf(note), dark);
            cards.Add(card);
            return height;
        });
        _wallCanvas.Children.Clear();
        _wallCanvas.Height = layout.Height;
        _wallCanvas.Width = width;
        foreach (var header in layout.Headers)
        {
            var label = new TextBlock { Text = header.Title, FontSize = 12, Foreground = Theme.SecondaryText() };
            Canvas.SetLeft(label, header.Frame.X);
            Canvas.SetTop(label, header.Frame.Y + 4);
            _wallCanvas.Children.Add(label);
        }

        for (var index = 0; index < cards.Count && index < layout.Frames.Count; index++)
        {
            var frame = layout.Frames[index];
            var card = cards[index];
            card.Width = frame.Width;
            card.Height = frame.Height;
            card.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            card.RenderTransform = new RotateTransform { Angle = Motion.Reduced ? 0 : layout.Tilts[index] };
            Canvas.SetLeft(card, frame.X);
            Canvas.SetTop(card, frame.Y);
            _wallCanvas.Children.Add(card);
        }
    }

    /// <summary>墙上的一张卡片：色条、标题（一两行）、开头几行字（截断渐隐）、底下的相对时间；量好的高。</summary>
    private (FrameworkElement Card, double Height) Card(Note note, NoteBook.Summary summary, bool dark)
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
        var excerpt = note.DeletedAt is null ? CardText(note) : NoteImages.Display(note.Body);
        var body = new TextBlock
        {
            Text = excerpt,
            FontSize = NoteWall.BodySize,
            TextWrapping = TextWrapping.Wrap,
            Foreground = ink,
            Width = NoteWall.TextWidth,
        };
        title.Measure(new Windows.Foundation.Size(title.Width, double.PositiveInfinity));
        body.Measure(new Windows.Foundation.Size(body.Width, double.PositiveInfinity));
        var metrics = NoteWall.Card(note.IsPinned, title.DesiredSize.Height, excerpt.Length > 0 ? body.DesiredSize.Height : 0);
        body.MaxHeight = metrics.BodyRoom;
        var stack = new StackPanel { Spacing = NoteWall.TitleGap, Padding = new Thickness(NoteWall.Padding, NoteWall.TopInset, NoteWall.Padding, 0) };
        stack.Children.Add(title);
        if (excerpt.Length > 0)
        {
            stack.Children.Add(body);
        }

        var footer = new TextBlock
        {
            Text = NotesWindowRules.Ago(note, NoteStore.Now, TimeZoneInfo.Local) +
                   (summary.Progress is { } progress ? " · " + Note.ProgressText(progress) : string.Empty),
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
            Translation = new System.Numerics.Vector3(0, 0, 8),
            Shadow = new ThemeShadow(),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, summary.Title);
        card.Tapped += (_, _) => ExpandCard(note.Id);
        card.ContextFlyout = ContextMenu(note);
        return (card, metrics.Height);
    }

    /// <summary>卡片上那段字：标题之后的开头几行（NoteWall.Excerpt），每行去掉藏着的 Markdown 标记、代码块的围栏行不要。</summary>
    private static string CardText(Note note)
    {
        var (text, blocks) = NoteWall.Excerpt(note);
        var builder = new System.Text.StringBuilder(text.Length);
        foreach (var (start, contentsEnd, _) in NoteText.Lines(text))
        {
            var line = text[start..contentsEnd];
            switch (NoteMarkdown.RoleAt(start, blocks))
            {
                case NoteMarkdown.Role.Open or NoteMarkdown.Role.Close:
                    continue;
                case NoteMarkdown.Role.Content:
                    builder.Append(line).Append('\n');
                    break;
                default:
                    builder.Append(NoteMarkdown.Plain(line, blocks: true)).Append('\n');
                    break;
            }
        }

        return builder.ToString().TrimEnd('\n');
    }

    private void ExpandCard(string id)
    {
        Select(id);
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
        if (_selection is { } id)
        {
            NoteStore.Instance?.Left(id);
        }

        BuildActions();
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
    }
}
