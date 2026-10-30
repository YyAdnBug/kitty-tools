// 截图历史窗口（PLAN-v8 第 2 批 H5，照 mac 的 ShotHistoryWindow / ShotHistoryView）：普通的 WinUI 窗口（外壳跟 Windows），
// 左边按天分组的缩略图网格，右边 280 宽的预览、两行信息和一列操作；顶上「全部 / 截图 / 长截图 / 录制」+ 搜索框。
// 只建一扇；关掉就整扇放掉，缩略图跟着放。入口：快捷动作「截图历史」（托盘、启动器、快捷键页）、设置 › 截图。
// 多选（照 mac 1ec2ca9a）：Ctrl 点加选或去掉、Shift 点从锚点连过去（Ctrl 点出来的零散的不丢）、Ctrl+A 全选列出来的、Shift + 方向键连着选；
// 选着两张以上时右边换成「已选 N 项」+ 各几个一共多大 + 能一起做的四件（拷贝 / 存储 / 在资源管理器中显示 / 删除），右键点选中的那几张里的
// 一张是整批的菜单，点选中外面那张还是单条那套、选中不变。分组是好几个 GridView，系统的多选跨不了组，选中自己管（GridView 不选，卡上自己画描边）。
// 快捷键（照 mac 933c1dd9）：Ctrl+C 拷贝、Ctrl+S 存储、Ctrl+Shift+S 另存为、Ctrl+P 钉图、Ctrl+O 识字并拷贝、Ctrl+Shift+R 在资源管理器中显示、
// Enter 改标注、Delete 删除、Ctrl+F 搜索、Ctrl+1–4 换筛选、方向键挑图（↑↓ 跳一行，一行几张按网格宽度量）；在搜索框里打字时方向键、Ctrl+C / A、
// Enter、Delete 让给输入框。右边每一行操作后面写着它的键。
// 拖出去（照 mac 0de6c18b / 605f41c8）：卡和右边的大预览都能拖到别的程序；按住的是选中的之一就拖全部选中的，不然只拖它（不改选中）。
// 录制的、存过盘的拖那个文件本身，别的拖一份成品 PNG（原图 + 标注，临时文件夹 kitty-shots\history 里，启动时清空）。
using System.Globalization;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.UI;
using Windows.UI.Core;
using Windows.Win32;

namespace KittyTools;

internal sealed partial class ShotHistoryWindow : Window
{
    /// <summary>
    /// ponytail: 一次只排最近的这么多张，底下「再显示」往后加（30 天 / 2 GB 的历史通常几百张）；
    /// 真到上万张再换 ItemsRepeater + 自己的虚拟化布局。
    /// </summary>
    private const int PageSize = 120;

    private const double CardWidth = 168;

    private const double CardHeight = 112;

    private static ShotHistoryWindow? _current;

    private readonly ShotHistory _history;
    private readonly Grid _root;
    private readonly SelectorBar _filter;
    private readonly TextBox _search;
    private readonly StackPanel _groups;
    private readonly Image _preview;
    private readonly TextBlock _infoTime;
    private readonly TextBlock _infoState;
    private readonly StackPanel _actions;
    private readonly List<GridView> _grids = new();

    /// <summary>现在列出来的（按顺序；方向键、Shift 点、全选都按它）和每一天各几张。</summary>
    private readonly List<ShotItem> _listed = new();
    private readonly List<int> _groupSizes = new();

    /// <summary>选中的几张（照 mac：picked + 锚点；正好一张时右边是它的详情）。</summary>
    private readonly HashSet<string> _picked = new();

    /// <summary>每张卡的选中描边，和卡在哪个 GridView 里（换选中时不用整个重排）。</summary>
    private readonly Dictionary<string, Border> _marks = new();
    private readonly Dictionary<string, (GridView Grid, FrameworkElement Card)> _cards = new();
    private int _shown = PageSize;
    private string? _anchor;

    /// <summary>方向键从哪张出发（最后点的、挪到的那张）。</summary>
    private string? _cursor;

    private ShotHistoryWindow(ShotHistory history)
    {
        _history = history;
        Title = "截图历史";
        // 设置窗的 Mica 在 Release AOT 下会抛（R31），这里同样不用系统背景材质，铺不透明的底。
        SystemBackdrop = null;

        _filter = new SelectorBar();
        foreach (var title in new[] { "全部", "截图", "长截图", "录制" })
        {
            _filter.Items.Add(new SelectorBarItem { Text = title });
        }

        _filter.SelectedItem = _filter.Items[0];
        _filter.SelectionChanged += (_, _) => Rebuild(resetPaging: true);
        _search = new TextBox
        {
            PlaceholderText = "搜索",
            Width = 240,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(_search, "搜索截图历史");
        _search.TextChanged += (_, _) => Rebuild(resetPaging: true);
        var top = new Grid { Padding = new Thickness(16, 8, 16, 8), ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(_filter);
        Grid.SetColumn(_search, 1);
        top.Children.Add(_search);

        _groups = new StackPanel { Spacing = 4, Padding = new Thickness(16, 4, 16, 24) };
        var scroll = new ScrollViewer
        {
            Content = _groups,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        _preview = new Image { Stretch = Stretch.Uniform, CanDrag = true };
        _preview.DragStarting += (_, args) =>
        {
            if (OnlyPicked() is { } item)
            {
                OnDragStarting(item, args);
            }
            else
            {
                args.Cancel = true;
            }
        };
        var previewBox = new Border
        {
            Height = 180,
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Background = Theme.Brush("Kitty.Fill.Control", Color.FromArgb(15, 0, 0, 0)),
            Child = _preview,
        };
        _infoTime = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            TextWrapping = TextWrapping.Wrap,
        };
        _infoState = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.SecondaryText(),
            TextWrapping = TextWrapping.Wrap,
        };
        _actions = new StackPanel { Spacing = 2 };
        var detail = new StackPanel { Spacing = 10, Padding = new Thickness(16) };
        detail.Children.Add(previewBox);
        detail.Children.Add(_infoTime);
        detail.Children.Add(_infoState);
        detail.Children.Add(_actions);
        var detailPane = new Border
        {
            Width = 280,
            BorderThickness = new Thickness(1, 0, 0, 0),
            BorderBrush = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            Child = new ScrollViewer { Content = detail, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.Children.Add(scroll);
        Grid.SetColumn(detailPane, 1);
        body.Children.Add(detailPane);

        _root = new Grid
        {
            RequestedTheme = Theme.ElementTheme,
            // ApplicationPageBackgroundThemeBrush 不在我们的主题字典里，取到的是跟系统走的那一套。
            Background = Theme.Brush("Kitty.PageBackground", Color.FromArgb(255, 243, 243, 243)),
        };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(top);
        Grid.SetRow(body, 1);
        _root.Children.Add(body);
        Content = _root;

        var hwnd = (Windows.Win32.Foundation.HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = PInvoke.GetDpiForWindow(hwnd) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)Math.Round(960 * scale), (int)Math.Round(620 * scale)));
        // 标题栏左上角的图标（2026-10-29 用户反馈：以前传 exe 路径，SetIcon 不认，显示的是系统默认图标）。
        AppWindow.SetIcon(Paths.AppIconFile);
        Theme.ApplyTitleBar(AppWindow);

        // 先于网格看到按键（不然方向键被 GridView 拿去挪焦点）。
        _root.PreviewKeyDown += OnPreviewKeyDown;
        _history.Changed += OnHistoryChanged;
        _history.ThumbnailChanged += OnThumbnailChanged;
        Closed += (_, _) =>
        {
            _history.Changed -= OnHistoryChanged;
            _history.ThumbnailChanged -= OnThumbnailChanged;
            _groups.Children.Clear();
            _grids.Clear();
            _cards.Clear();
            _marks.Clear();
            _preview.Source = null;
            _current = null;
            IdleReclaimer.Schedule();
        };
        Rebuild(resetPaging: true);
    }

    /// <summary>打开（已经开着就拿到前面来）。</summary>
    public static void ShowWindow()
    {
        if (ShotHistory.Instance is not { } history)
        {
            NoticeHost.Show("截图历史用不了", "数据库没打开", NoticeTone.Warning);
            return;
        }

        _current ??= new ShotHistoryWindow(history);
        _current.Activate();
    }

    /// <summary>--ui-snapshots：开一扇不激活的（左上角，按当前外观新建；出完图由自检关掉）。</summary>
    internal static Window? OpenForProbe()
    {
        if (ShotHistory.Instance is not { } history)
        {
            return null;
        }

        _current?.Close();
        _current = new ShotHistoryWindow(history);
        _current.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(8, 8, 1000, 640));
        _current.AppWindow.Show(activateWindow: false);
        return _current;
    }

    private void OnHistoryChanged() => Rebuild(resetPaging: false);

    private void OnThumbnailChanged(string id)
    {
        Rebuild(resetPaging: false);
    }

    private IEnumerable<ShotItem> Filtered()
    {
        var filter = _filter.Items.IndexOf(_filter.SelectedItem);
        var query = _search.Text.Trim();
        var today = DateTime.Now;
        foreach (var item in _history.Items)
        {
            var kindMatches = filter switch
            {
                1 => item.Kind == ShotKind.Shot,
                2 => item.Kind == ShotKind.Scroll,
                3 => ShotHistoryRules.IsRecording(item.Kind),
                _ => true,
            };
            if (!kindMatches)
            {
                continue;
            }

            if (query.Length > 0)
            {
                var created = LocalTime(item.CreatedAt);
                var haystack = string.Join(
                    ' ',
                    ShotHistoryRules.Title(item.Kind),
                    ShotHistoryRules.DayTitle(created, today),
                    created.ToString("yyyy-MM-dd HH:mm"),
                    item.Source,
                    Path.GetFileName(item.SavedPath ?? item.FilePath ?? string.Empty));
                if (!haystack.Contains(query, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
            }

            yield return item;
        }
    }

    private void Rebuild(bool resetPaging)
    {
        if (resetPaging)
        {
            _shown = PageSize;
        }

        _groups.Children.Clear();
        _grids.Clear();
        _cards.Clear();
        _marks.Clear();
        _listed.Clear();
        _groupSizes.Clear();
        var items = Filtered().ToList();
        if (items.Count == 0)
        {
            _groups.Children.Add(_history.Items.Count == 0
                ? EmptyState.Create(Glyphs.History, "还没有截图", "截图、长截图、钉过的图和录制都会记在这里，留 30 天")
                : EmptyState.Create(Glyphs.Search, "没有符合的", "换个关键词，或者切回「全部」"));
            Apply(Array.Empty<string>(), null, null);
            return;
        }

        var today = DateTime.Now;
        foreach (var group in items.Take(_shown).GroupBy(item => LocalTime(item.CreatedAt).Date))
        {
            _groups.Children.Add(new TextBlock
            {
                Text = ShotHistoryRules.DayTitle(group.Key, today),
                FontSize = Theme.FontSize("Kitty.FontSize.GroupHeader"),
                FontWeight = FontWeights.SemiBold,
                Foreground = Theme.TertiaryText(),
                Margin = new Thickness(0, 12, 0, 4),
            });
            // 系统的选中关掉（跨不了组），点卡走 ItemClick，选中自己画。
            var grid = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true };
            var count = 0;
            foreach (var item in group)
            {
                var card = Card(item);
                grid.Items.Add(card);
                _cards[item.Id] = (grid, card);
                _listed.Add(item);
                count++;
            }

            _groupSizes.Add(count);
            grid.ItemClick += OnCardClick;
            _grids.Add(grid);
            _groups.Children.Add(grid);
        }

        if (items.Count > _shown)
        {
            var more = new Button
            {
                Content = $"再显示 {Math.Min(PageSize, items.Count - _shown)} 张",
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 12, 0, 0),
            };
            more.Click += (_, _) =>
            {
                _shown += PageSize;
                Rebuild(resetPaging: false);
            };
            _groups.Children.Add(more);
        }

        // 删掉的、筛掉的不留在选中里；一张都不剩就选第一张。
        var listed = _listed.Select(item => item.Id).ToHashSet();
        var kept = _picked.Where(listed.Contains).ToList();
        if (kept.Count == 0)
        {
            Apply(new[] { _listed[0].Id }, _listed[0].Id, _listed[0].Id);
        }
        else
        {
            Apply(kept, _anchor is { } anchor && listed.Contains(anchor) ? anchor : kept[0],
                _cursor is { } cursor && listed.Contains(cursor) ? cursor : kept[0]);
        }
    }

    private FrameworkElement Card(ShotItem item)
    {
        var card = new Grid
        {
            Width = CardWidth,
            Height = CardHeight,
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Background = Theme.Brush("Kitty.Fill.Control", Color.FromArgb(15, 0, 0, 0)),
            Tag = item,
        };
        if (File.Exists(ShotHistory.ThumbnailPath(item.Id)))
        {
            card.Children.Add(new Image
            {
                Stretch = Stretch.UniformToFill,
                Source = new BitmapImage
                {
                    DecodePixelType = DecodePixelType.Logical,
                    DecodePixelWidth = (int)CardWidth,
                    CreateOptions = BitmapCreateOptions.IgnoreImageCache,
                    UriSource = new Uri(ShotHistory.ThumbnailPath(item.Id)),
                },
            });
        }
        else
        {
            card.Children.Add(new FontIcon
            {
                Glyph = KindGlyph(item.Kind),
                FontSize = 28,
                Foreground = Theme.TertiaryText(),
            });
        }

        if (item.Kind != ShotKind.Shot)
        {
            // 不是截图的左下角一枚黑底白字的小角标（长截图 / 录屏 / 录音 / GIF）。
            card.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(166, 0, 0, 0)),
                CornerRadius = Theme.Corner("Kitty.Corner.Control"),
                Padding = new Thickness(6, 1, 6, 2),
                Margin = new Thickness(6),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Bottom,
                Child = new TextBlock
                {
                    Text = ShotHistoryRules.Title(item.Kind),
                    FontSize = 11,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                },
            });
        }

        // 选中：强调色描边 + 一层选中底（画在最上面，不挡点击）。
        var mark = new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            BorderThickness = new Thickness(2),
            BorderBrush = new SolidColorBrush(Theme.AccentColor),
            Background = Theme.Brush("Kitty.Fill.Selected", Color.FromArgb(18, 0, 0, 0)),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        card.Children.Add(mark);
        _marks[item.Id] = mark;

        AutomationProperties.SetName(
            card, $"{ShotHistoryRules.Title(item.Kind)}，{LocalTime(item.CreatedAt):M 月 d 日 HH:mm}");
        card.DoubleTapped += (_, _) => Open(item);
        card.ContextFlyout = Menu(item);
        card.CanDrag = true;
        card.DragStarting += (_, args) => OnDragStarting(item, args);
        return card;
    }

    private static bool IsDown(Windows.System.VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>点一张：单点只选它、Ctrl 点加选或去掉、Shift 点从锚点连过去（ShotHistoryRules.Click）。</summary>
    private void OnCardClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not FrameworkElement { Tag: ShotItem item })
        {
            return;
        }

        var (picked, anchor) = ShotHistoryRules.Click(
            Ids(), _picked, _anchor, item.Id, IsDown(Windows.System.VirtualKey.Control), IsDown(Windows.System.VirtualKey.Shift));
        Apply(picked, anchor, item.Id);
    }

    private List<string> Ids() => _listed.Select(item => item.Id).ToList();

    /// <summary>换选中：描边跟着换，右边换成单条的详情或「已选 N 项」。</summary>
    private void Apply(IEnumerable<string> picked, string? anchor, string? cursor)
    {
        var next = picked.ToList();
        _picked.Clear();
        _picked.UnionWith(next);
        _anchor = anchor;
        _cursor = cursor;
        foreach (var (id, mark) in _marks)
        {
            mark.Visibility = _picked.Contains(id) ? Visibility.Visible : Visibility.Collapsed;
        }

        var items = PickedItems();
        if (items.Count > 1)
        {
            SelectMany(items);
        }
        else
        {
            Select(items.FirstOrDefault());
        }
    }

    /// <summary>选中的几张，按列出来的顺序。</summary>
    private List<ShotItem> PickedItems() => _listed.Where(item => _picked.Contains(item.Id)).ToList();

    /// <summary>正好选着一张时是它。</summary>
    private ShotItem? OnlyPicked() => _picked.Count == 1 ? _listed.FirstOrDefault(item => _picked.Contains(item.Id)) : null;

    /// <summary>右边：大预览、两行信息、这一条能做的操作。</summary>
    private void Select(ShotItem? item)
    {
        _actions.Children.Clear();
        if (item is null)
        {
            _preview.Source = null;
            _infoTime.Text = string.Empty;
            _infoState.Text = string.Empty;
            return;
        }

        var previewPath = File.Exists(ShotHistory.ComposedPath(item.Id)) ? ShotHistory.ComposedPath(item.Id)
            : File.Exists(ShotHistory.ImagePath(item.Id)) ? ShotHistory.ImagePath(item.Id)
            : File.Exists(ShotHistory.ThumbnailPath(item.Id)) ? ShotHistory.ThumbnailPath(item.Id)
            : null;
        _preview.Source = previewPath is null
            ? null
            : new BitmapImage
            {
                DecodePixelType = DecodePixelType.Logical,
                DecodePixelWidth = 248,
                CreateOptions = BitmapCreateOptions.IgnoreImageCache,
                UriSource = new Uri(previewPath),
            };

        var created = LocalTime(item.CreatedAt);
        var parts = new List<string> { created.ToString("yyyy-MM-dd HH:mm") };
        if (item.PixelWidth > 0)
        {
            parts.Add($"{item.PixelWidth} × {item.PixelHeight}");
        }

        if (!string.IsNullOrEmpty(item.Source))
        {
            parts.Add(item.Source);
        }

        _infoTime.Text = string.Join(" · ", parts);
        var state = new List<string>
        {
            item.SavedPath is { Length: > 0 } saved
                ? (ShotHistory.FileExists(item) ? "已存到 " : "存过（文件已经不在了）") +
                  (ShotHistory.FileExists(item) ? Path.GetFileName(Path.GetDirectoryName(saved)) ?? saved : string.Empty)
                : "没存成文件",
        };
        if (item.Annotations.Count > 0)
        {
            state.Add($"{item.Annotations.Count} 条标注");
        }

        if (item.PinnedAt is not null)
        {
            state.Add("钉过");
        }

        _infoState.Text = string.Join(" · ", state);

        foreach (var action in Actions(item))
        {
            _actions.Children.Add(ActionButton(action));
        }
    }

    /// <summary>选着两张以上：「已选 N 项」、各几个一共多大，底下是能一起做的四件（同 mac many）。</summary>
    private void SelectMany(List<ShotItem> items)
    {
        _actions.Children.Clear();
        _preview.Source = null;
        _infoTime.Text = $"已选 {items.Count} 项";
        _infoState.Text = ShotHistoryRules.Summary(items.Select(item => (item.Kind, SizeOf(item))).ToList());
        foreach (var action in ManyActions(items))
        {
            _actions.Children.Add(ActionButton(action));
        }
    }

    /// <summary>占多大：录制的看文件本身，截图看原图 + 缩略图。</summary>
    private static long SizeOf(ShotItem item)
    {
        if (!ShotHistoryRules.IsRecording(item.Kind))
        {
            return item.Bytes;
        }

        try
        {
            return item.FilePath is { } path && File.Exists(path) ? new FileInfo(path).Length : 0;
        }
        catch
        {
            return 0;
        }
    }

    private static Button ActionButton((string Glyph, string Title, string? Key, Action Run, bool Enabled, bool Danger) action)
    {
        var button = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            IsEnabled = action.Enabled,
            Content = ActionContent(action.Glyph, action.Title, action.Key, action.Enabled, action.Danger),
        };
        AutomationProperties.SetName(button, action.Title);
        if (action.Key is { } key)
        {
            AutomationProperties.SetAcceleratorKey(button, key);
        }

        button.Click += (_, _) => action.Run();
        return button;
    }

    /// <summary>
    /// 右键菜单：每次打开现排——右键点的是多选里的一张就是整批的那四件，点在选中外面的那张只管它自己、不动选中（同 mac）。
    /// 先放一份单条的（空菜单不弹）。
    /// </summary>
    private MenuFlyout Menu(ShotItem item)
    {
        var menu = new MenuFlyout();
        Fill(menu, Actions(item));
        menu.Opening += (_, _) =>
            Fill(menu, _picked.Count > 1 && _picked.Contains(item.Id) ? ManyActions(PickedItems()) : Actions(item));
        return menu;
    }

    private static void Fill(MenuFlyout menu, List<(string Glyph, string Title, string? Key, Action Run, bool Enabled, bool Danger)> actions)
    {
        menu.Items.Clear();
        foreach (var (glyph, title, key, action, enabled, danger) in actions)
        {
            var entry = new MenuFlyoutItem
            {
                Text = title,
                Icon = new FontIcon { Glyph = glyph },
                IsEnabled = enabled,
            };
            if (key is not null)
            {
                entry.KeyboardAcceleratorTextOverride = key;
            }

            if (danger)
            {
                entry.Foreground = Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28));
            }

            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }
    }

    /// <summary>一条能做的操作（右边那一列和右键菜单是同一份），后面写着它的键。</summary>
    private List<(string Glyph, string Title, string? Key, Action Run, bool Enabled, bool Danger)> Actions(ShotItem item)
    {
        if (ShotHistoryRules.IsRecording(item.Kind))
        {
            return new()
            {
                (Glyphs.OpenInNewWindow, "打开", "Enter", () => Open(item), true, false),
                (Glyphs.Copy, "拷贝", "Ctrl+C", () => CopyFile(item), true, false),
                (Glyphs.Folder, "在资源管理器中显示", "Ctrl+Shift+R", () => Reveal(item), true, false),
                (Glyphs.Delete, "从历史里删掉…", "Delete", () => _ = ForgetAsync(item), true, true),
            };
        }

        return new()
        {
            (Glyphs.Edit, "改标注", "Enter", () => Open(item), true, false),
            (Glyphs.Copy, "拷贝", "Ctrl+C", () => _ = CopyAsync(item), true, false),
            (Glyphs.Save, "存储", "Ctrl+S", () => _ = SaveAsync(item, saveAs: false), true, false),
            (Glyphs.SaveAs, "另存为…", "Ctrl+Shift+S", () => _ = SaveAsync(item, saveAs: true), true, false),
            (Glyphs.Pin, "钉到屏幕", "Ctrl+P", () => Pin(item), true, false),
            (Glyphs.Ocr, "识字并拷贝", "Ctrl+O", () => _ = RecognizeAsync(item), true, false),
            (Glyphs.Folder, "在资源管理器中显示", "Ctrl+Shift+R", () => Reveal(item), true, false),
            (Glyphs.Delete, "删除…", "Delete", () => _ = ForgetAsync(item), true, true),
        };
    }

    /// <summary>选着好几张时能一起做的（同 mac）：拷贝成几个文件、一条条存到截图文件夹、在资源管理器里选中、删除。</summary>
    private List<(string Glyph, string Title, string? Key, Action Run, bool Enabled, bool Danger)> ManyActions(List<ShotItem> items)
    {
        var count = items.Count;
        return new()
        {
            (Glyphs.Copy, $"拷贝 {count} 项", "Ctrl+C", () => _ = CopyManyAsync(items), true, false),
            (Glyphs.Save, $"存储 {count} 项", "Ctrl+S", () => _ = SaveManyAsync(items),
                items.Any(item => !ShotHistoryRules.IsRecording(item.Kind)), false),
            (Glyphs.Folder, "在资源管理器中显示", "Ctrl+Shift+R", () => RevealMany(items), true, false),
            (Glyphs.Delete, $"删除 {count} 项…", "Delete", () => _ = ForgetManyAsync(items), true, true),
        };
    }

    /// <summary>一行操作：图标 + 名字，右边是它的键（置灰的那行键也跟着灰）。</summary>
    private static Grid ActionContent(string glyph, string title, string? key, bool enabled, bool danger)
    {
        var foreground = danger ? Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28)) : null;
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon { Glyph = glyph, FontSize = 14 };
        var text = new TextBlock { Text = title, FontSize = Theme.FontSize("Kitty.FontSize.Body") };
        if (foreground is not null)
        {
            icon.Foreground = foreground;
            text.Foreground = foreground;
        }

        Grid.SetColumn(text, 1);
        row.Children.Add(icon);
        row.Children.Add(text);
        if (key is not null)
        {
            var cap = new TextBlock
            {
                Text = key,
                FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                Foreground = enabled ? Theme.SecondaryText() : Theme.TertiaryText(),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(cap, 2);
            row.Children.Add(cap);
        }

        return row;
    }

    /// <summary>双击：截图的改标注（截图遮罩里接着改，改完回写这一条）；录制的用默认程序打开。</summary>
    private void Open(ShotItem item)
    {
        if (!ShotHistoryRules.IsRecording(item.Kind))
        {
            ScreenshotSession.StartEditing(item);
            return;
        }

        if (!ShotHistory.FileExists(item))
        {
            NoticeHost.Show("文件已经不在了", Path.GetFileName(item.FilePath ?? string.Empty), NoticeTone.Warning);
            return;
        }

        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(item.FilePath!)
            {
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"shots.open-failed {ex.GetType().Name}");
            NoticeHost.Show("打不开这个文件", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static byte[]? Output(ShotItem item)
    {
        var png = ShotHistory.ReadOutput(item.Id);
        if (png is null)
        {
            NoticeHost.Show("原图不在了", "历史里的图被删掉了，这一条只剩记录", NoticeTone.Warning);
        }

        return png;
    }

    private static async Task CopyAsync(ShotItem item)
    {
        if (Output(item) is not { } png)
        {
            return;
        }

        var prepared = await ClipboardWriter.PrepareImageAsync(png);
        if (!ClipboardWriter.WriteImagePng(prepared.Png, prepared.Dib))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
            return;
        }

        var service = ClipboardService.Instance;
        service?.MarkOwnWrite();
        service?.Store.RecordImage(png, item.PixelWidth, item.PixelHeight, null, "截图历史");
        NoticeHost.Show("已复制截图", $"{item.PixelWidth} × {item.PixelHeight}", NoticeTone.Normal);
    }

    private static void CopyFile(ShotItem item)
    {
        if (!ShotHistory.FileExists(item) || item.FilePath is not { } path)
        {
            NoticeHost.Show("文件已经不在了", string.Empty, NoticeTone.Warning);
            return;
        }

        if (ClipboardWriter.WriteFiles(new[] { path }))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            NoticeHost.Show("已复制" + ShotHistoryRules.Title(item.Kind), Path.GetFileName(path), NoticeTone.Normal);
        }
        else
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
        }
    }

    private async Task SaveAsync(ShotItem item, bool saveAs)
    {
        if (Output(item) is not { } png)
        {
            return;
        }

        var path = saveAs
            ? await ScreenshotOutput.SavePngAsAsync(AppWindow, png)
            : await ScreenshotOutput.QuickSavePngAsync(png);
        if (path is not null)
        {
            _history.MarkSaved(item.Id, path);
        }
    }

    /// <summary>钉回当初框的那一块；没有位置的（长截图）钉在鼠标所在屏中间，超过八成等比缩小。</summary>
    private void Pin(ShotItem item)
    {
        if (Output(item) is not { } png)
        {
            return;
        }

        var bounds = item.Frame ?? Centered(item.PixelWidth, item.PixelHeight);
        PinHost.Show(png, bounds);
        _history.MarkPinned(item.Id);
    }

    private static PixelBounds Centered(int width, int height)
    {
        var work = Displays.AtCursor().Work;
        var ratio = Math.Min(1, Math.Min(work.Width * 0.8 / Math.Max(1, width), work.Height * 0.8 / Math.Max(1, height)));
        var w = Math.Max(1, (int)(width * ratio));
        var h = Math.Max(1, (int)(height * ratio));
        var left = work.Left + (work.Width - w) / 2;
        var top = work.Top + (work.Height - h) / 2;
        return new PixelBounds(left, top, left + w, top + h);
    }

    private static async Task RecognizeAsync(ShotItem item)
    {
        if (!OcrService.HasEngine)
        {
            NoticeHost.Show("没装中文识字组件", string.Empty, NoticeTone.Warning,
                NoticeActions.SystemSettings("ms-settings:regionlanguage"));
            return;
        }

        if (ShotHistory.ReadImage(item.Id) is not { } png || await ImageCodec.PngToBgraAsync(png) is not { } image)
        {
            NoticeHost.Show("原图不在了", string.Empty, NoticeTone.Warning);
            return;
        }

        try
        {
            var (text, _) = await OcrService.RecognizeAsync(
                image.Bgra, image.Width, image.Height, joined: SettingsService.Current.OcrJoinLines);
            if (string.IsNullOrWhiteSpace(text))
            {
                NoticeHost.Show("没有识别到文字", string.Empty, NoticeTone.Warning);
                return;
            }

            if (ClipboardWriter.WriteText(text))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(text);
            }

            var preview = text.Replace('\n', ' ').Trim();
            NoticeHost.Show("已复制识别的文字", preview.Length > 30 ? preview[..30] + "…" : preview, NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("shots.ocr-failed", ex);
            NoticeHost.Show("识字失败", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static void Reveal(ShotItem item)
    {
        if ((item.FilePath ?? item.SavedPath) is not { Length: > 0 } path)
        {
            NoticeHost.Show("这张还没存成文件", "先点「存储」", NoticeTone.Normal);
            return;
        }

        if (!File.Exists(path))
        {
            NoticeHost.Show("文件已经不在了", Path.GetFileName(path), NoticeTone.Warning);
            return;
        }

        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "/select,\"" + path + "\"",
                UseShellExecute = true,
            });
        }
        catch
        {
            // 打不开资源管理器就算了。
        }
    }

    /// <summary>删前问一次。截图的记录和图都删；录制的只是不在历史里了，文件不动。</summary>
    private async Task ForgetAsync(ShotItem item)
    {
        var recording = ShotHistoryRules.IsRecording(item.Kind);
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = recording ? "从历史里删掉这一条？" : "删除这张截图？",
            Content = recording
                ? "录制的文件不动，只是不在历史里了。"
                : "原图和标注都会删掉，已经存成文件的不动。",
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = _root.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            _history.Remove(new[] { item.Id });
        }
    }

    // ---- 按键（照 mac 933c1dd9；先于网格看到，方向键不让 GridView 拿去挪焦点）

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(Windows.System.VirtualKey.Control);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        // 在搜索框里打字、焦点在按钮 / 筛选上时，方向键、Enter、Delete、Ctrl+C / A 让给它们。
        var busy = e.OriginalSource is TextBox or ButtonBase or SelectorBarItem;
        var key = e.Key;
        if (control && key is >= Windows.System.VirtualKey.Number1 and <= Windows.System.VirtualKey.Number4)
        {
            _filter.SelectedItem = _filter.Items[key - Windows.System.VirtualKey.Number1];
        }
        else if (control && key == Windows.System.VirtualKey.F)
        {
            _search.Focus(FocusState.Keyboard);
            _search.SelectAll();
        }
        else if (control && key == Windows.System.VirtualKey.S)
        {
            SaveSelection(saveAs: shift);
        }
        else if (control && !shift && key == Windows.System.VirtualKey.P)
        {
            WithSingleImage(Pin);
        }
        else if (control && !shift && key == Windows.System.VirtualKey.O)
        {
            WithSingleImage(item => _ = RecognizeAsync(item));
        }
        else if (control && shift && key == Windows.System.VirtualKey.R)
        {
            RevealMany(PickedItems());
        }
        else if (busy)
        {
            return;
        }
        else if (control && key == Windows.System.VirtualKey.A)
        {
            Apply(Ids(), _listed.FirstOrDefault()?.Id, _cursor);
        }
        else if (control && key == Windows.System.VirtualKey.C)
        {
            CopySelection();
        }
        else if (!control && key == Windows.System.VirtualKey.Enter && OnlyPicked() is { } item)
        {
            Open(item);
        }
        else if (!control && key == Windows.System.VirtualKey.Delete && _picked.Count > 0)
        {
            ForgetSelection();
        }
        else if (!control && Direction(key) is { } step)
        {
            Move(step.Dx, step.Dy, shift);
        }
        else
        {
            return;
        }

        e.Handled = true;
    }

    private static (int Dx, int Dy)? Direction(Windows.System.VirtualKey key) => key switch
    {
        Windows.System.VirtualKey.Left => (-1, 0),
        Windows.System.VirtualKey.Right => (1, 0),
        Windows.System.VirtualKey.Up => (0, -1),
        Windows.System.VirtualKey.Down => (0, 1),
        _ => null,
    };

    /// <summary>方向键挑图（一行几张按网格宽度量）；按着 Shift 是从锚点连着选。挪到的那张滚进眼前、拿到焦点（读屏跟着念）。</summary>
    private void Move(int dx, int dy, bool shift)
    {
        var ids = Ids();
        var current = _cursor is { } cursor ? ids.IndexOf(cursor) : -1;
        // GridView 的每一格多出 4 的外边距（系统样式）。
        var columns = ShotHistoryRules.Columns(_grids.FirstOrDefault()?.ActualWidth ?? 0, CardWidth + 4);
        if (ShotHistoryRules.Moved(current < 0 ? null : current, dx, dy, _groupSizes, columns) is not { } next)
        {
            return;
        }

        var target = ids[next];
        if (shift)
        {
            var anchor = _anchor is { } from && ids.IndexOf(from) is var index and >= 0 ? index : Math.Max(current, 0);
            Apply(ShotHistoryRules.Span(ids, anchor, next), ids[anchor], target);
        }
        else
        {
            Apply(new[] { target }, target, target);
        }

        if (_cards.TryGetValue(target, out var place))
        {
            place.Card.StartBringIntoView();
            (place.Grid.ContainerFromItem(place.Card) as Control)?.Focus(FocusState.Keyboard);
        }
    }

    /// <summary>只对「正好选着一张截图」做的（钉图、识字）。</summary>
    private void WithSingleImage(Action<ShotItem> run)
    {
        if (OnlyPicked() is { } item && !ShotHistoryRules.IsRecording(item.Kind))
        {
            run(item);
        }
    }

    private void CopySelection()
    {
        var items = PickedItems();
        if (items.Count > 1)
        {
            _ = CopyManyAsync(items);
        }
        else if (items.Count == 1 && ShotHistoryRules.IsRecording(items[0].Kind))
        {
            CopyFile(items[0]);
        }
        else if (items.Count == 1)
        {
            _ = CopyAsync(items[0]);
        }
    }

    private void SaveSelection(bool saveAs)
    {
        var items = PickedItems();
        if (items.Count > 1 && !saveAs)
        {
            _ = SaveManyAsync(items);
        }
        else if (items.Count == 1 && !ShotHistoryRules.IsRecording(items[0].Kind))
        {
            _ = SaveAsync(items[0], saveAs);
        }
    }

    private void ForgetSelection()
    {
        var items = PickedItems();
        if (items.Count > 1)
        {
            _ = ForgetManyAsync(items);
        }
        else if (items.Count == 1)
        {
            _ = ForgetAsync(items[0]);
        }
    }

    // ---- 拖出去、一起拷贝 / 存储 / 显示 / 删除

    /// <summary>
    /// 这一条拖出去 / 一起拷贝时给哪个文件（照 mac ShotHistory.dragFile）：录制的就是那个文件；存过盘、文件还在的是存的那个；
    /// 别的把成品 PNG（原图 + 标注，本来就是 PNG）拷一份到临时文件夹，拷过、又没改过标注的直接用。没有返回 null。
    /// </summary>
    private static string? DragFile(ShotItem item)
    {
        if (ShotHistoryRules.IsRecording(item.Kind))
        {
            return ShotHistory.FileExists(item) ? item.FilePath : null;
        }

        if (item.SavedPath is { Length: > 0 } saved && File.Exists(saved))
        {
            return saved;
        }

        var source = File.Exists(ShotHistory.ComposedPath(item.Id)) ? ShotHistory.ComposedPath(item.Id) : ShotHistory.ImagePath(item.Id);
        if (!File.Exists(source))
        {
            return null;
        }

        try
        {
            // 每条一个子文件夹：同一秒截的两张名字一样，放一起会互相顶掉（启动时整个清掉）。
            var folder = Path.Combine(Path.GetTempPath(), "kitty-shots", "history", item.Id);
            Directory.CreateDirectory(folder);
            var created = LocalTime(item.CreatedAt).ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture);
            var path = Path.Combine(folder, $"{ShotHistoryRules.Title(item.Kind)} {created}.png");
            if (!File.Exists(path) || File.GetLastWriteTimeUtc(path) < File.GetLastWriteTimeUtc(source))
            {
                File.Copy(source, path, overwrite: true);
            }

            return path;
        }
        catch (Exception ex)
        {
            Log.Warn($"shots.drag-file-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>按住的是选中的之一就拖全部选中的，不然只拖它（不改选中）。</summary>
    private async void OnDragStarting(ShotItem item, DragStartingEventArgs args)
    {
        // REVIEW R11：不在 UI 线程上同步等异步，用 deferral + await（同角落卡）。
        var deferral = args.GetDeferral();
        try
        {
            var items = _picked.Count > 1 && _picked.Contains(item.Id) ? PickedItems() : new List<ShotItem> { item };
            var files = new List<IStorageItem>();
            foreach (var each in items)
            {
                if (DragFile(each) is { } path)
                {
                    files.Add(await StorageFile.GetFileFromPathAsync(path));
                }
            }

            if (files.Count == 0)
            {
                args.Cancel = true;
                return;
            }

            args.Data.SetStorageItems(files);
            args.Data.RequestedOperation = DataPackageOperation.Copy;
            args.Data.Properties.Title = files.Count == 1 ? files[0].Name : $"{files.Count} 项";
            Log.Info($"shots.drag count={files.Count}");
        }
        catch (Exception ex)
        {
            Log.Warn($"shots.drag-failed {ex.GetType().Name}");
            args.Cancel = true;
        }
        finally
        {
            deferral.Complete();
        }
    }

    /// <summary>好几张一起拷贝：剪贴板只装得下一张图，装成几个文件（同 mac copyMany，和拖出去同一份文件）。</summary>
    private static Task CopyManyAsync(List<ShotItem> items)
    {
        var paths = items.Select(DragFile).OfType<string>().ToList();
        if (paths.Count == 0)
        {
            NoticeHost.Show("没有能拷贝的文件", "选中的原图和录制文件都不在了", NoticeTone.Warning);
        }
        else if (ClipboardWriter.WriteFiles(paths))
        {
            ClipboardService.Instance?.MarkOwnWrite();
            NoticeHost.Show($"已复制 {paths.Count} 项", "能在资源管理器、聊天窗口里粘贴", NoticeTone.Normal);
        }
        else
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
        }

        return Task.CompletedTask;
    }

    /// <summary>好几张一起存：一条条存到截图文件夹，最后只说一句（同 mac saveMany）；录制的本来就是文件，跳过。</summary>
    private async Task SaveManyAsync(List<ShotItem> items)
    {
        string? last = null;
        var saved = 0;
        foreach (var item in items.Where(item => !ShotHistoryRules.IsRecording(item.Kind)))
        {
            if (ShotHistory.ReadOutput(item.Id) is not { } png || await ScreenshotOutput.QuickSavePngAsync(png, quiet: true) is not { } path)
            {
                continue;
            }

            _history.MarkSaved(item.Id, path);
            last = path;
            saved++;
        }

        if (last is null)
        {
            NoticeHost.Show("一张都没存成", "原图不在了，或者截图文件夹写不进去", NoticeTone.Warning);
            return;
        }

        NoticeHost.Show($"已存 {saved} 张", Path.GetFileName(Path.GetDirectoryName(last)) ?? last, NoticeTone.Normal,
            NoticeActions.Reveal(last));
    }

    /// <summary>在资源管理器里选中这几个文件（同一个文件夹的一次选中；没存成文件的跳过）。</summary>
    private static void RevealMany(List<ShotItem> items)
    {
        if (items.Count == 1)
        {
            Reveal(items[0]);
            return;
        }

        var paths = items.Select(item => item.FilePath ?? item.SavedPath).OfType<string>().Where(File.Exists).ToList();
        if (paths.Count == 0)
        {
            NoticeHost.Show("选中的都还没存成文件", "先点「存储」", NoticeTone.Normal);
            return;
        }

        // ponytail: 散在好几个文件夹时只开前 4 个，每个文件夹一扇资源管理器。
        foreach (var folder in paths.GroupBy(path => Path.GetDirectoryName(path) ?? string.Empty).Take(4))
        {
            SelectInExplorer(folder.Key, folder.ToList());
        }
    }

    /// <summary>SHOpenFolderAndSelectItems：开 folder，选中里面的这几个文件（explorer /select 只选得了一个）。</summary>
    private static void SelectInExplorer(string folder, List<string> files)
    {
        var parent = IntPtr.Zero;
        var children = new List<IntPtr>();
        try
        {
            parent = ILCreateFromPath(folder);
            children.AddRange(files.Select(ILCreateFromPath).Where(pidl => pidl != IntPtr.Zero));
            if (parent == IntPtr.Zero || children.Count == 0 ||
                SHOpenFolderAndSelectItems(parent, (uint)children.Count, children.ToArray(), 0) != 0)
            {
                Log.Warn("shots.reveal-many-failed");
            }
        }
        finally
        {
            foreach (var child in children)
            {
                ILFree(child);
            }

            if (parent != IntPtr.Zero)
            {
                ILFree(parent);
            }
        }
    }

    /// <summary>好几张一起删：问一次（截图的原图和标注删掉，录制的文件不动、只是不在历史里了）。</summary>
    private async Task ForgetManyAsync(List<ShotItem> items)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = $"删除这 {items.Count} 项？",
            Content = "截图的原图和标注会删掉，已经存成文件的不动；录制的文件也不动，只是不在历史里了。",
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = _root.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            _history.Remove(items.Select(item => item.Id).ToList());
        }
    }

    [LibraryImport("shell32.dll", EntryPoint = "ILCreateFromPathW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr ILCreateFromPath(string path);

    [LibraryImport("shell32.dll")]
    private static partial void ILFree(IntPtr pidl);

    [LibraryImport("shell32.dll")]
    private static partial int SHOpenFolderAndSelectItems(IntPtr folder, uint count, IntPtr[] items, uint flags);

    private static string KindGlyph(ShotKind kind) => kind switch
    {
        ShotKind.Video => Glyphs.Record,
        ShotKind.Audio => Glyphs.Microphone,
        ShotKind.Gif => Glyphs.Image,
        _ => Glyphs.Screenshot,
    };

    private static DateTime LocalTime(long unixMs) => DateTimeOffset.FromUnixTimeMilliseconds(unixMs).LocalDateTime;
}
