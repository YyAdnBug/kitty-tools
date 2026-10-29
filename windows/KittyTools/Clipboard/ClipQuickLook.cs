// Ctrl+Y 放大预览（照 mac QuickLookView / PreviewView enlarged、mac-whisker-clipboard「⌘Y 放大卡」，PLAN-v9-clipboard D3）：
// 单独一扇置顶、不激活的窗口（WS_EX_NOACTIVATE + SW_SHOWNOACTIVATE），归剪贴板面板所有（点面板也压不到它），键盘一直归剪贴板面板：↑↓ 照样换条目、它跟着换；
// Ctrl+Y / Esc 收起。以剪贴板面板为中心、夹在可见区、最大屏幕 90%；出现只淡入 + 落 8（Windows 版不做从小放大）。
// 内容：来源程序彩色页眉 40（图标平均色，白字不够 4.5:1 时压暗或改黑字）+ 按类型的大预览（字号 ×1.2、文字能选中）+ 页脚胶囊。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.UI;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

/// <summary>页脚胶囊要做的事（面板实现）。</summary>
internal sealed record QuickLookActions(Action Paste, Action<ClipEntry> Copy, Action<ClipEntry>? Third, string? ThirdTitle, string? ThirdGlyph, Action Actions);

internal sealed partial class ClipQuickLook : Window
{
    /// <summary>卡里只有一条左右边线 = 12（mac PreviewView.edge）。</summary>
    private const double Edge = 12;

    private readonly Grid _root;
    private readonly HWND _hwnd;
    private TextBlock? _selectable;
    private bool _shown;
    private HWND _owner;

    public ClipQuickLook()
    {
        Title = Paths.ProductName + " 放大预览";
        _root = new Grid { RequestedTheme = Theme.ElementTheme };
        Content = _root;
        SystemBackdrop = new AcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            Hide();
        };
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _hwnd = (HWND)handle;
        var style = GetWindowLong(handle, -20);
        SetWindowLong(handle, -20, style | 0x08000000); // WS_EX_NOACTIVATE：点它不抢剪贴板面板的键盘
    }

    public bool IsOpen => _shown;

    /// <summary>卡里正文被选中的那段（Ctrl+C 只拷选中的纯文本，mac 体检 B11）；没选中时 null。</summary>
    public string? SelectedText => _selectable is { SelectedText.Length: > 0 } block ? block.SelectedText : null;

    /// <summary>打开或换成另一条：按内容算大小，以剪贴板面板为中心摆好。</summary>
    public void Show(ClipEntry entry, string query, string displayText, QuickLookActions actions, HWND panel)
    {
        _root.RequestedTheme = Theme.ElementTheme;
        var display = Displays.AtWindow(panel);
        var scale = display.Scale <= 0 ? 1 : display.Scale;
        var work = display.Work;
        var limitWidth = (work.Right - work.Left) / scale * 0.9;
        var limitHeight = (work.Bottom - work.Top) / scale * 0.9;
        var (width, height) = ClipPreviewRules.QuickLookSize(
            entry.Kind, entry.Form, entry.Text, entry.Width, entry.Height, !string.IsNullOrWhiteSpace(entry.OcrText),
            entry.Files.Length, limitWidth, limitHeight, scale);

        _root.Children.Clear();
        _root.Children.Add(Build(entry, query, displayText, actions, scale, width));

        // 以剪贴板面板为中心，夹在可见区里。
        PInvoke.GetWindowRect(panel, out var anchor);
        var widthPx = (int)Math.Round(width * scale);
        var heightPx = (int)Math.Round(height * scale);
        var centerX = anchor.X + anchor.Width / 2;
        var centerY = anchor.Y + anchor.Height / 2;
        var left = Math.Clamp(centerX - widthPx / 2, work.Left, Math.Max(work.Left, work.Right - widthPx));
        var top = Math.Clamp(centerY - heightPx / 2, work.Top, Math.Max(work.Top, work.Bottom - heightPx));
        AppWindow.MoveAndResize(new RectInt32(left, top, widthPx, heightPx));
        if (_owner != panel)
        {
            // 归剪贴板面板所有（owner）：两扇都是置顶窗口，以前谁被点谁在上，点一下后面的面板，放大卡就一直压在它下面
            // （2026-10-29 用户反馈）；有了 owner，系统保证它总在面板上面。面板那扇窗口不销毁（OverlayWindow），不会连带把它销毁。
            _owner = panel;
            unsafe
            {
                SetWindowLongPtr((IntPtr)_hwnd.Value, -8 /* GWLP_HWNDPARENT */, (IntPtr)panel.Value);
            }
        }

        if (!_shown)
        {
            PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)4); // SW_SHOWNOACTIVATE
            _shown = true;
            Motion.Entrance(_root, MotionCurve.Glide, rise: -8);
        }

        Log.Info($"clipboard.quicklook kind={entry.Kind}");
    }

    public void Hide()
    {
        if (!_shown)
        {
            return;
        }

        _shown = false;
        _selectable = null;
        AppWindow.Hide();
        _root.Children.Clear();
    }

    private FrameworkElement Build(ClipEntry entry, string query, string displayText, QuickLookActions actions, double scale, double width)
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(Header(entry, scale));

        var body = Body(entry, query, displayText, scale, width);
        var bodyHost = new Border { Padding = new Thickness(Edge, Edge, Edge, 0), Child = body };
        Grid.SetRow(bodyHost, 1);
        grid.Children.Add(bodyHost);

        var footer = Footer(entry, actions);
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);
        AutomationProperties.SetName(grid, $"放大预览：{ClipRowView.TitleText(entry)}");
        return grid;
    }

    /// <summary>来源程序彩色页眉 40：图标 + 程序名 + 「类型 · 时间」；没有来源时中性。</summary>
    private static Grid Header(ClipEntry entry, double scale)
    {
        var header = new Grid
        {
            Padding = new Thickness(Edge, 0, Edge, 0),
            ColumnSpacing = 8,
            Background = Theme.Brush("Kitty.Fill.Control", Color.FromArgb(20, 128, 128, 128)),
        };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new Border { Width = 20, Height = 20, VerticalAlignment = VerticalAlignment.Center };
        var title = new TextBlock
        {
            Text = string.IsNullOrEmpty(entry.SourceName) ? ClipLensView.TypeTitle(entry, entry.Form) : entry.SourceName,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var meta = new TextBlock
        {
            Text = ClipLensView.MetaText(entry, entry.Form),
            FontSize = 12,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (!string.IsNullOrEmpty(entry.SourceExe) && Path.IsPathRooted(entry.SourceExe))
        {
            void ShowIcon(ImageSource image) => icon.Background = new ImageBrush { ImageSource = image, Stretch = Stretch.Uniform };
            if (ClipIcons.AppIcon(entry.SourceExe, scale, ShowIcon) is { } cached)
            {
                ShowIcon(cached);
            }

            _ = TintAsync(header, title, meta, entry.SourceExe, scale);
        }
        else
        {
            var (family, glyph) = ClipRowView.KindOf(entry, entry.Form);
            icon.Child = KindTile.Create(family, glyph, 20);
        }

        header.Children.Add(icon);
        Grid.SetColumn(title, 1);
        header.Children.Add(title);
        Grid.SetColumn(meta, 2);
        header.Children.Add(meta);
        return header;
    }

    /// <summary>页眉取来源程序图标的平均色（12 × 12 采样，按不透明度加权），按 Core 的 HeaderStyle 定底色和字色；只在这里，主界面保持中性。</summary>
    private static async Task TintAsync(Grid header, TextBlock title, TextBlock meta, string exe, double scale)
    {
        try
        {
            var png = await Task.Run(() => ShellIcons.LoadPng(exe, scale, 24));
            if (png is null)
            {
                return;
            }

            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(png);
                await writer.StoreAsync();
            }

            var decoder = await BitmapDecoder.CreateAsync(stream);
            var data = await decoder.GetPixelDataAsync(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight,
                new BitmapTransform { ScaledWidth = 12, ScaledHeight = 12 },
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            var pixels = data.DetachPixelData();
            double r = 0, g = 0, b = 0, weight = 0;
            for (var index = 0; index + 3 < pixels.Length; index += 4)
            {
                var alpha = pixels[index + 3] / 255.0;
                b += pixels[index] * alpha;
                g += pixels[index + 1] * alpha;
                r += pixels[index + 2] * alpha;
                weight += alpha;
            }

            if (weight < 1)
            {
                return;
            }

            var style = ClipPreviewRules.HeaderStyle((byte)(r / weight), (byte)(g / weight), (byte)(b / weight));
            var top = Color.FromArgb(255, style.R, style.G, style.B);
            var bottom = Color.FromArgb(255, (byte)(style.R * 0.92), (byte)(style.G * 0.92), (byte)(style.B * 0.92));
            header.Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0),
                EndPoint = new Windows.Foundation.Point(0, 1),
                GradientStops = { new GradientStop { Color = top, Offset = 0 }, new GradientStop { Color = bottom, Offset = 1 } },
            };
            var ink = new SolidColorBrush(style.DarkText ? Color.FromArgb(217, 0, 0, 0) : Colors.White);
            title.Foreground = ink;
            meta.Foreground = ink;
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.quicklook-tint-failed {ex.GetType().Name}");
        }
    }

    private FrameworkElement Body(ClipEntry entry, string query, string displayText, double scale, double width)
    {
        _selectable = null;
        switch (entry.Kind)
        {
            case ClipKind.Image:
                return ImageBody(entry, scale);
            case ClipKind.Files:
                return FilesBody(entry, scale);
        }

        var text = entry.Text ?? string.Empty;
        if (entry.Form == ContentForm.Color && ContentForms.Color(text) is { } color)
        {
            var swatch = ClipLensView.ColorSwatch(color, value =>
            {
                if (ClipboardWriter.WriteText(value))
                {
                    ClipboardService.Instance?.MarkOwnWrite();
                    NoticeHost.Show("已复制", value, NoticeTone.Normal);
                }
            });
            return new ScrollViewer { Content = swatch, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        }

        if (entry.Form == ContentForm.Link && LinkPreviewRules.SingleUrl(text) is { } uri)
        {
            var link = new ClipLinkLens(uri) { Height = 120 };
            if (LinkPreviewService.Enabled && LinkPreviewService.Peek(uri) is { } cached)
            {
                link.Update(cached, animate: false);
            }

            var stack = new StackPanel { Spacing = 12 };
            stack.Children.Add(link);
            stack.Children.Add(Selectable(uri.ToString(), query, 13, mono: true));
            return stack;
        }

        if (entry.Form is ContentForm.Code or ContentForm.Json)
        {
            var code = ClipLensView.Code(displayText, entry.Form == ContentForm.Json, query, height: 0, maxLines: 2000, fontSize: 14, selectable: true);
            _selectable = FindCode(code);
            return new ScrollViewer { Content = code, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        }

        var block = Selectable(text.Length > 200_000 ? text[..200_000] : text, query, 17, mono: false);
        return new ScrollViewer { Content = block, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static TextBlock? FindCode(FrameworkElement code)
        => code is Grid grid ? grid.Children.OfType<TextBlock>().LastOrDefault() : null;

    private TextBlock Selectable(string text, string query, double size, bool mono)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            LineHeight = Math.Round(size * 1.45),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            SelectionHighlightColor = new SolidColorBrush(Theme.AccentColor),
        };
        if (mono)
        {
            block.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        }

        if (query.Length > 0)
        {
            var highlighter = new Microsoft.UI.Xaml.Documents.TextHighlighter { Background = new SolidColorBrush(Color.FromArgb(89, 255, 204, 0)) };
            foreach (var (start, length) in Search.HitRanges(text, query))
            {
                highlighter.Ranges.Add(new Microsoft.UI.Xaml.Documents.TextRange { StartIndex = start, Length = length });
            }

            block.TextHighlighters.Add(highlighter);
        }

        _selectable ??= block;
        return block;
    }

    /// <summary>图片：在棋盘格里居中、按窗口能给的最大尺寸等比显示，右上角「宽×高」胶囊；下面是识别到的文字（能选中）。</summary>
    private FrameworkElement ImageBody(ClipEntry entry, double scale)
    {
        var grid = new Grid { RowSpacing = 10 };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var area = new Grid { CornerRadius = Theme.Corner("Kitty.Corner.Card") };
        area.Children.Add(ClipRowView.Checker(4000, 3000, 8));
        var image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(8) };
        area.Children.Add(image);
        area.Children.Add(new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 8, 8, 0),
            Height = 18,
            Padding = new Thickness(6, 0, 6, 0),
            CornerRadius = new CornerRadius(9),
            Background = new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)),
            Child = new TextBlock
            {
                Text = $"{entry.Width}×{entry.Height}",
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                Foreground = new SolidColorBrush(Colors.White),
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        grid.Children.Add(area);
        var path = Paths.ImagesFile(entry.Id);
        if (File.Exists(path))
        {
            _ = LoadImageAsync(image, path, Math.Min(entry.Width, 2400));
        }

        if (!string.IsNullOrWhiteSpace(entry.OcrText))
        {
            var ocr = new StackPanel { Spacing = 4 };
            ocr.Children.Add(new TextBlock { Text = "识别到的文字", FontSize = 12, Foreground = Theme.SecondaryText() });
            ocr.Children.Add(new ScrollViewer { Content = Selectable(entry.OcrText!, string.Empty, 14, mono: false), MaxHeight = 120 });
            Grid.SetRow(ocr, 1);
            grid.Children.Add(ocr);
        }

        return grid;
    }

    private static async Task LoadImageAsync(Image image, string path, int width)
    {
        try
        {
            using var stream = await FileRandomAccessStream.OpenAsync(path, FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = Math.Max(64, width) };
            await bitmap.SetSourceAsync(stream);
            image.Source = bitmap;
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.quicklook-image-failed {ex.GetType().Name}");
        }
    }

    /// <summary>文件：一个文件是 256 的系统缩略图 + 名字 + 路径（能选中）；多个是缩略图网格。</summary>
    private FrameworkElement FilesBody(ClipEntry entry, double scale)
    {
        var files = entry.Files;
        if (files.Length == 1)
        {
            var stack = new StackPanel { Spacing = 10 };
            var thumb = new Grid { Width = 256, Height = 256, HorizontalAlignment = HorizontalAlignment.Left };
            thumb.Children.Add(new FontIcon { Glyph = Directory.Exists(files[0]) ? Glyphs.Folder : Glyphs.File, FontSize = 96, Foreground = Theme.SecondaryText() });
            stack.Children.Add(thumb);
            _ = LoadThumbnailAsync(thumb, files[0], (uint)Math.Round(256 * scale));
            stack.Children.Add(new TextBlock { Text = Path.GetFileName(files[0]), FontSize = 16, FontWeight = FontWeights.SemiBold });
            stack.Children.Add(Selectable(files[0], string.Empty, 13, mono: true));
            return new ScrollViewer { Content = stack };
        }

        var wrap = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 120, ItemHeight = 120 };
        foreach (var file in files.Take(200))
        {
            var cell = new StackPanel { Spacing = 4, Width = 112 };
            var thumb = new Grid { Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Center };
            thumb.Children.Add(new FontIcon { Glyph = Directory.Exists(file) ? Glyphs.Folder : Glyphs.File, FontSize = 40, Foreground = Theme.SecondaryText() });
            cell.Children.Add(thumb);
            cell.Children.Add(new TextBlock
            {
                Text = Path.GetFileName(file),
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
                HorizontalAlignment = HorizontalAlignment.Center,
                MaxLines = 2,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
            });
            ToolTipService.SetToolTip(cell, file);
            _ = LoadThumbnailAsync(thumb, file, (uint)Math.Round(72 * scale));
            wrap.Children.Add(cell);
        }

        return new ScrollViewer { Content = wrap };
    }

    private static async Task LoadThumbnailAsync(Grid host, string path, uint size)
    {
        try
        {
            if (!File.Exists(path) && !Directory.Exists(path))
            {
                return;
            }

            Windows.Storage.FileProperties.StorageItemThumbnail thumbnail = Directory.Exists(path)
                ? await (await StorageFolder.GetFolderFromPathAsync(path)).GetThumbnailAsync(
                    Windows.Storage.FileProperties.ThumbnailMode.SingleItem, size, Windows.Storage.FileProperties.ThumbnailOptions.ResizeThumbnail)
                : await (await StorageFile.GetFileFromPathAsync(path)).GetThumbnailAsync(
                    Windows.Storage.FileProperties.ThumbnailMode.SingleItem, size, Windows.Storage.FileProperties.ThumbnailOptions.ResizeThumbnail);
            using (thumbnail)
            {
                if (thumbnail is null || thumbnail.Size == 0)
                {
                    return;
                }

                var bitmap = new BitmapImage();
                await bitmap.SetSourceAsync(thumbnail);
                host.Children.Clear();
                host.Children.Add(new Image { Source = bitmap, Stretch = Stretch.Uniform });
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.quicklook-thumbnail-failed {ex.GetType().Name}");
        }
    }

    /// <summary>页脚无边框胶囊（高 26、图标到字 6、最多 4 个）：粘贴、复制（这一条，不管勾选）、按类型的第 3 个、操作 Ctrl+K。</summary>
    private static StackPanel Footer(ClipEntry entry, QuickLookActions actions)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(Edge - 6, 8, Edge, 10) };
        row.Children.Add(Pill("粘贴", Glyphs.Paste, null, actions.Paste));
        row.Children.Add(Pill("复制", Glyphs.Copy, null, () => actions.Copy(entry)));
        if (actions.Third is { } third && actions.ThirdTitle is { } title)
        {
            row.Children.Add(Pill(title, actions.ThirdGlyph ?? Glyphs.More, null, () => third(entry)));
        }

        row.Children.Add(Pill("操作", Glyphs.More, "Ctrl+K", actions.Actions));
        return row;
    }

    private static Button Pill(string text, string glyph, string? key, Action action)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = text, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        if (key is not null)
        {
            var cap = KeyCap.Create(key);
            cap.VerticalAlignment = VerticalAlignment.Center;
            content.Children.Add(cap);
        }

        var button = new Button
        {
            Content = content,
            Height = 26,
            Padding = new Thickness(10, 0, key is null ? 10 : 6, 0),
            CornerRadius = new CornerRadius(13),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            IsTabStop = false,
        };
        button.Click += (_, _) => action();
        AutomationProperties.SetName(button, text);
        return button;
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static partial IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
}
