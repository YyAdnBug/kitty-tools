// 一条打开着的便签（PLAN-v13 第 5 批，照 mac Notes/NoteSheet.swift + NoteSheetModel.swift）：纸色的一张，顶上一条色条，头部是纸色圆点
// （点了换颜色）、标题、任务、固定、「⋯」（操作菜单，同 Ctrl+K）、关闭；正文是 NoteEditor；底下一行小字（改于 · 字数）。
// **全部便签窗口的右栏 / 便签墙上的编辑卡、屏幕边缘那叠里打开的、浮动便签画的都是它**，外面那层只管怎么摆、怎么关、浮不浮（Host 回调）。
// 纸上的字一律用这条便签的墨色，不用强调色（纸色是内容的颜色）。
// 便签里的按键固定（PLAN-v13 §3.3）：Ctrl+K 操作、Ctrl+P 固定、Ctrl+T 任务、Ctrl+F 查找、Ctrl+Shift+A 归档、Ctrl+Shift+Delete 删除、
// Ctrl+. 换下一种纸色、Ctrl+, 便签设置、Esc / Ctrl+W 关。
// 写标题、正文按这一份记着的编号落，不按「现在开着哪条」：换一条的那一下旧的输入框晚到的那次得落回它自己那条（同 mac）。
// **它自己带着的那张标签**（R108，mac NoteSheet.tab；只在屏幕边缘那叠里打开的、浮动便签上，SetTab）：朝屏幕里面的那一侧一条和标签等宽的竖条，
// 底 = 纸上叠 16% 的色条色（NotePaper.TabFill），竖排的标题（同标签列的排法），和纸之间一道墨 14% 的竖线；点它 = 关掉（那叠里回到那一列，
// 浮着的收回边缘），按着拖 = 把手（Host.TabPressed：那叠里拖出来浮到屏幕上，浮着时挪窗口）。有这张标签时顶上的色条不画（同 mac：颜色靠标签读）。
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using KittyTools.Ui;
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

internal sealed class NoteSheetView
{
    private readonly Border _paper;
    private readonly Border _strip;
    private readonly Grid _layout;
    private readonly Grid _frame;
    private readonly NoteSheetTab _tab;
    private readonly Border _tabRule;
    private TabSide _tabSide;
    private NoteDeckMetrics _tabMetrics = new(1);
    private string? _tabDrawn;
    private readonly Button _dot;
    private readonly TextBox _title;
    private readonly Button _task;
    private readonly Button _pin;
    private readonly Button _more;
    private readonly Button _close;
    private readonly TextBlock _footnote;
    private bool _settingTitle;
    private string? _id;

    /// <summary>外面那层：关（参数 = 用键盘关的：Esc、Ctrl+W；关闭钮、归档、删除之后是 false——那叠里键盘关连那一列一起收、别的回到那一列）、
    /// 浮出去 / 收回来、这一份浮着吗、有没有屏幕边缘那叠可回。</summary>
    public sealed class Host
    {
        public Action<bool> Close { get; init; } = _ => { };

        public Action? ToggleFloating { get; init; }

        public Func<bool> IsFloating { get; init; } = () => false;

        public bool ShowsClose { get; init; } = true;

        /// <summary>按住头部空白处拖（浮动便签挪窗口、那叠里拖出来）。</summary>
        public Action<PointerRoutedEventArgs>? GripPressed { get; init; }

        /// <summary>按下它带着的那张标签（左键）：没挪开就松手 = 关掉 / 收回，按着拖 = 把手。怎么认由外面那层定。</summary>
        public Action<PointerRoutedEventArgs>? TabPressed { get; init; }

        /// <summary>那张标签读屏念什么（同头部的关闭钮：那叠里「关闭便签」，浮着时「收回边缘」/「取消浮动」）。</summary>
        public Func<string> TabName { get; init; } = () => "关闭便签";
    }

    /// <summary>它带着的那张标签在哪一侧：没有（全部便签窗口）/ 左边（那叠在右边缘时，朝屏幕里面）/ 右边。</summary>
    public enum TabSide
    {
        None,
        Leading,
        Trailing,
    }

    private readonly Host _host;

    public NoteSheetView(Host host)
    {
        _host = host;
        Editor = new NoteEditor();
        Editor.BodyChanged += (id, body) => NoteStore.Instance?.SetBody(id, body);
        Editor.CloseRequested += () => _host.Close(true);
        Editor.Overflowed += () => NoticeHost.Show(NotesWindowRules.OverLimitText, string.Empty, NoticeTone.Warning);
        Editor.UnsavedChanged += ShowFootnote;

        _strip = new Border { Height = 4, CornerRadius = new CornerRadius(8, 8, 0, 0) };
        _dot = HeaderButton(string.Empty, NotesWindowRules.ColorTitle, ShowColors);
        _title = new TextBox
        {
            PlaceholderText = "标题",
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            MinWidth = 40,
            VerticalAlignment = VerticalAlignment.Center,
        };
        SearchLine.MakePlain(_title);
        SearchLine.HideClearButton(_title);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_title, "便签标题");
        _title.TextChanged += (_, _) =>
        {
            if (!_settingTitle && _id is { } id)
            {
                NoteStore.Instance?.SetTitle(id, _title.Text);
            }
        };
        _title.KeyDown += (_, e) =>
        {
            if (e.Key is VirtualKey.Enter or VirtualKey.Tab)
            {
                Editor.Focus();
                e.Handled = true;
            }
        };
        _task = HeaderButton("\uE9D5", NotesWindowRules.TaskHelp, () => Editor.ToggleTask());
        _pin = HeaderButton(Glyphs.Pin, "固定（Ctrl+P）", TogglePin);
        _more = HeaderButton(Glyphs.More, "操作（Ctrl+K）", ShowActions);
        _close = HeaderButton(Glyphs.Close, "关闭（Esc）", () => _host.Close(false));
        _close.Visibility = host.ShowsClose ? Visibility.Visible : Visibility.Collapsed;

        var header = new Grid { Padding = new Thickness(10, 6, 6, 0), ColumnSpacing = 2 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var index = 0; index < 4; index++)
        {
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }

        header.Children.Add(_dot);
        Grid.SetColumn(_title, 1);
        header.Children.Add(_title);
        var column = 2;
        foreach (var button in new[] { _task, _pin, _more, _close })
        {
            Grid.SetColumn(button, column++);
            header.Children.Add(button);
        }

        // 头部空白处当把手（浮动便签挪窗口、那叠里拖出来）
        header.Background = new SolidColorBrush(Colors.Transparent);
        header.PointerPressed += (_, e) =>
        {
            if (ReferenceEquals(e.OriginalSource, header))
            {
                _host.GripPressed?.Invoke(e);
            }
        };

        _footnote = new TextBlock
        {
            FontSize = 11,
            Margin = new Thickness(16, 0, 16, 8),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        _layout = new Grid();
        _layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _layout.Children.Add(_strip);
        Grid.SetRow(header, 1);
        _layout.Children.Add(header);
        Grid.SetRow(Editor.View, 2);
        _layout.Children.Add(Editor.View);
        Grid.SetRow(_footnote, 3);
        _layout.Children.Add(_footnote);
        // 读屏把它当一颗按钮，「调用」= 关掉 / 收回（同 mac 的 .isButton + 关掉的动作；R108 审查）
        _tab = new NoteSheetTab { Visibility = Visibility.Collapsed, Invoked = () => _host.Close(false) };
        _tab.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(_tab).Properties.IsLeftButtonPressed)
            {
                _host.TabPressed?.Invoke(e);
                e.Handled = true;
            }
        };
        _tab.SizeChanged += (_, _) => DrawTab();
        _tabRule = new Border { Width = 1, Visibility = Visibility.Collapsed };
        _frame = new Grid { Children = { _tab, _tabRule, _layout } };
        _paper = new Border { CornerRadius = new CornerRadius(8), Child = _frame };
        _paper.KeyDown += OnKeyDown;
        _paper.Unloaded += (_, _) => Detach();
        _paper.Loaded += (_, _) => Attach();
        Attach();
    }

    public FrameworkElement View => _paper;

    /// <summary>纸里面的那一层（它带着的标签、头部、正文、小字）：那叠里打开的便签出场时动的是它（纸本身不动，见 NoteDeckWindows 文件头）。</summary>
    public FrameworkElement MotionTarget => _frame;

    /// <summary>它带着的那张标签放哪一侧、多宽、字多大（跟那叠的大小档走）。那叠换了边、换了大小档时外面再调一次。</summary>
    public void SetTab(TabSide side, NoteDeckMetrics metrics)
    {
        if (side == _tabSide && metrics == _tabMetrics)
        {
            return;
        }

        _tabSide = side;
        _tabMetrics = metrics;
        _frame.ColumnDefinitions.Clear();
        var shows = side != TabSide.None;
        _tab.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
        _tabRule.Visibility = _tab.Visibility;
        _strip.Visibility = shows ? Visibility.Collapsed : Visibility.Visible;
        if (shows)
        {
            _tab.Width = metrics.TabWidth;
            var leading = side == TabSide.Leading;
            _frame.ColumnDefinitions.Add(new ColumnDefinition { Width = leading ? GridLength.Auto : new GridLength(1, GridUnitType.Star) });
            _frame.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _frame.ColumnDefinitions.Add(new ColumnDefinition { Width = leading ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            Grid.SetColumn(_tab, leading ? 0 : 2);
            Grid.SetColumn(_tabRule, 1);
            Grid.SetColumn(_layout, leading ? 2 : 0);
        }
        else
        {
            Grid.SetColumn(_layout, 0);
        }

        _tabDrawn = null;
        DrawTab();
    }

    /// <summary>那张标签的底、竖线、竖排的标题（标题、高、深浅、大小档没变就不重排）。</summary>
    private void DrawTab()
    {
        if (_tabSide == TabSide.None || Note is not { } note)
        {
            return;
        }

        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var contrast = Theme.IsHighContrast;
        var paper = NotePaper.Of(note);
        var tone = paper.Tone(dark);
        var title = NoteStore.Instance?.Book.SummaryOf(note).Title ?? note.DisplayTitle;
        // 能排多长：上下各让出 14（同 mac 的边距）
        var length = Math.Max(_tab.ActualHeight - 28, 0);
        var key = string.Join('|', title, length, dark, contrast, note.Color, paper.Tone(dark).Ink, _tabMetrics.Scale);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_tab, _host.TabName());
        if (key == _tabDrawn)
        {
            return;
        }

        _tabDrawn = key;
        _tab.Background = new SolidColorBrush(Rgb(paper.TabFill(dark)));
        _tabRule.Background = new SolidColorBrush(Shade(paper.Rule(dark, contrast), tone.Paper));
        if (length <= 0)
        {
            _tab.Children.Clear();
            return;
        }

        var label = NoteDeckUi.Label(title, length, _tabMetrics.FontSize, tone.Ink);
        label.VerticalAlignment = VerticalAlignment.Center;
        _tab.Children.Clear();
        _tab.Children.Add(label);
    }

    public NoteEditor Editor { get; }

    public string? NoteId => _id;

    public Note? Note => _id is { } id ? NoteStore.Instance?.Book.Find(id) : null;

    private bool _attached;

    private void Attach()
    {
        if (_attached)
        {
            return;
        }

        _attached = true;
        if (NoteStore.Instance is { } store)
        {
            store.Changed += Refresh;
            store.SaveProblemChanged += ShowFootnote;
        }

        SettingsService.Changed += Refresh;
    }

    private void Detach()
    {
        if (!_attached)
        {
            return;
        }

        _attached = false;
        if (NoteStore.Instance is { } store)
        {
            store.Changed -= Refresh;
            store.SaveProblemChanged -= ShowFootnote;
        }

        SettingsService.Changed -= Refresh;
    }

    /// <summary>换成这一条（null = 空着）。旧的那条是这次运行里新建、还空白着的：交给仓库删掉（mac NoteStore.left）。</summary>
    public void Show(string? id)
    {
        if (_id == id)
        {
            Refresh();
            return;
        }

        if (_id is { } old)
        {
            NoteStore.Instance?.Flush();
            NoteStore.Instance?.Left(old);
        }

        _id = id;
        if (id is null)
        {
            // 放掉编辑器里的那条（藏着的窗口里的编辑器还算「开着」，空白便签就删不掉了）
            Editor.Release();
        }

        Refresh();
    }

    public void FocusBody() => Editor.Focus();

    /// <summary>仓库变了 / 设置变了：标题、正文（和上次交出去的不一样才换）、纸色、按钮。</summary>
    public void Refresh()
    {
        var note = Note;
        _paper.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
        if (note is null)
        {
            return;
        }

        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var contrast = Theme.IsHighContrast;
        var paper = NotePaper.Of(note);
        var tone = paper.Tone(dark);
        _paper.Background = new SolidColorBrush(Rgb(tone.Paper));
        _strip.Background = new SolidColorBrush(Rgb(tone.Strip));
        DrawTab();
        var ink = new SolidColorBrush(Rgb(tone.Ink));
        _title.Foreground = ink;
        foreach (var key in new[] { "TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused" })
        {
            _title.Resources[key] = ink;
        }

        foreach (var button in new[] { _task, _pin, _more, _close })
        {
            button.Foreground = ink;
        }

        _dot.Content = new Ellipse
        {
            Width = 12,
            Height = 12,
            Fill = new SolidColorBrush(Rgb(tone.Paper)),
            Stroke = new SolidColorBrush(Rgb(tone.Strip)),
            StrokeThickness = 2,
        };
        ((FontIcon)_pin.Content).Glyph = note.IsPinned ? Glyphs.Unpin : Glyphs.Pin;
        ToolTipService.SetToolTip(_pin, NotesWindowRules.PinTitle(note) + "（Ctrl+P）");
        var readOnly = note.DeletedAt is not null;
        _task.IsEnabled = !readOnly;
        _title.IsReadOnly = readOnly;
        Editor.ReadOnly = readOnly;
        if (_title.FocusState == FocusState.Unfocused && _title.Text != note.Title)
        {
            _settingTitle = true;
            _title.Text = note.Title;
            _settingTitle = false;
        }

        _title.PlaceholderText = note.Title.Length == 0 ? note.DisplayTitle : "标题";
        var settings = SettingsService.Current;
        Editor.Images = NoteStore.Instance?.Images;
        Editor.Configure(paper, dark, contrast,
            new[] { 13, 15, 17, 20 }.Contains(settings.NotesFontSize) ? settings.NotesFontSize : 15,
            settings.NotesMarkdown, NoteStyles.SpacingFromName(settings.NotesLineSpacing) ?? NoteSpacing.Standard);
        Editor.Load(note);
        _footnote.Foreground = new SolidColorBrush(Shade(paper.SecondaryInk(dark, contrast), tone.Paper));
        _footnoteText = NotesWindowRules.Footnote(note, NoteStore.Now, TimeZoneInfo.Local);
        ShowFootnote();
    }

    private string _footnoteText = string.Empty;

    /// <summary>底行：改于 · 字数；改动交不出去（R73）、落盘一直失败（R75）时前面先写一句。</summary>
    private void ShowFootnote()
        => _footnote.Text = Editor.Unsaved ? NotesWindowRules.UnsavedText + " · " + _footnoteText
            : NoteStore.Instance?.SaveProblem is not null ? NotesWindowRules.SaveRetryText + " · " + _footnoteText
            : _footnoteText;

    internal static Color Rgb(int rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    private static Color Shade(NoteShade shade, int paper) => Rgb(NotePaper.Mix(shade.Rgb, paper, shade.Opacity));

    private static Button HeaderButton(string glyph, string name, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Width = 30,
            Height = 30,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            IsTabStop = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => action();
        return button;
    }

    // ---- 按键 ----

    private static bool Down(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!Down(VirtualKey.Control) || _id is not { } id)
        {
            if (e.Key == VirtualKey.Escape && !Editor.IsFinding)
            {
                _host.Close(true);
                e.Handled = true;
            }

            return;
        }

        var shift = Down(VirtualKey.Shift);
        e.Handled = (e.Key, shift) switch
        {
            (VirtualKey.K, false) => Run(ShowActions),
            (VirtualKey.P, false) => Run(TogglePin),
            (VirtualKey.A, true) => Run(ToggleArchive),
            (VirtualKey.Delete, true) => Run(Delete),
            ((VirtualKey)190, false) => Run(() => NoteStore.Instance?.SetColor(id, Core.Notes.Note.NextPreset(Note?.Color ?? 0))),
            ((VirtualKey)188, false) => Run(() => ShellRuntime.Instance?.ShowSettings(false, "notes")),
            (VirtualKey.W, false) => Run(() => _host.Close(true)),
            _ => false,
        };
    }

    private static bool Run(Action action)
    {
        action();
        return true;
    }

    // ---- 操作 ----

    private void TogglePin()
    {
        if (Note is { } note)
        {
            NoteStore.Instance?.SetPinned(note.Id, !note.IsPinned);
        }
    }

    private void ToggleArchive()
    {
        if (Note is not { } note)
        {
            return;
        }

        var archiving = !note.IsArchived;
        NoteStore.Instance?.SetArchived(note.Id, archiving);
        if (archiving)
        {
            _host.Close(false);
            NoticeHost.Show(NotesWindowRules.ArchivedTitle(1), note.DisplayTitle, NoticeTone.Normal,
                new NoticeAction("取消归档", () => NoteStore.Instance?.SetArchived(note.Id, false, toFront: false)));
        }
    }

    private void Delete()
    {
        if (Note is not { } note)
        {
            return;
        }

        NoteStore.Instance?.Delete(note.Id);
        _host.Close(false);
        NoteNotices.ShowDeleted(note.Id, undoKey: false);
    }

    /// <summary>操作菜单（mac NoteSheetModel.actionItems）：固定 / 颜色 ›/ 任务｜归档 / 删除｜浮在屏幕上 / 在全部便签里打开 / 导出｜便签设置。</summary>
    private void ShowActions()
    {
        if (Note is not { } note)
        {
            return;
        }

        var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
        Item(menu.Items, NotesWindowRules.PinTitle(note), note.IsPinned ? Glyphs.Unpin : Glyphs.Pin, "Ctrl+P", TogglePin);
        var colors = new MenuFlyoutSubItem { Text = NotesWindowRules.ColorTitle, Icon = new FontIcon { Glyph = "\uE790" } };
        FillColors(colors.Items, note, _dot);
        menu.Items.Add(colors);
        Item(menu.Items, NotesWindowRules.TaskTitle, "\uE9D5", "Ctrl+T", () => Editor.ToggleTask(), note.DeletedAt is null);
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(menu.Items, NotesWindowRules.ArchiveTitle(note), "\uE7B8", "Ctrl+Shift+A", ToggleArchive);
        var delete = Item(menu.Items, NotesWindowRules.DeleteTitle, Glyphs.Delete, "Ctrl+Shift+Delete", Delete);
        delete.Foreground = Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (_host.ToggleFloating is { } toggle)
        {
            Item(menu.Items, NotesWindowRules.FloatTitle(_host.IsFloating(), SettingsService.Current.NotesDeckEnabled), "\uE8A7", null, toggle);
        }

        Item(menu.Items, NotesWindowRules.OpenInWindowTitle, "\uE8A5", null, () => NotesWindow.ShowNote(note.Id));
        Item(menu.Items, NotesWindowRules.SingleExportTitle, Glyphs.Save, null, () => _ = NotesTransfer.ExportOneAsync(note.Id, _more.XamlRoot));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(menu.Items, NotesWindowRules.SettingsTitle + "…", Glyphs.Settings, "Ctrl+,",
            () => ShellRuntime.Instance?.ShowSettings(false, "notes"));
        menu.Closed += (_, _) => Editor.Focus();
        menu.ShowAt(_more);
    }

    private static MenuFlyoutItem Item(IList<MenuFlyoutItemBase> items, string text, string glyph, string? key, Action action, bool enabled = true)
    {
        var item = new MenuFlyoutItem
        {
            Text = text,
            Icon = new FontIcon { Glyph = glyph },
            KeyboardAcceleratorTextOverride = key ?? string.Empty,
            IsEnabled = enabled,
        };
        item.Click += (_, _) => action();
        items.Add(item);
        return item;
    }

    private void ShowColors()
    {
        if (Note is not { } note)
        {
            return;
        }

        var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
        FillColors(menu.Items, note, _dot);
        menu.ShowAt(_dot);
    }

    /// <summary>颜色那份表（全 App 选颜色的地方共用，mac NotePaper.colorItems）：8 种｜自定义的｜其他颜色…</summary>
    public static void FillColors(IList<MenuFlyoutItemBase> items, Note note, FrameworkElement? anchor = null)
    {
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var recent = NotePaper.RecentColors(SettingsService.Current.NotesRecentColors);
        var section = 0;
        foreach (var choice in NotePaper.ColorChoices(note.Color, recent, other: true))
        {
            if (choice.Section != section)
            {
                items.Add(new MenuFlyoutSeparator());
                section = choice.Section;
            }

            var item = new ToggleMenuFlyoutItem { Text = choice.Title, IsChecked = choice.IsChecked };
            if (choice.Color is { } color)
            {
                var tone = NotePaper.Of(color).Tone(dark);
                item.Icon = new PathIcon
                {
                    Data = new EllipseGeometry { Center = new Windows.Foundation.Point(8, 8), RadiusX = 6, RadiusY = 6 },
                    Foreground = new SolidColorBrush(Rgb(tone.Paper)),
                };
                item.Click += (_, _) => NoteStore.Instance?.SetColor(note.Id, color);
            }
            else
            {
                item.Icon = new FontIcon { Glyph = "\uEF3C" };
                item.Click += (_, _) => NoteColorFlyout.Show(note.Id, anchor);
            }

            items.Add(item);
        }
    }
}

/// <summary>
/// 打开的便签带着的那张标签（R108 审查，mac NoteSheet.tab 是 .isButton、带关掉的动作）：读屏把它当一颗按钮，「调用」（Invoke）= Invoked（关掉 / 收回）。
/// 不进 Tab 键的顺序（同 mac 不当焦点）：键盘照旧用头部的关闭钮、Esc。点、拖还是 NoteSheetView 挂的指针事件。
/// </summary>
internal sealed partial class NoteSheetTab : Grid
{
    public Action? Invoked { get; set; }

    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => new NoteSheetTabPeer(this);
}

/// <summary>NoteSheetTab 的读屏对象：按钮，能调用。</summary>
internal sealed partial class NoteSheetTabPeer(NoteSheetTab owner)
    : Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(owner), Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider
{
    public void Invoke() => owner.Invoked?.Invoke();

    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationControlType GetAutomationControlTypeCore()
        => Microsoft.UI.Xaml.Automation.Peers.AutomationControlType.Button;

    protected override object GetPatternCore(Microsoft.UI.Xaml.Automation.Peers.PatternInterface patternInterface)
        => patternInterface == Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke ? this : base.GetPatternCore(patternInterface)!;
}
