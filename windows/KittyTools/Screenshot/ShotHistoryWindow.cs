// 截图历史窗口（PLAN-v8 第 2 批 H5，照 mac 的 ShotHistoryWindow / ShotHistoryView）：普通的 WinUI 窗口（外壳跟 Windows），
// 左边按天分组的缩略图网格，右边 280 宽的预览、两行信息和一列操作；顶上「全部 / 截图 / 长截图 / 录制」+ 搜索框。
// 只建一扇；关掉就整扇放掉，缩略图跟着放。入口：快捷动作「截图历史」（托盘、启动器、快捷键页）、设置 › 截图。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;
using Windows.Win32;

namespace KittyTools;

internal sealed class ShotHistoryWindow : Window
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
    private int _shown = PageSize;
    private ShotItem? _selected;
    private bool _syncingSelection;

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

        _preview = new Image { Stretch = Stretch.Uniform };
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
        AppWindow.SetIcon(Paths.ExecutablePath);
        Theme.ApplyTitleBar(AppWindow);

        // Delete 删掉选中的那条（先问一次）；焦点在搜索框里时是删字。
        _root.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Delete && args.OriginalSource is not TextBox &&
                _selected is { } selected)
            {
                args.Handled = true;
                _ = ForgetAsync(selected);
            }
        };
        _history.Changed += OnHistoryChanged;
        _history.ThumbnailChanged += OnThumbnailChanged;
        Closed += (_, _) =>
        {
            _history.Changed -= OnHistoryChanged;
            _history.ThumbnailChanged -= OnThumbnailChanged;
            _groups.Children.Clear();
            _grids.Clear();
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
        var items = Filtered().ToList();
        if (items.Count == 0)
        {
            _groups.Children.Add(_history.Items.Count == 0
                ? EmptyState.Create(Glyphs.History, "还没有截图", "截图、长截图、钉过的图和录制都会记在这里，留 30 天")
                : EmptyState.Create(Glyphs.Search, "没有符合的", "换个关键词，或者切回「全部」"));
            Select(null);
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
                Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
                Margin = new Thickness(0, 12, 0, 4),
            });
            var grid = new GridView { SelectionMode = ListViewSelectionMode.Single };
            foreach (var item in group)
            {
                grid.Items.Add(Card(item));
            }

            grid.SelectionChanged += OnGridSelectionChanged;
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

        var keep = _selected is { } selected ? items.FirstOrDefault(item => item.Id == selected.Id) : null;
        SelectInGrids(keep ?? items[0]);
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
                Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
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

        AutomationProperties.SetName(
            card, $"{ShotHistoryRules.Title(item.Kind)}，{LocalTime(item.CreatedAt):M 月 d 日 HH:mm}");
        card.DoubleTapped += (_, _) => Open(item);
        card.ContextFlyout = Menu(item);
        return card;
    }

    private void OnGridSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (_syncingSelection || sender is not GridView grid || grid.SelectedItem is not FrameworkElement { Tag: ShotItem item })
        {
            return;
        }

        // 分组是几个 GridView：选了这一组的，别的组清掉。
        _syncingSelection = true;
        foreach (var other in _grids)
        {
            if (other != grid)
            {
                other.SelectedItem = null;
            }
        }

        _syncingSelection = false;
        Select(item);
    }

    private void SelectInGrids(ShotItem item)
    {
        _syncingSelection = true;
        foreach (var grid in _grids)
        {
            grid.SelectedItem = grid.Items.FirstOrDefault(element => element is FrameworkElement { Tag: ShotItem candidate } &&
                                                                     candidate.Id == item.Id);
        }

        _syncingSelection = false;
        Select(item);
    }

    /// <summary>右边：大预览、两行信息、这一条能做的操作。</summary>
    private void Select(ShotItem? item)
    {
        _selected = item;
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

        foreach (var (glyph, title, action, enabled, danger) in Actions(item))
        {
            var button = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                IsEnabled = enabled,
                Content = ActionContent(glyph, title, danger),
            };
            AutomationProperties.SetName(button, title);
            button.Click += (_, _) => action();
            _actions.Children.Add(button);
        }
    }

    private MenuFlyout Menu(ShotItem item)
    {
        var menu = new MenuFlyout();
        foreach (var (glyph, title, action, enabled, danger) in Actions(item))
        {
            var entry = new MenuFlyoutItem
            {
                Text = title,
                Icon = new FontIcon { Glyph = glyph },
                IsEnabled = enabled,
            };
            if (danger)
            {
                entry.Foreground = Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28));
            }

            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }

        return menu;
    }

    /// <summary>一条能做的操作（右边那一列和右键菜单是同一份）。</summary>
    private List<(string Glyph, string Title, Action Run, bool Enabled, bool Danger)> Actions(ShotItem item)
    {
        if (ShotHistoryRules.IsRecording(item.Kind))
        {
            return new()
            {
                (Glyphs.OpenInNewWindow, "打开", () => Open(item), true, false),
                (Glyphs.Copy, "拷贝", () => CopyFile(item), true, false),
                (Glyphs.Folder, "在资源管理器中显示", () => Reveal(item), true, false),
                (Glyphs.Delete, "从历史里删掉…", () => _ = ForgetAsync(item), true, true),
            };
        }

        return new()
        {
            (Glyphs.Edit, "改标注", () => Open(item), true, false),
            (Glyphs.Copy, "拷贝", () => _ = CopyAsync(item), true, false),
            (Glyphs.Save, "存储", () => _ = SaveAsync(item, saveAs: false), true, false),
            (Glyphs.SaveAs, "另存为…", () => _ = SaveAsync(item, saveAs: true), true, false),
            (Glyphs.Pin, "钉到屏幕", () => Pin(item), true, false),
            (Glyphs.Ocr, "识字并拷贝", () => _ = RecognizeAsync(item), true, false),
            (Glyphs.Folder, "在资源管理器中显示", () => Reveal(item), true, false),
            (Glyphs.Delete, "删除…", () => _ = ForgetAsync(item), true, true),
        };
    }

    private static StackPanel ActionContent(string glyph, string title, bool danger)
    {
        var foreground = danger ? Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28)) : null;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var icon = new FontIcon { Glyph = glyph, FontSize = 14 };
        var text = new TextBlock { Text = title, FontSize = Theme.FontSize("Kitty.FontSize.Body") };
        if (foreground is not null)
        {
            icon.Foreground = foreground;
            text.Foreground = foreground;
        }

        row.Children.Add(icon);
        row.Children.Add(text);
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

    private static string KindGlyph(ShotKind kind) => kind switch
    {
        ShotKind.Video => Glyphs.Record,
        ShotKind.Audio => Glyphs.Microphone,
        ShotKind.Gif => Glyphs.Image,
        _ => Glyphs.Screenshot,
    };

    private static DateTime LocalTime(long unixMs) => DateTimeOffset.FromUnixTimeMilliseconds(unixMs).LocalDateTime;
}
