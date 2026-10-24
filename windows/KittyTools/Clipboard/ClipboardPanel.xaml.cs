// 剪贴板面板：搜索框 + 收藏范围 + 左列表右预览。焦点一直在搜索框，方向键转给列表。
// 按键表见 PLAN §6.3；删除先只从列表拿掉（Ctrl+Z 可撤），面板收起时才真的删库。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;

namespace KittyTools;

public sealed partial class ClipboardPanel : UserControl
{
    private readonly List<ClipEntry> _visible = new();
    private bool _favoritesOnly;
    private bool _active;

    public ClipboardPanel()
    {
        InitializeComponent();
        AddHandler(KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: true);
        SearchBox.Loaded += (_, _) =>
        {
            if (_active)
            {
                FocusSearch();
            }
        };
        if (ClipboardService.Instance?.Store is { } store)
        {
            store.Changed += OnStoreChanged;
        }
    }

    public event Action? CloseRequested;

    public event Action? SettingsRequested;

    private static ClipboardStore? Store => ClipboardService.Instance?.Store;

    public void OnShown()
    {
        _active = true;
        SearchBox.Text = string.Empty;
        SetScope(favorites: false, refresh: false);
        Refresh();
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
        SearchBox.Text = string.Empty;
        _visible.Clear();
        List.ItemsSource = null;
        PreviewHost.Children.Clear();
        if (Store is { } store)
        {
            store.CommitDeletion();
            store.EnforceLimits();
        }
    }

    public void Refresh(long? keepSelection = null)
    {
        if (Store is not { } store)
        {
            return;
        }

        var previous = keepSelection ?? SelectedEntry?.Id;
        _visible.Clear();
        _visible.AddRange(store.Filter(SearchBox.Text.Trim(), _favoritesOnly));

        var rows = new List<ClipRow>(_visible.Count);
        var lastDate = long.MinValue;
        foreach (var entry in _visible)
        {
            var localDate = DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt).ToLocalTime().Date.Ticks;
            rows.Add(ClipRow.Create(entry, localDate != lastDate));
            lastDate = localDate;
        }

        List.ItemsSource = rows;
        if (rows.Count == 0)
        {
            List.SelectedIndex = -1;
            ShowPreview(null);
        }
        else
        {
            var index = previous is { } id ? rows.FindIndex(row => row.Entry.Id == id) : 0;
            List.SelectedIndex = index < 0 ? 0 : index;
            List.ScrollIntoView(rows[List.SelectedIndex]);
            ShowPreview(rows[List.SelectedIndex].Entry);
        }

        UpdateFooter();
    }

    private void UpdateFooter()
    {
        if (_visible.Count == 0)
        {
            FooterText.Text = SearchBox.Text.Length > 0 ? "没有匹配的条目" : "还没有记录，复制点什么试试";
            return;
        }

        var scope = _favoritesOnly ? "收藏 · " : string.Empty;
        FooterText.Text =
            $"{_visible.Count} 条 · {scope}粘贴 Enter · 纯文本 Shift+Enter · 更多 右键 · 收藏 Ctrl+D";
    }

    private ClipEntry? SelectedEntry => (List.SelectedItem as ClipRow)?.Entry;

    private void OnStoreChanged()
    {
        if (_active)
        {
            Refresh(SelectedEntry?.Id);
        }
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e) => Refresh();

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
        => ShowPreview(SelectedEntry);

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ClipRow row)
        {
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
        header.Children.Add(new TextBlock
        {
            Text = ClipRow.DateLabel(entry.CopiedAt) + " " +
                   DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt).ToLocalTime().ToString("HH:mm:ss"),
            FontSize = 12,
            Opacity = 0.65,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var favorite = new Button
        {
            Content = entry.Favorite ? "取消收藏" : "收藏",
            Padding = new Thickness(10, 4, 10, 4),
        };
        favorite.Click += (_, _) =>
        {
            Store?.ToggleFavorite(entry.Id);
            Refresh(entry.Id);
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

        var source = new TextBlock
        {
            Text = string.IsNullOrEmpty(entry.SourceName)
                ? entry.Kind == ClipKind.Text ? "来源：未知" : "本机生成"
                : $"来源：{entry.SourceName}",
            FontSize = 12,
            Opacity = 0.55,
            Margin = new Thickness(0, 6, 0, 0),
        };
        PreviewHost.Children.Add(source);
    }

    private void ShowText(ClipEntry entry)
    {
        var text = entry.Text ?? string.Empty;
        const int limit = 50_000;
        var truncated = text.Length > limit;
        var block = new TextBlock
        {
            Text = truncated ? text[..limit] : text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontSize = 14,
            LineHeight = 22,
        };
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

        var image = new Image
        {
            MaxHeight = 340,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        PreviewHost.Children.Add(image);
        PreviewHost.Children.Add(new TextBlock
        {
            Text = $"{entry.Width} × {entry.Height} · {entry.ImageBytes / 1024.0:F1} KB",
            FontSize = 12,
            Opacity = 0.6,
        });
        _ = LoadImageAsync(image, path);
    }

    private async Task LoadImageAsync(Image image, string path)
    {
        try
        {
            using var stream = await FileRandomAccessStream.OpenAsync(path, FileAccessMode.Read);
            var bitmap = new BitmapImage();
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
        List.SelectedIndex = index;
        List.ScrollIntoView(List.SelectedItem);
    }

    private void Paste(bool plain)
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

        var rich = RichOf(entry);
        var service = ClipboardService.Instance;
        var pasted = Paster.Paste(
            target,
            () => ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plain),
            service);
        if (pasted)
        {
            service?.Store.Bump(entry.Id);
        }
    }

    private static (string? Html, string? Rtf) RichOf(ClipEntry entry)
        => entry.Kind == ClipKind.Text && ClipboardService.Instance is { } service
            ? service.Database.LoadRich(entry.Id)
            : (null, null);

    private static bool EntryUsable(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => File.Exists(Paths.ImagesFile(entry.Id)),
        ClipKind.Files => entry.Files.All(file => File.Exists(file) || Directory.Exists(file)),
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

    private void Copy(ClipEntry entry)
    {
        if (!EntryUsable(entry))
        {
            NoticeHost.Show("没能复制", entry.Kind == ClipKind.Image ? "图片文件丢了" : "文件已经不在原处", NoticeTone.Warning);
            return;
        }

        var rich = RichOf(entry);
        if (!ClipboardWriter.WriteEntry(entry, rich.Html, rich.Rtf, plainText: false))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
            return;
        }

        ClipboardService.Instance?.MarkOwnWrite();
        NoticeHost.Show("已复制", PreviewLine(entry), NoticeTone.Normal);
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

        TranslateHost.ShowText(entry.Text);
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
            AddItem(menu, "钉到屏幕", () => NoticeHost.Show("钉图", "第 5 批接上", NoticeTone.Normal));
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
