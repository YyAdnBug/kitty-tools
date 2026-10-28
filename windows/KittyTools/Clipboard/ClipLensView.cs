// 剪贴板透镜的正文区和元信息行（照 mac LensView.swift、mac-whisker-clipboard「透镜」）。正文区按类型查表定高（Core 的 ClipLens），
// 放进固定高度里裁掉；左边和行标题对齐（x = 44）、右边留 10。正文不能选中（焦点一直在搜索框，要选字按 Ctrl+Y）。
//   文本：14 号行高 20，短文本最多两行；长文本有搜索词时从命中处截取；会超出的底部 12 渐隐（字的颜色渐变到透明）。
//   代码 / JSON：等宽 12、语法着色、tertiary 行号；JSON 默认美化（元信息行右边「原文 / 美化」）。
//   颜色：左 120×72 色块（HEX 22 居中、黑白字按亮度），右边两列四枚值胶囊，点一下复制、图标换对勾。
//   链接：左头图 160×90（取的时候扫光；没头图时渐变 + 网站图标），右标题 ≤ 2 行 + 网站 + 网址。
//   图片：高 108、保持比例、左对齐，垫 8 的棋盘格。文件：一排最多 6 个 48 的缩略图 + 文件名，多的写「+N」。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;
using Windows.UI;

namespace KittyTools;

internal static class ClipLensView
{
    /// <summary>正文区左边：行的内边距 10 + 图标块 24 + 间距 10（和行标题对齐）。</summary>
    public const double Left = ClipLens.RowPadding + 24 + ClipLens.RowSpacing;

    private const double FadeHeight = 12;

    /// <summary>正文的字色（具体颜色，渐隐要从它渐变到透明）。</summary>
    public static Color Ink => Theme.EffectiveTheme == ElementTheme.Dark
        ? Color.FromArgb(255, 255, 255, 255)
        : Color.FromArgb(228, 0, 0, 0);

    private static Color TertiaryInk => Theme.EffectiveTheme == ElementTheme.Dark
        ? Color.FromArgb(114, 255, 255, 255)
        : Color.FromArgb(114, 0, 0, 0);

    /// <summary>从 height − 12 往下渐变到透明的字色（Absolute：坐标按这段文字自己的左上角算）。</summary>
    private static Brush Fading(Color color, double height) => new LinearGradientBrush
    {
        MappingMode = BrushMappingMode.Absolute,
        StartPoint = new Windows.Foundation.Point(0, Math.Max(0, height - FadeHeight)),
        EndPoint = new Windows.Foundation.Point(0, height),
        GradientStops =
        {
            new GradientStop { Color = color, Offset = 0 },
            new GradientStop { Color = Color.FromArgb(0, color.R, color.G, color.B), Offset = 1 },
        },
    };

    /// <summary>文本：短的最多两行，长的截取（有搜索词时从命中处）、底部渐隐。</summary>
    public static FrameworkElement Text(string text, string query, double height)
    {
        var shortText = ClipLens.IsShort(text);
        string shown;
        if (shortText)
        {
            shown = text.Trim();
        }
        else
        {
            var source = text.Length > 20_000 ? text[..20_000] : text;
            shown = Search.Excerpt(source, query, before: 40, after: 600) ?? (source.Length > 640 ? source[..640] : source);
        }

        var block = new TextBlock
        {
            Text = shown,
            FontSize = Theme.FontSize("Kitty.FontSize.RowTitle"),
            LineHeight = 20,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = shortText ? 2 : 0,
            TextTrimming = shortText ? TextTrimming.CharacterEllipsis : TextTrimming.None,
            Foreground = shortText ? new SolidColorBrush(Ink) : Fading(Ink, height),
        };
        Highlight(block, shown, query);
        return block;
    }

    /// <summary>代码 / JSON：从第一个命中那一行的上一行开始，最多 10 行、每行前 300 字。</summary>
    public static FrameworkElement Code(string text, bool json, string query, double height)
    {
        var source = text.Length > 20_000 ? text[..20_000] : text;
        var lines = source.Replace("\r\n", "\n").Split('\n');
        var first = 0;
        if (Search.HitRanges(source, query) is { Count: > 0 } hits)
        {
            first = Math.Max(0, source[..hits[0].Start].Count(ch => ch == '\n') - 1);
        }

        var shown = lines.Skip(first).Take(10).Select(line => line.Length > 300 ? line[..300] : line).ToList();
        var joined = string.Join('\n', shown);
        var digits = (first + shown.Count).ToString().Length;

        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(digits * 7 + 2) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var numbers = new TextBlock
        {
            Text = string.Join('\n', Enumerable.Range(first + 1, shown.Count)),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 11,
            LineHeight = 16,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            TextAlignment = TextAlignment.Right,
            Foreground = Fading(TertiaryInk, height),
        };
        grid.Children.Add(numbers);

        var code = new TextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            LineHeight = 16,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        foreach (var (start, length, kind) in ClipPreviewRules.Highlight(joined, json))
        {
            var run = new Run
            {
                Text = joined.Substring(start, length),
                Foreground = Fading(SyntaxColor(kind), height),
            };
            if (kind == SyntaxKind.Keyword)
            {
                run.FontWeight = FontWeights.SemiBold;
            }
            else if (kind == SyntaxKind.Comment)
            {
                run.FontStyle = Windows.UI.Text.FontStyle.Italic;
            }

            code.Inlines.Add(run);
        }

        Highlight(code, joined, query);
        Grid.SetColumn(code, 1);
        grid.Children.Add(code);
        return grid;
    }

    /// <summary>着色的颜色（照 mac：数字紫、关键字粉、字符串红、JSON 的键蓝、注释灰斜体），深浅色各一套系统色。</summary>
    private static Color SyntaxColor(SyntaxKind kind) => kind switch
    {
        SyntaxKind.Number => Theme.Value(0xAF52DE, 0xBF5AF2),
        SyntaxKind.Keyword => Theme.Value(0xFF2D55, 0xFF375F),
        SyntaxKind.String => Theme.Value(0xFF3B30, 0xFF453A),
        SyntaxKind.Key => Theme.Value(0x007AFF, 0x0A84FF),
        SyntaxKind.Comment => TertiaryInk,
        _ => Ink,
    };

    /// <summary>搜索词黄 0.35 底（同行标题）。</summary>
    private static void Highlight(TextBlock block, string text, string query)
    {
        if (query.Length == 0)
        {
            return;
        }

        var highlighter = new TextHighlighter { Background = new SolidColorBrush(Color.FromArgb(89, 255, 204, 0)) };
        foreach (var (start, length) in Search.HitRanges(text, query))
        {
            highlighter.Ranges.Add(new TextRange { StartIndex = start, Length = length });
        }

        if (highlighter.Ranges.Count > 0)
        {
            block.TextHighlighters.Add(highlighter);
        }
    }

    /// <summary>颜色：色块 + 四枚值胶囊；copy 只写剪贴板、不记历史（面板开着时透镜里的色值块不记，mac）。</summary>
    public static FrameworkElement ColorSwatch(Rgba color, Action<string> copy)
    {
        var values = ClipPreviewRules.ColorValues(color);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var corner = Theme.Corner("Kitty.Corner.Control");
        var swatch = new Grid { Width = 120, Height = 72, CornerRadius = corner };
        if (color.Alpha < 1)
        {
            swatch.Children.Add(ClipRowView.Checker(120, 72, 8));
        }

        var light = ClipPreviewRules.IsLight(color);
        swatch.Children.Add(new Border
        {
            CornerRadius = corner,
            Background = new SolidColorBrush(ToColor(color)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(51, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Child = new Viewbox
            {
                StretchDirection = StretchDirection.DownOnly,
                Margin = new Thickness(6, 0, 6, 0),
                Child = new TextBlock
                {
                    Text = values[0],
                    FontSize = 22,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(light ? Windows.UI.Color.FromArgb(204, 0, 0, 0) : Colors.White),
                },
            },
        });
        row.Children.Add(swatch);

        var chips = new Grid { ColumnSpacing = 8, RowSpacing = 8, MaxWidth = 440, Width = 440 };
        chips.ColumnDefinitions.Add(new ColumnDefinition());
        chips.ColumnDefinitions.Add(new ColumnDefinition());
        chips.RowDefinitions.Add(new RowDefinition());
        chips.RowDefinitions.Add(new RowDefinition());
        for (var index = 0; index < 4; index++)
        {
            var value = values[index];
            var icon = new FontIcon { Glyph = Glyphs.Copy, FontSize = 10, Foreground = Theme.SecondaryText() };
            var content = new Grid { ColumnSpacing = 6 };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.Children.Add(new TextBlock
            {
                Text = value,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                FontSize = 11,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            });
            Grid.SetColumn(icon, 1);
            content.Children.Add(icon);
            var chip = new Button
            {
                Content = content,
                Height = 32,
                Padding = new Thickness(10, 0, 10, 0),
                CornerRadius = new CornerRadius(16),
                BorderThickness = new Thickness(0),
                Background = Theme.Brush("Kitty.Fill.Control", Windows.UI.Color.FromArgb(20, 128, 128, 128)),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Center,
                IsTabStop = false,
            };
            ToolTipService.SetToolTip(chip, $"复制 {value}");
            AutomationProperties.SetName(chip, $"复制 {value}");
            chip.Click += (_, _) =>
            {
                copy(value);
                icon.Glyph = Glyphs.Check;
                icon.Foreground = new SolidColorBrush(Theme.Value(0x34C759, 0x30D158));
                var timer = chip.DispatcherQueue.CreateTimer();
                timer.Interval = TimeSpan.FromSeconds(1.5);
                timer.IsRepeating = false;
                timer.Tick += (_, _) =>
                {
                    icon.Glyph = Glyphs.Copy;
                    icon.Foreground = Theme.SecondaryText();
                };
                timer.Start();
            };
            Grid.SetColumn(chip, index % 2);
            Grid.SetRow(chip, index / 2);
            chips.Children.Add(chip);
        }

        row.Children.Add(chips);
        return row;
    }

    public static Color ToColor(Rgba color) => Windows.UI.Color.FromArgb(
        (byte)Math.Round(color.Alpha * 255), (byte)Math.Round(color.Red * 255),
        (byte)Math.Round(color.Green * 255), (byte)Math.Round(color.Blue * 255));

    /// <summary>图片：高 108、宽按比例夹在 60–360，棋盘格上居中显示整张。</summary>
    public static FrameworkElement Picture(ClipEntry entry, double scale)
    {
        var ratio = entry.Width > 0 && entry.Height > 0 ? entry.Width / (double)entry.Height : 1.5;
        var width = Math.Min(Math.Max(108 * ratio, 60), 360);
        var corner = Theme.Corner("Kitty.Corner.Control");
        var frame = new Grid
        {
            Width = width,
            Height = 108,
            CornerRadius = corner,
            HorizontalAlignment = HorizontalAlignment.Left,
            BorderBrush = Theme.Brush("Kitty.Hairline", Windows.UI.Color.FromArgb(20, 0, 0, 0)),
            BorderThickness = new Thickness(1),
        };
        frame.Children.Add(ClipRowView.Checker(width, 108, 8));
        var path = Paths.ImagesFile(entry.Id);
        if (!File.Exists(path))
        {
            frame.Children.Add(new TextBlock
            {
                Text = "图片文件丢了",
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                Foreground = Theme.SecondaryText(),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
            return frame;
        }

        var image = new Microsoft.UI.Xaml.Controls.Image { Stretch = Stretch.Uniform };
        frame.Children.Add(image);
        _ = LoadAsync(image, path, (int)Math.Round(108 * Math.Max(1, scale)));
        return frame;
    }

    private static async Task LoadAsync(Microsoft.UI.Xaml.Controls.Image image, string path, int height)
    {
        try
        {
            using var stream = await Windows.Storage.Streams.FileRandomAccessStream.OpenAsync(path, FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelHeight = height, DecodePixelType = DecodePixelType.Physical };
            await bitmap.SetSourceAsync(stream);
            image.Source = bitmap;
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.lens-image-failed {ex.GetType().Name}");
        }
    }

    /// <summary>文件：一排最多 6 个，每格 72 宽：48 的系统缩略图 + 11 号文件名，都靠左；多的写「+N」。</summary>
    public static FrameworkElement Files(IReadOnlyList<string> paths, double scale)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var path in paths.Take(6))
        {
            var exists = File.Exists(path) || Directory.Exists(path);
            var cell = new StackPanel { Width = 72, Spacing = 4 };
            var thumb = new Grid { Width = 48, Height = 48, HorizontalAlignment = HorizontalAlignment.Left };
            thumb.Children.Add(new FontIcon
            {
                Glyph = Directory.Exists(path) ? Glyphs.Folder : Glyphs.File,
                FontSize = 32,
                Foreground = Theme.SecondaryText(),
                Opacity = exists ? 1 : 0.4,
            });
            cell.Children.Add(thumb);
            cell.Children.Add(new TextBlock
            {
                Text = Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : path,
                FontSize = 11,
                Foreground = new SolidColorBrush(Ink),
                Opacity = exists ? 1 : 0.5,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            });
            ToolTipService.SetToolTip(cell, exists ? path : path + "（找不到了）");
            row.Children.Add(cell);
            if (exists)
            {
                _ = LoadThumbnailAsync(thumb, path, (uint)Math.Round(48 * Math.Max(1, scale)));
            }
        }

        if (paths.Count > 6)
        {
            row.Children.Add(new TextBlock
            {
                Text = $"+{paths.Count - 6}",
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = Theme.SecondaryText(),
                Height = 48,
                VerticalAlignment = VerticalAlignment.Top,
                Padding = new Thickness(0, 15, 0, 0),
            });
        }

        return row;
    }

    private static async Task LoadThumbnailAsync(Grid host, string path, uint size)
    {
        try
        {
            IStorageItemProperties item = Directory.Exists(path)
                ? await StorageFolder.GetFolderFromPathAsync(path)
                : await StorageFile.GetFileFromPathAsync(path);
            using var thumbnail = await item.GetThumbnailAsync(ThumbnailMode.SingleItem, size, ThumbnailOptions.ResizeThumbnail);
            if (thumbnail is null || thumbnail.Size == 0)
            {
                return;
            }

            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(thumbnail);
            host.Children.Clear();
            host.Children.Add(new Microsoft.UI.Xaml.Controls.Image
            {
                Source = bitmap,
                Stretch = Stretch.Uniform,
                HorizontalAlignment = HorizontalAlignment.Left,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.file-thumbnail-failed {ex.GetType().Name}");
        }
    }

    /// <summary>
    /// 元信息行 22：「类型 · 字数 / 尺寸 · 时间 · [16 的程序图标] 程序名」，JSON 右边「原文 / 美化」（默认美化，按钮写「原文」）。
    /// </summary>
    public static FrameworkElement Meta(ClipEntry entry, ContentForm? form, double scale, bool? prettyJson, Action? togglePretty)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var hasSource = !string.IsNullOrEmpty(entry.SourceName);
        var fontSize = Theme.FontSize("Kitty.FontSize.Meta");
        grid.Children.Add(new TextBlock
        {
            Text = hasSource ? MetaText(entry, form) + " · " : MetaText(entry, form),
            FontSize = fontSize,
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (hasSource)
        {
            if (!string.IsNullOrEmpty(entry.SourceExe) && Path.IsPathRooted(entry.SourceExe))
            {
                var icon = new Border { Width = 16, Height = 16, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
                void Show(ImageSource image) => icon.Background = new ImageBrush { ImageSource = image, Stretch = Stretch.Uniform };
                if (ClipIcons.AppIcon(entry.SourceExe, scale, Show) is { } cached)
                {
                    Show(cached);
                }

                Grid.SetColumn(icon, 1);
                grid.Children.Add(icon);
            }

            var name = new TextBlock
            {
                Text = entry.SourceName,
                FontSize = fontSize,
                Foreground = Theme.SecondaryText(),
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(name, 2);
            grid.Children.Add(name);
        }

        if (prettyJson is { } pretty && togglePretty is not null)
        {
            var button = new HyperlinkButton
            {
                Content = pretty ? "原文" : "美化",
                FontSize = fontSize,
                Padding = new Thickness(0),
                Foreground = new SolidColorBrush(Theme.AccentTextColor),
                IsTabStop = false,
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTipService.SetToolTip(button, pretty ? "显示原文（这次打开面板里一直有效）" : "美化 JSON");
            button.Click += (_, _) => togglePretty();
            Grid.SetColumn(button, 3);
            grid.Children.Add(button);
        }

        return grid;
    }

    /// <summary>「文本 · 70 字 · 14:02」（今天写 14:02，更早写 9月25日 14:02，跨年带年份）。</summary>
    public static string MetaText(ClipEntry entry, ContentForm? form)
    {
        string? detail = entry.Kind switch
        {
            ClipKind.Image => entry.Width > 0 ? $"{entry.Width}×{entry.Height} · {Size(entry.ImageBytes)}" : null,
            ClipKind.Files => $"{entry.Files.Length} 个",
            _ => $"{new System.Globalization.StringInfo(entry.Text ?? string.Empty).LengthInTextElements} 字",
        };
        return string.Join(" · ", new[] { TypeTitle(entry, form), detail, ExactTime(entry.CopiedAt) }
            .Where(part => !string.IsNullOrEmpty(part)));
    }

    public static string TypeTitle(ClipEntry entry, ContentForm? form) => entry.Kind switch
    {
        ClipKind.Image => "图片",
        ClipKind.Files => "文件",
        _ => form is { } kind ? ContentForms.Title(kind) : "文本",
    };

    public static string ExactTime(long copiedAt)
    {
        var copied = DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime();
        var now = DateTimeOffset.Now;
        return copied.Date == now.Date ? copied.ToString("HH:mm")
            : copied.Year == now.Year ? copied.ToString("M月d日 HH:mm")
            : copied.ToString("yyyy年M月d日 HH:mm");
    }

    private static string Size(int bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:F0} KB",
        _ => $"{bytes / 1_048_576.0:F1} MB",
    };
}

/// <summary>
/// 链接透镜：左头图 160×90（取的时候扫光，到了淡入；没头图时网址家族色渐变 + 44 的网站图标），右标题 ≤ 2 行（没取到时是主机名）
/// + 网站图标和「站名 · 主机」+ 等宽 11 的网址。取到预览后由面板调 <see cref="Update"/>。
/// </summary>
internal sealed partial class ClipLinkLens : Grid
{
    private readonly Grid _hero;
    private readonly Border _heroIcon;
    private readonly Border _shimmer;
    private readonly TextBlock _title;
    private readonly Border _siteIcon;
    private readonly TextBlock _site;

    public ClipLinkLens(Uri uri)
    {
        Uri = uri;
        ColumnSpacing = 12;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var corner = Theme.Corner("Kitty.Corner.Control");
        var url = Theme.Family.Url;
        var search = Theme.Family.Search;
        _hero = new Grid
        {
            Width = 160,
            Height = 90,
            CornerRadius = corner,
            BorderBrush = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0),
                EndPoint = new Windows.Foundation.Point(1, 1),
                GradientStops =
                {
                    new GradientStop { Color = Color.FromArgb(115, url.R, url.G, url.B), Offset = 0 },
                    new GradientStop { Color = Color.FromArgb(64, search.R, search.G, search.B), Offset = 1 },
                },
            },
        };
        _heroIcon = KindTile.Create("url", Glyphs.Globe, 44);
        _heroIcon.HorizontalAlignment = HorizontalAlignment.Center;
        _heroIcon.VerticalAlignment = VerticalAlignment.Center;
        _hero.Children.Add(_heroIcon);
        _shimmer = new Border { Background = new SolidColorBrush(Color.FromArgb(36, 255, 255, 255)), Visibility = Visibility.Collapsed };
        _hero.Children.Add(_shimmer);
        Children.Add(_hero);

        var details = new StackPanel { Spacing = 6, Padding = new Thickness(0, 2, 0, 0) };
        _title = new TextBlock
        {
            Text = uri.Host,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = new SolidColorBrush(ClipLensView.Ink),
        };
        details.Children.Add(_title);
        var siteRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        _siteIcon = new Border
        {
            Width = 14,
            Height = 14,
            CornerRadius = new CornerRadius(3),
            Child = new FontIcon { Glyph = Glyphs.Globe, FontSize = 11, Foreground = Theme.SecondaryText() },
            VerticalAlignment = VerticalAlignment.Center,
        };
        siteRow.Children.Add(_siteIcon);
        _site = new TextBlock
        {
            Text = uri.Host,
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        siteRow.Children.Add(_site);
        details.Children.Add(siteRow);
        details.Children.Add(new TextBlock
        {
            Text = uri.ToString(),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 11,
            Foreground = Theme.Brush("Kitty.Text.Tertiary", Color.FromArgb(140, 0, 0, 0)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        SetColumn(details, 1);
        Children.Add(details);
        AutomationProperties.SetName(this, uri.Host);
    }

    public Uri Uri { get; }

    /// <summary>正在取：头图区扫光（一层淡白来回淡入淡出；系统关了动画时是静止的淡白）。</summary>
    public void SetLoading(bool loading)
    {
        _shimmer.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        if (loading && !Motion.Reduced)
        {
            var visual = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(_shimmer);
            var pulse = visual.Compositor.CreateScalarKeyFrameAnimation();
            pulse.InsertKeyFrame(0f, 0.2f);
            pulse.InsertKeyFrame(0.5f, 1f);
            pulse.InsertKeyFrame(1f, 0.2f);
            pulse.Duration = TimeSpan.FromSeconds(1.3);
            pulse.IterationBehavior = Microsoft.UI.Composition.AnimationIterationBehavior.Forever;
            visual.StartAnimation("Opacity", pulse);
        }
    }

    public void Update(LinkPreviewService.CachedPreview cached, bool animate)
    {
        SetLoading(false);
        var preview = cached.Preview;
        if (!string.IsNullOrWhiteSpace(preview.Title))
        {
            _title.Text = preview.Title;
        }

        _site.Text = string.IsNullOrWhiteSpace(preview.Site) || preview.Site == Uri.Host ? Uri.Host : $"{preview.Site} · {Uri.Host}";
        if (cached.IconBytes is { Length: > 0 } iconBytes)
        {
            _ = SetImageAsync(iconBytes, 28, image =>
            {
                _siteIcon.Child = null;
                _siteIcon.Background = new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill };
                _heroIcon.Child = null;
                _heroIcon.Background = new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill };
            });
        }

        if (cached.ImageBytes is { Length: > 0 } heroBytes)
        {
            _ = SetImageAsync(heroBytes, 480, image =>
            {
                var hero = new Microsoft.UI.Xaml.Controls.Image { Source = image, Stretch = Stretch.UniformToFill };
                _hero.Children.Insert(_hero.Children.Count - 1, hero);
                if (animate)
                {
                    Motion.Appear(hero);
                }
            });
        }
    }

    private static async Task SetImageAsync(byte[] bytes, int decodeWidth, Action<ImageSource> show)
    {
        try
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
            }

            var bitmap = new BitmapImage { DecodePixelWidth = decodeWidth };
            await bitmap.SetSourceAsync(stream);
            show(bitmap);
        }
        catch (Exception ex)
        {
            Log.Warn($"linkpreview.image-show-failed {ex.GetType().Name}");
        }
    }
}
