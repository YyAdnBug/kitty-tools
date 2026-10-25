// 剪贴板面板：搜索框 + 收藏范围 + 左列表右预览。焦点一直在搜索框，方向键转给列表。
// 按键表见 PLAN §6.3；删除先只从列表拿掉（Ctrl+Z 可撤），面板收起时才真的删库。
// 列表用一个固定的 ObservableCollection，按键搜索时只替换变了的尾部，不整表重建 ItemsSource。
// 第二版 §3.5：高度随内容（三行起、十行封顶）、只有一块会滑动的选中高亮、按住 Ctrl 150 ms 后
// 前九行右边浮现数字键帽、预览卡按内容换字体 / 色块 / 棋盘格、空状态各一句。
using System.Collections.ObjectModel;
using System.Numerics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using Windows.Win32;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;

namespace KittyTools;

public sealed partial class ClipboardPanel : UserControl
{
    private readonly List<ClipEntry> _visible = new();
    private readonly ObservableCollection<ClipRow> _rows = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _keyHintTimer;
    private bool _favoritesOnly;
    private bool _active;
    private bool _showKeyHints;
    private bool _animateHighlight;
    private MotionCurve _highlightCurve = MotionCurve.Glide;
    private ScrollViewer? _listScroll;

    public ClipboardPanel()
    {
        InitializeComponent();
        AddHandler(KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: true);
        AddHandler(KeyUpEvent, new KeyEventHandler(OnKeyUp), handledEventsToo: true);
        SearchBox.Loaded += (_, _) =>
        {
            if (_active)
            {
                FocusSearch();
            }
        };
        _keyHintTimer = DispatcherQueue.CreateTimer();
        _keyHintTimer.Interval = TimeSpan.FromMilliseconds(150);
        _keyHintTimer.IsRepeating = false;
        _keyHintTimer.Tick += (_, _) => SetKeyHints(true);

        List.Loaded += (_, _) =>
        {
            _listScroll ??= FindDescendant<ScrollViewer>(List);
            if (_listScroll is not null)
            {
                _listScroll.ViewChanged += (_, _) => MoveHighlight(animated: false);
            }

            MoveHighlight(animated: false);
        };
        if (ClipboardService.Instance?.Store is { } store)
        {
            store.Changed += OnStoreChanged;
        }
    }

    public event Action? CloseRequested;

    public event Action? SettingsRequested;

    /// <summary>内容高度变了（DIP，是否带动画）：浮层窗口据此改高度、顶边不动（第二版 §3.5）。</summary>
    public event Action<double, bool>? HeightRequested;

    /// <summary>按当前条数算出来的面板高度（三行起、十行封顶、最多 520 DIP）。</summary>
    public double ContentHeightDip => PanelMetrics.ClipboardHeight(_visible.Count);

    private static ClipboardStore? Store => ClipboardService.Instance?.Store;

    public void OnShown()
    {
        _active = true;
        SearchBox.Text = string.Empty;
        SetKeyHints(false);
        SetScope(favorites: false, refresh: false);
        Refresh(animated: false);
        FocusSearch();
    }

    /// <summary>从启动器「cb 词」进来：把词填进搜索框。</summary>
    public void SetQuery(string query)
    {
        SearchBox.Text = query;
        SearchBox.SelectionStart = SearchBox.Text.Length;
        Refresh();
        FocusSearch();
    }

    /// <summary>窗口激活后再抢一次焦点：刚 Activate 时 Focus 可能落不下去。</summary>
    public void FocusSearch()
    {
        var ok = SearchBox.Focus(FocusState.Programmatic);
        Log.Info($"clipboard.focus ok={ok}");
        if (!ok)
        {
            _ = FocusManager.TryFocusAsync(SearchBox, FocusState.Programmatic);
        }
    }

    public void OnHidden()
    {
        _active = false;
        _keyHintTimer.Stop();
        _showKeyHints = false;
        SearchBox.Text = string.Empty;
        _visible.Clear();
        _rows.Clear();
        List.SelectedIndex = -1;
        Highlight.Visibility = Visibility.Collapsed;
        PreviewHost.Children.Clear();
        if (Store is { } store)
        {
            store.CommitDeletion();
            store.EnforceLimits();
        }
    }

    public void Refresh(long? keepSelection = null, bool animated = true)
    {
        if (Store is not { } store)
        {
            return;
        }

        var previous = keepSelection ?? SelectedEntry?.Id;
        _visible.Clear();
        _visible.AddRange(store.Filter(SearchBox.Text.Trim(), _favoritesOnly));

        ApplyRows();

        if (_visible.Count == 0)
        {
            _animateHighlight = false;
            List.SelectedIndex = -1;
            ShowPreview(null);
        }
        else
        {
            var index = previous is { } id ? _visible.FindIndex(entry => entry.Id == id) : 0;
            index = index < 0 ? 0 : index;
            if (List.SelectedIndex == index)
            {
                // 同一条还在同一个位置：选中项没变，高亮自己重新量一次就行。
                ShowPreview(_visible[index]);
                DispatcherQueue.TryEnqueue(() => MoveHighlight(animated: false));
            }
            else
            {
                _animateHighlight = animated;
                List.SelectedIndex = index;
            }

            List.ScrollIntoView(_rows[List.SelectedIndex]);
        }

        UpdateFooter();
        UpdateEmptyState();
        HeightRequested?.Invoke(ContentHeightDip, animated);
    }

    /// <summary>
    /// 只把变了的尾部换掉：前缀的条目和日期分隔都没变就沿用原来的行，
    /// 不重设 ItemsSource（每按一个键整表重建会让列表跳动、虚拟化的容器全丢）。
    /// </summary>
    private void ApplyRows()
    {
        if (!ReferenceEquals(List.ItemsSource, _rows))
        {
            List.ItemsSource = _rows;
        }

        var headers = new bool[_visible.Count];
        var lastDate = long.MinValue;
        for (var index = 0; index < _visible.Count; index++)
        {
            var localDate = DateTimeOffset.FromUnixTimeMilliseconds(_visible[index].CopiedAt).ToLocalTime().Date.Ticks;
            headers[index] = localDate != lastDate;
            lastDate = localDate;
        }

        var reuse = 0;
        while (reuse < _visible.Count && reuse < _rows.Count &&
               _rows[reuse].SameAs(_visible[reuse], headers[reuse], reuse, _showKeyHints))
        {
            reuse++;
        }

        for (var index = _rows.Count - 1; index >= reuse; index--)
        {
            _rows.RemoveAt(index);
        }

        for (var index = reuse; index < _visible.Count; index++)
        {
            _rows.Add(ClipRow.Create(_visible[index], headers[index], index, _showKeyHints));
        }
    }

    private void UpdateFooter()
    {
        if (_visible.Count == 0)
        {
            FooterText.Text = string.Empty;
            return;
        }

        var scope = _favoritesOnly ? "收藏 · " : string.Empty;
        FooterText.Text =
            $"{_visible.Count} 条 ｜ {scope}粘贴 Enter · 纯文本 Shift+Enter · 更多（右键）· 收藏 Ctrl+D";
    }

    private void UpdateEmptyState()
    {
        var empty = _visible.Count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (empty)
        {
            EmptyText.Text = SearchBox.Text.Trim().Length > 0
                ? "没有匹配的条目\n换个词试试"
                : "还没有剪贴板历史\n复制点什么就会出现";
        }
    }

    /// <summary>按住 Ctrl 150 ms 后前九行右边浮现数字键帽（PLAN-v2 §3.5）。</summary>
    private void SetKeyHints(bool show)
    {
        if (_showKeyHints == show)
        {
            return;
        }

        _showKeyHints = show;
        ApplyRows();
    }

    /// <summary>只有一块中性高亮，换选中项时滑过去：键盘用 snap，鼠标点用 glide，换列表时不动画。</summary>
    private void MoveHighlight(bool animated)
    {
        var index = List.SelectedIndex;
        if (index < 0 || index >= _visible.Count)
        {
            Highlight.Visibility = Visibility.Collapsed;
            return;
        }

        if (List.ContainerFromIndex(index) is not ListViewItem container)
        {
            // 容器还没实现（虚拟化 / 刚换列表）：等下一次布局。
            Highlight.Visibility = Visibility.Collapsed;
            return;
        }

        var row = container.ContentTemplateRoot is Panel panel && panel.Children.Count > 1 &&
                  panel.Children[1] is FrameworkElement inner
            ? inner
            : container;
        var offset = row.TransformToVisual(List).TransformPoint(new Windows.Foundation.Point(0, 0));
        Highlight.Width = Math.Max(0, List.ActualWidth - 2);
        Highlight.Height = Math.Max(24, row.ActualHeight);
        Highlight.Visibility = Visibility.Visible;
        if (animated)
        {
            Motion.SlideTo(Highlight, 0, offset.Y, EnableAnimations ? _highlightCurve : MotionCurve.Instant);
        }
        else
        {
            Highlight.Translation = new Vector3(0, (float)offset.Y, 0);
        }
    }

    private bool EnableAnimations => !Motion.Reduced;

    private static T? FindDescendant<T>(DependencyObject root)
        where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T match)
            {
                return match;
            }

            if (FindDescendant<T>(child) is { } deeper)
            {
                return deeper;
            }
        }

        return null;
    }

    private ClipEntry? SelectedEntry => (List.SelectedItem as ClipRow)?.Entry;

    private void OnStoreChanged()
    {
        if (_active)
        {
            Refresh(SelectedEntry?.Id, animated: false);
        }
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e) => Refresh(animated: false);

    private void OnAllScopeClick(object sender, RoutedEventArgs e) => SetScope(favorites: false);

    private void OnFavoriteScopeClick(object sender, RoutedEventArgs e) => SetScope(favorites: true);

    private void SetScope(bool favorites, bool refresh = true)
    {
        _favoritesOnly = favorites;
        AllScope.IsChecked = !favorites;
        FavoriteScope.IsChecked = favorites;
        if (refresh)
        {
            Refresh();
            SearchBox.Focus(FocusState.Programmatic);
        }
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ShowPreview(SelectedEntry);
        var animated = _animateHighlight;
        _animateHighlight = false;
        // 选中项的容器可能还没实现：等这一轮布局完再量它的位置。
        DispatcherQueue.TryEnqueue(() => MoveHighlight(animated));
    }

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ClipRow row)
        {
            _animateHighlight = true;
            _highlightCurve = MotionCurve.Glide;
            List.SelectedItem = row;
        }
    }

    private void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        e.Handled = true;
        Paste(plain: false);
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private void ShowPreview(ClipEntry? entry)
    {
        PreviewHost.Children.Clear();
        if (entry is null)
        {
            PreviewHost.Children.Add(new TextBlock
            {
                Text = "选中一条看预览",
                Opacity = 0.55,
                Margin = new Thickness(0, 8, 0, 0),
            });
            return;
        }

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // 卡头：类型图标 + 来源 + 时间（PLAN-v2 §3.5）。
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(new FontIcon
        {
            Glyph = entry.Kind switch
            {
                ClipKind.Image => "\uEB9F",
                ClipKind.Files => "\uE8B7",
                _ => "\uE8C8",
            },
            FontSize = 13,
            Foreground = new SolidColorBrush(Theme.Family.Clipboard),
            VerticalAlignment = VerticalAlignment.Center,
        });
        title.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(entry.SourceName) ? "本机" : entry.SourceName,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        title.Children.Add(new TextBlock
        {
            Text = PreviewRules.SourceAndAge(null, ClipRow.Relative(entry.CopiedAt)) + " · " +
                   DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt).ToLocalTime().ToString("HH:mm:ss"),
            FontSize = 12,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        });
        Grid.SetColumn(title, 0);
        header.Children.Add(title);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var favorite = new Button
        {
            Content = entry.Favorite ? "取消收藏" : "收藏",
            Padding = new Thickness(10, 4, 10, 4),
        };
        favorite.Click += (_, _) =>
        {
            Store?.ToggleFavorite(entry.Id);
            Refresh(entry.Id, animated: false);
        };
        var copy = new Button { Content = "复制", Padding = new Thickness(10, 4, 10, 4) };
        copy.Click += (_, _) => Copy(entry);
        if (entry.Kind == ClipKind.Text)
        {
            var translate = new Button { Content = "翻译", Padding = new Thickness(10, 4, 10, 4) };
            translate.Click += (_, _) => TranslateEntry(entry);
            actions.Children.Add(translate);
        }

        actions.Children.Add(favorite);
        actions.Children.Add(copy);
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        PreviewHost.Children.Add(header);

        switch (entry.Kind)
        {
            case ClipKind.Image:
                ShowImage(entry);
                break;
            case ClipKind.Files:
                ShowFiles(entry);
                break;
            default:
                ShowText(entry);
                break;
        }
    }

    private void ShowText(ClipEntry entry)
    {
        var text = entry.Text ?? string.Empty;

        // 整条就是一个颜色值：上面加一块色块（PLAN-v2 §3.5）。
        if (PreviewRules.TryParseColor(text, out var red, out var green, out var blue))
        {
            var swatch = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            swatch.Children.Add(new Border
            {
                Width = 44,
                Height = 44,
                CornerRadius = new CornerRadius(8),
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, red, green, blue)),
                BorderThickness = new Thickness(1),
                BorderBrush = Theme.Brush("ControlStrokeColorDefaultBrush", Windows.UI.Color.FromArgb(40, 128, 128, 128)),
            });
            swatch.Children.Add(new TextBlock
            {
                Text = $"#{red:X2}{green:X2}{blue:X2}",
                FontFamily = new FontFamily("Consolas"),
                FontSize = 13,
                VerticalAlignment = VerticalAlignment.Center,
            });
            PreviewHost.Children.Add(swatch);
        }

        const int limit = 50_000;
        var truncated = text.Length > limit;
        var code = PreviewRules.LooksLikeCode(text);
        var block = new TextBlock
        {
            Text = truncated ? text[..limit] : text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontSize = code ? 13 : 14,
            LineHeight = code ? 20 : 22,
        };
        if (code)
        {
            // FontFamily 不能设成 null（WinUI 里会直接挂掉），只在是代码时才换字体。
            block.FontFamily = new FontFamily("Consolas");
        }

        PreviewHost.Children.Add(block);
        if (truncated)
        {
            PreviewHost.Children.Add(new TextBlock
            {
                Text = $"只显示前 {limit:N0} 个字，粘贴时是完整内容",
                FontSize = 12,
                Opacity = 0.55,
            });
        }
    }

    private void ShowImage(ClipEntry entry)
    {
        var path = Paths.ImagesFile(entry.Id);
        if (!File.Exists(path))
        {
            PreviewHost.Children.Add(new TextBlock
            {
                Text = "图片文件丢了（可能被清理了）",
                Opacity = 0.7,
            });
            return;
        }

        var stack = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        var checker = Checkerboard();
        stack.Children.Add(checker);

        var image = new Image
        {
            MaxHeight = 340,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        stack.Children.Add(image);

        // 右上角标「宽 × 高」（PLAN-v2 §3.5）。
        var size = new Border
        {
            Padding = new Thickness(6, 2, 6, 2),
            CornerRadius = new CornerRadius(4),
            Background = Theme.Brush("ControlFillColorSecondaryBrush", Windows.UI.Color.FromArgb(160, 32, 32, 32)),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 4, 4, 0),
            Child = new TextBlock
            {
                Text = $"{entry.Width} × {entry.Height}",
                FontSize = 11,
                FontFamily = new FontFamily("Consolas"),
            },
        };
        stack.Children.Add(size);
        PreviewHost.Children.Add(stack);
        _ = LoadImageAsync(image, path, PreviewDecodeWidth());
    }

    /// <summary>透明图片后面的棋盘格（十来行，比引一个平铺画刷省事）。</summary>
    private static Grid Checkerboard()
    {
        var grid = new Grid
        {
            Width = 320,
            Height = 240,
            HorizontalAlignment = HorizontalAlignment.Left,
            Opacity = 0.5,
        };
        var light = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 220, 220, 220));
        var dark = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 190, 190, 190));
        const int cell = 16;
        for (var row = 0; row < 15; row++)
        {
            for (var column = 0; column < 20; column++)
            {
                var square = new Border
                {
                    Width = cell,
                    Height = cell,
                    Background = (row + column) % 2 == 0 ? light : dark,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(column * cell, row * cell, 0, 0),
                };
                grid.Children.Add(square);
            }
        }

        return grid;
    }

    /// <summary>
    /// 预览按预览区的宽度 × 缩放比例解码（4K 截图整张解码要 33 MB）。预览区还没排好时给个保守值。
    /// </summary>
    private int PreviewDecodeWidth()
    {
        var width = PreviewScroll.ActualWidth > 0 ? PreviewScroll.ActualWidth : 520;
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        return Math.Clamp((int)Math.Round(width * scale), 64, 2048);
    }

    private async Task LoadImageAsync(Image image, string path, int decodeWidth)
    {
        try
        {
            using var stream = await FileRandomAccessStream.OpenAsync(path, FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = decodeWidth };
            await bitmap.SetSourceAsync(stream);
            image.Source = bitmap;
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.preview-image-failed {ex.GetType().Name}");
        }
    }

    private void ShowFiles(ClipEntry entry)
    {
        var files = entry.Files;
        var panel = new StackPanel { Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var file in files.Take(50))
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var exists = File.Exists(file) || Directory.Exists(file);
            row.Children.Add(new FontIcon
            {
                Glyph = Directory.Exists(file) ? "\uE8B7" : "\uE8A5",
                FontSize = 14,
                Opacity = exists ? 0.8 : 0.4,
            });
            row.Children.Add(new TextBlock
            {
                Text = exists ? file : file + "（找不到了）",
                TextWrapping = TextWrapping.Wrap,
                FontSize = 13,
                Opacity = exists ? 0.9 : 0.5,
            });
            panel.Children.Add(row);
        }

        if (files.Length > 50)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"还有 {files.Length - 50} 个文件",
                FontSize = 12,
                Opacity = 0.55,
            });
        }

        PreviewHost.Children.Add(panel);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_active)
        {
            return;
        }

        if (e.Key == VirtualKey.Control)
        {
            // 按住 Ctrl 150 ms 才浮现键帽：中途松开就不显示（PLAN-v2 §3.5）。
            _keyHintTimer.Stop();
            _keyHintTimer.Start();
            return;
        }

        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                if (SearchBox.Text.Length > 0)
                {
                    SearchBox.Text = string.Empty;
                }
                else
                {
                    CloseRequested?.Invoke();
                }

                break;
            case VirtualKey.W when control:
                e.Handled = true;
                CloseRequested?.Invoke();
                break;
            case VirtualKey.Down:
                e.Handled = true;
                MoveSelection(1);
                break;
            case VirtualKey.Up:
                e.Handled = true;
                MoveSelection(-1);
                break;
            case VirtualKey.Enter when !control:
                e.Handled = true;
                Paste(shift);
                break;
            case VirtualKey.Tab:
                e.Handled = true;
                SetScope(!_favoritesOnly);
                break;
            case VirtualKey.Delete when SearchBox.SelectionStart == SearchBox.Text.Length &&
                                        SearchBox.SelectionLength == 0:
                e.Handled = true;
                DeleteSelected();
                break;
            case VirtualKey.C when control:
                if (SearchBox.SelectionLength > 0)
                {
                    break; // 搜索框里选中了字：交还给搜索框
                }

                e.Handled = true;
                CopySelected();
                break;
            case VirtualKey.D when control:
                e.Handled = true;
                FavoriteSelected();
                break;
            case VirtualKey.Z when control:
                if (SearchBox.Text.Length > 0)
                {
                    break; // 搜索框里有字：让输入框自己撤销
                }

                e.Handled = true;
                UndoDelete();
                break;
            case VirtualKey.T when control:
                e.Handled = true;
                if (SelectedEntry is { } selected)
                {
                    TranslateEntry(selected);
                }

                break;
            case VirtualKey.Number1 or VirtualKey.Number2 or VirtualKey.Number3 or VirtualKey.Number4
                or VirtualKey.Number5 or VirtualKey.Number6 or VirtualKey.Number7 or VirtualKey.Number8
                or VirtualKey.Number9 when control:
                e.Handled = true;
                var number = (int)e.Key - (int)VirtualKey.Number1;
                if (number < _visible.Count)
                {
                    List.SelectedIndex = number;
                    Paste(plain: false);
                }

                break;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Control)
        {
            _keyHintTimer.Stop();
            SetKeyHints(false);
        }
    }

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void MoveSelection(int delta)
    {
        if (_visible.Count == 0)
        {
            return;
        }

        var index = Math.Clamp(List.SelectedIndex + delta, 0, _visible.Count - 1);
        _highlightCurve = MotionCurve.Snap;
        _animateHighlight = true;
        List.SelectedIndex = index;
        List.ScrollIntoView(List.SelectedItem);
    }

    private async void Paste(bool plain)
    {
        var entry = SelectedEntry;
        if (entry is null)
        {
            return;
        }

        if (!EntryUsable(entry))
        {
            NoticeHost.Show("没能粘贴", entry.Kind == ClipKind.Image ? "图片文件丢了" : "文件已经不在原处", NoticeTone.Warning);
            return;
        }

        var target = OverlayHost.PasteTarget;
        if (target == default)
        {
            Copy(entry);
            return;
        }

        try
        {
            // 图片的 DIB 先在后台转好，写剪贴板时一次写完（不占着剪贴板等编码）。
            var dib = entry.Kind == ClipKind.Image ? await PrepareDibAsync(entry) : null;
            var rich = RichOf(entry);
            var service = ClipboardService.Instance;
            var pasted = Paster.Paste(
                target,
                () => ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plain, dib),
                service);
            if (pasted)
            {
                service?.Store.Bump(entry.Id);
            }
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.paste-failed", ex);
            NoticeHost.Show("没能粘贴", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static async Task<byte[]?> PrepareDibAsync(ClipEntry entry)
        => (await ClipboardWriter.PrepareImageAsync(entry))?.Dib;

    private static (string? Html, string? Rtf) RichOf(ClipEntry entry)
        => entry.Kind == ClipKind.Text && ClipboardService.Instance is { } service
            ? service.Database.LoadRich(entry.Id)
            : (null, null);

    /// <summary>文件条目：只要还有一个在就还能粘（PLAN 和 mac 是全都不在才拦）。</summary>
    private static bool EntryUsable(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => File.Exists(Paths.ImagesFile(entry.Id)),
        ClipKind.Files => entry.Files.Any(file => File.Exists(file) || Directory.Exists(file)),
        _ => true,
    };

    private void CopySelected()
    {
        var entry = SelectedEntry;
        if (entry is not null)
        {
            Copy(entry);
        }
    }

    private async void Copy(ClipEntry entry)
    {
        if (!EntryUsable(entry))
        {
            NoticeHost.Show("没能复制", entry.Kind == ClipKind.Image ? "图片文件丢了" : "文件已经不在原处", NoticeTone.Warning);
            return;
        }

        try
        {
            var dib = entry.Kind == ClipKind.Image ? await PrepareDibAsync(entry) : null;
            var rich = RichOf(entry);
            if (!ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plainText: false, dib))
            {
                NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
                return;
            }

            ClipboardService.Instance?.MarkOwnWrite();
            NoticeHost.Show("已复制", PreviewLine(entry), NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.copy-failed", ex);
            NoticeHost.Show("没能复制", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static string PreviewLine(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => $"{entry.Width} × {entry.Height} 的图片",
        ClipKind.Files => entry.Files.FirstOrDefault() ?? "文件",
        _ => KillLine(entry.Text ?? string.Empty),
    };

    private static string KillLine(string text)
    {
        var line = text.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return line.Length <= 40 ? line : line[..40] + "…";
    }

    private void DeleteSelected()
    {
        var entry = SelectedEntry;
        if (entry is null || Store is not { } store)
        {
            return;
        }

        store.DeleteWithUndo(new[] { entry.Id });
        NoticeHost.Show("已删除", "收起面板前可以按 Ctrl+Z 撤销", NoticeTone.Normal);
        Refresh();
    }

    private void UndoDelete()
    {
        if (Store is not { } store)
        {
            return;
        }

        var restored = store.Undo();
        if (restored is { Count: > 0 })
        {
            NoticeHost.Show("已撤销", string.Empty, NoticeTone.Normal);
            Refresh(restored[0].Id);
        }
    }

    private void FavoriteSelected()
    {
        var entry = SelectedEntry;
        if (entry is null)
        {
            return;
        }

        Store?.ToggleFavorite(entry.Id);
        Refresh(entry.Id);
    }

    private static void TranslateEntry(ClipEntry entry)
    {
        if (entry.Kind != ClipKind.Text || string.IsNullOrWhiteSpace(entry.Text))
        {
            NoticeHost.Show("不能翻译", "只有文本条目能翻译", NoticeTone.Warning);
            return;
        }

        // 剪贴板面板留着，翻译浮窗只露出（PLAN §7.4 / PLAN-v2 §6 第 1 批）。
        TranslateHost.ShowTextKeepOverlay(entry.Text);
    }

    private async Task PinImageAsync(ClipEntry entry)
    {
        try
        {
            var path = Paths.ImagesFile(entry.Id);
            if (!File.Exists(path))
            {
                return;
            }
            var png = await File.ReadAllBytesAsync(path);
            var decoded = await ImageCodec.PngToBgraAsync(png);
            if (decoded is not { } image)
            {
                return;
            }
            PInvoke.GetCursorPos(out var cursor);
            var area = DisplayArea.GetFromPoint(
                new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary).WorkArea;
            var scale = Math.Min(1, Math.Min(area.Width * 0.8 / image.Width, area.Height * 0.8 / image.Height));
            var width = Math.Max(1, (int)(image.Width * scale));
            var height = Math.Max(1, (int)(image.Height * scale));
            var left = Math.Clamp(cursor.X - width / 2, area.X, area.X + area.Width - width);
            var top = Math.Clamp(cursor.Y - height / 2, area.Y, area.Y + area.Height - height);
            PinHost.Show(png, new PixelBounds(left, top, left + width, top + height));
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.pin-failed", ex);
            NoticeHost.Show("没能钉图", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private void OnListRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var row = (e.OriginalSource as FrameworkElement)?.DataContext as ClipRow;
        if (row is null)
        {
            return;
        }

        List.SelectedItem = row;
        var entry = row.Entry;
        var menu = new MenuFlyout();
        AddItem(menu, "粘贴", () => Paste(plain: false));
        AddItem(menu, "粘贴为纯文本", () => Paste(plain: true));
        AddItem(menu, "复制", () => Copy(entry));
        AddItem(menu, entry.Favorite ? "取消收藏" : "收藏", () => FavoriteSelected());
        if (entry.Kind == ClipKind.Text)
        {
            AddItem(menu, "翻译", () => TranslateEntry(entry));
        }

        if (entry.Kind == ClipKind.Image)
        {
            AddItem(menu, "钉到屏幕", () => _ = PinImageAsync(entry));
        }

        if (entry.Kind == ClipKind.Files && entry.Files.FirstOrDefault() is { } first)
        {
            AddItem(menu, "在资源管理器中显示", () => RevealInExplorer(first));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        AddItem(menu, "删除", () => DeleteSelected());
        menu.ShowAt(List, new FlyoutShowOptions { Position = e.GetPosition(List) });
        e.Handled = true;
    }

    private static void AddItem(MenuFlyout menu, string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    private static void RevealInExplorer(string path)
    {
        try
        {
            var arguments = File.Exists(path) ? $"/select,\"{path}\"" : $"\"{path}\"";
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = arguments,
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.reveal-failed {ex.GetType().Name}");
        }
    }
}
